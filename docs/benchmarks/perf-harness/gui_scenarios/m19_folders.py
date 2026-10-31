"""M19 folders: attach a second folder to a workspace, see Files and Search show both, then detach it.

Real input: right-click the workspace row, click "Attach Folder...", (the native folder dialog is replaced by the path
the driver leaves in the automation folder), then the Files and Search tabs, then "Detach Folder..." and the quick pick."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha", "beta"], "folders": ["extra"], "open": None, "appArgs": ["--open-workbench"]}
ELLIPSIS = "…"


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


def open_by_double_click(gui, wid, name):
    """A double click opens the workspace, idle or running (an idle one is started and waited for)."""
    gui.click(gui.element("w:" + wid), count=2)
    attached(gui, name)


def attach_extra(gui, wid, extra, name):
    show_workbench(gui)
    with open(os.path.join(gui.dir, "pick-folder.txt"), "w") as f:
        f.write(extra)
    menu(gui, "w:" + wid, "Attach Folder" + ELLIPSIS)
    return gui.check("%s now has two folders" % name, lambda s: len(ws(s["state"], name)["folders"]) == 2, 15,
                     detail=lambda s: ws(s["state"], name)["folders"])


def healthy(gui, label):
    time.sleep(3)  # a failed (re)start of the manager is reported a moment after the switch
    gui.check(label + ": the window is not 'Workspace unavailable'", lambda s: not s["state"]["workspaceError"], 8,
              detail=lambda s: (s["state"]["workspaceError"], s["state"]["notifications"]))


def run(gui):
    """Attach to a workspace that is not open, open it, check Files and Search, detach while it is open."""
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    beta = ws(gui.state(), "Beta")["id"]
    extra = os.path.join(os.path.dirname(gui.out), "fixture", "extra")
    norm = lambda p: p.replace("\\", "/").rstrip("/").lower()

    gui.step("attach 'extra' to Beta, which is not open")
    attach_extra(gui, beta, extra, "Beta")
    gui.step("open Beta; Files and Search show both folders")
    open_by_double_click(gui, beta, "Beta")
    healthy(gui, "after opening Beta")
    show_workbench(gui)
    gui.click(gui.element("w:" + beta))  # the workspace row selected: the right panel works in the whole workspace
    gui.check("Files roots list both folders", lambda s: any(norm(r) == norm(extra) for r in s["state"]["filesRoots"])
              and len(s["state"]["filesRoots"]) >= 2, 10, detail=lambda s: s["state"]["filesRoots"])
    gui.check("Files shows a file of each folder", lambda s: gui.find(s, "b1.txt", role="4") and gui.find(s, "e1.txt", role="4"), 10,
              detail=lambda s: [e["label"] for e in s["elements"] if e["role"] == "4" and e["x"] > 900])
    gui.shot("files-two-folders")

    gui.step("Search finds files in both")
    gui.click(gui.element("Search", role="18"))
    time.sleep(0.5)
    boxes = [e for e in gui.snapshot()["elements"] if e["role"] == "5" and e["x"] > 900]
    if boxes:
        gui.click(boxes[0])
    gui.type_text("file")
    gui.chord("enter")
    gui.check("search results name files from both folders", lambda s: gui.find(s, pattern=r"b\d\.txt") and gui.find(s, pattern=r"e\d\.txt"), 15,
              detail=lambda s: [e["label"][:60] for e in s["elements"] if e["x"] > 900 and e["y"] > 90][:30])
    gui.shot("search-two-folders")
    snapshot_dump(gui, "search")

    gui.step("detach 'extra' from the open Beta")
    show_workbench(gui)
    menu(gui, "w:" + beta, "Detach Folder" + ELLIPSIS)
    gui.wait("detach list", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text("extra")
    time.sleep(0.4)
    gui.chord("enter")
    gui.check("Beta is back to one folder", lambda s: len(ws(s["state"], "Beta")["folders"]) == 1, 15,
              detail=lambda s: ws(s["state"], "Beta")["folders"])
    healthy(gui, "after detaching")
    gui.check("Files roots no longer list 'extra'", lambda s: not any(norm(r) == norm(extra) for r in s["state"]["filesRoots"]), 10,
              detail=lambda s: s["state"]["filesRoots"])
    gui.shot("after-detach")


def snapshot_dump(gui, name):
    import json
    with open(os.path.join(gui.out, name + ".json"), "w") as f:
        json.dump(gui.snapshot(), f, indent=1)


if __name__ == "__main__":
    main(run)
