#!/usr/bin/env bash
# Real X11 keyboard input. Measures delivered text input to completed frame, not OS/display latency.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
if [[ ${1:-} == --drive ]]; then
    fixture=$2
    export PRAGTICAL_PORTABLE="$fixture/state"
    export LD_LIBRARY_PATH="$haxeon_root/out:$haxeon_root/.tools/hashlink:$root_dir/graphical/build/host/native/hostservices:$root_dir/graphical/build/host/native/exosuit-ui-native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    hl_options=()
    if [[ -n ${TYPING_UI_PROFILE_PORT:-} ]]; then
        hl_options+=(--diagnostics "$TYPING_UI_PROFILE_PORT")
    fi
    "$haxeon_root/.tools/hashlink/hl" "${hl_options[@]}" "$root_dir/graphical/build/host/main.hl" \
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
    python3 - "$fixture" "$app" "$root_dir" <<'PY_RUNTIME'
import hashlib, json, pathlib, sys
fixture, process, source = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
expected = (source / "graphical/build/host/native/exosuit-ui-native/libnativekit_ui.so").resolve()
paths = {line.split(maxsplit=5)[-1].strip() for line in pathlib.Path(f"/proc/{process}/maps").read_text().splitlines()
         if "libnativekit_ui.so" in line}
assert str(expected) in paths and len(paths) == 1, f"unexpected loaded UIKit library: {paths}"
digest = hashlib.sha256(expected.read_bytes()).hexdigest()
inputs = json.loads((fixture / "build-inputs.json").read_text())
assert digest == inputs["binaries"]["uikit"]["sha256"], "UIKit binary changed during launch"
(fixture / "loaded-runtime.json").write_text(json.dumps({"uikit": {"path": str(expected), "sha256": digest}}, indent=2) + "\n")
PY_RUNTIME
    xdotool windowfocus --sync "$window"
    xdotool mousemove --window "$window" 450 132 click 1
    sleep .5
    python3 -c 'import time,sys; open(sys.argv[1],"w").write(str(time.time()))' "$fixture/start.txt"
    key_pattern=${TYPING_UI_KEY_PATTERN:-repeat}
    if [[ $key_pattern != repeat && $key_pattern != varied ]]; then
        echo "TYPING_UI_KEY_PATTERN must be repeat or varied" >&2
        exit 1
    fi
    alphabet=abcdefghijklmnopqrstuvwxyz
    for ((index=0; index<30; index++)); do
        key=a
        if [[ $key_pattern == varied ]]; then key=${alphabet:index%26:1}; fi
        xdotool key --clearmodifiers --delay "${TYPING_UI_KEY_DELAY_MS:-120}" "$key" BackSpace
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
# The decoration test builds a separate app; always refresh this measured app.
"$root_dir/scripts/build.sh" > "$fixture/build.log" 2>&1
python3 - "$fixture" "$root_dir" <<'PY_BUILD'
import hashlib, json, pathlib, subprocess, sys
fixture, source = map(pathlib.Path, sys.argv[1:])
def revision(directory):
    return {"head": subprocess.check_output(["git", "-C", str(directory), "rev-parse", "HEAD"], text=True).strip(),
            "dirty": bool(subprocess.check_output(["git", "-C", str(directory), "status", "--porcelain"], text=True))}
def artifact(path):
    path = path.resolve()
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
vendor = source.parent / "uikit/vendor/skribidi"
inputs = {"repositories": {"exosuit": revision(source), "materia": revision(source.parent), "skribidi": revision(vendor)},
          "binaries": {"bytecode": artifact(source / "graphical/build/host/main.hl"),
                       "uikit": artifact(source / "graphical/build/host/native/exosuit-ui-native/libnativekit_ui.so")},
          "layoutSources": {name: artifact(vendor / name) for name in
                            ("src/skb_layout.c", "src/skb_layout_internal.h", "include/skribidi/skb_layout.h")}}
(fixture / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
PY_BUILD
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
def p95_ms(field):
    values = sorted(1000 * frame[field] for frame in input_frames
                    if frame.get(field) is not None)
    return values[math.ceil(.95 * len(values)) - 1] if values else None
cpu = next((line.split(":", 1)[1].strip() for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines()
            if line.startswith("model name")), platform.processor())
result = dict(fixture=sys.argv[2], cpu=cpu, bytes=(root / "input.txt").stat().st_size,
              metric="delivered text input to completed frame; includes edit dispatch, excludes OS delivery/display scanout",
              inputFrames=len(samples), inputEvents=sum(frame["textInputCount"] for frame in input_frames),
              captureSeconds=int(os.environ.get("TYPING_UI_CAPTURE_SECONDS", "15")),
              keyDelayMs=int(os.environ.get("TYPING_UI_KEY_DELAY_MS", "120")),
              keyPattern=os.environ.get("TYPING_UI_KEY_PATTERN", "repeat"),
              p50Ms=samples[len(samples)//2], p95Ms=p95,
              dispatchP95Ms=p95_ms("textInputDispatchSeconds"),
              frameP95Ms=p95_ms("frameSeconds"),
              nativeRenderP95Ms=p95_ms("nativeRenderSeconds"),
              frameGcP95Ms=p95_ms("frameGcSeconds"),
              maxMs=samples[-1], budgetMs=50, withinBudget=p95 < 50,
              platform=platform.platform(),
              build=json.loads((root / "build-inputs.json").read_text()),
              loadedRuntime=json.loads((root / "loaded-runtime.json").read_text()))
(root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
if not result["withinBudget"]:
    raise SystemExit(f"typing p95 {p95:.2f} ms exceeds the {result['budgetMs']} ms budget")
PY
