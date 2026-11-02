"""M19: a window on one workspace shows only that workspace's folders, and its title names that workspace.

Alpha is opened and gets a terminal tab; the window then moves to Beta (double click on its row), then back to Alpha by
the terminal row of the tree. After each move the right panel's folders, the context's roots, the open projects and the
title bar must all be the open workspace's own: never a folder of the workspace left behind."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import menu, open_by_double_click
from m19_sessions_drag import new_terminal

ELLIPSIS = "…"
FIXTURE = {"workspaces": ["alpha", "beta", "gamma"], "open": None, "appArgs": ["--open-workbench"]}


def norm(path):
    return path.replace("\\", "/").rstrip("/").lower()


def only(gui, label, name, folder, files=True):
    """Every folder list the app shows holds exactly `folder`, and the title says `name`."""
    want = [norm(folder)]
    for key in (("filesRoots",) if files else ()) + ("contextRoots", "projectRoots"):
        gui.check("%s: %s is just %s" % (label, key, name), lambda s, key=key: [norm(r) for r in s["state"][key]] == want, 10,
                  detail=lambda s: {k: s["state"][k] for k in ("filesRoots", "contextRoots", "projectRoots")})
    gui.check("%s: the title names %s" % (label, name), lambda s: s["state"]["title"] == name, 10,
              detail=lambda s: (s["state"]["title"], s["state"]["openWorkspace"], s["state"]["savedWorkspace"]))


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 3 and gui.find(s, pattern="^w:"), 60)
    fixture = os.path.join(os.path.dirname(gui.out), "fixture")
    alpha, beta = ws(gui.state(), "Alpha")["id"], ws(gui.state(), "Beta")["id"]

    gui.step("Alpha with a terminal tab")
    open_by_double_click(gui, alpha, "Alpha")
    show_workbench(gui)
    work = gui.wait("Alpha's group", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
    term = new_terminal(gui, "g:" + work)
    only(gui, "Alpha", "Alpha", os.path.join(fixture, "alpha"))
    gui.shot("alpha")

    gui.step("a group whose folder is Gamma's: 'Open folder' must not add Gamma to Alpha")
    show_workbench(gui)
    gamma = os.path.join(fixture, "gamma")
    with open(os.path.join(gui.dir, "pick-folder.txt"), "w") as f:
        f.write(gamma)
    menu(gui, "g:" + work, "Change Working Directory" + ELLIPSIS)
    gui.wait("the group's folder is Gamma's", lambda s: any(g["id"] == work and g["cwd"] and norm(g["cwd"]) == norm(gamma) for g in s["state"]["groups"]), 15)
    show_workbench(gui)
    menu(gui, "g:" + work, "Open folder")
    time.sleep(2)
    alpha_folder = [norm(os.path.join(fixture, "alpha"))]
    gui.check("Alpha's open projects are still just Alpha's folder", lambda s: [norm(r) for r in s["state"]["projectRoots"]] == alpha_folder, 10,
              detail=lambda s: {k: s["state"][k] for k in ("filesRoots", "contextRoots", "projectRoots")})
    gui.check("the title still names Alpha", lambda s: s["state"]["title"] == "Alpha", 10, detail=lambda s: s["state"]["title"])
    gui.shot("after-open-folder")
    # The group's folder is outside Alpha's, so it shows in the panel while the group is focused (Phase 5); the window
    # must work in Alpha's own folders again once back at the workspace root.
    quick_switch(gui, "Alpha")

    gui.step("move the window to Beta")
    show_workbench(gui)
    gui.click(gui.element("w:" + beta), count=2)
    attached(gui, "Beta")
    only(gui, "Beta", "Beta", os.path.join(fixture, "beta"))
    gui.shot("beta")

    gui.step("back to Alpha through its terminal row")
    show_workbench(gui)
    foreign_group = "f:g" + alpha + "|" + work
    foreign_term = "f:t" + alpha + "|" + term
    if not gui.find(gui.snapshot(), foreign_group):
        row_ = gui.element("w:" + alpha)
        gui.click(row_, fx=min(0.04, 10.0 / row_["w"]))
    gui.wait("Alpha's group in the tree", lambda s: gui.find(s, foreign_group), 45)
    if not gui.find(gui.snapshot(), foreign_term):
        group_row = gui.element(foreign_group)
        gui.click(group_row, fx=min(0.04, 10.0 / group_row["w"]) + 0.07)
    gui.click(gui.element(foreign_term))
    time.sleep(0.4)
    gui.chord("enter")
    gui.wait("the window follows to Alpha", lambda s: s["state"]["contextWorkspace"] == alpha, 40)
    attached(gui, "Alpha")
    only(gui, "Alpha again", "Alpha", os.path.join(fixture, "alpha"), files=False)
    gui.shot("alpha-again")


if __name__ == "__main__":
    main(run)
