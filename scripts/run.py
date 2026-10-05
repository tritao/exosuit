#!/usr/bin/env python3
"""Run the graphical app with the Haxeon CLI."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from haxeon_cli import run_cli


def _enable_core_dumps() -> None:
    if os.name == "nt":
        return

    try:
        import resource
    except ImportError:
        return

    _, hard_limit = resource.getrlimit(resource.RLIMIT_CORE)
    resource.setrlimit(resource.RLIMIT_CORE, (hard_limit, hard_limit))


def main() -> int:
    root_dir = Path(__file__).resolve().parent.parent
    arguments = [
        "run",
        "--project",
        str(root_dir / "graphical" / "haxeon.json"),
    ]
    if os.environ.get("HAXEON_SELF_HOSTED", "0") == "1":
        arguments.append("--self-hosted")
    arguments.extend(["--", *sys.argv[1:]])

    try:
        environment = {
            "EXOSUIT_AGENT_LAUNCHER": str(root_dir / "scripts" / "run-agent.py")
        }
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
