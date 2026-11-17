"""Everyday sweep, every other place that starts a session or a terminal, each clicked and each used.

Alpha: its empty row says so, and the row's New Agent Session starts the default provider (the fake Codex) at once,
a prompt and its reply. Then a group made from the workspace row's menu; the group row's menu makes an agent session
(prompt, reply) and a terminal (a command typed, its output seen). Beta, not open: its row's New Terminal makes the
terminal in Beta with its tab here, the window staying on Alpha (as wb_other_rows), a command and its output.

Real input only; the provider is tests/workspace-agents/fake-codex.py (no real Claude or Codex)."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep_common import *  # noqa: F401,F403
from m19_sessions_drag import by_name

FIXTURE = with_fake_agents({"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]})


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    beta = ws(gui.state(), "Beta")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    show_workbench(gui)
    made = {}

    def empty_row_agent():
        expand(gui, "w:" + alpha)  # a click opened it; the chevron shows its rows
        gui.check("Alpha's empty row says so", lambda s: s["state"]["workbenchEmptyState"] and gui.find(s, "s:none|" + alpha), 15)
        made["e"] = new_agent_from_menu(gui, "s:none|" + alpha, "the empty row's menu")
        ask(gui, "from the empty row", "the empty row's session")
    stage(gui, "agent session from the empty row's menu", empty_row_agent)

    def group():
        menu(gui, "w:" + alpha, "New Group")
        time.sleep(0.6)
        gui.type_text("Work")
        gui.chord("enter")
        gui.check("workspace row menu: New Group makes the group Work", lambda s: by_name(s["state"], "groups", "Work") and gui.find(s, open_row(gui, "g", by_name(s["state"], "groups", "Work")["id"])), 20,
                  detail=lambda s: (s["state"]["groups"], s["state"]["notifications"][-2:]))
        made["work"] = by_name(gui.state(), "groups", "Work")["id"]
    stage(gui, "a group from the workspace row's menu", group)
    work = made.get("work", "missing")

    def group_agent():
        made["g"] = new_agent_from_menu(gui, open_row(gui, "g", work), "group row menu")
        gui.check("the session is in the group Work", lambda s: next(a for a in s["state"]["agents"] if a["id"] == made["g"])["group"] == work, 5,
                  detail=lambda s: s["state"]["agents"])
        ask(gui, "from the group", "the group's session")
    stage(gui, "agent session from a group row's menu", group_agent)

    def group_terminal():
        before = terminal_ids(gui.state())
        menu(gui, open_row(gui, "g", work), "New Terminal")
        tid = fresh_terminal(gui, before, "group row menu: New Terminal makes a terminal")
        gui.check("the terminal is in the group Work", lambda s: next(t for t in s["state"]["terminals"] if t["id"] == tid)["group"] == work, 5,
                  detail=lambda s: s["state"]["terminals"])
        run_in_terminal(gui, "the group's terminal", "GROUPTERM")
        dump(gui, "group-terminal")
    stage(gui, "terminal from a group row's menu", group_terminal)

    def other_workspace_terminal():
        menu(gui, "w:" + beta, "New Terminal")
        gui.check("Beta's row menu: New Terminal makes a terminal in Beta", lambda s: gui.find(s, pattern=r"^t:%s\|" % beta), 40,
                  detail=lambda s: (s["state"]["workbench"], s["state"]["notifications"][-3:]))
        gui.check("the window stays on Alpha", lambda s: s["state"]["openWorkspace"] == alpha, 2, detail=lambda s: s["state"]["openWorkspace"])
        run_in_terminal(gui, "Beta's terminal", "BETATERM")
        dump(gui, "beta-terminal")
    stage(gui, "terminal from a row of a workspace that is not open", other_workspace_terminal)
    no_errors(gui, "at the end")
    dump(gui, "end")


if __name__ == "__main__":
    main(run)
