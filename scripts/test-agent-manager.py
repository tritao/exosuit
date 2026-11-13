#!/usr/bin/env python3
"""Exercise real managed daemon startup, discovery, exclusion and replacement fencing."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from agent_test_runtime import manager_command
from test_driver import ROOT, WINDOWS, assert_private, isolated_environment, kill_tree, request_stop, stop_manager

MANAGER = manager_command(ROOT)


def same(left, right):
    return os.path.normcase(os.path.realpath(left)) == os.path.normcase(os.path.realpath(right))


def wait_ready(process, state):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('Manager exited: ' + (directory / 'test.log').read_text()[-3000:])
        try:
            value = json.loads((state / 'endpoint.json').read_text())
            if value['managerPid'] == process.pid:
                return value
        except (FileNotFoundError, ValueError, PermissionError):
            pass
        time.sleep(0.05)
    raise RuntimeError('Manager readiness timeout')


def stop(process, state):
    """A stop the manager cleans up after: SIGTERM, or on Windows (where terminate() is TerminateProcess) a stop request."""
    if process.poll() is not None:
        return
    if WINDOWS:
        request_stop(state / 'endpoint.json')
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            kill_tree(process)
    else:
        process.terminate()
        process.wait(timeout=10)


def lock_is_free(state):
    """Whether no process holds the state's lifetime lock (flock). Windows has no flock: there the next start shows it."""
    import fcntl
    with (state / 'agent.lock').open('r+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False


with tempfile.TemporaryDirectory(prefix='exosuit-manager-', ignore_cleanup_errors=True) as temporary:
    directory = Path(temporary)
    state, root = directory / 'state', directory / 'project'
    # The manager makes its state folder, private to this user (on Windows by an access list a folder made here lacks).
    root.mkdir()
    ENVIRONMENT = isolated_environment(directory / 'home')
    process = None
    with (directory / 'test.log').open('w') as log:
        def start():
            return subprocess.Popen([*MANAGER, str(root), '--state-dir', str(state)], env=ENVIRONMENT, stdout=log, stderr=subprocess.STDOUT)

        def start_when_free():
            """Starts a manager once the killed one's lock is released, which takes a moment after its processes ended."""
            deadline = time.monotonic() + 10
            while True:
                candidate = start()
                try:
                    status = candidate.wait(timeout=1.5)
                except subprocess.TimeoutExpired:
                    return candidate
                assert status == 3 and time.monotonic() < deadline, 'Daemon lifetime lock did not release after exit (exit %d)' % status
                time.sleep(0.2)

        try:
            process = start()
            descriptor = wait_ready(process, state)
            assert same(descriptor['root'], root), descriptor
            assert 'credential' not in descriptor and descriptor['protocol'] == 1
            credential = (state / 'credential').read_text()
            assert len(credential) == 64 and int(credential, 16) >= 0
            # Owner-only by mode on POSIX, by access list on Windows.
            for filename in ['credential', 'endpoint.json', 'catalog.sqlite', 'workspace.json', 'agent.lock']:
                assert_private(state / filename)
            duplicate = subprocess.run([*MANAGER, str(root), '--state-dir', str(state)], env=ENVIRONMENT, capture_output=True, text=True, timeout=30)
            assert duplicate.returncode == 3 and 'workspace_in_use' in duplicate.stderr, (duplicate.returncode, duplicate.stderr)
            stop(process, state)
            assert not (state / 'endpoint.json').exists()
            process = start()
            second = wait_ready(process, state)
            assert second['generation'] != descriptor['generation']
            assert (state / 'credential').read_text() == credential
            if WINDOWS:
                # The daemon runs in a job that closes with its manager, so a killed manager takes its daemon along and the
                # lock goes with them: there is no daemon left to fence a second manager from.
                process.kill(); process.wait(timeout=10)
                process = start_when_free()
            else:
                # Abrupt manager death must not release the lock while its daemon is alive.
                children = Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()
                assert len(children) == 1
                daemon_group = int(children[0])
                process.kill(); process.wait(timeout=10)
                try:
                    duplicate = subprocess.run([*MANAGER, str(root), '--state-dir', str(state)], env=ENVIRONMENT, capture_output=True, text=True, timeout=10)
                    assert duplicate.returncode == 3, duplicate.stderr
                finally:
                    os.killpg(daemon_group, signal.SIGKILL)
                deadline = time.monotonic() + 10
                while not lock_is_free(state):
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Daemon lifetime lock did not release after exit')
                    time.sleep(0.05)
                process = start()
            wait_ready(process, state)
            # A pathname replacement must fence the manager rather than silently switch databases.
            replacement = state / 'replacement.sqlite'
            replacement.write_bytes(b'not the database the agent opened')
            os.chmod(replacement, 0o600)
            try:
                os.replace(replacement, state / 'catalog.sqlite')
                replaced = True
            except PermissionError:
                # Windows refuses to replace a file that is open without delete sharing: the replacement cannot happen.
                assert WINDOWS
                replaced = False
                print('SKIP on Windows: the open catalog cannot be replaced by path, so there is nothing to fence', flush=True)
            if replaced:
                assert process.wait(timeout=10) == 1
                assert not (state / 'endpoint.json').exists()
                if not WINDOWS:
                    assert lock_is_free(state)
            else:
                stop(process, state)
            # Refuse a mismatched root even when the lifetime lock is available.
            other = directory / 'other'; other.mkdir()
            mismatch = subprocess.run([*MANAGER, str(other), '--state-dir', str(state)], env=ENVIRONMENT, capture_output=True, text=True, timeout=30)
            assert mismatch.returncode == 1 and 'identity mismatch' in mismatch.stderr, (mismatch.returncode, mismatch.stderr)
        finally:
            if process is not None:
                kill_tree(process)
    # An explicit detached start returns discovery only after its own manager is ready.
    detached = directory / 'detached'
    result = subprocess.run([*MANAGER, str(root), '--state-dir', str(detached), '--detach'], env=ENVIRONMENT, capture_output=True, text=True, timeout=100)
    if result.returncode != 0:
        raise RuntimeError(result.stderr + (detached / 'manager.log').read_text()[-3000:])
    descriptor = json.loads(result.stdout)
    try:
        assert same(descriptor['root'], root) and (detached / 'endpoint.json').exists()
    finally:
        assert stop_manager(detached / 'endpoint.json', 10), 'the detached manager did not stop on request'
        assert not (detached / 'endpoint.json').exists()
print('PASS: managed private discovery, lifetime lock, restart, detached readiness and root identity'
      + ('' if replaced else '; the database replacement fence was SKIPPED (the open catalog cannot be replaced by path)')
      + ('' if not WINDOWS else '; on Windows the lock-survives-manager-death check is not applicable'))
