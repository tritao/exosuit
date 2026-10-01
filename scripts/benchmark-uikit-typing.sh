#!/usr/bin/env bash
# Real X11 keyboard input. Measures host input-request to completed frame, not OS/display latency.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
if [[ ${1:-} == --drive ]]; then
    fixture=$2
    export PRAGTICAL_PORTABLE="$fixture/state"
    export LD_LIBRARY_PATH="$haxeon_root/out:$haxeon_root/.tools/hashlink:$root_dir/graphical/build/host/native/pragtical_hx:$root_dir/graphical/build/host/native/exosuit-ui-native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    "$haxeon_root/.tools/hashlink/hl" "$root_dir/graphical/build/host/main.hl" \
        --capture-dir="$fixture/capture" --capture-seconds=15 --record-path="$fixture/events.jsonl" "$fixture/input.txt" > "$fixture/app.log" 2>&1 &
    app=$!
    trap 'kill "$app" 2>/dev/null || true' EXIT
    window=$(timeout 90 xdotool search --sync --onlyvisible --name '^exosuit$' | head -1)
    for attempt in {1..900}; do
        if rg -q 'exosuit: window ready' "$fixture/app.log"; then break; fi
        kill -0 "$app"
        sleep .1
    done
    rg -q 'exosuit: window ready' "$fixture/app.log"
    xdotool windowfocus --sync "$window"
    xdotool mousemove --window "$window" 450 132 click 1
    sleep .5
    python3 -c 'import time,sys; open(sys.argv[1],"w").write(str(time.time()))' "$fixture/start.txt"
    for _ in {1..30}; do
        xdotool key --clearmodifiers --delay 120 a BackSpace
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
import json, math, pathlib, platform, sys
root = pathlib.Path(sys.argv[1])
start, end = float((root / "start.txt").read_text()), float((root / "end.txt").read_text())
frames = [json.loads(line) for line in (root / "capture/frame-timeline.jsonl").read_text().splitlines()]
samples = [1000 * (frame["requestAgeSeconds"] + frame["frameSeconds"]) for frame in frames
           if start <= frame["startedAtSeconds"] <= end + .25
           and frame["requestAgeSeconds"] is not None
           and frame["requestReason"] == "event:TextInput"]
if len(samples) < 20: raise SystemExit(f"insufficient actual text-input frames: {len(samples)}")
samples.sort()
p95 = samples[math.ceil(.95 * len(samples)) - 1]
cpu = next((line.split(":", 1)[1].strip() for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines()
            if line.startswith("model name")), platform.processor())
result = dict(fixture=sys.argv[2], cpu=cpu, bytes=(root / "input.txt").stat().st_size,
              metric="committed text input-request to completed frame; excludes OS delivery/display scanout",
              inputFrames=len(samples), p50Ms=samples[len(samples)//2], p95Ms=p95,
              maxMs=samples[-1], budgetMs=50, withinBudget=p95 < 50,
              platform=platform.platform())
(root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
PY
