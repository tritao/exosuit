#!/usr/bin/env python3
"""Runs the repo's relay (relay/worker, `wrangler dev --local`) as a detached background process, for connect-real.ps1.

  local-relay.py start [--state DIR] [--port N]   start it (npm ci first when needed); prints {"origin","port","pid","log"}; does nothing when it already runs
  local-relay.py status [--state DIR]             {"running": bool, ...}
  local-relay.py stop [--state DIR]               stop it and everything it started

State (relay.json with the pid and port, relay.log, wrangler-state/ so registrations survive a restart) lives in DIR, by default
android/build/local-relay. It is configured as machine-acceptance's relay is (127.0.0.1, ALLOWED_ORIGINS for the web client only).
It keeps running after this script and the caller exit; `stop` ends it.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "relay" / "worker"
WRANGLER = WORKER / "node_modules" / "wrangler" / "bin" / "wrangler.js"
DEFAULT_STATE = ROOT / "android" / "build" / "local-relay"
DEFAULT_PORT = 18787


def reachable(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def read_state(state: Path):
    try:
        return json.loads((state / "relay.json").read_text())
    except (OSError, ValueError):
        return None


def alive(pid: int) -> bool:
    result = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True)
    return str(pid) in result.stdout


def describe(state: Path) -> dict:
    info = read_state(state)
    if not info or not alive(info["pid"]) or not reachable(info["port"]):
        return {"running": False}
    return {"running": True, **info}


def start(state: Path, port: int) -> dict:
    current = describe(state)
    if current["running"]:
        return current
    state.mkdir(parents=True, exist_ok=True)
    if not WRANGLER.is_file():
        subprocess.run(["npm.cmd" if os.name == "nt" else "npm", "ci"], cwd=WORKER, check=True, timeout=900)
    if reachable(port):
        raise SystemExit(json.dumps({"error": f"port {port} is in use by something else; pass --port"}))
    log = (state / "relay.log").open("ab")
    flags = (subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW) if os.name == "nt" else 0
    process = subprocess.Popen(
        ["node", str(WRANGLER), "dev", "--local", "--ip", "127.0.0.1", "--port", str(port),
         "--persist-to", str(state / "wrangler-state"), "--var", "ALLOWED_ORIGINS:http://localhost:5173"],
        cwd=WORKER, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, creationflags=flags)
    deadline = time.monotonic() + 120
    while not reachable(port):
        if process.poll() is not None or time.monotonic() > deadline:
            raise SystemExit(json.dumps({"error": "the local relay did not start; see " + str(state / "relay.log")}))
        time.sleep(0.5)
    info = {"origin": f"http://127.0.0.1:{port}", "port": port, "pid": process.pid, "log": str(state / "relay.log")}
    (state / "relay.json").write_text(json.dumps(info))
    return {"running": True, **info}


def stop(state: Path) -> dict:
    info = read_state(state)
    if info:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(info["pid"])], capture_output=True)
        (state / "relay.json").unlink(missing_ok=True)
    return {"running": False, "stopped": bool(info)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["start", "status", "stop"])
    parser.add_argument("--state", default=str(DEFAULT_STATE))
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    arguments = parser.parse_args()
    state = Path(arguments.state)
    result = {"start": lambda: start(state, arguments.port), "status": lambda: describe(state), "stop": lambda: stop(state)}[arguments.command]()
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
