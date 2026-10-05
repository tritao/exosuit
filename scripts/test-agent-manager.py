#!/usr/bin/env python3
"""Exercise real managed daemon startup, discovery, exclusion and replacement fencing."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MANAGER = ROOT / 'scripts/run-agent.py'


def wait_ready(process, state):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('Manager exited: ' + (state / 'test.log').read_text()[-3000:])
        try:
            value = json.loads((state / 'endpoint.json').read_text())
            if value['managerPid'] == process.pid:
                return value
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    raise RuntimeError('Manager readiness timeout')


def stop(process):
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=10)


with tempfile.TemporaryDirectory(prefix='exosuit-manager-') as temporary:
    directory = Path(temporary)
    state, root = directory / 'state', directory / 'project'
    state.mkdir(mode=0o700)
    root.mkdir()
    process = None
    with (state / 'test.log').open('w') as log:
        def start():
            return subprocess.Popen([sys.executable, str(MANAGER), str(root), '--state-dir', str(state)], stdout=log, stderr=subprocess.STDOUT)

        try:
            process = start()
            descriptor = wait_ready(process, state)
            assert descriptor['root'] == str(root.resolve())
            assert 'credential' not in descriptor and descriptor['protocol'] == 1
            credential = (state / 'credential').read_text()
            assert len(credential) == 64 and int(credential, 16) >= 0
            for filename in ['credential', 'endpoint.json', 'catalog.sqlite', 'workspace.json', 'agent.lock']:
                assert (state / filename).stat().st_mode & 0o077 == 0
            duplicate = subprocess.run([sys.executable, str(MANAGER), str(root), '--state-dir', str(state)], capture_output=True, text=True, timeout=10)
            assert duplicate.returncode == 3 and 'workspace_in_use' in duplicate.stderr
            stop(process)
            assert not (state / 'endpoint.json').exists()
            process = start()
            second = wait_ready(process, state)
            assert second['generation'] != descriptor['generation']
            assert (state / 'credential').read_text() == credential
            # Abrupt manager death must not release the lock while its daemon is alive.
            children = Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()
            assert len(children) == 1
            daemon_group = int(children[0])
            process.kill(); process.wait(timeout=10)
            try:
                duplicate = subprocess.run([sys.executable, str(MANAGER), str(root), '--state-dir', str(state)], capture_output=True, text=True, timeout=10)
                assert duplicate.returncode == 3, duplicate.stderr
            finally:
                os.killpg(daemon_group, signal.SIGKILL)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                with (state / 'agent.lock').open('r+') as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        pass
                time.sleep(0.05)
            else:
                raise RuntimeError('Daemon lifetime lock did not release after exit')
            process = start()
            wait_ready(process, state)
            # A pathname replacement must fence the manager rather than silently switch databases.
            replacement = state / 'replacement.sqlite'
            replacement.write_bytes(b'not the database the agent opened')
            os.chmod(replacement, 0o600)
            os.replace(replacement, state / 'catalog.sqlite')
            assert process.wait(timeout=10) == 1
            assert not (state / 'endpoint.json').exists()
            with (state / 'agent.lock').open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Refuse a mismatched root even when the lifetime lock is available.
            other = directory / 'other'; other.mkdir()
            mismatch = subprocess.run([sys.executable, str(MANAGER), str(other), '--state-dir', str(state)], capture_output=True, text=True, timeout=10)
            assert mismatch.returncode == 1 and 'identity mismatch' in mismatch.stderr
        finally:
            if process is not None:
                stop(process)
    # An explicit detached start returns discovery only after its own manager is ready.
    detached = directory / 'detached'
    result = subprocess.run([sys.executable, str(MANAGER), str(root), '--state-dir', str(detached), '--detach'], capture_output=True, text=True, timeout=100)
    if result.returncode != 0:
        raise RuntimeError(result.stderr + (detached / 'manager.log').read_text()[-3000:])
    descriptor = json.loads(result.stdout)
    try:
        assert descriptor['root'] == str(root.resolve()) and (detached / 'endpoint.json').exists()
    finally:
        os.kill(descriptor['managerPid'], signal.SIGTERM)
        deadline = time.monotonic() + 10
        while (detached / 'endpoint.json').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not (detached / 'endpoint.json').exists()
print('PASS: managed private discovery, lifetime lock, restart, detached readiness, root identity and database replacement fence')
