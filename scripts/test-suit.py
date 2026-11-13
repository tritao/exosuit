#!/usr/bin/env python3
"""suit end to end, isolated from the user's session.

Every suit call runs with EXOSUIT_SUIT=isolated and its own EXOSUIT_SUIT_HOME, so its own registry and
control endpoint. Most tests also set EXOSUIT_SUIT_SCAN=0, so suit sees only the processes this test
registers. The ownership test scans, so it lists the user's processes too, but it only reads that listing,
checks with --dry-run that bulk kills would touch none of them, and kills only its own processes by pid.

Covers: registration and pid-reuse checks (including old whole-second records), orphan detection, workspaces
shared by editors or kept by suit's relay hosting, positive ownership (adoption only of exosuit kinds exosuit
started itself, never through a terminal, never of EXOSUIT_SUIT=off; scanned processes kept out of bulk
kills), listing without side effects, stops that end a service's or an agent provider's whole tree (an agent's child
and grandchild are listed under it and end with it; a terminal host below a service, and what runs in it, survive
Quit; what starts during the grace period does not), terminal hosts (listed, never
orphaned, ended by the full Quit, `kill --all` and `terminals end`, kept by `quit --keep-terminals` with the
daemon staying up until the last one ends), relay listing and stop, the daemon's control
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


def test_quit_spares_shell_programs(fixture: Fixture) -> None:
    """Quit ends a service's whole tree, but never a terminal host it started nor what runs in that terminal.

    (Terminal hosts themselves are ended by the full Quit through their own end path: test_full_quit_ends_terminals.)

    A fake workspace daemon (registered) starts a compiler worker itself, and a terminal host that is not registered (so
    this quit does not choose it) running a shell. In the shell the user ran a build (another compiler worker) and a
    program of their own. Quit kills the daemon and its worker; the host, its shell, the build and the program live on.
    """
    scanning = dict(fixture.environment, EXOSUIT_SUIT_SCAN="1")
    shell = SPAWNER + [json.dumps([WORKER, SLEEPER])]
    # `python fake.hl --terminal-host DIR ...` reads as a terminal host (SuitClassifier.terminalDirectory).
    fake_host = Path(tempfile.mkdtemp(prefix="suit-fake-host-")) / "terminal-host.hl"
    fake_host.write_text("\n".join(["import json, os, subprocess, sys, time", _START.replace("sys.argv[1]", "sys.argv[3]"),
                                    "time.sleep(300)", ""]))
    host_command = [sys.executable, str(fake_host), "--terminal-host", str(fake_host.parent), json.dumps([shell])]
    # The host is started with suit off, so it is not this suit's: one its owned service starts would be adopted while it
    # starts (SuitInventory.startedByService) and ended by the quit, and this test is about what runs in a host it keeps.
    host = fixture.spawn(SPAWNER + [json.dumps([WORKER, {"command": host_command, "env": {"EXOSUIT_SUIT": "off"}}])], fixture.environment)
    fixture.register(host.pid, "workspace-host", root=str(Path(tempfile.gettempdir()) / "suit-test-quit"))
    wait_until(lambda: len(child_processes(host.pid)) == 2, 30, "the fake daemon did not start its children")
    worker, terminal_host = by_name(child_processes(host.pid))
    wait_until(lambda: len(child_processes(terminal_host)) == 1, 30, "the fake terminal host did not start its shell")
    (shell_pid,) = child_pids(terminal_host)
    wait_until(lambda: len(child_processes(shell_pid)) == 2, 30, "the fake shell did not start its children")
    build, program = by_name(child_processes(shell_pid))
    survivors = [terminal_host, shell_pid, build, program]
    try:
        listing = scanned_listing(scanning)
        assert find(listing, worker)["source"] == "adopted", find(listing, worker)
        # What runs below a terminal host is the user's, so suit does not list it at all (not even as scanned).
        assert find(listing, build) is None, "suit listed a worker started from a terminal"
        assert find(listing, shell_pid) is None and find(listing, program) is None, "suit listed a terminal's programs"
        planned = planned_kills(scanning, "--all")
        assert planned == {host.pid, worker}, f"kill --all would stop {planned}, not just this test's daemon and worker"
        assert "started" in run_suit(scanning, "start")
        assert "Quitting Exosuit" in run_suit(scanning, "quit")
        wait_until(lambda: not alive(host) and not pid_alive(worker), 15, "quit left the daemon or its worker running")
        time.sleep(1)
        for pid in survivors:
            assert pid_alive(pid), f"quit killed {pid}, which runs in or is a terminal host"
    finally:
        for pid in [worker, *survivors]:
            if pid_alive(pid):
                kill_pid(pid)


def test_provider_tree(fixture: Fixture, directory: Path) -> None:
    """An agent provider's children (an MCP server it started, and what that started) are not exosuit kinds: suit lists
    them under the provider and the full quit ends them with it."""
    provider = fixture.spawn(SPAWNER + [json.dumps([SPAWNER + [json.dumps([SLEEPER])]])], fixture.environment)
    fixture.register(provider.pid, "agent-provider", root=str(directory / "provider-root"))
    wait_until(lambda: len(child_pids(provider.pid)) == 1, 30, "the fake provider did not start its child")
    (child,) = child_pids(provider.pid)
    wait_until(lambda: len(child_pids(child)) == 1, 30, "the fake provider's child did not start the grandchild")
    (grandchild,) = child_pids(child)
    try:
        entry = find(fixture.listing(), provider.pid)
        assert entry["kind"] == "agent-provider" and entry["children"] == 2, entry
        assert "2 child processes" in fixture.suit("list"), fixture.suit("list")
        assert "started" in fixture.suit("start")
        assert "Quitting Exosuit" in fixture.suit("quit")
        wait_until(lambda: not alive(provider) and not pid_alive(child) and not pid_alive(grandchild), 20,
                   "the full quit left the provider's child or grandchild running")
    finally:
        for pid in (child, grandchild):
            if pid_alive(pid):
                kill_pid(pid)


# A stand-in terminal host: `python terminal-host.hl --terminal-host DIR [commands]` reads as a host
# (SuitClassifier.terminalDirectory). It starts each command of its JSON list (pids in DIR/children.txt) and ends when
# DIR/end-request.json appears, leaving DIR/ended-by-request, as a real host takes suit's end request.
_FAKE_HOST = "\n".join([
    "import json, os, subprocess, sys, time",
    "folder = sys.argv[2]",
    "commands = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []",
    "pids = [subprocess.Popen(c, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid for c in commands]",
    "open(os.path.join(folder, 'children.txt'), 'w').write(','.join(map(str, pids)))",
    "while not os.path.exists(os.path.join(folder, 'end-request.json')):",
    "    time.sleep(0.1)",
    "open(os.path.join(folder, 'ended-by-request'), 'w').write('1')",
    ""])


def fake_terminal_host(fixture: Fixture, folder: Path, commands: list | None = None,
                       environment: dict | None = None) -> subprocess.Popen:
    folder.mkdir(parents=True, exist_ok=True)
    script = folder.parent / "terminal-host.hl"
    if not script.exists():
        script.write_text(_FAKE_HOST)
    process = fixture.spawn([sys.executable, str(script), "--terminal-host", str(folder), json.dumps(commands or [])], environment)
    wait_until(lambda: (folder / "children.txt").exists(), 15, "the stand-in terminal host did not start")
    return process


def test_cli_ends_own_terminal_last(fixture: Fixture, directory: Path) -> None:
    """`suit kill --all` typed into an Exosuit terminal (no daemon) ends everything else first, prints it, and only then
    ends the terminal it runs in, which ends the command too."""
    service = fixture.spawn()
    fixture.register(service.pid, "workspace-host", root=str(directory / "alpha"))
    other = fake_terminal_host(fixture, directory / "hosts" / "other")
    fixture.register(other.pid, "terminal-host", root=str(directory / "alpha"), workspace="ws-alpha")
    output = directory / "cli-output.txt"
    # The terminal's program: waits for the host to be registered, then runs `suit kill --all` into a file.
    command = [sys.executable, "-c", "import subprocess, sys, time; time.sleep(2); o = open(sys.argv[1], 'w'); "
               "subprocess.run(sys.argv[2:], stdout=o, stderr=o); o.close()", str(output), str(HL), str(SUIT), "kill", "--all"]
    own = fake_terminal_host(fixture, directory / "hosts" / "own", [command], fixture.environment)
    fixture.register(own.pid, "terminal-host", root=str(directory / "alpha"), workspace="ws-alpha")
    wait_until(lambda: not alive(own), 30, "`suit kill --all` did not end the terminal it runs in")
    wait_until(lambda: output.exists() and "ending it now" in output.read_text(), 15, f"no closing line in the output")
    assert not alive(service) and not alive(other), "`suit kill --all` left a process running"
    lines = output.read_text().splitlines()
    last_others = max(i for i, line in enumerate(lines) if line.startswith((f"{service.pid} ", f"{other.pid} ")))
    announced = next(i for i, line in enumerate(lines) if "ending it now" in line)
    assert announced > last_others and lines[announced].startswith(f"{own.pid} "), f"the own terminal was not ended last: {lines}"


def terminal_host_stand_ins(fixture: Fixture, directory: Path):
    """Two registered stand-ins for terminal hosts in two workspaces, and an orphaned service stand-in."""
    root_a, root_b = directory / "alpha", directory / "beta"
    first = fake_terminal_host(fixture, directory / "hosts" / "first")
    second = fake_terminal_host(fixture, directory / "hosts" / "second")
    service = fixture.spawn()
    fixture.register(first.pid, "terminal-host", root=str(root_a), workspace="ws-alpha")
    fixture.register(second.pid, "terminal-host", root=str(root_b), workspace="ws-beta")
    fixture.register(service.pid, "workspace-host", root=str(root_a))
    return root_a, root_b, first, second, service


def test_terminal_hosts(fixture: Fixture, directory: Path) -> None:
    """Terminal hosts are listed in their own group, never orphaned, part of `kill --all`, and ended per workspace.

    Real hosts, their end request and their folders are covered by scripts/test-terminal-hosts.py.
    """
    root_a, root_b, first, second, service = terminal_host_stand_ins(fixture, directory)
    listing = fixture.listing()
    for host in (first, second):
        entry = find(listing, host.pid)
        assert entry["kind"] == "terminal-host" and not entry["orphaned"], entry
        assert entry["group"].startswith("Terminals"), entry
    assert listing["terminals"] == 2 and listing["background"] == 3, listing
    assert "2 terminals" in listing["summary"], listing["summary"]
    assert find(listing, service.pid)["orphaned"], "the service stand-in should be an orphan here"
    assert planned_kills(fixture.environment, "--all") == {service.pid, first.pid, second.pid}, "kill --all must end terminal hosts"
    assert planned_kills(fixture.environment, "--orphans") == {service.pid}, "kill --orphans would end a terminal host"

    def planned_ends(selection: str) -> set[int]:
        output = fixture.suit("terminals", "end", selection, "--dry-run")
        return {int(line.split()[0]) for line in output.splitlines() if line.endswith("would stop")}

    assert planned_ends("--all") == {first.pid, second.pid}
    assert planned_ends("ws-beta") == {second.pid} and planned_ends("alpha") == {first.pid} and planned_ends(str(root_b)) == {second.pid}
    menu = fixture.suit("menu")
    for expected in ("End all terminals (2)", "End terminals of alpha (1)", "End terminals of beta (1)",
                     "Quit Exosuit and end everything (2 terminals)", "Quit, keep terminals running (2)",
                     "Terminate all background processes (3)"):
        assert expected in menu, f"{expected!r} is missing from the menu:\n{menu}"
    assert str(first.pid) in fixture.suit("terminals") and "suit quit --keep-terminals" in fixture.suit("list")
    # One workspace's terminals, then all of them.
    assert str(second.pid) in fixture.suit("terminals", "end", "ws-beta")
    wait_until(lambda: not alive(second), 15, "`terminals end <workspace>` left its host running")
    assert alive(first), "`terminals end <workspace>` ended another workspace's terminal"
    assert str(first.pid) in fixture.suit("terminals", "end", "--all")
    wait_until(lambda: not alive(first), 15, "`terminals end --all` left a host running")
    assert fixture.listing()["terminals"] == 0


def test_full_quit_ends_terminals(fixture: Fixture, directory: Path) -> None:
    """`suit quit` (the full quit) ends terminal hosts with everything else, and the daemon exits when nothing is left."""
    _, _, first, second, service = terminal_host_stand_ins(fixture, directory)
    assert "started" in fixture.suit("start")
    said = fixture.suit("quit")
    assert "Quitting Exosuit: ending 3 process(es) (2 terminal(s) among them)" in said, said
    wait_until(lambda: not alive(service) and not alive(first) and not alive(second), 20, "the full quit left a process running")
    for name in ("first", "second"):
        assert (directory / "hosts" / name / "ended-by-request").exists(), f"the {name} host was killed, not ended through its end request"
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after the full quit")
    assert fixture.listing()["processes"] == []


def test_full_quit_waits_for_editor_in_terminal(fixture: Fixture, directory: Path) -> None:
    """An editor runs in an Exosuit terminal (`python scripts/run.py` started there). The full quit leaves that terminal's
    host running while the editor is open (it may be asking to save), and ends it once the editor has exited."""
    folder = directory / "hosts" / "with-editor"
    host = fake_terminal_host(fixture, folder, [SLEEPER])
    editor = int((folder / "children.txt").read_text())
    try:
        fixture.register(editor, "editor", roots=[str(directory / "run")])
        fixture.register(host.pid, "terminal-host", root=str(directory / "run"), workspace="ws-run")
        assert "started" in fixture.suit("start")
        fixture.suit("quit")
        time.sleep(4)
        assert alive(host) and not (folder / "ended-by-request").exists(), \
            "the full quit ended the terminal an editor runs in before the editor closed"
        kill_pid(editor)  # the editor closes (its stand-in has no window to ask)
        wait_until(lambda: not alive(host), 30, "the full quit did not end the terminal host once its editor had exited")
        assert (folder / "ended-by-request").exists(), "the host was killed, not ended through its end request"
        wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after the full quit")
    finally:
        if pid_alive(editor):
            kill_pid(editor)


def test_polite_quit_keeps_terminals(fixture: Fixture, directory: Path) -> None:
    """`suit quit --keep-terminals` ends everything but terminal hosts; the daemon stays up, listing them, until the last one ends."""
    _, _, first, second, service = terminal_host_stand_ins(fixture, directory)
    assert "started" in fixture.suit("start")
    said = fixture.suit("quit", "--keep-terminals")
    assert "2 terminals keep running" in said and "suit terminals end --all" in said, said
    wait_until(lambda: not alive(service), 15, "the polite quit left a background process")
    time.sleep(4)
    assert alive(first) and alive(second), "the polite quit ended a terminal host"
    status = json.loads(fixture.suit("status", "--json"))
    assert status.get("ok") is True and status["terminals"] == 2, f"the daemon must stay up listing the kept terminals: {status}"
    assert str(first.pid) in fixture.suit("terminals", "end", "--all")
    wait_until(lambda: not alive(first) and not alive(second), 15, "`terminals end --all` left a host running")
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after the last kept terminal ended")


def test_polite_quit_keeps_remote_access(fixture: Fixture, directory: Path) -> None:
    """With remote access on, the polite quit's kept terminals ending later does not take the daemon (and the phone's
    access) down with them: the quit is over and the daemon stays up as it would have without it."""
    if os.name != "nt":
        return
    directory.mkdir(parents=True, exist_ok=True)
    credentials = directory / "credentials"
    credentials.mkdir(exist_ok=True)
    fixture.environment.update(EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP="1", EXOSUIT_RELAY_TEST_CREDENTIALS_DIR=str(credentials))
    _, _, first, second, service = terminal_host_stand_ins(fixture, directory)
    assert "started" in fixture.suit("start")
    enabled = request_through_pipe(fixture, {"op": "remote-enable", "origin": "http://127.0.0.1:9"})
    assert enabled.get("enabled") is True, f"remote access was not set up: {enabled}"
    fixture.suit("quit", "--keep-terminals")
    wait_until(lambda: not alive(service), 15, "the polite quit left a background process")
    fixture.suit("terminals", "end", "--all")
    wait_until(lambda: not alive(first) and not alive(second), 15, "`terminals end --all` left a host running")
    time.sleep(12)  # longer than the daemon's 10 s rescan, which would find nothing owned left
    status = json.loads(fixture.suit("status", "--json"))
    assert status.get("ok") is True, f"the daemon exited after the polite quit although remote access is on: {status}"
    assert request_through_pipe(fixture, {"op": "remote-status"}).get("enabled") is True


def test_polite_quit_does_not_hunt_new_arrivals(fixture: Fixture, directory: Path) -> None:
    """After `suit quit --keep-terminals` with a terminal host kept, a manager started afterwards (the user starting
    Exosuit again, no editor registered yet) is left alone for longer than the quit's re-terminate rounds."""
    _, _, first, second, service = terminal_host_stand_ins(fixture, directory)
    assert "started" in fixture.suit("start")
    fixture.suit("quit", "--keep-terminals")
    wait_until(lambda: not alive(service), 15, "the polite quit left a background process")
    time.sleep(3)  # the quit's rounds are over
    manager = fixture.spawn()
    fixture.register(manager.pid, "workspace-manager", root=str(directory / "again"))
    time.sleep(12)  # longer than the daemon's 10 s rescan, which is when a lingering quit would find it
    assert alive(manager), "the daemon ended a workspace manager started after the polite quit"
    assert alive(first) and alive(second), "the polite quit ended a terminal host"


