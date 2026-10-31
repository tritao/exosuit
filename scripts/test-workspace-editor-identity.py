#!/usr/bin/env python3
"""The editor attaching to a machine workspace's service by the workspace's id (AttachmentTestMain workspace-identity).

With EXOSUIT_WORKSPACE_IDENTITY=workspace a two-folder workspace gets one service, state `workspaces/<id>`, whose groups
outlive the service. Without the flag each folder keeps a service of its own, state `workspaces/<hash of the folder>`.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import haxeon_cli
from agent_test_runtime import manager_environment, runtime_paths

PROJECT = ROOT / "tests/workspace-attachment/haxeon.json"
if haxeon_cli.run_cli(ROOT, ["build", "--project", str(PROJECT)]) != 0:
    sys.exit("building the attachment test failed")
runtime, launcher = runtime_paths(ROOT)
output = PROJECT.parent / "build/host"


def stop_managers(home):
    # Managers stop once idle; stop them now so the state can be reused and the temporary folder can go.
    for endpoint in (home / "workspaces").glob("*/endpoint.json"):
        try:
            pid = json.loads(endpoint.read_text())["managerPid"]
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)] if os.name == "nt" else ["kill", str(pid)],
                           capture_output=True, timeout=30)
        except (FileNotFoundError, KeyError, ValueError):
            pass
        endpoint.unlink(missing_ok=True)


def client(environment, first, second, phase, previous="-"):
    environment = dict(environment)
    native = output / "native"
    libraries = [str(path) for path in sorted(native.iterdir()) if path.is_dir()] if native.is_dir() else []
    variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    environment[variable] = os.pathsep.join(libraries + [environment[variable]])
    result = subprocess.run([str(runtime), str(output / "main.hl"), "workspace-identity", str(first), str(launcher), str(second), phase, previous],
                            env=environment, capture_output=True, text=True, timeout=400)
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.exit(f"client failed ({phase}): {result.stderr}")
    match = re.search(r"GENERATION (\w+)", result.stdout)
    assert match, result.stdout
    return match.group(1)


def states(home):
    return sorted(path.name for path in (home / "workspaces").iterdir() if path.is_dir())


with tempfile.TemporaryDirectory(prefix="exosuit-wsid-", ignore_cleanup_errors=True) as temporary:
    directory = Path(temporary)
    first, second = (directory / "one").resolve(), (directory / "two").resolve()
    first.mkdir()
    second.mkdir()
    base = manager_environment(ROOT)
    base["EXOSUIT_SUIT"] = "off"
    try:
        # With the flag: one service for both folders, keyed by the workspace.
        home = directory / "state-on"
        home.mkdir(mode=0o700)
        on = dict(base, EXOSUIT_AGENT_STATE_HOME=str(home), EXOSUIT_WORKSPACE_IDENTITY="workspace")
        generation = client(on, first, second, "create")
        assert states(home) == ["ws1"], states(home)
        endpoint = json.loads((home / "workspaces/ws1/endpoint.json").read_text())
        assert endpoint["workspaceId"] == "ws1" and endpoint["generation"] == generation
        identity = json.loads((home / "workspaces/ws1/workspace.json").read_text())
        assert identity["workspace"] == "ws1" and len(identity["folders"]) == 2, identity
        # The editor restarts and so does the service: the group made through it is still there.
        stop_managers(home)
        client(on, first, second, "check", generation)
        assert states(home) == ["ws1"], states(home)
        # Without the flag: a service per folder, as before.
        home = directory / "state-off"
        home.mkdir(mode=0o700)
        off = dict(base, EXOSUIT_AGENT_STATE_HOME=str(home))
        off.pop("EXOSUIT_WORKSPACE_IDENTITY", None)
        client(off, first, second, "create")
        names = states(home)
        assert len(names) == 2 and all(re.fullmatch(r"[0-9a-f]{20}", name) for name in names), names
    finally:
        for name in ("state-on", "state-off"):
            if (directory / name / "workspaces").is_dir():
                stop_managers(directory / name)
    print("PASS: one service per workspace with the flag, one per folder without it")
