#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
# Shared compiler/native output trees require serial stages.
(cd "$haxeon_root" && ./scripts/test.sh)
"$root_dir/scripts/test.sh"
python3 "$root_dir/scripts/build.py"
"$root_dir/scripts/test-skribidi-layout.sh"
"$root_dir/scripts/test-haxeon-lsp.sh"
"$root_dir/scripts/test-real-language-ui.sh"
"$root_dir/scripts/test-uikit-workflow.sh"
"$root_dir/scripts/test-decoration-ui.sh"
"$root_dir/scripts/test-workspace-ui.sh"
"$root_dir/scripts/test-release.sh"

"$root_dir/scripts/test-web.sh"
