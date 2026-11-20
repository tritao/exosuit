"""Driven over the control plane only: a window opens a workspace, gets a new agent session and a new terminal, and is
typed into, with the real mouse and keyboard untouched (docs/design/exosuitctl/TDD-exosuit-ctl.md §8.4, G8).

- `exosuit.agent.create` makes a session as the workspace row's New Agent Session does (the default provider, Claude,
  here the fake Claude Code TUI tests/workspace-terminals/fake-claude-tui.py, which logs every key it receives);
- `exosuit.ui.type` and `exosuit.ui.key` type into it through the window's own input queue, and the fake logs the text;
- `exosuit.terminal.create`, `exosuit.terminal.send` and `exosuit.terminal.read` run `echo` in a shell and read the
  rendered screen back as text;
- the pointer is where it was before the run, and the foreground window did not change."""
import ctypes
import ctypes.wintypes as wt
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"], "env": {
    "EXOSUIT_CLAUDE_BIN": "{python}", "EXOSUIT_CLAUDE_SCRIPT": "{root}/tests/workspace-terminals/fake-claude-tui.py",
    "FAKE_CLAUDE_LOG": "{out}/fake-claude.log", "PYTHONIOENCODING": "utf-8"}}


def pointer():
    p = wt.POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(p))
    return p.x, p.y


def read_rows(gui, terminal):
    return "\n".join(gui.call("exosuit.terminal.read", {"id": terminal})["rows"])


def run(gui):
    fake_log = os.path.join(os.path.dirname(gui.out), "fake-claude.log")
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1, 60)
    alpha = ws(gui.state(), "Alpha")["id"]

    gui.step("open Alpha over the control plane")
    gui.open_workspace(alpha)
    attached(gui, "Alpha")
    started_at, foreground = pointer(), ctypes.windll.user32.GetForegroundWindow()

    gui.step("a new agent session, as New Agent Session on Alpha's row makes it")
    session = gui.call("exosuit.agent.create", {"workspace": alpha})
    gui.check("the call answered with the new session's terminal", lambda s: session.get("kind") == "terminal" and session.get("id"), 1,
              detail=lambda s: session)
    gui.check("the fake Claude is up in it", lambda s: "default" in read_rows(gui, session["id"]) or os.path.exists(fake_log), 20,
              detail=lambda s: read_rows(gui, session["id"]))
    gui.shot("session")

    gui.step("type into the session through the window's input queue")
    gui.type_text("typed by exosuitctl")
    gui.chord("enter")
    gui.check("the session received the typed text and Enter", lambda s: os.path.exists(fake_log)
              and "typed by exosuitctl" in open(fake_log, encoding="utf-8").read().replace("TEXT ", "").replace("\n", "")
              and "ENTER" in open(fake_log, encoding="utf-8").read(), 10,
              detail=lambda s: open(fake_log, encoding="utf-8").read()[-400:] if os.path.exists(fake_log) else "no log")
    gui.check("the session's screen shows the text", lambda s: "typed by exosuitctl" in read_rows(gui, session["id"]), 10,
              detail=lambda s: read_rows(gui, session["id"]))
    gui.shot("session-typed")

    gui.step("a new terminal; send a command and read the screen back")
    terminal = gui.call("exosuit.terminal.create", {"workspace": alpha})
    gui.check("the call answered with the new terminal", lambda s: terminal.get("kind") == "terminal" and terminal.get("id") != session["id"], 1,
              detail=lambda s: terminal)
    gui.wait("the shell's prompt", lambda s: read_rows(gui, terminal["id"]).strip(), 20)
    gui.call("exosuit.terminal.send", {"id": terminal["id"], "text": "echo control-plane-%d\r" % 42})
    gui.check("the shell ran the command and printed its output", lambda s: read_rows(gui, terminal["id"]).count("control-plane-42") >= 2, 15,
              detail=lambda s: read_rows(gui, terminal["id"]))
    listed = gui.call("exosuit.terminals.list")["terminals"]
    gui.check("terminals.list has both, open", lambda s: {session["id"], terminal["id"]} <= {t["id"] for t in listed if t.get("open")}, 1,
              detail=lambda s: listed)
    gui.shot("terminal")

    gui.check("the real pointer did not move", lambda s: pointer() == started_at, 1, detail=lambda s: (started_at, pointer()))
    gui.check("the foreground window did not change", lambda s: ctypes.windll.user32.GetForegroundWindow() == foreground, 1)


if __name__ == "__main__":
    main(run)
