#!/usr/bin/env bash
set -euo pipefail
# Tests must not start the user's suit daemon.
export EXOSUIT_SUIT_AUTOSTART=${EXOSUIT_SUIT_AUTOSTART:-0}
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$root_dir/scripts/test-workspace-attachment.py"
