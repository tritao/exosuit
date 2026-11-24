#!/usr/bin/env python3
"""exohost end to end, isolated from the user's session.

Every exohost call runs with its own EXOSUIT_EXOHOST_HOME, so its own registry and control endpoint. Most tests also set
EXOSUIT_EXOHOST_SCAN=0, so exohost sees only the processes this test registers. The ownership test scans, so it lists the
user's processes too, but it only reads that listing, checks with --dry-run that bulk kills would touch none of them,
and kills only its own processes by pid.

Editors are stand-ins that link to the daemon as a real editor does (FAKE_EDITOR: `editor-attach` over the pipe, the
pushed events read, `exosuit.quit` answered by exiting or left unanswered as by a window kept open over unsaved work).

Covers: registration and pid-reuse checks (including old whole-second records), orphan detection, workspaces
shared by editors, positive ownership (adoption only of exosuit kinds exosuit
started itself, never through a terminal, never of another exohost home; scanned processes kept out of bulk
kills), the editor link (attach, `exosuit.machine.changed` pushed on changes, quit over the link), services that report
themselves (`service-attach`), stops that end a service's or an agent provider's whole tree (an agent's child
and grandchild are listed under it and end with it; a terminal host below a service, and what runs in it, survive
Quit; what starts during the grace period does not), terminal hosts (listed, never
orphaned, ended by the full Quit, `kill --all` and `terminals end`, kept by `quit --keep-terminals` with the
daemon staying up until the last one ends), the daemon's control
endpoint (status, quit, stop), exohost's unit tests, with --real-service a real workspace service exohost starts on
`workspace.open` and stops cooperatively over its service link, and with --editor two real editor windows that exohost quits over
their links, each keeping its unsaved text for the next start.
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
from exohost import library_path, library_variable  # noqa: E402  (one library-path rule, shared with exohost.py)
from test_driver import HAXEON_ROOT as HAXEON, HL, agent_homes, kill_tree, process_runs, wait_until  # noqa: E402

EXOHOST = ROOT / "exohost" / "build" / "host" / "main.hl"
SLEEPER = [sys.executable, "-c", "import time; time.sleep(300)"]
# Starts each command in argv[1] (a JSON list) as its child, then sleeps. An item may be
# {"command": [...], "env": {...}} to change the child's environment. A terminal shell is one of these too.
_START = ("[subprocess.Popen(c['command'] if isinstance(c, dict) else c, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, "
          "stderr=subprocess.DEVNULL, env=dict(os.environ, **(c.get('env', {}) if isinstance(c, dict) else {}))).pid "
          "for c in json.loads(sys.argv[1])]")
SPAWNER = [sys.executable, "-c", f"import json, os, subprocess, sys, time; {_START}; time.sleep(300)"]
# Like SPAWNER, but starts them after 1.5 s, inside exohost's 3 s grace period for a workspace service, and writes
# their pids (comma separated) to argv[2].
LATE_PARENT = [sys.executable, "-c",
               f"import json, os, subprocess, sys, time; time.sleep(1.5); pids = {_START}; "
               "open(sys.argv[2], 'w').write(','.join(map(str, pids))); time.sleep(300)"]
# Like LATE_PARENT, but first reports itself as workspace argv[4]'s service to the daemon at argv[3] (`service-attach`)
# and ignores exohost's {op: "stop"}, so exohost waits out the grace period before it kills it.
LATE_SERVICE = [sys.executable, "-c", "\n".join([
    "import json, os, subprocess, sys, time",
    "pipe = open(sys.argv[3], 'r+b', buffering=0)",
    "data = json.dumps({'op': 'service-attach', 'workspace': sys.argv[4], 'endpoint': r'\\\\.\\pipe\\exosuit-test-late', 'pid': os.getpid()}).encode()",
    "pipe.write(b'HMPK\\x01\\x00' + len(data).to_bytes(4, 'big') + data)",
    "time.sleep(1.5)",
    f"pids = {_START}",
    "open(sys.argv[2], 'w').write(','.join(map(str, pids)))",
    "time.sleep(300)",
])]
# A fake Haxeon compiler worker: exohost's own read-only `watch`, whose command line looks like a worker's.
WORKER = [str(HL), str(EXOHOST), "watch", "--fake=/haxeon/compiler/exohost-test-worker.hl"]
# An editor stand-in: starts the commands in argv[5] (a JSON list, as SPAWNER), links to the daemon at argv[1] with the
# state in argv[2], writes argv[4] once linked and appends every event it is pushed to it as a JSON line. It answers
# `exosuit.quit` by exiting when argv[3] is "1", and leaves it unanswered otherwise (a window kept open).
FAKE_EDITOR = [sys.executable, "-c", "\n".join([
    "import json, os, subprocess, sys",
    f"{_START.replace('json.loads(sys.argv[1])', 'json.loads(sys.argv[5])')}",
    "pipe = open(sys.argv[1], 'r+b', buffering=0)",
    "def send(value):",
    "    data = json.dumps(value).encode()",
    "    pipe.write(b'HMPK\\x01\\x00' + len(data).to_bytes(4, 'big') + data)",
    "def read(count):",
    "    data = b''",
    "    while len(data) < count:",
    "        part = pipe.read(count - len(data))",
    "        if not part: sys.exit(0)",
    "        data += part",
    "    return data",
    "def receive():",
    "    return json.loads(read(int.from_bytes(read(10)[6:10], 'big')))",
    "send(dict(json.loads(sys.argv[2]), op='editor-attach', version=1, instance_id=f'w{os.getpid()}-1', pid=os.getpid()))",
    "assert receive().get('ok') is True",
    "log = open(sys.argv[4], 'a')",
    "log.write('linked\\n'); log.flush()",
    "while True:",
    "    message = receive()",
    "    if message.get('kind') == 'event':",
    "        log.write(json.dumps(message) + '\\n'); log.flush()",
    "    if message.get('kind') == 'request' and message.get('method') == 'exosuit.quit' and sys.argv[3] == '1':",
    "        send({'version': 1, 'kind': 'response', 'id': message['id'], 'result': {'closing': True}})",
    "        sys.exit(0)",
])]


def exohost_library_path() -> str:
    """exohost's library path, plus the agent's native packages for the real service and editor tests."""
    agent_native = ROOT / "agent/build/host/native"
    extra = sorted(str(path) for path in agent_native.iterdir() if path.is_dir()) if agent_native.is_dir() else []
    return os.pathsep.join([library_path(EXOHOST, HL, HAXEON), *extra, os.environ.get(library_variable(), "")])


class Fixture:
    def __init__(self, directory: Path) -> None:
        self.home = directory / "exohost-home"
        self.registry = self.home / "registry"
        # isolated: anything started with this environment registers here, never in the user's registry, and keeps its
        # state, Claude Code's and Codex's configuration included, under `directory`, never in the user's. No warm spare:
        # the tests count the processes exohost lists, and a linked editor would add one.
        self.environment = dict(os.environ, EXOSUIT_EXOHOST_HOME=str(self.home),
                                EXOSUIT_EXOHOST_SCAN="0", EXOSUIT_EXOHOST_TRAY="0", EXOSUIT_EXOHOST_AUTOSTART="0", EXOSUIT_EXOHOST_SPARE="0",
                                EXOSUIT_EXOHOST_IDLE_SECONDS="30", EXOSUIT_EXOHOST_LAUNCHER=str(EXOHOST),
                                EXOSUIT_AGENT_STATE_HOME=str(directory / "agent-state"), PRAGTICAL_PORTABLE=str(directory / "portable"),
                                **agent_homes(directory / "homes"))
        self.environment[library_variable()] = exohost_library_path()
        self.children: list[subprocess.Popen] = []
        self.editors = 0
        # exohost creates its home with an owner-only ACL; the test writes records into it afterwards.
        self.exohost("status")
        assert self.registry.is_dir()

    def exohost(self, *arguments: str, timeout: float = 60) -> str:
        result = subprocess.run([str(HL), str(EXOHOST), *arguments], env=self.environment, capture_output=True,
                                text=True, timeout=timeout)
        assert result.returncode == 0, f"exohost {' '.join(arguments)} failed ({result.returncode}): {result.stderr}{result.stdout}"
        return result.stdout

    def listing(self) -> dict:
        return json.loads(self.exohost("list", "--json"))

    def spawn(self, command: list[str] = SLEEPER, environment: dict | None = None) -> subprocess.Popen:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   env=environment)
        self.children.append(process)
        time.sleep(0.2)
        return process

    def running(self) -> bool:
        return json.loads(self.exohost("status", "--json")).get("ok") is True

    def endpoint(self) -> str:
        return json.loads((self.home / "daemon.json").read_text())["endpoint"]

    def editor(self, roots: list[str] | None = None, workspaces: list[str] | None = None, answers_quit: bool = True,
               commands: list | None = None, environment: dict | None = None) -> subprocess.Popen:
        """An editor stand-in linked to the daemon, which is started first (with `environment`) if it is not running."""
        command, log = self.editor_command(roots, workspaces, answers_quit, commands, environment)
        process = self.spawn(command, environment)
        wait_until(lambda: log.exists() or not alive(process), 15, "the editor stand-in did not link")
        assert alive(process), "the editor stand-in exited before it linked"
        return process

    def editor_command(self, roots: list[str] | None = None, workspaces: list[str] | None = None, answers_quit: bool = True,
                       commands: list | None = None, environment: dict | None = None) -> tuple[list[str], Path]:
        """The stand-in's command (to start it elsewhere, as below a terminal host) and the log it writes once linked."""
        if not self.running():
            assert "started" in run_exohost(environment or self.environment, "start")
        self.editors += 1
        log = self.home.parent / f"editor-{self.editors}.log"
        state = {"context": None, "workspaces": workspaces or [], "roots": roots or []}
        return [*FAKE_EDITOR, self.endpoint(), json.dumps(state), "1" if answers_quit else "0", str(log), json.dumps(commands or [])], log

    def register(self, pid: int, kind: str, registered_at: float | None = None, version: int = 2,
                 **details: object) -> None:
        record = {"version": version, "pid": pid, "kind": kind,
                  "registeredAt": registered_at if registered_at is not None else time.time() * 1000, **details}
        (self.registry / f"{pid}.json").write_text(json.dumps(record))

    def cleanup(self) -> None:
        for child in self.children:
            kill_tree(child)


