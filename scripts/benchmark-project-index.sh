#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$repo_root/../realtime-haxe"}
fixture=$(mktemp -d)
trap 'find "$fixture" -type f -delete; find "$fixture" -depth -type d -empty -delete' EXIT

python3 "$repo_root/scripts/build.py"

for directory in $(seq 0 99); do
	mkdir "$fixture/directory-$directory"
	for file in $(seq 0 99); do
		: > "$fixture/directory-$directory/file-$file.txt"
	done
done
ln -s "$fixture" "$fixture/directory-0/cycle"

mapfile -t sources < <(find "$repo_root/src" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t stdlib_sources < <(find "$haxeon_root/stdlib" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t compiler_sources < <(find "$haxeon_root/src/compiler" "$haxeon_root/src/runtime" -type f -name '*.hx' -print | LC_ALL=C sort)
"$repo_root/scripts/haxeon-compile.sh" \
	--output="$repo_root/out/project-index-benchmark.hl" --entry=app.ProjectIndexBenchmarkMain \
	--root="$repo_root/src" --root="$haxeon_root/src" --root="$haxeon_root/stdlib" \
	"${sources[@]}" "${compiler_sources[@]}" "${stdlib_sources[@]}"
(
	cd "$repo_root/out"
	LD_LIBRARY_PATH="$haxeon_root/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_root/vendor/hashlink/hl" project-index-benchmark.hl "$fixture" 10000
)
