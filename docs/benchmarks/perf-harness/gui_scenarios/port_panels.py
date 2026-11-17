"""G14 (and the panel half of G13), port against baseline: the right panel's tabs, Source Control picking up a change
made outside, the bottom panel, and the Workbench tree's keyboard expansion.

Alpha is a git repository with its three files committed. The window starts with the Workbench in the side bar and
Files, Search and Changes in the right panel.

  tabs       clicks on Search, Changes and Files (role 18), 0.6 s apart.
  scm        a1.txt is changed from outside; the Changes tab lists it (on the port SCM status changes schedule a host
             frame themselves, U3/T6).
  bottom     Toggle Bottom Panel opens the bottom panel and closes it again.
  workbench  Alpha's row is selected; Right expands it, Left collapses it (T11), as a person does with the keyboard.
  idle       nothing for 4 s."""
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from port_common import *  # noqa: F401,F403


def prepare(out, root, env, exohost):
    folder = os.path.join(out, "fixture", "alpha")
    git = ["git", "-c", "user.name=port", "-c", "user.email=port@example.invalid", "-c", "commit.gpgsign=false"]
    for command in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]):
        subprocess.run(git + command, cwd=folder, check=True, capture_output=True, timeout=30, creationflags=0x08000000)


FIXTURE = port_fixture({"workspaces": ["alpha"], "open": "alpha", "appArgs": ["--open-workbench"]})


def region(s, top, bottom):
    """Labels of elements whose middle is between `top` and `bottom` (fractions of the viewport's height)."""
    height = s["viewport"]["height"]
    return sorted(set(e["label"] for e in s["elements"] if top * height <= e["y"] + e["h"] / 2 <= bottom * height))


def right_side(s):
    width = s["viewport"]["width"]
    return [e for e in s["elements"] if e["x"] > width * 0.6]


def run(gui):
    attached(gui, "Alpha")
    alpha = ws(gui.state(), "Alpha")["id"]
    check_traced(gui)
    gui.check("the right panel shows Files, Search and Changes", lambda s: all(gui.find(s, name, role="18") for name in ("Files", "Search", "Changes")), 15)
    time.sleep(1)

    begin(gui, "tabs")
    for name in ("Search", "Changes", "Files"):
        click(gui, gui.element(name, role="18"))
        time.sleep(0.6)
    click(gui, gui.element("Changes", role="18"))
    time.sleep(1.0)

    begin(gui, "scm")
    # A repository must be trusted before its Git changes are read ("Trust repositories to enable Git changes."): that is
    # a person's click, so the scenario clicks the row's Trust button, then waits for the repository to leave "Restricted".
    trust = gui.element(None, pattern=r"^Trust repository ", role="1", timeout=15)
    click(gui, trust)
    gui.check("trusting the repository lifts the restriction", lambda s: not gui.find(s, pattern=r"^Trust repository ") and not gui.find(s, "Restricted"), 10,
              detail=lambda s: [e["label"][:60] for e in right_side(s)][:30])
    mark(gui, "change a1.txt outside")
    with open(os.path.join(os.path.dirname(gui.out), "fixture", "alpha", "a1.txt"), "a") as f:
        f.write("changed outside the editor\n")
    listed = lambda s: any(e["label"].endswith("a1.txt") for e in right_side(s))
    # The Changes group starts collapsed on the baseline (its row shows only the count 1): open it, unless it is open.
    gui.check("the Changes group counts the change made outside", lambda s: listed(s) or any(e["label"] == "1" for e in right_side(s)), 20)
    if not listed(gui.snapshot()):
        click(gui, gui.element(None, pattern=r"^group:", timeout=5), fx=0.3)
    gui.check("Changes lists a1.txt after a change made outside", listed, 10,
              detail=lambda s: [e["label"][:60] for e in right_side(s)][:30])
    gui.shot("changes")

    begin(gui, "bottom")
    lower = region(gui.snapshot(), 0.6, 0.97)
    click(gui, gui.element("Toggle Bottom Panel", role="1"))
    gui.check("Toggle Bottom Panel opens the bottom panel", lambda s: region(s, 0.6, 0.97) != lower, 4,
              detail=lambda s: region(s, 0.6, 0.97))
    gui.shot("bottom-panel")
    click(gui, gui.element("Toggle Bottom Panel", role="1"))
    gui.check("pressing it again closes it", lambda s: region(s, 0.6, 0.97) == lower, 4,
              detail=lambda s: (lower, region(s, 0.6, 0.97)))

    begin(gui, "workbench")
    show_workbench(gui)
    focus_tree(gui, "w:" + alpha)
    expand_state = lambda s: (s["state"]["workbench"] or {}).get("openRowExpanded")
    first = expand_state(gui.snapshot())
    key(gui, "left" if first else "right", 0.6)
    gui.check("the keyboard toggles Alpha's row (%s)" % ("Left collapses" if first else "Right expands"),
              lambda s: expand_state(s) == (not first), 4, detail=lambda s: (s["state"]["workbench"] or {}).get("openRowChildren"))
    key(gui, "right" if first else "left", 0.6)
    gui.check("and back", lambda s: expand_state(s) == first, 4)
    idle(gui, "idle", 4)
    end(gui)
    close_window(gui)


if __name__ == "__main__":
    run_port(run)