def alive(process: subprocess.Popen) -> bool:
    return process.poll() is None


def find(listing: dict, pid: int) -> dict | None:
    return next((entry for entry in listing["processes"] if entry["pid"] == pid), None)


def test_registry_and_termination(fixture: Fixture, directory: Path) -> None:
    root_a, root_b, root_c = directory / "alpha", directory / "beta", directory / "gamma"
    for root in (root_a, root_b, root_c):
        root.mkdir()
    editor = fixture.editor(roots=[str(root_a), str(root_c)])
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
    # A service with a state directory, of a root the editor also has.
    state = directory / "gamma-state"; state.mkdir()
    hosted = fixture.spawn()
    fixture.register(hosted.pid, "workspace-host", root=str(root_c), stateDir=str(state))

    # A record from the second its process started, written by an exohost that kept whole seconds (version 1).
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
    # The daemon, which holds the editor's link, prunes stale records.
    assert not (fixture.registry / f"{reused.pid}.json").exists() and not (fixture.registry / f"{dead.pid}.json").exists(), \
        "the daemon kept stale records"
    for extra in (same_second, early):
        extra.kill(); extra.wait()
        (fixture.registry / f"{extra.pid}.json").unlink(missing_ok=True)
    assert "Exosuit: 1 editor, 4 background processes (1 orphaned)" == listing["summary"], listing["summary"]
    text = fixture.exohost("list")
    assert "Orphaned" in text and "workspace-host" in text, text

    # Only processes exohost knows about may be killed by pid.
    refused = subprocess.run([str(HL), str(EXOHOST), "kill", str(os.getpid())], env=fixture.environment,
                             capture_output=True, text=True, timeout=60)
    assert refused.returncode != 0 and "not an exosuit process" in refused.stderr, refused

    output = fixture.exohost("kill", "--orphans")
    assert f"{orphan.pid} workspace-host: killed" in output, output
    wait_until(lambda: not alive(orphan), 10, "orphan survived")
    assert alive(owned) and alive(editor) and alive(hosted), "kill --orphans touched owned processes"

    fixture.exohost("kill", "--all")
    wait_until(lambda: not alive(owned) and not alive(hosted), 10, "background process survived kill --all")
    assert alive(editor), "kill --all must keep editors"


def test_quit_spares_shell_programs(fixture: Fixture) -> None:
    """Quit ends a service's whole tree, but never a terminal host it started nor what runs in that terminal.

    (Terminal hosts themselves are ended by the full Quit through their own end path: test_full_quit_ends_terminals.)

    A fake workspace daemon (registered) starts a compiler worker itself, and a terminal host that is not registered (so
    this quit does not choose it) running a shell. In the shell the user ran a build (another compiler worker) and a
    program of their own. Quit kills the daemon and its worker; the host, its shell, the build and the program live on.
    """
    scanning = dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="1")
    shell = SPAWNER + [json.dumps([WORKER, SLEEPER])]
    # `python fake.hl --terminal-host DIR ...` reads as a terminal host (ExohostClassifier.terminalDirectory).
    fake_host = Path(tempfile.mkdtemp(prefix="exohost-fake-host-", dir=fixture.home.parent)) / "terminal-host.hl"
    fake_host.write_text("\n".join(["import json, os, subprocess, sys, time", _START.replace("sys.argv[1]", "sys.argv[3]"),
                                    "time.sleep(300)", ""]))
    host_command = [sys.executable, str(fake_host), "--terminal-host", str(fake_host.parent), json.dumps([shell])]
    # The host is started for another exohost home, so it is not this exohost's: one its owned service starts would be adopted
    # while it starts (ExohostInventory.startedByService) and ended by the quit, and this test is about what runs in a host it
    # keeps.
    elsewhere = str(Path(tempfile.gettempdir()) / "exohost-test-elsewhere")
    host = fixture.spawn(SPAWNER + [json.dumps([WORKER, {"command": host_command, "env": {"EXOSUIT_EXOHOST_HOME": elsewhere}}])], fixture.environment)
    fixture.register(host.pid, "workspace-host", root=str(Path(tempfile.gettempdir()) / "exohost-test-quit"))
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
        # What runs below a terminal host is the user's, so exohost does not list it at all (not even as scanned).
        assert find(listing, build) is None, "exohost listed a worker started from a terminal"
        assert find(listing, shell_pid) is None and find(listing, program) is None, "exohost listed a terminal's programs"
        planned = planned_kills(scanning, "--all")
        assert planned == {host.pid, worker}, f"kill --all would stop {planned}, not just this test's daemon and worker"
        assert "started" in run_exohost(scanning, "start")
        assert "Quitting Exosuit" in run_exohost(scanning, "quit")
        wait_until(lambda: not alive(host) and not process_runs(worker), 15, "quit left the daemon or its worker running")
        time.sleep(1)
        for pid in survivors:
            assert process_runs(pid), f"quit killed {pid}, which runs in or is a terminal host"
    finally:
        for pid in [worker, *survivors]:
            if process_runs(pid):
                kill_pid(pid)


