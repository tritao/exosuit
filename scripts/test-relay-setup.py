#!/usr/bin/env python3
"""Verify relay settings survive a workspace manager restart."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
from agent_test_runtime import launcher_path

HAXEON = os.environ.get("HAXEON_BIN", str(Path(os.environ.get("HAXEON_ROOT", str(ROOT / "haxeon"))) / "scripts/haxeon"))
MODE = ["--self-hosted"] if os.environ.get("HAXEON_SELF_HOSTED") == "1" else []
PROJECT = ROOT / "tests/workspace-attachment/haxeon.json"
ORIGIN = "https://127.0.0.1:1"


def run_client(mode: str, root: Path, launcher: Path, environment: dict[str, str]) -> None:
    subprocess.run(
        [HAXEON, "run", "--project", str(PROJECT), *MODE, "--", mode,
         str(root), str(launcher), ORIGIN],
        env=environment,
        check=True,
        timeout=120,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="exa-relay-") as temporary:
        base = Path(temporary)
        root, state = base / "project", base / "state"
        root.mkdir()
        launcher = launcher_path(ROOT)
        environment = dict(os.environ, XDG_STATE_HOME=str(state))
        key = hashlib.sha256(os.fsencode(root.resolve())).hexdigest()[:20]
        workspace = state / "exosuit" / "workspaces" / key
        endpoint = workspace / "endpoint.json"
        try:
            run_client("remote-setup", root, launcher, environment)
            settings = workspace / "relay-settings.json"
            value = json.loads(settings.read_text())
            assert value == {"version": 1, "origin": ORIGIN}
            assert settings.stat().st_mode & 0o077 == 0

            descriptor = json.loads(endpoint.read_text())
            os.kill(descriptor["managerPid"], signal.SIGTERM)
            deadline = time.monotonic() + 15
            while endpoint.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            assert not endpoint.exists(), "Workspace manager did not stop"

            run_client("relay-persist-inspect", root, launcher, environment)
            print("PASS: relay configuration survives manager restart", flush=True)
        finally:
            for current in state.glob("exosuit/workspaces/*/endpoint.json"):
                try:
                    os.kill(json.loads(current.read_text())["managerPid"], signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError):
                    pass
            for identity in state.glob("exosuit/workspaces/*/relay-machine.json"):
                machine_id = json.loads(identity.read_text())["machineId"]
                subprocess.run(
                    [HAXEON, "run", "--project", str(PROJECT), *MODE, "--", "cleanup-relay",
                     machine_id, ORIGIN],
                    env=environment,
                    check=True,
                    timeout=120,
                )
            deadline = time.monotonic() + 15
            while list(state.glob("exosuit/workspaces/*/endpoint.json")) and time.monotonic() < deadline:
                time.sleep(0.05)


if __name__ == "__main__":
    main()
