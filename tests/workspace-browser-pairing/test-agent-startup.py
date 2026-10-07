#!/usr/bin/env python3
"""Start the real workspace daemon against a local Worker and verify restart."""
import json
import os
import pathlib
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
HAXEON = pathlib.Path(os.environ.get("HAXEON_BIN", ROOT / "haxeon/scripts/haxeon"))
WRANGLER = ROOT / "relay/worker/node_modules/.bin/wrangler"

if not WRANGLER.exists():
    raise SystemExit("Install the project-local Wrangler dependencies first")


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def stop_group(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def tail(path):
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-100:])
    except OSError:
        return ""


def wait_worker(process, port, log):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Local Wrangler Worker exited:\n" + tail(log))
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Local Wrangler Worker did not start:\n" + tail(log))


def wait_agent_ready(process, log):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("AgentMain exited during startup:\n" + tail(log))
        if "READY: exosuit-agent local and loopback WebSocket" in tail(log):
            return
        time.sleep(0.1)
    raise RuntimeError("AgentMain did not report READY:\n" + tail(log))


def wait_ticket(process, origin, machine_id, token, log):
    url = f"{origin}/v1/machines/{machine_id}/tickets"
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("AgentMain exited before relay enrollment:\n" + tail(log))
        request = urllib.request.Request(url, data=b"{}", headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        }, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=1) as response:
                if response.status != 201:
                    raise RuntimeError(f"Relay returned unexpected ticket status {response.status}")
                json.loads(response.read())
                return
        except urllib.error.HTTPError as error:
            if error.code not in (401, 404, 503):
                raise RuntimeError(f"Relay ticket request returned HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        time.sleep(0.2)
    raise RuntimeError("AgentMain did not enroll with the local Worker:\n" + tail(log))


def launch_agent(work, origin, machine_id, bootstrap_token, epoch, root, database, index):
    socket_path = work / f"agent-{index}.sock"
    token_path = work / f"session-{index}.token"
    bootstrap_path = work / f"relay-{index}.json"
    token_path.write_text(secrets.token_hex(32))
    os.chmod(token_path, 0o600)
    bootstrap_path.write_text(json.dumps({"version": 1, "origin": origin,
        "machineId": machine_id, "bootstrapToken": bootstrap_token}))
    os.chmod(bootstrap_path, 0o600)
    log = work / f"agent-{index}.log"
    output = log.open("w+")
    environment = os.environ.copy()
    environment["EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP"] = "1"
    process = subprocess.Popen([
        str(HAXEON), "run", "--project", str(ROOT / "agent/haxeon.json"), "--",
        str(socket_path), str(free_port()), str(token_path), epoch, str(database), str(root),
        "browser-pairing-startup-test", "0", str(bootstrap_path),
    ], cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT,
        start_new_session=True)
    return process, output, log, bootstrap_path


with tempfile.TemporaryDirectory(prefix="exosuit-agent-startup-") as temporary:
    work = pathlib.Path(temporary)
    os.chmod(work, 0o700)
    worker_port = free_port()
    origin = f"http://127.0.0.1:{worker_port}"
    machine_id = secrets.token_hex(16)
    first_token = secrets.token_hex(32)
    second_token = secrets.token_hex(32)
    epoch = secrets.token_hex(16)
    workspace = work / "workspace"
    workspace.mkdir(mode=0o700)
    database = work / "workspace.sqlite"
    worker_log = work / "worker.log"
    worker_output = worker_log.open("w+")
    worker = subprocess.Popen([
        str(WRANGLER), "dev", "--local", "--ip", "127.0.0.1", "--port", str(worker_port),
        "--persist-to", str(work / "wrangler-state"),
    ], cwd=ROOT / "relay/worker", stdout=worker_output, stderr=subprocess.STDOUT,
        start_new_session=True)
    agent_handles = []
    agent_processes = []
    try:
        wait_worker(worker, worker_port, worker_log)
        for index, bootstrap_token in enumerate((first_token, second_token), 1):
            process, output, log, bootstrap = launch_agent(work, origin, machine_id,
                bootstrap_token, epoch, workspace, database, index)
            agent_handles.append(output)
            agent_processes.append(process)
            wait_agent_ready(process, log)
            wait_ticket(process, origin, machine_id, first_token, log)
            if bootstrap.exists():
                raise RuntimeError("AgentMain did not consume its one-shot relay bootstrap")
            print(f"PASS: AgentMain launch {index} used the saved OS credentials and enrolled with the Worker")
            stop_group(process)

        with sqlite3.connect(database) as db:
            version = db.execute("PRAGMA user_version").fetchone()[0]
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if version != 5 or "workspace_devices" not in tables:
                raise RuntimeError("AgentMain did not initialize the production workspace/device schema")
        print("PASS: AgentMain restart reopened the production SQLite catalog")
    except Exception as error:
        raise SystemExit(f"{error}\n\nWorker log:\n{tail(worker_log)}") from error
    finally:
        for process in reversed(agent_processes):
            stop_group(process)
        stop_group(worker)
        worker_output.close()
        for output in agent_handles:
            output.close()
        cleanup = subprocess.run([
            str(HAXEON), "run", "--project", str(ROOT / "tests/workspace-browser-pairing/haxeon.json"), "--",
            "--cleanup-credentials", machine_id, origin,
        ], cwd=ROOT, text=True, capture_output=True, timeout=120)
        if cleanup.returncode != 0:
            print("WARNING: could not remove temporary OS credentials:\n" + cleanup.stdout + cleanup.stderr)
