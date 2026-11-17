r"""Workspace open time: how long a double click on a workspace row takes to show it, in a state shaped like daily use.

The fixture makes that state in the run's own folders (gui_fixture.py, which calls `prepare` here), nothing copied
from the user's: suit's workspaces (WORKSPACES), each a git repository with a tree of source files, and in each
workspace's catalog the groups, agent sessions and terminals SHAPES lists, made through a service of the workspace with
the RPCs the editor sends (tests/mobile-pairing's admin tool, `--seed`). The editor's tabs per group and its
session.conf are written by the editor's own session code (tests/context-snapshots, `seed`); the window starts in
Lumen, so the targets start idle. The agent providers are pointed at programs that do not exist (no session is resumed
or renamed) and at configuration folders of the run (CLAUDE_CONFIG_DIR, CODEX_HOME). The terminals' shells keep running
in their terminal hosts, as after a day of use; the services the fixture started have idled out before the editor starts.
`python -I gui_fixture.py --root CHECKOUT --out RUNDIR --scenario ws_open` makes the fixture alone, without the editor.

Cases, each what a double click on a row of the Workbench tree does (sent over the protocol as `exosuit.workspace.open`,
no real input, so another window in front does not matter), timed from the editor's ConnectTimeline (milliseconds):
  cold   an idle workspace: click until connected, its catalog rows, its file tree;
  warm   the same workspaces again, their services running.
"terminals" is the time until the last terminal tab of the opened workspace has read its screen (absent with no terminal tab).
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_connect_time import after

# Workspaces of the fixture; gui_fixture names each after its folder, capitalized.
WORKSPACES = ["lumen", "atlas", "harbor", "quill"]
FIXTURE = {"workspaces": WORKSPACES, "open": None, "appArgs": ["--open-workbench"],
           "env": {"EXOSUIT_CLAUDE_BIN": "{out}/absent/claude.exe", "EXOSUIT_CODEX_BIN": "{out}/absent/codex.exe",
                   "EXOSUIT_PI_BIN": "{out}/absent/pi.exe", "EXOSUIT_NODE_BIN": "{out}/absent/node.exe",
                   "EXOSUIT_CLAUDE_NAMING_HELPER": "{out}/absent/names.mjs", "EXOSUIT_CONNECT_LOG": "1",
                   "CLAUDE_CONFIG_DIR": "{out}/claude-config", "CODEX_HOME": "{out}/codex-home"}}


def shape(groups, sessions, terminals, files, tabs):
    """`groups`: "Parent/Child" paths, parents first, each last segment unique. `sessions` and `terminals`: how many go
    to each group ("" is the workspace root). `files`: how many source files the folder holds. `tabs`: how many files
    are open in each group's context."""
    return {"groups": groups, "sessions": sessions, "terminals": terminals, "files": files, "tabs": tabs}


# Sizes of daily use: a main project with groups per task and a full agent catalog (a service keeps at most 32
# sessions), a second one about half that size, and small ones.
SHAPES = {
    "atlas": shape(["Work", "Work/Editor", "Work/Service", "Review", "Experiments", "Experiments/Perf"],
                   {"": 6, "Work": 6, "Work/Editor": 5, "Work/Service": 5, "Review": 4, "Experiments": 2, "Experiments/Perf": 2},
                   {"": 2, "Work": 2, "Work/Editor": 1, "Work/Service": 1, "Review": 1, "Experiments/Perf": 1},
                   600, {"": 6, "Work": 4, "Work/Editor": 3, "Review": 3}),
    "harbor": shape(["Build", "Docs"], {"": 6, "Build": 5, "Docs": 3}, {"": 2, "Build": 2}, 200, {"": 4, "Build": 2}),
    "lumen": shape(["Main"], {"": 2, "Main": 2}, {"Main": 2}, 80, {"": 2}),
    "quill": shape([], {"": 2}, {"": 1}, 40, {}),
}
# Workspaces opened, in order (names as the Workbench shows them).
TARGETS = [name for name in os.environ.get("WS_OPEN_TARGETS", "Atlas,Harbor").split(",") if name]
# Budgets in ms for the last step of each case, about 3-4x what the 2026-11-16 runs measured (cold about 100 ms, warm
# about 10 ms, editor start about 830 ms). WS_OPEN_BUDGET_MS overrides all three.
BUDGETS = {"cold": 400, "warm": 150, "start": 2500}
if os.environ.get("WS_OPEN_BUDGET_MS"):
    BUDGETS = {case: int(os.environ["WS_OPEN_BUDGET_MS"]) for case in BUDGETS}


def source_tree(folder, count):
    """`count` source files in nested folders, committed in a git repository of their own."""
    for index in range(count):
        path = folder / "src" / ("module%d" % (index % 12)) / ("part%d" % (index % 5)) / ("File%d.hx" % index)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("package module%d;\n\nclass File%d {\n%s}\n" % (index % 12, index, "".join(
            "\tpublic function step%d(value:Int):Int return value + %d;\n" % (line, line) for line in range(20))))
    (folder / "README.md").write_text("# %s\n\nA workspace of the ws_open scenario.\n" % folder.name)
    git = ["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.autocrlf=false"]
    for command in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "Fixture"]):
        subprocess.run(git + command, cwd=folder, check=True, capture_output=True)


