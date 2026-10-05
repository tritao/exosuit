#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}
server=${HAXEON_LSP:-"$haxeon_root/scripts/haxeon-lsp"}
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/project" "$fixture/state"
cat > "$fixture/project/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"real-language-ui-fixture"},"entry":"Main","sourceRoots":["."],"scopeSourceRoots":false,"target":"host","outputDir":"build"}
JSON
printf 'function main():Int return "wrong";\n' > "$fixture/project/Main.hx"
python3 - "$fixture/state/settings.json" "$server" <<'PY'
import json, sys
with open(sys.argv[1], "w") as output:
    json.dump({"version": 1, "values": {"languages/haxeon/command": json.dumps([sys.argv[2]])}, "state": {}}, output)
PY
compiler_mode=()
if [[ ${HAXEON_SELF_HOSTED:-0} == 1 ]]; then compiler_mode+=(--self-hosted); fi
PRAGTICAL_PORTABLE="$fixture/state" xvfb-run -a "$haxeon" run --project "$root_dir/tests/real-language-ui-smoke/haxeon.json" "${compiler_mode[@]}" -- "$fixture/project"
"$haxeon" build --project "$fixture/project/haxeon.json" "${compiler_mode[@]}"
set +e
"$haxeon" run --project "$fixture/project/haxeon.json" "${compiler_mode[@]}"
result=$?
set -e
if [[ $result -ne 42 ]]; then
    echo "graphical language fixture exited with $result, expected 42" >&2
    exit 1
fi
echo "PASS: graphical real-server fixture builds and executes after language edits"
PRAGTICAL_PORTABLE="$fixture/state-repository" HAXEON_LSP="$server" xvfb-run -a "$haxeon" run --project "$root_dir/tests/real-language-ui-smoke/haxeon.json" "${compiler_mode[@]}" -- "$root_dir" repository
