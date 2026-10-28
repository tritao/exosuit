#!/usr/bin/env bash
# Real X11 terminal dock, clipboard paste, PTY input, and viewport resize smoke.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
if [[ ${1:-} == --drive ]]; then
	fixture=$2
	export PRAGTICAL_PORTABLE="$fixture/state"
	export LD_LIBRARY_PATH="$haxeon_root/out:$haxeon_root/.tools/hashlink:$root_dir/graphical/build/host/native/pluginhost:$root_dir/graphical/build/host/native/exosuit-ui-native:$root_dir/graphical/build/host/native/terminalkit${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	LIBGL_ALWAYS_SOFTWARE=1 "$haxeon_root/.tools/hashlink/hl" "$root_dir/graphical/build/host/main.hl" \
		--open-terminal --capture-dir="$fixture/capture" --capture-seconds=16 \
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
	printf '%s' "stty size; printf pasted > '$fixture/paste-ok'" | xclip -selection clipboard
	xdotool key --clearmodifiers ctrl+shift+v
	sleep .2
	xdotool key Return
    for attempt in {1..100}; do
        [[ -f "$fixture/paste-ok" ]] && break
        sleep .02
    done
    xdotool type --clearmodifiers --delay 1 "python3 '$fixture/mouse.py' '$fixture'"
    xdotool key Return
    for attempt in {1..100}; do
        [[ -f "$fixture/mouse-ready" ]] && break
        sleep .02
    done
    [[ -f "$fixture/mouse-ready" ]]
    sleep .7
    xdotool mousemove --window "$window" 450 560 mousedown 1
    xdotool mousemove --window "$window" 480 580
    xdotool mouseup 1
    xdotool click 3
    sleep .15
    xdotool click 2
    sleep .15
    xdotool click 4
    sleep .15
    xdotool click 5
    xdotool keydown ctrl click 1 keyup ctrl
    xdotool keydown shift click 4 keyup shift
    xdotool keydown ctrl click 4
    xdotool mousemove --window "$window" 500 600
    xdotool keyup ctrl
    sleep 1
    touch "$fixture/mouse-stop"
    for attempt in {1..100}; do
        [[ -f "$fixture/mouse-bytes" ]] && break
        sleep .02
    done
    xdotool type --clearmodifiers --delay 1 "python3 '$fixture/selection.py' '$fixture'"
    xdotool key Return
    for attempt in {1..100}; do
        [[ -f "$fixture/selection-ready" ]] && break
        sleep .02
    done
    [[ -f "$fixture/selection-ready" ]]
    sleep .5
    xdotool keydown shift
    xdotool mousemove --window "$window" 68 535 mousedown 1
    xdotool mousemove --window "$window" 100 535 mouseup 1
    xdotool keyup shift
    xdotool key --clearmodifiers ctrl+shift+c
    timeout 3 xclip -selection clipboard -o > "$fixture/copied-line"
    xdotool keydown shift
    xdotool mousemove --window "$window" 110 554 mousedown 1
    xdotool mousemove --window "$window" 68 535 mouseup 1
    xdotool keyup shift
    xdotool key --clearmodifiers ctrl+shift+c
    timeout 3 xclip -selection clipboard -o > "$fixture/copied-multiline"
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
cat > "$fixture/mouse.py" <<'MOUSE'
import os, pathlib, select, sys, termios, time, tty
root = pathlib.Path(sys.argv[1])
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
data = bytearray()
try:
    tty.setraw(fd)
    sys.stdout.write('\x1b[?1006h\x1b[?1003h')
    sys.stdout.flush()
    (root / 'mouse-ready').touch()
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and not (root / 'mouse-stop').exists():
        if select.select([fd], [], [], .05)[0]:
            data.extend(os.read(fd, 4096))
finally:
    sys.stdout.write('\x1b[?1003l\x1b[?1006l')
    sys.stdout.flush()
    termios.tcsetattr(fd, termios.TCSANOW, saved)
    (root / 'mouse-bytes').write_bytes(data)
MOUSE
cat > "$fixture/selection.py" <<'SELECTION'
import pathlib, sys, termios, time, tty
root = pathlib.Path(sys.argv[1])
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    sys.stdout.write('\x1b[?1006h\x1b[?1003h\x1b[2J\x1b[Hhello\r\n日本語')
    sys.stdout.flush()
    (root / 'selection-ready').touch()
    time.sleep(20)
finally:
    termios.tcsetattr(fd, termios.TCSANOW, saved)
SELECTION
python3 "$root_dir/scripts/build.py" >/dev/null
xvfb-run -a timeout 40 "$0" --drive "$fixture"
python3 - "$fixture" <<'CHECK'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
state = json.loads((root / 'capture/app-state.json').read_text())
assert (root / 'paste-ok').read_text() == 'pasted', 'clipboard command was not executed by the PTY'
mouse = (root / 'mouse-bytes').read_bytes()
reports = re.findall(rb'\x1b\[<(\d+);(\d+);(\d+)([Mm])', mouse)
assert reports, mouse
buttons = {int(report[0]) for report in reports}
assert {0, 1, 2, 16, 32, 35, 51, 64, 65, 80} <= buttons, (buttons, mouse)
assert 68 not in buttons, ('Shift-wheel should use local scrollback', mouse)
assert any(report[0] == b'0' and report[3] == b'm' for report in reports), mouse
assert all(1 <= int(x) <= state['terminalColumns'] and 1 <= int(y) <= state['terminalRows']
           for _, x, y, _ in reports), (reports, state)
assert (root / 'copied-line').read_text() == 'hello', repr((root / 'copied-line').read_text())
assert (root / 'copied-multiline').read_text() == 'hello\n日本語', repr((root / 'copied-multiline').read_text())
from PIL import Image
image = Image.open(root / 'capture/frame.png').convert('RGB')
selected = image.getpixel((68, 531))
plain = image.getpixel((200, 573))
assert sum(abs(a - b) for a, b in zip(selected, plain)) > 100, (selected, plain)
assert state['terminal'] == 'running', state
assert 95 <= state['terminalColumns'] <= 105, state
assert 5 <= state['terminalRows'] <= 8, state
assert not state['errors'], state
tree = (root / 'capture/ui-tree.txt').read_text()
assert re.search(r'type=button.*label="Open Folder"', tree), tree
assert tree.count('type=canvas z=1') >= state['terminalRows'], state
assert (root / 'capture/frame.png').stat().st_size > 1000
events = (root / 'events.jsonl').read_text()
assert 'SurfaceResize' in events and '900,680' in events, events
print('PASS: terminal dock, row canvases, live PTY resize, clipboard paste, application mouse reports, and Unicode selection/copy')
CHECK
