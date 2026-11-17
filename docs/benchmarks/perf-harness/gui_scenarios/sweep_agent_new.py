"""Everyday sweep, agent sessions in a brand-new workspace and across two workspaces, end to end with real input.

New Workspace… makes Gamma (no restart). From Gamma's row menu: New Agent Session, which starts the default provider Codex (a fake,
tests/workspace-agents/fake-codex.py, answers "FAKE-REPLY: <prompt>"), the row and the tab appear, a prompt typed with
the keyboard and Enter gets its reply in the transcript. Then Alpha gets a session of its own the same way, and the
window switches Gamma, Alpha, Gamma: each shows its own session and conversation. No real provider is started."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep_common import *  # noqa: F401,F403

FIXTURE = with_fake_agents({"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"]})


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    show_workbench(gui)
    made = {}

    def new_workspace():
        gui.click(gui.element("n:new-workspace"))
        gui.wait("name prompt", lambda s: s["state"]["commandViewActive"], 5)
        gui.type_text("Gamma")
        gui.chord("enter")
        gui.check("New Workspace…: Gamma is made and open", lambda s: ws(s["state"], "Gamma") and s["state"]["openWorkspace"] == ws(s["state"], "Gamma")["id"], 20,
                  detail=lambda s: (s["state"]["machineWorkspaces"], s["state"]["openWorkspace"], s["state"]["notifications"][-3:]))
        made["gamma"] = ws(gui.state(), "Gamma")["id"]
        gui.check("Gamma can make an agent session", lambda s: (s["state"]["workbench"] or {}).get("canCreateAgent"), 20,
                  detail=lambda s: s["state"]["workbench"])
    if not stage(gui, "make a new workspace", new_workspace):
        return
    gamma = made["gamma"]

    def gamma_session():
        made["g"] = new_agent_from_menu(gui, "w:" + gamma, "Gamma's row menu")
        gui.check("the session belongs to Gamma's root", lambda s: next(a for a in s["state"]["agents"] if a["id"] == made["g"])["group"] in (None, ""), 5,
                  detail=lambda s: s["state"]["agents"])
        ask(gui, "hello gamma", "Gamma's session")
        dump(gui, "gamma-reply")
    stage(gui, "agent session in the new workspace: create, prompt, reply", gamma_session)

    def alpha_session():
        gui.click(gui.element("w:" + alpha), count=2)
        attached(gui, "Alpha")
        gui.check("Alpha: the window shows Alpha's (empty) catalog", lambda s: not s["state"]["agents"], 10, detail=lambda s: s["state"]["agents"])
        gui.check("Alpha: Gamma's conversation is not in front", lambda s: not any("hello gamma" in l for l in shown_transcript(s["state"])), 5,
                  detail=lambda s: active_tab(s["state"]))
        made["a"] = new_agent_from_menu(gui, "w:" + alpha, "Alpha's row menu")
        ask(gui, "hello alpha", "Alpha's session")
        dump(gui, "alpha-reply")
    stage(gui, "agent session in a second workspace", alpha_session)

    def switch(name, wid, own, other):
        gui.click(gui.element("w:" + wid), count=2)
        attached(gui, name)
        gui.check("back in %s: its session row is listed, the other's is not" % name,
                  lambda s: [a["id"] for a in s["state"]["agents"]] == [own] and gui.find(s, open_row(gui, "a", own)) and not gui.find(s, open_row(gui, "a", str(other))), 15,
                  detail=lambda s: s["state"]["agents"])
        if not shown_transcript(gui.state()):
            gui.click(gui.element(open_row(gui, "a", own)))
        gui.check("back in %s: its conversation is in front" % name,
                  lambda s: any(("FAKE-REPLY: hello " + name.lower()) in l for l in shown_transcript(s["state"])), 15,
                  detail=lambda s: s["state"]["panes"])
        gui.check("back in %s: no tab of the other workspace's session" % name,
                  lambda s: not any(("hello " + ("alpha" if name == "Gamma" else "gamma")) in l for t in agent_tabs(s["state"]) for l in t.get("lines", [])), 5,
                  detail=lambda s: s["state"]["panes"])

    stage(gui, "switch to Gamma", lambda: switch("Gamma", gamma, made.get("g"), made.get("a")))
    dump(gui, "gamma-again")
    stage(gui, "switch to Alpha", lambda: switch("Alpha", alpha, made.get("a"), made.get("g")))
    stage(gui, "switch to Gamma again", lambda: switch("Gamma", gamma, made.get("g"), made.get("a")))
    no_errors(gui, "at the end")
    dump(gui, "end")


if __name__ == "__main__":
    main(run)
