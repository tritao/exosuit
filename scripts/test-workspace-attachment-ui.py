#!/usr/bin/env python3
"""Real desktop composition: background attachment, window-independent lifetime, reuse."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
HAXEON = os.environ.get('HAXEON_BIN', str(Path(os.environ.get('HAXEON_ROOT', str(ROOT.parent / 'haxeon'))) / 'scripts/haxeon'))
MODE = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
with tempfile.TemporaryDirectory(prefix='exui-') as temporary:
    fixture = Path(temporary)
    project = fixture / 'project'
    project.mkdir()
    (project / 'sample.txt').write_text('Workspace attachment smoke\n')
    state = fixture / 'state'
    environment = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(fixture / 'settings'), EXOSUIT_AGENT_LAUNCHER=str(ROOT / 'scripts/run-agent.py'))
    try:
        previous = None
        for index in range(2):
            capture = fixture / str(index)
            subprocess.run(['xvfb-run', '-a', HAXEON, 'run', '--project', str(ROOT / 'graphical/haxeon.json'), *MODE, '--', str(project), str(project / 'sample.txt'), '--capture-dir=' + str(capture), '--capture-seconds=10'], env=environment, check=True, timeout=180)
            assert 'Workspace connected' in (capture / 'ui-tree.txt').read_text(), 'Desktop did not attach'
            metrics = json.loads((capture / 'frame-metrics.json').read_text())
            assert metrics['renderedFrames'] <= 40, 'Attachment caused continuous redraws'
            endpoints = list(state.glob('exosuit/workspaces/*/endpoint.json'))
            assert len(endpoints) == 1, 'Daemon did not survive window shutdown'
            descriptor = json.loads(endpoints[0].read_text())
            if previous is not None:
                assert descriptor['generation'] == previous, 'Second window replaced the live daemon'
            previous = descriptor['generation']
        print('PASS: desktop background attachment, bounded redraws and daemon reuse across windows', flush=True)
    finally:
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try:
                os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
        deadline = time.monotonic() + 10
        while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic() < deadline:
            time.sleep(0.05)
