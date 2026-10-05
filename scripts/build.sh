#!/usr/bin/env bash
# Thin wrapper around the haxeon CLI: builds the graphical app
# (graphical/haxeon.json, entry app.GraphicalMain).
#
# Core and test manifests compile shared models without building the graphical GPU host.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}

# Match the Haxeon CLI default; set HAXEON_SELF_HOSTED=1 to use the verified bootstrap.
extra=()
if [[ "${HAXEON_SELF_HOSTED:-0}" == "1" ]]; then
	extra+=(--self-hosted)
fi

exec "$haxeon" build --project "$root_dir/graphical/haxeon.json" "${extra[@]}" "$@"
