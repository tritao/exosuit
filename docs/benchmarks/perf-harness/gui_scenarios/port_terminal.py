"""G09, port against baseline: a terminal tab's output, typing, scrolling and selection (F1 on the port).

The Workbench's New terminal opens a PowerShell terminal of Alpha (a workspace terminal, through its service).

  typing     `echo port-check` one key at a time, Enter: the output line shows. On the port the rows rebuild in the
             pane's own scope, with no root build (F1).
  output     a command prints 400 numbered lines; the last one shows.
  scroll     wheel notches over the terminal, up then down (scrollback).
  select     a drag across two rows of the terminal (pointer selection).
  idle       nothing for 4 s: the shell's cursor blink is all that may draw.
terminal_echo.py measures keystroke -> echo with real input; this one compares frames and allocations."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403

FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha", "appArgs": ["--open-workbench"]})


def terminal_area(gui):
    """A point in the middle of the terminal tab's rows: below its tab, right of the side bar."""
    snap = gui.snapshot()
    v = snap["viewport"]
    return v["width"] * 0.6, v["height"] * 0.5


def run(gui):
    attached(gui, "Alpha")
    check_traced(gui)
    show_workbench(gui)
    before = terminal_ids(gui.state())
    gui.click(gui.element("New terminal", role="1"))
    fresh_terminal(gui, before, "New terminal adds a terminal to the catalog")
    gui.check("the terminal's tab is in front", lambda s: (active_tab(s["state"]) or {}).get("kind") == "terminal", 10,
              detail=lambda s: s["state"]["panes"])
    gui.check("the shell prints its prompt", lambda s: "PS " in terminal_shown(s["state"]) or ">" in terminal_shown(s["state"]), 30,
              detail=lambda s: terminal_shown(s["state"])[-300:])
    x, y = terminal_area(gui)
    gui.call("exosuit.ui.activate", {"x": x, "y": y, "button": "left", "count": 1})
    time.sleep(0.8)

    begin(gui, "typing")
    type_keys(gui, "echo port-check", 0.12)
    key(gui, "enter", 0.8)
    begin(gui, "after-typing")
    gui.check("the echoed line shows", lambda s: terminal_shown(s["state"]).count("port-check") >= 2, 10,
              detail=lambda s: terminal_shown(s["state"])[-300:])

    begin(gui, "output")
    gui.call("exosuit.ui.type", {"text": '1..400 | % { "port-line-$_" }'})
    key(gui, "enter", 0.1)
    time.sleep(3)
    begin(gui, "after-output")
    gui.check("the last of 400 lines shows", lambda s: "port-line-400" in terminal_shown(s["state"]), 15,
              detail=lambda s: terminal_shown(s["state"])[-300:])

    begin(gui, "scroll")
    for notches in (3, 3, 3, 3, -3, -3, -3, -3):
        wheel(gui, x, y, notches)
        time.sleep(0.2)
    begin(gui, "select")
    mark(gui, "drag")
    gui.call("exosuit.ui.drag", {"from": {"x": x - 150, "y": y - 20}, "to": {"x": x + 150, "y": y + 20}})
    time.sleep(0.6)
    gui.shot("selection")
    idle(gui, "idle", 4)
    end(gui)
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
