#!/usr/bin/env bash
# Builds the exosuit editor for the browser into build/web/site.
#
#   1. Generates the wasm32 FFI interfaces of every native kit.
#   2. Compiles the editor to a Haxeon guest module (entry app.WebMain), wasm32 by default or
#      wasm-gc with EXOSUIT_WEB_TARGET=wasm-gc.
#   3. Links the Emscripten host (NativeKit, UIKit, SceneKit) and exports every C
#      function the guest imports from those libraries.
#   4. Assembles the page, both modules and the fonts.
#
# Serve the result over HTTP: python3 -m http.server --directory build/web/site 8080
set -euo pipefail

app_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
materia_dir=$(dirname "$app_dir")
haxeon_dir=${HAXEON_DIR:-${HAXEON_ROOT:-"$app_dir/haxeon"}}
emsdk_dir=${EMSDK_DIR:-"$haxeon_dir/vendor/nativekit/.tools/emsdk"}
build_dir=${EXOSUIT_WEB_BUILD_DIR:-"$app_dir/build/web"}
build_type=${CMAKE_BUILD_TYPE:-Release}
# wasm32 keeps Haxe values in linear memory; wasm-gc keeps them as Wasm GC objects. The host is the same.
guest_target=${EXOSUIT_WEB_TARGET:-wasm32}
case $guest_target in wasm32 | wasm-gc) ;; *) echo "build.sh: unsupported guest target: $guest_target" >&2; exit 2 ;; esac
build_dir=$(realpath -m "$build_dir")
site_dir="$build_dir/site"
guest="$build_dir/exosuit_guest.wasm"

# Linear memory: the Emscripten host heap ends at host_limit and the guest's
# managed heap fills the rest. Both sides must agree, so both are derived here.
page_size=65536
host_limit=${EXOSUIT_WEB_HOST_HEAP_BYTES:-134217728}
memory_size=${EXOSUIT_WEB_MEMORY_BYTES:-805306368}
if (( host_limit % page_size != 0 || memory_size % page_size != 0 || host_limit >= memory_size )); then
	echo "build.sh: memory sizes must be 64 KiB multiples with the host heap below the total" >&2
	exit 2
fi

if [[ ! -f "$emsdk_dir/emsdk_env.sh" ]]; then
	echo "build.sh: Emscripten is not installed; run nativekit/tools/setup-web.sh" >&2
	exit 1
fi
if [[ ! -x "$haxeon_dir/.tools/hashlink/hl" ]]; then
	echo "build.sh: the Haxeon toolchain is missing; run haxeon/scripts/bootstrap-tools.sh" >&2
	exit 1
fi
mkdir -p "$build_dir" "$site_dir/assets"

echo "== wasm32 FFI interfaces"
HAXEON_DIR="$haxeon_dir" NATIVEKIT_DIR="$haxeon_dir/vendor/nativekit" "$app_dir/web/generate-wasm-hxi.sh" "$build_dir/hxi" \
 "$(realpath --relative-to="$materia_dir" "$haxeon_dir")/packages/platform/tools/audit-haxeon-abi.sh:nativekit.hxi:--output=" \
 "$(realpath --relative-to="$materia_dir" "$haxeon_dir")/packages/platform/tools/audit-haxeon-net-abi.sh:nativekit-net.hxi:--output=" \
 "$(realpath --relative-to="$materia_dir" "$haxeon_dir")/packages/gpu/tools/check-hxi.sh:nativekit-gpu.hxi" \
 "$(realpath --relative-to="$materia_dir" "$haxeon_dir")/packages/ui/tools/check-hxi.sh:nativekit-ui.hxi" \
 "scenekit/scene/tools/check-hxi.sh:nativekit-scene.hxi" \
 "scenekit/scene_render/tools/check-hxi.sh:nativekit-scene-render.hxi" \
 "exosuit/native-packages/noise/tools/generate-wasm-hxi.sh:noisekit.hxi" \
 "exosuit/native-packages/oniguruma/tools/generate-wasm-hxi.sh:textmate_regex.hxi" \
 "exosuit/native-packages/terminal/tools/generate-wasm-hxi.sh:terminalkit.hxi"