def attach_through_pipe(fixture: Fixture) -> dict:
    """A forged relay attach over the daemon's pipe (Windows); the reply, as a workspace service would read it."""
    return request_through_pipe(fixture, {"op": "relay-attach", "version": 1, "pid": os.getpid()})


def request_through_pipe(fixture: Fixture, request: dict) -> dict:
    """One control request over the daemon's pipe (Windows); the reply."""
    endpoint = json.loads((fixture.home / "daemon.json").read_text())["endpoint"]
    message = json.dumps(request).encode()
    with open(endpoint, "r+b", buffering=0) as pipe:
        pipe.write(b"HMPK\x01\x00" + len(message).to_bytes(4, "big") + message)
        header = pipe.read(10)
        return json.loads(pipe.read(int.from_bytes(header[6:10], "big")))


def test_full_quit_refuses_relay_attach(fixture: Fixture, directory: Path) -> None:
    """With an editor kept open the daemon stays up after the full quit, but refuses relay attaches and has machine remote
    access off until a new editor registers (the user started Exosuit again), which brings both back."""
    if os.name != "nt":
        return
    directory.mkdir(parents=True, exist_ok=True)
    credentials = directory / "credentials"
    credentials.mkdir(exist_ok=True)
    # Remote access set up with a relay nobody listens on (configured, never connected), with a file credential store.
    fixture.environment.update(EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP="1", EXOSUIT_RELAY_TEST_CREDENTIALS_DIR=str(credentials))
    editor = fixture.spawn()
    fixture.register(editor.pid, "editor", root=str(directory / "kept"))
    assert "started" in fixture.suit("start")
    enabled = request_through_pipe(fixture, {"op": "remote-enable", "origin": "http://127.0.0.1:9"})
    assert enabled.get("ok") is True and enabled.get("enabled") is True, f"remote access was not set up: {enabled}"
    fixture.suit("quit")
    time.sleep(3)
    assert alive(editor), "the full quit ended an editor that was not asked to close"
    reply = attach_through_pipe(fixture)
    assert reply.get("error") == "suit_quitting", f"the relay attach was not refused by the quit: {reply}"
    status = request_through_pipe(fixture, {"op": "remote-status"})
    assert status.get("enabled") is False, f"the full quit left remote access on: {status}"
    # A newly started editor cancels the quit; the attach then fails for its own reasons, not the quit's.
    other = fixture.spawn()
    fixture.register(other.pid, "editor", root=str(directory / "again"))
    fixture.suit("status")  # the status request rescans
    reply = attach_through_pipe(fixture)
    assert reply.get("error") != "suit_quitting", f"a new editor did not cancel the quit: {reply}"
    status = request_through_pipe(fixture, {"op": "remote-status"})
    assert status.get("enabled") is True, f"cancelling the quit did not bring remote access back: {status}"