def test_provider_tree(fixture: Fixture, directory: Path) -> None:
    """An agent provider's children (an MCP server it started, and what that started) are not exosuit kinds: exohost lists
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
        assert "2 child processes" in fixture.exohost("list"), fixture.exohost("list")
        assert "started" in fixture.exohost("start")
        assert "Quitting Exosuit" in fixture.exohost("quit")
        wait_until(lambda: not alive(provider) and not process_runs(child) and not process_runs(grandchild), 20,
                   "the full quit left the provider's child or grandchild running")
    finally:
        for pid in (child, grandchild):
            if process_runs(pid):
                kill_pid(pid)


# A stand-in terminal host: `python terminal-host.hl --terminal-host DIR [commands]` reads as a host
# (ExohostClassifier.terminalDirectory). It starts each command of its JSON list (pids in DIR/children.txt) and runs
# until exohost kills it, as exohost ends a real host.
_FAKE_HOST = "\n".join([
    "import json, os, subprocess, sys, time",
    "folder = sys.argv[2]",
    "commands = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []",
    "pids = [subprocess.Popen(c, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid for c in commands]",
    "open(os.path.join(folder, 'children.txt'), 'w').write(','.join(map(str, pids)))",
    "while True:",
    "    time.sleep(0.1)",
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
    """`exohost kill --all` typed into an Exosuit terminal (no daemon) ends everything else first, prints it, and only then
    ends the terminal it runs in, which ends the command too."""
    service = fixture.spawn()
    fixture.register(service.pid, "workspace-host", root=str(directory / "alpha"))
    other = fake_terminal_host(fixture, directory / "hosts" / "other")
    fixture.register(other.pid, "terminal-host", root=str(directory / "alpha"), workspace="ws-alpha")
    output = directory / "cli-output.txt"
    # The terminal's program: waits for the host to be registered, then runs `exohost kill --all` into a file.
    command = [sys.executable, "-c", "import subprocess, sys, time; time.sleep(2); o = open(sys.argv[1], 'w'); "
               "subprocess.run(sys.argv[2:], stdout=o, stderr=o); o.close()", str(output), str(HL), str(EXOHOST), "kill", "--all"]
    own = fake_terminal_host(fixture, directory / "hosts" / "own", [command], fixture.environment)
    fixture.register(own.pid, "terminal-host", root=str(directory / "alpha"), workspace="ws-alpha")
    wait_until(lambda: not alive(own), 30, "`exohost kill --all` did not end the terminal it runs in")
    wait_until(lambda: output.exists() and "ending it now" in output.read_text(), 15, f"no closing line in the output")
    assert not alive(service) and not alive(other), "`exohost kill --all` left a process running"
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

    Real hosts and their folders are covered by scripts/test-terminal-hosts.py.
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
        output = fixture.exohost("terminals", "end", selection, "--dry-run")
        return {int(line.split()[0]) for line in output.splitlines() if line.endswith("would stop")}

    assert planned_ends("--all") == {first.pid, second.pid}
    assert planned_ends("ws-beta") == {second.pid} and planned_ends("alpha") == {first.pid} and planned_ends(str(root_b)) == {second.pid}
    menu = fixture.exohost("menu")
    for expected in ("End all terminals (2)", "End terminals of alpha (1)", "End terminals of beta (1)",
                     "Quit Exosuit and end everything (2 terminals)", "Quit, keep terminals running (2)",
                     "Terminate all background processes (3)"):
        assert expected in menu, f"{expected!r} is missing from the menu:\n{menu}"
    assert str(first.pid) in fixture.exohost("terminals") and "exohost quit --keep-terminals" in fixture.exohost("list")
    # One workspace's terminals, then all of them.
    assert str(second.pid) in fixture.exohost("terminals", "end", "ws-beta")
    wait_until(lambda: not alive(second), 15, "`terminals end <workspace>` left its host running")
    assert alive(first), "`terminals end <workspace>` ended another workspace's terminal"
    assert str(first.pid) in fixture.exohost("terminals", "end", "--all")
    wait_until(lambda: not alive(first), 15, "`terminals end --all` left a host running")
    assert fixture.listing()["terminals"] == 0


def test_full_quit_ends_terminals(fixture: Fixture, directory: Path) -> None:
    """`exohost quit` (the full quit) ends terminal hosts with everything else, and the daemon exits when nothing is left."""
    _, _, first, second, service = terminal_host_stand_ins(fixture, directory)
    assert "started" in fixture.exohost("start")
    said = fixture.exohost("quit")
    assert "Quitting Exosuit: ending 3 process(es) (2 terminal(s) among them)" in said, said
    wait_until(lambda: not alive(service) and not alive(first) and not alive(second), 20, "the full quit left a process running")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not exit after the full quit")
    assert fixture.listing()["processes"] == []


def test_full_quit_waits_for_editor_in_terminal(fixture: Fixture, directory: Path) -> None:
    """An editor runs in an Exosuit terminal (`python scripts/run.py` started there). The full quit leaves that terminal's
    host running while the editor is open (it may be asking to save), and ends it once the editor has exited."""
    folder = directory / "hosts" / "with-editor"
    command, log = fixture.editor_command(roots=[str(directory / "run")], answers_quit=False)
    host = fake_terminal_host(fixture, folder, [command])
    editor = int((folder / "children.txt").read_text())
    try:
        wait_until(log.exists, 15, "the editor in the terminal did not link")
        fixture.register(host.pid, "terminal-host", root=str(directory / "run"), workspace="ws-run")
        fixture.exohost("quit")
        time.sleep(4)
        assert alive(host), "the full quit ended the terminal an editor runs in before the editor closed"
        kill_pid(editor)  # the editor closes (its stand-in left the quit unanswered, as a window kept open would)
        wait_until(lambda: not alive(host), 30, "the full quit did not end the terminal host once its editor had exited")
        wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not exit after the full quit")
    finally:
        if process_runs(editor):
            kill_pid(editor)


def test_polite_quit_keeps_terminals(fixture: Fixture, directory: Path) -> None:
    """`exohost quit --keep-terminals` ends everything but terminal hosts; the daemon stays up, listing them, until the last one ends."""
    _, _, first, second, service = terminal_host_stand_ins(fixture, directory)
    assert "started" in fixture.exohost("start")
    said = fixture.exohost("quit", "--keep-terminals")
    assert "2 terminals keep running" in said and "exohost terminals end --all" in said, said
    wait_until(lambda: not alive(service), 15, "the polite quit left a background process")
    time.sleep(4)
    assert alive(first) and alive(second), "the polite quit ended a terminal host"
    status = json.loads(fixture.exohost("status", "--json"))
    assert status.get("ok") is True and status["terminals"] == 2, f"the daemon must stay up listing the kept terminals: {status}"
    assert str(first.pid) in fixture.exohost("terminals", "end", "--all")
    wait_until(lambda: not alive(first) and not alive(second), 15, "`terminals end --all` left a host running")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not exit after the last kept terminal ended")


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
    assert "started" in fixture.exohost("start")
    enabled = request_through_pipe(fixture, {"op": "remote-enable", "origin": "http://127.0.0.1:9"})
    assert enabled.get("enabled") is True, f"remote access was not set up: {enabled}"
    fixture.exohost("quit", "--keep-terminals")
    wait_until(lambda: not alive(service), 15, "the polite quit left a background process")
    fixture.exohost("terminals", "end", "--all")
    wait_until(lambda: not alive(first) and not alive(second), 15, "`terminals end --all` left a host running")
    time.sleep(12)  # longer than the daemon's 10 s rescan, which would find nothing owned left
    status = json.loads(fixture.exohost("status", "--json"))
    assert status.get("ok") is True, f"the daemon exited after the polite quit although remote access is on: {status}"
    assert request_through_pipe(fixture, {"op": "remote-status"}).get("enabled") is True


def test_polite_quit_does_not_hunt_new_arrivals(fixture: Fixture, directory: Path) -> None:
    """After `exohost quit --keep-terminals` with a terminal host kept, a service started afterwards (the user starting
    Exosuit again, no editor registered yet) is left alone for longer than the quit's re-terminate rounds."""
    _, _, first, second, service = terminal_host_stand_ins(fixture, directory)
    assert "started" in fixture.exohost("start")
    fixture.exohost("quit", "--keep-terminals")
    wait_until(lambda: not alive(service), 15, "the polite quit left a background process")
    time.sleep(3)  # the quit's rounds are over
    service = fixture.spawn()
    fixture.register(service.pid, "workspace-host", root=str(directory / "again"))
    time.sleep(12)  # longer than the daemon's 10 s rescan, which is when a lingering quit would find it
    assert alive(service), "the daemon ended a workspace service started after the polite quit"
    assert alive(first) and alive(second), "the polite quit ended a terminal host"


