#!/usr/bin/env python3
"""Build the agent, suit and the graphical app with the Haxeon CLI."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

from haxeon_cli import ensure_language_server, run_cli
from prepare_agent_naming import prepare


def main() -> int:
    root_dir = Path(__file__).resolve().parent.parent
    self_hosted = os.environ.get("HAXEON_SELF_HOSTED", "0") == "1"
    # suit is the per-user tray daemon that tracks the processes editors and workspaces start. The projects build one
    # after another: built side by side, their CMake configures contended and the whole build took longer.
    projects = ["agent", "suit", "graphical"]

    try:
        prepare(root_dir)
        status = ensure_language_server(root_dir)
        if status != 0:
            return status
        for project in projects:
            arguments = ["build", "--project", str(root_dir / project / "haxeon.json")]
            if self_hosted:
                arguments.append("--self-hosted")
            arguments.extend(sys.argv[1:])
            started = time.monotonic()
            status = run_cli(root_dir, arguments)
            if status != 0:
                return status
            print(f"== {project} built in {time.monotonic() - started:.0f} s", flush=True)
        return 0
    except (OSError, RuntimeError) as error:
        print(f"Unable to prepare the Haxeon CLI: {error}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main())
