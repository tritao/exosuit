#!/usr/bin/env python3
"""Machine-level remote access end to end (M19 Phase 9, ADR 0005 section 4), isolated from the user's session.

Starts the local relay Worker (relay/worker, `npm ci` first; loopback http), an isolated exohost (its own
EXOSUIT_EXOHOST_HOME, agent state and a file credential store in the test's temporary directory) and runs
tests/machine-remote: two workspaces under one exohost, a fake device that pairs once with the machine, is granted
workspace A only, sees A (not B) in the directory, opens A and reads its catalog; granting B makes B appear and
openable; dropping B closes its stream; the device reconnects; revoking it ends its channel and refuses a new one.

Build first: agent, exohost and tests/machine-remote (scripts/haxeon_cli.py build --project tests/machine-remote/haxeon.json).
This script only starts the processes and checks the test program's exit code; the scenario is in Haxe.
Every process it starts is stopped at the end, including the workspace services exohost started.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import exohost_harness as harness  # noqa: E402

ROOT = harness.ROOT
TEST = ROOT / "tests" / "machine-remote" / "build" / "host" / "main.hl"


def processes_under(base: Path) -> list[int]:
    """Pids of processes whose command line names the test's temporary directory (exohost, services, the Worker's children)."""
    if os.name != "nt":
        return []
    script = ("Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('%s') } | "
              "ForEach-Object { $_.ProcessId }" % str(base).replace("'", "''"))
    result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=60)
    return [int(line) for line in result.stdout.split() if line.strip().isdigit() and int(line) != os.getpid()]


def main() -> int:
    assert harness.WRANGLER.is_file(), f"run `npm ci` in relay/worker first ({harness.WRANGLER} is missing)"
    assert any(harness.WORKERD.glob("bin/workerd*")), (
        f"workerd's binary is missing under {harness.WORKERD}: `npm ci --no-audit --no-fund` in relay/worker; if npm blocked its install "
        "script, `npm install-scripts approve workerd` then `npm rebuild workerd`")
    for built in (harness.EXOHOST, harness.AGENT, TEST):
        assert built.is_file(), f"build first: {built}"
    with tempfile.TemporaryDirectory(prefix="machine-remote-", ignore_cleanup_errors=True) as temporary:
        base = Path(temporary)
        credentials = base / "credentials"; credentials.mkdir()
        folder_a = base / "folder-a"; folder_a.mkdir()
        folder_b = base / "folder-b"; folder_b.mkdir()
        relay = harness.Relay(base)
        exohost = harness.Exohost(base, {
            "EXOSUIT_EXOHOST_IDLE_SECONDS": "30", "EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP": "1",
            "EXOSUIT_RELAY_TEST_CREDENTIALS_DIR": str(credentials), "EXOSUIT_AGENT_STATE_HOME": str(base / "agent-state"),
            "EXOSUIT_AGENT_LAUNCHER": str(harness.AGENT), "EXOSUIT_EXOHOST_LOGIN_KEY": "HKCU\\Software\\ExosuitExohostTest\\unused"})
        code = 1
        try:
            assert "started" in exohost("start")
            native = [path for path in (TEST.parent / "native").glob("*") if path.is_dir()]
            environment = dict(exohost.environment)
            variable = "PATH" if os.name == "nt" else "LD_LIBRARY_PATH"
            environment[variable] = os.pathsep.join([str(path) for path in native] + [environment[variable]])
            result = subprocess.run([str(harness.HL), str(TEST), "--origin", relay.origin, "--folder-a", str(folder_a), "--folder-b", str(folder_b)],
                                    env=environment, capture_output=True, text=True, timeout=300)
            sys.stdout.write(result.stdout)
            if result.returncode != 0:
                sys.stderr.write(result.stderr)
                sys.stderr.write("--- relay log ---\n" + relay.tail() + "\n")
            code = result.returncode
        finally:
            exohost.run("stop", check=False)
            relay.stop()
            for pid in processes_under(base):
                harness.kill_tree(pid)
    return code


if __name__ == "__main__":
    sys.exit(main())
