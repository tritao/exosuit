"""M19 new workspace: right after New Workspace… the window can add a terminal, an agent session and a group.

Real input: a click on the New Workspace… row, the name, Enter; then nothing for a few seconds while the snapshot is
watched (so a state that only appears after more input is seen as late); then the workspace row's menu and New Terminal.
Writes result/trace.json: every change of what the Workbench could do, with the seconds since the name was entered."""
import json
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha"], "folders": ["extra"], "open": "alpha", "appArgs": ["--open-workbench"]}
ELLIPSIS = "…"


def view(gui, snap):
    s = snap["state"]
    w = s.get("workbench") or {}
    return {"open": s["openWorkspace"], "status": s["workspaceStatus"], "error": s["workspaceError"],
            "catalog": w.get("catalog"), "terminal": w.get("canCreateTerminal"), "agent": w.get("canCreateAgent"),
            "groups": w.get("canEditGroups"), "rowsLive": w.get("openRowsLive"), "openRow": w.get("openRow"),
            "served": w.get("servedWorkspace"), "empty": s.get("workbenchEmptyState"), "connecting": not w.get("openRowsLive"),
            "selected": w.get("selected"), "tree": bool(gui.find(snap, "n:new-workspace")),
            "catalogError": w.get("catalogError"), "agentError": w.get("agentError"),
            "emptyRow": bool(gui.find(snap, pattern=r"^s:none\|"))}


def watch(gui, name, seconds, started, done=None):
    """Records each change of `view` for `seconds` without sending input; stops early once `done(view)` held for a second."""
    trace, last, end, held = [], None, time.monotonic() + seconds, None
    while time.monotonic() < end:
        try:
            now = view(gui, gui.snapshot(2))
        except Failure:
            break
        if now != last:
            trace.append({"at": round(time.monotonic() - started, 2), **now})
            last = now
        if done is not None and done(now):
            held = held or time.monotonic()
            if time.monotonic() - held > 1.0:
                break
        else:
            held = None
        time.sleep(0.05)
    with open(os.path.join(gui.out, name + ".json"), "w") as f:
        json.dump(trace, f, indent=1)
    return trace, last


def create(gui, name):
    show_workbench(gui)
    gui.click(gui.element("n:new-workspace"))
    gui.wait("name prompt", lambda s: s["state"]["commandViewActive"], 5)
    gui.type_text(name)
    gui.chord("enter")
    return time.monotonic()


def ready(now, row):
    return now["open"] and now["openRow"] == row(now) and now["terminal"] and now["agent"] and now["groups"]


def menu(gui, row_label):
    for attempt in range(2):
        gui.click(gui.element(row_label), button="right")
        try:
            gui.element("Rename" + ELLIPSIS, role="16", timeout=3)
            return [e["label"] for e in gui.snapshot()["elements"] if e["role"] == "16"]
        except Failure:
            if attempt:
                raise
            gui.chord("esc")


