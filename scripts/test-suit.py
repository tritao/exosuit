#!/usr/bin/env python3
"""suit end to end, isolated from the user's session.

Every suit call runs with EXOSUIT_SUIT=isolated and its own EXOSUIT_SUIT_HOME, so its own registry and
control endpoint. Most tests also set EXOSUIT_SUIT_SCAN=0, so suit sees only the processes this test
registers. The ownership test scans, so it lists the user's processes too, but it only reads that listing,
checks with --dry-run that bulk kills would touch none of them, and kills only its own processes by pid.

Covers: registration and pid-reuse checks (including old whole-second records), orphan detection, workspaces
shared by editors or kept by suit's relay hosting, positive ownership (adoption only of exosuit kinds exosuit
started itself, never through a terminal, never of EXOSUIT_SUIT=off; scanned processes kept out of bulk
kills), listing without side effects, graceful stops that then kill only exosuit kinds (a terminal's programs
survive Quit, a worker started during the grace period does not), relay listing and stop, the daemon's control
endpoint (status, quit, stop), suit's unit tests, and, with --real-manager, a real workspace manager that
registers itself and stops cooperatively through stop-request.json, and EXOSUIT_SUIT=off, isolated and unset-
with-temporary-state keeping a real manager out of the default registry.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from suit import library_path, library_variable  # noqa: E402  (one library-path rule, shared with suit.py)

HAXEON = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
HL = HAXEON / ".tools" / "hashlink" / ("hl.exe" if os.name == "nt" else "hl")
SUIT = ROOT / "suit" / "build" / "host" / "main.hl"
SLEEPER = [sys.executable, "-c", "import time; time.sleep(300)"]
# Starts each command in argv[1] (a JSON list) as its child, then sleeps. An item may be
# {"command": [...], "env": {...}} to change the child's environment. A terminal shell is one of these too.
_START = ("[subprocess.Popen(c['command'] if isinstance(c, dict) else c, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, "
          "stderr=subprocess.DEVNULL, env=dict(os.environ, **(c.get('env', {}) if isinstance(c, dict) else {}))).pid "
          "for c in json.loads(sys.argv[1])]")
SPAWNER = [sys.executable, "-c", f"import json, os, subprocess, sys, time; {_START}; time.sleep(300)"]
# Like SPAWNER, but starts them after 1.5 s, inside suit's 3 s grace period for a workspace manager, and writes
# their pids (comma separated) to argv[2].
LATE_PARENT = [sys.executable, "-c",
               f"import json, os, subprocess, sys, time; time.sleep(1.5); pids = {_START}; "
               "open(sys.argv[2], 'w').write(','.join(map(str, pids))); time.sleep(300)"]
# A fake Haxeon compiler worker: suit's own read-only `watch`, whose command line looks like a worker's.
WORKER = [str(HL), str(SUIT), "watch", "--fake=/haxeon/compiler/suit-test-worker.hl"]


def suit_library_path() -> str:
    """suit's library path, plus the agent's native packages for the real manager and editor tests."""
    agent_native = ROOT / "agent/build/host/native"
    extra = sorted(str(path) for path in agent_native.iterdir() if path.is_dir()) if agent_native.is_dir() else []
    return os.pathsep.join([library_path(SUIT, HL, HAXEON), *extra, os.environ.get(library_variable(), "")])


class Fixture:
    def __init__(self, directory: Path) -> None:
        self.home = directory / "suit-home"
        self.registry = self.home / "registry"
        # isolated: anything started with this environment registers here, never in the user's registry.
        self.environment = dict(os.environ, EXOSUIT_SUIT="isolated", EXOSUIT_SUIT_HOME=str(self.home),
                                EXOSUIT_SUIT_SCAN="0", EXOSUIT_SUIT_TRAY="0", EXOSUIT_SUIT_AUTOSTART="0",
                                EXOSUIT_SUIT_IDLE_SECONDS="30", EXOSUIT_SUIT_LAUNCHER=str(SUIT))
        self.environment[library_variable()] = suit_library_path()
        self.children: list[subprocess.Popen] = []
        # suit creates its home with an owner-only ACL; the test writes records into it afterwards.
        self.suit("status")
        assert self.registry.is_dir()

    def suit(self, *arguments: str, timeout: float = 60) -> str:
        result = subprocess.run([str(HL), str(SUIT), *arguments], env=self.environment, capture_output=True,
                                text=True, timeout=timeout)
        assert result.returncode == 0, f"suit {' '.join(arguments)} failed ({result.returncode}): {result.stderr}{result.stdout}"
        return result.stdout

    def listing(self) -> dict:
        return json.loads(self.suit("list", "--json"))

    def spawn(self, command: list[str] = SLEEPER, environment: dict | None = None) -> subprocess.Popen:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   env=environment)
        self.children.append(process)
        time.sleep(0.2)
        return process

    def register(self, pid: int, kind: str, registered_at: float | None = None, version: int = 2,
                 **details: object) -> None:
        record = {"version": version, "pid": pid, "kind": kind,
                  "registeredAt": registered_at if registered_at is not None else time.time() * 1000, **details}
        (self.registry / f"{pid}.json").write_text(json.dumps(record))

    def cleanup(self) -> None:
        for child in self.children:
            if child.poll() is None:
                child.kill()
        for child in self.children:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass


def alive(process: subprocess.Popen) -> bool:
    return process.poll() is None


def find(listing: dict, pid: int) -> dict | None:
    return next((entry for entry in listing["processes"] if entry["pid"] == pid), None)


def write_private(path: Path, text: str) -> None:
    """Writes a file only this user can read, as suit requires of relay records and settings."""
    path.write_text(text)
    if os.name == "nt":
        user = f"{os.environ['USERDOMAIN']}\\{os.environ['USERNAME']}"
        subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"{user}:F"], check=True, capture_output=True)
    else:
        path.chmod(0o600)


def wait_until(condition, timeout: float, message: str) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.1)
    raise AssertionError(message)


def test_registry_and_termination(fixture: Fixture, directory: Path) -> None:
    root_a, root_b, root_c = directory / "alpha", directory / "beta", directory / "gamma"
    for root in (root_a, root_b, root_c):
        root.mkdir()
    editor = fixture.spawn()
    fixture.register(editor.pid, "editor", roots=[str(root_a), str(root_c)])
    owned = fixture.spawn()
    fixture.register(owned.pid, "workspace-host", root=str(root_a))
    orphan = fixture.spawn()
    fixture.register(orphan.pid, "workspace-host", root=str(root_b), owner=999999)
    # A record written before its pid started describes an older process that reused the pid.
    reused = fixture.spawn()
    fixture.register(reused.pid, "workspace-host", registered_at=time.time() * 1000 - 3600_000, root=str(root_b))
    dead = fixture.spawn()
    dead.kill(); dead.wait()
    fixture.register(dead.pid, "workspace-host", root=str(root_b))
    # A relay-hosting workspace: its daemon's published status, read from the state directory.
    state = directory / "gamma-state"; state.mkdir()
    (state / "relay-settings.json").write_text(json.dumps({"version": 1, "origin": "http://127.0.0.1:1"}))
    (state / "relay-status.json").write_text(json.dumps({
        "version": 1, "configured": True, "connected": True, "origin": "http://127.0.0.1:1", "error": None,
        "devices": [{"deviceId": "d" * 32, "connected": True, "revoked": False}], "pending": 1,
        "updatedAt": time.time() * 1000}))
    hosted = fixture.spawn()
    fixture.register(hosted.pid, "workspace-host", root=str(root_c), stateDir=str(state))

    # A record from the second its process started, written by a suit that kept whole seconds (version 1).
    same_second = fixture.spawn()
    fixture.register(same_second.pid, "workspace-host", root=str(root_a))
    started = find(fixture.listing(), same_second.pid)["started"]
    fixture.register(same_second.pid, "workspace-host", registered_at=float(started // 1000 * 1000), version=1,
                     root=str(root_a))
    # The same time in a current record is before the start: an earlier owner of the pid.
    early = fixture.spawn()
    fixture.register(early.pid, "workspace-host", root=str(root_b))
    early_started = find(fixture.listing(), early.pid)["started"]
    fixture.register(early.pid, "workspace-host", registered_at=float(early_started - 1000), root=str(root_b))

    listing = fixture.listing()
    assert listing["editors"] == 1, listing
    assert find(listing, owned.pid)["orphaned"] is False and find(listing, owned.pid)["group"].startswith("Editor"), listing
    assert find(listing, orphan.pid)["orphaned"] is True, listing
    assert find(listing, same_second.pid) is not None, "a version 1 record from its process's start second was dropped"
    assert find(listing, early.pid) is None, "a current record older than its process was kept"
    assert find(listing, reused.pid) is None, "pid reuse not detected"
    assert find(listing, dead.pid) is None, "stale record listed"
    # Listing has no side effects: only the daemon prunes stale records.
    assert (fixture.registry / f"{reused.pid}.json").exists() and (fixture.registry / f"{dead.pid}.json").exists(), \
        "suit list deleted records"
    for extra in (same_second, early):
        extra.kill(); extra.wait()
        (fixture.registry / f"{extra.pid}.json").unlink()
    assert "Exosuit: 1 editor, 4 background processes (1 orphaned)" == listing["summary"], listing["summary"]
    text = fixture.suit("list")
    assert "Orphaned" in text and "workspace-host" in text, text

    relay = fixture.suit("relay", "list")
    assert "gamma" in relay and "connected" in relay and "d" * 32 in relay and "1 pairing request" in relay, relay
    assert "secret" not in relay

    # Only processes suit knows about may be killed by pid.
    refused = subprocess.run([str(HL), str(SUIT), "kill", str(os.getpid())], env=fixture.environment,
                             capture_output=True, text=True, timeout=60)
    assert refused.returncode != 0 and "not an exosuit process" in refused.stderr, refused

    output = fixture.suit("kill", "--orphans")
    assert f"{orphan.pid} workspace-host: killed" in output, output
    wait_until(lambda: not alive(orphan), 10, "orphan survived")
    assert alive(owned) and alive(editor) and alive(hosted), "kill --orphans touched owned processes"

    output = fixture.suit("relay", "stop", "gamma")
    assert f"{hosted.pid} workspace-host" in output, output
    wait_until(lambda: not alive(hosted), 10, "relay host survived")
    assert alive(owned), "relay stop touched another workspace"

    fixture.suit("kill", "--all")
    wait_until(lambda: not alive(owned), 10, "background process survived kill --all")
    assert alive(editor), "kill --all must keep editors"


def test_quit_spares_terminals(fixture: Fixture) -> None:
    """Quit stops exosuit's processes and what exosuit spawned under them, never what a terminal started.

    A fake workspace daemon (registered) starts a compiler worker itself, and a terminal shell. In the shell
    the user ran a build (another compiler worker) and a program of their own. Quit kills the daemon and
    its worker; the shell, the build and the program live on, as if the user had left the terminal open.
    """
    scanning = dict(fixture.environment, EXOSUIT_SUIT_SCAN="1")
    shell = SPAWNER + [json.dumps([WORKER, SLEEPER])]
    host = fixture.spawn(SPAWNER + [json.dumps([WORKER, shell])], fixture.environment)
    fixture.register(host.pid, "workspace-host", root=str(Path(tempfile.gettempdir()) / "suit-test-quit"))
    wait_until(lambda: len(child_processes(host.pid)) == 2, 30, "the fake daemon did not start its children")
    worker, shell_pid = by_name(child_processes(host.pid))
    wait_until(lambda: len(child_processes(shell_pid)) == 2, 30, "the fake shell did not start its children")
    build, program = by_name(child_processes(shell_pid))
    survivors = [shell_pid, build, program]
    try:
        listing = scanned_listing(scanning)
        assert find(listing, worker)["source"] == "adopted", find(listing, worker)
        assert find(listing, build)["source"] == "scanned", "a worker started from a terminal was adopted"
        assert find(listing, shell_pid) is None and find(listing, program) is None, "suit listed a terminal's programs"
        planned = planned_kills(scanning, "--all")
        assert planned == {host.pid, worker}, f"kill --all would stop {planned}, not just this test's daemon and worker"
        assert "started" in run_suit(scanning, "start")
        assert "Quitting Exosuit" in run_suit(scanning, "quit")
        wait_until(lambda: not alive(host) and not pid_alive(worker), 15, "quit left the daemon or its worker running")
        time.sleep(1)
        for pid in survivors:
            assert pid_alive(pid), f"quit killed {pid}, which a terminal started"
    finally:
        for pid in [worker, *survivors]:
            if pid_alive(pid):
                kill_pid(pid)


def run_suit(environment: dict, *arguments: str) -> str:
    result = subprocess.run([str(HL), str(SUIT), *arguments], env=environment, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"suit {' '.join(arguments)} failed: {result.stderr}{result.stdout}"
    return result.stdout


def scanned_listing(environment: dict) -> dict:
    return json.loads(run_suit(environment, "list", "--json"))


def planned_kills(environment: dict, selection: str) -> set[int]:
    output = run_suit(environment, "kill", selection, "--dry-run")
    return {int(line.split()[0]) for line in output.splitlines() if line.endswith("would stop")}


def by_name(children: dict[int, str]) -> tuple[int, int]:
    """The hl child and the other one, of a fake process that started a worker and one python process."""
    hl = [pid for pid, name in children.items() if name.lower().startswith("hl")]
    other = [pid for pid, name in children.items() if not name.lower().startswith("hl")]
    assert len(hl) == 1 and len(other) == 1, children
    return hl[0], other[0]


def registry_state(registry: Path) -> dict[str, str]:
    return {path.name: path.read_text() for path in sorted(registry.glob("*.json"))}


def test_shared_workspace(fixture: Fixture, directory: Path) -> None:
    """A workspace's services belong to every editor that uses its root, not to the one that started them."""
    root = directory / "shared"; root.mkdir(parents=True)
    first, second = fixture.spawn(), fixture.spawn()
    fixture.register(first.pid, "editor", roots=[str(root)])
    fixture.register(second.pid, "editor", roots=[str(root)])
    manager = fixture.spawn()
    fixture.register(manager.pid, "workspace-manager", root=str(root))
    host = fixture.spawn()
    fixture.register(host.pid, "workspace-host", root=str(root))
    first.kill(); first.wait()
    listing = fixture.listing()
    for service in (manager, host):
        entry = find(listing, service.pid)
        assert entry["orphaned"] is False and entry["group"] == f"Editor {second.pid}: shared", entry
    assert "Nothing to terminate" in fixture.suit("kill", "--orphans", "--dry-run")
    second.kill(); second.wait()
    listing = fixture.listing()
    assert all(find(listing, service.pid)["orphaned"] for service in (manager, host)), listing
    planned = fixture.suit("kill", "--orphans", "--dry-run")
    assert f"{manager.pid} workspace-manager: would stop" in planned and f"{host.pid} workspace-host" in planned, planned
    assert alive(manager) and alive(host), "--dry-run stopped something"


