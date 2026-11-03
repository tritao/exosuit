"""M19: leaving a workspace keeps its tabs under its own id; they never turn up in the next workspace or folder.

The window starts on Alpha's folder (so it adopts the machine workspace) and opens a1.txt. A plain folder is then opened
through the toolbar's Open Folder (which replaces the workspace): the window must show no tabs and only that folder.
Alpha's row brings a1.txt back; Beta shows none of Alpha's tabs, and Alpha still has its own afterwards."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import open_by_double_click

FIXTURE = {"workspaces": ["alpha", "beta"], "folders": ["extra"], "open": "alpha", "appArgs": ["--open-workbench"]}


def norm(path):
    return path.replace("\\", "/").rstrip("/").lower()


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    fixture = os.path.join(os.path.dirname(gui.out), "fixture")
    alpha, beta = ws(gui.state(), "Alpha")["id"], ws(gui.state(), "Beta")["id"]
    attached(gui, "Alpha")
    gui.step("a tab in Alpha")
    open_file(gui, "a1.txt")
    gui.check("Alpha has a1.txt", lambda s: tabs(s["state"]) == ["a1.txt"], 10, detail=lambda s: tabs(s["state"]))

    gui.step("Open Folder on a plain folder replaces Alpha")
    with open(os.path.join(gui.dir, "pick-folder.txt"), "w") as f:
        f.write(os.path.join(fixture, "extra"))
    gui.click(gui.element("Open Folder", role="1"))
    gui.check("only the extra folder is open", lambda s: [norm(r) for r in s["state"]["projectRoots"]] == [norm(os.path.join(fixture, "extra"))], 15,
              detail=lambda s: (s["state"]["projectRoots"], s["state"]["contextRoots"]))
    gui.check("Alpha's tab is not carried into the folder's window", lambda s: tabs(s["state"]) == [], 10, detail=lambda s: (tabs(s["state"]), s["state"]["context"]))
    gui.shot("extra")

    gui.step("back to Alpha, then Beta, then Alpha")
    show_workbench(gui)
    open_by_double_click(gui, alpha, "Alpha")
    gui.check("Alpha's a1.txt is back", lambda s: tabs(s["state"]) == ["a1.txt"], 15, detail=lambda s: (tabs(s["state"]), s["state"]["context"]))
    show_workbench(gui)
    open_by_double_click(gui, beta, "Beta")
    gui.check("Beta shows none of Alpha's tabs", lambda s: tabs(s["state"]) == [], 15, detail=lambda s: (tabs(s["state"]), s["state"]["context"]))
    show_workbench(gui)
    open_by_double_click(gui, alpha, "Alpha")
    gui.check("Alpha still has a1.txt", lambda s: tabs(s["state"]) == ["a1.txt"], 15, detail=lambda s: (tabs(s["state"]), s["state"]["context"]))
    gui.shot("alpha-again")


if __name__ == "__main__":
    main(run)
