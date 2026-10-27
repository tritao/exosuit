#!/usr/bin/env python3
"""Run the graphical app with the Haxeon CLI."""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

from haxeon_cli import ensure_language_server, run_cli
from prepare_agent_naming import prepare


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
        prepare(root_dir)
        status = ensure_language_server(root_dir)
        if status != 0:
            return status
        status = run_cli(root_dir, agent_arguments)
        if status != 0:
            return status
    except OSError as error:
        print(f"Unable to build the workspace agent: {error}", file=sys.stderr)
        return 127
    except RuntimeError as error:
        print(f"Unable to build the workspace agent: {error}", file=sys.stderr)
        return 127

    # --watch rebuilds and relaunches the app after source edits. --live also watches, but patches Haxe
    # edits into the running app instead of relaunching it. --profile records each launch with the
    # profiler and writes a Perfetto trace when it ends; the other --profile-* options (start, duration,
    # max size, window) go to haxeon with it. The rest is forwarded to the app.
    watch = "--watch" in sys.argv[1:]
    live = "--live" in sys.argv[1:]
    profile_arguments = [argument for argument in sys.argv[1:] if argument == "--profile" or argument.startswith("--profile=") or argument.startswith("--profile-")]
    app_arguments = [
        argument
        for argument in sys.argv[1:]
        if argument not in ("--watch", "--live") and argument not in profile_arguments
    ]
    arguments = [
        "run",
        "--project",
        str(root_dir / "graphical" / "haxeon.json"),
    ]
    if self_hosted:
        arguments.append("--self-hosted")
    if watch or live:
        arguments.append("--watch")
    if live:
        # Live builds carry patch history and must not overwrite the ordinary app build.
        arguments.extend(["--live", "--output", str(root_dir / "graphical" / "build" / "host" / "live.hl")])
    arguments.extend(profile_arguments)
    arguments.extend(["--", *app_arguments])

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
