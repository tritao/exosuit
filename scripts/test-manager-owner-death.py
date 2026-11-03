#!/usr/bin/env python3
"""A detached manager outlives the process that started it, and a manager that dies is replaced by the next start."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from agent_test_runtime import manager_command, manager_environment

AGENT = manager_command(ROOT)[:-1]

OWNER = r"""
import json, subprocess, sys, time
result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=120)
out = result.stdout.strip().splitlines()[-1] if result.returncode == 0 else "FAILED " + result.stderr
sys.stdout.write(out + chr(10))
sys.stdout.flush()
time.sleep(600)
"""


def alive(pid):
    if os.name == "nt":
        import ctypes
        handle = ctypes.windll.kernel32.OpenProcess(0x1000 | 0x100000, False, pid)  # QUERY_LIMITED | SYNCHRONIZE
        if not handle:
            return False
        try:
            return ctypes.windll.kernel32.WaitForSingleObject(handle, 0) != 0
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_for(what, test, seconds=30):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if test():
            return
        time.sleep(0.1)
    raise AssertionError("timed out waiting for " + what)


with tempfile.TemporaryDirectory(prefix="exosuit-owner-death-") as temporary:
    home, root = Path(temporary) / "state", Path(temporary) / "project"
    home.mkdir(mode=0o700)
    root.mkdir()
    environment = manager_environment(ROOT)
    environment["EXOSUIT_AGENT_STATE_HOME"] = str(home)

    def run(*arguments, check=True):
        result = subprocess.run([*AGENT, *arguments], env=environment, cwd=str(root), capture_output=True, text=True, timeout=120)
        if check and result.returncode != 0:
            raise RuntimeError(f"{arguments} exited {result.returncode}: {result.stderr}")
        return result

    def machine():
        return json.loads(run("--machine").stdout)["managers"]

    owner = subprocess.Popen([sys.executable, "-c", OWNER, *AGENT, "--manager", str(root), "--detach", "--idle-seconds", "120"],
                             env=environment, cwd=str(root), stdout=subprocess.PIPE, text=True)
    manager = None
    try:
        line = owner.stdout.readline().strip()
        assert not line.startswith("FAILED"), line
        first = json.loads(line)
        assert alive(first["managerPid"]) and first["managerPid"] != owner.pid, first

        owner.kill()
        owner.wait(timeout=30)
        assert not alive(owner.pid), "the owner is still running"
        time.sleep(1.0)
        assert alive(first["managerPid"]), "the manager died with its owner"
        found = json.loads(run("--manager", str(root), "--discover").stdout)
        assert found["generation"] == first["generation"] and found["managerPid"] == first["managerPid"], found
        assert [m["managerPid"] for m in machine()] == [first["managerPid"]], machine()

        # The manager dies without cleaning up: the next start replaces it.
        os.kill(first["managerPid"], signal.SIGTERM)
        wait_for("the manager to exit", lambda: not alive(first["managerPid"]))
        wait_for("the machine listing to drop it", lambda: first["managerPid"] not in [m["managerPid"] for m in machine()])
        # Two starts at once: the later one waits for the first manager's endpoint, which counts only while that pid runs.
        command = [*AGENT, "--manager", str(root), "--detach", "--idle-seconds", "120"]
        racers = [subprocess.Popen(command, env=environment, cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                  for _ in range(2)]
        replies = []
        for racer in racers:
            out, err = racer.communicate(timeout=120)
            assert racer.returncode == 0, err
            replies.append(json.loads(out.strip().splitlines()[-1]))
        assert replies[0]["generation"] == replies[1]["generation"] and replies[0]["managerPid"] == replies[1]["managerPid"], replies
        second = replies[0]
        manager = second["managerPid"]
        assert second["generation"] != first["generation"] and manager != first["managerPid"], second
        assert alive(manager), "the replacement manager is not running"
        assert [m["managerPid"] for m in machine()] == [manager], machine()
    finally:
        if owner.poll() is None:
            owner.kill()
        for pid in [manager] if manager else []:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        for pid in [manager] if manager else []:
            wait_for("the manager to stop", lambda: not alive(pid))
print("PASS: a manager outlives its owner, and a dead manager is replaced")
