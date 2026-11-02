"""M19 Phase 8: two editor windows on one machine. Window 1 opens Alpha, then starts a second window on Beta from Beta's
row (Open in New Window); the second window is driven with its own driver. Each window's tree marks what the other has
open, each sees the other's new group and terminal live, and closing the second window leaves the services running.

The second window's automation folder is EXOSUIT_NEW_WINDOW_AUTOMATION_DIR (set by the fixture)."""
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from gui_driver import Gui
from m19_folders import menu, open_by_double_click
from m19_sessions_drag import create, new_terminal

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"],
           "env": {"EXOSUIT_NEW_WINDOW_AUTOMATION_DIR": "{out}/automation-2"}}


def watched(state, workspace):
    return next((w for w in state.get("watched", []) if w["workspace"] == workspace), None)


def others(state, workspace):
    """The other windows' focus on `workspace`: their context keys."""
    return [w["context"] for w in state.get("otherWindows", []) if "/" + workspace + "/" in w["context"]]


def run(gui):
    second_pid = None
    try:
        gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
        alpha, beta = ws(gui.state(), "Alpha")["id"], ws(gui.state(), "Beta")["id"]
        open_by_double_click(gui, alpha, "Alpha")
        show_workbench(gui)
        work = gui.wait("Alpha's group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
        gui.check("no other window yet", lambda s: s["state"]["otherWindows"] == [], 5, detail=lambda s: s["state"]["otherWindows"])

        gui.step("Open in New Window on Beta's row")
        menu(gui, "w:" + beta, "Open in New Window")
        second_pid = gui.wait("window 2 registered, focused on Beta",
                              lambda s: next((w["pid"] for w in s["state"]["otherWindows"] if "/" + beta + "/" in w["context"]), None), 60)
        gui.check("window 1 knows window 2's focus (suit's windows list)", lambda s: others(s["state"], beta), 5)
        gui.check("starting the window blocked the frame under 50 ms", lambda s: 0 < s["state"]["newWindowMs"] < 50, 5,
                  detail=lambda s: s["state"]["newWindowMs"])
        two = Gui(second_pid, os.path.join(os.path.dirname(gui.dir), "automation-2"), os.path.join(gui.out, "window2"),
                  max(10, gui.deadline - time.monotonic()), 30)
        two.wait("window 2 attached to Beta", lambda s: s["state"]["openWorkspace"] == beta and s["state"]["groups"] is not None, 40)
        two.check("window 2 opened on Beta, not on the last workspace", lambda s: s["state"]["contextWorkspace"] == beta, 5,
                  detail=lambda s: s["state"]["context"])
        two.check("window 2 sees window 1 on Alpha", lambda s: others(s["state"], alpha), 10, detail=lambda s: s["state"]["otherWindows"])
        gui.focus()
        gui.check("window 1's tree marks Beta: open in another window", lambda s: gui.find(s, pattern=r"^Workspace Beta.*open in another window"), 15,
                  detail=lambda s: [e["label"][:60] for e in s["elements"] if e["label"].startswith("Workspace")])
        gui.shot("window1")
        two.focus()
        show_workbench(two)
        two.check("window 2's tree marks Alpha: open in another window", lambda s: two.find(s, pattern=r"^Workspace Alpha.*open in another window"), 15,
                  detail=lambda s: [e["label"][:60] for e in s["elements"] if e["label"].startswith("Workspace")])
        two.shot("window2")

        gui.step("window 1 makes a group and a terminal in Alpha; window 2 sees them")
        gui.focus()
        before = watched(two.state(), alpha)
        groups0, terms0 = (before["groups"], before["terminals"]) if before and before["groups"] >= 0 else (0, 0)
        create(gui, "g:" + work, "New group", "Second", "groups")
        new_terminal(gui, "g:" + work)
        two.check("window 2 sees Alpha's new group", lambda s: (watched(s["state"], alpha) or {}).get("groups", -1) > groups0, 20,
                  detail=lambda s: (watched(s["state"], alpha), groups0))
        two.check("window 2 sees Alpha's new terminal", lambda s: (watched(s["state"], alpha) or {}).get("terminals", -1) > terms0, 20,
                  detail=lambda s: (watched(s["state"], alpha), terms0))

        gui.step("window 2 makes a group in Beta; window 1 sees it")
        two.focus()
        bwork = two.wait("Beta's group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
        before = watched(gui.state(), beta)
        bgroups0 = before["groups"] if before and before["groups"] >= 0 else 0
        create(two, "g:" + bwork, "New group", "Third", "groups")
        gui.check("window 1 sees Beta's new group", lambda s: (watched(s["state"], beta) or {}).get("groups", -1) > bgroups0, 20,
                  detail=lambda s: (watched(s["state"], beta), bgroups0))

        gui.step("closing window 2 leaves both services running")
        subprocess.run(["taskkill", "/PID", str(second_pid), "/T", "/F"], capture_output=True)
        second_pid = None
        gui.focus()
        gui.check("window 2 is gone from window 1's list", lambda s: s["state"]["otherWindows"] == [], 20, detail=lambda s: s["state"]["otherWindows"])
        gui.check("Beta's service still runs", lambda s: (watched(s["state"], beta) or {}).get("running") is True, 10,
                  detail=lambda s: watched(s["state"], beta))
        gui.check("Alpha's service still runs", lambda s: s["state"]["openWorkspace"] == alpha and not s["state"]["workspaceError"], 5,
                  detail=lambda s: (s["state"]["openWorkspace"], s["state"]["workspaceError"]))
    finally:
        if second_pid is not None:
            subprocess.run(["taskkill", "/PID", str(second_pid), "/T", "/F"], capture_output=True)


if __name__ == "__main__":
    main(run)
