"""G12, port against baseline: one live edit (run through measure.ps1 -Live -Drive port_live).

The editor runs from `scripts/run.py --live` of the checkout under test. Once the window is up and idle, the scenario
makes one edit to that checkout's graphical/src/ui/ExosuitApp.hx: the toolbar's Commands button is renamed
"Commands (live)". The live watcher compiles a patch and the running window applies it (a `patch-applied` event in
graphical/build/host/live.hl.watch-events.jsonl; `patch_seconds` in results.json is edit -> that event). The toolbar is
a RetainedView keyed by plain inputs on both sides, so the window is then made 24 px wider and back (the run's own
window, as sweep_panel.py resizes it), which rebuilds it from the patched code: the renamed button must show without a
restart. Whether it showed before the resize is recorded too (`shown_before_resize`). `scripts/live-status.py` of
that checkout must exit 0. The file is restored before the scenario ends, whatever happened (its `git diff` is empty).

  idle       5 s before the edit.
  patch      from the edit to the patch-applied event, then the resize.
  idle-after 5 s after the patch.
One edit only (captures make at most one); the window is closed before the file is restored."""
import ctypes
import ctypes.wintypes
import json
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha"})
SOURCE = os.path.join("graphical", "src", "ui", "ExosuitApp.hx")
BEFORE = 'toolbarButton("Commands", IconName.Search'
AFTER = 'toolbarButton("Commands (live)", IconName.Search'


def events(root):
    """The live watcher's events (graphical/build/host/live.hl.watch-events.jsonl of the checkout), oldest first."""
    try:
        with open(os.path.join(root, "graphical", "build", "host", "live.hl.watch-events.jsonl"), encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip().startswith("{")]
    except (OSError, ValueError):
        return []


def resize_by(gui, dx):
    """Widens the run's own window by `dx` physical pixels, keeping its top left corner."""
    rect = ctypes.wintypes.RECT()
    ctypes.windll.user32.GetWindowRect(gui.window(), ctypes.byref(rect))
    ctypes.windll.user32.SetWindowPos(gui.window(), 0, rect.left, rect.top, rect.right - rect.left + dx, rect.bottom - rect.top, 0x0004 | 0x0010)
    time.sleep(0.8)


def _shows(gui):
    try:
        gui.wait("Commands (live)", lambda s: gui.find(s, "Commands (live)"), 5)
        return True
    except Failure:
        return False


def run(gui):
    root = checkout()
    path = os.path.join(root, SOURCE)
    with open(path, "rb") as f:
        original = f.read()
    if original.count(BEFORE.encode()) != 1:
        raise Failure("%s does not hold exactly one %r" % (path, BEFORE))
    try:
        attached(gui, "Alpha")
        check_traced(gui)
        gui.check("the toolbar has its Commands button", lambda s: gui.find(s, "Commands"), 10)
        time.sleep(2)
        idle(gui, "idle", 5)
        begin(gui, "patch")
        mark(gui, "edit " + SOURCE)
        edited_ms = time.time() * 1000
        with open(path, "wb") as f:
            f.write(original.replace(BEFORE.encode(), AFTER.encode()))
        event = None
        end_at = time.monotonic() + 60
        while event is None and time.monotonic() < end_at:
            event = next((e for e in events(root) if e.get("kind") in ("patch-applied", "patch-rejected", "build-failed", "reload")
                          and (e.get("time") or 0) >= edited_ms), None)
            time.sleep(0.2)
        mark(gui, "patch " + (event or {}).get("kind", "none"))
        seconds = None if event is None else round((event["time"] - edited_ms) / 1000, 2)
        gui.results.append({"check": "the edit is compiled and applied as a live patch", "ok": (event or {}).get("kind") == "patch-applied",
                            "event": event, "patch_seconds": seconds})
        print("live patch: %s after %s s" % ((event or {}).get("kind"), seconds), flush=True)
        time.sleep(1.0)
        shown_before = bool(gui.find(gui.snapshot(), "Commands (live)"))
        mark(gui, "resize")
        resize_by(gui, 24)
        resize_by(gui, -24)
        gui.results.append({"check": "the patched toolbar shows Commands (live) without a restart", "ok": _shows(gui),
                            "shown_before_resize": shown_before})
        gui._save()
        idle(gui, "idle-after", 5)
        end(gui)
        status = subprocess.run([sys.executable, "-I", os.path.join(root, "scripts", "live-status.py")], cwd=root, capture_output=True,
                                text=True, timeout=30, creationflags=0x08000000)
        gui.results.append({"check": "live-status.py reports the patch applied (exit 0)", "ok": status.returncode == 0,
                            "output": (status.stdout + status.stderr)[-1500:]})
        gui._save()
        close_window(gui)
    finally:
        with open(path, "wb") as f:
            f.write(original)
        diff = subprocess.run(["git", "-C", root, "diff", "--quiet", "--", SOURCE], capture_output=True, timeout=30, creationflags=0x08000000)
        gui.results.append({"check": "the edited source is restored (git diff is empty)", "ok": diff.returncode == 0})
        gui._save()


if __name__ == "__main__":
    run_port(run)
