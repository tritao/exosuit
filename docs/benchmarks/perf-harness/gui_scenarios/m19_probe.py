"""Exploration: dumps element labels and state after a few harmless clicks. Not a check."""
import json
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import open_by_double_click

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"]}


def dump(gui, name):
    with open(os.path.join(gui.out, name + ".json"), "w") as f:
        json.dump(gui.snapshot(), f, indent=1)
    gui.shot(name)


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    time.sleep(1)
    show_workbench(gui)
    dump(gui, "a-opened")
    gui.click(gui.element("g:work"), button="right")
    time.sleep(0.6)
    dump(gui, "b-group-menu")
    gui.chord("esc")
    gui.click(gui.element("w:" + alpha), button="right")
    time.sleep(0.6)
    dump(gui, "c-ws-menu")
    gui.chord("esc")
    gui.check("explored", lambda s: True)


if __name__ == "__main__":
    main(run)