def request_through_pipe(fixture: Fixture, request: dict) -> dict:
    """One control request over the daemon's pipe (Windows); the reply."""
    endpoint = json.loads((fixture.home / "daemon.json").read_text())["endpoint"]
    message = json.dumps(request).encode()
    with open(endpoint, "r+b", buffering=0) as pipe:
        pipe.write(b"HMPK\x01\x00" + len(message).to_bytes(4, "big") + message)
        header = pipe.read(10)
        return json.loads(pipe.read(int.from_bytes(header[6:10], "big")))


def test_full_quit_ends_remote_access(fixture: Fixture, directory: Path) -> None:
    """With an editor kept open the daemon stays up after the full quit, but has remote access off until a new editor
    links (the user started Exosuit again), which brings it back."""
    if os.name != "nt":
        return
    directory.mkdir(parents=True, exist_ok=True)
    credentials = directory / "credentials"
    credentials.mkdir(exist_ok=True)
    # Remote access set up with a relay nobody listens on (configured, never connected), with a file credential store.
    fixture.environment.update(EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP="1", EXOSUIT_RELAY_TEST_CREDENTIALS_DIR=str(credentials))
    editor = fixture.editor(roots=[str(directory / "kept")], answers_quit=False)
    enabled = request_through_pipe(fixture, {"op": "remote-enable", "origin": "http://127.0.0.1:9"})
    assert enabled.get("ok") is True and enabled.get("enabled") is True, f"remote access was not set up: {enabled}"
    fixture.exohost("quit")
    time.sleep(3)
    assert alive(editor), "the full quit ended an editor that was not asked to close"
    status = request_through_pipe(fixture, {"op": "remote-status"})
    assert status.get("enabled") is False, f"the full quit left remote access on: {status}"
    # A newly started editor cancels the quit.
    fixture.editor(roots=[str(directory / "again")])
    status = request_through_pipe(fixture, {"op": "remote-status"})
    assert status.get("enabled") is True, f"cancelling the quit did not bring remote access back: {status}"


# One stand-in per kind exohost can be shown by registration alone (each a sleeper this test started).
EVERY_KIND = ["editor", "workspace-host", "compiler-worker", "live-session", "live-host",
              "terminal-host", "agent-provider", "language-server", "helper", "launcher", "other"]


def start_every_kind(fixture: Fixture, directory: Path) -> dict[str, subprocess.Popen]:
    started = {}
    for kind in EVERY_KIND:
        if kind == "editor":
            started[kind] = fixture.editor(roots=[str(directory / "every")], workspaces=["ws-every"])
            continue
        process = fixture.spawn()
        fixture.register(process.pid, kind, root=str(directory / "every"), workspace="ws-every")
        started[kind] = process
    listing = json.loads(fixture.exohost("list", "--all", "--json"))
    for kind in EVERY_KIND:
        assert listing["all"]["kinds"][kind]["exosuit"] == 1, f"`exohost list --all` does not count the {kind}: {listing['all']['kinds']}"
    assert listing["all"]["daemon"] is not None, "`exohost list --all` does not show the daemon"
    assert "exohost daemon" in fixture.exohost("list", "--all")
    # Only this test's processes: the isolated exohost sees nothing else.
    assert {entry["pid"] for entry in listing["processes"]} == {p.pid for p in started.values()}, listing["processes"]
    return started


def test_full_quit_ends_every_kind(fixture: Fixture, directory: Path) -> None:
    """One of each kind, `exohost quit`: the editor quits when asked over its link, nothing exosuit-related is left, then
    the daemon exits."""
    assert "started" in fixture.exohost("start")
    started = start_every_kind(fixture, directory)
    fixture.exohost("quit")
    wait_until(lambda: all(not alive(p) for p in started.values()), 20, "the full quit left a process running")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not exit after the full quit")
    assert fixture.listing()["processes"] == []


def test_polite_quit_leaves_only_terminals(fixture: Fixture, directory: Path) -> None:
    """One of each kind, `exohost quit --keep-terminals`: only the terminal host and the daemon are left."""
    assert "started" in fixture.exohost("start")
    started = start_every_kind(fixture, directory)
    fixture.exohost("quit", "--keep-terminals")
    host = started["terminal-host"]
    wait_until(lambda: all(not alive(p) for kind, p in started.items() if kind != "terminal-host"), 20,
               "the polite quit left a process running")
    time.sleep(3)
    assert alive(host), "the polite quit ended the terminal host"
    assert {entry["pid"] for entry in fixture.listing()["processes"]} == {host.pid}
    assert "not running" not in fixture.exohost("status"), "the daemon must stay up while a terminal host runs"
    fixture.exohost("terminals", "end", "--all")
    wait_until(lambda: not alive(host), 15, "`terminals end --all` left the host running")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not exit after the last terminal ended")


