#!/usr/bin/env python3
"""suit relay hosting and Start at login, isolated from the user's session.

Start at login runs against a scratch registry key (EXOSUIT_SUIT_LOGIN_KEY) or autostart directory, never
the user's Run key, and removes it. The relay test runs the real suit daemon, workspace manager and daemon
against the local Wrangler Worker (relay/worker, `npm ci` first) on a loopback port. Relay bearers and
Noise keys go to a file store in the test's temporary directory (EXOSUIT_RELAY_TEST_CREDENTIALS_DIR), never
the OS credential store. suit has its own EXOSUIT_SUIT_HOME, so the user's suit is never involved.

Covers:
- the daemon hands its relay hosting to suit, and suit keeps the machine socket after the workspace
  service (the editor's side) stops;
- suit does not idle out while it hosts, and does once hosting is paused;
- a device frame with no service running starts the workspace manager on demand;
- frames pass both ways between a device and an attached daemon (a stand-in daemon on suit's pipe);
- Stop hosting pauses (the relay sees the machine offline), resume works without suit, and suit hosts
  again from its records when it starts.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

ROOT = Path(__file__).resolve().parent.parent
HAXEON = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
HL = HAXEON / ".tools" / "hashlink" / ("hl.exe" if os.name == "nt" else "hl")
SUIT = ROOT / "suit" / "build" / "host" / "main.hl"
AGENT = ROOT / "agent" / "build" / "host" / "main.hl"
WRANGLER = ROOT / "relay" / "worker" / "node_modules" / "wrangler" / "bin" / "wrangler.js"


def library_path() -> str:
    directories: list[Path] = []
    for native in (ROOT / "suit/build/host/native", ROOT / "agent/build/host/native"):
        if native.is_dir():
            directories += sorted(path for path in native.iterdir() if path.is_dir())
    directories += [HAXEON / "out", HAXEON / ".tools" / "hashlink"]
    variable = "PATH" if os.name == "nt" else "LD_LIBRARY_PATH"
    return os.pathsep.join([str(path) for path in directories if path.is_dir()] + [os.environ.get(variable, "")])


def wait_until(condition, timeout: float, message: str, interval: float = 0.2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(message)


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def pid_alive(pid: int) -> bool:
    if os.name == "nt":
        output = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True, timeout=30).stdout
        return str(pid) in output
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def kill_tree(pid: int) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True, timeout=30)
    else:
        try:
            os.killpg(pid, 9)
        except OSError:
            pass


class Suit:
    def __init__(self, base: Path, extra: dict[str, str]) -> None:
        self.home = base / "suit-home"
        self.environment = dict(os.environ, EXOSUIT_SUIT_HOME=str(self.home), EXOSUIT_SUIT_SCAN="0", EXOSUIT_SUIT_TRAY="0",
                                EXOSUIT_SUIT_AUTOSTART="0", EXOSUIT_SUIT_LAUNCHER=str(SUIT), **extra)
        self.environment["PATH" if os.name == "nt" else "LD_LIBRARY_PATH"] = library_path()

    def run(self, *arguments: str, timeout: float = 60, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run([str(HL), str(SUIT), *arguments], env=self.environment, capture_output=True, text=True,
                                timeout=timeout)
        if check:
            assert result.returncode == 0, f"suit {' '.join(arguments)} failed ({result.returncode}): {result.stderr}{result.stdout}"
        return result

    def __call__(self, *arguments: str, timeout: float = 60) -> str:
        return self.run(*arguments, timeout=timeout).stdout

    def running(self) -> bool:
        return json.loads(self("status", "--json")).get("ok") is True

    def hosts(self) -> list[dict]:
        return json.loads(self("relay", "list", "--json"))["hosts"]


# --- Start at login ---------------------------------------------------------------------------------------------

def test_login(base: Path) -> None:
    scratch = f"HKCU\\Software\\ExosuitSuitTest\\login-{secrets.token_hex(6)}"
    autostart = base / "autostart"
    suit = Suit(base, {"EXOSUIT_SUIT_LOGIN_KEY": scratch, "EXOSUIT_SUIT_AUTOSTART_DIR": str(autostart),
                       "EXOSUIT_SUIT_IDLE_SECONDS": "2"})
    real_run_key = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    value_name = "Exosuit suit " + hashlib.sha256(str(suit.home).encode()).hexdigest()[:12]
    script = suit.home / ("start-at-login.cmd" if os.name == "nt" else "start-at-login.sh")
    try:
        assert "start at login: off" in suit("login", "status")
        assert "[ ] Start at login" in suit("menu"), suit("menu")
        output = suit("login", "on")
        assert "start at login: on" in output and scratch in (output if os.name == "nt" else scratch), output
        assert script.is_file(), "the start script was not written"
        text = script.read_text()
        assert "daemon --login" in text and str(SUIT.name) in text, text
        if os.name == "nt":
            query = subprocess.run(["reg", "query", scratch, "/v", value_name], capture_output=True, text=True, timeout=30)
            assert query.returncode == 0, query.stdout + query.stderr
            assert "--headless" in query.stdout and str(script) in query.stdout and "conhost.exe" in query.stdout, query.stdout
            # The user's real Run key is never touched.
            real = subprocess.run(["reg", "query", real_run_key, "/v", value_name], capture_output=True, text=True, timeout=30)
            assert real.returncode != 0, "the test wrote to the real Run key"
        else:
            assert any(autostart.glob("exosuit-suit-*.desktop")), "no autostart entry"
        assert "[x] Start at login" in suit("menu")
        # The script starts a resident suit: it stays past its idle timeout with nothing to track.
        starter = subprocess.Popen(["cmd.exe", "/d", "/c", str(script)] if os.name == "nt" else ["/bin/sh", str(script)],
                                   env=suit.environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_until(suit.running, 30, "the start-at-login script did not start suit")
            time.sleep(5)
            assert suit.running(), "a suit started at login idled out"
            assert "stopped" in suit("stop")
            starter.wait(timeout=30)
        finally:
            if starter.poll() is None:
                kill_tree(starter.pid)
        assert "start at login: off" in suit("login", "off")
        assert not script.exists(), "the start script was left behind"
        if os.name == "nt":
            query = subprocess.run(["reg", "query", scratch, "/v", value_name], capture_output=True, text=True, timeout=30)
            assert query.returncode != 0, "the Run value was not removed"
        else:
            assert not any(autostart.glob("exosuit-suit-*.desktop")), "the autostart entry was not removed"
    finally:
        if os.name == "nt":
            subprocess.run(["reg", "delete", scratch, "/f"], capture_output=True, timeout=30)
            parent = "HKCU\\Software\\ExosuitSuitTest"
            listed = subprocess.run(["reg", "query", parent], capture_output=True, text=True, timeout=30)
            if listed.returncode == 0 and "\\ExosuitSuitTest\\" not in listed.stdout:
                subprocess.run(["reg", "delete", parent, "/f"], capture_output=True, timeout=30)


# --- Relay ------------------------------------------------------------------------------------------------------

def envelope(channel: str, payload: bytes) -> bytes:
    return bytes([1]) + bytes.fromhex(channel) + b"HMPK\x01\x00" + len(payload).to_bytes(4, "big") + payload


def parse_envelope(frame: bytes) -> tuple[int, str, bytes]:
    kind, channel = frame[0], frame[1:17].hex()
    if kind == 2:
        return kind, channel, b""
    assert frame[17:23] == b"HMPK\x01\x00", frame[:32]
    length = int.from_bytes(frame[23:27], "big")
    return kind, channel, frame[27:27 + length]


class WebSocket:
    """A minimal binary WebSocket client: enough for a device socket to the local Worker."""

    def __init__(self, url: str) -> None:
        parts = urllib.parse.urlsplit(url)
        self.socket = socket.create_connection((parts.hostname, parts.port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        path = parts.path + ("?" + parts.query if parts.query else "")
        self.socket.sendall((f"GET {path} HTTP/1.1\r\nHost: {parts.hostname}:{parts.port}\r\nUpgrade: websocket\r\n"
                             f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.socket.recv(4096)
            if not chunk:
                break
            response += chunk
        head, _, self.buffer = response.partition(b"\r\n\r\n")
        self.status = int(head.split(b" ")[1]) if head else 0

    def send(self, data: bytes) -> None:
        mask = os.urandom(4)
        length = len(data)
        header = bytes([0x82]) + (bytes([0x80 | length]) if length < 126 else bytes([0x80 | 126]) + length.to_bytes(2, "big"))
        self.socket.sendall(header + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(data)))

    def _read(self, count: int) -> bytes:
        while len(self.buffer) < count:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def receive(self, timeout: float) -> bytes | None:
        self.socket.settimeout(timeout)
        try:
            while True:
                first, second = self._read(2)
                length = second & 0x7F
                if length == 126:
                    length = int.from_bytes(self._read(2), "big")
                elif length == 127:
                    length = int.from_bytes(self._read(8), "big")
                payload = self._read(length)
                opcode = first & 0x0F
                if opcode == 2:
                    return payload
                if opcode == 8:
                    return None
        except (socket.timeout, ConnectionError, OSError):
            return None

    def close(self) -> None:
        try:
            self.socket.close()
        except OSError:
            pass


class PipeDaemon:
    """A stand-in workspace daemon on suit's pipe: attaches like the real one and echoes device frames."""

    def __init__(self, endpoint: str, request: dict) -> None:
        self.file = open(endpoint, "r+b", buffering=0)
        import msvcrt
        self.handle = msvcrt.get_osfhandle(self.file.fileno())
        self.buffer = b""
        self.send(json.dumps(request).encode())

    def send(self, message: bytes) -> None:
        self.file.write(b"HMPK\x01\x00" + len(message).to_bytes(4, "big") + message)

    def available(self) -> int:
        count = ctypes.c_ulong(0)
        if not ctypes.windll.kernel32.PeekNamedPipe(ctypes.c_void_p(self.handle), None, 0, None, ctypes.byref(count), None):
            raise ConnectionError("suit closed the relay link")
        return count.value

    def receive(self, timeout: float) -> bytes | None:
        deadline = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 10:
                length = int.from_bytes(self.buffer[6:10], "big")
                if len(self.buffer) >= 10 + length:
                    message, self.buffer = self.buffer[10:10 + length], self.buffer[10 + length:]
                    return message
            ready = self.available()
            if ready:
                self.buffer += self.file.read(ready)
                continue
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.02)

    def close(self) -> None:
        self.file.close()


