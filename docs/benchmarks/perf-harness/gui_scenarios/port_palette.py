"""G06, port against baseline: the command palette, and enablement after a command runs (T9, T12).

  palette    Ctrl+Shift+P, "toggle" one key at a time, Down x4, Up x2, Escape: on the port the field patches itself
             and the list rebuilds without a root build.
  save       a1.txt gets an edit (the tab shows its unsaved mark), then Ctrl+S: the mark goes. A command run used to
             refresh the window as a side effect (commands.revision); the port asks for the frame itself (D2).
  run        the palette runs "Toggle Left Sidebar" by name: the side bar goes, and comes back the same way."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha"})
UNSAVED = r"^\* a1\.txt$|^\*a1\.txt$|a1\.txt \*$|● a1\.txt"


def left_side(s):
    """The labels in the window's left quarter below the title bar: the activity bar and the side bar."""
    width = s["viewport"]["width"]
    return sorted(set(e["label"] for e in s["elements"] if e["x"] + e["w"] / 2 < width / 4 and e["y"] > 40))


def run(gui):
    attached(gui, "Alpha")
    open_file(gui, "a1.txt")
    gui.wait("a1.txt in a tab", lambda s: "a1.txt" in tabs(s["state"]), 15)
    check_traced(gui)
    time.sleep(1)

    begin(gui, "palette")
    key(gui, "ctrl+shift+p", 0.4)
    type_keys(gui, "toggle", 0.15)
    for _ in range(4):
        key(gui, "down", 0.2)
    for _ in range(2):
        key(gui, "up", 0.2)
    begin(gui, "after-palette")
    gui.check("the palette is open with the typed filter", lambda s: s["state"]["commandViewActive"], 3)
    gui.shot("palette")
    key(gui, "escape", 0.4)
    gui.check("Escape closes the palette", lambda s: not s["state"]["commandViewActive"], 3)

    begin(gui, "save")
    key(gui, "end", 0.1)
    type_keys(gui, " edited", 0.12)
    time.sleep(0.3)
    gui.check("the edit marks the tab unsaved", lambda s: gui.find(s, pattern=UNSAVED), 4,
              detail=lambda s: [e["label"] for e in s["elements"] if "a1.txt" in e["label"]])
    key(gui, "ctrl+s", 0.5)
    begin(gui, "after-save")
    gui.check("Ctrl+S saves: the unsaved mark goes", lambda s: not gui.find(s, pattern=UNSAVED) and gui.find(s, pattern=r"a1\.txt"), 4,
              detail=lambda s: [e["label"] for e in s["elements"] if "a1.txt" in e["label"]])

    begin(gui, "run")
    before = left_side(gui.snapshot())
    for attempt in range(2):
        key(gui, "ctrl+shift+p", 0.4)
        gui.wait("palette open", lambda s: s["state"]["commandViewActive"], 4)
        type_keys(gui, "Toggle Left Sidebar", 0.05)
        time.sleep(0.4)
        key(gui, "enter", 0.6)
        if attempt == 0:
            gui.check("the palette's Toggle Left Sidebar changes the side bar", lambda s: not s["state"]["commandViewActive"]
                      and left_side(s) != before, 4, detail=lambda s: left_side(s))
        else:
            gui.check("running it again brings the side bar back as it was", lambda s: not s["state"]["commandViewActive"]
                      and left_side(s) == before, 4, detail=lambda s: (before, left_side(s)))
    end(gui)
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