def run_exohost(environment: dict, *arguments: str) -> str:
    result = subprocess.run([str(HL), str(EXOHOST), *arguments], env=environment, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, f"exohost {' '.join(arguments)} failed: {result.stderr}{result.stdout}"
    return result.stdout


def scanned_listing(environment: dict) -> dict:
    return json.loads(run_exohost(environment, "list", "--json"))


def planned_kills(environment: dict, selection: str) -> set[int]:
    output = run_exohost(environment, "kill", selection, "--dry-run")
    return {int(line.split()[0]) for line in output.splitlines() if line.endswith("would stop")}


def by_name(children: dict[int, str]) -> tuple[int, int]:
    """The hl child and the other one, of a fake process that started a worker and one python process."""
    hl = [pid for pid, name in children.items() if name.lower().startswith("hl")]
    other = [pid for pid, name in children.items() if not name.lower().startswith("hl")]
    assert len(hl) == 1 and len(other) == 1, children
    return hl[0], other[0]


def test_shared_workspace(fixture: Fixture, directory: Path) -> None:
    """A workspace's services belong to every editor that uses its root, not to the one that started them."""
    root = directory / "shared"; root.mkdir(parents=True)
    first, second = fixture.editor(roots=[str(root)]), fixture.editor(roots=[str(root)])
    host = fixture.spawn()
    fixture.register(host.pid, "workspace-host", root=str(root))
    first.kill(); first.wait()
    listing = fixture.listing()
    entry = find(listing, host.pid)
    assert entry["orphaned"] is False and entry["group"] == f"Editor {second.pid}: shared", entry
    assert "Nothing to terminate" in fixture.exohost("kill", "--orphans", "--dry-run")
    second.kill(); second.wait()
    listing = fixture.listing()
    assert find(listing, host.pid)["orphaned"], listing
    planned = fixture.exohost("kill", "--orphans", "--dry-run")
    assert f"{host.pid} workspace-host: would stop" in planned, planned
    assert alive(host), "--dry-run stopped something"


def test_workspace_ids_with_several_editors(fixture: Fixture, directory: Path) -> None:
    """M19 Phase 8: a workspace's service (keyed by workspace id) stays up while any editor uses it, an editor
    exiting stops nothing, and Quit stops the services when asked and leaves editors that stay open."""
    one, two = fixture.editor(workspaces=["w1"]), fixture.editor(workspaces=["w1", "w2"])
    services = {}
    for workspace in ("w1", "w2"):
        service = fixture.spawn()
        fixture.register(service.pid, "workspace-host", workspace=workspace, root=None)
        services[workspace] = service
    listing = fixture.listing()
    assert not any(find(listing, s.pid)["orphaned"] for s in services.values()), listing
    two.kill(); two.wait()
    listing = fixture.listing()
    assert find(listing, services["w1"].pid)["orphaned"] is False, "w1's service lost its editor while another editor uses w1"
    assert find(listing, services["w2"].pid)["orphaned"] is True, "w2's service is used by no running editor"
    planned = fixture.exohost("kill", "--orphans", "--dry-run")
    assert f"{services['w2'].pid} workspace-host: would stop" in planned and str(services["w1"].pid) not in planned, planned
    assert all(alive(s) for s in services.values()) and alive(one), "an editor exiting, or --dry-run, stopped something"
    one.kill(); one.wait()
    listing = fixture.listing()
    assert all(find(listing, s.pid)["orphaned"] for s in services.values()), listing
    assert all(alive(s) for s in services.values()), "services stop only when asked, not when the last editor exits"
    # Quit with several editors: the services stop, editors that stay open (the quit unanswered) are left alone.
    third, fourth = fixture.editor(workspaces=["w1"], answers_quit=False), fixture.editor(workspaces=["w2"], answers_quit=False)
    assert "Quitting Exosuit" in fixture.exohost("quit")
    wait_until(lambda: not any(alive(s) for s in services.values()), 15, "quit left a workspace service running")
    assert alive(third) and alive(fourth), "quit killed an editor that stayed open"
    # The daemon exits only when nothing is left: it keeps listing the editors that stayed open.
    time.sleep(3)
    assert "not running" not in fixture.exohost("status"), "the daemon exited while editors were still open"
    for editor in (third, fourth):
        editor.kill(); editor.wait()
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not exit after the last editor closed")


def test_late_child(fixture: Fixture, directory: Path) -> None:
    """What a service starts during the grace period dies: exohost kills the target, then sweeps a fresh snapshot of its
    whole tree, so a worker and a program of another kind started then end with it."""
    directory.mkdir(parents=True, exist_ok=True)
    state = directory / "late-state"; state.mkdir()
    marker = directory / "late-children.pid"
    # A fake workspace service, linked to the daemon, that ignores exohost's stop, so exohost waits out the grace period.
    assert "started" in fixture.exohost("start")
    service = fixture.spawn(LATE_SERVICE + [json.dumps([WORKER, SLEEPER]), str(marker), fixture.endpoint(), "late"], fixture.environment)
    fixture.register(service.pid, "workspace-host", root=str(directory / "late-root"), stateDir=str(state), generation="g1", workspace="late")
    time.sleep(0.3)  # linked by now, and its children start only after 1.5 s: inside the grace period
    output = fixture.exohost("kill", str(service.pid))
    assert f"{service.pid} workspace-host: killed" in output, output
    late_worker, late_program = (int(pid) for pid in marker.read_text().split(","))
    try:
        wait_until(lambda: not process_runs(late_worker), 10, "a worker started during the grace period survived")
        wait_until(lambda: not process_runs(late_program), 10, "a program the service started during the grace period survived")
    finally:
        for pid in (late_worker, late_program):
            if process_runs(pid):
                kill_pid(pid)


def test_helper_markers(fixture: Fixture, directory: Path) -> None:
    """The Claude name bridge (node) and the profiler bridge (hl) carry `--exosuit-helper=...`: exohost recognises them
    under their workspace service, the same program without the marker is not listed as one, and ending the service ends
    them all (its whole tree)."""
    directory.mkdir(parents=True, exist_ok=True)
    state = directory / "helper-state"; state.mkdir()
    marker = directory / "helper-children.pid"
    helpers = [SLEEPER + ["root", "--exosuit-helper=claude-name-bridge"], SLEEPER + ["--exosuit-helper=profiler-bridge"], SLEEPER]
    service = fixture.spawn(LATE_PARENT + [json.dumps(helpers), str(marker)], fixture.environment)
    fixture.register(service.pid, "workspace-host", root=str(directory / "helper-root"), stateDir=str(state), generation="g1")
    wait_until(lambda: marker.exists() and marker.read_text().count(",") == 2, 20, "the fake service did not start its helpers")
    name_bridge, profiler_bridge, stranger = (int(pid) for pid in marker.read_text().split(","))
    try:
        listing = scanned_listing(dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="1"))
        helper_pids = {entry["pid"] for entry in listing["processes"] if entry.get("kind") == "helper"}
        assert {name_bridge, profiler_bridge} <= helper_pids, f"exohost did not list the bridges as helpers: {listing['processes']}"
        assert stranger not in helper_pids, "exohost took a program without the marker for a helper"
        output = fixture.exohost("kill", str(service.pid))
        assert f"{service.pid} workspace-host: killed" in output, output
        wait_until(lambda: not process_runs(name_bridge) and not process_runs(profiler_bridge) and not process_runs(stranger), 15,
                   "ending the service left a bridge or another child running")
    finally:
        for pid in (name_bridge, profiler_bridge, stranger):
            if process_runs(pid):
                kill_pid(pid)


def start_run_py(fixture: Fixture, directory: Path) -> tuple[subprocess.Popen, int]:
    """A stand-in `python scripts/run.py --live` that runs a run session of this checkout's graphical/haxeon.json; returns
    the launcher and, once it started, the session's pid."""
    scripts = directory / "scripts"; scripts.mkdir(parents=True, exist_ok=True)
    (scripts / "run.py").write_text("\n".join(["import json, os, subprocess, sys, time", _START, "time.sleep(300)", ""]))
    session = [str(HL), str(EXOHOST), "watch", "--fake=haxeon-cli.hl", "run", "--project", str(ROOT / "graphical" / "haxeon.json"),
               "--watch", "--live"]
    launcher = fixture.spawn([sys.executable, str(scripts / "run.py"), json.dumps([session])], fixture.environment)
    wait_until(lambda: len(child_pids(launcher.pid)) == 1, 20, "the run.py stand-in did not start its session")
    (session_pid,) = child_pids(launcher.pid)
    return launcher, session_pid


def test_run_py_chain(fixture: Fixture, directory: Path, keep_terminals: bool) -> None:
    """`python scripts/run.py --live` and what it starts, as stand-ins: the launcher runs a run session of this checkout's
    graphical/haxeon.json; a live host of this checkout's graphical/build and a compiler worker on this checkout's hl.exe,
    started after the session, run with no exosuit parent (as through `cmd /C` and `cmd /c start`). No editor is
    registered: exohost ties the chain by the checkout alone. A run session of another checkout, started by no run.py, stays
    not started by exosuit and out of every bulk stop; it runs on the same hl.exe, so while it runs the worker is shared
    with it. Once it is gone, the full quit, and the polite one, end the chain."""
    launcher, session_pid = start_run_py(fixture, directory)
    live_host = fixture.spawn([str(HL), str(EXOHOST), "watch", "--fake=live-host.hl", str(ROOT / "graphical/build/host/live.hl")],
                              fixture.environment)
    worker = fixture.spawn(WORKER, fixture.environment)
    stranger = fixture.spawn([str(HL), str(EXOHOST), "watch", "--fake=haxeon-cli.hl", "run", "--project",
                              str(directory / "other" / "graphical" / "haxeon.json"), "--live"], fixture.environment)
    scanning = dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="1")
    try:
        listing = json.loads(run_exohost(scanning, "list", "--all", "--json"))
        kinds = listing["all"]["kinds"]
        for kind in ("launcher", "live-session", "live-host", "compiler-worker"):
            assert kinds[kind]["exosuit"] == 1, f"`exohost list --all` does not count the {kind} as exosuit's: {kinds}"
        sources = {entry["pid"]: entry for entry in listing["processes"]}
        # The scan sees the whole machine, so the not-started counts include the user's own processes: check the stranger.
        assert sources.get(stranger.pid, {}).get("source") == "scanned", f"the other checkout's session was taken: {sources.get(stranger.pid)}"
        ours = {launcher.pid, session_pid, live_host.pid, worker.pid}
        for pid in ours:
            assert pid in sources and sources[pid]["source"] != "scanned", f"{pid} is not exosuit's: {listing['processes']}"
        # The isolated exohost sees nothing it was not shown: only this test's processes are exosuit's.
        assert {pid for pid, entry in sources.items() if entry["source"] != "scanned"} == ours, listing["processes"]
        assert sources[worker.pid]["shared"], f"a worker another checkout's session may use is not shared: {sources[worker.pid]}"
        planned = planned_kills(scanning, "--all")
        assert stranger.pid not in planned and worker.pid not in planned, f"kill --all would stop the stranger or the shared worker: {planned}"
        stranger.kill(); stranger.wait()
        assert worker.pid in planned_kills(scanning, "--all"), "the worker is still shared after the other session ended"
        run_exohost(scanning, "quit", *(["--keep-terminals"] if keep_terminals else []))
        wait_until(lambda: not any(process_runs(pid) for pid in ours), 20, "the quit left part of the run.py chain running")
    finally:
        for pid in (session_pid,):
            if process_runs(pid):
                kill_pid(pid)


