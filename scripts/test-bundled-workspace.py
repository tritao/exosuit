#!/usr/bin/env python3
"""Exercise an installed runtime outside its source tree, including default idle cleanup."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

install = Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='exbundle-') as temporary:
    fixture = Path(temporary)
    project = fixture / 'project with spaces'; project.mkdir()
    (project / 'sample.txt').write_text('Bundled workspace service\n')
    state = fixture / 'state'
    environment = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(fixture / 'settings'), LD_LIBRARY_PATH='', HAXEON_BIN='/no/source/compiler', HAXEON_ROOT='/no/source/tree')
    for name in ['EXOSUIT_AGENT_LAUNCHER', 'EXOSUIT_AGENT_ALWAYS_AVAILABLE', 'HAXEON_LSP']:
        environment.pop(name, None)
    def endpoints():
        return list(state.glob('exosuit/workspaces/*/endpoint.json'))
    try:
        generation = None
        for index in range(2):
            capture = fixture / str(index)
            subprocess.run(['xvfb-run', '-a', str(install / 'exosuit'), str(project), str(project / 'sample.txt'), '--capture-dir=' + str(capture), '--capture-seconds=10'], cwd=fixture, env=environment, check=True, timeout=40)
            assert 'Workspace connected' in (capture / 'ui-tree.txt').read_text(), 'Installed editor did not attach'
            assert len(endpoints()) == 1, 'Window shutdown discarded the service before grace'
            descriptor = json.loads(endpoints()[0].read_text())
            assert descriptor['root'] == str(project)
            if generation is not None:
                assert descriptor['generation'] == generation, 'Second window replaced shared daemon'
            generation = descriptor['generation']
        print('PASS: relocated editor starts and reuses bundled daemon without source/compiler access', flush=True)
        directory = endpoints()[0].parent
        assert 'compile-project' not in (directory / 'manager.log').read_text(), 'Bundle depended on source compilation'
        deadline = time.monotonic() + 75
        while endpoints() and time.monotonic() < deadline:
            time.sleep(0.1)
        assert not endpoints(), 'Bundled daemon did not stop after default idle grace'
        assert (directory / 'catalog.sqlite').exists() and not (directory / 'agent.sock').exists()
        print('PASS: bundled default idle shutdown removes discovery/socket and retains catalog', flush=True)
    finally:
        for endpoint in endpoints():
            try:
                os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
        deadline = time.monotonic() + 10
        while endpoints() and time.monotonic() < deadline:
            time.sleep(0.05)
