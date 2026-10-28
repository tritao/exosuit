#!/usr/bin/env python3
"""suit end to end, isolated from the user's session.

Every suit call runs with EXOSUIT_SUIT=isolated and its own EXOSUIT_SUIT_HOME, so its own registry and
control endpoint. Most tests also set EXOSUIT_SUIT_SCAN=0, so suit sees only the processes this test
registers. The ownership test scans, so it lists the user's processes too, but it only reads that listing,
checks with --dry-run that bulk kills would touch none of them, and kills only its own processes by pid.

Covers: registration and pid-reuse checks, orphan detection, workspaces shared by editors, positive
ownership (adoption, and scanned processes kept out of bulk kills), graceful-then-tree termination
including children started during the grace period, relay listing and stop, the daemon's control endpoint
(status, quit, stop), and, with --real-manager, a real workspace manager that registers itself and stops
cooperatively through stop-request.json, and EXOSUIT_SUIT=off and isolated keeping a real manager out of
the default registry.
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
PARENT = [sys.executable, "-c",
          "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)']); time.sleep(300)"]
# Runs the command in argv[1] (JSON) as its child, then sleeps.
SPAWNER = [sys.executable, "-c",
           "import json, subprocess, sys, time; subprocess.Popen(json.loads(sys.argv[1]), stdin=subprocess.DEVNULL, "
           "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(300)"]
# Starts a child after 1.5 s, inside suit's 3 s grace period for a workspace manager, and writes its pid to argv[1].
LATE_PARENT = [sys.executable, "-c",
               "import subprocess, sys, time; time.sleep(1.5); "
               "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)']); "
               "open(sys.argv[1], 'w').write(str(child.pid)); time.sleep(300)"]


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

    def register(self, pid: int, kind: str, registered_at: float | None = None, **details: object) -> None:
        record = {"version": 1, "pid": pid, "kind": kind,
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
    orphan = fixture.spawn(PARENT)
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

    listing = fixture.listing()
    assert listing["editors"] == 1, listing
    assert find(listing, owned.pid)["orphaned"] is False and find(listing, owned.pid)["group"].startswith("Editor"), listing
    assert find(listing, orphan.pid)["orphaned"] is True, listing
    assert find(listing, reused.pid) is None and not (fixture.registry / f"{reused.pid}.json").exists(), "pid reuse not detected"
    assert find(listing, dead.pid) is None and not (fixture.registry / f"{dead.pid}.json").exists(), "stale record kept"
    assert "Exosuit: 1 editor, 3 background processes (1 orphaned)" == listing["summary"], listing["summary"]
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


def test_tree_kill(fixture: Fixture) -> None:
    parent = fixture.spawn(PARENT)
    time.sleep(0.5)
    fixture.register(parent.pid, "terminal-host", owner=999999)
    listing = fixture.listing()
    assert find(listing, parent.pid)["orphaned"] is True
    # The grandchild is not registered; it must die with its parent's tree.
    children = child_pids(parent.pid)
    assert children, "fixture parent has no child"
    fixture.suit("kill", str(parent.pid))
    wait_until(lambda: not alive(parent), 10, "parent survived")
    wait_until(lambda: all(not pid_alive(pid) for pid in children), 10, "grandchild survived the tree kill")


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


def test_late_child(fixture: Fixture, directory: Path) -> None:
    """A child started during the grace period dies with the tree: suit re-snapshots before the final kill."""
    directory.mkdir(parents=True, exist_ok=True)
    state = directory / "late-state"; state.mkdir()
    marker = directory / "late-child.pid"
    # A fake workspace manager that ignores stop-request.json, so suit waits out the grace period.
    manager = fixture.spawn(LATE_PARENT + [str(marker)])
    fixture.register(manager.pid, "workspace-manager", root=str(directory / "late-root"), stateDir=str(state), generation="g1")
    output = fixture.suit("kill", str(manager.pid))
    assert f"{manager.pid} workspace-manager: killed" in output, output
    assert json.loads((state / "stop-request.json").read_text()) == {"version": 1, "generation": "g1"}
    late = int(marker.read_text())
    wait_until(lambda: not pid_alive(late), 10, "a child started during the grace period survived the tree kill")


def test_ownership(fixture: Fixture, directory: Path) -> None:
    """Only processes exosuit started are its own; scanned strangers stay out of every bulk kill."""
    directory.mkdir(parents=True, exist_ok=True)
    scanning = dict(fixture.environment, EXOSUIT_SUIT_SCAN="1")

    def listing() -> dict:
        result = subprocess.run([str(HL), str(SUIT), "list", "--json"], env=scanning, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def planned(selection: str) -> set[int]:
        result = subprocess.run([str(HL), str(SUIT), "kill", selection, "--dry-run"], env=scanning, capture_output=True,
                                text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        return {int(line.split()[0]) for line in result.stdout.splitlines() if line.endswith("would stop")}

    # Fake compiler workers: suit's own `watch`, whose command line looks like a Haxeon compiler worker's.
    worker_home = directory / "worker-home"
    worker_environment = dict(fixture.environment, EXOSUIT_SUIT_HOME=str(worker_home), EXOSUIT_SUIT_SCAN="0")
    worker = [str(HL), str(SUIT), "watch", "--fake=/haxeon/compiler/suit-test-worker.hl"]
    stranger = fixture.spawn(worker, worker_environment)
    editor = fixture.spawn(SPAWNER + [json.dumps(worker)], worker_environment)
    fixture.register(editor.pid, "editor", roots=[])
    wait_until(lambda: bool(child_pids(editor.pid)), 30, "the editor did not start its worker")
    owned = child_pids(editor.pid)[0]
    try:
        wait_until(lambda: find(listing(), stranger.pid) is not None and find(listing(), owned) is not None, 30,
                   "suit did not find the fake compiler workers")
        current = listing()
        entry = find(current, stranger.pid)
        assert entry["kind"] == "compiler-worker" and entry["source"] == "scanned" and not entry["startedByExosuit"], entry
        assert entry["group"] == "Not started by exosuit" and entry["orphaned"] is False, entry
        entry = find(current, owned)
        assert entry["source"] == "adopted" and entry["startedByExosuit"] and entry["group"] == "Haxeon", entry
        assert json.loads((fixture.registry / f"{owned}.json").read_text())["adopted"] is True
        ours = {editor.pid, owned, stranger.pid}
        everything = planned("--all")
        assert owned in everything and stranger.pid not in everything and everything <= ours, everything

        # The editor exits; its worker stays exosuit's through the adoption record and is now orphaned.
        editor.kill(); editor.wait()
        wait_until(lambda: find(listing(), owned) is not None and find(listing(), owned)["orphaned"], 30,
                   "the adopted worker was not orphaned when its editor exited")
        orphans = planned("--orphans")
        assert orphans == {owned}, f"bulk kill would touch processes this test did not mark orphaned: {orphans - {owned}}"
        assert stranger.pid not in planned("--all")

        # Killing a process by pid works whether or not exosuit started it.
        for pid in (owned, stranger.pid):
            output = subprocess.run([str(HL), str(SUIT), "kill", str(pid)], env=scanning, capture_output=True, text=True,
                                    timeout=60).stdout
            assert f"{pid} compiler-worker: killed" in output, output
        wait_until(lambda: not alive(stranger) and not pid_alive(owned), 10, "an explicitly killed worker survived")
    finally:
        if pid_alive(owned):
            kill_pid(owned)


def kill_pid(pid: int) -> None:
    """Kills one process this test started and whose Popen it does not hold."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True, timeout=30)
    else:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


