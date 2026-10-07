#!/usr/bin/env python3
"""Explicit opt-in native HTTPS/WSS acceptance against an existing hosted relay."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('origin', help='Hosted HTTPS relay origin to exercise')
    args = parser.parse_args()
    if not args.origin.startswith('https://'):
        parser.error('Expected an HTTPS relay origin')
    cli = os.environ.get('HAXEON_BIN', str(Path(os.environ.get('HAXEON_ROOT', str(ROOT / 'haxeon'))) / 'scripts/haxeon'))
    compiler_mode = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
    command = [cli, 'run', '--project', str(ROOT / 'tests/workspace-attachment/haxeon.json'), *compiler_mode, '--']
    with tempfile.TemporaryDirectory(prefix='exa-live-') as temporary:
        base = Path(temporary)
        project, state = base / 'project', base / 'state'
        project.mkdir()
        environment = dict(os.environ, XDG_STATE_HOME=str(state))
        try:
            subprocess.run([*command, 'relay-live', str(project), str(ROOT / 'scripts/run-agent.py'), args.origin],
                           env=environment, check=True, timeout=150)
        finally:
            for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
                try:
                    os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError):
                    pass
            deadline = time.monotonic() + 10
            while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic() < deadline:
                time.sleep(.05)
            for identity in state.glob('exosuit/workspaces/*/relay-machine.json'):
                subprocess.run([*command, 'cleanup-relay', json.loads(identity.read_text())['machineId'], args.origin],
                               env=environment, check=True, timeout=120)


if __name__ == '__main__':
    main()
