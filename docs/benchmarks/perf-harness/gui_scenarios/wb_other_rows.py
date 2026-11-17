"""Workbench design step 6, by real input: actions on another workspace's rows run in that workspace without moving the
window. With Alpha open, New Group, New Terminal and Rename Terminal… on Beta's rows act in Beta while the window stays
on Alpha (the new terminal's tab opens here); New Agent Session on Beta's row then takes the window to Beta.

The provider is the fake Claude Code TUI (tests/workspace-terminals/fake-claude-tui.py); no real Claude is started."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

ELLIPSIS = "…"
FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"], "env": {
    "EXOSUIT_CLAUDE_BIN": "{python}", "EXOSUIT_CLAUDE_SCRIPT": "{root}/tests/workspace-terminals/fake-claude-tui.py",
    "FAKE_CLAUDE_LOG": "{out}/fake-claude.log", "PYTHONIOENCODING": "utf-8"}}


def tabs(s):
    return [t for p in s["state"]["panes"] for t in p["tabs"]]


def rows_of(gui, s, kind, workspace):
    return [e["label"] for e in gui.find(s, pattern="^%s:%s\\|" % (kind, workspace))]


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    beta = ws(gui.state(), "Beta")["id"]

    gui.step("open Alpha")
    gui.click(gui.element("w:" + alpha))
    attached(gui, "Alpha")
    stays = lambda s: s["state"]["openWorkspace"] == alpha  # noqa: E731

    gui.step("New Group on Beta's row makes the group in Beta; the window stays on Alpha")
    menu(gui, "w:" + beta, "New Group")
    time.sleep(0.8)
    gui.type_text("Remote")
    gui.chord("enter")
    gui.check("a group row appears under Beta", lambda s: rows_of(gui, s, "g", beta), 30,
              detail=lambda s: (s["state"]["workbench"], s["state"]["notifications"][-3:]))
    gui.check("the window is still on Alpha", stays, 2, detail=lambda s: s["state"]["openWorkspace"])
    gui.shot("beta-group")

    gui.step("New Terminal on Beta's row makes a terminal in Beta, its tab here; the window stays on Alpha")
    before = len(tabs(gui.snapshot()))
    menu(gui, "w:" + beta, "New Terminal")
    gui.check("a terminal row appears under Beta", lambda s: rows_of(gui, s, "t", beta), 30,
              detail=lambda s: (s["state"]["workbench"], s["state"]["notifications"][-3:]))
    gui.check("its tab opened in this window", lambda s: len(tabs(s)) == before + 1, 15, detail=lambda s: s["state"]["panes"])
    gui.check("the window is still on Alpha", stays, 2, detail=lambda s: s["state"]["openWorkspace"])
    gui.check("Alpha's own lists did not get Beta's terminal", lambda s: not s["state"]["terminals"], 2,
              detail=lambda s: s["state"]["terminals"])
    gui.shot("beta-terminal")

    gui.step("Rename Terminal… on Beta's terminal row renames it in Beta; the window stays on Alpha")
    row = rows_of(gui, gui.snapshot(), "t", beta)[0]
    menu(gui, row, "Rename Terminal" + ELLIPSIS)
    time.sleep(0.8)
    gui.type_text("remote-shell")  # the current name is selected, so typing replaces it
    gui.chord("enter")
    gui.check("its tab is called remote-shell", lambda s: "remote-shell" in [t["title"] for t in tabs(s)], 15,
              detail=lambda s: [t["title"] for t in tabs(s)])
    gui.check("the window is still on Alpha", stays, 2, detail=lambda s: s["state"]["openWorkspace"])
    gui.shot("beta-renamed")

    gui.step("New Agent Session on Beta's row takes the window to Beta")
    menu(gui, "w:" + beta, "New Agent Session")
    attached(gui, "Beta", 60)
    gui.check("a Claude session is in Beta's catalog", lambda s: any(t.get("agentProvider") == "claude" for t in s["state"]["terminals"]), 40,
              detail=lambda s: (s["state"]["terminals"], s["state"]["notifications"][-3:]))
    gui.check("Beta's renamed terminal is in its catalog", lambda s: any(t["name"] == "remote-shell" for t in s["state"]["terminals"]), 10,
              detail=lambda s: s["state"]["terminals"])
    gui.check("no error was reported", lambda s: not s["state"]["workspaceError"]
              and not [n for n in s["state"]["notifications"] if "rror" in n or "ould not" in n], 2,
              detail=lambda s: (s["state"]["workspaceError"], s["state"]["notifications"]))
    gui.shot("beta-session")


if __name__ == "__main__":
    main(run)
