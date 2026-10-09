#!/usr/bin/env python3
"""Save, launch, and roll back a local Exosuit build without using build outputs at runtime."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
# The promoted launcher lives in .local/stable/<platform>, alongside the pointers.
ROOT = SCRIPT_DIRECTORY.parents[2] if (SCRIPT_DIRECTORY.parent.name == "stable"
    and SCRIPT_DIRECTORY.parent.parent.name == ".local") else SCRIPT_DIRECTORY.parent
STABLE_ROOT = ROOT / ".local" / "stable" / f"{platform.system().lower()}-{platform.machine().lower()}"
VERSIONS = STABLE_ROOT / "versions"
CURRENT = STABLE_ROOT / "current.txt"
PREVIOUS = STABLE_ROOT / "previous.txt"
DATA = STABLE_ROOT / "data"


@contextmanager
def stable_lock():
    """Serialize pointer changes, launch pinning, and snapshot cleanup."""
    STABLE_ROOT.mkdir(parents=True, exist_ok=True)
    handle = (STABLE_ROOT / ".lock").open("a+b")
    try:
        if os.name == "nt":
            import msvcrt

            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                handle.write(b"\0")
                handle.flush()
            while True:
                try:
                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    time.sleep(0.05)
            try:
                yield
            finally:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def hashlink_name() -> str:
    return "hl.exe" if os.name == "nt" else "hl"


def is_dynamic_library(path: Path) -> bool:
    name = path.name.lower()
    return name.endswith((".dll", ".hdll", ".dylib")) or re.search(r"\.so(?:\.\d+)*$", name) is not None


def copy_libraries(source: Path, destination: Path, immediate_subdirs: bool = False) -> int:
    """Copy runtime libraries while leaving compiler and CMake intermediates behind."""
    if not source.is_dir():
        raise RuntimeError(f"Missing native build output: {source}")
    count = 0
    packages = [item for item in source.iterdir() if item.is_dir()] if immediate_subdirs else [source]
    for package in sorted(packages):
        for item in sorted(package.iterdir()):
            if not item.is_file() or not is_dynamic_library(item):
                continue
            target_dir = destination / package.name if immediate_subdirs else destination
            target_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target_dir / item.name)
            count += 1
    return count


def copy_required(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise RuntimeError(f"Required build output is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_atomic(source: Path, destination: Path) -> None:
    temporary = destination.with_name(f"{destination.name}.{os.getpid()}.tmp")
    try:
        copy_required(source, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def revision() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short=12", "HEAD"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def pointer_path(name: Path) -> Path | None:
    if not name.is_file():
        return None
    value = name.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", value):
        raise RuntimeError(f"Invalid stable version pointer: {name}")
    path = VERSIONS / value
    if not path.is_dir():
        raise RuntimeError(f"Stable version recorded in {name} is missing: {path}")
    return path


def write_pointer(path: Path, version: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(version + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_language_server() -> None:
    haxeon = ROOT / "haxeon"
    haxe = haxeon / ".tools" / "haxe" / ("haxe.exe" if os.name == "nt" else "haxe")
    project = haxeon / "haxeon-lsp.hxml"
    output = haxeon / "out" / "haxeon-lsp.hl"
    sources = [project, *haxeon.joinpath("src").rglob("*.hx")]
    if output.is_file() and not any(source.stat().st_mtime_ns > output.stat().st_mtime_ns for source in sources):
        return
    if not haxe.is_file():
        raise RuntimeError(f"Haxeon language server needs its pinned compiler: {haxe}")
    result = subprocess.run([str(haxe), "--cwd", str(haxeon), str(project)], cwd=ROOT, check=False)
    if result.returncode != 0 or not output.is_file():
        raise RuntimeError("Could not build the Haxeon language server for the stable snapshot")


def save() -> Path:
    runtime_source = ROOT / "haxeon" / ".tools" / "hashlink"
    agent_source = ROOT / "agent" / "build" / "host"
    app_source = ROOT / "graphical" / "build" / "host"
    haxeon_output = ROOT / "haxeon" / "out"
    ensure_language_server()
    runtime = runtime_source / hashlink_name()
    required = [
        app_source / "main.hl",
        agent_source / "main.hl",
        runtime,
        haxeon_output / "haxeon_runtime.hdll",
        haxeon_output / "haxeon-lsp.hl",
    ]
    for path in required:
        if not path.is_file():
            raise RuntimeError(f"Required build output is missing: {path}\nBuild Exosuit first with python scripts/build.py")

    VERSIONS.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    version = f"{timestamp}-{revision()}"
    final = VERSIONS / version
    staging = Path(tempfile.mkdtemp(prefix=".pending-", dir=VERSIONS))
    try:
        copy_required(app_source / "main.hl", staging / "graphical" / "main.hl")
        if copy_libraries(app_source / "native", staging / "graphical" / "native", immediate_subdirs=True) == 0:
            raise RuntimeError(f"No graphical runtime libraries were found under {app_source / 'native'}")

        copy_required(agent_source / "main.hl", staging / "agent" / "main.hl")
        if copy_libraries(agent_source / "native", staging / "agent" / "native", immediate_subdirs=True) == 0:
            raise RuntimeError(f"No workspace-agent libraries were found under {agent_source / 'native'}")
        copy_required(ROOT / "scripts" / "stable_lsp.py", staging / "run-lsp.py")

        bundled_runtime = staging / "haxeon"
        hashlink_destination = bundled_runtime / ".tools" / "hashlink"
        copy_required(runtime, hashlink_destination / runtime.name)
        if copy_libraries(runtime_source, hashlink_destination) == 0:
            raise RuntimeError(f"No HashLink runtime libraries were found under {runtime_source}")
        copy_libraries(haxeon_output, bundled_runtime / "out")
        copy_required(haxeon_output / "haxeon_runtime.hdll", bundled_runtime / "out" / "haxeon_runtime.hdll")
        copy_required(haxeon_output / "haxeon-lsp.hl", bundled_runtime / "out" / "haxeon-lsp.hl")

        stdlib = ROOT / "haxeon" / "stdlib"
        if not stdlib.is_dir():
            raise RuntimeError(f"Missing Haxeon standard library: {stdlib}")
        shutil.copytree(stdlib, bundled_runtime / "stdlib")

        manifest = {
            "version": version,
            "platform": STABLE_ROOT.name,
            "revision": revision(),
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }
        (staging / "stable.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        if final.exists():
            raise RuntimeError(f"Stable snapshot already exists: {final}")
        DATA.mkdir(parents=True, exist_ok=True)
        with stable_lock():
            if os.name == "nt":
                copy_atomic(ROOT / "scripts" / "stable.py", STABLE_ROOT / "stable.py")
                copy_atomic(ROOT / "graphical" / "assets" / "exosuit.ico", STABLE_ROOT / "exosuit.ico")
            os.replace(staging, final)
            old_current = pointer_path(CURRENT)
            if old_current is not None:
                write_pointer(PREVIOUS, old_current.name)
            write_pointer(CURRENT, version)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    prune_versions()
    print(f"Saved stable Exosuit {version}\n{final}")
    return final


def stable_library_directories(bundle: Path) -> list[Path]:
    roots = [
        bundle / "haxeon" / ".tools" / "hashlink",
        bundle / "haxeon" / "out",
        bundle / "graphical" / "native",
        bundle / "agent" / "native",
    ]
    directories: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        candidates = [root, *(item for item in root.iterdir() if item.is_dir())]
        for candidate in candidates:
            if any(item.is_file() and is_dynamic_library(item) for item in candidate.iterdir()):
                directories.append(candidate)
    return directories


def current_bundle() -> Path:
    current = pointer_path(CURRENT)
    if current is None:
        raise RuntimeError("No stable build is saved yet. Run: python scripts/stable.py save")
    return current


def launch(arguments: list[str]) -> int:
    with stable_lock():
        bundle = current_bundle()
        marker = bundle / f".running-launch-{os.getpid()}-{time.time_ns()}"
        marker.write_text(str(os.getpid()) + "\n", encoding="ascii")
    runtime = bundle / "haxeon" / ".tools" / "hashlink" / hashlink_name()
    app = bundle / "graphical" / "main.hl"
    if not runtime.is_file() or not app.is_file():
        marker.unlink(missing_ok=True)
        raise RuntimeError(f"Stable snapshot is incomplete: {bundle}")

    lsp_helper = bundle / "run-lsp.py"
    if not lsp_helper.is_file():
        marker.unlink(missing_ok=True)
        raise RuntimeError(f"Stable snapshot is missing its language-server launcher: {lsp_helper}")
    environment = os.environ.copy()
    variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    directories = [str(path) for path in stable_library_directories(bundle)]
    inherited = environment.get(variable)
    if inherited:
        directories.append(inherited)
    environment[variable] = os.pathsep.join(directories)
    environment.update(
        {
            "PRAGTICAL_PORTABLE": str(DATA),
            "EXOSUIT_AGENT_STATE_HOME": str(DATA),
            "EXOSUIT_AGENT_LAUNCHER": str(bundle / "agent" / "main.hl"),
            "EXOSUIT_AGENT_MANAGED_UPDATES": "0",
            "EXOSUIT_STABLE_BUNDLE": str(bundle),
            "EXOSUIT_CHANNEL": "stable",
            "EXOSUIT_HAXEON_LSP_COMMAND": json.dumps([sys.executable, str(lsp_helper)]),
            "EXOSUIT_HAXEON_CLI_PYTHON": sys.executable,
            "EXOSUIT_PROJECT_ROOT": str(ROOT),
            "HAXEON_HOME": str(bundle / "haxeon"),
            "HAXEON_ROOT": str(bundle / "haxeon"),
        }
    )
    # The process environment pins the server to this exact snapshot.
    environment.pop("HAXEON_LSP", None)
    if os.name == "nt":
        pythonw = Path(sys.executable).with_name("pythonw.exe")
        environment["NK_APPLICATION_RELAUNCH_COMMAND"] = subprocess.list2cmdline([
            str(pythonw if pythonw.is_file() else Path(sys.executable)),
            str(STABLE_ROOT / "stable.py"), "launch",
        ])
        environment["NK_APPLICATION_RELAUNCH_DISPLAY_NAME"] = "Exosuit Stable"
        environment["NK_APPLICATION_RELAUNCH_ICON"] = str(STABLE_ROOT / "exosuit.ico") + ",0"
    try:
        result = subprocess.run([str(runtime), str(app), *arguments], env=environment, check=False)
    finally:
        marker.unlink(missing_ok=True)
    if result.returncode == 0:
        prune_versions()
    return result.returncode


def process_is_running(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ctypes.get_last_error() == 5  # Access denied means the process still exists.
        kernel.CloseHandle(handle)
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def has_running_launcher(bundle: Path) -> bool:
    running = False
    for marker in bundle.glob(".running-*"):
        try:
            pid = int(marker.read_text(encoding="ascii").strip())
        except (OSError, ValueError):
            marker.unlink(missing_ok=True)
            continue
        if process_is_running(pid):
            running = True
        else:
            marker.unlink(missing_ok=True)
    return running


def prune_versions() -> None:
    if not VERSIONS.is_dir():
        return
    with stable_lock():
        keep = {path.name for path in (pointer_path(CURRENT), pointer_path(PREVIOUS)) if path is not None}
        versions_root = VERSIONS.resolve()
        for version in VERSIONS.iterdir():
            if not version.is_dir() or version.name in keep or version.name.startswith(".pending-"):
                continue
            resolved = version.resolve()
            if resolved.parent != versions_root or has_running_launcher(version):
                continue
            try:
                shutil.rmtree(resolved)
            except OSError:
                # Keep snapshots that the operating system still has open.
                continue


def rollback() -> Path:
    with stable_lock():
        current = pointer_path(CURRENT)
        previous = pointer_path(PREVIOUS)
        if previous is None:
            raise RuntimeError("There is no previous stable snapshot to restore")
        if current is not None:
            write_pointer(PREVIOUS, current.name)
        write_pointer(CURRENT, previous.name)
    print(f"Stable Exosuit rolled back to {previous.name}\n{previous}")
    return previous


def status() -> int:
    with stable_lock():
        for label, pointer in (("current", CURRENT), ("previous", PREVIOUS)):
            version = pointer_path(pointer)
            print(f"{label}: {version.name if version else 'not saved'}")
            if version:
                print(f"  {version}")
    print(f"platform: {STABLE_ROOT.name}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("save", help="snapshot the current host build as stable")
    launch_parser = commands.add_parser("launch", help="launch the saved stable build")
    launch_parser.add_argument("arguments", nargs=argparse.REMAINDER, help="arguments passed to Exosuit")
    commands.add_parser("rollback", help="switch to the previous stable snapshot")
    commands.add_parser("status", help="show saved stable snapshots")
    arguments = parser.parse_args()
    try:
        if arguments.command == "save":
            save()
            return 0
        if arguments.command == "launch":
            forwarded = arguments.arguments
            if forwarded and forwarded[0] == "--":
                forwarded = forwarded[1:]
            return launch(forwarded)
        if arguments.command == "rollback":
            rollback()
            return 0
        return status()
    except (OSError, RuntimeError) as error:
        print(f"Stable Exosuit: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
