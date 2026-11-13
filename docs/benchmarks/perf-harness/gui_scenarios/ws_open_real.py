r"""Workspace open time against a copy of a real state: how long a double click on a workspace row takes to show it.

The fixture copies a saved state (EXOSUIT_STATE_COPY, default %LOCALAPPDATA%\Exosuit-20261112-preswitch: suit's machine
catalog and every workspace's catalog) into the run's isolated folders, and the editor's session and context snapshots
(EXOSUIT_EDITOR_STATE_COPY, default %LOCALAPPDATA%\Pragtical Haxeon, read only). Stale endpoints, manager records, relay
settings and backups are left out, the agent providers are pointed at programs that do not exist (no session is resumed
or renamed), and the workspace whose folder is the user's checkout (REMAP_FROM) serves another folder instead: this
checkout, or WS_OPEN_REMAP_TO. When that is a sibling of REMAP_FROM with a name of the same length (a junction to a
worktree, say), the workspace's catalog records and the editor's tabs are rewritten to it as well, so its terminals,
sessions and tabs open as the user's do; otherwise its service refuses the catalog's terminal records and its tabs are left out.
Each workspace's migration.json is left out: it names folders of the real state, which a start would finish marking.

Cases, each what a double click on a row of the Workbench tree does (sent as the automation command `open-workspace`, no
real input, so another window in front does not matter), timed from the editor's ConnectTimeline (milliseconds):
  cold   an idle workspace: click until connected, its catalog rows, its file tree;
  warm   the same workspaces again, their services running.
"terminals" is the time until the last terminal tab of the opened workspace has read its screen (absent with no terminal tab).
"""
import json
import os
import re
import shutil
import subprocess
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_connect_time import after

FIXTURE = {"workspaces": [], "open": None, "appArgs": ["--open-workbench"],
           "env": {"EXOSUIT_CLAUDE_BIN": "{out}/absent/claude.exe", "EXOSUIT_CODEX_BIN": "{out}/absent/codex.exe",
                   "EXOSUIT_PI_BIN": "{out}/absent/pi.exe", "EXOSUIT_NODE_BIN": "{out}/absent/node.exe",
                   "EXOSUIT_CLAUDE_NAMING_HELPER": "{out}/absent/names.mjs", "EXOSUIT_CONNECT_LOG": "1",
                   "EXOSUIT_TERMINAL_HOST": "0"}}
REMAP_FROM = "C:/Users/corbi/projects/exosuit"
REMAP_TO = os.environ.get("WS_OPEN_REMAP_TO", "")
# Workspaces opened, in order. The one REMAP_FROM names (exosuit) only with WS_OPEN_REMAP_TO: see above.
TARGETS = [name for name in os.environ.get("WS_OPEN_TARGETS", "eon-series,resume-2026").split(",") if name]
# Workspaces that keep their real folders (comma separated names). Default none: every workspace serves a throwaway folder
# of the run, so no service of the run reads or watches a real project.
REAL_FOLDERS = [name for name in os.environ.get("WS_OPEN_REAL_FOLDERS", "").split(",") if name]
BUDGET = int(os.environ.get("WS_OPEN_BUDGET_MS", "60000"))


def same(a, b):
    return a.replace(chr(92), "/").rstrip("/").lower() == b.replace(chr(92), "/").rstrip("/").lower()


def private(folder):
    """Suit and the services accept only folders and files whose access list names this user alone."""
    user = os.environ.get("USERDOMAIN", "") + chr(92) + os.environ["USERNAME"]
    subprocess.run(["icacls", str(folder), "/inheritance:r", "/grant:r", user + ":(OI)(CI)F"], check=True, capture_output=True)
    subprocess.run(["icacls", os.path.join(str(folder), "*"), "/reset", "/T", "/Q"], check=False, capture_output=True)


