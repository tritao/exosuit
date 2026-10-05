#!/usr/bin/env bash
# Thin wrapper around the haxeon CLI: builds and launches the graphical app
# (graphical/haxeon.json, entry app.GraphicalMain). See scripts/build.sh for
# why this is a separate manifest from the headless core.
# Extra arguments after the script's own are forwarded to the running program.
set -euo pipefail

# Let native crashes produce a core dump, up to the inherited hard limit.
ulimit -S -c "$(ulimit -H -c)"

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}
# The CLI launches the app from the graphical project's directory. Keep the
# development server fallback anchored to the compiler selected by this wrapper.
export HAXEON_ROOT="$(cd "$haxeon_root" && pwd)"

# Match scripts/build.sh and the Haxeon CLI compiler default.
extra=()
if [[ "${HAXEON_SELF_HOSTED:-0}" == "1" ]]; then
	extra+=(--self-hosted)
fi

export EXOSUIT_AGENT_LAUNCHER="$root_dir/scripts/run-agent.py"
exec "$haxeon" run --project "$root_dir/graphical/haxeon.json" "${extra[@]}" -- "$@"
