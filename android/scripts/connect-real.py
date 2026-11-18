#!/usr/bin/env python3
"""Talks to a running exohost's control pipe the way the editor's Remote Access panel does (Windows).

Used by connect-real.ps1. Each subcommand prints one JSON object on stdout.

  connect-real.py status   [--home DIR]                         remote-status (read only)
  connect-real.py devices  [--home DIR]                         remote-devices (read only)
  connect-real.py enable   [--home DIR] [--relay ORIGIN]        remote-enable, only when remote access is off
  connect-real.py invite   [--home DIR] [--ttl 300]             remote-invite: a one-time pairing URL
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
    """Mirrors ExohostPaths.endpoint(): the pipe name carries a hash of an explicitly configured home."""
    name = "exosuit-exohost-" + sanitized_user()
    configured = home or os.environ.get("EXOSUIT_EXOHOST_HOME")
    if configured:
        name += "-" + hashlib.sha256(configured.encode()).hexdigest()[:12]
    return "\\\\.\\pipe\\" + name


def default_relay() -> str:
    """The relay the Remote panel proposes: RelayUrl.DEFAULT (src/config/RelayUrl.hx)."""
    text = (ROOT / "src" / "config" / "RelayUrl.hx").read_text(encoding="utf-8")
    return re.search(r'DEFAULT\s*=\s*"([^"]+)"', text).group(1)


class Pipe:
    """One connection to exohost's pipe, speaking its framed messages (the same framing as scripts/exohost_harness.py)."""

    def __init__(self, path: str, request: dict) -> None:
        import ctypes
        import msvcrt
        self.ctypes = ctypes
        try:
            self.file = open(path, "r+b", buffering=0)
        except OSError as error:
            raise SystemExit(json.dumps({"ok": False, "error": f"exohost is not running on {path}: {error}"}))
        self.handle = msvcrt.get_osfhandle(self.file.fileno())
        self.buffer = b""
        message = json.dumps(request).encode()
        self.file.write(b"HMPK\x01\x00" + len(message).to_bytes(4, "big") + message)

    def receive(self, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 10:
                length = int.from_bytes(self.buffer[6:10], "big")
                if len(self.buffer) >= 10 + length:
                    return json.loads(self.buffer[10:10 + length])
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
        self.file.close()


def control(home: str | None, request: dict, timeout: float = 15) -> dict:
    pipe = Pipe(endpoint(home), request)
    try:
        return pipe.receive(timeout)
    finally:
        pipe.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["status", "devices", "enable", "invite", "approve", "pipe"])
    parser.add_argument("--home", default=None)
    parser.add_argument("--relay", default=None)
    parser.add_argument("--ttl", type=int, default=300)
    parser.add_argument("--device", default=None)
    arguments = parser.parse_args()
    home = arguments.home
    if arguments.command == "pipe":
        print(json.dumps({"endpoint": endpoint(home)}))
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
    elif arguments.command == "invite":
        reply = control(home, {"op": "remote-invite", "ttl": arguments.ttl}, timeout=40)
    else:
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