def prepare(out, root, env):
    local = os.environ.get("LOCALAPPDATA", "")
    source = os.environ.get("EXOSUIT_STATE_COPY", os.path.join(local, "Exosuit-20261112-preswitch"))
    editor = os.environ.get("EXOSUIT_EDITOR_STATE_COPY", os.path.join(local, "Pragtical Haxeon"))
    fixture_folders = out / "fixture-folders"

    def remap(folders, name=""):
        if name in REAL_FOLDERS:
            return [(REMAP_TO or str(root)) if same(f, REMAP_FROM) else f for f in folders]
        # Also used for the scratch folder of a folderless workspace.
        mapped = []
        for f in folders:
            leaf_name = re.sub(r"[^\w.-]", "_", os.path.basename(f.replace(chr(92), "/").rstrip("/")) or "folder")
            mapped.append(str(fixture_folders / (name or "ws") / leaf_name))
            os.makedirs(mapped[-1], exist_ok=True)
        return mapped
    leaf, new_leaf = os.path.basename(REMAP_FROM), os.path.basename(REMAP_TO.replace(chr(92), "/").rstrip("/"))
    rewrite = bool(REMAP_TO) and len(new_leaf) == len(leaf) and same(os.path.dirname(REMAP_TO.replace(chr(92), "/").rstrip("/")), os.path.dirname(REMAP_FROM))
    suit_home = out / "suit-home"
    suit_home.mkdir(parents=True, exist_ok=True)
    machine = json.loads(open(os.path.join(source, "suit", "machine.json")).read())
    for entry in machine["workspaces"]:
        entry["folders"] = remap(entry["folders"], entry["name"])
        if entry.get("scratch"):
            entry["scratch"] = remap([entry["scratch"]], entry["name"])[0]
    (suit_home / "machine.json").write_text(json.dumps(machine, indent="\t"))
    private(suit_home)
    skip = ("terminal-hosts", "stop-request.json", "endpoint.json", "agent.lock", "relay-settings.json", "relay-machine.json", "android-invitation.json", "restart-request.json",
            "migration.json", "relay-status.json")
    names = {e["id"]: e["name"] for e in machine["workspaces"]}
    for name in os.listdir(os.path.join(source, "workspaces")):
        if ".bak-" in name or not name.startswith("workspace-"):
            continue
        target = out / "agent-state" / "workspaces" / name
        shutil.copytree(os.path.join(source, "workspaces", name), target,
                        ignore=lambda _, names: [n for n in names if n in skip or n.endswith(".log") or n.endswith("-lock")])
        private(target)
        identity = target / "workspace.json"
        if identity.exists():
            record = json.loads(identity.read_text())
            if "folders" in record:
                record["folders"] = remap(record["folders"], names.get(name, name))
            if record.get("scratch"):
                record["scratch"] = remap([record["scratch"]], names.get(name, name))[0]
            identity.write_text(json.dumps(record))
        if rewrite and (target / "catalog.sqlite").exists():
            recatalog(str(target / "catalog.sqlite"), leaf, new_leaf)
    # Tabs that point into the user's checkout would attach a service there: such lines and context files are left out.
    foreign = re.compile(r"projects[\\/]+exosuit(?![-\w])", re.I)
    session = os.path.join(source, "session.conf.pragtical")
    if os.path.exists(session):
        lines = open(session, encoding="utf-8", errors="replace").read().splitlines()
        if rewrite:
            lines = [foreign.sub(lambda m: m.group(0)[:-len(leaf)] + new_leaf, l) for l in lines]
        (out / "state" / "session.conf").write_text("".join(l + chr(10) for l in lines if not foreign.search(l)), encoding="utf-8")
    contexts = os.path.join(editor, "contexts")
    if os.path.isdir(contexts):
        for folder, _, names in os.walk(contexts):
            for name in names:
                text = open(os.path.join(folder, name), encoding="utf-8", errors="replace").read()
                if rewrite:
                    text = foreign.sub(lambda m: m.group(0)[:-len(leaf)] + new_leaf, text)
                if foreign.search(text):
                    continue
                target = out / "state" / "contexts" / os.path.relpath(os.path.join(folder, name), contexts)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")


def recatalog(path, leaf, new_leaf):
    """Renames the checkout's folder in every stored value of a catalog (records are length-prefixed: the names are equally long)."""
    import sqlite3
    old = re.compile(rb"(projects[\\/]+)" + re.escape(leaf.encode()) + rb"(?![-\w])", re.I)
    swap = lambda m: m.group(1) + new_leaf.encode()
    db = sqlite3.connect(path)
    db.text_factory = bytes
    for (table,) in db.execute("select name from sqlite_master where type='table' and name like 'workspace_%'").fetchall():
        table = table.decode()
        columns = [c[1].decode() for c in db.execute("pragma table_info([%s])" % table)]
        for row in db.execute("select rowid, * from [%s]" % table).fetchall():
            for column, value in zip(columns, row[1:]):
                if isinstance(value, bytes) and old.search(value):
                    kind = db.execute("select typeof([%s]) from [%s] where rowid=?" % (column, table), (row[0],)).fetchone()[0]
                    changed = old.sub(swap, value)
                    db.execute("update [%s] set [%s]=? where rowid=?" % (table, column),
                               (changed.decode("utf-8") if kind == b"text" else changed, row[0]))
    db.commit()
    db.execute("pragma wal_checkpoint(truncate)")
    db.close()