class Relay:
    def __init__(self, base: Path) -> None:
        self.port = free_port()
        self.origin = f"http://127.0.0.1:{self.port}"
        self.log = (base / "worker.log").open("w+", encoding="utf-8", errors="replace")
        self.process = subprocess.Popen(
            ["node", str(WRANGLER), "dev", "--local", "--ip", "127.0.0.1", "--port", str(self.port),
             "--persist-to", str(base / "wrangler-state"), "--var", "ALLOWED_ORIGINS:http://localhost:5173"],
            cwd=ROOT / "relay" / "worker", stdout=self.log, stderr=subprocess.STDOUT)
        def ready():
            if self.process.poll() is not None:
                raise AssertionError("the local Worker exited:\n" + self.tail())
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.5):
                    return True
            except OSError:
                return False
        wait_until(ready, 90, "the local Worker did not start")

    def tail(self) -> str:
        self.log.flush()
        self.log.seek(0)
        return self.log.read()[-4000:]

    def http(self, method: str, path: str, token: str, body: dict | None = None) -> tuple[int, dict]:
        request = urllib.request.Request(self.origin + path, method=method, data=b"" if body is None else json.dumps(body).encode(),
                                         headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                text = response.read().decode()
                return response.status, json.loads(text) if text else {}
        except urllib.error.HTTPError as error:
            text = error.read().decode()
            return error.code, json.loads(text) if text else {}

    def device_socket(self, machine: str, device: str, token: str) -> WebSocket:
        status, body = self.http("POST", f"/v1/machines/{machine}/tickets", token)
        assert status == 201, (status, body)
        return WebSocket(f"ws://127.0.0.1:{self.port}/v1/machines/{machine}/connect?ticket={body['ticket']}")

    def stop(self) -> None:
        if self.process.poll() is None:
            kill_tree(self.process.pid)
        self.log.close()


def stored_secret(credentials: Path, account: str) -> str:
    name = hashlib.sha256(("com.exosuit.workspace-relay\n" + account).encode()).hexdigest()[:32] + ".secret"
    return bytes.fromhex((credentials / name).read_text().strip()).decode()


def test_relay(base: Path) -> None:
    assert WRANGLER.is_file(), f"run `npm ci` in relay/worker first ({WRANGLER} is missing)"
    assert AGENT.is_file(), f"build the agent first: {AGENT}"
    credentials = base / "credentials"; credentials.mkdir()
    workspace = base / "workspace"; workspace.mkdir()
    agent_state = base / "agent-state"
    relay = Relay(base)
    suit = Suit(base, {
        "EXOSUIT_SUIT_IDLE_SECONDS": "12", "EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP": "1", "EXOSUIT_RELAY_VIA_SUIT": "1",
        "EXOSUIT_RELAY_TEST_CREDENTIALS_DIR": str(credentials), "EXOSUIT_AGENT_STATE_HOME": str(agent_state),
        "EXOSUIT_SUIT_LOGIN_KEY": "HKCU\\Software\\ExosuitSuitTest\\unused"})
    # What the editor sets for the workspace manager it starts. suit's environment lacks it: its on-demand
    # start must set it itself.
    editor_environment = dict(suit.environment, EXOSUIT_AGENT_LAUNCHER=str(AGENT))
    manager = [str(HL), str(AGENT), "--manager", str(workspace)]
    devices: list[WebSocket] = []
    pipe: PipeDaemon | None = None
    try:
        assert "started" in suit("start")
        # An editor is open (this test process stands in for it), so suit has something to track.
        editor_record = suit.home / "registry" / f"{os.getpid()}.json"
        editor_record.write_text(json.dumps({"version": 1, "pid": os.getpid(), "kind": "editor",
                                             "registeredAt": time.time() * 1000, "roots": [str(workspace)]}))
        # The editor's side: start the workspace service and turn on remote access.
        for arguments in (["--detach"], ["--configure-relay", relay.origin]):
            result = subprocess.run([*manager, *arguments], env=editor_environment, timeout=120, capture_output=True, text=True)
            assert result.returncode == 0, f"manager {arguments[0]} failed: {result.stderr}{result.stdout}"
        state = wait_until(lambda: next(iter(agent_state.glob("workspaces/*/relay-machine.json")), None), 30,
                           "no relay identity was created").parent
        machine = json.loads((state / "relay-machine.json").read_text())["machineId"]
        host = wait_until(lambda: next((item for item in suit.hosts() if item["state"] == "connected" and item["serviceRunning"]), None),
                          60, "the daemon did not hand its relay hosting to suit: " + suit("relay", "list"))
        assert host["machineId"] == machine and host["origin"] == relay.origin, host
        status = wait_until(lambda: (lambda value: value if value.get("connected") else None)(
            json.loads((state / "relay-status.json").read_text())) if (state / "relay-status.json").exists() else None,
            30, "the daemon does not report the relay as connected through suit")
        assert status["origin"] == relay.origin, status
        assert (suit.home / "relay-hosts" / f"{machine}.json").is_file(), "suit kept no host record"
        record = (suit.home / "relay-hosts" / f"{machine}.json").read_text()
        machine_token = stored_secret(credentials, f"relay:{relay.origin}/machine/{machine}")
        assert machine_token not in record, "the host record holds the bearer"
        print("  daemon attached to suit; suit holds the machine socket")

        device, device_token = secrets.token_hex(16), secrets.token_hex(32)
        status_code, _ = relay.http("PUT", f"/v1/machines/{machine}/devices/{device}", machine_token, {"token": device_token})
        assert status_code in (201, 204), status_code

        # The editor goes away, and its workspace service stops. suit keeps the machine socket.
        editor_record.unlink()
        manager_pid = json.loads((state / "endpoint.json").read_text())["managerPid"]
        assert "stopped" in suit("kill", str(manager_pid))
        wait_until(lambda: not (state / "endpoint.json").exists(), 30, "the workspace manager did not stop")
        wait_until(lambda: not suit.hosts()[0]["serviceRunning"], 30, "suit still shows the service running")
        time.sleep(26)  # twice suit's idle timeout (it rescans every 10 s), with nothing registered
        assert suit.running(), "suit idled out while hosting"
        assert suit.hosts()[0]["state"] == "connected", suit.hosts()
        print("  service stopped; suit stays up and connected past its idle timeout")

        # A device connects: the Worker accepts it only while a machine socket is open (suit's).
        socket_a = relay.device_socket(machine, device, device_token); devices.append(socket_a)
        assert socket_a.status == 101, f"device socket refused ({socket_a.status}); machine offline?"
        socket_a.send(envelope(device, b"device hello while the service is down"))
        started = wait_until(lambda: next((item for item in suit.hosts() if item["serviceRunning"]), None), 90,
                             "suit did not start the workspace service for the device")
        assert started["starts"] >= 1, started
        print(f"  a device frame started the workspace service on demand (pid {started['servicePid']})")
        socket_a.close()
        manager_pid = wait_until(lambda: json.loads((state / "endpoint.json").read_text())["managerPid"]
                                 if (state / "endpoint.json").exists() else None, 30, "no endpoint for the started manager")
        assert "stopped" in suit("kill", str(manager_pid))
        wait_until(lambda: not suit.hosts()[0]["serviceRunning"], 30, "the started service did not stop")

        if os.name == "nt":
            # Both directions through suit, with a stand-in daemon on suit's pipe.
            endpoint = json.loads((suit.home / "daemon.json").read_text())["endpoint"]
            starts = suit.hosts()[0]["starts"]
            pipe = PipeDaemon(endpoint, {"op": "relay-attach", "version": 1, "pid": os.getpid(), "root": host["root"],
                                         "stateDir": host["stateDir"], "machineId": machine, "origin": relay.origin,
                                         "executable": str(HL), "launcher": str(AGENT)})
            reply = json.loads(pipe.receive(10) or b"{}")
            assert reply.get("ok") is True, reply
            first = pipe.receive(10)
            assert first is not None and first[0] == 0x10 and json.loads(first[1:])["connected"] is True, first
            socket_b = relay.device_socket(machine, device, device_token); devices.append(socket_b)
            assert socket_b.status == 101, socket_b.status
            socket_b.send(envelope(device, b"ping through suit"))
            received: bytes | None = None
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                message = pipe.receive(1)
                if message and message[0] == 1:
                    received = message
                    break
            assert received is not None, "the device frame did not reach the attached daemon"
            kind, channel, payload = parse_envelope(received)
            assert channel == device and payload == b"ping through suit", (kind, channel, payload)
            pipe.send(envelope(device, b"pong through suit"))
            answer = socket_b.receive(20)
            assert answer is not None, "the daemon's frame did not reach the device"
            assert parse_envelope(answer)[2] == b"pong through suit", answer
            assert suit.hosts()[0]["starts"] == starts, "suit started a service although a daemon was attached"
            print("  frames pass both ways between a device and the attached daemon")

            # Two clients: both listed with their details, one disconnected from the CLI, the list follows.
            second, second_token = secrets.token_hex(16), secrets.token_hex(32)
            status_code, _ = relay.http("PUT", f"/v1/machines/{machine}/devices/{second}", machine_token, {"token": second_token})
            assert status_code in (201, 204), status_code
            socket_d = relay.device_socket(machine, second, second_token); devices.append(socket_d)
            assert socket_d.status == 101, socket_d.status
            socket_d.send(envelope(second, b"second client"))
            report = {"devices": [{"deviceId": device, "grants": ["workspace.files.read"], "connected": True}],
                      "pending": [second], "open": {"terminals": 1, "agents": 2}}
            pipe.send(bytes([0x11]) + json.dumps(report).encode())
            def clients() -> dict:
                return {client["id"]: client for client in suit.hosts()[0]["clients"]}
            listed = wait_until(lambda: (lambda value: value if set(value) == {device, second}
                                         and value[device]["kind"] == "device" and value[second]["kind"] == "pairing" else None)(clients()),
                                15, f"suit does not list both clients: {suit('relay', 'list')}")
            assert listed[device]["grants"] == ["workspace.files.read"], listed
            for client in listed.values():
                assert client["connectedAt"] > 0 and client["lastActivity"] >= client["connectedAt"] and client["framesIn"] >= 1, client
            view = suit.hosts()[0]
            assert view["open"] == {"terminals": 1, "agents": 2}, view
            text = suit("relay", "list")
            assert device in text and second in text and "2 clients connected" in text and "1 terminal(s), 2 agent session(s)" in text, text
            assert "2 devices connected" in json.loads(suit("status", "--json"))["tooltip"]
            menu = suit("menu")
            assert f"device {device[:12]}" in menu and f"pairing request {second[:12]}" in menu and "Disconnect" in menu, menu
            output = suit("relay", "disconnect", device[:8])
            assert f"disconnected {device}" in output, output
            reset = None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and reset is None:
                message = pipe.receive(1)
                if message and message[0] == 2 and message[1:17].hex() == device:
                    reset = message
            assert reset is not None, "the disconnected client's session was not reset in the daemon"
            wait_until(lambda: set(clients()) == {second}, 10, "the disconnected client is still listed")
            socket_b.send(envelope(device, b"after disconnect"))
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                message = pipe.receive(0.5)
                assert not (message and message[0] == 1 and message[1:17].hex() == device), "a disconnected client's frame was forwarded"
            assert "1 device connected" in json.loads(suit("status", "--json"))["tooltip"]
            # The other client closes its socket: the Worker resets its channel and suit drops it at once.
            socket_d.close()
            wait_until(lambda: not clients(), 10, "a closed client is still listed")
            print("  two clients listed with details; one disconnected from the CLI; a closed one dropped promptly")
            pipe.close(); pipe = None
            socket_b.close()

        # Stop hosting: paused in the workspace's settings, the machine socket closes, suit may idle out.
        output = suit("relay", "stop", workspace.name)
        assert "paused hosting" in output, output
        assert json.loads((state / "relay-settings.json").read_text()).get("hosting") == "paused"
        def device_refused() -> bool:
            probe = relay.device_socket(machine, device, device_token)
            probe.close()
            return probe.status == 503
        wait_until(device_refused, 30, "the relay still sees the machine online after Stop hosting", interval=0.5)
        # Watch the process, not `suit status`: every control request counts as activity and resets the idle clock.
        suit_pid = json.loads((suit.home / "daemon.json").read_text())["pid"]
        wait_until(lambda: not pid_alive(suit_pid), 45, "suit did not idle out once hosting was paused", interval=1)
        print("  Stop hosting paused the workspace; the relay sees it offline and suit idled out")

        # Resume without suit running, then suit hosts again from its records when it starts.
        assert "resumed hosting" in suit("relay", "resume", workspace.name)
        assert "hosting" not in json.loads((state / "relay-settings.json").read_text())
        assert "started" in suit("start")
        wait_until(lambda: next((item for item in suit.hosts() if item["state"] == "connected"), None), 60,
                   "suit did not host again from its records")
        socket_c = relay.device_socket(machine, device, device_token); devices.append(socket_c)
        assert socket_c.status == 101, socket_c.status
        print("  resumed: suit hosts again from its records after a restart")
    except BaseException:
        print("--- suit relay list\n" + suit.run("relay", "list", check=False).stdout, file=sys.stderr)
        print("--- suit list, status\n" + suit.run("list", "--json", check=False).stdout
              + suit.run("status", "--json", check=False).stdout, file=sys.stderr)
        print("--- worker log\n" + relay.tail(), file=sys.stderr)
        for log in [*agent_state.glob("workspaces/*/manager.log"), *agent_state.glob("workspaces/*/relay-*.json"),
                    *suit.home.glob("*.json"), *suit.home.glob("*.txt"), *suit.home.glob("relay-hosts/*.json")]:
            print(f"--- {log}\n" + log.read_text(errors="replace")[-3000:], file=sys.stderr)
        raise
    finally:
        if pipe is not None:
            pipe.close()
        for item in devices:
            item.close()
        suit.run("kill", "--all", check=False)
        suit.run("stop", check=False)
        try:
            wait_until(lambda: not suit.running(), 20, "suit did not stop")
        finally:
            relay.stop()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--login-only", action="store_true", help="skip the relay test (no Worker needed)")
    options = parser.parse_args()
    assert SUIT.is_file(), f"build suit first: {SUIT}"
    with tempfile.TemporaryDirectory(prefix="suit-relay-", ignore_cleanup_errors=True) as temporary:
        base = Path(temporary)
        (base / "login").mkdir()
        test_login(base / "login")
        print("PASS start at login (scratch key)")
        if not options.login_only:
            (base / "relay").mkdir()
            test_relay(base / "relay")
            print("PASS relay hosting under suit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
