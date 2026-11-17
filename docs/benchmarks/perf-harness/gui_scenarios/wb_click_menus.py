"""Workbench design step 1, by real input: every workspace row has its full menu, open or idle; a click on a workspace
row opens it (the chevron only expands); New Agent Session on a workspace this window is not on goes there and starts a
session of the default provider (Claude) at once, with no dialog.

The provider is the fake Claude Code TUI (tests/workspace-terminals/fake-claude-tui.py); no real Claude is started."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

ELLIPSIS = "…"
FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"], "env": {
    "EXOSUIT_CLAUDE_BIN": "{python}", "EXOSUIT_CLAUDE_SCRIPT": "{root}/tests/workspace-terminals/fake-claude-tui.py",
    "FAKE_CLAUDE_LOG": "{out}/fake-claude.log", "PYTHONIOENCODING": "utf-8"}}

ROW_MENU = ["New Agent Session", "New Agent Session With" + ELLIPSIS, "New Terminal", "New Group", "Rename" + ELLIPSIS,
            "Attach Folder" + ELLIPSIS, "Detach Folder" + ELLIPSIS, "Open in New Window", "Remove from This Machine"]


def menu_labels(s):
    return [e["label"] for e in s["elements"] if e["role"] == "16"]


def chevron(gui, s, key):
    """The Expand or Collapse button inside the row `key`, or None."""
    rows = gui.find(s, key)
    if not rows:
        return None
    row = rows[0]
    return next((e for e in gui.find(s, pattern="^(Expand|Collapse)$", role="1")
                 if row["y"] <= e["y"] + e["h"] / 2 <= row["y"] + row["h"] and row["x"] <= e["x"] + e["w"] / 2 <= row["x"] + row["w"]), None)


def chevron_label(gui, s, key):
    found = chevron(gui, s, key)
    return found["label"] if found else None


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    beta = ws(gui.state(), "Beta")["id"]

    gui.step("an idle workspace's row has the full menu")
    gui.click(gui.element("w:" + beta), button="right")
    gui.check("Beta's (idle) row menu has every item", lambda s: all(item in menu_labels(s) for item in ROW_MENU), 5,
              detail=lambda s: menu_labels(s))
    gui.check("New Agent Session names the default provider", lambda s: gui.find(s, "Claude"), 2, detail=lambda s: menu_labels(s))
    gui.shot("idle-row-menu")
    gui.click(gui.element("New Agent Session With" + ELLIPSIS, role="16"))
    gui.check("New Agent Session With… offers the other providers and Change Folder…",
              lambda s: all(item in menu_labels(s) for item in ("Codex", "Pi", "Change Folder" + ELLIPSIS))
              and "Claude" not in menu_labels(s), 5, detail=lambda s: menu_labels(s))
    gui.shot("providers-submenu")
    gui.chord("esc")

    gui.step("a single click on Alpha's row opens it; the click does not expand it")
    before = chevron_label(gui, gui.snapshot(), "w:" + alpha)
    gui.click(gui.element("w:" + alpha))
    attached(gui, "Alpha")
    gui.check("Alpha is open in this window", lambda s: s["state"]["openWorkspace"] == alpha and s["state"]["workbench"]["openRow"] == "w:" + alpha, 5)
    gui.check("the click left Alpha's row %s" % ("collapsed" if before == "Expand" else "expanded"),
              lambda s: chevron_label(gui, s, "w:" + alpha) == before, 3, detail=lambda s: (chevron_label(gui, s, "w:" + alpha), s["state"]["workbench"]))
    gui.shot("click-opened")

    gui.step("the chevron alone expands and collapses; the empty workspace's row says so")
    button = gui.wait("Alpha's chevron", lambda s: chevron(gui, s, "w:" + alpha), 5)
    state = button["label"]
    gui.click(button)
    flipped = "Expand" if state == "Collapse" else "Collapse"
    gui.check("the chevron turned Alpha's row %s and kept it open" % ("collapsed" if state == "Collapse" else "expanded"),
              lambda s: chevron_label(gui, s, "w:" + alpha) == flipped and s["state"]["openWorkspace"] == alpha, 5)
    if flipped == "Expand":
        expand(gui, "w:" + alpha)
    gui.check("Alpha is empty, and its row says so", lambda s: s["state"]["workbenchEmptyState"] and gui.find(s, "s:none|" + alpha), 15,
              detail=lambda s: (s["state"]["workbench"], [e["label"] for e in s["elements"] if e["label"].startswith(("w:", "s:", "g:", "t:", "a:"))]))
    gui.shot("chevron-expanded-empty")

    gui.step("New Agent Session on Beta's row (idle, not open): the window goes to Beta and a Claude session starts at once")
    gui.click(gui.element("w:" + beta), button="right")
    gui.click(gui.element("New Agent Session", role="16"))
    attached(gui, "Beta", 60)

    def claude(s):
        return next((t for t in s["state"]["terminals"] if t.get("agentProvider") == "claude"), None)
    gui.check("a Claude session is in Beta's catalog", claude, 40,
              detail=lambda s: (s["state"]["terminals"], s["state"]["notifications"][-3:], s["state"]["workbench"]))
    gui.check("no dialog or prompt opened", lambda s: not s["state"]["commandViewActive"], 2)
    gui.check("its tab is in front", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 15,
              detail=lambda s: s["state"]["panes"])
    log = os.path.join(os.path.dirname(gui.out), "fake-claude.log")

    def started(_):
        try:
            with open(log, encoding="utf-8") as f:
                return "SIZE " in f.read()
        except OSError:
            return False
    gui.check("the fake Claude Code started in the terminal and got its size", started, 20)
    gui.type_text("typed-in-claude")

    def echoed(_):
        try:
            with open(log, encoding="utf-8") as f:
                return "typed-in-claude" in f.read().replace("TEXT ", "").replace(chr(10), "")
        except OSError:
            return False
    gui.check("what is typed reaches Claude Code", echoed, 10, detail=lambda s: open(log, encoding="utf-8").read()[-400:])
    gui.check("its row is shown under Beta's row, which opened for it", lambda s: claude(s) and gui.find(s, row_key("t", beta, claude(s)["id"]))
              and chevron_label(gui, s, "w:" + beta) == "Collapse", 10)
    gui.check("no error was reported", lambda s: not s["state"]["workspaceError"]
              and not [n for n in s["state"]["notifications"] if "rror" in n or "ould not" in n], 2,
              detail=lambda s: (s["state"]["workspaceError"], s["state"]["notifications"]))
    gui.shot("new-claude-session")


if __name__ == "__main__":
    main(run)