def opened(gui, name, wid, case):
    """Opens workspace `wid` as a double click on its row does (by the automation command, so the run does not depend on
    which window is in front); records the times from the open event to each later step."""
    mark = len(gui.state()["timeline"])
    with open(os.path.join(gui.dir, "command.tmp"), "w") as f:
        f.write("open-workspace " + wid)
    os.replace(os.path.join(gui.dir, "command.tmp"), os.path.join(gui.dir, "command.txt"))
    begin = gui.wait("open event", lambda s: after(s["state"]["timeline"], mark, lambda e: e["event"] == "open-workspace" and e["workspace"] == wid), 10)
    steps = {"connected": lambda e: e["event"] == "status" and e["detail"] == "Workspace connected",
             "rows": lambda e: e["event"] == "rows-visible" and e["detail"] == "own",
             "files": lambda e: e["event"] == "files-visible",
             "scm": lambda e: e["event"] == "scm-visible",
             "frame": lambda e: e["event"] == "open-frame"}

    def look(s):
        tl = s["state"]["timeline"]
        return True if after(tl, begin, steps["connected"]) is not None and after(tl, begin, steps["rows"]) is not None else None
    try:
        gui.wait("%s connected with rows" % name, look, 40)
    except Failure:
        pass
    time.sleep(1.5)
    tl = gui.state()["timeline"]
    base = tl[begin]["t"]
    found = {label: after(tl, begin, test) for label, test in steps.items()}
    # The last terminal tab to show its screen and history (each marks "terminal-shown" when its snapshot is read).
    found["terminals"] = after(tl, begin, lambda e: e["event"] == "terminal-shown", last=True)
    # The last document tab (or preview) read from the service.
    found["documents"] = after(tl, begin, lambda e: e["event"] == "tab-file-read", last=True)
    times = {label: tl[index]["t"] - base for label, index in found.items() if index is not None}
    ok = "connected" in times and "rows" in times and max(times.values()) <= BUDGET
    gui.results.append({"check": "time %s %s" % (case, name), "ok": ok, "ms": times, "budget_ms": BUDGET,
                        "events": ["%d %s %s %s" % (e["t"] - base, e["event"], e["workspace"][-8:], e["detail"][:300]) for e in tl[begin:]
                                   if e["event"] not in ("suit-queued",)]})
    print("%s time %s %s %s" % ("PASS" if ok else "FAIL", case, name, times), flush=True)
    gui._save()
    gui.shot_window("%s-%s" % (case, name))


def run(gui):
    gui.wait("workspaces", lambda s: len(s["state"]["machineWorkspaces"]) >= 2, 60)
    time.sleep(3)  # the window's own workspace settles first
    state = gui.state()
    # Editor start with the last workspace restored: ms since the process began, up to the first open.
    start = {}
    for e in state["timeline"]:
        if e["event"] == "open-workspace":
            break
        label = {"window-open": "window", "app-built": "app", "first-frame": "frame", "attach": "attach",
                 "rows-visible": "rows", "terminal-shown": "terminals"}.get(e["event"])
        if e["event"] == "status" and e["detail"] == "Workspace connected":
            label = "connected"
        if label and (label not in start or label == "terminals"):
            start[label] = e["t"]
    gui.results.append({"check": "time start", "ok": "connected" in start, "ms": start})
    print("%s time start %s" % ("PASS" if "connected" in start else "FAIL", start), flush=True)
    ids = {name: ws(state, name)["id"] for name in TARGETS}
    for name in TARGETS:
        gui.step("cold: " + name)
        opened(gui, name, ids[name], "cold")
    for name in TARGETS + TARGETS[:1]:
        gui.step("warm: " + name)
        opened(gui, name, ids[name], "warm")
    with open(os.path.join(gui.out, "timeline.json"), "w") as f:
        json.dump(gui.state()["timeline"], f, indent=1)


if __name__ == "__main__":
    main(run)
