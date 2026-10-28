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
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

ROOT = Path(__file__).resolve().parent.parent
INSTALL = Path(sys.argv[1]).resolve(strict=True) if len(sys.argv) > 1 else None
RUNNER = [str(INSTALL / 'exosuit')] if INSTALL else [str(ROOT / 'scripts/run.sh')]
with tempfile.TemporaryDirectory(prefix='exactions-') as temporary:
    fixture = Path(temporary)
    project = fixture / 'project'; project.mkdir()
    state = fixture / 'state'
    (fixture / 'settings').mkdir()
    (fixture / 'settings/settings.json').write_text(json.dumps({'values': {'workbench/agents/session_mode': 'integrated'}}))
    (project / 'fake-codex.json').write_text(json.dumps({'starts': 0, 'prompts': 0, 'threads': {
        'existing': {'id': 'existing', 'name': 'Existing work', 'cwd': str(project), 'status': {'type': 'idle'}, 'turn': None},
        'foreign': {'id': 'foreign', 'name': 'Other directory', 'cwd': str(fixture), 'status': {'type': 'idle'}, 'turn': None}}}))
    environment = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(fixture / 'settings'),
                       EXOSUIT_CODEX_BIN=str(ROOT / 'tests/workspace-agents/fake-codex.py'),
                       EXOSUIT_AGENT_LAUNCHER=str(INSTALL / 'tools/exosuit-agent.hl' if INSTALL else ROOT / 'agent/build/host/main.hl'))
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
        for index in range(9):
            with (fixture / ('app-' + str(index) + '.log')).open('w') as log:
                app = subprocess.Popen([*RUNNER, str(project), '--open-workbench',
                                        '--capture-dir=' + str(fixture / str(index)), '--capture-seconds=9'],
                                       cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
                window = subprocess.check_output(['timeout', '60', 'xdotool', 'search', '--sync', '--onlyvisible', '--name', '^exosuit$'], text=True).splitlines()[0]
                subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True); time.sleep(2)
                if 1 <= index <= 4:
                    click(window, locate(layout(0), 'Workbench actions')); time.sleep(.3)
                if 2 <= index <= 4:
                    click(window, locate(layout(1), 'Attach existing Codex thread…')); time.sleep(1)
                if index == 3:
                    click(window, locate(layout(2), 'Search Codex threads'))
                    subprocess.run(['xdotool', 'type', '--clearmodifiers', 'unmatched-title'], check=True)
                if index == 4:
                    click(window, locate(layout(2), 'Existing work'))
                if index in (5, 6, 7):
                    nodes = layout(0)
                    group = next(n for n in nodes if n.get('label') == 'g:work' and n['visible'])['bounds']
                    subprocess.run(['xdotool', 'mousemove', '--window', window, str(round(group['x'] + group['width']/2)), str(round(group['y'] + group['height']/2)), 'click', '3'], check=True)
                    time.sleep(.4)
                    if index == 7: click(window, locate(layout(5), 'Change Sort Order…'))
                    if index == 6:
                        click(window, locate(layout(5), 'New Agent Session…')); time.sleep(.4)
                        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'Return'], check=True)
                if index == 8:
                    diagnostic = json.loads((fixture / '6/app-state.json').read_text())
                    agent_id = diagnostic['agentCatalog']['records'][0]['id']
                    node = next(n for n in layout(6) if n.get('label') == 'a:' + agent_id and n['visible'])['bounds']
                    subprocess.run(['xdotool', 'mousemove', '--window', window, str(round(node['x'] + node['width']/2)), str(round(node['y'] + node['height']/2)), 'click', '3'], check=True)
                assert app.wait(timeout=90) == 0, (fixture / ('app-' + str(index) + '.log')).read_text()[-4000:]
                app = None
            nodes = layout(index)
            labels = [node.get('label') for node in nodes if node['visible']]
            if index == 0:
                assert 'Workbench actions' in labels and 'New terminal' in labels and 'New Codex' in labels
                header = next(node['bounds'] for node in nodes if node.get('label') == 'Workbench' and node['visible'])
                for label in ['New terminal', 'New Codex', 'Workbench actions']:
                    action = next(node['bounds'] for node in nodes if node.get('label') == label and node['visible'])
                    assert header['y'] <= action['y'] + action['height'] / 2 <= header['y'] + header['height'], (label, header, action)
                    assert action['x'] >= header['x'] + header['width'], (label, header, action)
                assert not any(label and ('codex-tui/' in label or 'Codex · on demand' in label) for label in labels), labels
                assert 'New group' not in labels and 'Manage terminals…' not in labels and 'Existing Codex thread id' not in labels
                # The group row is near the toolbar, with no permanent attachment form above it.
                groups = [node for node in nodes if node.get('label') == 'g:work' and node['visible']]
                assert groups and groups[0]['bounds']['y'] < 150, (groups, json.loads((fixture / str(index) / 'app-state.json').read_text()))
            if index == 1: assert all(label in labels for label in ['New Agent Session…', 'New terminal', 'New group', 'Rename group', 'Change Working Directory…', 'Change Sort Order…', 'Open folder', 'Refresh Workbench']), labels
            if index == 2:
                assert 'Existing work' in labels and 'Other directory' not in labels and 'Existing Codex thread id' in labels, labels
                assert (project / 'fake-codex.json').exists()
            if index == 3: assert 'No matching threads.' in labels and 'Existing work' not in labels
            if index == 4:
                diagnostic = json.loads((fixture / str(index) / 'app-state.json').read_text())
                records = diagnostic['agentCatalog']['records']
                assert len(records) == 1 and records[0]['thread'] == 'existing' and records[0]['group'] == 'work', diagnostic
                assert len(diagnostic['agentTabs']) == 1, diagnostic
            if index == 5:
                # Group actions sit directly in the menu; an occupied top-level group cannot move or be removed.
                assert not any(label in labels for label in ['More Group Actions…', 'Remove Group', 'Move to Group…', 'Refresh Workbench', 'New Pi session', 'New Claude session']), labels
                assert all(label in labels for label in ['New Agent Session…', 'New terminal', 'New group', 'Rename group', 'Change Working Directory…', 'Change Sort Order…']), labels
            if index == 7:
                # Choosing the item runs the action itself: the menu closes into the sort-order prompt.
                assert 'Change Sort Order…' not in labels and 'Rename group' not in labels, labels
            if index == 8:
                assert 'Open agent session' in labels and 'Remove from Workbench' in labels, labels
                assert not any(label in labels for label in ['New group', 'Rename group', 'Change Working Directory…', 'Refresh Workbench', 'New Agent Session…']), labels
            if index == 6:
                diagnostic = json.loads((fixture / str(index) / 'app-state.json').read_text())
                assert len(diagnostic['agentCatalog']['records']) == 2, diagnostic
                assert all(record['group'] == 'work' for record in diagnostic['agentCatalog']['records']), diagnostic
                created = next(record for record in diagnostic['agentCatalog']['records'] if record['thread'] != 'existing')
                assert diagnostic['workbenchSelectedNode'] == 'a:' + created['id'], diagnostic
                assert any(node.get('label') == 'Codex prompt' and node.get('focused') for node in nodes), nodes
                assert any((node.get('label') or '').startswith(created['name'] + ' · ') and node['visible'] for node in nodes), nodes
        print('PASS: compact Workbench, contextual group actions, scoped discovery, search and explicit existing-thread attachment')
    except Exception:
        for path in fixture.glob('app-*.log'): print(path.name + '\n' + path.read_text()[-3000:])
        raise
    finally:
        if app is not None and app.poll() is None: app.terminate(); app.wait(timeout=10)
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try: os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError): pass
