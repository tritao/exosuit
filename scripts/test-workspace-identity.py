#!/usr/bin/env python3
"""A workspace's service keyed by its id (M19 Phase 4): its state, discovery, folders changing between starts,
`--from-state`, a folderless workspace's scratch folder, and the --machine listing."""
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

AGENT = manager_command(ROOT)[:-1]
WORKSPACE = "workspace-0123456789abcdef0123456789abcdef"


def run(environment, cwd, *arguments, check=True):
    result = subprocess.run([*AGENT, *arguments], env=environment, cwd=str(cwd), capture_output=True, text=True, timeout=120)
    if check and result.returncode != 0:
        raise RuntimeError(f"{arguments} exited {result.returncode}: {result.stderr}")
    return result


def start(environment, cwd, *arguments):
    return json.loads(run(environment, cwd, "--manager", *arguments, "--detach", "--idle-seconds", "60").stdout)


def stop(state, endpoint):
    """Asks the manager to stop, as suit does, and waits until it has."""
    (Path(state) / "stop-request.json").write_text(json.dumps({"version": 1, "generation": endpoint["generation"]}) + "\n")
    deadline = time.monotonic() + 30
    while (Path(state) / "endpoint.json").exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert not (Path(state) / "endpoint.json").exists(), "the manager stopped"


def identity(state):
    return json.loads((Path(state) / "workspace.json").read_text())


def owner(state):
    database = sqlite3.connect(f"file:{Path(state) / 'catalog.sqlite'}?mode=ro", uri=True)
    try:
        return database.execute("SELECT root FROM workspace_meta").fetchone()[0]
    finally:
        database.close()


def same(left, right):
    return os.path.normcase(os.path.realpath(left)) == os.path.normcase(os.path.realpath(right))


with tempfile.TemporaryDirectory(prefix="exosuit-identity-") as temporary:
    home = Path(temporary) / "state"
    first, second, scratch = (Path(temporary) / name for name in ("first", "second", "scratch"))
    home.mkdir(mode=0o700)
    for folder in (first, second, scratch):
        folder.mkdir()
    environment = manager_environment(ROOT)
    environment["EXOSUIT_AGENT_STATE_HOME"] = str(home)
    state = home / "workspaces" / WORKSPACE

    started = start(environment, first, "--workspace", WORKSPACE, "--folder", str(first), "--folder", str(second))
    assert started["workspaceId"] == WORKSPACE and same(started["root"], first), started
    recorded = identity(state)
    assert (recorded["version"], recorded["workspace"], recorded["scratch"]) == (2, WORKSPACE, None), recorded
    assert [same(f, expected) for f, expected in zip(recorded["folders"], (first, second))] == [True, True], recorded
    assert owner(state) == "workspace:" + WORKSPACE, "the catalog belongs to the workspace, not its first folder"

    # Discovery and the listing find it by id alone; its folders are not part of its name.
    found = json.loads(run(environment, first, "--manager", "--workspace", WORKSPACE, "--discover").stdout)
    assert found["generation"] == started["generation"], found
    listing = json.loads(run(environment, first, "--machine").stdout)
    assert [(m["workspace"], m["defaultState"]) for m in listing["managers"]] == [(WORKSPACE, True)], listing
    # The folder's own service is another service, with its own state.
    folder = start(environment, first, str(first))
    assert "workspaceId" not in folder and folder["socket"] != started["socket"], folder
    managers = json.loads(run(environment, first, "--machine").stdout)["managers"]
    assert sorted(m["workspace"] for m in managers) == ["", WORKSPACE], managers
    stop(next(m["stateDir"] for m in managers if m["workspace"] == ""), folder)
    stop(state, started)

    # Its folders change between starts: reordered, one detached. The same state and catalog serve it.
    again = start(environment, second, "--workspace", WORKSPACE, "--folder", str(second))
    assert again["workspaceId"] == WORKSPACE and same(again["root"], second), again
    assert [same(f, second) for f in identity(state)["folders"]] == [True], identity(state)
    stop(state, again)

    # suit starts a hosted workspace from its state folder alone.
    hosted = start(environment, second, "--from-state", str(state))
    assert hosted["workspaceId"] == WORKSPACE and same(hosted["root"], second), hosted
    stop(state, hosted)

    # A workspace with no folders starts in its scratch folder.
    empty = start(environment, scratch, "--workspace", WORKSPACE, "--scratch", str(scratch))
    assert same(empty["root"], scratch) and identity(state)["folders"] == [], identity(state)
    stop(state, empty)

    refused = run(environment, first, "--manager", "--workspace", WORKSPACE, "--discover", "--folder", str(first), "--from-state", str(state),
                  check=False)
    assert refused.returncode != 0
    refused = run(environment, first, "--manager", "--workspace", "../escape", "--discover", check=False)
    assert refused.returncode != 0 and "workspace id" in refused.stderr, refused.stderr
    # Named by its id alone, it starts with the folders it last had; a workspace never started has none.
    recalled = start(environment, scratch, "--workspace", WORKSPACE)
    assert same(recalled["root"], scratch), recalled
    stop(state, recalled)
    refused = run(environment, first, "--manager", "--workspace", "workspace-new", "--detach", check=False)
    assert refused.returncode != 0 and "scratch folder" in refused.stderr, refused.stderr
    missing = run(environment, first, "--manager", "--workspace", "workspace-new", "--discover", check=False)
    assert missing.returncode == 4, missing
print("workspace identity: ok")
