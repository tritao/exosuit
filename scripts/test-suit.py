#!/usr/bin/env python3
"""suit end to end, isolated from the user's session.

Every suit call runs with its own EXOSUIT_SUIT_HOME (so its own registry and control endpoint) and with
EXOSUIT_SUIT_SCAN=0, so it sees only the processes this test registers. Nothing outside the test's own
process tree can be listed, and so nothing else can be terminated.

Covers: registration and pid-reuse checks, orphan detection, graceful-then-tree termination, relay
listing and stop, the daemon's control endpoint (status, quit, stop), and, with --real-manager, a real
workspace manager that registers itself and stops cooperatively through stop-request.json.
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
HAXEON = Path(os.environ.get("HAXEON_ROOT", ROOT / "haxeon"))
HL = HAXEON / ".tools" / "hashlink" / ("hl.exe" if os.name == "nt" else "hl")
SUIT = ROOT / "suit" / "build" / "host" / "main.hl"
SLEEPER = [sys.executable, "-c", "import time; time.sleep(300)"]
PARENT = [sys.executable, "-c",
          "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)']); time.sleep(300)"]


def library_path() -> str:
    directories = [ROOT / "suit/build/host/native" / name for name in ("exosuit-suit", "processkit")]
    directories += [HAXEON / "out", HAXEON / ".tools" / "hashlink"]
    agent_native = ROOT / "agent/build/host/native"
    if agent_native.is_dir():
        directories += sorted(path for path in agent_native.iterdir() if path.is_dir())
    variable = "PATH" if os.name == "nt" else "LD_LIBRARY_PATH"
    return os.pathsep.join([str(path) for path in directories if path.is_dir()] + [os.environ.get(variable, "")])


class Fixture:
    def __init__(self, directory: Path) -> None:
        self.home = directory / "suit-home"
        self.registry = self.home / "registry"
        self.environment = dict(os.environ, EXOSUIT_SUIT_HOME=str(self.home), EXOSUIT_SUIT_SCAN="0",
                                EXOSUIT_SUIT_TRAY="0", EXOSUIT_SUIT_AUTOSTART="0", EXOSUIT_SUIT_IDLE_SECONDS="30",
                                EXOSUIT_SUIT_LAUNCHER=str(SUIT))
        self.environment["PATH" if os.name == "nt" else "LD_LIBRARY_PATH"] = library_path()
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

    def spawn(self, command: list[str] = SLEEPER) -> subprocess.Popen:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
    fixture.register(editor.pid, "editor", roots=[str(root_a)])
    owned = fixture.spawn()
    fixture.register(owned.pid, "workspace-host", root=str(root_a), owner=editor.pid)
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
    fixture.register(hosted.pid, "workspace-host", root=str(root_c), stateDir=str(state), owner=editor.pid)

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
    fixture.register(service.pid, "workspace-host", owner=editor.pid)
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
        key: value for key, value in fixture.environment.items() if key.startswith("EXOSUIT_SUIT_")})
    subprocess.run([*manager_command(ROOT), str(workspace), "--state-dir", str(state), "--detach", "--idle-seconds", "60"],
                   env=environment, check=True, timeout=100, capture_output=True)
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
    options = parser.parse_args()
    assert SUIT.is_file(), f"build suit first: {SUIT}"
    with tempfile.TemporaryDirectory(prefix="suit-test-") as temporary:
        directory = Path(temporary)
        tests = [("registry and termination", lambda f: test_registry_and_termination(f, directory / "a")),
                 ("tree kill", test_tree_kill), ("daemon", test_daemon)]
        if options.real_manager:
            tests.append(("real manager", lambda f: test_real_manager(f, directory / "r")))
        if options.editor:
            tests.append(("editor", lambda f: test_editor(f, directory / "e")))
        for name, test in tests:
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
