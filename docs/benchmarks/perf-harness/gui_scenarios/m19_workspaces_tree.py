"""M19 workspaces, starting the normal way: the window opens on no folder and Alpha is opened by a double click on its row
in the Workbench tree. The same create / switch / tabs-come-back sequence as m19_workspaces."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_workspaces import sequence

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]}


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    gui.click(gui.element("w:" + alpha), count=2)  # a double click opens the workspace in this window
    opened = gui.check("a double click on a workspace row opens it", lambda s: s["state"]["openWorkspace"] == alpha, 15,
                       detail=lambda s: s["state"]["openWorkspace"])
    if not opened:  # the right-click menu's Open does the same; carry on with the rest of the checks
        gui.click(gui.element("w:" + alpha), button="right")
        gui.click(gui.element("Open", role="16"))
    attached(gui, "Alpha")
    sequence(gui, alpha, folder_start=False)


if __name__ == "__main__":
    main(run)
