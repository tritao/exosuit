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


def is_attached(state, workspace_id):
    """Whether the window has workspace `workspace_id` open with a catalog from that workspace's service. The snapshot's
    `groups` is a list with or without a catalog, so it says nothing; the Workbench's automation state says it."""
    workbench = state.get("workbench") or {}
    return bool(state["openWorkspace"] == workspace_id and workbench.get("catalog")
                and workbench.get("servedWorkspace") in (None, workspace_id))


def attached(gui, name, timeout=60):
    """Waits until the window is attached to the workspace `name` and holds its catalog; returns its id."""
    def look(s):
        w = ws(s["state"], name)
        return w["id"] if w and is_attached(s["state"], w["id"]) else None
    return gui.wait("window attached to workspace " + name, look, timeout, settle=0.5)


def menu(gui, row_label, item):
    """Right-click a row and click a menu item; one retry when the menu did not open (a tooltip can swallow the first click)."""
    for attempt in range(2):
        gui.click(gui.element(row_label), button="right")
        try:
            target = gui.element(item, role="16", timeout=3)
            break
        except Failure:
            if attempt:
                raise
            gui.chord("esc")
    gui.click(target)


def ensure_group(gui, workspace_id, name="Work"):
    """The id of the group `name` at the root of the open workspace `workspace_id`, made from the workspace row's menu
    (New Group…, the inline editor, Enter) when the catalog has none: a new workspace has no groups."""
    def named(s):
        return next((g["id"] for g in s["state"]["groups"] if g["name"] == name and not g["parent"]), None)
    gui.wait("catalog of the open workspace", lambda s: is_attached(s["state"], workspace_id), 40, settle=0.5)
    found = named(gui.snapshot())
    if found:
        return found
    show_workbench(gui)
    menu(gui, "w:" + workspace_id, "New Group…")
    time.sleep(0.6)
    gui.type_text(name)
    gui.chord("enter")
    return gui.wait("group %s created at the workspace root" % name, named, 20)


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