# One stand-in per kind suit can be shown by registration alone (each a sleeper this test started).
EVERY_KIND = ["editor", "workspace-manager", "workspace-host", "compiler-worker", "live-session", "live-host",
              "terminal-host", "agent-provider", "language-server", "helper", "launcher", "other"]


def start_every_kind(fixture: Fixture, directory: Path) -> dict[str, subprocess.Popen]:
    started = {}
    for kind in EVERY_KIND:
        process = fixture.spawn()
        fixture.register(process.pid, kind, root=str(directory / "every"), workspace="ws-every",
                         **({"roots": [str(directory / "every")], "workspaces": ["ws-every"]} if kind == "editor" else {}))
        started[kind] = process
    listing = json.loads(fixture.suit("list", "--all", "--json"))
    for kind in EVERY_KIND:
        assert listing["all"]["kinds"][kind]["exosuit"] == 1, f"`suit list --all` does not count the {kind}: {listing['all']['kinds']}"
    assert listing["all"]["daemon"] is not None, "`suit list --all` does not show the daemon"
    assert "suit daemon" in fixture.suit("list", "--all")
    # Only this test's processes: the isolated suit sees nothing else.
    assert {entry["pid"] for entry in listing["processes"]} == {p.pid for p in started.values()}, listing["processes"]
    return started