def test_hosted_workspace(fixture: Fixture, directory: Path) -> None:
    """Services suit starts for a workspace it hosts are in use while hosting is on: not orphaned, and
    Terminate orphaned leaves them. Paused hosting makes them ordinary orphans again."""
    root = directory / "hosted"; root.mkdir(parents=True)
    state = directory / "hosted-state"; state.mkdir()
    settings = state / "relay-settings.json"
    write_private(settings, json.dumps({"version": 1, "origin": "http://127.0.0.1:1"}))
    machine = "ab" * 16
    hosts = fixture.home / "relay-hosts"; hosts.mkdir()
    write_private(hosts / f"{machine}.json", json.dumps({
        "version": 1, "root": str(root), "stateDir": str(state), "machineId": machine, "origin": "http://127.0.0.1:1",
        "executable": str(HL), "launcher": str(SUIT)}))
    manager, host = fixture.spawn(), fixture.spawn()
    fixture.register(manager.pid, "workspace-manager", root=str(root), stateDir=str(state), generation="g1")
    fixture.register(host.pid, "workspace-host", root=str(root), stateDir=str(state), owner=manager.pid)
    # Another workspace's manager with no editor and no hosting stays an orphan.
    other = fixture.spawn()
    fixture.register(other.pid, "workspace-manager", root=str(directory / "other"), stateDir=str(directory / "other-state"))
    listing = fixture.listing()
    for service in (manager, host):
        entry = find(listing, service.pid)
        assert entry["orphaned"] is False and entry["group"] == "Other", entry
    assert find(listing, other.pid)["orphaned"] is True, find(listing, other.pid)
    output = fixture.suit("kill", "--orphans")
    assert f"{other.pid} workspace-manager" in output and str(manager.pid) not in output and str(host.pid) not in output, output
    wait_until(lambda: not alive(other), 10, "the unhosted orphan survived")
    time.sleep(0.5)
    assert alive(manager) and alive(host), "Terminate orphaned stopped a hosted workspace's services"
    settings.write_text(json.dumps({"version": 1, "origin": "http://127.0.0.1:1", "hosting": "paused"}))
    listing = fixture.listing()
    assert all(find(listing, service.pid)["orphaned"] for service in (manager, host)), listing


