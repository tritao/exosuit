#!/usr/bin/env python3
"""Native client discovery/launch/reuse acceptance, with real private managed daemons."""
import hashlib
import json
import contextlib
import socket
import threading
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
from agent_test_runtime import launcher_path, manager_command

HAXEON = os.environ.get('HAXEON_BIN', str(Path(os.environ.get('HAXEON_ROOT', str(ROOT / 'haxeon'))) / 'scripts/haxeon'))
MANAGER = launcher_path(ROOT)
MANAGER_COMMAND = manager_command(ROOT)
MODE = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []


def directory_for(state, root):
    key = hashlib.sha256(os.fsencode(root.resolve())).hexdigest()[:20]
    return state / 'exosuit/workspaces' / key


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
    subprocess.run([HAXEON, 'run', '--project', str(ROOT / 'tests/workspace-attachment/haxeon.json'), *MODE, '--', mode, str(root), str(MANAGER)], env=environment, check=True, timeout=120)


with tempfile.TemporaryDirectory(prefix='exa-') as temporary:
    directory = Path(temporary)
    root, state = directory / 'project', directory / 'state'
    (root / 'other').mkdir(parents=True)
    environment = dict(os.environ, XDG_STATE_HOME=str(state))
    descriptors = []
    try:
        run_client('attach', root, environment)
        for project in [root, root / 'other']:
            endpoint = directory_for(state, project) / 'endpoint.json'
            descriptors.append(json.loads(endpoint.read_text()))
        endpoint = directory_for(state, root) / 'endpoint.json'
        original = json.loads(endpoint.read_text())
        # Same expected root, but a socket serving another workspace: RPC must reject it.
        other = descriptors[1]
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
        rejected = subprocess.run([*MANAGER_COMMAND, str(root), '--discover'], env=environment, capture_output=True, text=True, timeout=10)
        assert rejected.returncode == 1 and 'path mismatch' in rejected.stderr
        endpoint.write_text(json.dumps(original))
        # A stale descriptor for a dead manager/socket must cause safe restart.
        os.kill(original['managerPid'], signal.SIGTERM)
        deadline = time.monotonic() + 10
        while endpoint.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not endpoint.exists()
        endpoint.write_text(json.dumps(original)); os.chmod(endpoint, 0o600)
        run_client('attach', root, environment)
        restarted = json.loads(endpoint.read_text())
        assert restarted['generation'] != original['generation']
        descriptors[0] = restarted
        print('PASS: safe stale discovery restart and private descriptor rejection', flush=True)
        run_client('remote-setup', root, environment)
    finally:
        # Read current owned descriptors, including managers created before a failed assertion.
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try:
                descriptor = json.loads(endpoint.read_text())
                os.kill(descriptor['managerPid'], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
        for identity in state.glob('exosuit/workspaces/*/relay-machine.json'):
            machine_id = json.loads(identity.read_text())['machineId']
            subprocess.run([HAXEON, 'run', '--project', str(ROOT / 'tests/workspace-attachment/haxeon.json'), *MODE, '--',
                            'cleanup-relay', machine_id, 'https://127.0.0.1:1'], env=environment, check=True, timeout=120)
        deadline = time.monotonic() + 10
        while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic() < deadline:
            time.sleep(0.05)
