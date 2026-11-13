"""Everyday sweep, tabs and layout: open three files, switch with Ctrl+Tab and Ctrl+Shift+Tab, drag a tab to another
place, hover a tab for its tooltip, close a tab with Ctrl+W and reopen it with Ctrl+Shift+T, read the status bar, hide
and show the side bar and the right panel, change the layout mode and come back.

Real input only. Each flow is its own stage, so one broken flow does not hide the others."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha"], "open": "alpha", "appArgs": ["--open-workbench"]}


def tab(gui, name, timeout=8.0):
    """The tab strip's element for a document (role 18 is a tab; the Files tree's rows are role 4 and 31)."""
    return gui.element(pattern=r"(^|[\\/ ])" + name.replace(".", r"\.") + "$", role="18", timeout=timeout)


def status(snap):
    """Texts of the status bar: everything labelled in the window's last 30 pixels."""
    bottom = snap["viewport"]["height"] - 30
    return [e["label"].replace("\n", " | ") for e in snap["elements"] if e["y"] >= bottom]


def run(gui):
    attached(gui, "Alpha")
    gui.wait("Alpha's catalog", lambda s: s["state"]["workbench"]["catalog"], 40, settle=0.5)
    for name in ("a1.txt", "a2.txt", "a3.txt"):
        open_file(gui, name)
    gui.check("three tabs in the order they were opened", lambda s: titles(s["state"]) == ["a1.txt", "a2.txt", "a3.txt"], 10,
              detail=lambda s: titles(s["state"]))
    dump(gui, "three-tabs")

    def keyboard():
        gui.check("the last opened tab is active", lambda s: active_title(s["state"]) == "a3.txt", 3, detail=lambda s: active_title(s["state"]))
        gui.chord("ctrl+tab")
        gui.check("Ctrl+Tab wraps to the first tab", lambda s: active_title(s["state"]) == "a1.txt", 3, detail=lambda s: active_title(s["state"]))
        gui.chord("ctrl+tab")
        gui.check("Ctrl+Tab goes to the next tab", lambda s: active_title(s["state"]) == "a2.txt", 3, detail=lambda s: active_title(s["state"]))
        gui.chord("ctrl+shift+tab")
        gui.check("Ctrl+Shift+Tab goes back", lambda s: active_title(s["state"]) == "a1.txt", 3, detail=lambda s: active_title(s["state"]))
    stage(gui, "switch tabs with the keyboard", keyboard)

    def status_bar():
        gui.click(tab(gui, "a2.txt"))
        gui.check("a click on a tab makes it active", lambda s: active_title(s["state"]) == "a2.txt", 3, detail=lambda s: active_title(s["state"]))
        gui.check("the status bar names the active document", lambda s: any("a2.txt" in text for text in status(s)), 3, detail=status)
        gui.check("the status bar shows the encoding, the indentation and how many tabs are open",
                  lambda s: any("UTF-8" in text for text in status(s)) and any(text.startswith("Spaces") or text.startswith("Tabs") for text in status(s))
                  and any(text == "3 open" for text in status(s)), 3, detail=status)
        gui.check("the status bar shows the cursor's line and column", lambda s: any(text.startswith("Ln ") and ", Col " in text for text in status(s)), 3, detail=status)
    stage(gui, "the status bar follows the active tab", status_bar)

    def tooltip():
        target = tab(gui, "a3.txt")
        x, y = gui.screen_point(target)
        gui.glide(x, y)
        time.sleep(1.5)
        dump(gui, "tab-tooltip")
        strip = target["y"] + target["h"]
        gui.check("hovering a tab shows a tooltip with the file's path", lambda s: any("fixture" in e["label"] and e["label"].endswith("a3.txt") and e["role"] == "4"
                  and strip - 4 <= e["y"] < strip + 60 and abs(e["x"] - target["x"]) < 400 for e in s["elements"]), 3,
                  detail=lambda s: [(e["role"], e["x"], e["y"], e["label"]) for e in s["elements"] if "a3.txt" in e["label"]])
    stage(gui, "a tab's tooltip", tooltip)

    def reorder():
        gui.drag(tab(gui, "a3.txt"), tab(gui, "a1.txt"), target_fy=0.5)
        gui.check("dragging a3 onto a1 moves it to the front", lambda s: titles(s["state"]) == ["a3.txt", "a1.txt", "a2.txt"], 5,
                  detail=lambda s: titles(s["state"]))
        dump(gui, "reordered")
    stage(gui, "drag a tab to another place", reorder)

    def close_reopen():
        before = titles(gui.state())
        gui.click(tab(gui, "a1.txt"))
        gui.chord("ctrl+w")
        gui.check("Ctrl+W closes the active tab", lambda s: "a1.txt" not in titles(s["state"]) and len(titles(s["state"])) == 2, 5,
                  detail=lambda s: titles(s["state"]))
        gui.chord("ctrl+shift+t")
        gui.check("Ctrl+Shift+T reopens the tab that was closed last, in its old place", lambda s: titles(s["state"]) == before and active_title(s["state"]) == "a1.txt", 5,
                  detail=lambda s: (titles(s["state"]), active_title(s["state"])))
        closers = [e for e in gui.snapshot()["elements"] if e["label"].lower().startswith("close") and e["y"] < 110 and 280 < e["x"] < 1000]
        gui.check("each tab has a close button", lambda s: len(closers) >= 1, 1, detail=lambda s: [e["label"] for e in s["elements"] if e["y"] < 110])
        if closers:
            count = len(titles(gui.state()))
            gui.click(closers[-1])
            gui.check("a tab's close button closes it", lambda s: len(titles(s["state"])) == count - 1, 5, detail=lambda s: titles(s["state"]))
            gui.chord("ctrl+shift+t")
            gui.check("and Ctrl+Shift+T brings that one back", lambda s: len(titles(s["state"])) == count, 5, detail=lambda s: titles(s["state"]))
    stage(gui, "close a tab and reopen the last closed", close_reopen)

    def panels():
        width = lambda s: next((e["w"] for e in s["elements"] if e["label"] == "Workbench" and e["role"] == "19"), 0)
        wide = width(gui.snapshot())
        gui.click(gui.element("Toggle Left Sidebar", role="1"))
        gui.check("Toggle Left Sidebar hides the side bar", lambda s: not gui.find(s, "n:new-workspace"), 3)
        dump(gui, "sidebar-hidden")
        gui.click(gui.element("Toggle Left Sidebar", role="1"))
        gui.check("and shows it again at about the same width", lambda s: gui.find(s, "n:new-workspace") and abs(width(s) - wide) <= 3, 3, detail=lambda s: (wide, width(s)))
        widths = [wide, width(gui.snapshot())]
        for _ in range(2):
            gui.click(gui.element("Toggle Left Sidebar", role="1"))
            gui.wait("side bar hidden", lambda s: not gui.find(s, "n:new-workspace"), 3)
            gui.click(gui.element("Toggle Left Sidebar", role="1"))
            gui.wait("side bar shown", lambda s: gui.find(s, "n:new-workspace"), 3, settle=0.3)
            widths.append(width(gui.snapshot()))
        gui.check("hiding and showing the side bar three times leaves its width exactly as it was", lambda s: max(widths) - min(widths) < 0.5, 1, detail=lambda s: widths)
        gui.click(gui.element("Toggle Right Panel", role="1"))
        gui.check("Toggle Right Panel hides the Files panel", lambda s: not gui.find(s, "Files", role="18"), 3)
        gui.click(gui.element("Toggle Right Panel", role="1"))
        gui.check("and shows it again", lambda s: gui.find(s, "Files", role="18"), 3)
        gui.check("the tabs are untouched", lambda s: len(titles(s["state"])) == 3, 2, detail=lambda s: titles(s["state"]))
    stage(gui, "hide and show the side bar and the right panel", panels)

    def modes():
        first = gui.state()["layoutMode"]
        gui.click(gui.element("Layout", role="1"))
        time.sleep(0.5)
        dump(gui, "layout-menu")
        gui.chord("escape")
        other = "editor" if first != "editor" else "agents"
        palette(gui, "Use %s Layout" % other.capitalize())
        gui.check("the palette changes the layout mode to " + other, lambda s: s["state"]["layoutMode"] == other, 5, detail=lambda s: s["state"]["layoutMode"])
        time.sleep(0.5)
        dump(gui, "mode-" + other)
        gui.check("the tabs are still there in the other mode", lambda s: len(titles(s["state"])) == 3, 3, detail=lambda s: titles(s["state"]))
        palette(gui, "Use %s Layout" % first.capitalize())
        gui.check("and back to " + first, lambda s: s["state"]["layoutMode"] == first, 5, detail=lambda s: s["state"]["layoutMode"])
        time.sleep(0.5)
        dump(gui, "mode-back")
    stage(gui, "change the layout mode and come back", modes)
    no_errors(gui, "at the end")


if __name__ == "__main__":
    main(run)