def test_late_child(fixture: Fixture, directory: Path) -> None:
    """A worker started during the grace period dies: suit kills the target, then sweeps a fresh snapshot.
    A program of another kind started then is not exosuit's to kill, and lives on."""
    directory.mkdir(parents=True, exist_ok=True)
    state = directory / "late-state"; state.mkdir()
    marker = directory / "late-children.pid"
    # A fake workspace manager that ignores stop-request.json, so suit waits out the grace period.
    manager = fixture.spawn(LATE_PARENT + [json.dumps([WORKER, SLEEPER]), str(marker)], fixture.environment)
    fixture.register(manager.pid, "workspace-manager", root=str(directory / "late-root"), stateDir=str(state), generation="g1")
    output = fixture.suit("kill", str(manager.pid))
    assert f"{manager.pid} workspace-manager: killed" in output, output
    assert json.loads((state / "stop-request.json").read_text()) == {"version": 1, "generation": "g1"}
    late_worker, late_program = (int(pid) for pid in marker.read_text().split(","))
    try:
        wait_until(lambda: not pid_alive(late_worker), 10, "a worker started during the grace period survived")
        assert pid_alive(late_program), "suit killed a program that is not of a kind exosuit starts"
    finally:
        for pid in (late_worker, late_program):
            if pid_alive(pid):
                kill_pid(pid)


