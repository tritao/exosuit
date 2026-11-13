#!/usr/bin/env python3
"""Native client discovery/launch/reuse acceptance, with real private managed daemons."""
import json
import contextlib
import socket
import threading
import os
from pathlib import Path
import subprocess
import tempfile
import time

from agent_test_runtime import launcher_path, manager_command
from test_driver import ROOT, WINDOWS, build_test, endpoint_for, isolated_environment, request_stop, run_tree, stop_managers

MANAGER = launcher_path(ROOT)
MANAGER_COMMAND = manager_command(ROOT)
RUNNER = build_test('workspace-attachment')


@contextlib.contextmanager
def proxy_socket(address, target):
    backup = address.with_name('socket-backup')
    address.rename(backup)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(address)); os.chmod(address, 0o600)
    listener.listen(); listener.settimeout(0.1)
    stopping = threading.Event()
    connections = []
    workers = []
    def forward(source, destination):
        try:
            while not stopping.is_set():
                data = source.recv(65536)
                if not data: break
                destination.sendall(data)
        except OSError:
            pass
    def accept():
        while not stopping.is_set():
            try:
                incoming, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            outgoing = socket.socket(socket.AF_UNIX); outgoing.connect(str(target))
            connections.extend([incoming, outgoing])
            for source, destination in [(incoming, outgoing), (outgoing, incoming)]:
                thread = threading.Thread(target=forward, args=(source, destination), daemon=True)
                workers.append(thread); thread.start()
    thread = threading.Thread(target=accept, daemon=True); thread.start()
    try:
        yield
    finally:
        stopping.set(); listener.close(); thread.join(timeout=2)
        for connection in connections:
            try: connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            connection.close()
        for worker in workers: worker.join(timeout=2)
        address.unlink(missing_ok=True); backup.rename(address)


def run_client(mode, root, environment):
    run_tree([*RUNNER, mode, str(root), str(MANAGER)], environment, timeout=150)


with tempfile.TemporaryDirectory(prefix='exa-', ignore_cleanup_errors=True) as temporary:
    directory = Path(temporary)
    root, state = directory / 'project', directory / 'state'
    (root / 'other').mkdir(parents=True)
    environment = isolated_environment(state, MANAGER, 'workspace-attachment')
    descriptors = []
    try:
        run_client('attach', root, environment)
        for project in [root, root / 'other']:
            descriptors.append(json.loads(endpoint_for(state, project).read_text()))
        endpoint = endpoint_for(state, root)
        original = json.loads(endpoint.read_text())
        # Same expected root, but a socket serving another workspace: RPC must reject it.
        other = descriptors[1]
        if WINDOWS:
            # The endpoint is a named pipe, exosuit-<key> in the pipe namespace. It cannot be moved aside for a proxy to
            # take its name while its manager serves it. What a client does with a descriptor naming another workspace's
            # pipe is checked instead: the second manager's pipe goes into the descriptor and the client must refuse it.
            endpoint.write_text(json.dumps(dict(original, socket=other['socket']))); os.chmod(endpoint, 0o600)
            run_client('reject', root, environment)
            endpoint.write_text(json.dumps(original))
        else:
            with proxy_socket(Path(original['socket']), Path(other['socket'])):
                run_client('reject', root, environment)
        # Wrong roots in private metadata must also fail before opening a transport.
        value = dict(original, root=str(root / 'other'))
        endpoint.write_text(json.dumps(value)); os.chmod(endpoint, 0o600)
        run_client('reject', root, environment)
        endpoint.write_text(json.dumps(original))
        # Validate helper rejection independently of RPC with an injected remote path.
        value = dict(original, socket=str(directory / 'untrusted.sock'))
        endpoint.write_text(json.dumps(value))
        # The manager runs with its native libraries, so it fails for the descriptor rather than for loading.
        rejected = subprocess.run([*MANAGER_COMMAND, str(root), '--discover'], env=environment, capture_output=True, text=True, timeout=30)
        assert rejected.returncode == 1 and 'identity mismatch' in rejected.stderr, (rejected.returncode, rejected.stdout, rejected.stderr)
        endpoint.write_text(json.dumps(original))
        # A stale descriptor for a dead manager/socket must cause safe restart.
        request_stop(endpoint, original)
        deadline = time.monotonic() + 15
        while endpoint.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not endpoint.exists()
        endpoint.write_text(json.dumps(original)); os.chmod(endpoint, 0o600)
        run_client('attach', root, environment)
        restarted = json.loads(endpoint.read_text())
        assert restarted['generation'] != original['generation']
        descriptors[0] = restarted
        print('PASS: safe stale discovery restart and private descriptor rejection', flush=True)
        run_client('terminal-handover', root, environment)
        run_client('remote-setup', root, environment)
    finally:
        # Current owned descriptors, including managers created before a failed assertion.
        stop_managers(state)
        for identity in state.glob('exosuit/workspaces/*/relay-machine.json'):
            machine_id = json.loads(identity.read_text())['machineId']
            run_tree([*RUNNER, 'cleanup-relay', machine_id, 'https://127.0.0.1:1'], environment, timeout=120)
