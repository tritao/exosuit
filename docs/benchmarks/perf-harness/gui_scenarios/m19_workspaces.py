"""M19 workspaces: create a workspace, switch between two, and see each workspace's tabs come back.

Real input only: clicks on the tree and file rows, typing in the name prompt, Ctrl+Shift+A (quick switch) and Ctrl+Shift+D
(previous). Asserts on the app's state (open workspace, context key, tabs per context, persisted session lines)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha", "beta"], "open": "alpha", "appArgs": ["--open-workbench"]}


def run(gui):
    alpha = attached(gui, "Alpha")
    sequence(gui, alpha, folder_start=True)


def sequence(gui, alpha, folder_start):
    """`folder_start`: the window began on Alpha's folder (a command line argument), not by opening the workspace row; the
    context key then stays 'workspace', which loses Alpha's tabs once the window has been in another workspace."""
    gui.step("open two files in Alpha")
    open_file(gui, "a1.txt")
    open_file(gui, "a2.txt")
    gui.check("Alpha has tabs a1.txt, a2.txt", lambda s: tabs(s["state"]) == ["a1.txt", "a2.txt"])
    gui.check("context key is Alpha's", lambda s: alpha in s["state"]["context"],
              detail=lambda s: s["state"]["context"])
    gui.shot("alpha-two-tabs")

    gui.step("create workspace Gamma from the New Workspace row")
    show_workbench(gui)
    gui.click(gui.element("n:new-workspace"))
    gui.wait("name prompt", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text("Gamma")
    gui.chord("enter")
    gamma = gui.wait("Gamma exists", lambda s: (ws(s["state"], "Gamma") or {}).get("id"), 20)
    gui.check("new workspace Gamma created and opened", lambda s: s["state"]["openWorkspace"] == gamma and s["state"]["groups"] is not None, 40)
    gui.check("Gamma starts with no tabs", lambda s: tabs(s["state"]) == [])
    gui.check("Gamma's context key names it", lambda s: gamma in s["state"]["context"], detail=lambda s: s["state"]["context"])
    gui.shot("gamma-open")

    gui.step("quick switch back to Alpha")
    show_workbench(gui)
    gui.click(gui.element("w:" + gamma))
    quick_switch(gui, "Alpha")
    gui.check("switched to Alpha", lambda s: s["state"]["openWorkspace"] == alpha and s["state"]["groups"] is not None, 40)
    gui.check("Alpha's tabs came back (a1.txt, a2.txt)", lambda s: tabs(s["state"]) == ["a1.txt", "a2.txt"],
              detail=lambda s: tabs(s["state"]))
    gui.shot("alpha-back")

    gui.step("Ctrl+Shift+D goes to the previous workspace (Gamma)")
    show_workbench(gui)
    gui.click(gui.element("w:" + alpha))
    gui.chord("ctrl+shift+d")
    gui.check("previous workspace is Gamma", lambda s: s["state"]["openWorkspace"] == gamma and s["state"]["groups"] is not None, 40)
    gui.check("Gamma still has no tabs", lambda s: tabs(s["state"]) == [])
    gui.chord("ctrl+shift+d")
    gui.check("and previous again is Alpha with its tabs", lambda s: s["state"]["openWorkspace"] == alpha and tabs(s["state"]) == ["a1.txt", "a2.txt"], 40,
              detail=lambda s: (s["state"]["openWorkspace"], tabs(s["state"])))
    gui.shot("alpha-after-previous")


if __name__ == "__main__":
    main(run)
