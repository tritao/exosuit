"""M19 folders, the other path: attach a folder to the workspace that is open in the window (no restart wanted)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import attach_extra, healthy, open_by_double_click

FIXTURE = {"workspaces": ["alpha"], "folders": ["extra"], "open": None, "appArgs": ["--open-workbench"]}


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    extra = os.path.join(os.path.dirname(gui.out), "fixture", "extra")
    attach_extra(gui, alpha, extra, "Alpha")
    healthy(gui, "after attaching to the open workspace")
    gui.check("Files roots list both folders", lambda s: len(s["state"]["filesRoots"]) >= 2, 10, detail=lambda s: s["state"]["filesRoots"])
    gui.shot("after-attach")


if __name__ == "__main__":
    main(run)