def test_live_host_worker_ends_with_quit(fixture: Fixture, directory: Path, keep_terminals: bool) -> None:
    """The run.py launcher and its run session are gone (crashed, or ended first) but the live host of this checkout's
    graphical/build still runs, with the resident compiler worker on this checkout's hl.exe. Both register with this
    exohost, so both are exosuit's and the quit, full or polite, ends them: no worker is left running the toolchain."""
    live_host = fixture.spawn([str(HL), str(EXOHOST), "watch", "--fake=live-host.hl", str(ROOT / "graphical/build/host/live.hl")],
                              fixture.environment)
    worker = fixture.spawn(WORKER, fixture.environment)
    scanning = dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="1")
    try:
        listing = scanned_listing(scanning)
        for process in (live_host, worker):
            entry = find(listing, process.pid)
            assert entry is not None and entry["source"] == "adopted", f"{process.pid} is not exosuit's with only a live host running: {entry}"
        assert worker.pid in planned_kills(scanning, "--all"), "kill --all does not plan the live host's worker"
        run_exohost(scanning, "quit", *(["--keep-terminals"] if keep_terminals else []))
        wait_until(lambda: not process_runs(live_host.pid) and not process_runs(worker.pid), 20,
                   "the quit left the live host's compiler worker running")
    finally:
        for process in (live_host, worker):
            if process_runs(process.pid):
                kill_pid(process.pid)


def test_terminal_build_shares_worker(fixture: Fixture, directory: Path) -> None:
    """A run.py session's compiler worker is exosuit's, but a build the user runs in a terminal on the same hl.exe (a
    stand-in shell running `hl haxeon-cli.hl build`) uses the same per-compiler workers: while it runs the worker is
    listed as shared with your builds, no bulk stop plans it, and the polite quit ends the session and leaves the worker
    and the build. Once the session is gone the worker is not exosuit's, so the orphan sweep leaves it too."""
    launcher, session_pid = start_run_py(fixture, directory)
    worker = fixture.spawn(WORKER, fixture.environment)
    scanning = dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="1")
    build_command = [str(HL), str(EXOHOST), "watch", "--fake=haxeon-cli.hl", "build", "--project", str(directory / "mine" / "haxeon.json")]
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
        assert find(listing, build) is None, "exohost listed the terminal's build"
        assert "shared with your builds" in listing["summary"] and "shared with your builds" in run_exohost(scanning, "list")
        for selection in ("--all", "--orphans"):
            assert worker.pid not in planned_kills(scanning, selection), f"kill {selection} would stop a worker a terminal build uses"
        run_exohost(scanning, "quit", "--keep-terminals")
        wait_until(lambda: not process_runs(session_pid) and not alive(launcher), 20, "the polite quit left the run.py chain running")
        time.sleep(1)
        assert alive(worker) and process_runs(build), "the polite quit ended a worker a terminal build uses, or the build"
        # The build ends; the session that tied the worker to exosuit is gone, so no adoption lingers to orphan it.
        kill_pid(build)
        wait_until(lambda: not process_runs(build), 10, "the build stand-in did not end")
        entry = find(scanned_listing(scanning), worker.pid)
        assert entry is not None and entry["source"] == "scanned" and not entry["orphaned"], entry
        assert worker.pid not in planned_kills(scanning, "--orphans"), "the orphan sweep would stop a worker exosuit no longer uses"
        assert not (fixture.registry / f"{worker.pid}.json").exists(), "exohost persisted a checkout worker's adoption"
    finally:
        for pid in (session_pid, build):
            if pid is not None and process_runs(pid):
                kill_pid(pid)


def test_terminal_program_not_adopted(fixture: Fixture, directory: Path) -> None:
    """A terminal whose program is itself of a kind exosuit starts (here a stand-in SDK-mode claude) runs the user's
    program: exohost neither adopts nor lists it, so no bulk stop takes it; the host ends it when the terminal ends."""
    claude = SLEEPER + ["--permission-prompt-tool", "stdio", "--output-format", "stream-json"]
    host = fixture.spawn(SPAWNER + [json.dumps([claude])], fixture.environment)
    fixture.register(host.pid, "terminal-host", root=str(directory / "alpha"), workspace="ws-alpha")
    wait_until(lambda: len(child_pids(host.pid)) == 1, 20, "the terminal host stand-in did not start its program")
    (program,) = child_pids(host.pid)
    scanning = dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="1")
    try:
        listing = scanned_listing(scanning)
        assert find(listing, host.pid)["kind"] == "terminal-host", listing["processes"]
        assert find(listing, program) is None, f"exohost listed a terminal's program by its kind: {find(listing, program)}"
        assert planned_kills(scanning, "--all") == {host.pid}, "kill --all would stop a terminal's program directly"
    finally:
        if process_runs(program):
            kill_pid(program)


def test_ownership(fixture: Fixture, directory: Path) -> None:
    """Only processes exosuit started are its own; scanned strangers stay out of every bulk kill.

    The fake editor starts a worker itself (adopted), a worker of another exohost home (never adopted), and a terminal
    shell that starts a worker (a build in the terminal: not adopted). The daemon persists the adoption and prunes a
    stale record.
    """
    directory.mkdir(parents=True, exist_ok=True)
    scanning = dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="1")
    # Workers register with this fixture's exohost, as a worker the editor starts would.
    worker_environment = dict(fixture.environment, EXOSUIT_EXOHOST_SCAN="0")
    stranger = fixture.spawn(WORKER, worker_environment)
    stale = fixture.spawn()
    stale.kill(); stale.wait()
    fixture.register(stale.pid, "workspace-host", root=str(directory / "stale-root"))
    # The daemon scans, so it adopts and prunes.
    editor = fixture.editor(commands=[WORKER, {"command": WORKER, "env": {"EXOSUIT_EXOHOST_HOME": str(directory / "elsewhere")}},
                                      SPAWNER + [json.dumps([WORKER])]], environment=scanning)
    wait_until(lambda: len(child_processes(editor.pid)) == 3, 30, "the editor did not start its children")
    children = child_processes(editor.pid)
    shell = next(pid for pid, name in children.items() if not name.lower().startswith("hl"))
    wait_until(lambda: bool(child_processes(shell)), 30, "the fake terminal did not start its build")
    in_terminal = next(iter(child_processes(shell)))
    workers = [pid for pid, name in children.items() if name.lower().startswith("hl")]
    started = [stranger.pid, in_terminal, *workers]
    try:
        wait_until(lambda: all(find(scanned_listing(scanning), pid) is not None for pid in started), 30,
                   "exohost did not find the fake compiler workers")
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

        # The daemon persists the adoption and prunes the stale record.
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
            output = run_exohost(scanning, "kill", str(pid))
            assert f"{pid} compiler-worker: killed" in output, output
        wait_until(lambda: not alive(stranger) and not process_runs(owned), 10, "an explicitly killed worker survived")
    finally:
        for pid in [*workers, shell, in_terminal]:
            if process_runs(pid):
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