def finish_with_editor(fixture: Fixture, editor: subprocess.Popen, expected: set[int]) -> None:
    """The editor stand-in has no window to close, so it stays (never killed); the daemon keeps listing it. Close it."""
    left = {entry["pid"] for entry in fixture.listing()["processes"]}
    assert left == expected | {editor.pid}, f"after the quit {left} is left, expected {expected | {editor.pid}}"
    assert "not running" not in fixture.suit("status"), "the daemon exited while something was left"
    editor.kill(); editor.wait()


def test_full_quit_ends_every_kind(fixture: Fixture, directory: Path) -> None:
    """One of each kind, `suit quit`: nothing exosuit-related is left, then the daemon exits."""
    assert "started" in fixture.suit("start")
    started = start_every_kind(fixture, directory)
    fixture.suit("quit")
    wait_until(lambda: all(not alive(p) for kind, p in started.items() if kind != "editor"), 20, "the full quit left a process running")
    finish_with_editor(fixture, started["editor"], set())
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after the full quit")
    assert fixture.listing()["processes"] == []


def test_polite_quit_leaves_only_terminals(fixture: Fixture, directory: Path) -> None:
    """One of each kind, `suit quit --keep-terminals`: only the terminal host and the daemon are left."""
    assert "started" in fixture.suit("start")
    started = start_every_kind(fixture, directory)
    fixture.suit("quit", "--keep-terminals")
    host = started["terminal-host"]
    wait_until(lambda: all(not alive(p) for kind, p in started.items() if kind not in ("editor", "terminal-host")), 20,
               "the polite quit left a process running")
    finish_with_editor(fixture, started["editor"], {host.pid})
    time.sleep(3)
    assert alive(host), "the polite quit ended the terminal host"
    assert {entry["pid"] for entry in fixture.listing()["processes"]} == {host.pid}
    assert "not running" not in fixture.suit("status"), "the daemon must stay up while a terminal host runs"
    fixture.suit("terminals", "end", "--all")
    wait_until(lambda: not alive(host), 15, "`terminals end --all` left the host running")
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after the last terminal ended")


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


