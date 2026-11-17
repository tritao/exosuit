"""Helpers of the everyday-flow sweep scenarios (sweep_*.py): stages that do not end the run when one fails, dumps of
what the window showed, and the paths a user takes to make and find things. Real input only."""
import glob
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import menu, open_by_double_click  # noqa: F401
from gui_driver import Exohost  # noqa: E402

ELLIPSIS = "…"


def service_pid_alive(pid):
    out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True, creationflags=0x08000000).stdout
    return str(pid) in out


def running_services(state_dir):
    """The pids of the workspace services under `state_dir` that still run (the last start each service.log names)."""
    pids = []
    for log in glob.glob(os.path.join(state_dir, "workspaces", "*", "service.log")):
        try:
            started = [int(line.rsplit(", pid ", 1)[1]) for line in open(log, encoding="utf-8", errors="replace")
                       if "service starting: generation " in line]
        except (OSError, ValueError):
            continue
        if started and service_pid_alive(started[-1]):
            pids.append(started[-1])
    return pids


def stop_services(out_dir, state_dir):
    """Asks the run's exohost (exohost-home in the run folder) to stop every running workspace service of the run (what
    exohost's Quit sends over each service's link)."""
    exohost = Exohost(os.path.join(out_dir, "exohost-home"))
    for pid in running_services(state_dir):
        try:
            exohost.request({"op": "service-stop", "pid": pid})
        except Failure:
            pass