def test_ownership(fixture: Fixture, directory: Path) -> None:
    """Only processes exosuit started are its own; scanned strangers stay out of every bulk kill.

    The fake editor starts a worker itself (adopted), a worker with EXOSUIT_SUIT=off (never adopted), and a
    terminal shell that starts a worker (a build in the terminal: not adopted). Listing and --dry-run write
    nothing; the daemon persists the adoption and prunes a stale record.
    """
    directory.mkdir(parents=True, exist_ok=True)
    scanning = dict(fixture.environment, EXOSUIT_SUIT_SCAN="1")
    # Workers register with this fixture's suit, as a worker the editor starts would.
    worker_environment = dict(fixture.environment, EXOSUIT_SUIT_SCAN="0")
    stranger = fixture.spawn(WORKER, worker_environment)
    editor = fixture.spawn(SPAWNER + [json.dumps([
        WORKER, {"command": WORKER, "env": {"EXOSUIT_SUIT": "off"}}, SPAWNER + [json.dumps([WORKER])]])], worker_environment)
    fixture.register(editor.pid, "editor", roots=[])
    stale = fixture.spawn()
    stale.kill(); stale.wait()
    fixture.register(stale.pid, "workspace-host", root=str(directory / "stale-root"))
    wait_until(lambda: len(child_processes(editor.pid)) == 3, 30, "the editor did not start its children")
    children = child_processes(editor.pid)
    shell = next(pid for pid, name in children.items() if not name.lower().startswith("hl"))
    wait_until(lambda: bool(child_processes(shell)), 30, "the fake terminal did not start its build")
    in_terminal = next(iter(child_processes(shell)))
    workers = [pid for pid, name in children.items() if name.lower().startswith("hl")]
    started = [stranger.pid, in_terminal, *workers]
    try:
        wait_until(lambda: all(find(scanned_listing(scanning), pid) is not None for pid in started), 30,
                   "suit did not find the fake compiler workers")
        current = scanned_listing(scanning)
        adopted = [pid for pid in workers if find(current, pid)["source"] == "adopted"]
        assert len(adopted) == 1, [find(current, pid) for pid in workers]
        owned = adopted[0]
        switched_off = next(pid for pid in workers if pid != owned)
        for pid in (stranger.pid, in_terminal, switched_off):
            entry = find(current, pid)
            assert entry["kind"] == "compiler-worker" and entry["source"] == "scanned" and not entry["startedByExosuit"], entry
            assert entry["group"] == "Not started by exosuit" and entry["orphaned"] is False, entry
        entry = find(current, owned)
        assert entry["startedByExosuit"] and entry["group"] == "Haxeon", entry
        ours = {editor.pid, *started}
        everything = planned_kills(scanning, "--all")
        assert everything == {owned}, f"kill --all would stop {everything - {owned}} too"
        assert everything <= ours

        # Listing and planning wrote nothing: no adoption record, and the stale record is still there.
        before = registry_state(fixture.registry)
        assert set(before) == {f"{editor.pid}.json", f"{stale.pid}.json"}, before
        scanned_listing(scanning); fixture.suit("list"); planned_kills(scanning, "--orphans")
        assert registry_state(fixture.registry) == before, "suit list or --dry-run changed the registry"

        # The daemon persists the adoption and prunes the stale record.
        assert "started" in run_suit(scanning, "start")
        adoption = fixture.registry / f"{owned}.json"
        wait_until(lambda: adoption.is_file() and not (fixture.registry / f"{stale.pid}.json").exists(), 30,
                   "the daemon did not record the adoption or prune the stale record")
        assert json.loads(adoption.read_text())["adopted"] is True
        assert not any((fixture.registry / f"{pid}.json").exists() for pid in (stranger.pid, in_terminal, switched_off))

        # The editor exits; its worker stays exosuit's through the adoption record and is now orphaned.
        editor.kill(); editor.wait()
        wait_until(lambda: find(scanned_listing(scanning), owned) is not None
                   and find(scanned_listing(scanning), owned)["orphaned"], 30,
                   "the adopted worker was not orphaned when its editor exited")
        orphans = planned_kills(scanning, "--orphans")
        assert orphans == {owned}, f"bulk kill would touch processes this test did not mark orphaned: {orphans - {owned}}"
        assert stranger.pid not in planned_kills(scanning, "--all")

        # Killing a process by pid works whether or not exosuit started it.
        for pid in (owned, stranger.pid):
            output = run_suit(scanning, "kill", str(pid))
            assert f"{pid} compiler-worker: killed" in output, output
        wait_until(lambda: not alive(stranger) and not pid_alive(owned), 10, "an explicitly killed worker survived")
    finally:
        for pid in [*workers, shell, in_terminal]:
            if pid_alive(pid):
                kill_pid(pid)