def test_workspace_ids_with_several_editors(fixture: Fixture, directory: Path) -> None:
    """M19 Phase 8: a workspace's service (keyed by workspace id) stays up while any editor uses it, an editor
    exiting stops nothing, and Quit stops the services when asked and leaves editors that have no window to close."""
    one, two = fixture.spawn(), fixture.spawn()
    fixture.register(one.pid, "editor", roots=[], workspaces=["w1"])
    fixture.register(two.pid, "editor", roots=[], workspaces=["w1", "w2"])
    services = {}
    for workspace in ("w1", "w2"):
        service = fixture.spawn()
        fixture.register(service.pid, "workspace-manager", workspace=workspace, root=None)
        services[workspace] = service
    listing = fixture.listing()
    assert not any(find(listing, s.pid)["orphaned"] for s in services.values()), listing
    two.kill(); two.wait()
    listing = fixture.listing()
    assert find(listing, services["w1"].pid)["orphaned"] is False, "w1's service lost its editor while another editor uses w1"
    assert find(listing, services["w2"].pid)["orphaned"] is True, "w2's service is used by no running editor"
    planned = fixture.suit("kill", "--orphans", "--dry-run")
    assert f"{services['w2'].pid} workspace-manager: would stop" in planned and str(services["w1"].pid) not in planned, planned
    assert all(alive(s) for s in services.values()) and alive(one), "an editor exiting, or --dry-run, stopped something"
    one.kill(); one.wait()
    listing = fixture.listing()
    assert all(find(listing, s.pid)["orphaned"] for s in services.values()), listing
    assert all(alive(s) for s in services.values()), "services stop only when asked, not when the last editor exits"
    # Quit with several editors: the services stop, the editors (fixture processes without a window) are left alone.
    third, fourth = fixture.spawn(), fixture.spawn()
    fixture.register(third.pid, "editor", roots=[], workspaces=["w1"])
    fixture.register(fourth.pid, "editor", roots=[], workspaces=["w2"])
    assert "started" in fixture.suit("start", timeout=60)
    assert "Quitting Exosuit" in fixture.suit("quit")
    wait_until(lambda: not any(alive(s) for s in services.values()), 15, "quit left a workspace service running")
    assert alive(third) and alive(fourth), "quit killed an editor that was not asked to close"
    # The daemon exits only when nothing is left: it keeps listing the editors that stayed open.
    time.sleep(3)
    assert "not running" not in fixture.suit("status"), "the daemon exited while editors were still open"
    for editor in (third, fourth):
        editor.kill(); editor.wait()
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after the last editor closed")


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
    # A state that moved into a workspace (M19 Phase 4) is never hosted, whatever settings it still has.
    settings.write_text(json.dumps({"version": 1, "origin": "http://127.0.0.1:1"}))
    listing = fixture.listing()
    assert not any(find(listing, service.pid)["orphaned"] for service in (manager, host)), listing
    write_private(state / "workspace.json", json.dumps({"version": 2, "root": str(root), "migratedTo": "workspace-" + "0" * 32}))
    listing = fixture.listing()
    assert all(find(listing, service.pid)["orphaned"] for service in (manager, host)), listing


def test_late_child(fixture: Fixture, directory: Path) -> None:
    """What a service starts during the grace period dies: suit kills the target, then sweeps a fresh snapshot of its
    whole tree, so a worker and a program of another kind started then end with it."""
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
        wait_until(lambda: not pid_alive(late_program), 10, "a program the service started during the grace period survived")
    finally:
        for pid in (late_worker, late_program):
            if pid_alive(pid):
                kill_pid(pid)


