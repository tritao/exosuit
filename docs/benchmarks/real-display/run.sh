#!/usr/bin/env bash
# Runs one scripted session (scenarios.py) in exosuit on the display in $DISPLAY: the real GPU, compositor and window
# size, unlike Xvfb. The app plays the input into its own window, so nothing reaches other windows. State is isolated
# in OUT_DIR, which ends up holding the capture (frame timeline, screenshot), the session record and, unless
# --no-profile, a sampling profile.
#
# Usage: run.sh SCENARIO OUT_DIR [--no-profile]     then: report.py OUT_DIR
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
haxeon=${HAXEON_ROOT:-"$root/haxeon"}
scenario=$1
out=$(mkdir -p "$2" && cd "$2" && pwd)
profile=1
[[ "${3:-}" == --no-profile ]] && profile=0
[[ -n "${DISPLAY:-}" ]] || { echo "run.sh needs a display (DISPLAY)" >&2; exit 1; }
[[ -f "$root/graphical/build/host/main.hl" ]] || { echo "build exosuit first: python3 scripts/build.py" >&2; exit 1; }

# The workspace: a 10 MB file, a real source file of a few thousand lines and a small one.
workspace="$out/workspace"
mkdir -p "$out/state" "$out/capture" "$workspace"
cp "$root/graphical/src/ui/ExosuitApp.hx" "$workspace/ExosuitApp.hx"
cp "$root/src/editor/Document.hx" "$workspace/Document.hx"
python3 - "$workspace/big.txt" <<'PY'
import pathlib, sys
unit = ("ordinary editable text with é🙂 " * 6 + "\n").encode()
size = 10 * 1024 * 1024
pathlib.Path(sys.argv[1]).write_text((unit * (size // len(unit)) + b"x" * (size % len(unit))).decode())
PY
startup=()
while IFS= read -r file; do startup+=("$workspace/$file"); done < <(python3 "$here/scenarios.py" "$scenario" "$out/session.json")
seconds=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["events"][-1]["at"]) + 2)' "$out/session.json")

export PRAGTICAL_PORTABLE="$out/state"
export XDG_CONFIG_HOME="$out/state/config" XDG_DATA_HOME="$out/state/data" XDG_STATE_HOME="$out/state/state" XDG_CACHE_HOME="$out/state/cache"
native=$root/graphical/build/host/native
export LD_LIBRARY_PATH="$haxeon/out:$haxeon/.tools/hashlink:$native/pluginhost:$native/exosuit-ui-native:$native/textmateregex:$native/terminalkit${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
port=$((20000 + RANDOM % 20000))
diagnostics=()
((profile)) && diagnostics=(--diagnostics "$port" --diagnostics-wait)
title="exosuit benchmark $scenario $$"
"$haxeon/.tools/hashlink/hl" "${diagnostics[@]}" "$root/graphical/build/host/main.hl" --title="$title" \
	--capture-dir="$out/capture" --capture-seconds="$seconds" --record-path="$out/record.jsonl" \
	--input-script="$out/session.json" "$workspace" "${startup[@]}" > "$out/app.log" 2>&1 &
app=$!
recorder=
if ((profile)); then
	"$haxeon/.tools/hashlink/hlprof-live" --sources sampling,alloc --rate 1000 --duration $((seconds + 60)) --connect-timeout 30 \
		--output "$out/profile.hlpc" "$port" > "$out/recorder.log" 2>&1 &
	recorder=$!
fi
trap 'kill "$app" 2>/dev/null || true' EXIT
timeout $((seconds + 90)) tail --pid="$app" -f /dev/null || kill "$app"
wait "$app" 2>/dev/null || true
[[ -n "$recorder" ]] && { wait "$recorder" 2>/dev/null || true; }
trap - EXIT
echo "$out"
