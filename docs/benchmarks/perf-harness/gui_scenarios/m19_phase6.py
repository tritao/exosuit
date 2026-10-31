"""M19 Phase 6: with two workspaces running, the Workbench tree of one window shows the other workspace's groups and items.

Beta gets a group and a terminal while the window is on it; the window then moves to Alpha, and the tree must still list
Beta's group and terminal (rows keyed f:...), live, from the catalog connection."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import menu, open_by_double_click
from m19_sessions_drag import new_terminal

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]}
ELLIPSIS = "…"


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha, beta = ws(gui.state(), "Alpha")["id"], ws(gui.state(), "Beta")["id"]
    open_by_double_click(gui, beta, "Beta")
    show_workbench(gui)
    work = gui.wait("Beta's group", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
    bterm = new_terminal(gui, "g:" + work)

    gui.step("move the window to Alpha; Beta keeps running")
    show_workbench(gui)
    gui.click(gui.element("w:" + alpha), count=2)
    attached(gui, "Alpha")
    show_workbench(gui)
    gui.check("Beta's row says running", lambda s: gui.find(s, pattern=r"^Workspace Beta, running"), 20,
              detail=lambda s: [e["label"][:40] for e in s["elements"] if e["label"].startswith("Workspace")])
    foreign_group = "f:g" + beta + "|" + work
    foreign_term = "f:t" + beta + "|" + bterm
    # Beta's row is collapsed: expand it with its chevron.
    if not gui.find(gui.snapshot(), foreign_group):
        beta_row = gui.element("w:" + beta)
        gui.click(beta_row, fx=min(0.04, 10.0 / beta_row["w"]))
    labels = lambda s: [("watched", s["state"].get("watched"))] + [e["label"][:50] for e in s["elements"] if e["x"] < 300 and e["y"] > 100 and e["role"] in ("4", "31")]
    gui.check("Beta's group is in the tree (f: row)", lambda s: gui.find(s, foreign_group), 45, detail=labels)
    if not gui.find(gui.snapshot(), foreign_term):  # the group row is collapsed: expand it with its chevron
        group_row = gui.element(foreign_group)
        gui.click(group_row, fx=min(0.04, 10.0 / group_row["w"]) + 0.07)
    gui.check("Beta's terminal is in the tree (f: row)", lambda s: gui.find(s, foreign_term), 10, detail=labels)
    gui.shot("beta-in-alpha-tree")

    gui.step("a click and Enter on Beta's terminal row opens Beta's context")
    if not gui.find(gui.snapshot(), foreign_term):
        gui.step("skipped: Beta's rows are not in the tree (known bug above)")
        return
    gui.click(gui.element(foreign_term))
    time.sleep(0.4)
    gui.chord("enter")
    gui.check("the window follows to Beta", lambda s: s["state"]["contextWorkspace"] == beta, 40,
              detail=lambda s: (s["state"]["contextWorkspace"], s["state"]["openWorkspace"]))


if __name__ == "__main__":
    main(run)