def test_helper_markers(fixture: Fixture, directory: Path) -> None:
    """The Claude name bridge (node) and the profiler bridge (hl) carry `--exosuit-helper=...`: suit recognises them
    under their workspace service, the same program without the marker is not listed as one, and ending the service ends
    them all (its whole tree)."""
    directory.mkdir(parents=True, exist_ok=True)
    state = directory / "helper-state"; state.mkdir()
    marker = directory / "helper-children.pid"
    helpers = [SLEEPER + ["root", "--exosuit-helper=claude-name-bridge"], SLEEPER + ["--exosuit-helper=profiler-bridge"], SLEEPER]
    manager = fixture.spawn(LATE_PARENT + [json.dumps(helpers), str(marker)], fixture.environment)
    fixture.register(manager.pid, "workspace-manager", root=str(directory / "helper-root"), stateDir=str(state), generation="g1")
    wait_until(lambda: marker.exists() and marker.read_text().count(",") == 2, 20, "the fake service did not start its helpers")
    name_bridge, profiler_bridge, stranger = (int(pid) for pid in marker.read_text().split(","))
    try:
        listing = scanned_listing(dict(fixture.environment, EXOSUIT_SUIT_SCAN="1"))
        helper_pids = {entry["pid"] for entry in listing["processes"] if entry.get("kind") == "helper"}
        assert {name_bridge, profiler_bridge} <= helper_pids, f"suit did not list the bridges as helpers: {listing['processes']}"
        assert stranger not in helper_pids, "suit took a program without the marker for a helper"
        output = fixture.suit("kill", str(manager.pid))
        assert f"{manager.pid} workspace-manager: killed" in output, output
        wait_until(lambda: not pid_alive(name_bridge) and not pid_alive(profiler_bridge) and not pid_alive(stranger), 15,
                   "ending the service left a bridge or another child running")
    finally:
        for pid in (name_bridge, profiler_bridge, stranger):
            if pid_alive(pid):
                kill_pid(pid)


def start_run_py(fixture: Fixture, directory: Path) -> tuple[subprocess.Popen, int]:
    """A stand-in `python scripts/run.py --live` that runs a run session of this checkout's graphical/haxeon.json; returns
    the launcher and, once it started, the session's pid."""
    scripts = directory / "scripts"; scripts.mkdir(parents=True, exist_ok=True)
    (scripts / "run.py").write_text("\n".join(["import json, os, subprocess, sys, time", _START, "time.sleep(300)", ""]))
    session = [str(HL), str(SUIT), "watch", "--fake=haxeon-cli.hl", "run", "--project", str(ROOT / "graphical" / "haxeon.json"),
               "--watch", "--live"]
    launcher = fixture.spawn([sys.executable, str(scripts / "run.py"), json.dumps([session])], fixture.environment)
    wait_until(lambda: len(child_pids(launcher.pid)) == 1, 20, "the run.py stand-in did not start its session")
    (session_pid,) = child_pids(launcher.pid)
    return launcher, session_pid


def test_run_py_chain(fixture: Fixture, directory: Path, keep_terminals: bool) -> None:
    """`python scripts/run.py --live` and what it starts, as stand-ins: the launcher runs a run session of this checkout's
    graphical/haxeon.json; a live host of this checkout's graphical/build and a compiler worker on this checkout's hl.exe,
    started after the session, run with no exosuit parent (as through `cmd /C` and `cmd /c start`). No editor is
    registered: suit ties the chain by the checkout alone. A run session of another checkout, started by no run.py, stays
    not started by exosuit and out of every bulk stop; it runs on the same hl.exe, so while it runs the worker is shared
    with it. Once it is gone, the full quit, and the polite one, end the chain."""
    launcher, session_pid = start_run_py(fixture, directory)
    live_host = fixture.spawn([str(HL), str(SUIT), "watch", "--fake=live-host.hl", str(ROOT / "graphical/build/host/live.hl")],
                              fixture.environment)
    worker = fixture.spawn(WORKER, fixture.environment)
    stranger = fixture.spawn([str(HL), str(SUIT), "watch", "--fake=haxeon-cli.hl", "run", "--project",
                              str(directory / "other" / "graphical" / "haxeon.json"), "--live"], fixture.environment)
    scanning = dict(fixture.environment, EXOSUIT_SUIT_SCAN="1")
    try:
        listing = json.loads(run_suit(scanning, "list", "--all", "--json"))
        kinds = listing["all"]["kinds"]
        for kind in ("launcher", "live-session", "live-host", "compiler-worker"):
            assert kinds[kind]["exosuit"] == 1, f"`suit list --all` does not count the {kind} as exosuit's: {kinds}"
        sources = {entry["pid"]: entry for entry in listing["processes"]}
        # The scan sees the whole machine, so the not-started counts include the user's own processes: check the stranger.
        assert sources.get(stranger.pid, {}).get("source") == "scanned", f"the other checkout's session was taken: {sources.get(stranger.pid)}"
        ours = {launcher.pid, session_pid, live_host.pid, worker.pid}
        for pid in ours:
            assert pid in sources and sources[pid]["source"] != "scanned", f"{pid} is not exosuit's: {listing['processes']}"
        # The isolated suit sees nothing it was not shown: only this test's processes are exosuit's.
        assert {pid for pid, entry in sources.items() if entry["source"] != "scanned"} == ours, listing["processes"]
        assert sources[worker.pid]["shared"], f"a worker another checkout's session may use is not shared: {sources[worker.pid]}"
        planned = planned_kills(scanning, "--all")
        assert stranger.pid not in planned and worker.pid not in planned, f"kill --all would stop the stranger or the shared worker: {planned}"
        stranger.kill(); stranger.wait()
        assert worker.pid in planned_kills(scanning, "--all"), "the worker is still shared after the other session ended"
        run_suit(scanning, "quit", *(["--keep-terminals"] if keep_terminals else []))
        wait_until(lambda: not any(pid_alive(pid) for pid in ours), 20, "the quit left part of the run.py chain running")
    finally:
        for pid in (session_pid,):
            if pid_alive(pid):
                kill_pid(pid)


