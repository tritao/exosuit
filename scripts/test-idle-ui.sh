#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/project" "$fixture/state"
printf 'class Main { static function main():Int { return 42; } }\n' > "$fixture/project/Main.hx"
python3 - "$fixture" "$root_dir" <<'PY'
import json, sys
from pathlib import Path
fixture, root = map(Path, sys.argv[1:])
command = ["python3", str(root / "tests/fake_lsp.py"), "--idle-diagnostic", "--events", str(fixture / "events.jsonl")]
(fixture / "state/settings.json").write_text(json.dumps({"version": 1, "values": {
    "languages/haxeon/command": json.dumps(command)}, "state": {}}))
PY
PRAGTICAL_PORTABLE="$fixture/state" xvfb-run -a "$haxeon_root/scripts/haxeon" run \
    --project "$root_dir/graphical/haxeon.json" -- \
    "$fixture/project" "$fixture/project/Main.hx" \
    "--capture-dir=$fixture/capture" --capture-seconds=6
python3 - "$fixture" <<'PY'
import json, sys
from pathlib import Path
fixture = Path(sys.argv[1])
metrics = json.loads((fixture / "capture/frame-metrics.json").read_text())
events = [json.loads(line) for line in (fixture / "events.jsonl").read_text().splitlines()]
assert any(event["method"] == "initialized" for event in events), "LSP did not initialize"
assert "Idle background diagnostic" in (fixture / "capture/ui-tree.txt").read_text(), "Idle LSP response did not reach the UI"
assert metrics["renderedFrames"] <= 20, f"Idle LSP caused continuous redraws: {metrics['renderedFrames']} frames"
print(f"PASS: idle LSP publishes delayed diagnostics with {metrics['renderedFrames']} frames in 6 seconds")
PY
# Restored editor focus drives real caret deadlines, without forcing frames.
PRAGTICAL_PORTABLE="$fixture/state" xvfb-run -a "$haxeon_root/scripts/haxeon" run \
    --project "$root_dir/graphical/haxeon.json" -- \
    "$fixture/project" "$fixture/project/Main.hx" \
    "--capture-dir=$fixture/caret-capture" --capture-seconds=6
python3 - "$fixture" <<'PY'
import json, sys
from pathlib import Path
fixture = Path(sys.argv[1])
frames = [json.loads(line) for line in (fixture / "caret-capture/frame-timeline.jsonl").read_text().splitlines()]
caret = [frame for frame in frames if frame["repaintOnly"]]
assert len(caret) >= 3, "Restored editor did not schedule caret-only repaints"
assert all(frame["nativeLayoutSeconds"] == 0 and frame["treeAndStyleSeconds"] == 0 for frame in caret), "Caret repaint rebuilt or laid out the UI"
assert "Idle background diagnostic" in (fixture / "caret-capture/ui-tree.txt").read_text(), "Background diagnostics were lost during caret repaints"
mean = sum(frame["allocatedBytes"] for frame in caret) / len(caret)
print(f"PASS: {len(caret)} caret-only repaints skip tree/layout work, averaging {mean:.0f} render bytes")
PY
