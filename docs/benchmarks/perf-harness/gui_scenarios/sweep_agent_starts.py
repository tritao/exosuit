"""Everyday sweep, every other place that starts a session or a terminal, each clicked and each used.

Alpha: the empty state's "New agent session…" button, the fake Codex picked in the chooser, a prompt and its reply.
Then a group made from the workspace row's menu; the group row's menu makes an agent session (prompt, reply) and a
terminal (a command typed, its output seen). Beta: the empty state's "New terminal" button, a command and its output.

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

    def empty_state_agent():
        gui.check("Alpha's empty state offers New agent session…", lambda s: gui.find(s, "New agent session" + ELLIPSIS, role="1"), 15)
        before = agent_ids(gui.state())
        gui.click(gui.element("New agent session" + ELLIPSIS, role="1"))
        made["e"] = pick_fake_agent(gui, before, "empty state's New agent session…")
        ask(gui, "from the empty state", "the empty state's session")
    stage(gui, "agent session from the empty state's button", empty_state_agent)

    def group():
        menu(gui, "w:" + alpha, "New Group" + ELLIPSIS)
        time.sleep(0.6)
        gui.type_text("Work")
        gui.chord("enter")
        gui.check("workspace row menu: New Group… makes the group Work", lambda s: by_name(s["state"], "groups", "Work") and gui.find(s, "g:" + by_name(s["state"], "groups", "Work")["id"]), 20,
                  detail=lambda s: (s["state"]["groups"], s["state"]["notifications"][-2:]))
        made["work"] = by_name(gui.state(), "groups", "Work")["id"]
    stage(gui, "a group from the workspace row's menu", group)
    work = made.get("work", "missing")

    def group_agent():
        made["g"] = new_agent_from_menu(gui, "g:" + work, "group row menu")
        gui.check("the session is in the group Work", lambda s: next(a for a in s["state"]["agents"] if a["id"] == made["g"])["group"] == work, 5,
                  detail=lambda s: s["state"]["agents"])
        ask(gui, "from the group", "the group's session")
    stage(gui, "agent session from a group row's menu", group_agent)

    def group_terminal():
        before = terminal_ids(gui.state())
        menu(gui, "g:" + work, "New Terminal" + ELLIPSIS)
        gui.wait("New Terminal prompt", lambda s: s["state"]["commandViewActive"], 5)
        gui.chord("enter")
        tid = fresh_terminal(gui, before, "group row menu: New Terminal… makes a terminal")
        gui.check("the terminal is in the group Work", lambda s: next(t for t in s["state"]["terminals"] if t["id"] == tid)["group"] == work, 5,
                  detail=lambda s: s["state"]["terminals"])
        run_in_terminal(gui, "the group's terminal", "GROUPTERM")
        dump(gui, "group-terminal")
    stage(gui, "terminal from a group row's menu", group_terminal)

    def empty_state_terminal():
        gui.click(gui.element("w:" + beta), count=2)
        attached(gui, "Beta")
        gui.check("Beta's empty state offers New terminal", lambda s: gui.find(s, "New terminal in this workspace", role="1"), 15)
        before = terminal_ids(gui.state())
        gui.click(gui.element("New terminal in this workspace", role="1"))
        time.sleep(0.8)
        if gui.state()["commandViewActive"]:
            gui.chord("enter")
        fresh_terminal(gui, before, "empty state's New terminal makes a terminal")
        run_in_terminal(gui, "the empty state's terminal", "BETATERM")
        dump(gui, "beta-terminal")
    stage(gui, "terminal from the empty state's button", empty_state_terminal)
    no_errors(gui, "at the end")
    dump(gui, "end")


if __name__ == "__main__":
    main(run)
