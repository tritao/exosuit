#!/usr/bin/env python3
"""Build the agent, exohost and the graphical app with the Haxeon CLI."""

from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

from haxeon_cli import cli_command, run_cli
from prepare_agent_naming import prepare


def main() -> int:
    root_dir = Path(__file__).resolve().parent.parent
    self_hosted = os.environ.get("HAXEON_SELF_HOSTED", "0") == "1"
    # exohost is the per-user tray daemon that tracks the processes editors and workspaces start. The projects build at
    # the same time (`--serial` for one after another). They share the CMake trees of the native packages they have in
    # common (haxeon/out/native-cache), which a lock lets only one build use at a time; a build that needs one waits.
    projects = ["agent", "exohost", "graphical"]
    # `--only agent,exohost` (or `--only=agent,exohost`) builds just those, for a quick loop on one part.
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

    serial = "--serial" in passed
    passed = [argument for argument in passed if argument != "--serial"]
    try:
        # The Claude naming adapter belongs to the agent.
        if "agent" in projects:
            prepare(root_dir)
        # The terminal host is built on its own beside the agent: a small program starts much faster (TerminalHosts).
        builds = [part for project in projects for part in ([project, "agent/terminal-host"] if project == "agent" else [project])]

        def arguments_for(project: str) -> list[str]:
            arguments = ["build", "--project", str(root_dir / project / "haxeon.json")]
            if self_hosted:
                arguments.append("--self-hosted")
            return arguments + passed

        if serial or len(builds) == 1:
            for project in builds:
                started = time.monotonic()
                status = run_cli(root_dir, arguments_for(project))
                if status != 0:
                    return status
                print(f"== {project} built in {time.monotonic() - started:.0f} s", flush=True)
            return 0
        return build_in_parallel(root_dir, builds, arguments_for)
    except (OSError, RuntimeError) as error:
        print(f"Unable to prepare the Haxeon CLI: {error}", file=sys.stderr)
        return 127


def build_in_parallel(root_dir: Path, builds: list[str], arguments_for) -> int:
    """Runs the project builds at once, each line of output prefixed with its project. The Haxe compile of each project
    is single-threaded, so the builds overlap well; native packages they share wait on the native-cache lock, as before.
    graphical, the longest, starts first. `--serial` builds one after another instead."""
    # Every CLI start checks that the CLI itself is up to date (scripts/haxeon runs cmake for it). Do that once, alone,
    # so the parallel starts never race to rebuild it in the same CMake tree.
    status = run_cli(root_dir, ["--version"], None) if os.name != "nt" else 0
    if status != 0:
        return status
    order = sorted(builds, key=lambda project: project != "graphical")
    width = max(len(project) for project in order)
    lock = threading.Lock()
    results: dict[str, tuple[int, float]] = {}

    def run(project: str) -> None:
        started = time.monotonic()
        command, environment = cli_command(root_dir, arguments_for(project))
        process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, errors="replace", bufsize=1)
        assert process.stdout is not None
        for line in process.stdout:
            with lock:
                sys.stdout.write(f"[{project:<{width}}] {line}")
                sys.stdout.flush()
        status = process.wait()
        results[project] = (status, time.monotonic() - started)
        with lock:
            outcome = f"built in {results[project][1]:.0f} s" if status == 0 else f"FAILED (exit {status})"
            print(f"== {project} {outcome}", flush=True)

    started = time.monotonic()
    threads = [threading.Thread(target=run, args=(project,)) for project in order]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    failed = [project for project in builds if results.get(project, (1, 0))[0] != 0]
    print(f"== {len(builds)} builds in parallel: {time.monotonic() - started:.0f} s" + (f", failed: {', '.join(failed)}" if failed else ""),
          flush=True)
    return next((results[project][0] for project in builds if results.get(project, (1, 0))[0] != 0), 0)


if __name__ == "__main__":
    sys.exit(main())