def test_terminal_build_shares_worker(fixture: Fixture, directory: Path) -> None:
    """A run.py session's compiler worker is exosuit's, but a build the user runs in a terminal on the same hl.exe (a
    stand-in shell running `hl haxeon-cli.hl build`) uses the same per-compiler workers: while it runs the worker is
    listed as shared with your builds, no bulk stop plans it, and the polite quit ends the session and leaves the worker
    and the build. Once the session is gone the worker is not exosuit's, so the orphan sweep leaves it too."""
    launcher, session_pid = start_run_py(fixture, directory)
    worker = fixture.spawn(WORKER, fixture.environment)
    scanning = dict(fixture.environment, EXOSUIT_SUIT_SCAN="1")
    build_command = [str(HL), str(SUIT), "watch", "--fake=haxeon-cli.hl", "build", "--project", str(directory / "mine" / "haxeon.json")]
    build = None
    try:
        entry = find(scanned_listing(scanning), worker.pid)
        assert entry is not None and entry["source"] == "adopted" and not entry["shared"], entry
        assert worker.pid in planned_kills(scanning, "--all"), "the session's own worker is not in kill --all"
        shell = fixture.spawn(SPAWNER + [json.dumps([build_command])], fixture.environment)
        wait_until(lambda: len(child_pids(shell.pid)) == 1, 20, "the terminal stand-in did not start its build")
        (build,) = child_pids(shell.pid)
        listing = scanned_listing(scanning)
        entry = find(listing, worker.pid)
        assert entry["shared"] and not entry["orphaned"] and entry["startedByExosuit"], entry
        assert find(listing, build) is None, "suit listed the terminal's build"
        assert "shared with your builds" in listing["summary"] and "shared with your builds" in run_suit(scanning, "list")
        for selection in ("--all", "--orphans"):
            assert worker.pid not in planned_kills(scanning, selection), f"kill {selection} would stop a worker a terminal build uses"
        run_suit(scanning, "quit", "--keep-terminals")
        wait_until(lambda: not pid_alive(session_pid) and not alive(launcher), 20, "the polite quit left the run.py chain running")
        time.sleep(1)
        assert alive(worker) and pid_alive(build), "the polite quit ended a worker a terminal build uses, or the build"
        # The build ends; the session that tied the worker to exosuit is gone, so no adoption lingers to orphan it.
        kill_pid(build)
        wait_until(lambda: not pid_alive(build), 10, "the build stand-in did not end")
        entry = find(scanned_listing(scanning), worker.pid)
        assert entry is not None and entry["source"] == "scanned" and not entry["orphaned"], entry
        assert worker.pid not in planned_kills(scanning, "--orphans"), "the orphan sweep would stop a worker exosuit no longer uses"
        assert not (fixture.registry / f"{worker.pid}.json").exists(), "suit persisted a checkout worker's adoption"
    finally:
        for pid in (session_pid, build):
            if pid is not None and pid_alive(pid):
                kill_pid(pid)


def test_terminal_program_not_adopted(fixture: Fixture, directory: Path) -> None:
    """A terminal whose program is itself of a kind exosuit starts (here a stand-in SDK-mode claude) runs the user's
    program: suit neither adopts nor lists it, so no bulk stop takes it; the host ends it when the terminal ends."""
    claude = SLEEPER + ["--permission-prompt-tool", "stdio", "--output-format", "stream-json"]
    host = fixture.spawn(SPAWNER + [json.dumps([claude])], fixture.environment)
    fixture.register(host.pid, "terminal-host", root=str(directory / "alpha"), workspace="ws-alpha")
    wait_until(lambda: len(child_pids(host.pid)) == 1, 20, "the terminal host stand-in did not start its program")
    (program,) = child_pids(host.pid)
    scanning = dict(fixture.environment, EXOSUIT_SUIT_SCAN="1")
    try:
        listing = scanned_listing(scanning)
        assert find(listing, host.pid)["kind"] == "terminal-host", listing["processes"]
        assert find(listing, program) is None, f"suit listed a terminal's program by its kind: {find(listing, program)}"
        assert planned_kills(scanning, "--all") == {host.pid}, "kill --all would stop a terminal's program directly"
    finally:
        if pid_alive(program):
            kill_pid(program)


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
    time.sleep(3)
    assert "not running" not in fixture.suit("status"), "the daemon exited while an editor was still open"
    editor.kill(); editor.wait()
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not exit after quit")
    assert "started" in fixture.suit("start")
    assert "stopped" in fixture.suit("stop")
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not stop")


