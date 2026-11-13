"""What the test drivers share, on Linux, macOS and Windows: the Haxeon CLI, a built test program, isolated state and
stopping what a test started.

A driver must not start `haxeon/scripts/haxeon` itself: it is a Bash script, which Windows cannot start (WinError 193).
`haxeon(...)` runs the CLI the way scripts/build.py does. `build_test(name)` builds tests/<name> once and returns the
command that runs it, so each step of a driver starts the program without the compiler in between.

State: `isolated_environment(state)` points every state variable at `state`. XDG_STATE_HOME alone does nothing on
Windows, where the agent uses EXOSUIT_AGENT_STATE_HOME or %LOCALAPPDATA%\\Exosuit; with both set, a workspace's state is
<state>/exosuit/workspaces/<key> on every platform, and the editor's own state (PRAGTICAL_PORTABLE) is <state>/portable.

Stopping: SIGTERM lets a manager clean up on POSIX. On Windows os.kill is TerminateProcess, which leaves the endpoint
file and, under a terminal host, the terminals; `stop_manager` writes the stop request suit writes."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from agent_test_runtime import manager_environment

ROOT = Path(__file__).resolve().parent.parent
WINDOWS = os.name == "nt"
HAXEON_ROOT = Path(os.environ.get("HAXEON_ROOT") or ROOT / "haxeon").expanduser().resolve()
MODE = ["--self-hosted"] if os.environ.get("HAXEON_SELF_HOSTED") == "1" else []
HL = HAXEON_ROOT / ".tools" / "hashlink" / ("hl.exe" if WINDOWS else "hl")
LIBRARY_VARIABLE = "PATH" if WINDOWS else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"


def kill_tree(process: subprocess.Popen) -> None:
    """Stops a child and everything it started; a timeout must not leave a manager, a shell or a PTY behind."""
    if process.poll() is not None:
        return
    if WINDOWS:
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            process.kill()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass


def run_tree(command: list[str], environment: dict[str, str] | None = None, timeout: float = 120, check: bool = True, **options) -> int:
    """Runs a command in a process group of its own and stops the whole group when it takes longer than `timeout`."""
    process = subprocess.Popen(command, env=environment, start_new_session=not WINDOWS, **options)
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_tree(process)
        raise
    if check and status != 0:
        raise subprocess.CalledProcessError(status, command)
    return status


def haxeon(arguments: list[str], environment: dict[str, str] | None = None, timeout: float = 900, check: bool = True) -> int:
    """Runs the Haxeon CLI: HAXEON_BIN when set, else scripts/haxeon_cli.py (the Bash launcher off Windows, hl.exe on it)."""
    configured = os.environ.get("HAXEON_BIN")
    command = [configured] if configured else [sys.executable, str(ROOT / "scripts" / "haxeon_cli.py")]
    return run_tree([*command, *arguments], dict(environment or os.environ, EXOSUIT_PROJECT_ROOT=str(ROOT)), timeout, check)


def build_test(name: str) -> list[str]:
    """Builds tests/<name> and returns the command that starts the built program (arguments follow it)."""
    project = ROOT / "tests" / name / "haxeon.json"
    haxeon(["build", "--project", str(project), *MODE])
    return [str(HL), str(project.parent / "build" / "host" / "main.hl")]


def with_libraries(environment: dict[str, str], *directories: Path) -> dict[str, str]:
    """`environment` with the HashLink runtime, Haxeon's native runtime and the native packages under `directories` on the
    library path. A missing one is a load error (exit -1073741515 on Windows), not a test failure."""
    found = [HAXEON_ROOT / "out", HL.parent]
    for directory in directories:
        if directory.is_dir():
            found.append(directory)
            found.extend(sorted(path for path in directory.iterdir() if path.is_dir()))
    inherited = environment.get(LIBRARY_VARIABLE, "")
    result = dict(environment)
    result[LIBRARY_VARIABLE] = os.pathsep.join([*(str(path) for path in found), *([inherited] if inherited else [])])
    return result


def assert_private(path: Path) -> None:
    """The file is readable by its owner only: no group or other mode bits on POSIX; on Windows the owner is the current
    user and no allow entry grants Everyone, Users or Authenticated Users anything (inherited entries count)."""
    if not WINDOWS:
        assert path.stat().st_mode & 0o077 == 0, f"{path} is not private"
        return
    script = (
        "$ErrorActionPreference='Stop';$sid=[Security.Principal.SecurityIdentifier];$a=(New-Object IO.FileInfo $env:EXOSUIT_ACL_PATH).GetAccessControl();"
        "$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$owner=$a.GetOwner($sid).Value;"
        "$bad=@('S-1-1-0','S-1-5-32-545','S-1-5-11');"
        "$open=@($a.GetAccessRules($true,$true,$sid)|?{$_.AccessControlType -eq 'Allow' -and ($bad -contains $_.IdentityReference.Value)}|%{$_.IdentityReference.Value});"
        "ConvertTo-Json -Compress @{ownerIsMe=($owner -eq $me);owner=$owner;open=$open}"
    )
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script], env={**os.environ, "EXOSUIT_ACL_PATH": str(path)},
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"ACL of {path} unreadable: {result.stderr}"
    value = json.loads(result.stdout)
    # An administrator's files are owned by the Administrators group; that is still the current user's own.
    assert value["ownerIsMe"] or value["owner"] == "S-1-5-32-544", f"{path} is owned by {value['owner']}"
    assert not value["open"], f"{path} is readable by {value['open']}"


def isolated_environment(state: Path, launcher: Path | None = None, test: str | None = None) -> dict[str, str]:
    """The environment of a manager and of a test program that starts managers, with all state under `state` and the
    native packages of the agent (and of tests/<test>) loadable. Managers neither register with suit nor start it."""
    environment = manager_environment(ROOT, launcher)
    environment.update(
        XDG_STATE_HOME=str(state),
        EXOSUIT_AGENT_STATE_HOME=str(state / "exosuit"),
        PRAGTICAL_PORTABLE=str(state / "portable"),
        EXOSUIT_SUIT="off",
    )
    # A service that outlives its clients because the caller's environment asks for it never lets a test end.
    environment.pop("EXOSUIT_AGENT_ALWAYS_AVAILABLE", None)
    (state / "portable").mkdir(parents=True, exist_ok=True)
    if test is not None:
        environment = with_libraries(environment, ROOT / "tests" / test / "build" / "host" / "native")
    return environment


def endpoints(state: Path) -> list[Path]:
    """The endpoint files of the managers running on the default state of each root under `state`."""
    return sorted(state.glob("exosuit/workspaces/*/endpoint.json"))


def endpoint_for(state: Path, root: Path) -> Path:
    """The endpoint file of the manager serving the folder `root`. The state folder's name is a hash of the root as the
    agent spells it, which differs by platform; the descriptor's own `root` does not."""
    wanted = os.path.normcase(os.path.realpath(root))
    for endpoint in endpoints(state):
        try:
            served = json.loads(endpoint.read_text())["root"]
        except (OSError, ValueError, KeyError):
            continue
        if os.path.normcase(os.path.realpath(served)) == wanted:
            return endpoint
    raise FileNotFoundError(f"no manager serves {root} under {state}")


