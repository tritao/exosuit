#!/usr/bin/env python3
"""A repeatable memory measurement of the desktop editor and its workspace service (macOS; Linux reads /proc).

    python3 scripts/memory-scenario.py [--runs 3] [--out DIR] [--settle 20] [--census]

Each run starts an exohost of its own (a fresh home and state, never the user's) and a window on this repository, then:
  1. opens FILES (10 source files) in tabs;
  2. creates 3 terminals and runs an output-heavy command in each (COMMANDS), waiting for each one's end marker;
  3. lets things settle (--settle seconds), measures, and quits everything it started (`exohost quit`).

What is measured, for the window and the workspace service:
  rss_mb         `ps -o rss`
  footprint_mb   phys_footprint, and footprint_peak_mb its peak (`vmmap --summary`); graphics_mb and malloc_mb are the
                 footprint's graphics and malloc categories (`footprint`)
  gc_heap_mb     the HashLink GC's heap pages (window: after a full collection, `exosuitctl call exosuit.memory
                 {"collect":true}`; service: the EXOSUIT_MEMORY_STATS file it writes)
  alloc_mb_s     GC bytes allocated per second while idle after settling (the churn of a window nobody touches), over
                 --idle seconds; the window's alloc_mb is what the whole scenario allocated
The summary is the median of the runs. Everything goes to DIR (default build/memory-scenario/<time>): summary.json,
run-N/result.json (with the window at each step), and each run's logs. --census records the window's allocation census
over the idle interval to run-N/census-idle.json (read it with haxeon/scripts/alloc-sites.py). Sockets, and exohost's
home that holds its socket, live under EXOSUIT_AGENT_STATE_HOME (keep it short: a Unix socket path must fit 104 bytes),
else under a temporary folder in /tmp.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

import haxeon_paths

ROOT = Path(__file__).resolve().parent.parent
HAXEON = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
WINDOW = ROOT / "graphical" / "build" / "host" / "main.hl"
AGENT = ROOT / "agent" / "build" / "host" / "main.hl"
EXOHOST = ROOT / "exohost" / "build" / "host" / "main.hl"

FILES = [
    "src/workspace/client/RpcTerminalBackend.hx", "graphical/src/ui/TerminalPane.hx", "graphical/src/ui/ExosuitApp.hx",
    "agent/src/app/AgentMain.hx", "agent/src/workspace/runtime/WorkspaceTerminalManager.hx",
    "src/workspace/service/WorkspaceService.hx", "native-packages/terminal/src/terminalkit.c", "scripts/run.py",
    "README.md", "docs/ARCHITECTURE.md",
]
COMMANDS = ["seq 1 200000", "find haxeon -name '*.hx'", "ls -laR haxeon/stdlib haxeon/packages"]


def library_variable() -> str:
    return "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"


def environment(run: Path, sockets: Path) -> dict[str, str]:
    """An environment that reaches only this run's exohost and state."""
    env = dict(os.environ)
    for name in list(env):
        if name.startswith(("EXOSUIT_", "PRAGTICAL_")):
            del env[name]
    credentials = run / "relay-credentials"
    credentials.mkdir(mode=0o700, parents=True, exist_ok=True)
    native = WINDOW.parent / "native"
    libraries = [HAXEON / "out", haxeon_paths.vm_dir(HAXEON)] + sorted(p for p in native.iterdir() if p.is_dir())
    inherited = os.environ.get(library_variable(), "")
    env.update({
        "XDG_STATE_HOME": str(run / "xdg-state"),
        "EXOSUIT_EXOHOST_HOME": str(sockets / "exohost"),  # its socket is in it
        "EXOSUIT_AGENT_STATE_HOME": str(sockets),
        "PRAGTICAL_PORTABLE": str(run / "portable"),
        "EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP": "1",
        "EXOSUIT_RELAY_TEST_CREDENTIALS_DIR": str(credentials),
        "EXOSUIT_EXOHOST_TRAY": "0",
        "EXOSUIT_EXOHOST_SCAN": "0",
        "EXOSUIT_AGENT_LAUNCHER": str(AGENT),
        "EXOSUIT_PROJECT_ROOT": str(ROOT),
        "EXOSUIT_MEMORY_STATS": str(run / "memory-stats"),
        "HAXEON_ROOT": str(HAXEON),
        "HAXEON_HOME": str(HAXEON),
        "HAXEON_SDK": str(HAXEON / "out" / "sdk"),
        library_variable(): os.pathsep.join([str(p) for p in libraries] + ([inherited] if inherited else [])),
    })
    for folder in (run / "xdg-state", sockets / "exohost", run / "portable"):
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        folder.chmod(0o700)  # exohost refuses a home other users can read
    return env


