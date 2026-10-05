#!/usr/bin/env bash
# Real X11 input, real UIKit widgets and real process/plugin services.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} == --drive ]]; then
	fixture=$2
	phase=$3
	export PRAGTICAL_PORTABLE="$fixture/state"
	haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
	export HAXEON_LSP="$haxeon_root/scripts/haxeon-lsp"
	export LD_LIBRARY_PATH="$haxeon_root/out:$haxeon_root/.tools/hashlink:$root_dir/graphical/build/host/native/pragtical_hx:$root_dir/graphical/build/host/native/exosuit-ui-native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	"$haxeon_root/.tools/hashlink/hl" "$root_dir/graphical/build/host/main.hl" --capture-dir="$fixture/$phase" --capture-seconds=25 \
		--record-path="$fixture/$phase-events.jsonl" --plugin="$fixture/plugin/plugin.conf" \
		"$fixture/project" "$fixture/project/Main.hx" > "$fixture/$phase-app.log" 2>&1 &
	app=$!
	trap 'kill "$app" 2>/dev/null || true' EXIT
	window=$(timeout 30 xdotool search --sync --onlyvisible --name '^exosuit$' | head -1)
	xdotool windowfocus --sync "$window"
	for attempt in {1..300}; do
		grep -qF 'exosuit: window ready' "$fixture/$phase-app.log" && break
		kill -0 "$app"
		sleep .1
	done
	grep -qF 'exosuit: window ready' "$fixture/$phase-app.log"
	sleep .5
	palette() {
		xdotool key --clearmodifiers ctrl+shift+p
		sleep .3
		xdotool key --clearmodifiers ctrl+a
		xdotool type --clearmodifiers --delay 12 "$1"
		xdotool key Return
		sleep .5
	}
	if [[ $phase == problems ]]; then
		# Fresh project has one visible file. Open it through the explorer.
		xdotool mousemove --window "$window" 90 110 click 1
		sleep .5
		xdotool mousemove --window "$window" 500 132 click 1
		xdotool key --clearmodifiers ctrl+a
		xdotool type --clearmodifiers --delay 12 'class Main { static function main():Int { return 42; } }'
		xdotool key --clearmodifiers ctrl+s
		# Reload the source plugin through the palette and its real picker.
		sed -i 's/UIKIT_PLUGIN_V1/UIKIT_PLUGIN_V2/' "$fixture/plugin/Main.hx"
		palette 'Plugins: Reload'
		xdotool key Return
		sleep 3
		# A document event calls the newly compiled plugin body.
		xdotool mousemove --window "$window" 500 132 click 1
		xdotool key --clearmodifiers ctrl+End
		xdotool type --clearmodifiers ' '
		xdotool key --clearmodifiers ctrl+s
	fi
	palette 'Build: Run Task'
	xdotool key Return
	sleep 3
	if [[ $phase == problems ]]; then
		xdotool mousemove --window "$window" 330 625 click 1
	else
		xdotool mousemove --window "$window" 465 625 click 1
	fi
	wait "$app"
	trap - EXIT
	exit 0
fi

fixture=$(mktemp -d)
artifacts=${UIKIT_WORKFLOW_ARTIFACTS:-}
cleanup() {
	if [[ -n $artifacts ]]; then
		mkdir -p "$artifacts"
		cp -R "$fixture/." "$artifacts/"
	fi
	rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/project/.pragtical" "$fixture/plugin"
printf 'class Main { static function main():Int { return 1; } }\n' > "$fixture/project/Main.hx"
cat > "$fixture/project/.pragtical/tasks.conf" <<'TASK'
task=window-check
executable=/bin/sh
cwd=.
argument=-c
argument=printf 'Main.hx:1:1: UIKit window diagnostic\n'; exit 1
TASK
cat > "$fixture/plugin/plugin.conf" <<'MANIFEST'
manifestVersion=1
apiVersion=2
id=window-check
version=1.0.0
entry=Main
source=Main.hx
MANIFEST
cat > "$fixture/plugin/Main.hx" <<'PLUGIN'
import pragtical.Editor;
function main():Int return 0;
function activate():Void {
	Editor.connect("window-check");
	Editor.onDocumentChanged("changed");
}
function deactivate():Void {}
class Probe { public static var fired = false; }
function marker():String return "UIKIT_PLUGIN_V1";
function changed(text:String):Void {
	if (!Probe.fired && marker() == "UIKIT_PLUGIN_V2") {
		Probe.fired = true;
		Editor.replaceSelections(" // UIKIT_PLUGIN_V2");
	}
}
PLUGIN
"$root_dir/scripts/build.sh"
xvfb-run -a "$0" --drive "$fixture" problems
grep -qF 'return 42;' "$fixture/project/Main.hx"
grep -qF '// UIKIT_PLUGIN_V2' "$fixture/project/Main.hx"
grep -F 'UIKit window diagnostic' "$fixture/problems/ui-tree.txt"
# A fresh host restores the saved document; rerun the task and inspect output.
xvfb-run -a "$0" --drive "$fixture" output
grep -F 'Main.hx' "$fixture/output/app-state.json"
grep -F 'Running window-check' "$fixture/output/ui-tree.txt"
grep -F 'Process exited with status 1' "$fixture/output/ui-tree.txt"
grep -F 'UIKit window diagnostic' "$fixture/output/ui-tree.txt"
python3 - "$fixture" <<'CHECK'
import json, pathlib, sys
fixture = pathlib.Path(sys.argv[1])
for phase in ('problems', 'output'):
    state = json.loads((fixture / phase / 'app-state.json').read_text())
    assert state['errors'] == [], state['errors']
    assert state['plugins'] == ['window-check'], state['plugins']
    assert state['documents'] == ['Main.hx'], state['documents']
CHECK
for phase in problems output; do
	[[ -s "$fixture/$phase/frame.png" ]]
	grep -qF 'TextInput(' "$fixture/$phase-events.jsonl"
	if grep -F '"kind":"failure"' "$fixture/$phase-events.jsonl"; then
		echo "UIKit host reported a failure" >&2
		exit 1
	fi
done
echo 'PASS: real UIKit project/open/edit/save/palette/problems/build-output/plugin-reload route'
