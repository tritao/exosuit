#!/usr/bin/env bash
# session_linux.sh NAME [--seconds S] [--live] [--human]: runs the editor in a private Xvfb display on its own sources, drives
# it with X11 input (driver_x11.py), records a profiler capture and prints the latency tables (analyze_capture.py). Output
# goes to runs/NAME/. Linux. The editor must be built (python3 scripts/build.py).
#
# With --human the editor opens on the display in $DISPLAY (your GPU, compositor and devices) and a person drives it for S
# seconds: move the mouse over it with pauses between, click in the text, use the arrow keys. Nothing is injected.
#
# The capture is of the NativeKit trace sink, which is always on while a session records, and a 1 kHz sampling profile (the rate `haxeon run --profile` uses, so live and normal runs match),
# so the recording itself adds little. The machine's load shows in the numbers: run on a quiet machine, and compare runs
# made close together.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
haxeon=${HAXEON_ROOT:-"$root/haxeon"}
name=$1; shift
seconds=60
live=0
human=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--seconds) seconds=$2; shift 2 ;;
		--live) live=1; shift ;;
		--human) human=1; shift ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done
out="$here/runs/$name"
rm -rf "$out"
mkdir -p "$out/workspace" "$out/state"
[[ -f "$root/graphical/build/host/main.hl" ]] || { echo "build exosuit first: python3 scripts/build.py" >&2; exit 1; }
if [[ $human == 1 ]]; then
	[[ -n "${DISPLAY:-}" ]] || { echo "--human needs a display (DISPLAY)" >&2; exit 1; }
else
	command -v xvfb-run >/dev/null || { echo "needs xvfb-run" >&2; exit 1; }
fi

# The workspace: the editor's own sources.
cp "$root/graphical/src/ui/ExosuitApp.hx" "$root/src/editor/Document.hx" "$out/workspace/"

title="latency session $name $$"
inner="$out/inner.sh"
cat > "$inner" <<INNER
#!/usr/bin/env bash
set -u
native=$root/graphical/build/host/native
export PRAGTICAL_PORTABLE=$out/state XDG_CONFIG_HOME=$out/state/config XDG_DATA_HOME=$out/state/data
export XDG_STATE_HOME=$out/state/state XDG_CACHE_HOME=$out/state/cache
export LD_LIBRARY_PATH=$haxeon/out:$haxeon/.tools/hashlink:\$native/pluginhost:\$native/exosuit-ui-native:\$native/textmateregex:\$native/terminalkit
port=\$((20000 + RANDOM % 20000))
if [[ $live == 1 ]]; then
	cd $root
	PATH=$haxeon/out:$haxeon/.tools/hashlink:\$PATH setsid python3 scripts/run.py --live --profile=sampling --profile-output=$out/capture \\
		--title="$title" $out/workspace $out/workspace/Document.hx > $out/app.log 2>&1 &
else
	$haxeon/.tools/hashlink/hl --diagnostics \$port --diagnostics-wait $root/graphical/build/host/main.hl --title="$title" \\
		$out/workspace $out/workspace/Document.hx > $out/app.log 2>&1 &
fi
app=\$!
if [[ $live == 0 ]]; then
	$haxeon/.tools/hashlink/hlprof-live --sources sampling --rate 1000 --connect-timeout 60 --output $out/capture.hlpc \$port > $out/recorder.log 2>&1 &
	recorder=\$!
fi
if [[ $human == 1 ]]; then
	echo "editor starting on \$DISPLAY; drive it for $seconds s once its window is up" >&2
	until xdotool search --name "$title" > /dev/null 2>&1; do sleep 0.5; done
	sleep $seconds
else
	python3 $here/driver_x11.py "$title" --seconds $seconds --wait-window 150 > $out/driver.log 2>&1
fi
sleep 2
# A live run is a process group (the watcher, the build and the app): stop all of it, or it would relaunch the app.
if [[ $live == 1 ]]; then kill -TERM -- -\$app 2>/dev/null; pkill -f -- "--title=$title" 2>/dev/null; else kill \$app 2>/dev/null; fi
wait \$app 2>/dev/null
# The recorder finalizes the capture when the app's connection closes: give it a moment, then stop it.
if [[ $live == 0 ]]; then
	timeout 30 tail --pid=\$recorder -f /dev/null 2>/dev/null
	kill \$recorder 2>/dev/null
	wait \$recorder 2>/dev/null
fi
exit 0
INNER
chmod +x "$inner"
if [[ $human == 1 ]]; then
	timeout $((seconds + 400)) "$inner" || true
else
	timeout $((seconds + 400)) xvfb-run -a -s "-screen 0 1600x1000x24" "$inner" || true
fi

capture="$out/capture.hlpc"
[[ $live == 1 ]] && capture=$(ls "$out"/capture/*/profile.hlpc 2>/dev/null | head -n1 || true)
[[ -n "$capture" && -f "$capture" ]] || { echo "no capture was recorded; see $out/app.log and $out/recorder.log" >&2; exit 1; }
"$haxeon/.tools/hashlink/hlprof-live" export --format perfetto --output "$out/trace.json" "$capture" > "$out/export.log" 2>&1
python3 "$here/analyze_capture.py" "$out/trace.json" | tee "$out/summary.txt"
