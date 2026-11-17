"""An idle window talks to its workspace service only when something changed (entropy plan Step 3).

The window opens workspace Alpha over the protocol (exosuit.workspace.open, no real input), waits until it is connected with its rows,
then is left alone for IDLE_SECONDS with the Workbench shown. Every request the workspace client sends by itself is an
"rpc" event in the ConnectTimeline (the connect log), and every catalog read after a CHANGED push is "catalog-read".
The check passes when the idle window shows neither. It also records the CPU time the editor and the workspace service
used while idle (Win32_Process kernel + user time, in ms)."""
import json
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"],
           "env": {"EXOSUIT_CLAUDE_BIN": "{out}/absent/claude.exe", "EXOSUIT_CODEX_BIN": "{out}/absent/codex.exe",
                   "EXOSUIT_PI_BIN": "{out}/absent/pi.exe", "EXOSUIT_NODE_BIN": "{out}/absent/node.exe",
                   "EXOSUIT_CLAUDE_NAMING_HELPER": "{out}/absent/names.mjs", "EXOSUIT_CONNECT_LOG": "1"}}
IDLE_SECONDS = int(os.environ.get("IDLE_RPC_SECONDS", "30"))


def cpu_ms():
    """Kernel + user CPU ms and the command line of every hl.exe, by process id."""
    query = ("Get-CimInstance Win32_Process -Filter \"Name='hl.exe'\" | "
             "Select-Object ProcessId, KernelModeTime, UserModeTime, CommandLine | ConvertTo-Json -Compress")
    text = subprocess.run(["pwsh", "-NoProfile", "-Command", query], capture_output=True, text=True, timeout=60).stdout
    rows = json.loads(text) if text.strip() else []
    found = {}
    for row in rows if isinstance(rows, list) else [rows]:
        found[row["ProcessId"]] = ((row["KernelModeTime"] + row["UserModeTime"]) // 10000, row["CommandLine"] or "")
    return found


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1, 60)
    alpha = ws(gui.state(), "Alpha")["id"]
    gui.open_workspace(alpha)
    attached(gui, "Alpha", 60)
    time.sleep(3)  # first reads after connecting
    begin = gui.state()["timeline"][-1]["t"]
    before = cpu_ms()
    time.sleep(IDLE_SECONDS)
    after_cpu = cpu_ms()
    timeline = gui.state()["timeline"]
    idle = [e for e in timeline if e["t"] > begin]
    talk = [e for e in idle if e["event"] in ("rpc", "catalog-read")]
    counts = {}
    for e in talk:
        key = e["event"] + " " + e["detail"]
        counts[key] = counts.get(key, 0) + 1
    usage = {}
    checkout = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")).replace("\\", "/").lower()
    for pid, (ms, command) in after_cpu.items():
        command = command.replace("\\", "/").lower()
        if pid in before and (pid == gui.pid or checkout + "/agent/" in command):
            usage["editor" if pid == gui.pid else "service %d" % pid] = ms - before[pid][0]
    # The connect reads rpc marks: without them the timeline records none, and "no rpc while idle" would prove nothing.
    marked = any(e["event"] == "rpc" for e in timeline if e["t"] <= begin)
    gui.results.append({"check": "rpc marks recorded while connecting", "ok": marked})
    ok = marked and not talk
    gui.results.append({"check": "no rpc while idle for %d s" % IDLE_SECONDS, "ok": ok, "counts": counts,
                        "cpu_ms": usage, "events": ["%d %s %s" % (e["t"], e["event"], e["detail"]) for e in idle][:200]})
    print(("PASS" if ok else "FAIL") + " idle %d s: %s; cpu ms %s%s" % (IDLE_SECONDS, json.dumps(counts), json.dumps(usage),
                                                                      "" if marked else "; no rpc marks recorded"), flush=True)


if __name__ == "__main__":
    main(run)
