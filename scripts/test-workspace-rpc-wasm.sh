#!/usr/bin/env bash
set -euo pipefail
exosuit_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root_dir=${HAXEON_ROOT:-"$exosuit_dir/haxeon"}
root_dir=$(cd "$root_dir" && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
source "$root_dir/scripts/haxeon-compiler.sh"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/exosuit-workspace-rpc-wasm.XXXXXX")
cleanup() {
 rm -rf -- "$fixture_dir"
 if [[ -n ${haxeon_compiler_dir:-} ]]; then rm -rf -- "$haxeon_compiler_dir"; fi
}
trap cleanup EXIT
cd "$root_dir"
for target in wasm32 wasm-gc; do
 haxeon_compile --target="$target" --output="$fixture_dir/$target.wasm" --entry=app.WorkspaceRpcPortableMain \
  --root="$exosuit_dir/tests/haxeon-rpc/src" --root="$exosuit_dir/src" \
  "$exosuit_dir/tests/haxeon-rpc/src/app/WorkspaceRpcPortableMain.hx" > "$fixture_dir/$target.log" 2>&1 || { cat "$fixture_dir/$target.log"; exit 1; }
done
node - "$fixture_dir" <<'JS'
const fs = require("fs");
const runtime = {__math_is_finite:Number.isFinite, __math_ceil:Math.ceil, __math_floor:Math.floor,
 __math_pow:Math.pow, __math_sqrt:Math.sqrt, __math_fmod:(a,b)=>a%b, __std_int_f64:Math.trunc};
class ProgramExit { constructor(code) { this.code=code; } }
for (const target of ["wasm32", "wasm-gc"]) {
 const module = new WebAssembly.Module(fs.readFileSync(`${process.argv[2]}/${target}.wasm`));
 const instance = new WebAssembly.Instance(module, {haxeon_runtime:runtime,std:{sys_exit:code=>{throw new ProgramExit(code);}}});
 let result;
 try { result=instance.exports.main(); } catch(error) { if (error instanceof ProgramExit) result=error.code; else throw error; }
 if (result !== 42) throw new Error(`${target}: workspace fixture failed (${result})`);
 console.log(`PASS: frozen RPC compatibility vectors, version/method errors, workspace recovery and mutation reconciliation on ${target}`);
}
JS
