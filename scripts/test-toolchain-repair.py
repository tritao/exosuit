#!/usr/bin/env python3
"""scripts/run.py repairs a Haxeon toolchain with a tool missing: it runs the bootstrap build-windows.ps1 runs.

Moves haxe and ccache aside in THIS checkout's haxeon/.tools (never another checkout's), checks that they are noticed
(ccache only because a native CMake cache launches through it), repairs, and checks that both are back.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolchain_repair  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
HAXEON = ROOT / "haxeon"


def main() -> int:
    tools = HAXEON / ".tools"
    if not toolchain_repair.haxe_executable(HAXEON).is_file():
        print("SKIP: the toolchain is not bootstrapped here; run scripts/build-windows.ps1 first")
        return 0
    assert toolchain_repair.missing_tools(HAXEON) == [], f"a complete toolchain reports missing tools: {toolchain_repair.missing_tools(HAXEON)}"
    launchers = toolchain_repair.cached_launchers(HAXEON)
    aside: list[tuple[Path, Path]] = []
    try:
        for name in ("haxe", "ccache"):
            folder = tools / name
            if folder.is_dir():
                moved = tools / (name + ".aside")
                shutil.rmtree(moved, ignore_errors=True)
                folder.rename(moved)
                aside.append((moved, folder))
        missing = toolchain_repair.missing_tools(HAXEON)
        assert any(path.endswith("haxe.exe") or path.endswith("haxe") for path in missing), f"a missing haxe was not noticed: {missing}"
        if launchers:
            assert any("ccache" in path for path in missing), f"a missing ccache that the native caches use was not noticed: {missing}"
        repaired = toolchain_repair.ensure(HAXEON)
        assert repaired == missing, f"ensure reported {repaired}, expected {missing}"
        assert toolchain_repair.missing_tools(HAXEON) == [], f"still missing after the repair: {toolchain_repair.missing_tools(HAXEON)}"
        assert toolchain_repair.ensure(HAXEON) == [], "a complete toolchain was bootstrapped again"
    finally:
        for moved, folder in aside:
            if folder.is_dir():
                shutil.rmtree(moved, ignore_errors=True)  # the bootstrap made a new one
            elif moved.is_dir():
                moved.rename(folder)
    print("PASS: run.py's toolchain repair notices a missing haxe or ccache and restores both with the bootstrap")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
