#!/usr/bin/env python3
"""Exercise inspection over a real local socket and render the separate viewer (use xvfb-run)."""
import json
import os
from pathlib import Path
import socket
import select
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "haxeon/scripts/haxeon"


def receive_exact(peer, length):
    data = b""
    while len(data) < length:
        part = peer.recv(length - len(data))
        assert part, "Inspection connection closed"
        data += part
    return data


def request(peer, selected=0, full=False, version=1, details=False, frame_id=0):
    payload = json.dumps(dict(version=version, selected=selected, full=full, pick=False,
                              details=details, frameId=frame_id)).encode()
    peer.sendall(b"HMPK\x01\x00" + struct.pack(">I", len(payload)) + payload)
    header = receive_exact(peer, 10)
    assert header[:6] == b"HMPK\x01\x00"
    length = struct.unpack(">I", header[6:])[0]
    assert length <= 262144
    return json.loads(receive_exact(peer, length))


def main():
    # The UI native libraries are built independently of the Haxe package graph.
    native = ROOT / "haxeon/out/packages/ui/native"
    os.environ["LD_LIBRARY_PATH"] = os.pathsep.join([str(ROOT / "haxeon/out"), str(ROOT / "haxeon/.tools/hashlink"), str(native), str(native / "nativekit"),
                                                    str(native / "nativekit/modules/gpu"), os.environ.get("LD_LIBRARY_PATH", "")])
    subprocess.run([str(CLI), "build", "--project", str(ROOT / "tests/devtools/haxeon.json")], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([str(ROOT / "haxeon/.tools/haxe/haxe"), "-cp", str(ROOT / "haxeon/src"),
                    "-cp", str(ROOT / "devtools/bridge"), "-main", "ProfilerBridge", "-hl", str(ROOT / "devtools/build/profiler.hl")], check=True)
    with tempfile.TemporaryDirectory(prefix="devtools-test-") as temporary:
        directory = Path(temporary)
        test_idle(directory)
        endpoint = str(directory / "inspection.sock")
        with (directory / "target.log").open("w+") as log:
            with socket.socket() as reserve:
                reserve.bind(("127.0.0.1", 0))
                port = reserve.getsockname()[1]
            target = subprocess.Popen([str(ROOT / "haxeon/.tools/hashlink/hl"), "--diagnostics", str(port),
                                       str(ROOT / "tests/devtools/build/host/main.hl"), "--fixture", endpoint],
                                      cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 60
                while not Path(endpoint).exists():
                    assert target.poll() is None, "Target exited: " + (directory / "target.log").read_text()
                    assert time.monotonic() < deadline, "Target listener timed out"
                    time.sleep(.05)
                assert os.stat(endpoint).st_mode & 0o777 == 0o600, "Socket is not private"
                with socket.socket(socket.AF_UNIX) as peer:
                    peer.settimeout(5)
                    peer.connect(endpoint)
                    first = request(peer, full=True)
                    deadline = time.monotonic() + 5
                    while not first["changed"]:
                        assert time.monotonic() < deadline, first
                        time.sleep(.3)
                        first = request(peer, full=True)
                    assert first["full"] and first["changed"] and not first["truncated"], first
                    selected = next(n["id"] for n in first["changed"] if n["type"] == "button")
                    time.sleep(.3)
                    second = request(peer, selected=selected)
                    assert second["selected"]["id"] == selected and second["selected"]["styles"]
                    assert not second["full"] and not second["removed"]
                    time.sleep(.3)
                    third = request(peer, selected=2147483647)
                    assert third["selected"] is None, "Destroyed/unknown selection was retained"
                    assert third["frames"] and len(third["frames"]) <= 240
                    frame = third["frames"][-1]
                    assert frame["totalMs"] >= 0 and frame["heapBytes"] > 0
                    time.sleep(.3)
                    request(peer, details=True)
                    time.sleep(.3)
                    detailed = request(peer, details=True)
                    assert detailed["frameEvents"] is not None, "Detailed widget events were not retained"
                time.sleep(.3)
                with socket.socket(socket.AF_UNIX) as peer:
                    peer.settimeout(5)
                    peer.connect(endpoint)
                    assert request(peer, full=True)["changed"], "Reconnect did not restore full tree"
                test_profiler(directory, port)
                capture = ROOT / "build/devtools-smoke"
                result = subprocess.run(["python3", str(ROOT / "scripts/devtools.py"),
                                         "--endpoint=" + endpoint, "--profiler-port=" + str(port),
                                         "--start-sampling",
                                         "--save-inspection=" + str(directory / "inspection.json"),
                                         "--capture-dir=" + str(capture), "--capture-seconds=3"],
                                        cwd=ROOT, capture_output=True, text=True, timeout=60)
                assert result.returncode == 0, result.stdout + result.stderr
                state = json.loads((capture / "app-state.json").read_text())
                assert state["snapshot"] is not None and state["snapshot"]["frames"], state
                assert state["profiler"] is not None and state["profiler"]["state"] == "running" and state["profiler"]["samples"] > 0, state
                saved = json.loads((directory / "inspection.json").read_text())
                assert saved["nodes"] and saved["snapshot"]["frames"]
                replay = subprocess.run(["python3", str(ROOT / "scripts/devtools.py"),
                                         "--inspection-capture=" + str(directory / "inspection.json"),
                                         "--capture-dir=" + str(capture / "offline"), "--smoke-frames=2"],
                                        cwd=ROOT, capture_output=True, text=True, timeout=60)
                assert replay.returncode == 0, replay.stdout + replay.stderr
                offline = json.loads((capture / "offline/app-state.json").read_text())
                assert offline["status"] == "Offline inspection capture" and offline["snapshot"]["frames"]
                assert (capture / "ui-tree.txt").is_file()
                print("PASS: private local socket, full/delta snapshots, selection, missing IDs, bounded frames, reconnect, separate UI capture")
                print("Viewer capture:", capture)
            finally:
                target.terminate()
                try:
                    target.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    target.kill()
                    target.wait()


def test_profiler(directory, port):
    environment = dict(os.environ, HAXEON_DEVTOOLS_PROFILER_TOOL=str(ROOT / "haxeon/.tools/hashlink/hlprof-live"))
    bridge = subprocess.Popen([str(ROOT / "haxeon/.tools/hashlink/hl"), str(ROOT / "devtools/build/profiler.hl")],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    pending = b""

    def send(command, **options):
        bridge.stdin.write((json.dumps(dict(command=command, options=options)) + "\n").encode())
        bridge.stdin.flush()

    def wait(predicate):
        nonlocal pending
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                value = json.loads(line)
                assert value["type"] != "error", value
                if predicate(value):
                    return value
            ready, _, _ = select.select([bridge.stdout], [], [], .1)
            if ready:
                data = os.read(bridge.stdout.fileno(), 65536)
                assert data, "Profiler helper exited"
                pending += data
        raise AssertionError("Profiler response timed out")

    try:
        capture = directory / "profile.hlpc"
        send("connect", host="127.0.0.1", port=port, maxEntries=20)
        wait(lambda v: v.get("command") == "connect")
        send("captureStart", path=str(capture))
        wait(lambda v: v.get("command") == "captureStart")
        send("start", sampleRate=250, pollIntervalMs=250)
        first = wait(lambda v: v["type"] == "snapshot" and v["value"]["samples"] > 0)
        # Stop reading the helper output: decoding must continue while its writer experiences pipe pressure.
        time.sleep(3)
        send("pause")
        paused = wait(lambda v: v.get("command") == "pause")
        assert paused["value"]["samples"] > first["value"]["samples"] + 100, "Slow viewer stalled HLDI decoding"
        send("captureStop")
        wait(lambda v: v.get("command") == "captureStop")
        assert capture.read_bytes()[:4] == b"HLPC"
        send("report", path=str(capture))
        report = wait(lambda v: v["type"] == "report")
        assert report["text"], "Existing HLPC capture report was empty"
        trace = directory / "profile.pftrace"
        send("export", path=str(capture), output=str(trace))
        wait(lambda v: v["type"] == "report")
        assert trace.stat().st_size > 0
        print("PASS: HLDI sampling, complete HLPC recording, existing capture report, Perfetto export")
    finally:
        bridge.stdin.close()
        try:
            bridge.wait(timeout=5)
        except subprocess.TimeoutExpired:
            bridge.kill()
            bridge.wait()


def test_idle(directory):
    endpoint = str(directory / "idle.sock")
    with (directory / "idle.log").open("w") as log:
        target = subprocess.Popen([str(ROOT / "haxeon/.tools/hashlink/hl"), str(ROOT / "tests/devtools/build/host/main.hl"),
                                   "--idle-fixture", endpoint], cwd=ROOT, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while not Path(endpoint).exists():
                assert target.poll() is None, (directory / "idle.log").read_text()
                assert time.monotonic() < deadline
                time.sleep(.05)
            time.sleep(.5)
            with socket.socket(socket.AF_UNIX) as peer:
                peer.settimeout(5)
                peer.connect(endpoint)
                first = request(peer, full=True)
                assert first["frames"], "Attachment did not expose the last idle frame"
                frame = first["frames"][-1]["id"]
                for _ in range(3):
                    time.sleep(.3)
                    assert request(peer)["frames"][-1]["id"] == frame, "Inspection forced an idle target to render"
                time.sleep(.3)
                payload = json.dumps(dict(version=99)).encode()
                peer.sendall(b"HMPK\x01\x00" + struct.pack(">I", len(payload)) + payload)
                assert peer.recv(1) == b"", "Unsupported protocol was accepted"
            print("PASS: inspection preserves idle rendering; unsupported protocol disconnects cleanly")
        finally:
            target.terminate()
            target.wait(timeout=5)


if __name__ == "__main__":
    main()
