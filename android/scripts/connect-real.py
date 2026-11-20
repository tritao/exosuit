#!/usr/bin/env python3
"""Talks to a running exohost's control pipe the way the editor's Remote Access panel does (a named pipe on Windows, a Unix socket elsewhere).

Used by connect-real.ps1. Each subcommand prints one JSON object on stdout.

  connect-real.py status   [--home DIR]                         remote-status (read only)
  connect-real.py devices  [--home DIR]                         remote-devices (read only)
  connect-real.py enable   [--home DIR] [--relay ORIGIN]        remote-enable, only when remote access is off
  connect-real.py invite   [--home DIR] [--ttl 300]             remote-invite: a one-time pairing URL
  connect-real.py disable  [--home DIR]                         remote-disable (relay switch)
  connect-real.py grant    --home DIR --device ID --workspace W  remote-grant all (isolated test hosts only)
  connect-real.py approve  --home DIR [--device ID]             remote-approve with no workspaces (isolated test hosts only)

Without --home the control pipe is the user's own exohost (\\\\.\\pipe\\exosuit-exohost-<user>), as the editor finds it;
EXOSUIT_EXOHOST_HOME moves it, exactly as exohost reads it (src/exohost/ExohostPaths.hx). Nothing here starts or stops exohost,
and it never writes a file. `approve` refuses to run against the user's own exohost: approval belongs to the owner, in the editor.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sanitized_user() -> str:
    name = os.environ.get("USERNAME") or os.environ.get("USER") or "user"
    return re.sub(r"[^0-9A-Za-z_-]", "_", name)


def endpoint(home: str | None) -> str:
    """Mirrors ExohostPaths.endpoint(): the pipe name carries a hash of an explicitly configured home.
    Off Windows the endpoint is a Unix socket in the home; the running daemon records it in <home>/daemon.json."""
    if os.name != "nt":
        configured = home or os.environ.get("EXOSUIT_EXOHOST_HOME")
        if not configured:
            raise SystemExit(json.dumps({"ok": False, "error": "off Windows pass --home (or set EXOSUIT_EXOHOST_HOME): the isolated exohost's folder"}))
        try:
            return json.loads((Path(configured) / "daemon.json").read_text())["endpoint"]
        except (OSError, ValueError, KeyError) as error:
            raise SystemExit(json.dumps({"ok": False, "error": f"exohost is not running in {configured}: {error}"}))
    name = "exosuit-exohost-" + sanitized_user()
    configured = home or os.environ.get("EXOSUIT_EXOHOST_HOME")
    if configured:
        name += "-" + hashlib.sha256(configured.encode()).hexdigest()[:12]
    return "\\\\.\\pipe\\" + name


def refuse_real_home(home: str | None) -> None:
    """approve and grant belong to isolated test hosts: refuse the user's default home."""
    configured = home or os.environ.get("EXOSUIT_EXOHOST_HOME")
    real = Path.home() / ".local" / "state" / "exosuit" / "exohost"
    if configured and Path(configured).expanduser().resolve() == real.resolve():
        raise SystemExit(json.dumps({"ok": False, "error": "refusing: this is the user's own exohost home"}))


def default_relay() -> str:
    """The relay the Remote panel proposes: RelayUrl.DEFAULT (src/config/RelayUrl.hx)."""
    text = (ROOT / "src" / "config" / "RelayUrl.hx").read_text(encoding="utf-8")
    return re.search(r'DEFAULT\s*=\s*"([^"]+)"', text).group(1)


