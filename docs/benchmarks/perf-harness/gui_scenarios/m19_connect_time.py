"""M19 connect time: how long a workspace takes to show 'Workspace connected' and its catalog rows.

Times come from the editor's own ConnectTimeline (src/workspace/client/ConnectTimeline.hx, shown in the automation state as
`timeline`, milliseconds since the process began), so they do not include the driver's polling. Four cases, all real input:
  launch   the window's own workspace (Alpha, opened by the editor's start folder), from process start;
  expand   an idle workspace (Gamma) expanded in the tree: service start until its rows show;
  open     an idle workspace (Beta) opened by a double click: click until connected and rows;
  back     a running workspace (Alpha, resident since launch) opened again.
The numbers are written to results.json (checks named 'time ...', with the events between) and to timeline.json."""
import json
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_folders import healthy

FIXTURE = {"workspaces": ["alpha", "beta", "gamma"], "open": "alpha", "appArgs": ["--open-workbench"]}
# Budgets in milliseconds, generous on purpose: they catch a return of the old multi-second waits, not machine noise.
BUDGET = {"launch": 12000, "expand": 12000, "open": 12000, "back": 6000}


def after(timeline, start, test, last=False):
    """First event matching `test` at or after index `start`; its index, or None."""
    found = None
    for index in range(start, len(timeline)):
        if test(timeline[index]):
            if not last:
                return index
            found = index
    return found


def record(gui, case, timeline, begin, ends):
    """Writes the time from event index `begin` to each (label, index) in `ends` as a result, with the events in between."""
    base = timeline[begin]["t"]
    times = {label: timeline[i]["t"] - base for label, i in ends if i is not None}
    finish = max(times.values()) if len(times) == len(ends) and times else None
    ok = finish is not None and finish <= BUDGET[case]
    last = max([i for _, i in ends if i is not None] + [begin])
    gui.results.append({"check": "time " + case, "ok": ok, "ms": times, "budget_ms": BUDGET[case],
                        "events": ["%d %s %s %s" % (e["t"] - base, e["event"], e["workspace"][:8], e["detail"]) for e in timeline[begin:last + 1]
                                   if e["event"] not in ("suit-queued",)]})
    print("%s %s %s" % ("PASS" if ok else "FAIL", "time " + case, times), flush=True)
    gui._save()


def timeline(gui):
    return gui.state()["timeline"]


def connected_and_rows(gui, name, wid, begin_index, timeout=60):
    """Waits for 'connected' and the own catalog rows of workspace `wid`; returns (status index, rows index) in the timeline."""
    def look(s):
        tl = s["state"]["timeline"]
        status = after(tl, begin_index, lambda e: e["event"] == "status" and e["detail"] == "Workspace connected" and e["workspace"] == wid)
        rows = after(tl, begin_index, lambda e: e["event"] == "rows-visible" and e["workspace"] == wid and e["detail"] == "own")
        return (status, rows) if status is not None and rows is not None else None
    return gui.wait("%s connected with rows" % name, look, timeout)


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 3 and gui.find(s, pattern="^w:"), 60)
    state = gui.state()
    alpha, beta, gamma = (ws(state, n)["id"] for n in ("Alpha", "Beta", "Gamma"))

    gui.step("launch: the window's own workspace")
    status, rows = connected_and_rows(gui, "Alpha", alpha, 0)
    tl = timeline(gui)
    suit = after(tl, 0, lambda e: e["event"] == "suit-reply" and e["detail"] == "machine ok")
    ready = after(tl, 0, lambda e: e["event"] == "ready" and e["workspace"] == alpha)
    # t of the first event is the start of the window's life; count from index 0.
    record(gui, "launch", [{"t": 0, "event": "process", "workspace": "", "detail": ""}] + tl, 0,
           [("suit machine reply", None if suit is None else suit + 1), ("service ready", None if ready is None else ready + 1),
            ("connected", status + 1), ("rows", rows + 1)])

    gui.step("expand: Gamma, idle, started by expanding its row")
    show_workbench(gui)
    mark = len(timeline(gui))
    row = gui.element("w:" + gamma)
    gui.click(row, fx=min(0.04, 10.0 / row["w"]))
    def gamma_rows(s):
        tl = s["state"]["timeline"]
        requested = after(tl, mark, lambda e: e["event"] == "start-requested" and e["workspace"] == gamma)
        shown = after(tl, mark, lambda e: e["event"] == "rows-visible" and e["workspace"] == gamma)
        return (requested, shown) if requested is not None and shown is not None else None
    requested, shown = gui.wait("Gamma's rows", gamma_rows, 60)
    tl = timeline(gui)
    record(gui, "expand", tl, requested, [("rows", shown)])

    gui.step("open: Beta, idle, by a double click")
    mark = len(timeline(gui))
    gui.click(gui.element("w:" + beta), count=2)
    attached(gui, "Beta")
    healthy(gui, "after opening Beta")
    opened = gui.wait("open event", lambda s: after(s["state"]["timeline"], mark, lambda e: e["event"] == "open-workspace" and e["workspace"] == beta), 10)
    status, rows = connected_and_rows(gui, "Beta", beta, opened)
    record(gui, "open", timeline(gui), opened, [("connected", status), ("rows", rows)])

    gui.step("back: Alpha, running since launch")
    show_workbench(gui)
    mark = len(timeline(gui))
    gui.click(gui.element("w:" + alpha), count=2)
    opened = gui.wait("open event", lambda s: after(s["state"]["timeline"], mark, lambda e: e["event"] == "open-workspace" and e["workspace"] == alpha), 10)
    status, rows = connected_and_rows(gui, "Alpha", alpha, opened)
    record(gui, "back", timeline(gui), opened, [("connected", status), ("rows", rows)])

    with open(os.path.join(gui.out, "timeline.json"), "w") as f:
        json.dump(timeline(gui), f, indent=1)
    gui.shot("end")


if __name__ == "__main__":
    main(run)
