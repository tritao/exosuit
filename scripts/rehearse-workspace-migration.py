#!/usr/bin/env python3
"""Rehearses M19 Phase 4's migration on a copy of this machine's real state, leaving the real state untouched.

Copies the agent's state folders to a temporary folder, starts each workspace in suit's machine.json there with its
folders (as the editor does), and checks that every group, session, terminal and terminal history of each folder's old
state arrived; that a second start changes nothing; and that --restore-migration puts each folder's state back.
Prints one line per workspace. `--keep` keeps the copy for inspection.
"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from agent_test_runtime import manager_command, manager_environment

AGENT = manager_command(ROOT)[:-1]


def state_base():
    configured = os.environ.get("EXOSUIT_AGENT_STATE_HOME")
    if configured:
        return Path(configured)
    if os.name == "nt":
        return Path(os.environ["LOCALAPPDATA"]) / "Exosuit"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "exosuit"


def suit_home():
    configured = os.environ.get("EXOSUIT_SUIT_HOME")
    if configured:
        return Path(configured)
    return state_base() / "suit" if os.name == "nt" else Path.home() / ".local" / "share" / "exosuit-suit"


def counts(catalog):
    if not catalog.exists():
        return (0, 0, 0, 0)
    database = sqlite3.connect(f"file:{catalog}?mode=ro", uri=True)
    try:
        tables = {row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        return tuple(database.execute(f"SELECT count(*) FROM {table}").fetchone()[0] if table in tables else 0
                     for table in ("workspace_groups", "workspace_agents", "workspace_terminals", "workspace_terminal_history"))
    finally:
        database.close()


def old_states(base):
    """Each folder-keyed state folder by its folder, with its catalog's counts."""
    result = {}
    for state in (base / "workspaces").iterdir():
        identity = state / "workspace.json"
        if state.is_dir() and identity.exists():
            value = json.loads(identity.read_text())
            if value.get("version") == 1:
                result[os.path.normcase(value["root"])] = (state, counts(state / "catalog.sqlite"))
    return result


def copy_state(source, destination):
    """Copies state folders keeping them private: the agent refuses state other users could read."""
    skipped = ["agent.lock", "*.sqlitekit-lock", "endpoint.json"]
    if os.name == "nt":
        # robocopy keeps the ACLs (/COPY:DATS); exit codes below 8 mean success.
        result = subprocess.run(["robocopy", str(source), str(destination), "/E", "/COPY:DATS", "/DCOPY:DAT", "/NFL", "/NDL", "/NJH", "/NJS",
                                 "/XF", *skipped], capture_output=True, text=True)
        if result.returncode >= 8:
            raise RuntimeError(f"robocopy failed ({result.returncode}): {result.stdout}")
    else:
        shutil.copytree(source, destination, ignore=shutil.ignore_patterns(*skipped))


def run(environment, *arguments, check=True):
    result = subprocess.run([*AGENT, *arguments], env=environment, capture_output=True, text=True, timeout=120)
    if check and result.returncode != 0:
        raise RuntimeError(f"{arguments[:4]} exited {result.returncode}: {result.stderr.strip()}")
    return result


def stop(state, endpoint):
    (state / "stop-request.json").write_text(json.dumps({"version": 1, "generation": endpoint["generation"]}) + "\n")
    deadline = time.monotonic() + 30
    while (state / "endpoint.json").exists() and time.monotonic() < deadline:
        time.sleep(0.1)


def main():
    keep = "--keep" in sys.argv
    real_base = state_base()
    machine = json.loads((suit_home() / "machine.json").read_text())
    copy = Path(tempfile.mkdtemp(prefix="exosuit-rehearsal-"))
    base = copy / "state"
    copy_state(real_base / "workspaces", base / "workspaces")
    environment = manager_environment(ROOT)
    environment["EXOSUIT_AGENT_STATE_HOME"] = str(base)
    environment["EXOSUIT_SUIT"] = "off"
    before = old_states(base)
    failures = 0
    for workspace in machine["workspaces"]:
        folders = [folder for folder in workspace["folders"] if Path(folder).is_dir()]
        scratch = workspace.get("scratch")
        if not folders and not (scratch and Path(scratch).is_dir()):
            print(f"skip   {workspace['name']}: no folder on disk")
            continue
        arguments = ["--manager", "--workspace", workspace["id"]]
        for folder in folders:
            arguments += ["--folder", folder]
        if not folders:
            arguments += ["--scratch", scratch]
        state = base / "workspaces" / workspace["id"]
        expected = [before[os.path.normcase(folder)][1] for folder in folders if os.path.normcase(folder) in before]
        try:
            endpoint = json.loads(run(environment, *arguments, "--detach", "--idle-seconds", "60").stdout)
            stop(state, endpoint)
            got = counts(state / "catalog.sqlite")
            # Merged: one more group per folder; otherwise the same counts.
            want = tuple(sum(values) for values in zip(*expected)) if expected else got
            if len(expected) > 1:
                want = (want[0] + len(expected),) + want[1:]
            assert got == want, f"catalog {got}, expected {want}"
            record = (state / "migration.json").read_text() if (state / "migration.json").exists() else ""
            endpoint = json.loads(run(environment, *arguments, "--detach", "--idle-seconds", "60").stdout)
            stop(state, endpoint)
            again = (state / "migration.json").read_text() if (state / "migration.json").exists() else ""
            assert again == record and counts(state / "catalog.sqlite") == got, "a second start changed the migration"
            if expected:
                restored = json.loads(run(environment, "--manager", "--workspace", workspace["id"], "--restore-migration").stdout)
                for folder in folders:
                    key = os.path.normcase(folder)
                    if key in before:
                        assert counts(before[key][0] / "catalog.sqlite") == before[key][1], f"{folder} restored differently"
                assert len(restored["restored"]) == len(expected)
            print(f"ok     {workspace['name']}: {len(expected)} folder state(s) migrated; groups, sessions, terminals, histories {got}")
        except Exception as error:  # noqa: BLE001 - report every workspace
            failures += 1
            print(f"FAIL   {workspace['name']}: {error}")
    if keep:
        print(f"copy kept at {copy}")
    else:
        shutil.rmtree(copy, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
