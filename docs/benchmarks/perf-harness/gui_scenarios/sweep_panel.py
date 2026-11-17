"""Everyday sweep, the right panel and the window's size: a group gets a folder of its own (Change Working Directory…),
and the right panel's Files, Search and Changes tabs follow the selected row (the group's folder, then the workspace's
again); then the window is made narrow and wide again and what must stay reachable is checked at each size.

Real input, except the window's size, which the driver sets on the run's own window (a user drags its border)."""
import ctypes
import ctypes.wintypes
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep_common import *  # noqa: F401,F403
from m19_sessions_drag import by_name

FIXTURE = {"workspaces": ["alpha"], "folders": ["extra"], "open": "alpha", "appArgs": ["--open-workbench"]}
norm = lambda p: p.replace("\\", "/").rstrip("/").lower()


def resize(gui, width, height):
    """Sets the window's outer size in physical pixels, keeping its top left corner."""
    rect = ctypes.wintypes.RECT()
    ctypes.windll.user32.GetWindowRect(gui.window(), ctypes.byref(rect))
    ctypes.windll.user32.SetWindowPos(gui.window(), 0, rect.left, rect.top, int(width), int(height), 0x0004 | 0x0010)  # NOZORDER | NOACTIVATE
    time.sleep(1.0)
    return rect.right - rect.left, rect.bottom - rect.top


def clipped(snap, roles=("1", "18")):
    """Buttons and tabs that reach past the window's right or bottom edge."""
    v = snap["viewport"]
    return [(e["label"][:40], round(e["x"] + e["w"] - v["width"])) for e in snap["elements"]
            if e["role"] in roles and e["x"] < v["width"] and (e["x"] + e["w"] > v["width"] + 1 or e["y"] + e["h"] > v["height"] + 1)]


def run(gui):
    alpha = attached(gui, "Alpha")
    gui.wait("Alpha's catalog", lambda s: s["state"]["workbench"]["catalog"], 40, settle=0.5)
    show_workbench(gui)
    wrow = "w:" + alpha
    extra = os.path.join(os.path.dirname(gui.out), "fixture", "extra")
    box = {}

    def group_with_folder():
        menu(gui, wrow, "New Group")
        time.sleep(0.6)
        gui.type_text("Docs")
        gui.chord("enter")
        gui.check("group Docs made", lambda s: by_name(s["state"], "groups", "Docs"), 20, detail=lambda s: s["state"]["groups"])
        box["docs"] = by_name(gui.state(), "groups", "Docs")["id"]
        menu(gui, open_row(gui, "g", box["docs"]), "Change Working Directory" + ELLIPSIS)
        gui.answer_dialog(paths=[extra])
        gui.check("Docs has the folder 'extra'", lambda s: norm(by_name(s["state"], "groups", "Docs")["cwd"] or "") == norm(extra), 10,
                  detail=lambda s: s["state"]["groups"])
    stage(gui, "a group with a folder of its own", group_with_folder)

    def follows():
        gui.click(gui.element(open_row(gui, "g", box["docs"])))
        gui.check("with Docs selected, Files shows its folder", lambda s: gui.find(s, "e1.txt", role="4") and not gui.find(s, "a1.txt", role="4"), 8,
                  detail=lambda s: (s["state"]["filesRoots"], [e["label"] for e in s["elements"] if e["role"] == "4" and e["label"].endswith(".txt")]))
        dump(gui, "files-docs")
        gui.click(gui.element("Search", role="18"))
        time.sleep(0.5)
        v = gui.snapshot()["viewport"]
        boxes = [e for e in gui.snapshot()["elements"] if e["role"] == "5" and e["x"] > v["width"] * 0.6]
        gui.check("the Search tab has a search box", lambda s: bool(boxes), 1, detail=lambda s: [(e["role"], e["label"]) for e in s["elements"] if e["x"] > v["width"] * 0.6][:30])
        if boxes:
            gui.click(boxes[0])
            gui.type_text("file")
            gui.chord("enter")
            gui.check("Search finds the group folder's files and not the workspace's", lambda s: gui.find(s, pattern=r"e\d\.txt") and not gui.find(s, pattern=r"a\d\.txt"), 15,
                      detail=lambda s: [e["label"][:60] for e in s["elements"] if e["x"] > v["width"] * 0.6 and e["y"] > 90][:30])
        dump(gui, "search-docs")
        gui.click(gui.element("Changes", role="18"))
        time.sleep(1.0)
        dump(gui, "changes-docs")
        gui.click(gui.element("Files", role="18"))
        gui.click(gui.element(wrow))
        # The workspace's scope holds its own folder first, then its groups' folders.
        gui.check("with the workspace row selected, the row is selected and Files shows the workspace's folder again",
                  lambda s: s["state"]["workbench"]["selected"] == wrow and gui.find(s, "a1.txt", role="4")
                  and norm(s["state"]["filesRoots"][0]).endswith("/fixture/alpha"), 8,
                  detail=lambda s: (s["state"]["filesRoots"], [e["label"] for e in s["elements"] if e["role"] == "4" and e["label"].endswith(".txt")]))
    stage(gui, "the right panel follows the selected row", follows)

    def sizes():
        open_file(gui, "a1.txt")
        first = resize(gui, 760, 600)
        snap = dump(gui, "narrow")
        gui.check("narrow: nothing clickable reaches past the window's edge", lambda s: not clipped(s), 2, detail=clipped)
        gui.check("narrow: the document's tab is still there", lambda s: "a1.txt" in titles(s["state"]), 2, detail=lambda s: titles(s["state"]))
        gui.check("narrow: the window controls are on screen", lambda s: all(gui.find(s, name) and gui.on_screen(s, gui.find(s, name)[0])
                  for name in ("Close window", "Commands")), 2, detail=lambda s: [e["label"] for e in s["elements"] if e["y"] < 40])
        resize(gui, 1500, 900)
        dump(gui, "wide")
        gui.check("wide: nothing clickable reaches past the window's edge", lambda s: not clipped(s), 2, detail=clipped)
        gui.check("wide: side bar, tab and right panel are all showing", lambda s: gui.find(s, "n:new-workspace") and gui.find(s, "Files", role="18")
                  and "a1.txt" in titles(s["state"]), 3, detail=lambda s: (s["state"]["layoutMode"], titles(s["state"])))
        resize(gui, *first)
        gui.check("back at the first size: nothing clickable reaches past the edge", lambda s: not clipped(s), 2, detail=clipped)
        dump(gui, "first-size")
    stage(gui, "narrow, wide and back", sizes)
    no_errors(gui, "at the end")


if __name__ == "__main__":
    main(run)