echo "== Haxeon $guest_target guest"
contract="$build_dir/memory_contract.json"
cat > "$contract" <<JSON
{
  "name": "nativekit-haxeon-linear-memory",
  "version": 1,
  "address_model": "wasm32",
  "page_size": $page_size,
  "host_base": 0,
  "host_limit": $host_limit,
  "guest_base": $host_limit,
  "guest_limit": $memory_size,
  "memory_size": $memory_size
}
JSON
# The compiler runs as HashLink bytecode; rebuild it when its sources change.
compiler="$build_dir/haxeon-compiler.hl"
"$haxeon_dir/.tools/haxe/haxe" --cwd "$haxeon_dir" -cp src -hl "$compiler" -main compiler.tools.HaxeonCompiler
python3 "$app_dir/web/generate-manifest.py"
python3 "$materia_dir/tools/web/guest-arguments.py" "$app_dir/web/haxeon.json" "$build_dir/hxi" > "$build_dir/guest-arguments.txt"
mapfile -t guest_arguments < "$build_dir/guest-arguments.txt"
(cd "$haxeon_dir" && LD_LIBRARY_PATH="$haxeon_dir/out:$haxeon_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	HAXEON_WASM_LEGACY_EXCEPTIONS=1 \
	"$haxeon_dir/.tools/hashlink/hl" "$compiler" --target="$guest_target" --output="$guest" --entry=app.WebMain \
	--wasm-import-memory --wasm-memory-contract="$contract" \
	"${guest_arguments[@]}") > "$build_dir/guest-compile.log" 2>&1
echo "Guest compiled; see $build_dir/guest-compile.log"

echo "== Emscripten host"
# Export the guest's imports from the libraries the host links; haxeon-host.js
# gives the guest's remaining imports stubs that throw when called.
exports="$build_dir/exports.json"
node - "$guest" "$exports" <<'NODE'
const fs = require("fs");
const [guestPath, exportsPath] = process.argv.slice(2);
const linked = new Set(["nativekit", "nativekit_gpu", "nativekit_ui", "nativekit_scene", "nativekit_scene_render", "noisekit", "terminalkit", "textmate_regex"]);
const module = new WebAssembly.Module(fs.readFileSync(guestPath));
const names = new Set(["_main", "_nk_last_error", "_nkgpu_last_error", "_nkui_haxeon_memory_contract_status",
  "_nkui_haxeon_memory_contract_version", "_nkui_haxeon_memory_contract_page_size",
  "_nkui_haxeon_memory_contract_host_base", "_nkui_haxeon_memory_contract_host_limit",
  "_nkui_haxeon_memory_contract_guest_base", "_nkui_haxeon_memory_contract_guest_limit",
  "_nkui_haxeon_memory_contract_memory_size"]);
for (const entry of WebAssembly.Module.imports(module))
  if (entry.kind === "function" && linked.has(entry.module)) names.add("_" + entry.name);
fs.writeFileSync(exportsPath, JSON.stringify([...names].sort()));
NODE
source "$emsdk_dir/emsdk_env.sh" >/dev/null 2>&1
emcmake cmake -S "$app_dir/web" -DEXOSUIT_HAXEON_ROOT="$haxeon_dir" -B "$build_dir/host" -G Ninja -DCMAKE_BUILD_TYPE="$build_type" \
	-DEXOSUIT_WEB_GUEST_WASM="$guest" -DEXOSUIT_WEB_EXPORTS_FILE="$exports" \
	-DNK_WASM_HOST_HEAP_LIMIT="$host_limit" -DEXOSUIT_WEB_GUEST_MEMORY_LIMIT="$memory_size" >/dev/null
cmake --build "$build_dir/host" --target exosuit_web
# Instantiation stops at the first mismatched import; report them all here.
node "$materia_dir/tools/web/check-imports.js" "$guest" "$build_dir/host/exosuit_web.wasm" "$build_dir/host/exosuit_web.js"

echo "== Site"
cp "$build_dir/host/exosuit_web.js" "$build_dir/host/exosuit_web.wasm" "$guest" "$site_dir/"
cp "$app_dir/web/index.html" "$app_dir/web/exosuit.js" "$app_dir/web/remote-device-store.js" "$haxeon_dir/stdlib/haxeon/wasm/haxeon-host.js" "$site_dir/"
fonts="$haxeon_dir/packages/ui/vendor/skribidi/example/data"
cp "$fonts/IBMPlexSans-Regular.ttf" "$fonts/IBMPlexMono-Regular.ttf" "$fonts/NotoEmoji-Regular.ttf" "$site_dir/assets/"
mkdir -p "$site_dir/licenses/seti"
cp "$app_dir/graphical/assets/seti/LICENSE.txt" "$app_dir/graphical/assets/seti/ThirdPartyNotices.txt" "$app_dir/graphical/assets/seti/SOURCE.txt" "$site_dir/licenses/seti/"
echo "Built $site_dir"
echo "Serve it with: python3 -m http.server --directory \"$site_dir\" 8080"
