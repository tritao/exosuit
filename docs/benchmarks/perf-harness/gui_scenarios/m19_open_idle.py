"""Opening an idle workspace at once: a double click on its row. Expanding starts its service (Phase 6) and the second click
attaches the window, which starts a manager of its own. The window must end up attached, not 'Workspace unavailable'."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import healthy

FIXTURE = {"workspaces": ["alpha", "beta"], "folders": ["extra"], "open": None, "appArgs": ["--open-workbench"]}


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    beta = ws(gui.state(), "Beta")["id"]
    gui.click(gui.element("w:" + beta), count=2)
    healthy(gui, "double click on an idle workspace")
    gui.check("the window attached to Beta", lambda s: s["state"]["openWorkspace"] == beta and s["state"]["groups"] is not None, 30,
              detail=lambda s: (s["state"]["openWorkspace"], s["state"]["workspaceStatus"], s["state"]["notifications"]))
    gui.shot("after-double-click")


if __name__ == "__main__":
    main(run)