def test_daemon(fixture: Fixture) -> None:
    assert "not running" in fixture.exohost("status")
    assert "started" in fixture.exohost("start", timeout=60)
    status = json.loads(fixture.exohost("status", "--json"))
    assert status["ok"] is True and status["home"] == str(fixture.home), status
    editor = fixture.editor(answers_quit=False)
    service = fixture.spawn()
    fixture.register(service.pid, "workspace-host", root=str(Path(tempfile.gettempdir()) / "exohost-test-root"))
    assert "running" in fixture.exohost("list")
    quit_output = fixture.exohost("quit")
    assert "Quitting Exosuit" in quit_output, quit_output
    wait_until(lambda: not alive(service), 15, "quit left a background process")
    # The editor stand-in stays open (it leaves the quit unanswered), so exohost leaves it running instead of killing it.
    assert alive(editor), "quit killed an editor that stayed open"
    time.sleep(3)
    assert "not running" not in fixture.exohost("status"), "the daemon exited while an editor was still open"
    editor.kill(); editor.wait()
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not exit after quit")
    assert "started" in fixture.exohost("start")
    assert "stopped" in fixture.exohost("stop")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not stop")


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
    assert "started" in fixture.exohost("start")
    machine = json.loads(fixture.exohost("machine", "--json"))
    assert machine["name"] and machine["id"].startswith("machine-"), machine
    # The fixture folder is under the temp folder, so the import leaves it out, as it does a test's.
    assert machine["workspaces"] == [], machine
    created = json.loads(fixture.exohost("workspace", "new", str(other), "--name", "Second"))
    assert created["name"] == "Second" and len(created["folders"]) == 1, created
    added = json.loads(fixture.exohost("workspace", "add-folder", created["id"], str(folder)))
    assert len(added["folders"]) == 2, added
    failed = subprocess.run([str(HL), str(EXOHOST), "workspace", "new", str(directory / "missing")], env=fixture.environment,
                            capture_output=True, text=True, timeout=60)
    assert failed.returncode != 0 and "Folder not found" in failed.stdout + failed.stderr, failed
    # A workspace by name only, then its scratch folder, made on first request under EXOSUIT_SCRATCH_HOME.
    notes = json.loads(fixture.exohost("workspace", "new", "--name", "Notes?"))
    assert notes["name"] == "Notes?" and notes["folders"] == [] and notes["scratch"] is None, notes
    nameless = subprocess.run([str(HL), str(EXOHOST), "workspace", "new"], env=fixture.environment, capture_output=True,
                              text=True, timeout=60)
    assert nameless.returncode != 0, nameless
    (scratch_home / "Notes").mkdir(parents=True)
    scratch = fixture.exohost("workspace", "scratch", notes["id"]).strip()
    assert Path(scratch) == scratch_home / "Notes 2" and Path(scratch).is_dir(), scratch
    replied = json.loads(fixture.exohost("workspace", "scratch", notes["id"], "--json"))
    assert replied["scratch"] == scratch and replied["folders"] == [], replied
    # The last folder can be removed.
    fixture.exohost("workspace", "remove-folder", created["id"], str(folder))
    emptied = json.loads(fixture.exohost("workspace", "remove-folder", created["id"], str(other)))
    assert emptied["folders"] == [], emptied
    fixture.exohost("machine", "rename", "cube-test")
    assert "stopped" in fixture.exohost("stop")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not stop")
    assert "started" in fixture.exohost("start")
    machine = json.loads(fixture.exohost("machine", "--json"))
    assert machine["name"] == "cube-test" and [w["name"] for w in machine["workspaces"]] == ["Second", "Notes?"], machine
    kept = {w["id"]: w for w in machine["workspaces"]}
    assert kept[notes["id"]]["scratch"] == scratch and kept[notes["id"]]["folders"] == [], machine
    assert kept[created["id"]]["folders"] == [] and kept[created["id"]]["scratch"] is None, machine
    assert json.loads((fixture.home / "machine.json").read_text())["version"] == 2
    fixture.exohost("workspace", "delete", created["id"])
    fixture.exohost("workspace", "delete", notes["id"])
    assert json.loads(fixture.exohost("machine", "--json"))["workspaces"] == []
    assert Path(scratch).is_dir(), "deleting a workspace leaves its scratch folder alone"
    assert "stopped" in fixture.exohost("stop")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "daemon did not stop")


def test_real_service(fixture: Fixture, directory: Path) -> None:
    """A real workspace service: exohost starts it on `workspace.open`, lists it as the workspace's one process, answers a
    second open with the same pipe, and `exohost kill` stops it cooperatively over its service link."""
    sys.path.insert(0, str(ROOT / "scripts"))
    from test_driver import launcher_path
    folder = directory / "real-workspace"; folder.mkdir(parents=True)
    state = directory / "agent-state"
    fixture.environment.update(EXOSUIT_AGENT_STATE_HOME=str(state), EXOSUIT_AGENT_LAUNCHER=str(launcher_path(ROOT)))
    assert "started" in fixture.exohost("start")
    created = json.loads(fixture.exohost("workspace", "new", str(folder), "--name", "Real"))
    pid = None
    try:
        opened = request_through_pipe(fixture, {"op": "workspace.open", "workspace": created["id"]})
        assert opened.get("ok") is True and opened.get("endpoint") and opened.get("generation"), opened
        again = request_through_pipe(fixture, {"op": "workspace.open", "workspace": created["id"]})
        assert again.get("endpoint") == opened["endpoint"] and again.get("generation") == opened["generation"], again
        services = [entry for entry in fixture.listing()["processes"] if entry["kind"] == "workspace-host"]
        assert len(services) == 1 and Path(services[0]["stateDir"]).name == created["id"], f"not one service of {created['id']}: {services}"
        pid = services[0]["pid"]
        output = fixture.exohost("kill", str(pid))
        assert f"{pid} workspace-host: stopped" in output, f"the service was not stopped cooperatively: {output}"
        wait_until(lambda: not process_runs(pid), 15, "the workspace service survived its stop")
        log = (state / "workspaces" / created["id"] / "service.log").read_text()
        assert "service stopped: exohost asked it to stop" in log, log[-2000:]
        assert fixture.listing()["processes"] == []
    finally:
        # Whatever service started, even before the listing named it (its service.log names each start's pid).
        for log in state.glob("workspaces/*/service.log"):
            for line in log.read_text(errors="replace").splitlines():
                if "service starting: generation " in line and process_runs(int(line.rsplit(", pid ", 1)[1])):
                    kill_pid(int(line.rsplit(", pid ", 1)[1]))
        fixture.exohost("stop")


# A workspace service stand-in: reports itself to the daemon at argv[1] for workspace argv[2] (`service-attach`) and stays.
FAKE_SERVICE = [sys.executable, "-c", "\n".join([
    "import json, os, sys, time",
    "pipe = open(sys.argv[1], 'r+b', buffering=0)",
    "data = json.dumps({'op': 'service-attach', 'workspace': sys.argv[2], 'endpoint': r'\\\\.\\pipe\\exosuit-test-service', 'pid': os.getpid()}).encode()",
    "pipe.write(b'HMPK\\x01\\x00' + len(data).to_bytes(4, 'big') + data)",
    "time.sleep(300)",
])]


def test_links(fixture: Fixture, directory: Path) -> None:
    """exohost pushes `exosuit.machine.changed` to a linked editor when a workspace is created and when a service reports
    itself or goes; `machine` lists a service from its report alone, and drops it when its connection closes."""
    directory.mkdir(parents=True, exist_ok=True)
    folder = directory / "linked"; folder.mkdir()
    command, log = fixture.editor_command()
    fixture.spawn(command)
    wait_until(log.exists, 15, "the editor stand-in did not link")
    assert json.loads(fixture.exohost("status", "--json"))["editors"] == 1

    def pushed(condition) -> bool:
        events = [json.loads(line) for line in log.read_text().splitlines()[1:]]
        return any(event.get("event") == "exosuit.machine.changed" and condition(event["data"]["machine"]) for event in events)

    created = json.loads(fixture.exohost("workspace", "new", str(folder)))
    assert created["name"] == "linked" and created["folders"] == [str(folder)], created
    wait_until(lambda: pushed(lambda machine: any(w["id"] == created["id"] for w in machine["workspaces"])), 10,
               "the editor was not pushed the new workspace")

    def service() -> dict | None:
        machine = json.loads(fixture.exohost("machine", "--json"))
        return next(w for w in machine["workspaces"] if w["id"] == created["id"]).get("service")

    reporter = fixture.spawn([*FAKE_SERVICE, fixture.endpoint(), created["id"]])
    wait_until(lambda: (service() or {}).get("pid") == reporter.pid, 10, "a service that reported itself is not listed")
    assert service()["running"] is True and service()["endpoint"] == r"\\.\pipe\exosuit-test-service", service()
    wait_until(lambda: pushed(lambda machine: any(w.get("service") for w in machine["workspaces"])), 10,
               "the editor was not pushed the service")
    reporter.kill(); reporter.wait()
    wait_until(lambda: service() is None, 10, "a service whose connection closed is still listed")


