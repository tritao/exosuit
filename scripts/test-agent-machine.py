#!/usr/bin/env python3
"""This machine's manager registry, the --machine listing, and a second manager seeded with --seed-from."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from agent_test_runtime import manager_command, manager_environment

MANAGER = manager_command(ROOT)
AGENT = MANAGER[:-1]


def run(environment, root, *arguments, check=True):
    result = subprocess.run([*AGENT, *arguments], env=environment, cwd=str(root), capture_output=True, text=True, timeout=120)
    if check and result.returncode != 0:
        raise RuntimeError(f"{arguments} exited {result.returncode}: {result.stderr}")
    return result


def catalog(state):
    database = sqlite3.connect(f"file:{Path(state) / 'catalog.sqlite'}?mode=ro", uri=True)
    try:
        groups = database.execute("SELECT id, revision, payload FROM workspace_groups ORDER BY id").fetchall()
        epoch = database.execute("SELECT epoch FROM workspace_meta").fetchone()[0]
        events = database.execute("SELECT count(*) FROM workspace_events").fetchone()[0]
        has_devices = database.execute("SELECT count(*) FROM sqlite_master WHERE name='workspace_devices'").fetchone()[0]
        devices = database.execute("SELECT count(*) FROM workspace_devices").fetchone()[0] if has_devices else 0
        return groups, epoch, events, devices
    finally:
        database.close()


with tempfile.TemporaryDirectory(prefix="exosuit-machine-") as temporary:
    home, root = Path(temporary) / "state", Path(temporary) / "project"
    home.mkdir(mode=0o700)
    root.mkdir()
    environment = manager_environment(ROOT)
    environment["EXOSUIT_AGENT_STATE_HOME"] = str(home)

    def machine():
        return json.loads(run(environment, root, "--machine").stdout)

    first = json.loads(run(environment, root, "--manager", str(root), "--detach", "--idle-seconds", "8").stdout)
    assert Path(first["launcher"]) == Path(AGENT[1]), first
    listing = machine()
    expected_name = os.environ.get("COMPUTERNAME", "").lower() if os.name == "nt" else None
    assert listing["machine"] and (expected_name is None or listing["machine"] == expected_name), listing
    assert [m["managerPid"] for m in listing["managers"]] == [first["managerPid"]], listing
    default_state = listing["managers"][0]["stateDir"]
    assert listing["managers"][0]["defaultState"], listing
    assert len(list((home / "managers").glob("*.json"))) == 1

    own = home / "workspaces" / "own"
    second = json.loads(run(environment, root, "--manager", str(root), "--detach", "--idle-seconds", "8",
                            "--state-dir", str(own), "--seed-from", default_state).stdout)
    assert second["generation"] != first["generation"]
    listing = machine()
    assert sorted(m["defaultState"] for m in listing["managers"]) == [False, True], listing

    source, copy = catalog(default_state), catalog(own)
    assert copy[0] == source[0] and copy[0], "the copy keeps the source's groups"
    assert copy[1] == source[1], "the copy keeps the epoch its operation log is checked against"
    assert copy[3] == 0, "the copy has no paired devices"
    assert not list(own.glob("catalog.sqlite.seed*"))
    found = json.loads(run(environment, root, "--manager", str(root), "--discover", "--state-dir", str(own)).stdout)
    assert found["generation"] == second["generation"]

    refused = run(environment, root, "--manager", str(root), "--discover", "--seed-from", default_state, check=False)
    assert refused.returncode != 0 and "--seed-from" in refused.stderr, refused.stderr

    deadline = time.monotonic() + 60
    while machine()["managers"] and time.monotonic() < deadline:
        time.sleep(0.5)
    assert machine()["managers"] == [], "idle managers leave the listing"
    assert not list((home / "managers").glob("*.json")), "and remove their records"
print("agent machine registry: ok")
