#!/usr/bin/env python3
"""A desktop-side test host for the phone app, machine level (M19 Phase 9, ADR 0005 section 4).

  mobile-machine-host.py start --out DIR [--real-claude PATH]
  mobile-machine-host.py grant --out DIR NAME[:PRESET] ...      (PRESET: read, edit, all; default all)
  mobile-machine-host.py revoke-grant --out DIR NAME ...        (take a workspace back from the paired device)
  mobile-machine-host.py approve --out DIR                       (approve the pending device once its code matches the phone's)
  mobile-machine-host.py restart-exohost --out DIR [--down-seconds N]   (the desktop restarting: exohost stops and starts again on the same home)
  mobile-machine-host.py stop  --out DIR

`start` runs everything under DIR (nothing in the user's real state) and stays in the foreground until DIR/stop
appears, Ctrl-C, or 24 minutes pass. It prints JSON lines (also to DIR/host.log) and, once the machine is ready, writes
DIR/ready.json (invitation URL, machine id, workspace ids). Build first:

  python scripts/build.py --only agent
  python scripts/haxeon_cli.py build --project exohost/haxeon.json
  python scripts/haxeon_cli.py build --project tests/mobile-pairing/haxeon.json     (the admin tool, to make sessions)

What it starts, all under DIR and all loopback:
- the local Wrangler relay (relay/worker) on 127.0.0.1:PORT, EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1;
- an isolated exohost (its own home, agent state and a file credential store) with remote access enabled for that relay;
- two workspaces, "Alpha" (one session) and "Beta" (two sessions), each with a folder and a running workspace service
  using the fake Codex (tests/workspace-agents/fake-codex.py). Exohost finds the services by their state folders;
- terminals in each workspace's service: Alpha has "Terminal 1" (the shell) and "Claude Code · Terminal", which runs
  tests/workspace-terminals/fake-claude-tui.py (a deterministic Claude Code look-alike; every key it gets is logged to
  DIR/fake-claude-alpha.log). With --real-claude PATH, Beta's "Claude Code · Terminal" runs the real CLI instead, with a
  throwaway config (CLAUDE_CONFIG_DIR, HOME and USERPROFILE under DIR/claude-home; no Anthropic variable of the real
  environment reaches it), so it only shows its first-run screen;
- the pairing: it makes an invitation and, when the phone's device is pending, compares the phone's code (DIR/pairing.json
  has the machine's pending code) and approves it with NO workspaces. `grant` then grants workspaces to the paired device
  (the same exohost control requests the desktop's Remote Access panel sends); the phone follows without pairing again.

Files in DIR: ready.json, pairing.json ({pendingCode, deviceId, approved, granted}), host.log, *.log, commands/ (grant
requests), stop (create it to stop). An emulator reaches the host's loopback with `adb -s emulator-N reverse tcp:PORT tcp:PORT`.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import exohost_harness as harness  # noqa: E402
sys.path.insert(0, str(SCRIPTS))
from test_driver import runtime_paths, service_environment  # noqa: E402

ROOT = harness.ROOT
DEFAULT_OUT = Path(r"C:\Users\corbi\projects\exosuit-wt\mobile\state\mobile-machine-host\run")
ADMIN = ROOT / "tests" / "mobile-pairing" / "build" / "host" / "main.hl"
LIFETIME_SECONDS = 24 * 60
NO_WINDOW = (subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP) if os.name == "nt" else 0
WORKSPACES = [("Alpha", ["Alpha session"]), ("Beta", ["Beta session", "Beta second session"])]
FAKE_CLAUDE = ROOT / "tests" / "workspace-terminals" / "fake-claude-tui.py"
SECRET_PREFIXES = ("ANTHROPIC_", "CLAUDE_", "CLAUDECODE", "AWS_", "OPENAI_")


def write_json(path: Path, value) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


class Log:
    def __init__(self, path: Path) -> None:
        self.file = path.open("a", encoding="utf-8")

    def __call__(self, event: str, **fields) -> None:
        line = json.dumps({"t": round(time.time(), 3), "event": event, **fields})
        print(line, flush=True)
        self.file.write(line + "\n")
        self.file.flush()


def start(arguments) -> int:
    out = Path(arguments.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    for stale in ("stop", "approve", "ready.json", "pairing.json"):
        (out / stale).unlink(missing_ok=True)
    commands = out / "commands"
    commands.mkdir(exist_ok=True)
    for old in commands.glob("*.json"):
        old.unlink()
    log = Log(out / "host.log")
    assert harness.WRANGLER.is_file(), f"run `npm ci` in relay/worker first ({harness.WRANGLER} is missing)"
    assert ADMIN.is_file(), "build tests/mobile-pairing first (scripts/haxeon_cli.py build --project tests/mobile-pairing/haxeon.json)"
    for built in (harness.EXOHOST, harness.AGENT):
        assert built.is_file(), f"build first: {built}"
    runtime, bytecode = runtime_paths(ROOT)
    for name in ("credentials", "agent-state", "portable"):
        (out / name).mkdir(exist_ok=True)

    environment = service_environment(ROOT)
    environment.update({
        "EXOSUIT_AGENT_STATE_HOME": str(out / "agent-state"), "PRAGTICAL_PORTABLE": str(out / "portable"),
        "EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP": "1", "EXOSUIT_RELAY_TEST_CREDENTIALS_DIR": str(out / "credentials"),
        "EXOSUIT_CODEX_BIN": sys.executable, "EXOSUIT_CODEX_SCRIPT": str(ROOT / "tests" / "workspace-agents" / "fake-codex.py"),
        "EXOSUIT_CODEX_PROXY_LAUNCHER": str(ROOT / "scripts" / "run-codex-proxy.py"), "FAKE_CODEX_REPLY": "1",
        "EXOSUIT_SERVICE_IDLE_SECONDS": "3000"})

    relay = harness.Relay(out)
    exohost = harness.Exohost(out, {
        "EXOSUIT_EXOHOST_IDLE_SECONDS": "3000", "EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP": "1",
        "EXOSUIT_RELAY_TEST_CREDENTIALS_DIR": str(out / "credentials"), "EXOSUIT_AGENT_STATE_HOME": str(out / "agent-state"),
        "EXOSUIT_AGENT_LAUNCHER": str(harness.AGENT), "EXOSUIT_EXOHOST_LOGIN_KEY": "HKCU\\Software\\ExosuitExohostTest\\unusedPhone9",
        "EXOSUIT_CODEX_BIN": sys.executable, "EXOSUIT_CODEX_SCRIPT": environment["EXOSUIT_CODEX_SCRIPT"],
        "EXOSUIT_CODEX_PROXY_LAUNCHER": environment["EXOSUIT_CODEX_PROXY_LAUNCHER"], "FAKE_CODEX_REPLY": "1", "EXOSUIT_SERVICE_IDLE_SECONDS": "3000"})
    # The services report to this exohost (service-attach), which then lists them as running and forwards device streams to them.
    environment["EXOSUIT_EXOHOST_HOME"] = str(exohost.home)
    exit_code = 0
    started = time.monotonic()
    ids: dict[str, str] = {}
    sockets: dict[str, str] = {}
    device_id = None
    try:
        log("relay-ready", origin=relay.origin)
        assert "started" in exohost("start")
        log("exohost-started", home=str(exohost.home))

        def start_service(workspace: str, folder: Path, env: dict, timeout: float = 120) -> str:
            """Starts workspace `workspace`'s service as exohost does, in the background, and returns its pipe once its service.log
            says it is ready."""
            log = out / "agent-state" / "workspaces" / workspace / "service.log"
            offset = log.stat().st_size if log.exists() else 0
            process = subprocess.Popen([str(runtime), str(bytecode), "--workspace", workspace, "--folder", str(folder)], env=env,
                                       cwd=str(folder), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       creationflags=NO_WINDOW | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"the service of {workspace} exited with {process.returncode}")
                text = log.read_bytes()[offset:].decode("utf-8", "replace") if log.exists() else ""
                for line in text.splitlines():
                    if "service ready on " in line:
                        return line.split("service ready on ", 1)[1].partition(" for ")[0].strip()
                time.sleep(0.2)
            raise RuntimeError(f"the service of {workspace} was not ready in {timeout} s")

        def claude_environment(name: str) -> dict:
            """Alpha's Claude Code terminal is the fake TUI; Beta's is the real CLI when asked, always on a throwaway config."""
            result = {k: v for k, v in environment.items() if not k.upper().startswith(SECRET_PREFIXES)}
            if name == "Beta" and arguments.real_claude:
                home = out / "claude-home"
                (home / ".claude").mkdir(parents=True, exist_ok=True)
                result.update({"EXOSUIT_CLAUDE_BIN": arguments.real_claude, "CLAUDE_CONFIG_DIR": str(home / ".claude"),
                               "HOME": str(home), "USERPROFILE": str(home), "APPDATA": str(home / "AppData"),
                               "LOCALAPPDATA": str(home / "AppData" / "Local"), "CLAUDE_CODE_DISABLE_AUTOUPDATE": "1"})
                result.pop("EXOSUIT_CLAUDE_SCRIPT", None)
            elif name == "Alpha":
                result.update({"EXOSUIT_CLAUDE_BIN": sys.executable, "EXOSUIT_CLAUDE_SCRIPT": str(FAKE_CLAUDE),
                               "FAKE_CLAUDE_LOG": str(out / "fake-claude-alpha.log"), "PYTHONIOENCODING": "utf-8"})
            return result

        def admin(*extra: str, timeout: float = 90) -> subprocess.CompletedProcess:
            return subprocess.run([str(runtime), str(ADMIN), *extra], env=environment, cwd=str(ROOT), capture_output=True, text=True,
                                  timeout=timeout, creationflags=NO_WINDOW)

        for name, sessions in WORKSPACES:
            folder = out / f"folder-{name.lower()}"
            folder.mkdir(exist_ok=True)
            (folder / "README.md").write_text(f"# {name}\n\nThrowaway folder for the phone's machine test.\n", encoding="utf-8")
            reply = exohost.control({"op": "workspace-create", "name": name, "folders": [str(folder)]})
            assert reply.get("ok"), reply
            workspace = reply["workspace"]["id"]
            ids[name] = workspace
            # The service exohost would start on a device's OPEN, started here first so its sessions exist; exohost finds it by its state folder.
            local_socket = start_service(workspace, folder, claude_environment(name))
            sockets[name] = local_socket
            deadline = time.monotonic() + 90
            while admin("--socket", local_socket, "--list-sessions").returncode != 0:
                if time.monotonic() > deadline:
                    raise RuntimeError("the local catalog did not answer")
                time.sleep(1)
            for session in sessions:
                deadline = time.monotonic() + 90
                while True:
                    ensured = admin("--socket", local_socket, "--ensure-session", session)
                    if ensured.returncode == 0:
                        break
                    if time.monotonic() > deadline or "provider_starting" not in ensured.stderr:
                        raise RuntimeError(f"creating the session failed: {ensured.stderr}{ensured.stdout}")
                    time.sleep(2)
            terminals = []
            if name == "Alpha" or arguments.real_claude:
                plans = [("Claude Code", "claude")] + ([("Shell", None)] if name == "Alpha" else [])
                for terminal_name, provider in plans:
                    command = ["--socket", local_socket, "--ensure-terminal", f"{name} {terminal_name}"] + (["--provider", provider] if provider else [])
                    deadline = time.monotonic() + 60
                    while True:
                        created = admin(*command)
                        if created.returncode == 0:
                            terminals.append(json.loads(created.stdout.strip().splitlines()[-1]))
                            break
                        if time.monotonic() > deadline:
                            raise RuntimeError(f"creating the terminal failed: {created.stderr}{created.stdout}")
                        time.sleep(2)
            log("workspace-ready", name=name, workspace=workspace, sessions=sessions, terminals=terminals)

        reply = exohost.control({"op": "remote-enable", "origin": relay.origin})
        assert reply.get("ok"), reply
        log("remote-enabled", status=reply)
        invitation = None
        for _ in range(30):
            reply = exohost.control({"op": "remote-invite", "ttl": 300})
            if reply.get("ok"):
                invitation = reply["invitation"]
                break
            time.sleep(1)
        assert invitation is not None, reply
        device_id = invitation["deviceId"]
        status = exohost.control({"op": "remote-status"})
        write_json(out / "ready.json", {
            "relayPort": relay.port, "relayOrigin": relay.origin, "invitationUrl": invitation.get("invitationUrl") or invitation["pairingSocketUrl"], "deviceId": device_id,
            "relayMachineId": status.get("relayMachineId"), "machineId": status.get("machineId"), "workspaces": ids, "sockets": sockets, "out": str(out),
            "stopFile": str(out / "stop"), "sessions": {name: sessions for name, sessions in WORKSPACES},
            "fakeClaudeLog": str(out / "fake-claude-alpha.log"), "realClaude": bool(arguments.real_claude)})
        log("ready", invitation=invitation["pairingSocketUrl"])
        pairing = {"pendingCode": None, "deviceId": device_id, "approved": False, "granted": {}}
        write_json(out / "pairing.json", pairing)
        device_state = "none"

        while not (out / "stop").exists():
            if time.monotonic() - started > LIFETIME_SECONDS:
                log("lifetime-exceeded", seconds=LIFETIME_SECONDS)
                break
            devices = exohost.control({"op": "remote-devices"})
            # The machine's record of the device (none, saved, connected, revoked), logged when it changes: a pairing the machine
            # rolled back after the approval shows as saved -> none, with the times that explain it.
            state = "none"
            for item in devices.get("devices", []):
                if item.get("deviceId") == device_id:
                    state = "revoked" if item.get("revoked") else "connected" if item.get("connected") else "saved"
            if state != device_state:
                device_state = state
                log("device", state=state)
            if not pairing["approved"]:
                for item in devices.get("pending", []):
                    if item["deviceId"] == device_id:
                        if pairing["pendingCode"] != item["authenticationCode"]:
                            pairing["pendingCode"] = item["authenticationCode"]
                            write_json(out / "pairing.json", pairing)
                            log("pending", code=item["authenticationCode"])
                        # The phone's own code is compared by the acceptance script (it reads the phone's log) before this approves.
                        if (out / "approve").exists():
                            approved = exohost.control({"op": "remote-approve", "deviceId": device_id, "workspaces": []})
                            log("approved", reply=approved)
                            pairing["approved"] = bool(approved.get("ok"))
                            write_json(out / "pairing.json", pairing)
            for command in sorted(commands.glob("*.json")):
                request = read_json(command)
                command.unlink(missing_ok=True)
                if request is None:
                    continue
                if request.get("restart-exohost"):
                    # The desktop going away and coming back: exohost stops (the machine leaves the relay) and starts again with the same home
                    # and credentials; the workspace services keep running and exohost finds them by their state folders.
                    exohost.run("stop", check=False)
                    time.sleep(float(request.get("downSeconds", 0)))
                    assert "started" in exohost("start")
                    reply = exohost.control({"op": "remote-enable", "origin": relay.origin})
                    log("exohost-restarted", ok=reply.get("ok"), error=reply.get("error"))
                    continue
                current = {entry["workspace"]: entry["preset"] for device in devices.get("devices", []) if device["deviceId"] == device_id
                           for entry in device["workspaces"]}
                for name, preset in request.get("set", {}).items():
                    if preset is None:
                        current.pop(ids[name], None)
                    else:
                        current[ids[name]] = preset
                reply = exohost.control({"op": "remote-grant", "deviceId": device_id,
                                      "workspaces": [{"workspace": workspace, "preset": preset} for workspace, preset in current.items()]})
                pairing["granted"] = {name: current[workspace] for name, workspace in ids.items() if workspace in current}
                write_json(out / "pairing.json", pairing)
                log("granted", granted=pairing["granted"], ok=reply.get("ok"), error=reply.get("error"))
            if relay.process.poll() is not None:
                raise RuntimeError("the relay exited:\n" + relay.tail())
            time.sleep(0.5)
        log("stopping", reason="stop file" if (out / "stop").exists() else "lifetime")
    except KeyboardInterrupt:
        log("stopping", reason="interrupt")
    except Exception as error:  # noqa: BLE001
        log("failed", error=str(error))
        exit_code = 1
    finally:
        shutdown(out, exohost, relay, log)
    return exit_code


def shutdown(out: Path, exohost, relay, log) -> None:
    (out / "stop").write_text("stop\n")
    try:
        exohost.run("stop", check=False)
    except Exception:  # noqa: BLE001
        pass
    relay.stop()
    killed = []
    if os.name == "nt":
        marker = str(out).replace("'", "''")
        script = ("$all = Get-CimInstance Win32_Process; $skip = @{}; $id = " + str(os.getpid()) + "; "
                  "while ($id -and -not $skip.ContainsKey($id)) { $skip[$id] = 1; $id = ($all | Where-Object ProcessId -eq $id).ParentProcessId }; "
                  "$all | Where-Object { @('hl.exe','node.exe','workerd.exe','python.exe','python3.exe') -contains $_.Name -and $_.CommandLine -and "
                  "$_.CommandLine.Contains('" + marker + "') -and -not $_.CommandLine.Contains('mobile-machine-host') -and -not $skip.ContainsKey([int]$_.ProcessId) } | ForEach-Object { $_.ProcessId }")
        result = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True, text=True, timeout=60,
                                creationflags=NO_WINDOW)
        for text in result.stdout.split():
            if text.isdigit() and int(text) != os.getpid():
                harness.kill_tree(int(text))
                killed.append(int(text))
    log("stopped", leftoversKilled=killed)


def command_restart_exohost(out: Path, down_seconds: float) -> None:
    folder = out / "commands"
    folder.mkdir(exist_ok=True)
    write_json(folder / f"{time.time_ns()}.json", {"restart-exohost": True, "downSeconds": down_seconds})


def command_set(out: Path, changes: dict) -> None:
    folder = out / "commands"
    folder.mkdir(exist_ok=True)
    write_json(folder / f"{time.time_ns()}.json", {"set": changes})


def hold_control(out: Path, arguments) -> int:
    """Starts the admin tool as a second, controlling viewer of one terminal and returns once it holds control; it lets go after --seconds."""
    ready = read_json(out / "ready.json") or {}
    socket_path = (ready.get("sockets") or {}).get(arguments.workspace)
    if not socket_path:
        raise SystemExit(f"no local socket recorded for {arguments.workspace}")
    runtime, _ = runtime_paths(ROOT)
    # The controller outlives this command, so its output goes to a file, never to a pipe: once this process exits a pipe has
    # no reader, and the controller's next write to it would end the controller and with it the control it holds.
    log_path = out / f"hold-control-{time.time_ns()}.log"
    with open(log_path, "w", encoding="utf-8") as log:
        process = subprocess.Popen([str(runtime), str(ADMIN), "--socket", socket_path, "--hold-control", arguments.terminal,
                                    "--hold-seconds", str(arguments.seconds), "--columns", str(arguments.columns), "--rows", str(arguments.rows)],
                                   env=service_environment(ROOT), cwd=str(ROOT), stdout=log, stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if line.startswith("{") and '"holding"' in line:
                print(line.strip())
                return 0
        if process.poll() is not None:
            raise SystemExit(f"the controller failed (exit {process.returncode}); its output ({log_path.name}): " + text[-2000:])
        time.sleep(0.2)
    raise SystemExit(f"the controller did not take control within 60 s; its output ({log_path.name}): " + log_path.read_text(errors="replace")[-2000:])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    start_parser = commands.add_parser("start")
    start_parser.add_argument("--out", default=str(DEFAULT_OUT))
    start_parser.add_argument("--real-claude", default=None, help="path of the real Claude Code CLI to run in Beta's terminal, on a throwaway config")
    hold_parser = commands.add_parser("hold-control", help="attach to a terminal as a second viewer that takes control (a stand-in for the desktop)")
    hold_parser.add_argument("--out", default=str(DEFAULT_OUT))
    hold_parser.add_argument("workspace")
    hold_parser.add_argument("terminal", help='the terminal name given to --ensure-terminal, e.g. "Alpha Claude Code"')
    hold_parser.add_argument("--seconds", type=float, default=60)
    hold_parser.add_argument("--columns", type=int, default=120)
    hold_parser.add_argument("--rows", type=int, default=30)
    restart_parser = commands.add_parser("restart-exohost", help="stop exohost, wait, start it again with the same home (the desktop restarting)")
    restart_parser.add_argument("--out", default=str(DEFAULT_OUT))
    restart_parser.add_argument("--down-seconds", type=float, default=0)
    for name in ("grant", "revoke-grant", "approve", "stop"):
        sub = commands.add_parser(name)
        sub.add_argument("--out", default=str(DEFAULT_OUT))
        if name in ("grant", "revoke-grant"):
            sub.add_argument("names", nargs="+")
    arguments = parser.parse_args()
    out = Path(arguments.out).resolve()
    if arguments.command == "start":
        return start(arguments)
    if arguments.command == "hold-control":
        return hold_control(out, arguments)
    if arguments.command == "grant":
        changes = {}
        for item in arguments.names:
            name, _, preset = item.partition(":")
            changes[name] = preset or "all"
        command_set(out, changes)
    elif arguments.command == "revoke-grant":
        command_set(out, {name: None for name in arguments.names})
    elif arguments.command == "restart-exohost":
        command_restart_exohost(out, arguments.down_seconds)
    elif arguments.command == "approve":
        (out / "approve").write_text("approve\n")
    else:
        (out / "stop").write_text("stop\n")
        recorded = read_json(out / "ready.json") or {}
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and not (out / "host.log").read_text(errors="replace").rstrip().endswith('"leftoversKilled": []}') \
                and '"event": "stopped"' not in (out / "host.log").read_text(errors="replace"):
            time.sleep(0.5)
        print(json.dumps({"stopped": True, "workspaces": recorded.get("workspaces")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