def seed_spec(item):
    """The admin tool's --seed request: groups by name (the last path segment), sessions and terminals per group."""
    names = {path: path.split("/")[-1] for path in item["groups"]}
    spec = {"groups": [{"name": names[path], "parent": names.get(path.rpartition("/")[0])} for path in item["groups"]],
            "sessions": [], "terminals": []}
    for path, count in item["sessions"].items():
        for index in range(count):
            # Mostly Claude, some Pi.
            spec["sessions"].append({"name": "%s session %d" % (names.get(path, "Root"), index + 1), "group": names.get(path),
                                     "provider": "pi" if index % 4 == 3 else "claude"})
    for path, count in item["terminals"].items():
        spec["terminals"] += [{"group": names.get(path)}] * count
    return spec


def prepare(out, root, env, suit):
    """Fills the workspaces gui_fixture made: their folders, their catalogs (through a service of each, which idles out
    after) and the editor's tabs. `env` is the environment of the run's suit; `suit(*args)` runs suit's CLI."""
    sys.path.insert(0, str(root / "scripts"))
    from test_driver import build_test, kill_tree, ready_services, service_command, service_environment, with_libraries

    machine = json.loads(suit("machine", "--json").stdout)
    by_name = {entry["name"]: entry for entry in machine["workspaces"]}
    admin = build_test("mobile-pairing")
    contexts_tool = build_test("context-snapshots")
    environment = service_environment(root)
    environment.update({key: value for key, value in env.items() if key.upper() != "PATH"})
    # Each service stops by itself once the admin tool has left it (its terminals' hosts keep running).
    environment["EXOSUIT_SERVICE_IDLE_SECONDS"] = "3"
    environment = with_libraries(environment, root / "tests" / "mobile-pairing" / "build" / "host" / "native",
                                 root / "tests" / "context-snapshots" / "build" / "host" / "native")
    contexts = []  # WORKSPACES' order: Lumen's root context comes first, and the window starts in it
    for name in WORKSPACES:
        item, entry = SHAPES[name], by_name[name.capitalize()]
        folder = Path(entry["folders"][0])
        source_tree(folder, item["files"])
        log = Path(env["EXOSUIT_AGENT_STATE_HOME"]) / "workspaces" / entry["id"] / "service.log"
        process = subprocess.Popen([*service_command(root), "--workspace", entry["id"], "--folder", str(folder)], env=environment,
                                   cwd=str(folder), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   creationflags=0x08000000)
        try:
            deadline = time.monotonic() + 60
            while not ready_services(log):
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("the service of %s did not start (exit %s): %s" % (name, process.poll(), log))
                time.sleep(0.1)
            spec_path = out / ("seed-%s.json" % name)
            spec_path.write_text(json.dumps(seed_spec(item)))
            seeded = subprocess.run([*admin, "--socket", ready_services(log)[-1].endpoint, "--seed", str(spec_path)], env=environment,
                                    capture_output=True, text=True, timeout=180)
            if seeded.returncode != 0:
                raise RuntimeError("seeding %s failed: %s%s" % (name, seeded.stderr, seeded.stdout))
            groups = json.loads(seeded.stdout.strip().splitlines()[-1])["groups"]
            files = sorted(str(p) for p in (folder / "src").rglob("*.hx"))
            for path, count in item["tabs"].items():
                contexts.append({"workspace": entry["id"], "group": groups[path.split("/")[-1]] if path else "", "files": files[:count]})
        finally:
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                kill_tree(process)
    spec_path = out / "seed-contexts.json"
    first = by_name[WORKSPACES[0].capitalize()]
    spec_path.write_text(json.dumps({"machine": machine["id"], "contexts": contexts,
                                     "open": {"id": first["id"], "name": first["name"], "folders": first["folders"]}}))
    written = subprocess.run([*contexts_tool, "seed", str(spec_path), str(out / "state")], env=environment, capture_output=True,
                             text=True, timeout=60)
    if written.returncode != 0:
        raise RuntimeError("writing the editor's tabs failed: %s%s" % (written.stderr, written.stdout))


def opened(gui, name, wid, case):
    """Opens workspace `wid` as a double click on its row does (exosuit.workspace.open, so the run does not depend on
    which window is in front); records the times from the open event to each later step."""
    mark = len(gui.state()["timeline"])
    gui.open_workspace(wid)
    begin = gui.wait("open event", lambda s: after(s["state"]["timeline"], mark, lambda e: e["event"] == "open-workspace" and e["workspace"] == wid), 10)
    steps = {"connected": lambda e: e["event"] == "status" and e["detail"] == "Workspace connected",
             "rows": lambda e: e["event"] == "rows-visible" and e["detail"] == "own",
             "files": lambda e: e["event"] == "files-visible",
             "scm": lambda e: e["event"] == "scm-visible",
             "frame": lambda e: e["event"] == "rows-frame" and e["detail"] == "own"}

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
    ok = "connected" in times and "rows" in times and max(times.values()) <= BUDGETS[case]
    gui.results.append({"check": "time %s %s" % (case, name), "ok": ok, "ms": times, "budget_ms": BUDGETS[case],
                        "events": ["%d %s %s %s" % (e["t"] - base, e["event"], e["workspace"][-8:], e["detail"][:300]) for e in tl[begin:]
                                   if e["event"] not in ("suit-queued",)]})
    print("%s time %s %s %s" % ("PASS" if ok else "FAIL", case, name, times), flush=True)
    gui._save()
    gui.shot_window("%s-%s" % (case, name))


def run(gui):
    gui.wait("workspaces", lambda s: len(s["state"]["machineWorkspaces"]) >= len(WORKSPACES), 60)
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
    started = "connected" in start and max(start.values()) <= BUDGETS["start"]
    gui.results.append({"check": "time start", "ok": started, "ms": start, "budget_ms": BUDGETS["start"]})
    print("%s time start %s" % ("PASS" if started else "FAIL", start), flush=True)
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