def run(gui):
    attached(gui, "Alpha")
    gui.wait("Alpha's catalog", lambda s: s["state"]["workbench"]["catalog"] and s["state"]["workbench"]["openRowsLive"], 40, settle=0.5)
    gui.step("create workspace Gamma from the New Workspace row, then send nothing")
    started = create(gui, "Gamma")
    trace, last = watch(gui, "trace", 15, started, lambda now: ready(now, lambda v: "w:" + v["open"]) and now["empty"])
    gamma = (ws(gui.state(), "Gamma") or {}).get("id")
    row = "w:%s" % gamma
    gui.check("Gamma exists and is open", lambda s: gamma and s["state"]["openWorkspace"] == gamma, 1, detail=lambda s: last)
    gui.check("the Workbench tree is still showing", lambda s: gui.find(s, "n:new-workspace") and gui.find(s, row), 1, detail=lambda s: last)
    gui.check("the new workspace's row is selected", lambda s: s["state"]["workbench"]["selected"] == row, 1, detail=lambda s: last)
    gui.check("the tree's rows belong to Gamma", lambda s: s["state"]["workbench"]["openRow"] == row and s["state"]["workbench"]["openRowsLive"], 1, detail=lambda s: last)
    gui.check("a terminal can be created", lambda s: s["state"]["workbench"]["canCreateTerminal"], 1, detail=lambda s: last)
    gui.check("an agent session can be created", lambda s: s["state"]["workbench"]["canCreateAgent"], 1, detail=lambda s: last)
    gui.check("a group can be created", lambda s: s["state"]["workbench"]["canEditGroups"], 1, detail=lambda s: last)
    gui.check("the empty workspace's row says so", lambda s: s["state"]["workbenchEmptyState"], 1, detail=lambda s: last)
    gui.check("no workspace error", lambda s: not s["state"]["workspaceError"], 1,
              detail=lambda s: (s["state"]["workspaceError"], s["state"]["notifications"]))
    gui.shot("gamma-created")

    gui.step("the empty row's New Group makes a group in the new workspace")
    # Gamma's own note row: Alpha is empty too, and its row stays expanded above Gamma's.
    gui.click(gui.element("s:none|" + gamma), button="right")
    gui.click(gui.element("New Group", role="16"))
    time.sleep(0.6)
    gui.type_text("Sorted")
    gui.chord("enter")
    gui.check("group Sorted is in Gamma's catalog", lambda s: any(g["name"] == "Sorted" for g in s["state"]["groups"]), 20,
              detail=lambda s: (s["state"]["groups"], s["state"]["notifications"], view(gui, s)))
    gui.click(gui.element(row))

    gui.step("the workspace row's menu creates in the new workspace")
    labels = menu(gui, row)
    for item in ("New Terminal", "New Agent Session", "New Group"):
        gui.check("row menu offers " + item, lambda s, item=item: gui.find(s, item, role="16"), 1, detail=lambda s: labels)
    gui.shot("gamma-menu")
    gui.click(gui.element("New Terminal", role="16"))
    gui.check("the new terminal is in Gamma's catalog", lambda s: len(s["state"]["terminals"]) == 1, 20,
              detail=lambda s: (s["state"]["terminals"], s["state"]["notifications"], view(gui, s)))
    gui.check("and has a tab", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 5,
              detail=lambda s: s["state"]["panes"])
    gui.check("no error was reported", lambda s: not s["state"]["notifications"], 1, detail=lambda s: s["state"]["notifications"])
    gui.shot("gamma-terminal")

    gui.step("attach a folder to the new workspace: the connection, the terminal and the group stay")
    extra = os.path.join(os.path.dirname(gui.out), "fixture", "extra")
    menu(gui, row)
    gui.click(gui.element("Attach Folder" + ELLIPSIS, role="16"))
    gui.answer_dialog(paths=[extra])
    began = time.monotonic()
    gui.check("Gamma has the folder", lambda s: len(ws(s["state"], "Gamma")["folders"]) == 1, 15,
              detail=lambda s: ws(s["state"], "Gamma"))
    attach, last = watch(gui, "attach", 4, began)
    gui.check("the window never went back to connecting", lambda s: all(e["catalog"] and not e["connecting"] for e in attach), 1,
              detail=lambda s: attach)
    gui.check("the terminal and the group are still there", lambda s: len(s["state"]["terminals"]) == 1
              and any(g["name"] == "Sorted" for g in s["state"]["groups"]), 5, detail=lambda s: (s["state"]["terminals"], s["state"]["groups"]))
    gui.check("still can create", lambda s: ready(view(gui, s), lambda v: row), 5, detail=lambda s: view(gui, s))
    gui.check("no error after the attach", lambda s: not s["state"]["notifications"] and not s["state"]["workspaceError"], 1,
              detail=lambda s: (s["state"]["workspaceError"], s["state"]["notifications"]))

    gui.step("open Alpha, then Gamma again: each shows its own rows at once")
    alpha = ws(gui.state(), "Alpha")["id"]
    gui.click(gui.element("w:" + alpha), count=2)
    began = time.monotonic()
    there, last = watch(gui, "to-alpha", 12, began, lambda now: now["open"] == alpha and ready(now, lambda v: "w:" + alpha))
    gui.check("Alpha is open with the tree showing and ready", lambda s: last["open"] == alpha and last["tree"]
              and ready(last, lambda v: "w:" + alpha), 1, detail=lambda s: last)
    gui.click(gui.element(row), count=2)
    began = time.monotonic()
    back, last = watch(gui, "to-gamma", 12, began, lambda now: now["open"] == gamma and ready(now, lambda v: row))
    gui.check("Gamma is open again with the tree showing and ready", lambda s: last["open"] == gamma and last["tree"]
              and ready(last, lambda v: row), 1, detail=lambda s: last)
    gui.check("Gamma still has its terminal and group", lambda s: len(s["state"]["terminals"]) == 1
              and any(g["name"] == "Sorted" for g in s["state"]["groups"]), 10, detail=lambda s: (s["state"]["terminals"], s["state"]["groups"]))
    gui.check("no error after the switches", lambda s: not s["state"]["notifications"] and not s["state"]["workspaceError"], 1,
              detail=lambda s: (s["state"]["workspaceError"], s["state"]["notifications"]))
    gui.shot("gamma-again")


if __name__ == "__main__":
    main(run)
