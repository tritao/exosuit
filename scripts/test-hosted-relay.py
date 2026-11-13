#!/usr/bin/env python3
"""Explicit opt-in native HTTPS/WSS acceptance against an existing hosted relay."""
import argparse
import json
from pathlib import Path
import tempfile

from agent_test_runtime import launcher_path
from test_driver import ROOT, build_test, isolated_environment, run_tree, stop_managers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('origin', help='Hosted HTTPS relay origin to exercise')
    args = parser.parse_args()
    if not args.origin.startswith('https://'):
        parser.error('Expected an HTTPS relay origin')
    runner = build_test('workspace-attachment')
    launcher = launcher_path(ROOT)
    with tempfile.TemporaryDirectory(prefix='exa-live-', ignore_cleanup_errors=True) as temporary:
        base = Path(temporary)
        project, state = base / 'project', base / 'state'
        project.mkdir()
        environment = isolated_environment(state, launcher, 'workspace-attachment')
        try:
            run_tree([*runner, 'relay-live', str(project), str(launcher), args.origin], environment, timeout=150)
        finally:
            stop_managers(state, timeout=10)
            for identity in state.glob('exosuit/workspaces/*/relay-machine.json'):
                run_tree([*runner, 'cleanup-relay', json.loads(identity.read_text())['machineId'], args.origin],
                         environment, timeout=120)


if __name__ == '__main__':
    main()
