#!/usr/bin/env bash
# Thin wrapper around the haxeon CLI: builds and launches the graphical app
# (graphical/haxeon.json, entry app.GraphicalMain). See scripts/build.sh for
# why this is a separate manifest from the headless core.
# Extra arguments after the script's own are forwarded to the running program.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}

# See scripts/build.sh for why --self-hosted is NOT the default here.
extra=()
if [[ "${HAXEON_SELF_HOSTED:-0}" == "1" ]]; then
	extra+=(--self-hosted)
fi

# Sidesteps a Haxeon executor race on a clean checkout; see run_test() in
# scripts/test.sh for the full explanation.
mkdir -p "$root_dir/graphical/build/.haxeon/actions"

exec "$haxeon" run --project "$root_dir/graphical/haxeon.json" "${extra[@]}" -- "$@"