def child_pids(pid: int) -> list[int]:
    if os.name == "nt":
        output = subprocess.run(["powershell", "-NoProfile", "-Command",
                                 f"(Get-CimInstance Win32_Process -Filter 'ParentProcessId={pid}').ProcessId"],
                                capture_output=True, text=True, timeout=60).stdout
    else:
        output = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True, timeout=30).stdout
    return [int(value) for value in output.split() if value.strip().isdigit()]


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
    """EXOSUIT_SUIT=off, and isolated without a home, keep a real manager out of the default registry and suit.

    The default home is moved into the test directory, and a last run with EXOSUIT_SUIT=on (autostart off)
    checks that the manager does register there, so the first two cannot pass because nothing registers.
    """
    sys.path.insert(0, str(ROOT / "scripts"))
    from agent_test_runtime import manager_command, manager_environment, launcher_path
    directory.mkdir(parents=True, exist_ok=True)
    for index, mode in enumerate(("off", "isolated", "on")):
        workspace = directory / f"switch-workspace-{index}"; workspace.mkdir()
        state = directory / f"switch-state-{index}"
        # The default home moves into the test directory, so a registration there cannot reach the user's suit.
        default_parent = directory / f"default-{index}"
        environment = manager_environment(ROOT, launcher_path(ROOT))
        for key in [key for key in environment if key.startswith("EXOSUIT_SUIT")]:
            del environment[key]
        environment.update(EXOSUIT_SUIT=mode, LOCALAPPDATA=str(default_parent), XDG_STATE_HOME=str(default_parent),
                           EXOSUIT_SUIT_LAUNCHER=str(SUIT))
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
                assert record.is_file(), f"EXOSUIT_SUIT=on: the manager did not register in the moved default home {suit_home}"
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--real-manager", action="store_true", help="also run a real workspace manager (needs agent build)")
    parser.add_argument("--editor", action="store_true", help="also run a real editor window (needs graphical build)")
    parser.add_argument("--only", help="run only the tests whose name contains this text")
    options = parser.parse_args()
    assert SUIT.is_file(), f"build suit first: {SUIT}"
    with tempfile.TemporaryDirectory(prefix="suit-test-") as temporary:
        directory = Path(temporary)
        tests = [("registry and termination", lambda f: test_registry_and_termination(f, directory / "a")),
                 ("shared workspace", lambda f: test_shared_workspace(f, directory / "s")),
                 ("tree kill", test_tree_kill), ("late child", lambda f: test_late_child(f, directory / "l")),
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
