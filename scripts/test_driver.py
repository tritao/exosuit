"""What the test drivers share, on Linux, macOS and Windows: the Haxeon CLI, the built workspace agent, a built test
program, isolated state and stopping what a test started.

A driver must not start `haxeon/scripts/haxeon` itself: it is a Bash script, which Windows cannot start (WinError 193).
`haxeon(...)` runs the CLI the way scripts/build.py does. `build_test(name)` builds tests/<name> once and returns the
command that runs it, so each step of a driver starts the program without the compiler in between.

State: `isolated_environment(state)` points every state variable at `state`. XDG_STATE_HOME alone does nothing on
Windows, where the agent uses EXOSUIT_AGENT_STATE_HOME or %LOCALAPPDATA%\\Exosuit; with both set, a workspace's state is
<state>/exosuit/workspaces/<key> on every platform, and the editor's own state (PRAGTICAL_PORTABLE) is <state>/portable.
Claude Code and Codex read and write their configuration folders (CLAUDE_CONFIG_DIR, CODEX_HOME), else the user's
~/.claude and ~/.codex: `isolated_environment` points them under `state` too (`agent_homes`).

Services: `start_service` runs a workspace service as exohost does (`--workspace ID --folder ROOT`) and waits until its
service.log says it is ready. A service stops when idle (EXOSUIT_SERVICE_IDLE_SECONDS) or when exohost asks over its link;
without exohost, `stop_services` stops what is left (SIGTERM first on POSIX, a kill on Windows)."""
from __future__ import annotations

import atexit
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
WINDOWS = os.name == "nt"
HAXEON_ROOT = Path(os.environ.get("HAXEON_ROOT") or ROOT / "haxeon").expanduser().resolve()
MODE = ["--self-hosted"] if os.environ.get("HAXEON_SELF_HOSTED") == "1" else []
HL = HAXEON_ROOT / ".tools" / "hashlink" / ("hl.exe" if WINDOWS else "hl")
LIBRARY_VARIABLE = "PATH" if WINDOWS else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"


def runtime_paths(root: Path) -> tuple[Path, Path]:
    """The HashLink runtime (HAXEON_HL or HL_BIN when set) and the built workspace agent's bytecode."""
    haxeon = Path(os.environ.get("HAXEON_ROOT", root / "haxeon")).expanduser()
    bytecode = root / "agent" / "build" / "host" / "main.hl"
    configured = os.environ.get("HAXEON_HL") or os.environ.get("HL_BIN")
    if configured:
        runtime = Path(configured).expanduser()
    else:
        executable = "hl.exe" if WINDOWS else "hl"
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


def service_command(root: Path) -> list[str]:
    """The command that runs the workspace service; `--workspace ID [--folder F]... [--scratch S]` follows it."""
    runtime, bytecode = runtime_paths(root)
    return [str(runtime), str(bytecode)]


def launcher_path(root: Path) -> Path:
    """The workspace agent's bytecode: the services' program, and what a test program starts a service with."""
    return runtime_paths(root)[1]


_EXOHOST_HOME: str | None = None


def isolated_exohost(environment: dict[str, str] | None = None) -> dict[str, str]:
    """EXOSUIT_EXOHOST_HOME and EXOSUIT_EXOHOST_AUTOSTART for a test: an exohost home of the run's own, which is never started.
    An inherited EXOSUIT_EXOHOST_HOME may be the user's, so it is never used; the test runners name the run's home with
    EXOSUIT_TEST_HOME (its `exohost` folder), else a temporary one is made and removed when the driver exits."""
    global _EXOHOST_HOME
    environment = os.environ if environment is None else environment
    if environment.get("EXOSUIT_TEST_HOME"):
        return {"EXOSUIT_EXOHOST_HOME": str(Path(environment["EXOSUIT_TEST_HOME"]) / "exohost"), "EXOSUIT_EXOHOST_AUTOSTART": "0"}
    if _EXOHOST_HOME is None:
        temporary = tempfile.mkdtemp(prefix="exosuit-test-exohost-")
        atexit.register(shutil.rmtree, temporary, True)
        _EXOHOST_HOME = str(Path(temporary) / "exohost")
    return {"EXOSUIT_EXOHOST_HOME": _EXOHOST_HOME, "EXOSUIT_EXOHOST_AUTOSTART": "0"}


