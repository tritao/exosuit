#!/usr/bin/env bash
# Real X11 keyboard input. Measures delivered text input to completed frame, not OS/display latency.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
if [[ ${1:-} == --drive ]]; then
    fixture=$2
    export PRAGTICAL_PORTABLE="$fixture/state"
    export LD_LIBRARY_PATH="$haxeon_root/out:$haxeon_root/.tools/hashlink:$root_dir/graphical/build/host/native/pragtical_hx:$root_dir/graphical/build/host/native/exosuit-ui-native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    "$haxeon_root/.tools/hashlink/hl" "$root_dir/graphical/build/host/main.hl" \
        --capture-dir="$fixture/capture" --capture-seconds="${TYPING_UI_CAPTURE_SECONDS:-15}" --record-path="$fixture/events.jsonl" "$fixture/input.txt" > "$fixture/app.log" 2>&1 &
    app=$!
    trap 'kill "$app" 2>/dev/null || true' EXIT
    window=$(timeout 90 xdotool search --sync --onlyvisible --name '^exosuit$' | head -1)
    # This marker follows successful rendering; capture timelines are saved at shutdown.
    for attempt in {1..900}; do
        if rg -q 'exosuit: first frame ready' "$fixture/app.log"; then break; fi
        kill -0 "$app"
        sleep .1
    done
    rg -q 'exosuit: first frame ready' "$fixture/app.log"
    xdotool windowfocus --sync "$window"
    xdotool mousemove --window "$window" 450 132 click 1
    sleep .5
    python3 -c 'import time,sys; open(sys.argv[1],"w").write(str(time.time()))' "$fixture/start.txt"
    for _ in {1..30}; do
        xdotool key --clearmodifiers --delay "${TYPING_UI_KEY_DELAY_MS:-120}" a BackSpace
    done
    python3 -c 'import time,sys; open(sys.argv[1],"w").write(str(time.time()))' "$fixture/end.txt"
    wait "$app"
    trap - EXIT
    exit 0
fi
artifacts=${TYPING_UI_ARTIFACTS:-}
fixture=$(mktemp -d)
cleanup() {
    if [[ -n $artifacts ]]; then mkdir -p "$artifacts"; cp -R "$fixture/." "$artifacts/"; fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
size=${TYPING_UI_FIXTURE:-small}
# Keep enough capture time and distinct frames for each measured fixture.
case "$size" in
    small) capture_default=15; delay_default=120 ;;
    10mb) capture_default=45; delay_default=400 ;;
    long-line) capture_default=90; delay_default=1200 ;;
    *) echo "fixture must be small, 10mb or long-line" >&2; exit 1 ;;
esac
export TYPING_UI_CAPTURE_SECONDS=${TYPING_UI_CAPTURE_SECONDS:-$capture_default}
export TYPING_UI_KEY_DELAY_MS=${TYPING_UI_KEY_DELAY_MS:-$delay_default}
python3 - "$fixture/input.txt" "$size" <<'PY'
import pathlib, sys
kind = sys.argv[2]
if kind == "small": text = "ordinary editable text with é🙂\n" * 120
elif kind == "10mb":
    unit = ("ordinary editable text with é🙂 " * 6 + "\n").encode()
    size = 10 * 1024 * 1024
    text = (unit * (size // len(unit)) + b"x" * (size % len(unit))).decode()
elif kind == "long-line": text = "a" * (1024 * 1024)
else: raise SystemExit("fixture must be small, 10mb or long-line")
pathlib.Path(sys.argv[1]).write_text(text)
PY
xvfb-run -a timeout 180 "$0" --drive "$fixture"
python3 - "$fixture" "$size" <<'PY'
import json, math, os, pathlib, platform, sys
root = pathlib.Path(sys.argv[1])
start, end = float((root / "start.txt").read_text()), float((root / "end.txt").read_text())
frames = [json.loads(line) for line in (root / "capture/frame-timeline.jsonl").read_text().splitlines()]
input_frames = [frame for frame in frames
                if start <= frame["startedAtSeconds"] <= end + .25
                and frame["textInputCount"] > 0]
samples = [1000 * (frame["textInputRequestAgeSeconds"] + frame["frameSeconds"]) for frame in input_frames]
if len(samples) < 20: raise SystemExit(f"insufficient actual text-input frames: {len(samples)}")
samples.sort()
p95 = samples[math.ceil(.95 * len(samples)) - 1]
cpu = next((line.split(":", 1)[1].strip() for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines()
            if line.startswith("model name")), platform.processor())
result = dict(fixture=sys.argv[2], cpu=cpu, bytes=(root / "input.txt").stat().st_size,
              metric="delivered text input to completed frame; includes edit dispatch, excludes OS delivery/display scanout",
              inputFrames=len(samples), inputEvents=sum(frame["textInputCount"] for frame in input_frames),
              captureSeconds=int(os.environ.get("TYPING_UI_CAPTURE_SECONDS", "15")),
              keyDelayMs=int(os.environ.get("TYPING_UI_KEY_DELAY_MS", "120")),
              p50Ms=samples[len(samples)//2], p95Ms=p95,
              maxMs=samples[-1], budgetMs=50, withinBudget=p95 < 50,
              platform=platform.platform())
(root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
PY
