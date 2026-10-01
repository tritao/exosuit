#!/usr/bin/env bash
# Thin wrapper around the haxeon CLI: builds the graphical app
# (graphical/haxeon.json, entry app.GraphicalMain).
#
# The headless core (haxeon.json, entry app.Main) that the test suite
# exercises is a separate, lighter manifest - see scripts/test.sh. Splitting
# these keeps every headless test project (each depends on the core manifest
# as "pragtical_hx") from also having to build and link NativeKit/UIKit's
# whole native GPU toolkit, which only the graphical app actually needs; see
# graphical/haxeon.json's "exosuit-ui-native" dependency.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}

# Match the Haxeon CLI default; set HAXEON_SELF_HOSTED=1 to use the verified bootstrap.
extra=()
if [[ "${HAXEON_SELF_HOSTED:-0}" == "1" ]]; then
	extra+=(--self-hosted)
fi

exec "$haxeon" build --project "$root_dir/graphical/haxeon.json" "${extra[@]}" "$@"
