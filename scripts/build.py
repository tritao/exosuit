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
    # after another: they share the CMake trees of the native packages they have in common (haxeon/out/native-cache),
    # which a lock lets only one build use at a time, so the later projects find those packages built.
    projects = ["agent", "suit", "graphical"]
    # `--only agent,suit` (or `--only=agent,suit`) builds just those, for a quick loop on one part.
    passed = sys.argv[1:]
    for index, argument in enumerate(passed):
        if argument == "--only" or argument.startswith("--only="):
            if argument == "--only":
                value = passed[index + 1] if index + 1 < len(passed) else ""
                end = index + 2
            else:
                value = argument[len("--only="):]
                end = index + 1
            chosen = value.split(",")
            if not value or not set(chosen) <= set(projects):
                print(f"--only takes a comma-separated list of {', '.join(projects)}", file=sys.stderr)
                return 2
            projects = [project for project in projects if project in chosen]
            passed = passed[:index] + passed[end:]
            break

    try:
        # The Claude naming adapter belongs to the agent, and the language server to the editor (graphical).
        if "agent" in projects:
            prepare(root_dir)
        if "graphical" in projects:
            status = ensure_language_server(root_dir)
            if status != 0:
                return status
        for project in projects:
            arguments = ["build", "--project", str(root_dir / project / "haxeon.json")]
            if self_hosted:
                arguments.append("--self-hosted")
            arguments.extend(passed)
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
