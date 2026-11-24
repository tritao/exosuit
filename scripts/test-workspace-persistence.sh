#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon=${HAXEON_BIN:-"${HAXEON_ROOT:-$root_dir/haxeon}/scripts/haxeon"}
directory=$(mktemp -d /tmp/exosuit-persistence.XXXXXX)
trap 'rm -rf -- "$directory"' EXIT
self_hosted=()
if [[ "${HAXEON_SELF_HOSTED:-0}" == "1" ]]; then
  self_hosted+=(--self-hosted)
fi
"$haxeon" run --project "$root_dir/tests/workspace-persistence/haxeon.json" ${self_hosted[@]+"${self_hosted[@]}"} -- "$directory/catalog.sqlite"
