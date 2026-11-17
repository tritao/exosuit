#!/usr/bin/env bash
set -euo pipefail
# What the steps start talks only to a suit of its own, in a home of its own, and does not start it (see suit/README.md);
# scripts/test.sh makes a home of its own for the suites.
EXOSUIT_SUIT_HOME=$(mktemp -d)/suit
export EXOSUIT_SUIT_HOME EXOSUIT_SUIT_AUTOSTART=0

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
# Shared compiler/native output trees require serial stages.
(cd "$haxeon_root" && ./scripts/test.sh)
"$root_dir/scripts/test.sh"
python3 "$root_dir/scripts/build.py"
"$root_dir/scripts/test-haxeon-lsp.sh"
"$root_dir/scripts/test-release.sh"

"$root_dir/scripts/test-web.sh"