def kill_pid(pid: int) -> None:
    """Kills one process this test started and whose Popen it does not hold."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True, timeout=30)
    else:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


def child_processes(pid: int) -> dict[int, str]:
    """The running children of `pid`, by pid, with their executable names."""
    if os.name == "nt":
        output = subprocess.run(["powershell", "-NoProfile", "-Command",
                                 f"Get-CimInstance Win32_Process -Filter 'ParentProcessId={pid}' | "
                                 "ForEach-Object { \"$($_.ProcessId) $($_.Name)\" }"],
                                capture_output=True, text=True, timeout=60).stdout
        pairs = [line.split(" ", 1) for line in output.splitlines() if line.strip()]
        return {int(child): name.strip() for child, name in pairs}
    output = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True, timeout=30).stdout
    children = {}
    for value in output.split():
        try:
            children[int(value)] = Path(f"/proc/{value}/comm").read_text().strip()
        except OSError:
            pass
    return children


def child_pids(pid: int) -> list[int]:
    return list(child_processes(pid))


def pid_alive(pid: int) -> bool:
    if os.name == "nt":
        output = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True, timeout=30).stdout
        return str(pid) in output
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def test_daemon(fixture: Fixture) -> None:
    assert "not running" in fixture.suit("status")
    assert "started" in fixture.suit("start", timeout=60)
    status = json.loads(fixture.suit("status", "--json"))
    assert status["ok"] is True and status["home"] == str(fixture.home), status
    editor = fixture.spawn()
    fixture.register(editor.pid, "editor", roots=[])
    service = fixture.spawn()
    fixture.register(service.pid, "workspace-host", root=str(Path(tempfile.gettempdir()) / "suit-test-root"))
    assert "running" in fixture.suit("list")
    quit_output = fixture.suit("quit")
    assert "Quitting Exosuit" in quit_output, quit_output
    wait_until(lambda: not alive(service), 15, "quit left a background process")
    # The fixture editor has no window to close, so suit leaves it running instead of killing it.
    assert alive(editor), "quit killed an editor that was not asked to close"
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after quit")
    assert "started" in fixture.suit("start")
    assert "stopped" in fixture.suit("stop")
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not stop")


def test_real_manager(fixture: Fixture, directory: Path) -> None:
    sys.path.insert(0, str(ROOT / "scripts"))
    from agent_test_runtime import manager_command, manager_environment, launcher_path
    workspace = directory / "real-workspace"; workspace.mkdir()
    state = directory / "real-state"
    environment = dict(manager_environment(ROOT, launcher_path(ROOT)), **{
        key: value for key, value in fixture.environment.items() if key.startswith("EXOSUIT_SUIT")})
    subprocess.run([*manager_command(ROOT), str(workspace), "--state-dir", str(state), "--detach", "--idle-seconds", "60"],
                   env=environment, check=True, timeout=100, capture_output=True)
    try:
        wait_until(lambda: {"workspace-manager", "workspace-host"} <= {entry["kind"] for entry in fixture.listing()["processes"]},
                   30, "real manager and daemon did not register")
        listing = fixture.listing()
        manager = next(entry for entry in listing["processes"] if entry["kind"] == "workspace-manager")
        host = next(entry for entry in listing["processes"] if entry["kind"] == "workspace-host")
        assert manager["orphaned"] is True and manager["stateDir"], manager
        output = fixture.suit("kill", str(manager["pid"]))
        assert f"{manager['pid']} workspace-manager: stopped" in output, f"manager was not stopped cooperatively: {output}"
        wait_until(lambda: not pid_alive(host["pid"]), 15, "workspace daemon survived its manager")
        assert not (state / "endpoint.json").exists(), "manager did not clean up its endpoint"
        assert fixture.listing()["processes"] == []
    finally:
        stop_manager_tree(state)


def stop_manager_tree(state: Path) -> None:
    """After a failure, kills the manager this test started (named in its state directory) with its daemon."""
    try:
        pid = json.loads((state / "endpoint.json").read_text())["managerPid"]
    except (OSError, ValueError, KeyError):
        return
    if not pid_alive(pid):
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True, timeout=30)
    else:
        for child in child_pids(pid):
            kill_pid(child)
        kill_pid(pid)


def test_suit_switch(fixture: Fixture, directory: Path) -> None:
    """EXOSUIT_SUIT=off, isolated without a home, and unset with state in the temp folder (a test run by hand,
    outside test.sh and the guard) keep a real manager out of the default registry and suit.

    The default home is moved into the test directory, and a last run with EXOSUIT_SUIT=on (autostart off)
    checks that the manager does register there, so the others cannot pass because nothing registers.
    """
    sys.path.insert(0, str(ROOT / "scripts"))
    from agent_test_runtime import manager_command, manager_environment, launcher_path
    directory.mkdir(parents=True, exist_ok=True)
    for index, mode in enumerate(("off", "isolated", "unset", "on")):
        workspace = directory / f"switch-workspace-{index}"; workspace.mkdir()
        state = directory / f"switch-state-{index}"
        # The default home moves into the test directory, so a registration there cannot reach the user's suit.
        default_parent = directory / f"default-{index}"
        environment = manager_environment(ROOT, launcher_path(ROOT))
        for key in [key for key in environment if key.startswith("EXOSUIT_SUIT")]:
            del environment[key]
        environment.update(LOCALAPPDATA=str(default_parent), XDG_STATE_HOME=str(default_parent),
                           EXOSUIT_SUIT_LAUNCHER=str(SUIT))
        if mode != "unset":
            environment["EXOSUIT_SUIT"] = mode
        assert Path(tempfile.gettempdir()) in state.parents, "the switch test's state must be disposable"
        if mode == "on":
            environment["EXOSUIT_SUIT_AUTOSTART"] = "0"
        subprocess.run([*manager_command(ROOT), str(workspace), "--state-dir", str(state), "--detach", "--idle-seconds", "60"],
                       env=environment, check=True, timeout=100, capture_output=True)
        wait_until(lambda: (state / "endpoint.json").is_file(), 30, f"EXOSUIT_SUIT={mode}: the manager did not start")
        endpoint = json.loads((state / "endpoint.json").read_text())
        try:
            time.sleep(1)  # registration and autostart happen as the manager becomes ready
            suit_home = default_parent / "exosuit" / "suit"
            if mode == "on":
                record = suit_home / "registry" / f"{endpoint['managerPid']}.json"
                # The daemon registers once it is ready, which can take a few seconds after endpoint.json.
                wait_until(record.is_file, 15, f"EXOSUIT_SUIT=on: the manager did not register in the moved default home {suit_home}")
                assert not (suit_home / "suit.lock").exists(), "EXOSUIT_SUIT_AUTOSTART=0 still started suit"
            else:
                assert not suit_home.exists(), f"EXOSUIT_SUIT={mode}: the manager registered or started suit in {suit_home}"
        finally:
            (state / "stop-request.json").write_text(json.dumps({"version": 1, "generation": endpoint["generation"]}))
            try:
                wait_until(lambda: not pid_alive(endpoint["managerPid"]), 20, "")
            except AssertionError:
                stop_manager_tree(state)
                raise AssertionError(f"EXOSUIT_SUIT={mode}: the manager ignored stop-request.json")


def test_editor(fixture: Fixture, directory: Path) -> None:
    """A real editor registers, starts suit, and closes when suit quits Exosuit."""
    directory.mkdir(parents=True, exist_ok=True)
    workspace = directory / "editor-workspace"; workspace.mkdir()
    graphical = ROOT / "graphical/build/host"
    native = sorted(path for path in (graphical / "native").iterdir() if path.is_dir())
    environment = dict(fixture.environment, PRAGTICAL_PORTABLE=str(directory / "settings"),
                       EXOSUIT_AGENT_STATE_HOME=str(directory / "agent-state"), XDG_STATE_HOME=str(directory / "state"),
                       EXOSUIT_AGENT_LAUNCHER=str(ROOT / "agent/build/host/main.hl"))
    environment.pop("EXOSUIT_SUIT_AUTOSTART")
    variable = "PATH" if os.name == "nt" else "LD_LIBRARY_PATH"
    environment[variable] = os.pathsep.join([str(path) for path in native] + [environment[variable]])
    log = (directory / "editor.log").open("w")
    editor = subprocess.Popen([str(HL), str(graphical / "main.hl"), "--title=suit-test-editor", str(workspace)], cwd=ROOT,
                              env=environment, stdout=log, stderr=subprocess.STDOUT)
    fixture.children.append(editor)
    wait_until(lambda: editor.poll() is not None or find(fixture.listing(), editor.pid) is not None, 60,
               "the editor did not register")
    assert editor.poll() is None, (directory / "editor.log").read_text()[-3000:]
    entry = find(fixture.listing(), editor.pid)
    assert entry["kind"] == "editor" and entry["registered"], entry
    wait_until(lambda: json.loads(fixture.suit("status", "--json")).get("ok") is True, 30, "the editor did not start suit")
    # The workspace service follows if the editor opens one for the folder; report rather than require it.
    try:
        wait_until(lambda: any(item["kind"] == "workspace-manager" for item in fixture.listing()["processes"]), 30, "")
        services = [item for item in fixture.listing()["processes"] if item["kind"] != "editor"]
        assert all(not item["orphaned"] for item in services), services
        print(f"  editor started {len(services)} registered service(s), none orphaned")
    except AssertionError as error:
        if str(error):
            raise
        print("  (the editor started no workspace service for the folder)")
    assert "Quitting Exosuit" in fixture.suit("quit")
    wait_until(lambda: editor.poll() is not None, 30, "the editor did not close when suit quit Exosuit")
    wait_until(lambda: fixture.listing()["processes"] == [], 30, "processes survived quit")
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "suit did not exit after quit")


def run_unit_tests() -> None:
    """suit's ownership rules over made-up processes (suit/tests)."""
    result = subprocess.run([sys.executable, str(ROOT / "scripts" / "haxeon_cli.py"), "run", "--project",
                             str(ROOT / "suit" / "tests" / "haxeon.json")], capture_output=True, text=True, timeout=600)
    assert result.returncode == 0 and "PASS: suit unit tests" in result.stdout, f"suit unit tests failed:\n{result.stdout}{result.stderr}"
    print("PASS unit tests")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--real-manager", action="store_true", help="also run a real workspace manager (needs agent build)")
    parser.add_argument("--editor", action="store_true", help="also run a real editor window (needs graphical build)")
    parser.add_argument("--only", help="run only the tests whose name contains this text")
    options = parser.parse_args()
    assert SUIT.is_file(), f"build suit first: {SUIT}"
    if not options.only or options.only in "unit tests":
        run_unit_tests()
    with tempfile.TemporaryDirectory(prefix="suit-test-") as temporary:
        directory = Path(temporary)
        tests = [("registry and termination", lambda f: test_registry_and_termination(f, directory / "a")),
                 ("shared workspace", lambda f: test_shared_workspace(f, directory / "s")),
                 ("quit spares terminals", test_quit_spares_terminals),
                 ("hosted workspace", lambda f: test_hosted_workspace(f, directory / "h")),
                 ("late child", lambda f: test_late_child(f, directory / "l")),
                 ("ownership", lambda f: test_ownership(f, directory / "o")), ("daemon", test_daemon)]
        if options.real_manager:
            tests.append(("real manager", lambda f: test_real_manager(f, directory / "r")))
            tests.append(("EXOSUIT_SUIT switch", lambda f: test_suit_switch(f, directory / "w")))
        if options.editor:
            tests.append(("editor", lambda f: test_editor(f, directory / "e")))
        for name, test in tests:
            if options.only and options.only not in name:
                continue
            (directory / "a").mkdir(exist_ok=True); (directory / "r").mkdir(exist_ok=True)
            fixture_directory = Path(tempfile.mkdtemp(dir=temporary))
            fixture = Fixture(fixture_directory)
            try:
                test(fixture)
                print(f"PASS {name}")
            finally:
                try:
                    subprocess.run([str(HL), str(SUIT), "stop"], env=fixture.environment, capture_output=True, timeout=30)
                except subprocess.TimeoutExpired:
                    pass
                fixture.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
