#!/usr/bin/env python3
"""Exercise browser first-pairing through the real local Wrangler Worker and daemon code."""
import json
import os
import pathlib
import secrets
import signal
import shutil
import sqlite3
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
arguments = sys.argv[1:]
AGENT_MODE = "--agent" in arguments
if AGENT_MODE:
    arguments.remove("--agent")
if len(arguments) > 1:
    raise SystemExit("Usage: run.py [--agent] <built-site-directory>")
SITE = pathlib.Path(os.environ.get("EXOSUIT_WEB_SITE", ""))
if arguments:
    SITE = pathlib.Path(arguments[0])
if not SITE.is_dir() or not (SITE / "index.html").is_file():
    raise SystemExit("Pass a built web site directory (for example /tmp/exosuit-web-browser-pairing/site)")

HAXEON = pathlib.Path(os.environ.get("HAXEON_BIN", ROOT / "haxeon/scripts/haxeon"))
WRANGLER = ROOT / "relay/worker/node_modules/.bin/wrangler"
CHROME = os.environ.get("CHROME_BIN") or shutil.which("google-chrome") or "/opt/google/chrome/chrome"
NODE = shutil.which("node")
if not WRANGLER.exists() or not pathlib.Path(CHROME).is_file() or not NODE:
    raise SystemExit("Wrangler, Chrome and Node.js are required for the browser pairing test")


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def terminate(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def terminate_group(process):
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
        return "\n".join(path.read_text(errors="replace").splitlines()[-80:])
    except OSError:
        return ""


def wait_agent_ready(process, log):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("AgentMain exited during startup:\n" + tail(log))
        if "READY: exosuit-agent local and loopback WebSocket" in tail(log):
            return
        time.sleep(0.1)
    raise RuntimeError("AgentMain did not report READY:\n" + tail(log))

with tempfile.TemporaryDirectory(prefix="exosuit-browser-pairing-") as temporary:
    work = pathlib.Path(temporary)
    os.chmod(work, 0o700)
    relay_port = free_port()
    web_port = free_port()
    debug_port = free_port()
    workspace_root = work / "workspace"
    workspace_root.mkdir(mode=0o700)
    (workspace_root / "remote.md").write_text("# Browser remote file\n\nServed from the workspace daemon.\n")
    invitation = work / "invitation.json"
    status = work / "status.json"
    decision = work / "approval.json"
    success = work / "success.json"
    config = work / "host-config.json"
    database = work / "workspace.sqlite"
    local_socket = work / "agent.sock"
    machine_id = secrets.token_hex(16)
    machine_token = secrets.token_hex(32)
    epoch = secrets.token_hex(16)
    origin = f"http://127.0.0.1:{relay_port}"
    config.write_text(json.dumps({"origin": origin, "machineId": machine_id, "machineToken": machine_token,
        "workspaceRoot": str(workspace_root), "invitePath": str(invitation), "statusPath": str(status),
        "decisionPath": str(decision), "successPath": str(success), "databasePath": str(database),
        "localSocket": str(local_socket)}))
    os.chmod(config, 0o600)
    worker_log = work / "worker.log"
    agent_log = work / "agent.log"
    http_log = work / "http.log"
    chrome_log = work / "chrome.log"
    handles = [worker_log.open("w+"), agent_log.open("w+"), http_log.open("w+"), chrome_log.open("w+")]
    processes = []
    daemon = None
    daemon_output = None
    daemon_log = work / "agent-main.log"
    try:
        worker = subprocess.Popen([
            str(WRANGLER), "dev", "--local", "--ip", "127.0.0.1", "--port", str(relay_port),
            "--persist-to", str(work / "wrangler-state"), "--var", f"ALLOWED_ORIGINS:http://localhost:{web_port}",
        ], cwd=ROOT / "relay/worker", stdout=handles[0], stderr=subprocess.STDOUT)
        processes.append(worker)
        web = subprocess.Popen([
            sys.executable, "-m", "http.server", str(web_port), "--directory", str(SITE), "--bind", "127.0.0.1",
        ], cwd=ROOT, stdout=handles[2], stderr=subprocess.STDOUT)
        processes.append(web)
        chrome = subprocess.Popen([
            CHROME, "--headless", "--no-sandbox", "--disable-gpu", "--enable-unsafe-swiftshader",
            "--disable-dev-shm-usage", f"--remote-debugging-port={debug_port}", "--remote-debugging-address=127.0.0.1",
            f"--user-data-dir={work / 'chrome-profile'}", "--noerrdialogs", "--no-first-run",
            "--ozone-platform=headless", "--window-size=1050,688", "about:blank",
        ], cwd=ROOT, stdout=handles[3], stderr=subprocess.STDOUT)
        processes.append(chrome)
        if AGENT_MODE:
            token_path = work / "agent-session.token"
            token_path.write_text(secrets.token_hex(32))
            os.chmod(token_path, 0o600)
            bootstrap_path = work / "relay-bootstrap.json"
            bootstrap_path.write_text(json.dumps({"version": 1, "origin": origin,
                "machineId": machine_id, "bootstrapToken": machine_token}))
            os.chmod(bootstrap_path, 0o600)
            daemon_output = daemon_log.open("w+")
            handles.append(daemon_output)
            environment = os.environ.copy()
            environment["EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP"] = "1"
            daemon = subprocess.Popen([
                str(HAXEON), "run", "--project", str(ROOT / "agent/haxeon.json"), "--",
                str(local_socket), str(free_port()), str(token_path), epoch, str(database),
                str(workspace_root), "browser-pairing-agent-test", "0", str(bootstrap_path),
            ], cwd=ROOT, env=environment, stdout=daemon_output, stderr=subprocess.STDOUT,
                start_new_session=True)
            processes.append(daemon)
            wait_agent_ready(daemon, daemon_log)
            host = subprocess.Popen([
                str(HAXEON), "run", "--project", str(ROOT / "tests/workspace-browser-pairing/haxeon.json"), "--",
                "--agent-admin", str(config),
            ], cwd=ROOT, stdout=handles[1], stderr=subprocess.STDOUT)
        else:
            host = subprocess.Popen([
                str(HAXEON), "run", "--project", str(ROOT / "tests/workspace-browser-pairing/haxeon.json"), "--",
                str(config),
            ], cwd=ROOT, stdout=handles[1], stderr=subprocess.STDOUT)
        processes.append(host)

        deadline = time.monotonic() + 180
        while time.monotonic() < deadline and not invitation.exists():
            exited = [name for name, process in (("Worker", worker), ("pairing admin", host), ("Chrome", chrome), ("AgentMain", daemon))
                if process is not None and process.poll() is not None]
            if exited:
                raise RuntimeError("Test process exited before the one-use invitation was ready: " + ", ".join(exited))
            try:
                with socket.create_connection(("127.0.0.1", relay_port), timeout=0.2):
                    time.sleep(0.5)
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("The local Wrangler Worker did not start in time")
        while time.monotonic() < deadline and not invitation.exists():
            exited = [name for name, process in (("Worker", worker), ("pairing admin", host), ("Chrome", chrome), ("AgentMain", daemon))
                if process is not None and process.poll() is not None]
            if exited:
                raise RuntimeError("Test process exited before the one-use invitation was ready: " + ", ".join(exited))
            time.sleep(0.1)
        if not invitation.exists():
            raise RuntimeError("The local Worker did not produce a pairing invitation in time")

        env = os.environ.copy()
        env["EXOSUIT_CDP_PORT"] = str(debug_port)
        env["EXOSUIT_APP_PORT"] = str(web_port)
        env["EXOSUIT_TEST_AGENT"] = "1" if AGENT_MODE else "0"
        client = subprocess.run([
            NODE, str(ROOT / "tests/workspace-browser-pairing/browser-client.mjs"),
            str(invitation), str(status), str(decision), str(success),
        ], cwd=ROOT, env=env, text=True, capture_output=True, timeout=100)
        print(client.stdout, end="")
        if client.returncode != 0:
            raise RuntimeError("Browser pairing client failed:\n" + client.stderr + client.stdout)

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and host.poll() is None:
            time.sleep(0.05)
        if host.returncode != 0:
            raise RuntimeError("Pairing host failed after browser completion")
        result = json.loads(status.read_text())
        if result.get("activeClients") != 1 or not result.get("approved"):
            raise RuntimeError("The desktop did not retain exactly one approved browser RPC client")
        print("PASS: desktop persisted the pairing and admitted one remote RPC client")
        if AGENT_MODE:
            terminate_group(daemon)
            with sqlite3.connect(database) as db:
                version = db.execute("PRAGMA user_version").fetchone()[0]
                tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if version != 5 or "workspace_devices" not in tables:
                    raise RuntimeError("AgentMain did not persist the production workspace/device schema")
                rows = db.execute("SELECT device_id,revoked,length(static_key),length(grants) FROM workspace_devices").fetchall()
                success_result = json.loads(success.read_text())
                if len(rows) != 1 or rows[0][0] != success_result.get("deviceId") or rows[0][1] != 0 or rows[0][2] != 32 or rows[0][3] <= 0:
                    raise RuntimeError("AgentMain did not retain the reconnected device key and grants in SQLite")
            print("PASS: AgentMain retained the approved device in production SQLite after reconnect")
    except Exception as error:
        daemon_details = f"\n\nAgentMain log:\n{tail(daemon_log)}" if AGENT_MODE else ""
        raise SystemExit(f"{error}{daemon_details}\n\nWorker log:\n{tail(worker_log)}\n\nHost log:\n{tail(agent_log)}\n\nChrome log:\n{tail(chrome_log)}") from error
    finally:
        for process in reversed(processes):
            if process is daemon:
                terminate_group(process)
            else:
                terminate(process)
        for handle in handles:
            handle.close()
        if AGENT_MODE:
            cleanup = subprocess.run([
                str(HAXEON), "run", "--project", str(ROOT / "tests/workspace-browser-pairing/haxeon.json"), "--",
                "--cleanup-credentials", machine_id, origin,
            ], cwd=ROOT, text=True, capture_output=True, timeout=120)
            if cleanup.returncode != 0:
                print("WARNING: could not remove temporary OS credentials:\n" + cleanup.stdout + cleanup.stderr)
