#!/usr/bin/env python3
"""Run under Xvfb: discover a shell with no saved tab, reopen it, then restore its view."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get('HAXEON_ROOT', str(ROOT / 'haxeon')))
HAXEON = os.environ.get('HAXEON_BIN', str(HOME / 'scripts/haxeon'))
MODE = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
INSTALL = Path(sys.argv[1]).resolve(strict=True) if len(sys.argv) > 1 else None
OUTPUT = ROOT / 'tests/workspace-terminals/build/host'
subprocess.run([HAXEON, 'build', '--project', str(ROOT / 'tests/workspace-terminals/haxeon.json'), *MODE], check=True)
with tempfile.TemporaryDirectory(prefix='extcatui-') as temporary:
    fixture = Path(temporary); project = fixture / 'project'; project.mkdir(); state = fixture / 'state'
    launcher = INSTALL / 'tools/run-agent.py' if INSTALL else ROOT / 'scripts/run-agent.py'
    environment = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(fixture / 'settings'), SHELL='/bin/sh', EXOSUIT_AGENT_LAUNCHER=str(launcher))
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE', None)
    if INSTALL:
        environment.update(HAXEON_BIN='/no/source/compiler', HAXEON_ROOT='/no/source/tree', LD_LIBRARY_PATH='')
    client_environment = dict(environment)
    libraries = [HOME / 'out', HOME / '.tools/hashlink', *sorted(path for path in (OUTPUT / 'native').iterdir() if path.is_dir())]
    client_environment['LD_LIBRARY_PATH'] = ':'.join(str(path) for path in libraries)
    app = None
    try:
        subprocess.run([str(HOME / '.tools/hashlink/hl'), str(OUTPUT / 'main.hl'), 'create', str(project), str(launcher)], env=client_environment, check=True, timeout=100)
        for index in range(3):
            capture = fixture / str(index)
            runner = [str(INSTALL / 'exosuit')] if INSTALL else [HAXEON, 'run', '--project', str(ROOT / 'graphical/haxeon.json'), *MODE, '--']
            arguments = ['--open-workspace-terminals'] if index < 2 else []
            with (fixture / ('app-' + str(index) + '.log')).open('w') as log:
                app = subprocess.Popen([*runner, str(project), *arguments, '--capture-dir=' + str(capture), '--capture-seconds=10'], cwd=fixture if INSTALL else ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
                window = subprocess.check_output(['timeout', '60', 'xdotool', 'search', '--sync', '--onlyvisible', '--name', '^exosuit$'], text=True).splitlines()[0]
                subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
                time.sleep(3)
                if index == 1:
                    layout = json.loads((fixture / '0/layout.json').read_text())
                    buttons = [node for node in layout if node.get('label') == 'Open' and node['visible'] and node['enabled'] and node['bounds']['y'] > 80]
                    assert len(buttons) == 1, buttons
                    bounds = buttons[0]['bounds']
                    subprocess.run(['xdotool', 'mousemove', '--window', window, str(round(bounds['x'] + bounds['width'] / 2)), str(round(bounds['y'] + bounds['height'] / 2)), 'click', '1'], check=True)
                    time.sleep(1)
                if index > 0:
                    command = "printf '%s %s\\n' \"$KEEP\" $$ > " + ('browser-reattached' if index == 1 else 'browser-restored') + ('; exit 0' if index == 2 else '')
                    subprocess.run(['xdotool', 'type', '--clearmodifiers', '--delay', '2', command], check=True)
                    subprocess.run(['xdotool', 'key', 'Return'], check=True)
                assert app.wait(timeout=40) == 0, (fixture / ('app-' + str(index) + '.log')).read_text()[-5000:]
            snapshot = json.loads((capture / 'app-state.json').read_text())
            assert not snapshot['errors'], snapshot
            if index == 0:
                records = snapshot['terminalCatalog']['terminals']
                assert len(records) == 1 and records[0]['id'] == 'test-terminal' and records[0]['available'], snapshot
                assert 'test-terminal' not in snapshot['terminalIds'], 'Catalog discovery silently opened a tab'
            else:
                result = project / ('browser-reattached' if index == 1 else 'browser-restored')
                assert result.exists(), 'Discovered/restored terminal did not accept input: ' + str(snapshot)
                assert result.read_text().strip() == 'alive ' + (project / 'shell-pid').read_text().strip(), 'Catalog attachment replaced shell state/PID'
                assert snapshot['terminalResourceIds'].count('test-terminal') == 1, 'Catalog open duplicated or lost its view'
        print('PASS: desktop discovers terminal without saved tab, Open reattaches same shell, explicit remote ownership restores arbitrary resource ID', flush=True)
    except Exception:
        for path in fixture.glob('app-*.log'):
            print(path.read_text()[-4000:], file=sys.stderr)
        raise
    finally:
        if app and app.poll() is None:
            app.terminate(); app.wait(timeout=10)
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try:
                os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
        deadline = time.monotonic() + 10
        while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic() < deadline:
            time.sleep(.05)
