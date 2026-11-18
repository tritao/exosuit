"""G07, port against baseline: the title bar's frame-rate reading (2bf957d9) follows what the window renders.

The reading is "<n> fps" in the title caption, taken once a second. Idle, the window renders only the frame that shows
the new reading, so it reads about 1 fps; the port keeps that once-a-second host frame even when the text does not
change (T20). While the editor scrolls continuously the reading goes up, and back down once it stops.

Stages: `idle` (6 s, nothing sent or read), `busy` (Page Down / Page Up in a long file for 4 s), `idle-after` (6 s).
The reading is read before and after the stages, never inside the idle ones."""
import os
import re
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

FPS = r"(^|\s)(\d+) fps($|\s)"


def prepare(out, root, env, exohost):
    with open(os.path.join(out, "fixture", "alpha", "long.txt"), "w") as f:
        for index in range(1, 3001):
            f.write("line %d of a long file for scrolling\n" % index)


FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha"})


def reading(snap):
    label = label_of(snap, FPS)
    if label is None:
        return None
    return int(re.search(FPS, label).group(2))


def run(gui):
    attached(gui, "Alpha")
    open_file(gui, "long.txt")
    gui.wait("long.txt in a tab", lambda s: "long.txt" in tabs(s["state"]), 15)
    check_traced(gui)
    gui.check("the title shows a frame rate", lambda s: reading(s) is not None, 8,
              detail=lambda s: [e["label"] for e in s["elements"] if e["y"] < 40])
    time.sleep(3)
    idle(gui, "idle", 6)
    gui.check("an idle window reads 1 or 2 fps", lambda s: (reading(s) or 0) in (1, 2), 3,
              detail=lambda s: label_of(s, FPS))
    begin(gui, "busy")
    stop = time.monotonic() + 4
    down = True
    while time.monotonic() < stop:
        key(gui, "pagedown" if down else "pageup", 0.05)
        down = not down
    seen = []
    gui.check("while the editor scrolls the reading goes above 2 fps", lambda s: seen.append(reading(s)) or (reading(s) or 0) > 2, 2,
              detail=lambda s: seen)
    idle(gui, "idle-after", 6)
    end(gui)
    gui.check("once it stops the reading falls back to 1 or 2 fps", lambda s: (reading(s) or 0) in (1, 2), 4,
              detail=lambda s: label_of(s, FPS))
    check_rate(gui, "idle", 0.3, 3, "idle: about one frame a second")
    check_rate(gui, "busy", 3, 1000, "busy: frames follow the input")
    check_rate(gui, "idle-after", 0.3, 3, "idle again: about one frame a second")
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
