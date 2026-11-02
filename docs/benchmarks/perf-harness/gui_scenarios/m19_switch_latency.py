"""M19 Phase 7 budget: the time from real input to the first frame of the new group.

One workspace (Alpha) gets six contexts: its root, Work and four more groups, each with its own document tab. The
host keeps four inactive contexts attached (`warmLimit`), so toggling between two contexts is a warm switch and walking
the six in least-recently-used order is a cold one (the target was rebuilt from its snapshot). Each switch is made by a
click on a group row in the Workbench tree, by Ctrl+Shift+D (Goto Previous Workspace) or by the quick switch
(Ctrl+Shift+A, a name, Enter). The driver stamps every input it sends (sent.txt), the app stamps the switch and every
frame it renders (EXOSUIT_SWITCH_TRACE, switch.txt) on the same QueryPerformanceCounter clock; `switch_latency.py`
matches them and prints median/p90/max. Run through measure.ps1 -Drive; analyze with
`python -I docs/benchmarks/perf-harness/switch_latency.py runs/<name>/result`.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from gui_driver import qpc  # noqa: E402
from m19_folders import open_by_double_click
from m19_sessions_drag import by_name, create

FIXTURE = {"workspaces": ["alpha", "beta"], "open": None, "appArgs": ["--open-workbench"],
           "env": {"EXOSUIT_SWITCH_TRACE": "{result}\switch.txt", "NK_LATENCY_TRACE": "{result}\nk.txt"}}
GROUPS = ["Two", "Three", "Four", "Five"]
WARM = int(os.environ.get("SWITCH_WARM", "6"))


def tag(gui, text):
    gui.sent.append(("tag", qpc(), text))


def current(gui):
    return gui.state()["hostContext"]


def go(gui, how, row_key, name, expect, cold):
    """One switch by `how` (click, previous, quick); waits until the host shows `expect`; tags the input."""
    before = current(gui)
    tag(gui, "%s %s %s" % ("cold" if cold else "warm", how, expect))
    if how == "click":
        gui.click(gui.element(row_key), fy=0.5)
    elif how == "previous":
        gui.chord("ctrl+shift+d")
    else:
        quick_switch(gui, name)
    gui.check("%s switch (%s) reaches %s" % ("cold" if cold else "warm", how, name), lambda s: s["state"]["hostContext"] == expect, 8,
              detail=lambda s: (before, s["state"]["hostContext"], s["state"]["context"]))
    time.sleep(0.5)


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2 and gui.find(s, pattern="^w:"), 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    open_by_double_click(gui, alpha, "Alpha")
    show_workbench(gui)
    work = gui.wait("group Work", lambda s: next((g["id"] for g in s["state"]["groups"] if g["name"] == "Work"), None), 20)
    root_key = current(gui)

    gui.step("setup: four more groups, each entered and given a document")
    contexts = [("Alpha", None, root_key)]
    for name in GROUPS:
        show_workbench(gui)
        create(gui, "g:" + work, "New group", name, "groups")
    gui.shot("tree")
    open_file(gui, "a1.txt")
    contexts[0] = ("Alpha", None, root_key)
    for index, name in enumerate(["Work"] + GROUPS):
        gid = work if name == "Work" else by_name(gui.state(), "groups", name)["id"]
        show_workbench(gui)
        before = current(gui)
        gui.click(gui.element("g:" + gid))
        gui.check("a click on %s's row enters it" % name, lambda s: s["state"]["hostContext"] != before, 8,
                  detail=lambda s: (before, s["state"]["hostContext"], s["state"]["context"]))
        contexts.append((name, gid, current(gui)))
        if not tabs(gui.state()):
            open_file(gui, "a%d.txt" % (index % 3 + 1))
    gui.shot("setup-done")
    names = [c[0] for c in contexts]
    gui.step("contexts: " + ", ".join("%s=%s" % (c[0], c[2]) for c in contexts))

    def row_of(item):
        return "g:" + item[1] if item[1] else "w:" + alpha

    gui.step("warm: toggle between the last two contexts")
    a, b = contexts[-2], contexts[-1]
    for _ in range(WARM):
        go(gui, "click", row_of(a), a[0], a[2], False)
        go(gui, "click", row_of(b), b[0], b[2], False)
    for _ in range(WARM // 2):
        go(gui, "previous", None, b[0], a[2], False)
        go(gui, "previous", None, a[0], b[2], False)
    for _ in range(WARM // 2):
        go(gui, "quick", None, a[0], a[2], False)
        go(gui, "quick", None, b[0], b[2], False)

    gui.step("cold: walk the contexts in least-recently-used order")
    order = [c for c in contexts if c[2] not in (a[2], b[2])]
    for _ in range(2):  # two rounds through the six
        for item in order + [a, b]:
            go(gui, "click", row_of(item), item[0], item[2], True)
    gui.shot("done")


if __name__ == "__main__":
    main(run)
