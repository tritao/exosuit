#!/usr/bin/env python3
"""Compatibility entry point for supervisors started by older Exosuit builds."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import sys


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    configured_launcher = os.environ.get("EXOSUIT_AGENT_LAUNCHER")
    launchers = [Path(configured_launcher)] if configured_launcher else []
    launchers.extend(
        [
            repository / "agent" / "build" / "host" / "main.hl",
            repository / "tools" / "exosuit-agent.hl",
        ]
    )
    launcher = next((path.resolve() for path in launchers if path.is_file()), None)
    if launcher is None:
        print("Haxe workspace manager bytecode is not installed", file=sys.stderr)
        return 127

    runtime_name = "hl.exe" if os.name == "nt" else "hl"
    runtime_candidates = []
    for variable in ("HAXEON_HL", "HL_BIN"):
        value = os.environ.get(variable)
        if value:
            runtime_candidates.append(Path(value))
    haxeon_root = os.environ.get("HAXEON_ROOT") or os.environ.get("HAXEON_HOME")
    if haxeon_root:
        runtime_candidates.append(Path(haxeon_root) / ".tools" / "hashlink" / runtime_name)
    located = shutil.which(runtime_name)
    if located:
        runtime_candidates.append(Path(located))
    runtime = next((path.resolve() for path in runtime_candidates if path.is_file()), None)
    if runtime is None:
        print("HashLink runtime is not installed", file=sys.stderr)
        return 127

    os.environ["EXOSUIT_AGENT_LAUNCHER"] = str(launcher)
    os.environ["EXOSUIT_HAXEON_CLI_PYTHON"] = sys.executable
    os.environ["EXOSUIT_PROJECT_ROOT"] = str(repository)
    os.execv(str(runtime), [str(runtime), str(launcher), "--manager", *sys.argv[1:]])
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
