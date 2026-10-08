#!/usr/bin/env python3
"""Exercise Haxe-managed workspace updates with two attached clients."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
from agent_test_runtime import launcher_path

HAXEON = os.environ.get("HAXEON_BIN", str(Path(os.environ.get("HAXEON_ROOT", str(ROOT / "haxeon"))) / "scripts/haxeon"))
MODE = ["--self-hosted"] if os.environ.get("HAXEON_SELF_HOSTED") == "1" else []
PROJECT = ROOT / "tests/workspace-attachment/haxeon.json"


def run_update(mode: str, base: Path) -> None:
    project = base / "project"
    state = base / "state"
    project.mkdir()
    revision = base / "revision"
    revision.write_text("a" * 64)
    launcher = launcher_path(ROOT)
    environment = dict(
        os.environ,
        XDG_STATE_HOME=str(state),
        EXOSUIT_AGENT_BUILD_ID_FILE=str(revision),
        EXOSUIT_HAXEON_CLI_PYTHON=sys.executable,
        EXOSUIT_PROJECT_ROOT=str(ROOT),
    )
    if mode == "update-legacy":
        environment["EXOSUIT_AGENT_MANAGED_UPDATES"] = "0"
    try:
        subprocess.run(
            [HAXEON, "run", "--project", str(PROJECT), *MODE, "--", mode,
             str(project), str(launcher), str(revision)],
            env=environment,
            check=True,
            timeout=180,
        )
    finally:
        for endpoint in state.glob("exosuit/workspaces/*/endpoint.json"):
            try:
                os.kill(json.loads(endpoint.read_text())["managerPid"], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
        deadline = time.monotonic() + 15
        while list(state.glob("exosuit/workspaces/*/endpoint.json")) and time.monotonic() < deadline:
            time.sleep(0.05)


def main() -> None:
    for mode in ["update-idle", "update-busy", "update-now", "update-legacy"]:
        with tempfile.TemporaryDirectory(prefix="exa-update-") as temporary:
            run_update(mode, Path(temporary))


if __name__ == "__main__":
    main()
