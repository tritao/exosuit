"""M19 group entry: a single click on a group row focuses that group; a click on the open workspace's row focuses its
root. Work (the default group, which has the workspace folder) and the root are two contexts with two keys: tabs opened in
one do not appear in the other. Context keys come from the automation snapshot (`context`, `hostContext`)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import open_by_double_click
from m19_sessions_drag import create

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]}


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    show_workbench(gui)
    work = gui.wait("group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
    root_key = gui.state()["context"]
    gui.check("the window starts in the workspace root context", lambda s: s["state"]["context"] == root_key and not s["state"]["context"].endswith("/" + work), 5)

    gui.step("a single click on the Work row enters Work")
    gui.click(gui.element("g:" + work), fx=0.6)
    gui.check("the click makes Work the active context", lambda s: s["state"]["context"].endswith("/" + work), 8,
              detail=lambda s: (s["state"]["context"], s["state"]["hostContext"]))
    work_key = gui.state()["context"]
    gui.check("Work's key differs from the root's", lambda s: work_key != root_key and s["state"]["hostContext"] == work_key, 5,
              detail=lambda s: (root_key, work_key, s["state"]["hostContext"]))
    gui.shot("work-entered")

    gui.step("tabs opened in Work stay in Work")
    open_file(gui, "a1.txt")
    gui.check("Work has a1", lambda s: tabs(s["state"]) == ["a1.txt"], 10, detail=lambda s: tabs(s["state"]))

    gui.step("a click on the workspace row enters the root, which has no tabs of Work's")
    gui.click(gui.element("w:" + alpha), fx=0.6)
    gui.check("the root context is active", lambda s: s["state"]["context"] == root_key, 8,
              detail=lambda s: (s["state"]["context"], root_key))
    gui.check("the root shows none of Work's tabs", lambda s: tabs(s["state"]) == [], 8, detail=lambda s: tabs(s["state"]))
    open_file(gui, "a2.txt")
    gui.check("the root has a2 only", lambda s: tabs(s["state"]) == ["a2.txt"], 10, detail=lambda s: tabs(s["state"]))

    gui.step("back to Work by a click: a1 only")
    gui.click(gui.element("g:" + work), fx=0.6)
    gui.check("Work is back with a1 only", lambda s: s["state"]["context"] == work_key and tabs(s["state"]) == ["a1.txt"], 10,
              detail=lambda s: (s["state"]["context"], tabs(s["state"])))

    gui.step("a second group is entered by a click as well")
    show_workbench(gui)
    create(gui, "g:" + work, "New group", "Second", "groups")
    second = by_name_id(gui.state(), "Second")
    gui.click(gui.element("g:" + second), fx=0.6)
    gui.check("the click enters Second", lambda s: s["state"]["context"].endswith("/" + second), 8,
              detail=lambda s: s["state"]["context"])
    gui.check("Second starts with no tabs", lambda s: tabs(s["state"]) == [], 8, detail=lambda s: tabs(s["state"]))

    gui.step("Enter on a selected group row enters it")
    gui.click(gui.element("w:" + alpha), fx=0.6)
    gui.check("root again", lambda s: s["state"]["context"] == root_key, 8, detail=lambda s: s["state"]["context"])
    gui.chord("down")  # the selection moves to the next row, which is a group of Alpha; the context stays
    time.sleep(0.3)
    gui.check("an arrow key alone does not switch", lambda s: s["state"]["context"] == root_key, 3, detail=lambda s: s["state"]["context"])
    time.sleep(0.7)
    gui.chord("enter")
    gui.shot("after-enter")
    gui.step("focus after Down: %s" % gui.snapshot().get("focus"))
    gui.check("Enter enters the selected group", lambda s: s["state"]["context"] != root_key, 8, detail=lambda s: s["state"]["context"],
              known_bug="the tree loses keyboard focus after an arrow key moved the selection, so Enter after it reaches no row (NEXT-PHASE)")
    gui.shot("done")


def by_name_id(state, name):
    return next((g["id"] for g in state["groups"] if g["name"] == name), None)


if __name__ == "__main__":
    main(run)