def test_editor(fixture: Fixture, directory: Path) -> None:
    """Two real editor windows link to exohost, which the first starts. The first opens a loose folder, which becomes a
    workspace named after it. Each types into an open file (window-local scripted input, never OS input). `exohost quit`
    asks each window over its link; each closes at once, keeping its unsaved text in its recovery store for the next start
    (the tray's Quit), and exohost exits once nothing is left."""
    directory.mkdir(parents=True, exist_ok=True)
    folder = directory / "loose-folder"; folder.mkdir()
    graphical = ROOT / "graphical/build/host"
    native = sorted(path for path in (graphical / "native").iterdir() if path.is_dir())
    environment = dict(fixture.environment, EXOSUIT_AGENT_STATE_HOME=str(directory / "agent-state"), XDG_STATE_HOME=str(directory / "state"),
                       EXOSUIT_AGENT_LAUNCHER=str(ROOT / "agent/build/host/main.hl"))
    environment.pop("EXOSUIT_EXOHOST_AUTOSTART")
    variable = "PATH" if os.name == "nt" else "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    environment[variable] = os.pathsep.join([str(path) for path in native] + [environment[variable]])
    editors = []
    for index in (1, 2):
        note = directory / f"note-{index}.txt"
        note.write_text("saved\n")
        script = directory / f"input-{index}.json"
        script.write_text(json.dumps({"version": 1, "events": [{"at": 3.0, "kind": "text", "text": f"unsaved-{index} "}]}))
        paths = [str(folder), str(note)] if index == 1 else [str(note)]
        settings = directory / f"settings-{index}"
        log = (directory / f"editor-{index}.log").open("w")
        editor = subprocess.Popen([str(HL), str(graphical / "main.hl"), f"--title=exohost-test-editor-{index}", f"--input-script={script}", *paths],
                                  cwd=ROOT, env=dict(environment, PRAGTICAL_PORTABLE=str(settings)), stdout=log, stderr=subprocess.STDOUT)
        fixture.children.append(editor)
        editors.append((editor, settings, f"unsaved-{index}", directory / f"editor-{index}.log"))
    for editor, _, _, log_path in editors:
        wait_until(lambda: editor.poll() is not None or fixture.running() and find(fixture.listing(), editor.pid) is not None, 60,
                   "an editor did not link to exohost")
        assert editor.poll() is None, log_path.read_text()[-3000:]
        assert find(fixture.listing(), editor.pid)["kind"] == "editor"

    def named_workspace() -> dict | None:
        machine = json.loads(fixture.exohost("machine", "--json"))
        return next((w for w in machine["workspaces"] if w["folders"] == [str(folder)]), None)

    wait_until(lambda: named_workspace() is not None, 30, "opening a loose folder made no workspace")
    assert named_workspace()["name"] == "loose-folder", named_workspace()
    print(f"  the loose folder became workspace {named_workspace()['id']} named {named_workspace()['name']!r}")
    time.sleep(6)  # the scripted text is typed 3 s after each window's first frame
    started = time.monotonic()
    assert "Quitting Exosuit" in fixture.exohost("quit")
    for editor, _, _, _ in editors:
        wait_until(lambda: editor.poll() is not None, 30, "an editor did not close when exohost quit Exosuit")
    print(f"  both windows closed {time.monotonic() - started:.1f} s after `exohost quit`")
    for _, settings, text, _ in editors:
        kept = [path for path in settings.rglob("*") if path.is_file() and text.encode() in path.read_bytes()]
        assert kept, f"the window did not keep its unsaved text {text!r} under {settings}"
        print(f"  {text!r} kept in {', '.join(str(path.relative_to(settings)) for path in kept)}")
    wait_until(lambda: fixture.listing()["processes"] == [], 30, "processes survived quit")
    wait_until(lambda: "not running" in fixture.exohost("status"), 30, "exohost did not exit after quit")


def run_unit_tests() -> None:
    """exohost's ownership rules over made-up processes (exohost/tests)."""
    result = subprocess.run([sys.executable, str(ROOT / "scripts" / "haxeon_cli.py"), "run", "--project",
                             str(ROOT / "exohost" / "tests" / "haxeon.json")], capture_output=True, text=True, timeout=240)
    assert result.returncode == 0 and "PASS: exohost unit tests" in result.stdout, f"exohost unit tests failed:\n{result.stdout}{result.stderr}"
    print("PASS unit tests")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--real-service", action="store_true", help="also run a real workspace service (needs agent build)")
    parser.add_argument("--editor", action="store_true", help="also run a real editor window (needs graphical build)")
    parser.add_argument("--only", help="run only the tests whose name contains this text")
    options = parser.parse_args()
    assert EXOHOST.is_file(), f"build exohost first: {EXOHOST}"
    if not options.only or options.only in "unit tests":
        run_unit_tests()
    with tempfile.TemporaryDirectory(prefix="exohost-test-") as temporary:
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
                 ("full quit ends remote access", lambda f: test_full_quit_ends_remote_access(f, directory / "fr")),
                 ("full quit ends every kind", lambda f: test_full_quit_ends_every_kind(f, directory / "ea")),
                 ("polite quit leaves only terminals", lambda f: test_polite_quit_leaves_only_terminals(f, directory / "ep")),
                 ("workspace ids with several editors", lambda f: test_workspace_ids_with_several_editors(f, directory / "i")),
                 ("late child", lambda f: test_late_child(f, directory / "l")),
                 ("helper markers", lambda f: test_helper_markers(f, directory / "h")),
                 ("full quit ends the run.py chain", lambda f: test_run_py_chain(f, directory / "rq", False)),
                 ("polite quit ends the run.py chain", lambda f: test_run_py_chain(f, directory / "rp", True)),
                 ("full quit ends a live host's worker", lambda f: test_live_host_worker_ends_with_quit(f, directory / "lq", False)),
                 ("polite quit ends a live host's worker", lambda f: test_live_host_worker_ends_with_quit(f, directory / "lp", True)),
                 ("a terminal build shares the worker", lambda f: test_terminal_build_shares_worker(f, directory / "rb")),
                 ("a terminal's program is not adopted", lambda f: test_terminal_program_not_adopted(f, directory / "rt")),
                 ("ownership", lambda f: test_ownership(f, directory / "o")), ("daemon", test_daemon),
                 ("links", lambda f: test_links(f, directory / "k")),
                 ("machine", lambda f: test_machine(f, directory / "m"))]
        if options.real_service:
            tests.append(("real service", lambda f: test_real_service(f, directory / "r")))
        if options.editor:
            tests.append(("two-editor-windows-quit", lambda f: test_editor(f, directory / "e")))
        for name, test in tests:
            if options.only and options.only not in name:
                continue
            (directory / "a").mkdir(exist_ok=True); (directory / "r").mkdir(exist_ok=True)
            fixture_directory = Path(tempfile.mkdtemp(dir=temporary))
            fixture = Fixture(fixture_directory)
            passed = False
            try:
                test(fixture)
                passed = True
                print(f"PASS {name}")
            finally:
                try:
                    # A failed test may leave what exohost started (a real service, an editor's): exohost ends what it lists. The
                    # fixture's exohost does not scan, so it lists only what this test started.
                    if not passed:
                        subprocess.run([str(HL), str(EXOHOST), "kill", "--all"], env=fixture.environment, capture_output=True, timeout=30)
                    subprocess.run([str(HL), str(EXOHOST), "stop"], env=fixture.environment, capture_output=True, timeout=30)
                    # The daemon holds exohost.lock until it has exited; the folder goes after.
                    wait_until(lambda: "not running" in fixture.exohost("status"), 15, "the daemon did not stop")
                except (subprocess.TimeoutExpired, AssertionError):
                    pass
                fixture.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
