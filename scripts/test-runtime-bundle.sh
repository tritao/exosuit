#!/usr/bin/env bash
# Developer acceptance uses the production staging routine, without release publication/pin changes.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/exstage.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
"$root_dir/scripts/stage-runtime.sh" "$fixture/initial"
mv "$fixture/initial" "$fixture/relocated bundle"
python3 "$root_dir/scripts/test-bundled-workspace.py" "$fixture/relocated bundle"