def process_runs(pid: int) -> bool:
    if WINDOWS:
        import ctypes
        kernel = ctypes.WinDLL("kernel32")
        kernel.OpenProcess.restype = ctypes.c_void_p
        handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = ctypes.c_ulong()
        kernel.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code))
        kernel.CloseHandle(ctypes.c_void_p(handle))
        return code.value == 259
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def request_stop(endpoint: Path, descriptor: dict | None = None) -> None:
    """Asks the manager of `endpoint` to stop and returns at once: SIGTERM, or on Windows the stop request suit writes."""
    try:
        descriptor = descriptor or json.loads(endpoint.read_text())
    except (OSError, ValueError):
        return
    if WINDOWS:
        (endpoint.parent / "stop-request.json").write_text(json.dumps({"version": 1, "generation": descriptor["generation"]}) + "\n")
        return
    try:
        os.kill(descriptor["managerPid"], signal.SIGTERM)
    except ProcessLookupError:
        pass


def stop_manager(endpoint: Path, timeout: float = 15) -> bool:
    """Stops the manager of `endpoint` and waits for its endpoint file to go; a manager that ignores the request is
    killed. Returns whether it stopped on request."""
    try:
        descriptor = json.loads(endpoint.read_text())
    except (OSError, ValueError):
        return True
    request_stop(endpoint, descriptor)
    deadline = time.monotonic() + timeout
    while endpoint.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not endpoint.exists():
        return True
    pid = descriptor.get("managerPid")
    if isinstance(pid, int) and process_runs(pid):
        if WINDOWS:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            os.kill(pid, signal.SIGKILL)
    return False


def stop_managers(state: Path, timeout: float = 15) -> None:
    """Stops every manager with state under `state`, including ones started before a failed assertion."""
    found = endpoints(state)
    for endpoint in found:
        request_stop(endpoint)
    for endpoint in found:
        stop_manager(endpoint, timeout)