def ctl(env: dict[str, str], *arguments: str, timeout: float = 60) -> str:
    result = subprocess.run([sys.executable, str(ROOT / "scripts" / "exohost.py"), "--ctl", *arguments], env=env,
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"exosuitctl {' '.join(arguments)}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def call(env: dict[str, str], method: str, params: dict | None = None, timeout: float = 60) -> dict:
    return json.loads(ctl(env, "--output", "json", "call", method, json.dumps(params or {}), timeout=timeout))


def wait(what: str, check, seconds: float, step: float = 0.5):
    deadline = time.time() + seconds
    while True:
        try:
            value = check()
        except Exception:  # noqa: BLE001 - not ready yet
            value = None
        if value:
            return value
        if time.time() > deadline:
            raise TimeoutError(f"timed out waiting for {what}")
        time.sleep(step)


def children(pid: int) -> list[tuple[int, str]]:
    listed = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    table = [line.split(None, 2) for line in listed.splitlines() if len(line.split(None, 2)) == 3]
    found, frontier = [], {pid}
    while frontier:
        nxt = set()
        for child, parent, command in table:
            if int(parent) in frontier and int(child) not in nxt:
                nxt.add(int(child))
                found.append((int(child), command))
        frontier = nxt
    return found


def measure_process(pid: int) -> dict:
    out: dict = {"pid": pid}
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    out["rss_mb"] = round(int(rss) / 1024, 1) if rss else None
    if sys.platform == "darwin":
        summary = subprocess.run(["vmmap", "--summary", str(pid)], capture_output=True, text=True, timeout=120).stdout
        for key, pattern in (("footprint_mb", r"Physical footprint:\s+([\d.]+)([KMG])"),
                             ("footprint_peak_mb", r"Physical footprint \(peak\):\s+([\d.]+)([KMG])")):
            match = re.search(pattern, summary)
            if match:
                out[key] = round(float(match.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[match.group(2)], 1)
        categories = subprocess.run(["footprint", "-f", "bytes", str(pid)], capture_output=True, text=True,
                                    timeout=120).stdout
        graphics = malloc = 0
        for line in categories.splitlines():
            fields = line.split()
            # "<dirty> B <clean> B <reclaimable> B <regions> <category>"
            if len(fields) >= 8 and fields[0].isdigit() and fields[1] == "B":
                name = " ".join(fields[7:])
                if "graphics" in name or name.startswith("IOSurface"):
                    graphics += int(fields[0])
                elif name.startswith("Malloc"):
                    malloc += int(fields[0])
        out["graphics_mb"] = round(graphics / 2**20, 1)
        out["malloc_mb"] = round(malloc / 2**20, 1)
    elif Path(f"/proc/{pid}/status").is_file():
        status = Path(f"/proc/{pid}/status").read_text()
        peak = re.search(r"VmHWM:\s+(\d+)", status)
        out["footprint_peak_mb"] = round(int(peak.group(1)) / 1024, 1) if peak else None
    return out


def gc(stats: dict) -> dict:
    return {"gc_heap_mb": round(stats["heapBytes"] / 2**20, 1), "collections": stats["collections"]}


def service_stats(run: Path, pid: int) -> dict | None:
    path = run / "memory-stats" / f"service-{pid}.json"
    return json.loads(path.read_text()) if path.is_file() else None


def screen_locked() -> bool:
    if sys.platform != "darwin":
        return False
    shown = subprocess.run(["ioreg", "-n", "Root", "-d1"], capture_output=True, text=True).stdout
    return bool(re.search(r'"CGSSessionScreenIsLocked"\s*=\s*Yes', shown))


def scenario(index: int, out: Path, sockets: Path, settle: float, idle: float, census: bool) -> dict:
    run = out / f"run-{index}"
    run.mkdir(parents=True, exist_ok=True)
    state = sockets / f"r{index}"
    shutil.rmtree(state, ignore_errors=True)
    state.mkdir(mode=0o700, parents=True)
    env = environment(run, state)
    result: dict = {"run": index, "screen_locked": screen_locked(), "phases": {}}
    log = open(run / "window.log", "w")
    # The window starts as scripts/run.py starts it (through `haxeon run`, which finds the build up to date).
    launcher = subprocess.Popen([sys.executable, str(ROOT / "scripts" / "run.py"), str(ROOT)], env=env, cwd=ROOT,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    started = time.time()
    try:
        def window_pid() -> int | None:
            for pid, command in children(launcher.pid):
                if str(WINDOW) in command:
                    return pid
            return None
        pid = wait("the window process", window_pid, 300, 1.0)
        wait("the window", lambda: f"pid {pid} " in ctl(env, "list", timeout=10), 180, 1.0)
        result["phases"]["window"] = round(time.time() - started, 1)
        time.sleep(5)
        result["window_at"] = {"start": measure_process(pid)}

        def service() -> int | None:
            # The service may be the adopted warm spare (`--spare` on its command line): it is the one that serves,
            # which is the one writing memory stats.
            # exohost (detached, so not under the window) starts it; only this run's service writes this run's stats.
            for stats in (run / "memory-stats").glob("service-*.json"):
                child = int(stats.stem.split("-")[1])
                if subprocess.run(["ps", "-p", str(child), "-o", "command="], capture_output=True, text=True).stdout.find(str(AGENT)) >= 0:
                    return child
            return None
        for name in FILES:
            ctl(env, "open", str(ROOT / name))
        result["phases"]["files"] = round(time.time() - started, 1)
        time.sleep(3)
        result["window_at"]["files"] = measure_process(pid)
        terminals = []
        for number, command in enumerate(COMMANDS):
            created = call(env, "exosuit.terminal.create")
            terminal = created.get("id") or created.get("result", {}).get("id")
            terminals.append(terminal)
            # The command marks its end with a file: `exosuit.terminal.read` shows only the screen's first rows.
            marker = run / f"terminal-{number}.done"
            wait("the terminal's prompt", lambda: any(row.strip() for row in call(env, "exosuit.terminal.read", {"id": terminal})["rows"]), 60)
            call(env, "exosuit.terminal.send", {"id": terminal, "text": f"cd {ROOT} && {command}; touch {marker}\n"})
        for number in range(len(terminals)):
            try:
                wait(f"terminal {number}'s output", (run / f"terminal-{number}.done").is_file, 180, 1.0)
            except TimeoutError:
                result.setdefault("unfinished", []).append(number)
        result["phases"]["terminals"] = round(time.time() - started, 1)
        result["window_at"]["terminals"] = measure_process(pid)
        agent = wait("the workspace service", service, 30)
        time.sleep(settle)
        before_window = call(env, "exosuit.memory", {"census": "start"} if census else None)
        before_service = service_stats(run, agent)
        time.sleep(idle)
        after_window = call(env, "exosuit.memory", {"census": "dump", "path": str(run / "census-idle.json")} if census else None)
        after_service = service_stats(run, agent)
        window_now = measure_process(pid)
        window_now.update(gc(call(env, "exosuit.memory", {"collect": True})))
        window_now["collections"] = after_window["collections"]  # the ones the window ran, not the one asked for
        window_now["alloc_mb_s"] = round((after_window["allocatedBytes"] - before_window["allocatedBytes"]) / 2**20
                                         / (after_window["at"] - before_window["at"]), 3)
        window_now["alloc_mb"] = round(after_window["allocatedBytes"] / 2**20, 1)
        service_now = measure_process(agent)
        if after_service:
            service_now.update(gc(after_service))
            if before_service and after_service["at"] > before_service["at"]:
                service_now["alloc_mb_s"] = round((after_service["allocatedBytes"] - before_service["allocatedBytes"])
                                                  / 2**20 / (after_service["at"] - before_service["at"]), 3)
            service_now["alloc_mb"] = round(after_service["allocatedBytes"] / 2**20, 1)
        result["window"], result["service"] = window_now, service_now
    finally:
        try:
            subprocess.run([sys.executable, str(ROOT / "scripts" / "exohost.py"), "quit"], env=env, capture_output=True,
                           timeout=60)
        except subprocess.TimeoutExpired:
            pass
        try:
            launcher.wait(30)
        except subprocess.TimeoutExpired:
            os.killpg(launcher.pid, 9)
        log.close()
    (run / "result.json").write_text(json.dumps(result, indent=2))
    return result


KEYS = ["rss_mb", "footprint_mb", "footprint_peak_mb", "graphics_mb", "malloc_mb", "gc_heap_mb", "collections",
        "alloc_mb_s", "alloc_mb"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--idle", type=float, default=10)
    parser.add_argument("--census", action="store_true")
    options = parser.parse_args()
    for built in (WINDOW, AGENT, EXOHOST):
        if not built.is_file():
            print(f"{built} is not built; run python3 scripts/build.py", file=sys.stderr)
            return 127
    out = (options.out or ROOT / "build" / "memory-scenario" / time.strftime("%Y%m%d-%H%M%S")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    named = os.environ.get("EXOSUIT_AGENT_STATE_HOME")
    sockets = Path(named) if named else Path(tempfile.mkdtemp(prefix="exm", dir="/tmp"))
    runs = []
    for index in range(1, options.runs + 1):
        result = scenario(index, out, sockets, options.settle, options.idle, options.census)
        runs.append(result)
        print(json.dumps({"run": index, "window": result.get("window"), "service": result.get("service"),
                          "screen_locked": result["screen_locked"], "unfinished": result.get("unfinished")}))
    summary = {"runs": len(runs), "screen_locked": any(r["screen_locked"] for r in runs)}
    for side in ("window", "service"):
        summary[side] = {}
        for key in KEYS:
            values = [r[side][key] for r in runs if r.get(side) and r[side].get(key) is not None]
            if values:
                summary[side][key] = round(statistics.median(values), 3)
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    print(f"results: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
