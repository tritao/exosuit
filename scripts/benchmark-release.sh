#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
rss_file="$fixture/peak-rss.txt"
plugin_dir="$fixture/plugin"
mkdir "$plugin_dir"
cp "$root_dir/plugins/example/plugin.conf" "$root_dir/plugins/example/Main.hx" "$plugin_dir/"

python3 "$root_dir/scripts/build.py"

mapfile -t sources < <(find "$root_dir/src" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t stdlib_sources < <(find "$haxeon_root/stdlib" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t compiler_sources < <(find "$haxeon_root/src/compiler" "$haxeon_root/src/runtime" -type f -name '*.hx' -print | LC_ALL=C sort)
"$root_dir/scripts/haxeon-compile.sh" \
	--output="$root_dir/out/release-benchmark.hl" --entry=app.ReleaseBenchmarkMain \
	--root="$root_dir/src" --root="$haxeon_root/src" --root="$haxeon_root/stdlib" \
	"${sources[@]}" "${compiler_sources[@]}" "${stdlib_sources[@]}"
(
	cd "$root_dir/out"
	LD_LIBRARY_PATH="$haxeon_root/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		/usr/bin/time -f 'BENCH peak_rss_kib=%M' -o "$rss_file" \
		"$haxeon_root/vendor/hashlink/hl" release-benchmark.hl "$fixture" "$plugin_dir/plugin.conf" "$plugin_dir/Main.hx"
)
sed -n '1p' "$rss_file"
