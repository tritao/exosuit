"""Where a Haxeon checkout keeps its HashLink VM and the compiled CLI.

The VM is built in the CMake preset's tree, at the directory `<haxeon>/cmake/hashlink-output-paths.txt` names for the
preset (`windows-msvc` on Windows, `release` elsewhere); Haxeon resolves it the same way (build.HashLinkPath,
scripts/hashlink-path.sh). A checkout from before that table kept the VM in `.tools/hashlink` and the CLI in `out/`; the
GUI harness measures such a checkout as the baseline, so both layouts resolve here.

    python scripts/haxeon_paths.py [HAXEON_ROOT]   prints the VM directory (for PowerShell and shell scripts)
"""

from __future__ import annotations

import os
from pathlib import Path
import sys


def _table(haxeon_root: Path) -> Path:
    return haxeon_root / "cmake" / "hashlink-output-paths.txt"


def vm_dir(haxeon_root: Path) -> Path:
    """The directory of hl, hlprof-live, haxeon and haxeon-cli.hl."""
    table = _table(haxeon_root)
    if not table.is_file():
        return haxeon_root / ".tools" / "hashlink"
    preset = "windows-msvc" if os.name == "nt" else "release"
    for line in table.read_text(encoding="utf-8").splitlines():
        name, separator, path = line.partition("=")
        if separator and name == preset and path.strip():
            return haxeon_root / path.strip()
    raise RuntimeError(f"{table} names no HashLink output directory for {preset}")


def hl(haxeon_root: Path) -> Path:
    """The HashLink VM."""
    return vm_dir(haxeon_root) / ("hl.exe" if os.name == "nt" else "hl")


def cli(haxeon_root: Path) -> Path:
    """The CLI's bytecode, which `hl` runs with HAXEON_HOME of the caller's choosing."""
    if not _table(haxeon_root).is_file():
        return haxeon_root / "out" / "haxeon-cli.hl"
    return vm_dir(haxeon_root) / "haxeon-cli.hl"


if __name__ == "__main__":
    root = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("HAXEON_ROOT") or Path(__file__).resolve().parent.parent / "haxeon")
    print(vm_dir(root.expanduser().resolve()))
