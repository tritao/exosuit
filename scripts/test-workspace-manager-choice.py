#!/usr/bin/env python3
"""The editor's client choosing between two builds' managers for one folder (AttachmentTestMain manager-choice)."""
import json
import os
from pathlib import Path
import shutil
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

with tempfile.TemporaryDirectory(prefix="exosuit-choice-") as temporary:
    directory = Path(temporary)
    home, root = directory / "state", directory / "project"
    home.mkdir(mode=0o700)
    root.mkdir()
    # Another worktree's build: the same agent, launched from a path of its own.
    other = directory / "checkout/.claude/worktrees/other/agent/build/host/main.hl"
    other.parent.mkdir(parents=True)
    shutil.copy2(launcher, other)

    environment = manager_environment(ROOT)
    environment["EXOSUIT_AGENT_STATE_HOME"] = str(home)
    foreign = dict(environment, EXOSUIT_AGENT_LAUNCHER=str(other))
    started = subprocess.run([str(runtime), str(other), "--manager", str(root), "--detach", "--idle-seconds", "120"],
                             env=foreign, cwd=str(root), capture_output=True, text=True, timeout=120)
    if started.returncode != 0:
        sys.exit("starting the other build's manager failed: " + started.stderr)
    assert Path(json.loads(started.stdout)["launcher"]) == other

    client = dict(environment)
    native = output / "native"
    libraries = [str(path) for path in sorted(native.iterdir()) if path.is_dir()] if native.is_dir() else []
    variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    client[variable] = os.pathsep.join(libraries + [client[variable]])
    result = subprocess.run([str(runtime), str(output / "main.hl"), "manager-choice", str(root.resolve()), str(launcher)],
                            env=client, timeout=400)
    # Both managers stop once idle; stop them now so the temporary folder can go.
    for state in (home / "workspaces").iterdir():
        try:
            endpoint = json.loads((state / "endpoint.json").read_text())
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(endpoint["managerPid"])] if os.name == "nt"
                           else ["kill", str(endpoint["managerPid"])], capture_output=True, timeout=30)
        except (FileNotFoundError, KeyError, ValueError):
            pass
    sys.exit(result.returncode)
