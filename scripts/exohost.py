#!/usr/bin/env python3
"""Run exohost, the per-user daemon behind the Exosuit tray icon, from a source tree.

    python scripts/exohost.py list            every exosuit process, grouped by editor
    python scripts/exohost.py kill --orphans  stop processes whose editor is gone
    python scripts/exohost.py build           build exohost/haxeon.json

    python scripts/exohost.py --ctl list      exohostctl: the open windows (scripts/exohostctl.cmd runs this)
    python scripts/exohost.py --ctl open F    open a folder or file in the running editor

Everything after the script name goes to exohost; `python scripts/exohost.py help` lists its commands and
`python scripts/exohost.py --ctl --help` exohostctl's (exohost/README.md, "Control plane").
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

import haxeon_paths

ROOT = Path(__file__).resolve().parent.parent


def library_path(bytecode: Path, runtime: Path, haxeon: Path, inherited: str = "") -> str:
    """The library path exohost runs with.

    The same rule as ExohostClient.nativePath in src/exohost/ExohostClient.hx, which starts exohost from an editor or a
    bundle; keep the two in the same order: the directories under <bytecode dir>/native, lib beside the
    bytecode directory (a bundle keeps tools/ and lib/ side by side),
    the HashLink runtime's directory, Haxeon's out and its VM directory (scripts/haxeon_paths.py), then the inherited
    value.
    """
    native = bytecode.parent / "native"
    directories = sorted(path for path in native.iterdir() if path.is_dir()) if native.is_dir() else []
    directories += [bytecode.parent.parent / "lib", runtime.parent, haxeon / "out", haxeon_paths.vm_dir(haxeon)]
    unique = list(dict.fromkeys(str(path) for path in directories if path.is_dir()))
    return os.pathsep.join(unique + ([inherited] if inherited else []))


def library_variable() -> str:
    return "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"


def main() -> int:
    if sys.argv[1:2] == ["build"]:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from haxeon_cli import run_cli
        return run_cli(ROOT, ["build", "--project", str(ROOT / "exohost" / "haxeon.json"), *sys.argv[2:]])
    haxeon = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
    runtime = haxeon_paths.hl(haxeon)
    bytecode = ROOT / "exohost" / "build" / "host" / "main.hl"
    if not bytecode.is_file():
        print(f"exohost is not built; run: python {Path(__file__).name} build", file=sys.stderr)
        return 127
    if not runtime.is_file():
        print(f"HashLink runtime not found: {runtime}", file=sys.stderr)
        return 127
    environment = dict(os.environ)
    variable = library_variable()
    environment[variable] = library_path(bytecode, runtime, haxeon, environment.get(variable, ""))
    environment.setdefault("EXOSUIT_EXOHOST_LAUNCHER", str(bytecode))
    return subprocess.run([str(runtime), str(bytecode), *sys.argv[1:]], env=environment).returncode


if __name__ == "__main__":
    sys.exit(main())
