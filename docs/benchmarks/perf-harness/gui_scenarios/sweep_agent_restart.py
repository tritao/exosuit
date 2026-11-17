"""Everyday sweep, an agent session kept: rename it, close its tab and reopen it from its row, quit the editor and
start it again, and continue the conversation with one prompt.

An editor (A) opens Alpha, makes an agent session from the workspace row's menu (the fake Codex,
tests/workspace-agents/fake-codex.py), asks a first question, renames the session, closes its tab and reopens it from
the row. A is closed (exosuit.quit, as closing it does) and the workspace service is stopped (what exohost's Quit sends), so nothing of the session
is left running. A new editor (R) on the same state must show the row (renamed), its tab and the first reply, and a
second prompt typed into it gets a second reply.

The run's own editor window stays open and idle (the harness ends the scenario when it exits); A and R are processes the
scenario starts and stops. Real input only; no real provider is started."""
import glob
import json
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep_common import *  # noqa: F401,F403
from gui_driver import Gui
from m19_two_windows_restart import close_window, command_line

FIXTURE = with_fake_agents({"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"]})


def run(gui):
    out_dir = os.path.dirname(gui.out)
    state_dir = os.path.join(out_dir, "agent-state")
    started = []

    def services():
        return running_services(state_dir)

    def editor(name, arguments):
        program = next(x for x in arguments if x.lower().endswith(".hl"))
        root = os.path.abspath(os.path.join(os.path.dirname(program), "..", "..", ".."))
        env = dict(os.environ)
        native = os.path.join(os.path.dirname(program), "native")
        libraries = [os.path.join(native, d) for d in sorted(os.listdir(native))] if os.path.isdir(native) else []
        libraries.append(os.path.dirname(arguments[0]))
        env["PATH"] = os.pathsep.join(libraries + [env.get("PATH", "")])
        os.makedirs(gui.out, exist_ok=True)
        log = open(os.path.join(gui.out, name + ".log"), "w")
        log.write(" ".join(arguments) + chr(10)); log.flush()
        process = subprocess.Popen(arguments, env=env, cwd=root, stdout=log, stderr=subprocess.STDOUT, creationflags=0x08000000)
        started.append(process.pid)
        return Gui(process.pid, os.path.join(gui.out, "window-" + name), max(10, gui.deadline - time.monotonic()), 30)

    def record(window):
        gui.results.extend(window.results)
        window.results = []

    a = r = None
    try:
        gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and gui.find(s, pattern="^w:"), 60)
        alpha = ws(gui.state(), "Alpha")["id"]
        launch = [x for x in command_line(gui.pid) if not x.startswith("--context=")]
        a = editor("a", launch)
        a.wait("workspace rows in A", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and a.find(s, pattern="^w:"), 40)
        open_by_double_click(a, alpha, "Alpha")
        show_workbench(a)
        made = {}

        def first():
            made["s"] = new_agent_from_menu(a, "w:" + alpha, "Alpha's row menu")
            ask(a, "first question", "first prompt")
        if not stage(a, "agent session: create, first prompt, reply", first):
            return
        sid = made["s"]

        def rename():
            a.click(a.element(open_row(a, "a", sid)), button="right")
            a.click(a.element(pattern="^Rename", role="16", timeout=4))
            time.sleep(0.6)
            dump(a, "rename-session")
            a.type_text("Planner")  # the old name is selected, so typing replaces it
            a.chord("enter")
            a.check("rename: the session is called Planner in the catalog", lambda s: next(x for x in s["state"]["agents"] if x["id"] == sid)["name"] == "Planner", 10,
                    detail=lambda s: s["state"]["agents"])
            a.check("rename: its tab is called Planner", lambda s: any(t["title"] == "Planner" for t in agent_tabs(s["state"])), 5,
                    detail=lambda s: s["state"]["panes"])
        stage(a, "rename the session from its row", rename)

        def close_reopen():
            count = len(titles(a.state()))
            focus_tree(a, open_row(a, "a", sid))
            palette(a, "Close Tab")
            a.check("close: the session's tab closed, the session stays", lambda s: not agent_tabs(s["state"]) and sid in agent_ids(s["state"]), 6,
                    detail=lambda s: (s["state"]["panes"], s["state"]["agents"]))
            a.click(a.element(open_row(a, "a", sid)))
            a.check("reopen: a click on its row opens the tab again", lambda s: (active_tab(s["state"]) or {}).get("kind") == "agent", 8,
                    detail=lambda s: s["state"]["panes"])
            a.check("reopen: the first reply is still in the transcript", lambda s: any("FAKE-REPLY: first question" in l for l in shown_transcript(s["state"])), 10,
                    detail=lambda s: active_tab(s["state"]))
            dump(a, "reopened")
        stage(a, "close the session's tab and reopen it from its row", close_reopen)

        gui.step("quit the editor and stop the workspace service")
        closed = close_window(a, a.pid)
        record(a)
        gui.results.append({"check": "quit: the editor closed", "ok": closed, "note": ""})
        stop_services(out_dir, state_dir)
        end = time.monotonic() + 15
        while services() and time.monotonic() < end:
            time.sleep(0.2)
        gui.results.append({"check": "quit: the workspace service stopped", "ok": not services(), "note": ""})

        gui.step("start the editor again")
        r = editor("r", launch)
        r.wait("the new editor attached to Alpha", lambda s: s["state"]["openWorkspace"] == alpha and s["state"]["groups"] is not None, 40)
        show_workbench(r)
        r.check("restart: the session's row is back, still called Planner", lambda s: r.find(s, open_row(r, "a", sid))
                and any(x["id"] == sid and x["name"] == "Planner" for x in s["state"]["agents"]), 20, detail=lambda s: s["state"]["agents"])
        r.check("restart: the session's tab is back", lambda s: agent_tabs(s["state"]), 10, detail=lambda s: s["state"]["panes"])
        if (active_tab(r.state()) or {}).get("kind") != "agent":
            r.click(r.element(open_row(r, "a", sid)))
        r.check("restart: the first reply is in the transcript", lambda s: any("FAKE-REPLY: first question" in l for l in shown_transcript(s["state"])), 20,
                detail=lambda s: active_tab(s["state"]))
        dump(r, "restarted")
        stage(r, "continue after the restart", lambda: ask(r, "second question", "second prompt after the restart"))
        r.check("restart: both replies are in the transcript", lambda s: sum("FAKE-REPLY:" in l for l in shown_transcript(s["state"])) == 2, 5,
                detail=lambda s: active_tab(s["state"]))
        no_errors(r, "after the restart")
        dump(r, "end")
    finally:
        for window in (a, r):
            if window is not None:
                record(window)
        for pid in started:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
        stop_services(out_dir, state_dir)


if __name__ == "__main__":
    main(run)
