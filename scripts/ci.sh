#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Release packaging and the LSP smoke test still target the old realtime-haxe
# layout and are not part of this build/test setup yet.
"$root_dir/scripts/test.sh"
"$root_dir/scripts/build.sh"
