#!/usr/bin/env python3
"""Run the graphical app with the Haxeon CLI."""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

from haxeon_cli import run_cli


def _windows_npm_codex_environment() -> dict[str, str]:
    """Use the npm Codex CLI directly instead of another codex.exe earlier on PATH."""
    if os.name != "nt" or os.environ.get("EXOSUIT_CODEX_BIN"):
        return {}
    shim = shutil.which("codex.cmd")
    if shim is None:
        return {}
    directory = Path(shim).resolve().parent
    node = directory / "node.exe"
    cli = directory / "node_modules" / "@openai" / "codex" / "bin" / "codex.js"
    if not node.is_file() or not cli.is_file():
        return {}
    return {
        "EXOSUIT_CODEX_BIN": str(node),
        "EXOSUIT_CODEX_SCRIPT": str(cli),
    }


def _enable_core_dumps() -> None:
    if os.name == "nt":
        return

    try:
        import resource
    except ImportError:
        return

    if os.environ.get("EXOSUIT_DEV_CORE_DUMPS", "1") == "0":
        return
    _, hard_limit = resource.getrlimit(resource.RLIMIT_CORE)
    resource.setrlimit(resource.RLIMIT_CORE, (hard_limit, hard_limit))
    if hard_limit == 0:
        print("Core dumps are disabled by the shell hard limit; start from a shell with a nonzero core limit.", file=sys.stderr)


def main() -> int:
    root_dir = Path(__file__).resolve().parent.parent
    self_hosted = os.environ.get("HAXEON_SELF_HOSTED", "0") == "1"
    agent_arguments = ["build", "--project", str(root_dir / "agent" / "haxeon.json")]
    if self_hosted:
        agent_arguments.append("--self-hosted")
    try:
        status = run_cli(root_dir, agent_arguments)
        if status != 0:
            return status
    except OSError as error:
        print(f"Unable to build the workspace agent: {error}", file=sys.stderr)
        return 127
    except RuntimeError as error:
        print(f"Unable to build the workspace agent: {error}", file=sys.stderr)
        return 127

    arguments = [
        "run",
        "--project",
        str(root_dir / "graphical" / "haxeon.json"),
    ]
    if self_hosted:
        arguments.append("--self-hosted")
    arguments.extend(["--", *sys.argv[1:]])

    try:
        environment = {
            "EXOSUIT_AGENT_LAUNCHER": str(root_dir / "agent" / "build" / "host" / "main.hl"),
            "EXOSUIT_HAXEON_CLI_PYTHON": sys.executable,
            "EXOSUIT_PROJECT_ROOT": str(root_dir),
            # The source-tree launcher is a development entry point. Abort at
            # native text-layout failures before caught exceptions dispose state.
            "NKUI_DUMP_ON_TEXT_LAYOUT_FAILURE": os.environ.get("EXOSUIT_DEV_CORE_DUMPS", "1"),
        }
        environment.update(_windows_npm_codex_environment())
        _enable_core_dumps()
        return run_cli(root_dir, arguments, environment)
    except OSError as error:
        print(f"Unable to run the Haxeon CLI: {error}", file=sys.stderr)
        return 127
    except RuntimeError as error:
        print(f"Unable to prepare the Haxeon CLI: {error}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main())
