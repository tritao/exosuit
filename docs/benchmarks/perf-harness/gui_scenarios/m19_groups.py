"""M19 groups: switching groups changes the tab set. Alpha's Work group holds a1.txt and a2.txt; a new group Second starts
with none, gets a3.txt, and switching back to Work (quick switch, Groups entries) restores a1 and a2. Also Ctrl+Tab and
Goto Previous Workspace from the command palette."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import menu, open_by_double_click
from m19_sessions_drag import by_name, create

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]}


def active_tab(state):
    pane = state["panes"][0] if state["panes"] else None
    return None if not pane or pane["active"] is None or pane["active"] < 0 else tabs(state)[pane["active"]]


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    show_workbench(gui)
    work = gui.wait("group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
    ctx_work = gui.state()["context"]

    gui.step("tabs in Work, and Ctrl+Tab")
    open_file(gui, "a1.txt")
    open_file(gui, "a2.txt")
    gui.check("Work has a1 and a2", lambda s: tabs(s["state"]) == ["a1.txt", "a2.txt"], 10, detail=lambda s: tabs(s["state"]))
    gui.check("a2 is the active tab", lambda s: active_tab(s["state"]) == "a2.txt", 5, detail=lambda s: active_tab(s["state"]))
    gui.chord("ctrl+tab")
    gui.check("Ctrl+Tab moves to the next tab (wraps to a1)", lambda s: active_tab(s["state"]) == "a1.txt", 5,
              detail=lambda s: active_tab(s["state"]))

    gui.step("Ctrl+Shift+G shows Source Control (a keymap binding made with platform key codes)")
    show_workbench(gui)
    gui.click(gui.element(pattern="^w:", timeout=10), button="right")
    time.sleep(0.3)
    gui.chord("escape")
    gui.chord("ctrl+shift+g")
    gui.check("Ctrl+Shift+G activates the Source Control sidebar", lambda s: s["state"]["sidebar"] == "scm", 5,
              detail=lambda s: s["state"]["sidebar"])
    show_workbench(gui)

    gui.step("a new group has its own tab set")
    show_workbench(gui)
    create(gui, "g:" + work, "New group", "Second", "groups")
    quick_switch(gui, "Second")
    gui.check("context is a different group", lambda s: s["state"]["context"] != ctx_work, 10,
              detail=lambda s: (ctx_work, s["state"]["context"]))
    gui.check("Second starts with no tabs", lambda s: tabs(s["state"]) == [], 10, detail=lambda s: tabs(s["state"]))
    ctx_second = gui.state()["context"]
    open_file(gui, "a3.txt")
    gui.check("Second has a3 only", lambda s: tabs(s["state"]) == ["a3.txt"], 10, detail=lambda s: tabs(s["state"]))
    gui.shot("second")

    gui.step("back to the workspace's own context: its tabs return (the Work group is another context from the root)")
    quick_switch(gui, "Alpha")
    gui.check("the root context's tabs are back", lambda s: tabs(s["state"]) == ["a1.txt", "a2.txt"] and s["state"]["context"] == ctx_work, 15,
              detail=lambda s: (s["state"]["context"], tabs(s["state"])))
    quick_switch(gui, "Second")
    gui.check("Second still has a3 only", lambda s: tabs(s["state"]) == ["a3.txt"] and s["state"]["context"] == ctx_second, 15,
              detail=lambda s: (s["state"]["context"], tabs(s["state"])))

    gui.step("Goto Previous Workspace from the palette")
    # An idle workspace is not attached to by a quick switch (the context moves, the window stays on Alpha's service;
    # reported separately), so start Beta's service first, from its row's menu.
    beta = ws(gui.state(), "Beta")["id"]
    show_workbench(gui)
    menu(gui, "w:" + beta, "Start Service")
    gui.wait("Beta running", lambda s: gui.find(s, pattern=r"^Workspace Beta, running"), 40)
    quick_switch(gui, "Beta")
    gui.shot("after-beta-switch")
    gui.check("moved to Beta", lambda s: s["state"]["contextWorkspace"] != alpha and s["state"]["openWorkspace"] == s["state"]["contextWorkspace"], 60,
              detail=lambda s: {"alpha": alpha, "beta": beta, "tabs": tabs(s["state"]), **{k: s["state"][k] for k in ("context", "contextWorkspace", "openWorkspace", "workspaceStatus", "workspaceError", "savedWorkspace", "commandViewActive")}})
    gui.chord("ctrl+shift+p")
    gui.wait("palette open", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text("Previous Workspace")
    time.sleep(0.5)
    gui.shot("palette")
    gui.chord("enter")
    gui.check("palette Goto Previous Workspace returns to Alpha", lambda s: s["state"]["contextWorkspace"] == alpha, 20,
              detail=lambda s: s["state"]["contextWorkspace"])


if __name__ == "__main__":
    main(run)
