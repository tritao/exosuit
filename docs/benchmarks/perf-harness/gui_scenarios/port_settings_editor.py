"""G01, G05 and G15, port against baseline: the editor's caret, typing, scrolling and search, then the Settings tab.

long.txt (3000 lines) opens from the Files tree, which puts the keyboard focus in its editor.

  caret      (G01) Down x12, Right x8, Shift+Down x4, one key every 0.15 s: the status bar follows ("Ln 13, Col 9",
             then "(n selected)"). On the port caret moves still rebuild the root (F3 kept them in the detector).
  typing     (G01) 16 characters one at a time: the tab gets its unsaved mark ("* long.txt").
  scroll     (G05) wheel notches over the text, down then up, and Page Down x4: on the port only the editor pane's
             scope rebuilds (F3).
  search     (G05) Ctrl+F, "line 15", Enter x3, Escape: search marks on the port are pane-scope changes.
  settings   (G15) Ctrl+, opens the Settings tab; Ctrl+W closes it.
Each stage is followed by checks that read the window; the stages themselves read nothing."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403


def prepare(out, root, env, exohost):
    with open(os.path.join(out, "fixture", "alpha", "long.txt"), "w") as f:
        for index in range(1, 3001):
            f.write("line %d of a long file for scrolling\n" % index)


FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha"})
CARET = r"^Ln \d+, Col \d+"


def text_point(gui):
    """A point over the text: below the long.txt tab, in the middle of the editor's width."""
    snap = gui.snapshot()
    tab = next(e for e in gui.find(snap, pattern=r"long\.txt$") if e["role"] == "18" or (e["role"] != "4" and e["y"] < 120))
    return tab["x"] + 200, tab["y"] + tab["h"] + 200


def run(gui):
    attached(gui, "Alpha")
    open_file(gui, "long.txt")
    gui.wait("long.txt in a tab", lambda s: "long.txt" in tabs(s["state"]), 15)
    check_traced(gui)
    gui.check("the status bar shows the caret", lambda s: label_of(s, CARET), 8)
    time.sleep(1)

    begin(gui, "caret")
    for _ in range(12):
        key(gui, "down", 0.15)
    for _ in range(8):
        key(gui, "right", 0.15)
    for _ in range(4):
        key(gui, "shift+down", 0.15)
    time.sleep(0.5)
    begin(gui, "after-caret")
    gui.check("the caret moved: the status bar reads Ln 17, Col 9 with a selection",
              lambda s: (label_of(s, CARET) or "").startswith("Ln 17, Col 9") and "selected" in (label_of(s, CARET) or ""), 4,
              detail=lambda s: label_of(s, CARET))
    key(gui, "right", 0.3)  # drop the selection before typing

    begin(gui, "typing")
    type_keys(gui, "port typing test", 0.12)
    time.sleep(0.5)
    begin(gui, "after-typing")
    gui.check("the tab shows the unsaved mark", lambda s: gui.find(s, pattern=r"^\* long\.txt$|^\*long\.txt$|long\.txt \*$|● long\.txt"), 4,
              detail=lambda s: [e["label"] for e in s["elements"] if "long.txt" in e["label"]])
    x, y = text_point(gui)

    begin(gui, "scroll")
    for _ in range(6):
        wheel(gui, x, y, -3)
        time.sleep(0.15)
    for _ in range(6):
        wheel(gui, x, y, 3)
        time.sleep(0.15)
    for _ in range(4):
        key(gui, "pagedown", 0.2)
    idle(gui, "idle-after-scroll", 3)

    begin(gui, "search")
    key(gui, "ctrl+f", 0.4)
    type_keys(gui, "line 15", 0.1)
    for _ in range(3):
        key(gui, "enter", 0.3)
    key(gui, "escape", 0.4)
    idle(gui, "idle-after-search", 3)

    begin(gui, "settings")
    key(gui, "ctrl+,", 1.0)
    begin(gui, "after-settings")
    gui.check("Ctrl+, opens the Settings tab", lambda s: any(t["kind"] == "settings" for p in s["state"]["panes"] for t in p["tabs"]), 5,
              detail=lambda s: [(t["kind"], t["title"]) for p in s["state"]["panes"] for t in p["tabs"]])
    gui.shot("settings")
    key(gui, "ctrl+w", 0.8)
    gui.check("Ctrl+W closes it", lambda s: not any(t["kind"] == "settings" for p in s["state"]["panes"] for t in p["tabs"]), 5)
    end(gui)
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