def service_environment(root: Path, launcher: Path | None = None) -> dict[str, str]:
    """The environment of a workspace service (and of a test program that starts one): the runtime's and the agent's
    native libraries on the library path, and an exohost home of the test's own that is never started."""
    runtime, bytecode = runtime_paths(root)
    environment = os.environ.copy()
    agent_root = (launcher or bytecode).parent
    haxeon = Path(os.environ.get("HAXEON_ROOT", root / "haxeon")).expanduser()
    libraries = [haxeon / "out", haxeon / ".tools" / "hashlink", agent_root / "native"]
    if (agent_root / "native").is_dir():
        libraries.extend(sorted(path for path in (agent_root / "native").iterdir() if path.is_dir()))
    libraries.append(runtime.parent)
    libraries = [str(path.resolve()) for path in libraries if path.is_dir()]
    inherited = environment.get(LIBRARY_VARIABLE, "")
    environment[LIBRARY_VARIABLE] = os.pathsep.join(libraries + ([inherited] if inherited else []))
    # Test services talk only to an exohost in a home of their own and do not start it (see exohost/README.md).
    environment.update(isolated_exohost(environment))
    return environment


def kill_tree(process: subprocess.Popen) -> None:
    """Stops a child and everything it started; a timeout must not leave a service, a shell or a PTY behind."""
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


def wait_until(condition, timeout: float, message: str, interval: float = 0.1):
    """Polls `condition` until it returns a true value, which it returns; fails with `message` after `timeout` seconds."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(message)


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
    """The environment of a service and of a test program that starts services, with all state under `state` and the
    native packages of the agent (and of tests/<test>) loadable. Services reach only an exohost home of their own and do not
    start exohost."""
    environment = service_environment(ROOT, launcher)
    environment.update(
        XDG_STATE_HOME=str(state),
        EXOSUIT_AGENT_STATE_HOME=str(state / "exosuit"),
        PRAGTICAL_PORTABLE=str(state / "portable"),
        **agent_homes(state),
    )
    (state / "portable").mkdir(parents=True, exist_ok=True)
    if test is not None:
        environment = with_libraries(environment, ROOT / "tests" / test / "build" / "host" / "native")
    return environment


def agent_homes(folder: Path) -> dict[str, str]:
    """CLAUDE_CONFIG_DIR and CODEX_HOME under `folder` (created), so an agent CLI a test starts, and a service reading its
    transcripts, never use the user's ~/.claude or ~/.codex."""
    homes = {"CLAUDE_CONFIG_DIR": folder / "claude-config", "CODEX_HOME": folder / "codex-home"}
    for path in homes.values():
        path.mkdir(parents=True, exist_ok=True)
    return {name: str(path) for name, path in homes.items()}


def signed_in_home(variable: str) -> str:
    """The configuration folder a test against a real agent CLI runs with: `variable` (CLAUDE_CONFIG_DIR or CODEX_HOME)
    must name a signed-in folder of the test's own. Exits when it is unset or is the user's own (~/.claude, ~/.codex),
    which tests never read or write."""
    own = Path.home() / {"CLAUDE_CONFIG_DIR": ".claude", "CODEX_HOME": ".codex"}[variable]
    value = os.environ.get(variable, "")
    if not value or Path(value).expanduser().resolve() == own.resolve():
        sys.exit(f"set {variable} to a signed-in configuration folder of the test's own: the user's {own} is not used")
    return value


def workspace_id(root: Path | str) -> str:
    """The test workspace of folder `root`, as testing.DirectService.idOf names it: a hash of the path as spelled."""
    return "test-" + hashlib.sha256(str(root).encode()).hexdigest()[:16]


