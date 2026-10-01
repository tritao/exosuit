#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}
language_server=${HAXEON_LSP:-"$haxeon_root/scripts/haxeon-lsp"}
smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/exosuit-real-lsp.XXXXXX")
trap 'rm -rf -- "$smoke_dir"' EXIT
compiler_mode=()
if [[ ${HAXEON_SELF_HOSTED:-0} == 1 ]]; then
    compiler_mode+=(--self-hosted)
fi

cat > "$smoke_dir/haxeon.json" <<'JSON'
{
  "version": 1,
  "package": { "name": "real-language-service-fixture" },
  "entry": "Main",
  "sourceRoots": ["."],
  "scopeSourceRoots": false,
  "target": "host",
  "outputDir": "build"
}
JSON

"$haxeon" run --project "$root_dir/tests/real-language-service-smoke/haxeon.json" \
    "${compiler_mode[@]}" -- "$language_server" "$smoke_dir"
"$haxeon" build --project "$smoke_dir/haxeon.json" "${compiler_mode[@]}"
set +e
"$haxeon" run --project "$smoke_dir/haxeon.json" "${compiler_mode[@]}"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "fixed language-service fixture exited with $status, expected 42" >&2
    exit 1
fi
echo "PASS: real language-service edit, diagnose, fix, save, build and execution"
