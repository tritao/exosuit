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


def library_path(bytecode: Path, runtime: Path, haxeon: Path, inherited: str = "") -> str:
    """The library path suit runs with.

    The same rule as SuitClient.nativePath in src/suit/SuitClient.hx, which starts suit from an editor or a
    bundle; keep the two in the same order: the directories under <bytecode dir>/native, lib beside the
    bytecode directory (a bundle keeps tools/ and lib/ side by side),
    the HashLink runtime's directory, Haxeon's out and .tools/hashlink, then the inherited value.
    """
    native = bytecode.parent / "native"
    directories = sorted(path for path in native.iterdir() if path.is_dir()) if native.is_dir() else []
    directories += [bytecode.parent.parent / "lib", runtime.parent, haxeon / "out", haxeon / ".tools" / "hashlink"]
    unique = list(dict.fromkeys(str(path) for path in directories if path.is_dir()))
    return os.pathsep.join(unique + ([inherited] if inherited else []))


def library_variable() -> str:
    return "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"


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
    environment = dict(os.environ)
    variable = library_variable()
    environment[variable] = library_path(bytecode, runtime, haxeon, environment.get(variable, ""))
    environment.setdefault("EXOSUIT_SUIT_LAUNCHER", str(bytecode))
    return subprocess.run([str(runtime), str(bytecode), *sys.argv[1:]], env=environment).returncode


if __name__ == "__main__":
    sys.exit(main())
