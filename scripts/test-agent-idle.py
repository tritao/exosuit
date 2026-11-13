#!/usr/bin/env python3
"""Real managed shutdown: idle, unnegotiated sockets, authenticated clients and opt-in availability."""
import contextlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from agent_test_runtime import launcher_path, manager_command
from test_driver import ROOT, WINDOWS, build_test, endpoints, isolated_environment, kill_tree, run_tree, stop_managers

MANAGER = launcher_path(ROOT)
MANAGER_COMMAND = manager_command(ROOT)
RUNNER = build_test('workspace-attachment')


@contextlib.contextmanager
def raw_connection(address):
    """A connection to the manager's local endpoint that never speaks: a Unix socket, or a named pipe on Windows."""
    if WINDOWS:
        with open(address, 'r+b', buffering=0) as pipe:
            yield pipe
    else:
        with socket.socket(socket.AF_UNIX) as raw:
            raw.connect(address)
            yield raw


def endpoint_gone(address):
    if not WINDOWS:
        return not Path(address).exists()
    # Asking whether a pipe exists opens it, so open it: a manager that is gone has no pipe of that name.
    try:
        with open(address, 'r+b', buffering=0):
            return False
    except FileNotFoundError:
        return True
    except OSError:
        return False


with tempfile.TemporaryDirectory(prefix='exidle-', ignore_cleanup_errors=True) as temporary:
    fixture = Path(temporary)
    root = fixture / 'project'; root.mkdir()
    state = fixture / 'state'
    environment = isolated_environment(state, MANAGER, 'workspace-attachment')
    def endpoint():
        entries = endpoints(state)
        return entries[0] if entries else None
    def ready(process):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            assert process.poll() is None, 'Manager exited before readiness: ' + (fixture / 'manager.log').read_text()[-4000:]
            path = endpoint()
            if path:
                try: return json.loads(path.read_text())
                except (OSError, ValueError): pass  # being written
            time.sleep(0.05)
        raise AssertionError('Readiness timeout')
    with (fixture / 'manager.log').open('w') as log:
        process = None
        try:
            # No handshake: a raw socket cannot keep a service alive indefinitely.
            process = subprocess.Popen([*MANAGER_COMMAND, str(root), '--idle-seconds', '2'], env=environment, stdout=log, stderr=subprocess.STDOUT)
            first = ready(process)
            with raw_connection(first['socket']):
                assert process.wait(timeout=12) == 0, 'Idle shutdown reported failure'
            assert endpoint() is None and endpoint_gone(first['socket']), 'Idle shutdown left live discovery/socket'
            database = Path(first['credentialFile']).parent / 'catalog.sqlite'
            assert database.exists(), 'Idle shutdown discarded persistent catalog'
            # A fresh instance reopens the same durable database. Clients reset grace.
            process = subprocess.Popen([*MANAGER_COMMAND, str(root), '--idle-seconds', '10'], env=environment, stdout=log, stderr=subprocess.STDOUT)
            second = ready(process)
            assert first['generation'] != second['generation']
            run_tree([*RUNNER, 'hold', str(root), str(MANAGER)], environment, timeout=120)
            assert process.poll() is None and endpoint() is not None, 'Last disconnect had no grace'
            assert process.wait(timeout=15) == 0 and endpoint() is None
            # Explicit availability propagates through the detached manager boundary.
            subprocess.run([*MANAGER_COMMAND, str(root), '--detach', '--idle-seconds', '1', '--always-available'], env=environment, check=True, timeout=90,
                           stdout=subprocess.DEVNULL, stderr=log)
            descriptor = json.loads(endpoint().read_text())
            time.sleep(2)
            assert endpoint() is not None and json.loads(endpoint().read_text())['generation'] == descriptor['generation'], 'Always-available service idled out'
            print('PASS: graceful idle stop, unnegotiated socket exclusion, connected sibling, retained catalog, restart and detached always-available mode', flush=True)
        except Exception:
            log.flush()
            print((fixture / 'manager.log').read_text()[-6000:], file=sys.stderr)
            raise
        finally:
            if process is not None:
                kill_tree(process)
            stop_managers(state)
