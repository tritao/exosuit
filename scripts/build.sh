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

# The reference-Haxe bootstrap of Haxeon's own compiler is reliable again (the
# in-progress change under haxeon/src/compiler that used to break it has
# landed), so this defaults to the normal reference-compiler build.
# --self-hosted (Haxeon's precompiled bootstrap/compiler.hl) is available as an
# override, but is NOT the default here: it has a confirmed generic-resolution
# bug reached through this project's graphical entry (app.GraphicalMain ->
# nativekit.ui.widgets.text.TextField -> ComboBox's Array<SelectOption<T>>,
# "Type \"SelectOption\" does not accept type arguments"), which the
# reference-compiler build does not hit.
extra=()
if [[ "${HAXEON_SELF_HOSTED:-0}" == "1" ]]; then
	extra+=(--self-hosted)
fi

# Sidesteps a Haxeon executor race on a clean checkout; see run_test() in
# scripts/test.sh for the full explanation.
mkdir -p "$root_dir/graphical/build/.haxeon/actions"

exec "$haxeon" build --project "$root_dir/graphical/haxeon.json" "${extra[@]}" "$@"