def dump(gui, name, shot=True):
    """Writes the labelled elements (one per line) and the state of the current snapshot, and a screenshot."""
    snap = gui.snapshot()
    with open(os.path.join(gui.out, name + ".txt"), "w", encoding="utf-8") as f:
        f.write("viewport %s focus %r\n" % (snap["viewport"], snap.get("focus")))
        for e in sorted(snap["elements"], key=lambda e: (e["y"], e["x"])):
            f.write("%-3s %6.0f %6.0f %6.0f %5.0f  %s\n" % (e["role"], e["x"], e["y"], e["w"], e["h"], e["label"]))
    state = dict(snap["state"])
    state.pop("timeline", None)
    with open(os.path.join(gui.out, name + ".state.json"), "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1)
    if shot:
        gui.shot(name)
    return snap


def stage(gui, name, action):
    """Runs one flow; a Failure in it is recorded as a failed check (with a dump), menus and prompts are closed, and the
    run goes on with the next flow."""
    gui.step(name)
    try:
        action()
        return True
    except Failure as failure:
        gui.results.append({"check": name, "ok": False, "note": str(failure)})
        print("FAIL " + name + " -- " + str(failure), flush=True)
        try:
            dump(gui, "failed-" + "".join(c if c.isalnum() else "-" for c in name)[:40])
            gui.release_all()
            gui.chord("esc")
            gui.chord("esc")
        except Failure:
            pass
        return False


def no_errors(gui, label):
    gui.check(label + ": no error reported", lambda s: not s["state"]["notifications"] and not s["state"]["workspaceError"], 1,
              detail=lambda s: (s["state"]["workspaceError"], s["state"]["notifications"]))


def kinds(state):
    return [t["kind"] for p in state["panes"] for t in p["tabs"]]


def titles(state):
    return [t["title"].replace("\\", "/").split("/")[-1] for p in state["panes"] for t in p["tabs"]]


def active_title(state):
    pane = state["panes"][0] if state["panes"] else None
    if not pane or pane["active"] is None or pane["active"] < 0 or pane["active"] >= len(pane["tabs"]):
        return None
    return pane["tabs"][pane["active"]]["title"].replace("\\", "/").split("/")[-1]


def terminal_ids(state):
    return {t["id"] for t in state["terminals"]}


def fresh_terminal(gui, before, what, timeout=20):
    """Checks that a terminal not in `before` appears in the catalog; returns its id or None."""
    found = []

    def look(s):
        new = [t["id"] for t in s["state"]["terminals"] if t["id"] not in before]
        if new:
            found.append(new[0])
        return bool(new)
    gui.check(what, look, timeout, detail=lambda s: (s["state"]["terminals"], s["state"]["notifications"][-3:], s["state"]["commandViewActive"]))
    return found[0] if found else None


def focus_tree(gui, row_key):
    """Keyboard focus on a tree row without opening anything: its menu, then Escape."""
    gui.click(gui.element(row_key), button="right")
    time.sleep(0.4)
    gui.chord("escape")


def palette(gui, text):
    """Ctrl+Shift+P, type, Enter."""
    gui.chord("ctrl+shift+p")
    gui.wait("command palette open", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text(text)
    time.sleep(0.5)
    gui.chord("enter")


# Agent sessions with a fake provider: Codex, made the default provider, starts tests/workspace-agents/fake-codex.py,
# which answers every prompt with "FAKE-REPLY: <prompt>" at once. No real Claude or Codex is ever started.
FAKE_AGENT_FIXTURE = {"settings": {"workbench/agents/session_mode": "integrated", "workbench/agents/default_provider": "codex"}, "env": {
    "EXOSUIT_CODEX_BIN": "{python}", "EXOSUIT_CODEX_SCRIPT": "{root}/tests/workspace-agents/fake-codex.py",
    "EXOSUIT_CODEX_PROXY_LAUNCHER": "{root}/scripts/run-codex-proxy.py", "FAKE_CODEX_REPLY": "1"}}


def with_fake_agents(fixture):
    merged = dict(fixture)
    merged["settings"] = dict(fixture.get("settings", {}), **FAKE_AGENT_FIXTURE["settings"])
    merged["env"] = dict(fixture.get("env", {}), **FAKE_AGENT_FIXTURE["env"])
    return merged


def agent_ids(state):
    return {a["id"] for a in state["agents"]}


def agent_tabs(state):
    return [t for p in state["panes"] for t in p["tabs"] if t["kind"] == "agent"]


def active_tab(state):
    pane = state["panes"][0] if state["panes"] else None
    if not pane or pane["active"] is None or pane["active"] < 0 or pane["active"] >= len(pane["tabs"]):
        return None
    return pane["tabs"][pane["active"]]


def shown_transcript(state):
    """The transcript of the agent tab in front (one "kind: text" line per item), or []."""
    tab = active_tab(state)
    return tab.get("lines", []) if tab and tab["kind"] == "agent" else []


def terminal_shown(state):
    tab = active_tab(state)
    return "\n".join(tab.get("lines", [])) if tab and tab["kind"] == "terminal" else ""


def started_agent(gui, before, where):
    """New Agent Session was chosen: checks the new session (the fake Codex), its row and its tab; returns its id."""
    found = []

    def look(s):
        new = [a["id"] for a in s["state"]["agents"] if a["id"] not in before]
        found.extend(new[:1])
        return bool(new)
    gui.check(where + ": a new agent session is in the catalog", look, 30,
              detail=lambda s: (s["state"]["agents"], s["state"]["notifications"][-3:], s["state"]["workbench"]))
    if not found:
        return None
    sid = found[0]
    gui.check(where + ": its row appears in the Workbench", lambda s: gui.find(s, open_row(gui, "a", sid)), 10)
    gui.check(where + ": its tab opens in front", lambda s: (active_tab(s["state"]) or {}).get("kind") == "agent", 10,
              detail=lambda s: s["state"]["panes"])
    return sid


def new_agent_from_menu(gui, row_key, where):
    before = agent_ids(gui.state())
    menu(gui, row_key, "New Agent Session")
    return started_agent(gui, before, where)


def ask(gui, prompt, where, timeout=30):
    """Clicks the prompt field of the agent tab in front, types `prompt`, Enter; checks the fake's reply in the transcript."""
    gui.check(where + ": the session is ready for a prompt", lambda s: gui.find(s, "Codex prompt"), 30,
              detail=lambda s: (active_tab(s["state"]), s["state"]["notifications"][-3:]))
    gui.click(gui.element("Codex prompt"))
    time.sleep(0.3)
    gui.type_text(prompt)
    gui.chord("enter")
    reply = "FAKE-REPLY: " + prompt
    gui.check(where + ": the prompt shows in the transcript", lambda s: any(prompt in l for l in shown_transcript(s["state"])
              if l.startswith("userMessage")), timeout, detail=lambda s: (active_tab(s["state"]), s["state"]["notifications"][-3:]))
    gui.check(where + ": the reply %r shows in the transcript" % reply, lambda s: any(reply in l for l in shown_transcript(s["state"])),
              timeout, detail=lambda s: (active_tab(s["state"]), s["state"]["notifications"][-3:]))


def run_in_terminal(gui, where, token):
    """Types a command into the terminal tab in front and checks its output (`token` appears only in the output)."""
    gui.check(where + ": the terminal's tab is in front", lambda s: (active_tab(s["state"]) or {}).get("kind") == "terminal", 10,
              detail=lambda s: s["state"]["panes"])
    gui.check(where + ": the shell prints its prompt", lambda s: "PS " in terminal_shown(s["state"]) or ">" in terminal_shown(s["state"]), 20,
              detail=lambda s: terminal_shown(s["state"])[-300:])
    time.sleep(0.5)
    gui.type_text('echo ("%s-" + (6*7))' % token)
    gui.chord("enter")
    gui.check(where + ": the command's output %s-42 shows" % token, lambda s: (token + "-42") in terminal_shown(s["state"]), 20,
              detail=lambda s: terminal_shown(s["state"])[-400:])
