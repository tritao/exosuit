#!/usr/bin/env bash
set -euo pipefail
# Tests must not start the user's suit daemon.
export EXOSUIT_SUIT_AUTOSTART=${EXOSUIT_SUIT_AUTOSTART:-0}
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for target in wasm-gc wasm32; do
  bash "$root_dir/scripts/build-workspace-rpc-browser.sh" "$target"
  python3 "$root_dir/scripts/test-workspace-rpc-browser.py"
done
