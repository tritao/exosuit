#!/usr/bin/env python3
"""Real managed shutdown: idle, unnegotiated sockets, authenticated clients and opt-in availability."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MANAGER = ROOT / 'scripts/run-agent.py'
HAXEON = os.environ.get('HAXEON_BIN', str(Path(os.environ.get('HAXEON_ROOT', str(ROOT / 'haxeon'))) / 'scripts/haxeon'))
MODE = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
PROJECT = ROOT / 'tests/workspace-attachment/haxeon.json'
subprocess.run([HAXEON, 'build', '--project', str(PROJECT), *MODE], check=True)
with tempfile.TemporaryDirectory(prefix='exidle-') as temporary:
    fixture = Path(temporary)
    root = fixture / 'project'; root.mkdir()
    state = fixture / 'state'
    environment = dict(os.environ, XDG_STATE_HOME=str(state))
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE', None)
    def endpoint():
        entries = list(state.glob('exosuit/workspaces/*/endpoint.json'))
        return entries[0] if entries else None
    def ready(process):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            assert process.poll() is None, 'Manager exited before readiness: ' + (fixture / 'manager.log').read_text()[-4000:]
            path = endpoint()
            if path:
                return json.loads(path.read_text())
            time.sleep(0.05)
        raise AssertionError('Readiness timeout')
    with (fixture / 'manager.log').open('w') as log:
        process = None
        try:
            # No handshake: a raw socket cannot keep a service alive indefinitely.
            process = subprocess.Popen([sys.executable, str(MANAGER), str(root), '--idle-seconds', '2'], env=environment, stdout=log, stderr=subprocess.STDOUT)
            first = ready(process)
            with socket.socket(socket.AF_UNIX) as raw:
                raw.connect(first['socket'])
                assert process.wait(timeout=12) == 0, 'Idle shutdown reported failure'
            assert endpoint() is None and not Path(first['socket']).exists(), 'Idle shutdown left live discovery/socket'
            database = Path(first['credentialFile']).parent / 'catalog.sqlite'
            assert database.exists(), 'Idle shutdown discarded persistent catalog'
            # A fresh instance reopens the same durable database. Clients reset grace.
            process = subprocess.Popen([sys.executable, str(MANAGER), str(root), '--idle-seconds', '4'], env=environment, stdout=log, stderr=subprocess.STDOUT)
            second = ready(process)
            assert first['generation'] != second['generation']
            subprocess.run([HAXEON, 'run', '--project', str(PROJECT), *MODE, '--', 'hold', str(root), str(MANAGER)], env=environment, check=True, timeout=120)
            assert process.poll() is None and endpoint() is not None, 'Last disconnect had no grace'
            assert process.wait(timeout=12) == 0 and endpoint() is None
            # Explicit availability propagates through the detached manager boundary.
            subprocess.run([sys.executable, str(MANAGER), str(root), '--detach', '--idle-seconds', '1', '--always-available'], env=environment, check=True, timeout=90)
            descriptor = json.loads(endpoint().read_text())
            time.sleep(2)
            assert endpoint() is not None and json.loads(endpoint().read_text())['generation'] == descriptor['generation'], 'Always-available service idled out'
            print('PASS: graceful idle stop, unnegotiated socket exclusion, connected sibling, retained catalog, restart and detached always-available mode', flush=True)
        except Exception:
            print((fixture / 'manager.log').read_text()[-6000:], file=sys.stderr)
            raise
        finally:
            if process is not None and process.poll() is None:
                process.terminate(); process.wait(timeout=10)
            path = endpoint()
            if path:
                import signal
                try: os.kill(json.loads(path.read_text())['managerPid'], signal.SIGTERM)
                except ProcessLookupError: pass
                deadline = time.monotonic() + 10
                while endpoint() and time.monotonic() < deadline: time.sleep(0.05)