def service_log(state: Path, workspace: str) -> Path:
    return state / "exosuit" / "workspaces" / workspace / "service.log"


class Service:
    """A service seen ready in its service.log: its process (when this driver started it), pipe, generation, pid, root."""

    def __init__(self, process, endpoint: str, generation: str, pid: int, root: str):
        self.process, self.endpoint, self.generation, self.pid, self.root = process, endpoint, generation, pid, root

    def runs(self) -> bool:
        return process_runs(self.pid)

    def wait(self, timeout: float) -> int:
        """Waits for the service to exit; its status when this driver started it, else 0."""
        if self.process is not None:
            return self.process.wait(timeout=timeout)
        deadline = time.monotonic() + timeout
        while process_runs(self.pid):
            if time.monotonic() > deadline:
                raise subprocess.TimeoutExpired(str(self.pid), timeout)
            time.sleep(0.05)
        return 0


def ready_services(log: Path, offset: int = 0) -> list[Service]:
    """The services that got ready in `log` after byte `offset`, oldest first (generation and pid from the line before)."""
    try:
        text = log.read_bytes()[offset:].decode("utf-8", "replace")
    except OSError:
        return []
    found, starting = [], None
    for line in text.splitlines():
        if "service starting: generation " in line:
            generation, _, pid = line.split("service starting: generation ", 1)[1].partition(", pid ")
            starting = (generation.strip(), int(pid.strip()))
        elif "service ready on " in line and starting is not None:
            endpoint, _, root = line.split("service ready on ", 1)[1].partition(" for ")
            found.append(Service(None, endpoint.strip(), starting[0], starting[1], root.strip()))
    return found


IN_USE = 3


def start_service(environment: dict[str, str], state: Path, root: Path, idle_seconds: float | None = None,
                  timeout: float = 90, workspace: str | None = None, **options) -> Service:
    """Starts the service of the test workspace of `root` (as exohost does) and returns it once ready. `idle_seconds` sets
    its idle limit (EXOSUIT_SERVICE_IDLE_SECONDS). When one already runs (exit 3: it holds the lock) that one is returned."""
    workspace = workspace or workspace_id(root)
    log = service_log(state, workspace)
    offset = log.stat().st_size if log.exists() else 0
    environment = dict(environment)
    if idle_seconds is not None:
        environment["EXOSUIT_SERVICE_IDLE_SECONDS"] = str(idle_seconds)
    process = subprocess.Popen([*service_command(ROOT), "--workspace", workspace, "--folder", str(root)], env=environment,
                               cwd=str(root), start_new_session=not WINDOWS, **options)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = process.poll()
        if status == IN_USE:
            running = ready_services(log)
            if running and running[-1].runs():
                return running[-1]
            raise AssertionError(f"the service of {workspace} holds its lock but no running one is logged")
        if status is not None:
            raise AssertionError(f"the service exited with {status}: " + (log.read_text()[-4000:] if log.exists() else "no log"))
        started = ready_services(log, offset)
        if started:
            service = started[-1]
            service.process = process
            return service
        time.sleep(0.05)
    kill_tree(process)
    raise AssertionError(f"the service of {workspace} was not ready in {timeout} s")


def running_services(state: Path) -> list[Service]:
    """The services with state under `state` that still run."""
    return [service for log in state.glob("exosuit/workspaces/*/service.log") for service in ready_services(log) if service.runs()]


def stop_services(state: Path) -> None:
    """Stops every service with state under `state` that still runs, including ones started before a failed assertion."""
    for service in running_services(state):
        if WINDOWS:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(service.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            continue
        try:
            os.kill(service.pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        deadline = time.monotonic() + 10
        while service.runs() and time.monotonic() < deadline:
            time.sleep(0.05)
        if service.runs():
            os.kill(service.pid, signal.SIGKILL)


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
