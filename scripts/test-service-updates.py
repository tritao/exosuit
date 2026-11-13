#!/usr/bin/env python3
"""Exercise Haxe-managed workspace updates with two attached clients."""
from pathlib import Path
import sys
import tempfile

from agent_test_runtime import launcher_path
from test_driver import ROOT, build_test, isolated_environment, run_tree, stop_managers

RUNNER = build_test("workspace-attachment")


def run_update(mode: str, base: Path) -> None:
    project = base / "project"
    state = base / "state"
    project.mkdir()
    revision = base / "revision"
    revision.write_text("a" * 64)
    launcher = launcher_path(ROOT)
    environment = dict(
        isolated_environment(state, launcher, "workspace-attachment"),
        EXOSUIT_AGENT_BUILD_ID_FILE=str(revision),
        EXOSUIT_HAXEON_CLI_PYTHON=sys.executable,
        EXOSUIT_PROJECT_ROOT=str(ROOT),
    )
    if mode == "update-legacy":
        environment["EXOSUIT_AGENT_MANAGED_UPDATES"] = "0"
    try:
        run_tree([*RUNNER, mode, str(project), str(launcher), str(revision)], environment, timeout=180)
    except Exception:
        # The failure names these logs, which go with the fixture.
        for log in [*state.glob("exosuit/workspaces/*/update-build.log"), *state.glob("exosuit/workspaces/*/manager.log")]:
            # Without the compiler's statistics lines, which are thousands of characters each.
            lines = [line for line in log.read_text(errors="replace").splitlines() if line.strip() and len(line) < 400]
            print(f"== {mode}: {log.name}", *lines[-40:], sep="\n", file=sys.stderr)
        raise
    finally:
        stop_managers(state)


def main() -> None:
    for mode in ["update-idle", "update-busy", "update-now", "update-legacy"]:
        with tempfile.TemporaryDirectory(prefix="exa-update-", ignore_cleanup_errors=True) as temporary:
            run_update(mode, Path(temporary))


if __name__ == "__main__":
    main()
