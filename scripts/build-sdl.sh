#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../realtime-haxe"}
pragtical_root=${PRAGTICAL_ROOT:-"$root_dir/../pragtical"}
cc=${CC:-cc}

mkdir -p "$root_dir/build" "$root_dir/out"
python3 "$root_dir/scripts/generate-platform-abi.py" --check
if [[ ! -f "$haxeon_root/out/realtime_runtime.hdll" ]]; then
	echo "missing Haxeon runtime bridge: $haxeon_root/out/realtime_runtime.hdll" >&2
	exit 1
fi

mapfile -t sources < <(find "$root_dir/src" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t stdlib_sources < <(find "$haxeon_root/stdlib" -type f -name '*.hx' -print | LC_ALL=C sort)
mapfile -t compiler_sources < <(find "$haxeon_root/src/compiler" "$haxeon_root/src/runtime" -type f -name '*.hx' -print | LC_ALL=C sort)
read -r -a sdl_cflags <<< "$(pkg-config --cflags sdl3)"
read -r -a sdl_libs <<< "$(pkg-config --libs sdl3)"
read -r -a font_cflags <<< "$(pkg-config --cflags freetype2)"
read -r -a font_libs <<< "$(pkg-config --libs freetype2)"
read -r -a shape_cflags <<< "$(pkg-config --cflags harfbuzz)"
read -r -a shape_libs <<< "$(pkg-config --libs harfbuzz)"
read -r -a lua_cflags <<< "$(pkg-config --cflags lua5.4)"
cc_path=$(command -v "$cc")
cc_version=$("$cc" --version | sed -n '1p')
pkg_config_versions=$(pkg-config --modversion sdl3 freetype2 harfbuzz lua5.4)
patchelf_path=$(command -v patchelf || true)
patchelf_version=$([[ -n "$patchelf_path" ]] && patchelf --version || true)
hl_host_objects=(
	"$haxeon_root/vendor/hashlink/src/code.o"
	"$haxeon_root/vendor/hashlink/src/hlpatch.o"
	"$haxeon_root/vendor/hashlink/src/hlruntime.o"
	"$haxeon_root/vendor/hashlink/src/jit.o"
	"$haxeon_root/vendor/hashlink/src/jit_emit.o"
	"$haxeon_root/vendor/hashlink/src/jit_regs.o"
	"$haxeon_root/vendor/hashlink/src/jit_x86_64.o"
	"$haxeon_root/vendor/hashlink/src/jit_dump.o"
	"$haxeon_root/vendor/hashlink/src/jit_gdb.o"
	"$haxeon_root/vendor/hashlink/src/module.o"
	"$haxeon_root/vendor/hashlink/src/debugger.o"
	"$haxeon_root/vendor/hashlink/src/diagnostics.o"
	"$haxeon_root/vendor/hashlink/src/diagnostics_transport.o"
	"$haxeon_root/vendor/hashlink/src/profile.o"
)

mapfile -t native_inputs < <(
	find "$root_dir/include" "$root_dir/native" "$pragtical_root/src" \
		-type f \( -name '*.c' -o -name '*.h' \) -print | LC_ALL=C sort
)
build_inputs=(
	"$root_dir/scripts/build-sdl.sh"
	"$root_dir/scripts/haxeon-compile.sh"
	"$root_dir/scripts/generate-platform-abi.py"
	"$root_dir/README.md"
	"$haxeon_root/.tools/haxe/haxe"
	"$haxeon_root/out/realtime_runtime.hdll"
	"$pragtical_root/data/fonts/JetBrainsMono-Regular.ttf"
	"$pragtical_root/data/fonts/NotoSansSymbols2-Regular.ttf"
	"${sources[@]}"
	"${compiler_sources[@]}"
	"${stdlib_sources[@]}"
	"${native_inputs[@]}"
	"${hl_host_objects[@]}"
)
build_signature=$(
	{
		printf '%s\0' "$haxeon_root" "$pragtical_root" "$cc" "$cc_path" "$cc_version" \
			"$pkg_config_versions" "$patchelf_path" "$patchelf_version" \
			"${sdl_cflags[*]}" "${sdl_libs[*]}" \
			"${font_cflags[*]}" "${font_libs[*]}" \
			"${shape_cflags[*]}" "${shape_libs[*]}" "${lua_cflags[*]}"
		sha256sum -- "${build_inputs[@]}"
	} | sha256sum | awk '{print $1}'
)
signature_file="$root_dir/build/build-sdl.signature"
outputs=(
	"$root_dir/out/pragtical-haxeon.hl"
	"$root_dir/out/pragtical_hx.hdll"
	"$root_dir/out/realtime_runtime.hdll"
	"$root_dir/out/pragtical-haxeon"
	"$root_dir/out/README.md"
	"$root_dir/out/data/fonts/JetBrainsMono-Regular.ttf"
	"$root_dir/out/data/fonts/NotoSansSymbols2-Regular.ttf"
)
outputs_complete=true
for output in "${outputs[@]}"; do
	if [[ ! -f "$output" ]]; then
		outputs_complete=false
		break
	fi
done
if [[ ${PRAGTICAL_FORCE_REBUILD:-0} != 1 && "$outputs_complete" == true \
	&& -f "$signature_file" && $(<"$signature_file") == "$build_signature" ]]; then
	echo "SDL build is up to date"
	exit 0
fi

stage_dir=$(mktemp -d "$root_dir/out/.build-sdl.XXXXXX")
trap 'find "$stage_dir" -depth -delete' EXIT
"$root_dir/scripts/haxeon-compile.sh" \
	--output="$stage_dir/pragtical-haxeon.hl" --entry=app.GraphicalMain \
	--ffi-header="$root_dir/include/pragtical_hx/native_ffi.h" --ffi-library=pragtical_hx \
	--root="$root_dir/src" --root="$haxeon_root/src" --root="$haxeon_root/stdlib" \
	"${sources[@]}" "${compiler_sources[@]}" "${stdlib_sources[@]}"

"$cc" -std=c11 -Wall -Wextra -Werror \
	-Wno-sign-compare -Wno-missing-field-initializers -Wno-ignored-qualifiers \
	-Wno-type-limits -Wno-unused-parameter \
	-fPIC -shared \
	-I"$root_dir/include" -I"$root_dir/native" -I"$haxeon_root/vendor/hashlink/src" -I"$pragtical_root/src" \
	"$root_dir/native/hashlink/pragtical_hx.c" \
	-L"$haxeon_root/vendor/hashlink" -lhl \
	-Wl,-rpath,'$ORIGIN/tools' \
	-o "$stage_dir/pragtical_hx.hdll"

"$cc" -std=c11 -Wall -Wextra -Werror \
	-Wno-sign-compare -Wno-missing-field-initializers -Wno-ignored-qualifiers \
	-Wno-type-limits -Wno-unused-parameter \
	-DPHX_WITH_SDL -DPHX_WITH_FREETYPE \
	-I"$root_dir/include" -I"$root_dir/native" -I"$haxeon_root/vendor/hashlink/src" -I"$pragtical_root/src" \
	"${sdl_cflags[@]}" "${font_cflags[@]}" "${shape_cflags[@]}" "${lua_cflags[@]}" \
	"$root_dir/native/host/main.c" \
	"$root_dir/native/headless/platform.c" \
	"$root_dir/native/pragtical/renderer_backend.c" \
	"$pragtical_root/src/renderer/atlas.c" \
	"$pragtical_root/src/renderer/atlas_surface.c" \
	"$pragtical_root/src/renderer/backend/surface.c" \
	"$pragtical_root/src/renderer/cache.c" \
	"$pragtical_root/src/renderer/renderer.c" \
	"$pragtical_root/src/renderer/window.c" \
	"${hl_host_objects[@]}" \
	-L"$stage_dir" -Wl,-rpath,'$ORIGIN:$ORIGIN/tools' -l:pragtical_hx.hdll \
	-L"$haxeon_root/vendor/hashlink" -lhl \
	"${sdl_libs[@]}" "${font_libs[@]}" "${shape_libs[@]}" -lm -rdynamic \
	-o "$stage_dir/pragtical-haxeon"
cp "$haxeon_root/out/realtime_runtime.hdll" "$stage_dir/realtime_runtime.hdll"
if command -v patchelf >/dev/null; then
	patchelf --set-rpath '$ORIGIN/tools' "$stage_dir/realtime_runtime.hdll"
fi
mv -f "$stage_dir/pragtical-haxeon.hl" "$root_dir/out/pragtical-haxeon.hl"
mv -f "$stage_dir/pragtical_hx.hdll" "$root_dir/out/pragtical_hx.hdll"
mv -f "$stage_dir/realtime_runtime.hdll" "$root_dir/out/realtime_runtime.hdll"
mv -f "$stage_dir/pragtical-haxeon" "$root_dir/out/pragtical-haxeon"
cp "$root_dir/README.md" "$root_dir/out/README.md"
mkdir -p "$root_dir/out/data/fonts"
cp "$pragtical_root/data/fonts/JetBrainsMono-Regular.ttf" "$root_dir/out/data/fonts/"
cp "$pragtical_root/data/fonts/NotoSansSymbols2-Regular.ttf" "$root_dir/out/data/fonts/"
printf '%s\n' "$build_signature" > "$stage_dir/build-sdl.signature"
mv -f "$stage_dir/build-sdl.signature" "$signature_file"
find "$stage_dir" -depth -delete
trap - EXIT
