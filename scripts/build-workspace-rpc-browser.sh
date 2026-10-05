#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
materia_dir=$(cd "$root_dir/.." && pwd)
haxeon_dir=${HAXEON_ROOT:-"$materia_dir/haxeon"}
build_dir="$root_dir/tests/workspace-browser/build"
target=${1:-wasm-gc}
case "$target" in wasm-gc|wasm32) ;; *) echo "Expected wasm-gc or wasm32" >&2; exit 2 ;; esac
mkdir -p "$build_dir/site" "$build_dir/hxi"
cp "$materia_dir/nativekit/bindings/haxe/nativekit-wasm.hxi" "$build_dir/hxi/nativekit-wasm.hxi"
python3 "$materia_dir/tools/web/guest-arguments.py" "$root_dir/tests/workspace-browser/haxeon.json" "$build_dir/hxi" > "$build_dir/arguments"
mapfile -t arguments < "$build_dir/arguments"
cat > "$build_dir/contract.json" <<'JSON'
{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,"host_limit":33554432,"guest_base":33554432,"guest_limit":134217728,"memory_size":134217728}
JSON
"$haxeon_dir/.tools/haxe/haxe" --cwd "$haxeon_dir" -cp src -hl "$build_dir/compiler.hl" -main compiler.tools.HaxeonCompiler
(cd "$haxeon_dir" && LD_LIBRARY_PATH="$haxeon_dir/out:$haxeon_dir/.tools/hashlink" HAXEON_WASM_LEGACY_EXCEPTIONS=1 \
 "$haxeon_dir/.tools/hashlink/hl" "$build_dir/compiler.hl" --target="$target" --entry=app.BrowserRpcMain --output="$build_dir/site/guest.wasm" \
 --wasm-import-memory --wasm-memory-contract="$build_dir/contract.json" "${arguments[@]}") > "$build_dir/compile-$target.log" 2>&1
node - "$build_dir/site/guest.wasm" "$build_dir/exports.json" <<'JS'
const fs=require("fs"),module=new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const names=new Set(["_main","_nk_last_error"]);
for (const entry of WebAssembly.Module.imports(module)) if (entry.module === "nativekit" && entry.kind === "function") names.add("_"+entry.name);
fs.writeFileSync(process.argv[3],JSON.stringify([...names]));
JS
source "$materia_dir/nativekit/.tools/emsdk/emsdk_env.sh" >/dev/null 2>&1
emcmake cmake -S "$root_dir/tests/workspace-browser/host" -B "$build_dir/host" -G Ninja -DCMAKE_BUILD_TYPE=Release -DRPC_EXPORTS="$build_dir/exports.json"
cmake --build "$build_dir/host" --target workspace_rpc_host
cp "$build_dir/host/workspace_rpc_host.js" "$build_dir/host/workspace_rpc_host.wasm" "$build_dir/site/"
cp "$haxeon_dir/stdlib/haxeon/wasm/haxeon-host.js" "$root_dir/tests/workspace-browser/browser.js" "$root_dir/tests/workspace-browser/index.html" "$build_dir/site/"
