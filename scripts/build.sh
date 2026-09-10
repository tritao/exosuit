#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../realtime-haxe"}
nativekit_root=${NATIVEKIT_ROOT:-"$root_dir/../nativekit"}
cc=${CC:-cc}

mkdir -p "$root_dir/build" "$root_dir/out"
python3 "$root_dir/scripts/generate-platform-abi.py" --check

if [[ ! -f "$haxeon_root/out/realtime_runtime.hdll" ]]; then
	echo "missing Haxeon runtime bridge: $haxeon_root/out/realtime_runtime.hdll" >&2
	echo "run $haxeon_root/scripts/test-poc.sh once to build it" >&2
	exit 1
fi

mapfile -t sources < <(find "$root_dir/src" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t stdlib_sources < <(find "$haxeon_root/stdlib" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t compiler_sources < <(find "$haxeon_root/src/compiler" "$haxeon_root/src/runtime" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t nativekit_sources < <(find "$nativekit_root/bindings/haxe" -type f -name '*.hx' ! -name '*Tests.hx' -print | LC_ALL=C sort)

stage_dir=$(mktemp -d "$root_dir/out/.build-headless.XXXXXX")
trap 'find "$stage_dir" -depth -delete' EXIT

"$root_dir/scripts/haxeon-compile.sh" \
	--output="$stage_dir/pragtical-haxeon.hl" \
	--entry=app.Main \
	--ffi-header="$root_dir/include/pragtical_hx/native_ffi.h" \
	--ffi-library=pragtical_hx \
	--ffi-interface="$nativekit_root/bindings/haxe/nativekit-abi64.hxi" \
	--root="$root_dir/src" \
	--root="$haxeon_root/src" \
	--root="$haxeon_root/stdlib" \
	--root="$nativekit_root/bindings/haxe" \
	"${sources[@]}" "${compiler_sources[@]}" "${stdlib_sources[@]}" "${nativekit_sources[@]}"

"$cc" -std=c11 -Wall -Wextra -Werror -fPIC -shared \
	-I"$root_dir/include" -I"$haxeon_root/vendor/hashlink/src" \
	"$root_dir/native/headless/platform.c" \
	"$root_dir/native/hashlink/pragtical_hx.c" \
	-L"$haxeon_root/vendor/hashlink" -lhl \
	-Wl,-rpath,"$haxeon_root/vendor/hashlink" \
	-o "$stage_dir/pragtical_hx.hdll"
cp "$haxeon_root/out/realtime_runtime.hdll" "$stage_dir/realtime_runtime.hdll"
mv -f "$stage_dir/pragtical-haxeon.hl" "$root_dir/out/pragtical-haxeon.hl"
mv -f "$stage_dir/pragtical_hx.hdll" "$root_dir/out/pragtical_hx.hdll"
mv -f "$stage_dir/realtime_runtime.hdll" "$root_dir/out/realtime_runtime.hdll"
find "$stage_dir" -depth -delete
trap - EXIT
