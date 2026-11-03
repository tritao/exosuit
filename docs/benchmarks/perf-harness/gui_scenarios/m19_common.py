"""Helpers the M19 scenarios share: names to ids, tab lists, and the usual UI paths (all through real input)."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from gui_driver import Failure, main  # noqa: E402,F401


def ws(state, name):
    """The machine workspace called `name`, or None."""
    return next((w for w in state["machineWorkspaces"] if w["name"] == name), None)


def tabs(state):
    """Titles of the open tabs, file names only for documents, in order (every pane)."""
    return [t["title"].replace("\\", "/").split("/")[-1] for p in state["panes"] for t in p["tabs"]]


def context_tabs(state, workspace_id):
    """The persisted tab lines (host session lines) of the context of a workspace's root group: documents' file names."""
    names = []
    for line in state["sessionLines"]:
        parts = line.split("\t")
        if parts[0] == "X" and len(parts) > 2 and workspace_id in parts[1]:
            names += [p.replace("\\", "/").split("/")[-1] for p in parts[2:] if "/" in p or "\\" in p]
    return names


def attached(gui, name, timeout=60):
    """Waits until the window is attached to the workspace `name`; returns its id."""
    def look(s):
        w = ws(s["state"], name)
        return w["id"] if w and s["state"]["openWorkspace"] == w["id"] and s["state"]["groups"] is not None else None
    return gui.wait("window attached to workspace " + name, look, timeout, settle=0.5)


def row(gui, key_prefix, index=0, timeout=8.0):
    return gui.element(pattern="^" + key_prefix, index=index, timeout=timeout)


def workspace_row(gui, wid):
    return gui.element("w:" + wid)


def open_file(gui, name):
    """Double click a file in whichever Files tree is visible (the right panel, or the side bar's Files)."""
    gui.click(gui.element(name, role="4", timeout=20), count=2)


def quick_switch(gui, text):
    """Ctrl+Shift+A with focus off the text editor, type `text`, Enter. Returns after the quick pick closed."""
    gui.chord("ctrl+shift+a")
    gui.wait("quick switch open", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text(text)
    time.sleep(0.4)
    gui.chord("enter")
    gui.wait("quick switch closed", lambda s: not s["state"]["commandViewActive"], 5)


def show_workbench(gui):
    """Makes the Workbench tree visible (a new context may start without a side bar), by the activity bar button."""
    def visible():
        try:
            gui.wait("tree", lambda s: gui.find(s, "n:new-workspace"), 3)
            return True
        except Failure:
            return False
    if gui.find(gui.snapshot(), "n:new-workspace"):
        return
    gui.click(gui.element("Workbench", role="1"))
    if visible():
        return
    gui.click(gui.element("Toggle Left Sidebar", role="1"))  # a context that starts with the side bar hidden
    if visible():
        return
    gui.click(gui.element("Workbench", role="1"))
    gui.wait("Workbench tree visible", lambda s: gui.find(s, "n:new-workspace"), 5)


def reveal(gui, parent_id, child_id):
    """Makes the row of group `child_id` visible: selects its parent group's row and expands it with Right."""
    if gui.find(gui.snapshot(), "g:" + child_id):
        return
    gui.click(gui.element("g:" + parent_id))
    gui.chord("right")
    gui.wait("row of group " + child_id, lambda s: gui.find(s, "g:" + child_id), 5)
