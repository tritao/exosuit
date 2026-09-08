#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../realtime-haxe"}
language_server=${HAXEON_LSP:-"$haxeon_root/scripts/haxeon-lsp"}
smoke_dir=$(mktemp -d)
trap 'rm -rf "$smoke_dir"' EXIT

"$root_dir/scripts/build.sh"

mapfile -t sources < <(find "$root_dir/src" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t stdlib_sources < <(find "$haxeon_root/stdlib" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t compiler_sources < <(find "$haxeon_root/src/compiler" "$haxeon_root/src/runtime" -type f -name '*.hx' -print | LC_ALL=C sort)

"$root_dir/scripts/haxeon-compile.sh" \
	--output="$root_dir/out/real-language-service-smoke.hl" --entry=app.RealLanguageServiceSmokeMain \
	--root="$root_dir/src" --root="$haxeon_root/src" --root="$haxeon_root/stdlib" \
	"${sources[@]}" "${compiler_sources[@]}" "${stdlib_sources[@]}"

LD_LIBRARY_PATH="$root_dir/out:$haxeon_root/out:$haxeon_root/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$haxeon_root/vendor/hashlink/hl" "$root_dir/out/real-language-service-smoke.hl" "$language_server" "$smoke_dir"

"$root_dir/scripts/haxeon-compile.sh" \
	--output="$smoke_dir/Main.hl" --entry=Main --root="$smoke_dir" --root="$haxeon_root/stdlib" \
	"$smoke_dir/Main.hx" "${stdlib_sources[@]}"
set +e
LD_LIBRARY_PATH="$haxeon_root/out:$haxeon_root/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$haxeon_root/vendor/hashlink/hl" "$smoke_dir/Main.hl"
status=$?
set -e
if [[ $status -ne 42 ]]; then
	echo "fixed language-service fixture exited with $status, expected 42" >&2
	exit 1
fi
echo "PASS: fixed source built and executed after the real language-service cycle"
