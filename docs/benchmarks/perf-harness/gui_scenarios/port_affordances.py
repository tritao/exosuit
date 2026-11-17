"""G04, port against baseline: what shows only on hover, focus or a right click, and screenshots of it (U9's visual
parity: a tooltip, a context menu, the side bar's header actions).

  header     the pointer moves onto the side bar's Files tree: its header actions (New File, New Folder, Refresh,
             Collapse All) show; it moves to the editor: they go (T19: hover alone causes no root build upstream, so
             the port asks for one when their visibility flips).
  focus      a click on a tree row: the actions show while focus is inside the side bar, with the pointer away.
  tooltip    the pointer rests on the toolbar's Commands button: its tooltip shows (screenshot).
  menu       a right click on a2.txt opens its context menu (menu items, role 16; screenshot); Escape closes it.
Screenshots: header.png, tooltip.png, menu.png in the result folder, for comparing the two sides by eye."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha"})
ACTIONS = ("New File", "New Folder", "Refresh", "Collapse All")


def actions_shown(s):
    return any(gui_label(s, name) for name in ACTIONS)


def gui_label(s, label):
    return [e for e in s["elements"] if e["label"] == label]


def run(gui):
    attached(gui, "Alpha")
    check_traced(gui)
    files = [e for e in gui.find(gui.snapshot(), "Files") if e["role"] != "18"]
    if files and not gui.find(gui.snapshot(), "a2.txt", role="4"):
        gui.click(files[0])
    gui.element("a2.txt", role="4", timeout=15)
    open_file(gui, "a1.txt")
    gui.wait("a1.txt in a tab", lambda s: "a1.txt" in tabs(s["state"]), 15)
    tab = next(e for e in gui.find(gui.snapshot(), pattern=r"a1\.txt$") if e["role"] == "18" or (e["role"] != "4" and e["y"] < 120))
    away = {"x": tab["x"] + 200, "y": tab["y"] + tab["h"] + 200}
    time.sleep(1)

    begin(gui, "header")
    mark(gui, "pointer away")
    gui.call("exosuit.ui.hover", away)
    gui.check("away from the side bar its header actions are hidden", lambda s: not actions_shown(s), 3,
              detail=lambda s: [e["label"] for e in s["elements"] if e["label"] in ACTIONS])
    hover(gui, gui.element("a2.txt", role="4"))
    gui.check("hovering the Files tree shows its header actions", actions_shown, 3)
    gui.shot("header")
    mark(gui, "pointer away")
    gui.call("exosuit.ui.hover", away)
    gui.check("leaving it hides them", lambda s: not actions_shown(s), 3)

    begin(gui, "focus")
    click(gui, gui.element("a2.txt", role="4"))
    mark(gui, "pointer away")
    gui.call("exosuit.ui.hover", away)
    gui.check("with focus in the tree and the pointer away the actions stay", actions_shown, 3,
              detail=lambda s: s.get("focus"))
    key(gui, "escape", 0.2)

    begin(gui, "tooltip")
    hover(gui, gui.element("Commands"))
    time.sleep(1.8)
    gui.shot("tooltip")
    mark(gui, "pointer away")
    gui.call("exosuit.ui.hover", away)

    begin(gui, "menu")
    click(gui, gui.element("a2.txt", role="4"), button="right")
    gui.check("a right click on a2.txt opens its context menu", lambda s: gui.find(s, role="16"), 4)
    gui.shot("menu")
    key(gui, "escape", 0.4)
    gui.check("Escape closes it", lambda s: not gui.find(s, role="16"), 3)
    idle(gui, "idle", 3)
    end(gui)
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
