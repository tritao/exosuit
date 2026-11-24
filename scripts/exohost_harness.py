"""What the exohost and relay tests share: paths, an isolated exohost, the local relay Worker and process helpers.

Every exohost here gets its own EXOSUIT_EXOHOST_HOME and PRAGTICAL_PORTABLE, so the user's exohost and editor state are never
involved. Relay is the local Wrangler Worker (relay/worker, `npm ci --no-audit --no-fund` first) on a loopback port.
Used by test-machine-remote.py and mobile-machine-host.py.
"""
from __future__ import annotations

import ctypes
import json
import os
import platform
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

from test_driver import HL, ROOT, isolated_exohost, wait_until, with_libraries

# Tests must not reach the user's exohost: what they start without a fixture's own home gets a temporary one, unstarted.
os.environ.update(isolated_exohost())

EXOHOST = ROOT / "exohost" / "build" / "host" / "main.hl"
AGENT = ROOT / "agent" / "build" / "host" / "main.hl"
WRANGLER = ROOT / "relay" / "worker" / "node_modules" / "wrangler" / "bin" / "wrangler.js"
if os.name == "nt":
    _workerd_package = "workerd-windows-64"
elif sys.platform == "darwin":
    _workerd_package = "workerd-darwin-arm64" if platform.machine() == "arm64" else "workerd-darwin-64"
else:
    _workerd_package = "workerd-linux-arm64" if platform.machine() in ("aarch64", "arm64") else "workerd-linux-64"
WORKERD = ROOT / "relay" / "worker" / "node_modules" / "@cloudflare" / _workerd_package


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def kill_tree(pid: int) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True, timeout=30)
    else:
        try:
            os.killpg(pid, 9)
        except OSError:
            pass


class Exohost:
    def __init__(self, base: Path, extra: dict[str, str], home: str = "exohost-home") -> None:
        self.home = base / home
        portable = base / "portable"
        portable.mkdir(exist_ok=True)
        credentials = base / "relay-credentials"
        credentials.mkdir(mode=0o700, exist_ok=True)
        self.environment = with_libraries(
            dict(os.environ, EXOSUIT_RELAY_TEST_CREDENTIALS_DIR=str(credentials), EXOSUIT_EXOHOST_HOME=str(self.home), EXOSUIT_EXOHOST_SCAN="0", EXOSUIT_EXOHOST_TRAY="0", EXOSUIT_EXOHOST_AUTOSTART="0",
                 EXOSUIT_EXOHOST_LAUNCHER=str(EXOHOST), PRAGTICAL_PORTABLE=str(portable), **extra),
            EXOHOST.parent / "native", AGENT.parent / "native")

    def run(self, *arguments: str, timeout: float = 60, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run([str(HL), str(EXOHOST), *arguments], env=self.environment, capture_output=True, text=True,
                                timeout=timeout)
        if check:
            assert result.returncode == 0, f"exohost {' '.join(arguments)} failed ({result.returncode}): {result.stderr}{result.stdout}"
        return result

    def __call__(self, *arguments: str, timeout: float = 60) -> str:
        return self.run(*arguments, timeout=timeout).stdout

    def control(self, request: dict) -> dict:
        """One control request over exohost's pipe, as the CLI sends it."""
        endpoint = json.loads((self.home / "daemon.json").read_text())["endpoint"]
        client = PipeClient(endpoint, request)
        try:
            return json.loads(client.receive(10) or b"{}")
        finally:
            client.close()


class PipeClient:
    """One connection to exohost's pipe, speaking its framed messages."""

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
            raise ConnectionError("exohost closed the pipe")
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

    def stop(self) -> None:
        if self.process.poll() is None:
            kill_tree(self.process.pid)
        self.log.close()
