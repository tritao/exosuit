"""Repairs a Haxeon toolchain that is missing or partly deleted, with the bootstrap scripts/build-windows.ps1 runs.

`haxeon/.tools` holds the pinned Haxe compiler and ccache. With either gone (or the whole folder), the Haxeon CLI fails
with "Pinned Haxe compiler is not bootstrapped" or, when the native CMake caches still launch the compiler through the
missing ccache.exe, "CreateProcess failed". scripts/run.py calls `ensure` first, so one command repairs it.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

_LAUNCHER = re.compile(r"^CMAKE_[A-Z]+_COMPILER_LAUNCHER:[A-Z]+=(.+ccache(?:\.exe)?)\s*$", re.MULTILINE | re.IGNORECASE)


def haxe_executable(haxeon_root: Path) -> Path:
    return haxeon_root / ".tools" / "haxe" / ("haxe.exe" if os.name == "nt" else "haxe")


def cached_launchers(haxeon_root: Path) -> set[Path]:
    """The ccache programs the native CMake caches under `out/native-cache` launch the compiler through."""
    found: set[Path] = set()
    cache = haxeon_root / "out" / "native-cache"
    if not cache.is_dir():
        return found
    for path in cache.glob("*/*/cmake-ninja/CMakeCache.txt"):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        found.update(Path(match) for match in _LAUNCHER.findall(text))
    return found


def missing_tools(haxeon_root: Path) -> list[str]:
    """What the bootstrap would put back: the Haxe compiler, and any ccache a native CMake cache points at that is gone."""
    missing: list[str] = []
    if not haxe_executable(haxeon_root).is_file():
        missing.append(str(haxe_executable(haxeon_root)))
    missing.extend(sorted(str(launcher) for launcher in cached_launchers(haxeon_root) if not launcher.is_file()))
    return missing


def visual_studio_environment() -> dict[str, str]:
    """The environment Enter-VisualStudio2026 in scripts/build-windows.ps1 makes: the newest Visual Studio 2026 (18.x) x64
    tools, with its bundled CMake first on PATH. The bootstrap builds libffi, which needs them. Empty off Windows."""
    environment = os.environ.copy()
    if os.name != "nt":
        return environment
    vswhere = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    if not vswhere.is_file():
        raise RuntimeError("vswhere.exe not found; install Visual Studio 2026 with the C++ desktop workload")
    found = subprocess.run(
        [str(vswhere), "-latest", "-version", "[18.0,19.0)", "-products", "*", "-requires",
         "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
        stdout=subprocess.PIPE, text=True, check=False).stdout.strip()
    if not found:
        raise RuntimeError("Visual Studio 2026 with the MSVC x64 tools is not installed")
    vcvars = Path(found) / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    dumped = subprocess.run(f'cmd /c ""{vcvars}" >nul 2>&1 && set"', stdout=subprocess.PIPE, text=True, check=False, shell=True)
    if dumped.returncode != 0:
        raise RuntimeError(f"{vcvars} failed")
    for line in dumped.stdout.splitlines():
        name, separator, value = line.partition("=")
        if separator and name:
            environment[name] = value
    cmake_directory = Path(found) / "Common7" / "IDE" / "CommonExtensions" / "Microsoft" / "CMake" / "CMake" / "bin"
    environment["PATH"] = f"{cmake_directory};{environment.get('PATH', '')}"
    environment["CMAKE_GENERATOR"] = "Visual Studio 18 2026"
    return environment


def bootstrap(haxeon_root: Path) -> None:
    """The step scripts/build-windows.ps1 calls "Haxeon toolchain bootstrap" (it keeps archives it already downloaded)."""
    environment = visual_studio_environment()
    cmake = shutil.which("cmake", path=environment.get("PATH"))
    if cmake is None:
        raise RuntimeError("cmake is not on PATH, so the Haxeon toolchain cannot be repaired; run scripts/build-windows.ps1")
    result = subprocess.run(
        [cmake, "-P", str(haxeon_root / "cmake" / "Bootstrap.cmake")],
        cwd=haxeon_root,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{result.stdout}Haxeon toolchain bootstrap failed; run scripts/build-windows.ps1")


def ensure(haxeon_root: Path) -> list[str]:
    """Runs the bootstrap when a tool is missing; returns what was missing. Raises RuntimeError when it did not help."""
    missing = missing_tools(haxeon_root)
    if not missing:
        return []
    print("Repairing the Haxeon toolchain (missing: " + ", ".join(missing) + ")", file=sys.stderr)
    bootstrap(haxeon_root)
    still = missing_tools(haxeon_root)
    if still:
        raise RuntimeError("The Haxeon toolchain is still missing " + ", ".join(still) + " after the bootstrap; run scripts/build-windows.ps1")
    return missing
