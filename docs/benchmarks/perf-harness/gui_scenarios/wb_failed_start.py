"""Workbench design Q11, by real input: an agent session whose CLI cannot start keeps its tab, shows the cause with
Retry, and never sends what was typed by itself. The Claude CLI is pointed at a file that does not exist."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"], "env": {
    "EXOSUIT_CLAUDE_BIN": "{out}/missing/claude.exe"}}


def strip(s):
    return next((e["label"] for e in s["elements"] if "Terminal unavailable" in e["label"] or "Not sent" in e["label"]), None)


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    gui.click(gui.element("w:" + alpha))
    attached(gui, "Alpha")

    gui.step("New Agent Session with a Claude CLI that is missing; type at once")
    gui.click(gui.element("w:" + alpha), button="right")
    gui.click(gui.element("New Agent Session", role="16"))
    gui.type_text("never-send-this")
    gui.check("the tab stays open", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 10,
              detail=lambda s: s["state"]["panes"])
    gui.check("the strip shows the cause", strip, 20, detail=lambda s: ([e["label"] for e in s["elements"]][-40:], s["state"]["terminals"]))
    gui.check("it offers Retry", lambda s: gui.find(s, "Retry", role="1"), 5)
    gui.check("the typed text is kept, marked not sent", lambda s: "Not sent" in (strip(s) or "") and "never-send-this" in (strip(s) or ""), 5,
              detail=lambda s: strip(s))
    gui.results.append({"check": "strip text: %s" % strip(gui.snapshot()), "ok": True, "note": ""})
    gui.shot("failed-start")
    gui.click(gui.element("Retry", role="1"))
    gui.check("after Retry the text is still shown as not sent, and was not sent", lambda s: "never-send-this" in (strip(s) or ""), 20,
              detail=lambda s: strip(s))
    gui.check("after Retry the strip names the real cause again", lambda s: "CLI was not found" in (strip(s) or ""), 20,
              detail=lambda s: strip(s))
    gui.results.append({"check": "after Retry: %s" % strip(gui.snapshot()), "ok": True, "note": ""})
    gui.shot("after-retry")


if __name__ == "__main__":
    main(run)
