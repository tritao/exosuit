"""Baseline of the entropy plan's Step 0 marks (docs/design/entropy/baseline/BASELINE.md), with real input.

Every time comes from the editor's ConnectTimeline (src/workspace/client/ConnectTimeline.hx, the automation state's
`timeline`, milliseconds since the process began), so the driver's polling is not in it. Cases:
  startup   process start to first frame, by phase (startup-main ... app-built, first-frame);
  exohost      each exohost `machine` request to its reply (exohost-reply carries the milliseconds);
  expand    a click expanding an idle workspace (Gamma): start-requested to the first frame showing its rows;
  open      a double click opening an idle workspace (Beta): open-workspace to the first frame of its rows;
  back      a double click opening a running workspace (Alpha) again: the same;
  agent     New Agent Session (Claude, a fake TUI: tests/workspace-terminals/fake-claude-tui.py) from Alpha's row menu:
            new-agent-session to terminal-attached (the tab accepts input) and terminal-shown (its first screen).
The numbers go to results.json (checks named 'time ...') and the whole timeline to timeline.json."""
import json
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha", "beta", "gamma"], "open": "alpha", "appArgs": ["--open-workbench"],
           "env": {"EXOSUIT_CLAUDE_BIN": "{python}", "EXOSUIT_CLAUDE_SCRIPT": "{root}/tests/workspace-terminals/fake-claude-tui.py"}}
STARTUP = ["startup-main", "window-open", "app-constructed", "workspace-clients", "context-started", "app-built", "first-frame"]


def after(timeline, start, test):
    return next((i for i in range(start, len(timeline)) if test(timeline[i])), None)


def timeline(gui):
    return gui.state()["timeline"]


def record(gui, case, times, events=None):
    ok = bool(times) and all(v is not None for v in times.values())
    gui.results.append({"check": "time " + case, "ok": ok, "ms": times, "events": events or []})
    print("%s time %s %s" % ("PASS" if ok else "FAIL", case, times), flush=True)
    gui._save()


def span(gui, case, begin_test, end_tests, timeout=60):
    """Waits for the first event matching `begin_test` at or after `mark`, then each end event after it; records the times."""
    mark = len(timeline(gui))

    def look(s):
        tl = s["state"]["timeline"]
        begin = after(tl, mark, begin_test)
        if begin is None:
            return None
        ends = {label: after(tl, begin, test) for label, test in end_tests}
        return (begin, ends) if all(v is not None for v in ends.values()) else None
    return mark, look


def finish(gui, case, look, timeout=60):
    begin, ends = gui.wait(case, look, timeout)
    tl = timeline(gui)
    base = tl[begin]["t"]
    last = max(ends.values())
    record(gui, case, {label: tl[i]["t"] - base for label, i in ends.items()},
           ["%d %s %s %s" % (e["t"] - base, e["event"], e["workspace"][:8], e["detail"]) for e in tl[begin:last + 1]])


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 3 and gui.find(s, pattern="^w:"), 60)
    state = gui.state()
    alpha, beta, gamma = (ws(state, n)["id"] for n in ("Alpha", "Beta", "Gamma"))

    gui.step("startup: process start to first frame, by phase; the window's own workspace to its rows")
    gui.wait("Alpha's rows on screen", lambda s: after(s["state"]["timeline"], 0, lambda e: e["event"] == "rows-frame" and e["workspace"] == alpha), 60)
    tl = timeline(gui)
    phases = {}
    for name in STARTUP:
        index = after(tl, 0, lambda e: e["event"] == name)
        phases[name] = None if index is None else tl[index]["t"]
    rows = after(tl, 0, lambda e: e["event"] == "rows-frame" and e["workspace"] == alpha)
    phases["alpha-rows-frame"] = tl[rows]["t"]
    record(gui, "startup", phases)

    gui.step("expand: Gamma, idle, by a click on its expander")
    show_workbench(gui)
    _, look = span(gui, "expand", lambda e: e["event"] == "start-requested" and e["workspace"] == gamma,
                   [("rows-visible", lambda e: e["event"] == "rows-visible" and e["workspace"] == gamma),
                    ("rows-frame", lambda e: e["event"] == "rows-frame" and e["workspace"] == gamma)])
    row = gui.element("w:" + gamma)
    gui.click(row, fx=min(0.04, 10.0 / row["w"]))
    finish(gui, "expand", look)

    for case, name, wid in (("open", "Beta", beta), ("back", "Alpha", alpha)):
        gui.step("%s: %s by a double click" % (case, name))
        show_workbench(gui)
        _, look = span(gui, case, lambda e, w=wid: e["event"] == "open-workspace" and e["workspace"] == w,
                       [("connected", lambda e, w=wid: e["event"] == "status" and e["detail"] == "Workspace connected" and e["workspace"] == w),
                        ("rows-frame", lambda e, w=wid: e["event"] == "rows-frame" and e["workspace"] == w and e["detail"] == "own")])
        gui.click(gui.element("w:" + wid), count=2)
        attached(gui, name)
        show_workbench(gui)
        finish(gui, case, look)

    gui.step("agent: New Agent Session (Claude, terminal) from Alpha's row menu")
    show_workbench(gui)
    _, look = span(gui, "agent", lambda e: e["event"] == "new-agent-session",
                   [("terminal-attached", lambda e: e["event"] == "terminal-attached"),
                    ("terminal-shown", lambda e: e["event"] == "terminal-shown")])
    menu(gui, "w:" + alpha, "New Agent Session…")
    gui.wait("provider chooser", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text("Claude")
    time.sleep(0.3)
    gui.chord("enter")
    finish(gui, "agent", look, 30)

    tl = timeline(gui)
    record(gui, "exohost machine", {"reply %d" % n: int(e["detail"].split()[-2]) for n, e in
                                 enumerate([e for e in tl if e["event"] == "exohost-reply" and e["detail"].startswith("machine ok")])})
    with open(os.path.join(gui.out, "timeline.json"), "w") as f:
        json.dump(tl, f, indent=1)
    gui.shot("end")


if __name__ == "__main__":
    main(run)
