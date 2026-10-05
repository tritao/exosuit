#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$root_dir/scripts/test-workspace-attachment.py"
