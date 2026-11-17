#!/usr/bin/env python3
"""WorkspaceLink against real workspace services, started the way suit starts them: shared verified reuse, a link that
refuses a service it was not told about, independent closing, and what a link does when its service is killed."""
from pathlib import Path
import tempfile

from test_driver import ROOT, build_test, isolated_environment, launcher_path, run_tree, running_services, stop_services

LAUNCHER = launcher_path(ROOT)
RUNNER = build_test('workspace-attachment')

with tempfile.TemporaryDirectory(prefix='exa-', ignore_cleanup_errors=True) as temporary:
    directory = Path(temporary)
    root, state = directory / 'project', directory / 'state'
    root.mkdir(parents=True)
    environment = isolated_environment(state, LAUNCHER, 'workspace-attachment')
    try:
        for mode in ['link', 'restart']:
            run_tree([*RUNNER, mode, str(root), str(LAUNCHER)], environment, timeout=200)
        assert len(running_services(state)) == 1, 'one workspace ran more than one service'
    finally:
        stop_services(state)
