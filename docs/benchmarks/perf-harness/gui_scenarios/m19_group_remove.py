"""M19 group remove: removing the group the window works in (the last group of the workspace) moves the window to the
workspace root, keeps the layout mode (so the Activity Rail's destinations stay where the Agents layout put them),
and the Workbench does not show its "Nothing here yet" start while the workspace root still holds a session.

Real input only. Alpha starts with the group Work; an agent session is made in the workspace root; Work is focused with the
quick switch, then removed from its row's menu."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import menu, open_by_double_click
from m19_sessions_drag import ELLIPSIS

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"],
    "settings": {"workbench/agents/session_mode": "integrated"}, "env": {
    "EXOSUIT_CODEX_BIN": "{python}", "EXOSUIT_CODEX_SCRIPT": "{root}/tests/workspace-agents/fake-codex.py",
    "EXOSUIT_CODEX_PROXY_LAUNCHER": "{root}/scripts/run-codex-proxy.py"}}


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    show_workbench(gui)
    work = gui.wait("group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
    root_context = gui.state()["context"]

    gui.step("an agent session in the workspace root (a fake Codex stands in for the provider)")
    before = {a["id"] for a in gui.state()["agents"]}
    menu(gui, "w:" + alpha, "New Agent Session" + ELLIPSIS)
    gui.element(pattern="Codex", timeout=10)
    gui.shot("chooser")
    gui.chord("enter")
    root_session = gui.wait("a new agent session", lambda s: next((a["id"] for a in s["state"]["agents"] if a["id"] not in before), None), 30)
    gui.check("the session is in the workspace root", lambda s: next(a for a in s["state"]["agents"] if a["id"] == root_session)["group"] in (None, ""), 5,
              detail=lambda s: s["state"]["agents"])

    gui.step("focus the group Work")
    show_workbench(gui)
    gui.chord("ctrl+shift+a")
    gui.wait("quick switch open", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text("Work")
    time.sleep(0.4)
    gui.chord("up")  # the fuzzy match puts the open "Workspace" first; the group entry is above it
    gui.shot("quick-switch")
    gui.chord("enter")
    gui.wait("quick switch closed", lambda s: not s["state"]["commandViewActive"], 5)
    gui.check("the window works in Work", lambda s: s["state"]["contextKind"] == "Group" and s["state"]["context"] != root_context, 15,
              detail=lambda s: (s["state"]["context"], s["state"]["contextKind"]))
    mode = gui.state()["layoutMode"]
    hidden = gui.state()["railHidden"]
    gui.check("the Agents layout is on", lambda s: s["state"]["layoutMode"] == "agents", 5, detail=lambda s: s["state"]["layoutMode"])
    gui.shot("before-remove")

    gui.step("remove the focused group")
    show_workbench(gui)
    menu(gui, "g:" + work, "Remove Group")
    gui.check("Work is gone from the catalog", lambda s: not any(g["id"] == work for g in s["state"]["groups"]), 15,
              detail=lambda s: s["state"]["groups"])
    gui.check("the window moved to the workspace root", lambda s: s["state"]["contextKind"] == "Workspace" and s["state"]["context"] == root_context, 10,
              detail=lambda s: (s["state"]["context"], s["state"]["contextKind"], root_context))
    gui.check("the layout mode did not change", lambda s: s["state"]["layoutMode"] == mode, 5, detail=lambda s: (mode, s["state"]["layoutMode"]))
    gui.check("the Activity Rail did not change", lambda s: s["state"]["railHidden"] == hidden, 5, detail=lambda s: (hidden, s["state"]["railHidden"]))
    gui.check("the root session is still there", lambda s: any(a["id"] == root_session for a in s["state"]["agents"]), 5)
    gui.check("no empty-state start beside the root session", lambda s: not s["state"]["workbenchEmptyState"], 5)
    gui.shot("after-remove")


if __name__ == "__main__":
    main(run)
