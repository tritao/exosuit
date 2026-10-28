#!/usr/bin/env python3
"""Run suit, the per-user daemon behind the Exosuit tray icon, from a source tree.

    python scripts/suit.py list            every exosuit process, grouped by editor
    python scripts/suit.py kill --orphans  stop processes whose editor is gone
    python scripts/suit.py build           build suit/haxeon.json

Everything after the script name goes to suit; `python scripts/suit.py help` lists its commands.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    if sys.argv[1:2] == ["build"]:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from haxeon_cli import run_cli
        return run_cli(ROOT, ["build", "--project", str(ROOT / "suit" / "haxeon.json"), *sys.argv[2:]])
    haxeon = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
    runtime = haxeon / ".tools" / "hashlink" / ("hl.exe" if os.name == "nt" else "hl")
    bytecode = ROOT / "suit" / "build" / "host" / "main.hl"
    if not bytecode.is_file():
        print(f"suit is not built; run: python {Path(__file__).name} build", file=sys.stderr)
        return 127
    if not runtime.is_file():
        print(f"HashLink runtime not found: {runtime}", file=sys.stderr)
        return 127
    native = bytecode.parent / "native"
    directories = [path for path in sorted(native.iterdir()) if path.is_dir()] if native.is_dir() else []
    directories += [haxeon / "out", runtime.parent]
    variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    environment = dict(os.environ)
    environment[variable] = os.pathsep.join([str(path) for path in directories if path.is_dir()] + [environment.get(variable, "")])
    environment.setdefault("EXOSUIT_SUIT_LAUNCHER", str(bytecode))
    return subprocess.run([str(runtime), str(bytecode), *sys.argv[1:]], env=environment).returncode


if __name__ == "__main__":
    sys.exit(main())
