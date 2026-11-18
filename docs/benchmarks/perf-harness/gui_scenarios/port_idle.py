"""G02, port against baseline: an idle window, then pointer hover, then idle again. Frames and allocations per frame.

Alpha opens with a1.txt in a tab. `idle` (10 s) sends and reads nothing: the window should render about one frame a
second (the frame-rate reading's own frame, T20) and, on the port, allocate nothing in submit (the string key is gone,
D1). `hover` moves the pointer over the activity bar, the toolbar, the tab and the Files rows, one element every 0.3 s:
upstream patches hover visuals without a root build. `idle-after` (5 s) checks the window settles again.

    measure.ps1 -Name <side>-g02 -Drive port_idle [-Root <baseline>]       frames: port_frames.py runs/<side>-g02/result
    PORT_MEASURE=alloc ... -Name <side>-g02-alloc                           census: port_frames.py prints it"""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha"})
HOVER_LABELS = ["Workbench", "Files", "Toggle Left Sidebar", "Toggle Bottom Panel", "Layout", "a1.txt", "a2.txt", "a3.txt"]


def targets(gui):
    snap = gui.snapshot()
    found = []
    for label in HOVER_LABELS:
        hits = [e for e in gui.find(snap, label) if gui.on_screen(snap, e)]
        found.extend(hits[:1])
    return found


def run(gui):
    attached(gui, "Alpha")
    open_file(gui, "a1.txt")
    gui.wait("a1.txt in a tab", lambda s: "a1.txt" in tabs(s["state"]), 15)
    check_traced(gui)
    items = targets(gui)
    gui.check("hover targets on screen", lambda s: len(items) >= 4, 1)
    time.sleep(2)
    idle(gui, "idle", 10)
    begin(gui, "hover")
    for _ in range(2):
        for element in items:
            hover(gui, element)
            time.sleep(0.3)
    idle(gui, "idle-after", 5)
    end(gui)
    check_rate(gui, "idle", 0.3, 3, "an idle window renders about one frame a second")
    check_rate(gui, "idle-after", 0.3, 3, "after hovering the window is idle again")
    gui.shot("idle")
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
