"""Resolve the built Haxe workspace agent for integration-test processes."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import sys


def runtime_paths(root: Path) -> tuple[Path, Path]:
    haxeon = Path(os.environ.get("HAXEON_ROOT", root / "haxeon")).expanduser()
    bytecode = root / "agent" / "build" / "host" / "main.hl"
    configured = os.environ.get("HAXEON_HL") or os.environ.get("HL_BIN")
    if configured:
        runtime = Path(configured).expanduser()
    else:
        executable = "hl.exe" if os.name == "nt" else "hl"
        candidates = [haxeon / ".tools" / "hashlink" / executable]
        found = shutil.which(executable)
        if found:
            candidates.append(Path(found))
        runtime = next((candidate for candidate in candidates if candidate.is_file()), candidates[0])
    if not runtime.is_file():
        raise FileNotFoundError(f"HashLink runtime not found: {runtime}")
    if not bytecode.is_file():
        raise FileNotFoundError(f"Workspace agent bytecode not found: {bytecode}; build agent/haxeon.json")
    return runtime.resolve(), bytecode.resolve()


def manager_command(root: Path) -> list[str]:
    runtime, bytecode = runtime_paths(root)
    return [str(runtime), str(bytecode), "--manager"]


def launcher_path(root: Path, install: Path | None = None) -> Path:
    if install is not None:
        return install / "tools" / "exosuit-agent.hl"
    _, bytecode = runtime_paths(root)
    return bytecode


def manager_environment(root: Path, launcher: Path | None = None) -> dict[str, str]:
    runtime, bytecode = runtime_paths(root)
    environment = os.environ.copy()
    agent_root = root / "agent" / "build" / "host"
    haxeon = Path(os.environ.get("HAXEON_ROOT", root / "haxeon")).expanduser()
    libraries = [haxeon / "out", haxeon / ".tools" / "hashlink", agent_root / "native"]
    if (agent_root / "native").is_dir():
        libraries.extend(sorted(path for path in (agent_root / "native").iterdir() if path.is_dir()))
    libraries.append(runtime.parent)
    libraries = [str(path.resolve()) for path in libraries if path.is_dir()]
    variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    inherited = environment.get(variable, "")
    environment[variable] = os.pathsep.join(libraries + ([inherited] if inherited else []))
    environment["EXOSUIT_AGENT_LAUNCHER"] = str(launcher or bytecode)
    return environment