class Pipe:
    """One connection to exohost's pipe, speaking its framed messages (the same framing as scripts/exohost_harness.py)."""

    def __init__(self, path: str, request: dict) -> None:
        self.buffer = b""
        message = json.dumps(request).encode()
        frame = b"HMPK\x01\x00" + len(message).to_bytes(4, "big") + message
        if os.name == "nt":
            import ctypes
            import msvcrt
            self.ctypes = ctypes
            self.socket = None
            try:
                self.file = open(path, "r+b", buffering=0)
            except OSError as error:
                raise SystemExit(json.dumps({"ok": False, "error": f"exohost is not running on {path}: {error}"}))
            self.handle = msvcrt.get_osfhandle(self.file.fileno())
            self.file.write(frame)
        else:
            import socket
            self.socket = socket.socket(socket.AF_UNIX)
            try:
                self.socket.connect(path)
            except OSError as error:
                raise SystemExit(json.dumps({"ok": False, "error": f"exohost is not running on {path}: {error}"}))
            self.socket.sendall(frame)

    def receive(self, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 10:
                length = int.from_bytes(self.buffer[6:10], "big")
                if len(self.buffer) >= 10 + length:
                    return json.loads(self.buffer[10:10 + length])
            if self.socket is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SystemExit(json.dumps({"ok": False, "error": "exohost did not answer in time"}))
                self.socket.settimeout(remaining)
                try:
                    chunk = self.socket.recv(65536)
                except OSError:
                    raise SystemExit(json.dumps({"ok": False, "error": "exohost did not answer in time"}))
                if not chunk:
                    raise SystemExit(json.dumps({"ok": False, "error": "exohost closed the socket"}))
                self.buffer += chunk
                continue
            count = self.ctypes.c_ulong(0)
            if not self.ctypes.windll.kernel32.PeekNamedPipe(self.ctypes.c_void_p(self.handle), None, 0, None, self.ctypes.byref(count), None):
                raise SystemExit(json.dumps({"ok": False, "error": "exohost closed the pipe"}))
            if count.value:
                self.buffer += self.file.read(count.value)
                continue
            if time.monotonic() >= deadline:
                raise SystemExit(json.dumps({"ok": False, "error": "exohost did not answer in time"}))
            time.sleep(0.02)

    def close(self) -> None:
        (self.socket or self.file).close()


def control(home: str | None, request: dict, timeout: float = 15) -> dict:
    pipe = Pipe(endpoint(home), request)
    try:
        return pipe.receive(timeout)
    finally:
        pipe.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["status", "devices", "enable", "disable", "invite", "approve", "grant", "pipe", "relay", "create-workspace"])
    parser.add_argument("--home", default=None)
    parser.add_argument("--relay", default=None)
    parser.add_argument("--ttl", type=int, default=300)
    parser.add_argument("--device", default=None)
    parser.add_argument("--workspace", action="append", default=[])
    arguments = parser.parse_args()
    home = arguments.home
    if arguments.command == "pipe":
        print(json.dumps({"endpoint": endpoint(home)}))
        return 0
    if arguments.command == "relay":
        print(json.dumps({"relay": default_relay()}))
        return 0
    if arguments.command == "status":
        reply = control(home, {"op": "remote-status"})
    elif arguments.command == "devices":
        reply = control(home, {"op": "remote-devices"})
    elif arguments.command == "enable":
        status = control(home, {"op": "remote-status"})
        if status.get("enabled"):
            # The panel offers "Enable remote access" only while it is off; a relay already in use is never changed.
            reply = dict(status, alreadyEnabled=True)
        else:
            reply = control(home, {"op": "remote-enable", "origin": (arguments.relay or default_relay()).rstrip("/")})
    elif arguments.command == "disable":
        reply = control(home, {"op": "remote-disable"}, timeout=30)
    elif arguments.command == "create-workspace":
        if not (home or os.environ.get("EXOSUIT_EXOHOST_HOME")):
            raise SystemExit(json.dumps({"ok": False, "error": "create-workspace only runs against an isolated exohost (--home)"}))
        if len(arguments.workspace) != 2:
            raise SystemExit(json.dumps({"ok": False, "error": "usage: create-workspace --workspace NAME --workspace FOLDER"}))
        reply = control(home, {"op": "workspace-create", "name": arguments.workspace[0], "folders": [arguments.workspace[1]]})
    elif arguments.command == "grant":
        refuse_real_home(home)
        if not (home or os.environ.get("EXOSUIT_EXOHOST_HOME")):
            raise SystemExit(json.dumps({"ok": False, "error": "grant only runs against an isolated exohost (--home)"}))
        reply = control(home, {"op": "remote-grant", "deviceId": arguments.device, "workspaces": [{"workspace": w, "preset": "all"} for w in arguments.workspace]})
    elif arguments.command == "invite":
        reply = control(home, {"op": "remote-invite", "ttl": arguments.ttl}, timeout=40)
    else:
        refuse_real_home(home)
        if not (home or os.environ.get("EXOSUIT_EXOHOST_HOME")):
            raise SystemExit(json.dumps({"ok": False, "error": "approve only runs against an isolated exohost (--home): the owner approves a real one in the editor"}))
        devices = control(home, {"op": "remote-devices"})
        pending = [item for item in devices.get("pending", []) if not arguments.device or item["deviceId"] == arguments.device]
        if not pending:
            reply = {"ok": False, "error": "no device is waiting for approval"}
        else:
            reply = control(home, {"op": "remote-approve", "deviceId": pending[0]["deviceId"], "workspaces": []}, timeout=60)
            reply["deviceId"] = pending[0]["deviceId"]
    print(json.dumps(reply))
    return 0


if __name__ == "__main__":
    sys.exit(main())
