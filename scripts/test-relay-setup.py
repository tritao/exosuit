#!/usr/bin/env python3
"""Verify relay settings survive a workspace manager restart."""
import json
from pathlib import Path
import tempfile

from agent_test_runtime import launcher_path
from test_driver import ROOT, WINDOWS, assert_private, build_test, endpoint_for, isolated_environment, run_tree, stop_manager, stop_managers

RUNNER = build_test("workspace-attachment")
ORIGIN = "https://127.0.0.1:1"


def run_client(mode: str, *arguments: str, environment: dict[str, str]) -> None:
    run_tree([*RUNNER, mode, *arguments], environment, timeout=120)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="exa-relay-", ignore_cleanup_errors=True) as temporary:
        base = Path(temporary)
        root, state = base / "project", base / "state"
        root.mkdir()
        launcher = launcher_path(ROOT)
        environment = isolated_environment(state, launcher, "workspace-attachment")
        try:
            run_client("remote-setup", str(root), str(launcher), ORIGIN, environment=environment)
            endpoint = endpoint_for(state, root)
            settings = endpoint.parent / "relay-settings.json"
            value = json.loads(settings.read_text())
            assert value == {"version": 1, "origin": ORIGIN}
            assert_private(settings)

            assert stop_manager(endpoint), "Workspace manager did not stop on request"
            assert not endpoint.exists(), "Workspace manager did not stop"

            run_client("relay-persist-inspect", str(root), str(launcher), ORIGIN, environment=environment)
            print("PASS: relay configuration survives manager restart", flush=True)
        finally:
            stop_managers(state)
            for identity in state.glob("exosuit/workspaces/*/relay-machine.json"):
                machine_id = json.loads(identity.read_text())["machineId"]
                run_client("cleanup-relay", machine_id, ORIGIN, environment=environment)


if __name__ == "__main__":
    main()