def test_machine(fixture: Fixture, directory: Path) -> None:
    """The machine's workspaces through the daemon: first-start import, edits, workspaces without folders, scratch
    folders, and machine.json surviving a restart."""
    state = directory / "agent-state"; folder = directory / "imported"; other = directory / "second"
    for path in (folder, other):
        path.mkdir(parents=True)
    # A folder with a workspace service on its default state, as a new machine finds it.
    default_state = state / "workspaces" / ("0" * 20)
    default_state.mkdir(parents=True)
    (default_state / "workspace.json").write_text(json.dumps({"root": str(folder)}))
    fixture.environment["EXOSUIT_AGENT_STATE_HOME"] = str(state)
    # Scratch folders go under the test's folder, never the user's home; the daemon inherits this.
    scratch_home = directory / "scratch"
    fixture.environment["EXOSUIT_SCRATCH_HOME"] = str(scratch_home)
    assert "started" in fixture.suit("start")
    machine = json.loads(fixture.suit("machine", "--json"))
    assert machine["name"] and machine["id"].startswith("machine-"), machine
    # The fixture folder is under the temp folder, so the import leaves it out, as it does a test's.
    assert machine["workspaces"] == [], machine
    created = json.loads(fixture.suit("workspace", "new", str(other), "--name", "Second"))
    assert created["name"] == "Second" and len(created["folders"]) == 1, created
    added = json.loads(fixture.suit("workspace", "add-folder", created["id"], str(folder)))
    assert len(added["folders"]) == 2, added
    failed = subprocess.run([str(HL), str(SUIT), "workspace", "new", str(directory / "missing")], env=fixture.environment,
                            capture_output=True, text=True, timeout=60)
    assert failed.returncode != 0 and "Folder not found" in failed.stdout + failed.stderr, failed
    # A workspace by name only, then its scratch folder, made on first request under EXOSUIT_SCRATCH_HOME.
    notes = json.loads(fixture.suit("workspace", "new", "--name", "Notes?"))
    assert notes["name"] == "Notes?" and notes["folders"] == [] and notes["scratch"] is None, notes
    nameless = subprocess.run([str(HL), str(SUIT), "workspace", "new"], env=fixture.environment, capture_output=True,
                              text=True, timeout=60)
    assert nameless.returncode != 0, nameless
    (scratch_home / "Notes").mkdir(parents=True)
    scratch = fixture.suit("workspace", "scratch", notes["id"]).strip()
    assert Path(scratch) == scratch_home / "Notes 2" and Path(scratch).is_dir(), scratch
    replied = json.loads(fixture.suit("workspace", "scratch", notes["id"], "--json"))
    assert replied["scratch"] == scratch and replied["folders"] == [], replied
    # The last folder can be removed.
    fixture.suit("workspace", "remove-folder", created["id"], str(folder))
    emptied = json.loads(fixture.suit("workspace", "remove-folder", created["id"], str(other)))
    assert emptied["folders"] == [], emptied
    fixture.suit("machine", "rename", "cube-test")
    assert "stopped" in fixture.suit("stop")
    wait_until(lambda: "not running" in fixture.suit("status"), 30, "daemon did not stop")
    assert "started" in fixture.suit("start")
    machine = json.loads(fixture.suit("machine", "--json"))
    assert machine["name"] == "cube-test" and [w["name"] for w in machine["workspaces"]] == ["Second", "Notes?"], machine
    kept = {w["id"]: w for w in machine["workspaces"]}
    assert kept[notes["id"]]["scratch"] == scratch and kept[notes["id"]]["folders"] == [], machine
    assert kept[created["id"]]["folders"] == [] and kept[created["id"]]["scratch"] is None, machine
    assert json.loads((fixture.home / "machine.json").read_text())["version"] == 2
    fixture.suit("workspace", "delete", created["id"])
    fixture.suit("workspace", "delete", notes["id"])
    assert json.loads(fixture.suit("machine", "--json"))["workspaces"] == []
    assert Path(scratch).is_dir(), "deleting a workspace leaves its scratch folder alone"
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
                 ("quit spares a shell's programs", test_quit_spares_shell_programs),
                 ("provider tree", lambda f: test_provider_tree(f, directory / "pt")),
                 ("terminal hosts", lambda f: test_terminal_hosts(f, directory / "t")),
                 ("full quit ends terminals", lambda f: test_full_quit_ends_terminals(f, directory / "tq")),
                 ("full quit waits for an editor in a terminal", lambda f: test_full_quit_waits_for_editor_in_terminal(f, directory / "tw")),
                 ("polite quit keeps terminals", lambda f: test_polite_quit_keeps_terminals(f, directory / "tp")),
                 ("the CLI ends its own terminal last", lambda f: test_cli_ends_own_terminal_last(f, directory / "co")),
                 ("polite quit keeps remote access", lambda f: test_polite_quit_keeps_remote_access(f, directory / "pr")),
                 ("polite quit leaves new arrivals", lambda f: test_polite_quit_does_not_hunt_new_arrivals(f, directory / "pn")),
                 ("full quit refuses relay attach", lambda f: test_full_quit_refuses_relay_attach(f, directory / "fr")),
                 ("full quit ends every kind", lambda f: test_full_quit_ends_every_kind(f, directory / "ea")),
                 ("polite quit leaves only terminals", lambda f: test_polite_quit_leaves_only_terminals(f, directory / "ep")),
                 ("workspace ids with several editors", lambda f: test_workspace_ids_with_several_editors(f, directory / "i")),
                 ("hosted workspace", lambda f: test_hosted_workspace(f, directory / "h")),
                 ("late child", lambda f: test_late_child(f, directory / "l")),
                 ("helper markers", lambda f: test_helper_markers(f, directory / "h")),
                 ("full quit ends the run.py chain", lambda f: test_run_py_chain(f, directory / "rq", False)),
                 ("polite quit ends the run.py chain", lambda f: test_run_py_chain(f, directory / "rp", True)),
                 ("a terminal build shares the worker", lambda f: test_terminal_build_shares_worker(f, directory / "rb")),
                 ("a terminal's program is not adopted", lambda f: test_terminal_program_not_adopted(f, directory / "rt")),
                 ("ownership", lambda f: test_ownership(f, directory / "o")), ("daemon", test_daemon),
                 ("machine", lambda f: test_machine(f, directory / "m"))]
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
