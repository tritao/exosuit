#!/usr/bin/env python3
"""Under Xvfb: compact Workbench, group actions and directory-scoped thread attachment."""
import json
import os
from pathlib import Path
import signal
import sys
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
INSTALL = Path(sys.argv[1]).resolve(strict=True) if len(sys.argv) > 1 else None
RUNNER = [str(INSTALL / 'exosuit')] if INSTALL else [str(ROOT / 'scripts/run.sh')]
with tempfile.TemporaryDirectory(prefix='exactions-') as temporary:
    fixture = Path(temporary)
    project = fixture / 'project'; project.mkdir()
    state = fixture / 'state'
    (project / 'fake-codex.json').write_text(json.dumps({'starts': 0, 'prompts': 0, 'threads': {
        'existing': {'id': 'existing', 'name': 'Existing work', 'cwd': str(project), 'status': {'type': 'idle'}, 'turn': None},
        'foreign': {'id': 'foreign', 'name': 'Other directory', 'cwd': str(fixture), 'status': {'type': 'idle'}, 'turn': None}}}))
    environment = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(fixture / 'settings'),
                       EXOSUIT_CODEX_BIN=str(ROOT / 'tests/workspace-agents/fake-codex.py'),
                       EXOSUIT_AGENT_LAUNCHER=str(INSTALL / 'tools/run-agent.py' if INSTALL else ROOT / 'scripts/run-agent.py'))
    if INSTALL: environment.update(HAXEON_BIN='/no/source/compiler', HAXEON_ROOT='/no/source/tree', LD_LIBRARY_PATH='')
    app = None
    def layout(index): return json.loads((fixture / str(index) / 'layout.json').read_text())
    def locate(nodes, label):
        matching = [node for node in nodes if node.get('label') == label and node['visible'] and node.get('focusable')]
        assert matching, (label, [node.get('label') for node in nodes if node['visible']])
        return matching[0]['bounds']
    def click(window, bounds):
        subprocess.run(['xdotool', 'mousemove', '--window', window,
                        str(round(bounds['x'] + bounds['width'] / 2)), str(round(bounds['y'] + bounds['height'] / 2)), 'click', '1'], check=True)
    try:
        for index in range(5):
            with (fixture / ('app-' + str(index) + '.log')).open('w') as log:
                app = subprocess.Popen([*RUNNER, str(project), '--open-workbench',
                                        '--capture-dir=' + str(fixture / str(index)), '--capture-seconds=6'],
                                       cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
                window = subprocess.check_output(['timeout', '60', 'xdotool', 'search', '--sync', '--onlyvisible', '--name', '^exosuit$'], text=True).splitlines()[0]
                subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True); time.sleep(1.5)
                if index >= 1:
                    click(window, locate(layout(0), 'Workbench actions')); time.sleep(.3)
                if index >= 2:
                    click(window, locate(layout(1), 'Attach existing Codex thread…')); time.sleep(1)
                if index == 3:
                    click(window, locate(layout(2), 'Search Codex threads'))
                    subprocess.run(['xdotool', 'type', '--clearmodifiers', 'unmatched-title'], check=True)
                if index == 4:
                    click(window, locate(layout(2), 'Existing work'))
                assert app.wait(timeout=90) == 0, (fixture / ('app-' + str(index) + '.log')).read_text()[-4000:]
                app = None
            nodes = layout(index)
            labels = [node.get('label') for node in nodes if node['visible']]
            if index == 0:
                assert 'Workbench actions' in labels and 'New terminal' in labels and 'New Codex' in labels
                assert 'New group' not in labels and 'Manage terminals…' not in labels and 'Existing Codex thread id' not in labels
                # The group row is near the toolbar, with no permanent attachment form above it.
                groups = [node for node in nodes if node.get('label') == 'g:work' and node['visible']]
                assert groups and groups[0]['bounds']['y'] < 150, groups
            if index == 1: assert all(label in labels for label in ['New group', 'Edit group', 'Open folder', 'Manage terminals…'])
            if index == 2:
                assert 'Existing work' in labels and 'Other directory' not in labels and 'Existing Codex thread id' in labels, labels
                assert (project / 'fake-codex.json').exists()
            if index == 3: assert 'No matching threads.' in labels and 'Existing work' not in labels
            if index == 4:
                diagnostic = json.loads((fixture / str(index) / 'app-state.json').read_text())
                records = diagnostic['agentCatalog']['records']
                assert len(records) == 1 and records[0]['thread'] == 'existing' and records[0]['group'] == 'work', diagnostic
                assert len(diagnostic['agentTabs']) == 1, diagnostic
        print('PASS: compact Workbench, contextual group actions, scoped discovery, search and explicit existing-thread attachment')
    except Exception:
        for path in fixture.glob('app-*.log'): print(path.name + '\n' + path.read_text()[-3000:])
        raise
    finally:
        if app is not None and app.poll() is None: app.terminate(); app.wait(timeout=10)
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try: os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError): pass
