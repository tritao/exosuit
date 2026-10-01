#!/usr/bin/env bash
# Real X11 terminal dock, PTY input, and viewport resize smoke.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
if [[ ${1:-} == --drive ]]; then
	fixture=$2
	export PRAGTICAL_PORTABLE="$fixture/state"
	export LD_LIBRARY_PATH="$haxeon_root/out:$haxeon_root/.tools/hashlink:$root_dir/graphical/build/host/native/pragtical_hx:$root_dir/graphical/build/host/native/exosuit-ui-native:$root_dir/graphical/build/host/native/terminalkit${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	LIBGL_ALWAYS_SOFTWARE=1 "$haxeon_root/.tools/hashlink/hl" "$root_dir/graphical/build/host/main.hl" \
		--open-terminal --capture-dir="$fixture/capture" --capture-seconds=4 \
		--record-path="$fixture/events.jsonl" > "$fixture/app.log" 2>&1 &
	app=$!
	trap 'kill "$app" 2>/dev/null || true' EXIT
	window=$(timeout 30 xdotool search --sync --onlyvisible --name '^exosuit$' | head -1)
	for attempt in {1..300}; do
		grep -qF 'exosuit: window ready' "$fixture/app.log" && break
		kill -0 "$app"
		sleep .1
	done
	grep -qF 'exosuit: window ready' "$fixture/app.log"
	# Let the initial PTY grid settle, then resize the actual desktop window.
	sleep .5
	xdotool windowsize "$window" 900 680
	sleep .4
	xdotool mousemove --window "$window" 450 560 click 1
	xdotool type --clearmodifiers --delay 12 'stty size'
	xdotool key Return
	wait "$app"
	trap - EXIT
	exit 0
fi

fixture=$(mktemp -d)
artifacts=${TERMINAL_UI_ARTIFACTS:-}
cleanup() {
	if [[ -n $artifacts ]]; then
		mkdir -p "$artifacts"
		cp -R "$fixture/." "$artifacts/"
	fi
	rm -rf "$fixture"
}
trap cleanup EXIT
"$root_dir/scripts/build.sh" >/dev/null
xvfb-run -a timeout 40 "$0" --drive "$fixture"
python3 - "$fixture" <<'CHECK'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
state = json.loads((root / 'capture/app-state.json').read_text())
assert state['terminal'] == 'running', state
assert 95 <= state['terminalColumns'] <= 105, state
assert 5 <= state['terminalRows'] <= 8, state
assert not state['errors'], state
tree = (root / 'capture/ui-tree.txt').read_text()
assert re.search(r'Box \[8,48 40x36\].*label="Open Folder"', tree), tree
assert tree.count('type=canvas z=1') >= state['terminalRows'], state
assert (root / 'capture/frame.png').stat().st_size > 1000
events = (root / 'events.jsonl').read_text()
assert 'SurfaceResize' in events and '900,680' in events, events
print('PASS: terminal dock, row canvases, live PTY resize, and shell input')
CHECK
