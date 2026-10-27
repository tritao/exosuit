#!/usr/bin/env python3
"""Xvfb desktop matrix: provider picker, toolbar, creation, and reattachment in both modes."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from agent_test_runtime import manager_environment

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--provider', choices=['codex', 'claude'])
parser.add_argument('--mode', choices=['integrated', 'terminal'])
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--legacy-agent', type=Path)
options = parser.parse_args()
if not options.skip_build:
    for project_file in ['agent/haxeon.json', 'graphical/haxeon.json']:
        subprocess.run([str(ROOT/'haxeon/scripts/haxeon'), 'build', '--project', str(ROOT/project_file)], check=True)
runner = [str(ROOT/'haxeon/.tools/hashlink/hl'), str(ROOT/'graphical/build/host/main.hl')]


def scenario(provider, mode):
    with tempfile.TemporaryDirectory(prefix=f'exagent-{provider}-{mode}-') as temporary:
        fixture = Path(temporary)
        project = fixture/'project'
        project.mkdir()
        state = fixture/'state'
        settings = fixture/'settings'
        settings.mkdir()
        (settings/'settings.json').write_text(json.dumps({'values': {'workbench/agents/session_mode': mode}}))
        legacy = options.legacy_agent.resolve(strict=True) if options.legacy_agent else None
        environment = dict(manager_environment(ROOT, legacy), XDG_STATE_HOME=str(state),
                           PRAGTICAL_PORTABLE=str(settings), HAXEON_ROOT=str(ROOT/'haxeon'),
                           EXOSUIT_CODEX_PROXY_LAUNCHER=str(ROOT/'scripts/run-codex-proxy.py'))
        for name in ['codex', 'claude']:
            if mode == 'terminal':
                script = fixture/f'{name}-terminal.py'
                script.write_text('import json,os,sys\nfrom pathlib import Path\n'
                                  f'with Path("terminal-launches.jsonl").open("a") as log: log.write(json.dumps({{"provider":"{name}","pid":os.getpid()}})+"\\n")\n'
                                  f'print("EXOSUIT_{name.upper()}_TERMINAL_READY",flush=True)\n'
                                  'for line in sys.stdin: print("ECHO:"+line.strip(),flush=True)\n')
            else:
                script = ROOT/f'tests/{"workspace" if name == "codex" else "claude"}-agents/fake-{name}.py'
            environment[f'EXOSUIT_{name.upper()}_BIN'] = sys.executable
            environment[f'EXOSUIT_{name.upper()}_SCRIPT'] = str(script)
        native = ROOT/'graphical/build/host/native'
        environment['LD_LIBRARY_PATH'] = ':'.join([str(p) for p in sorted(native.iterdir()) if p.is_dir()]
                                                  + [environment.get('LD_LIBRARY_PATH', '')])
        if legacy:
            environment['EXOSUIT_AGENT_MANAGED_UPDATES'] = '0'
            environment['EXOSUIT_PROJECT_ROOT'] = str(legacy.parents[3])
        app = None

        def nodes(index):
            return json.loads((fixture/str(index)/'layout.json').read_text())

        def locate(index, label):
            found = [n for n in nodes(index) if n.get('label') == label and n['visible'] and n.get('focusable')]
            assert found, (label, [n.get('label') for n in nodes(index) if n['visible']])
            return found[0]['bounds']

        def click(window, bounds):
            subprocess.run(['xdotool', 'mousemove', '--window', window,
                            str(round(bounds['x']+bounds['width']/2)), str(round(bounds['y']+bounds['height']/2)),
                            'click', '1'], check=True)

        try:
            for index in range(3 if legacy else 4):
                with (fixture/f'app-{index}.log').open('w') as log:
                    app = subprocess.Popen([*runner, str(project), '--open-workbench',
                                            '--capture-dir='+str(fixture/str(index)), '--capture-seconds=7'],
                                           cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
                    window = subprocess.check_output(['timeout', '60', 'xdotool', 'search', '--sync', '--onlyvisible',
                                                      '--name', '^exosuit$'], text=True).splitlines()[0]
                    subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
                    time.sleep(2)
                    if index in (1, 2):
                        click(window, locate(0, 'Workbench actions'))
                        time.sleep(.3)
                    if index == 2:
                        click(window, locate(1, 'New Agent Session…'))
                        time.sleep(.4)
                        # Select the provider in the same command view a user sees.
                        subprocess.run(['xdotool', 'type', '--clearmodifiers', provider], check=True)
                        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'Return'], check=True)
                    if index == 3 and provider == 'codex':
                        # The toolbar must obey the same mode as the provider picker.
                        click(window, locate(0, 'New Codex'))
                    assert app.wait(timeout=90) == 0, (fixture/f'app-{index}.log').read_text()[-4000:]
                    app = None
                if index < 2:
                    continue
                diagnostic = json.loads((fixture/str(index)/'app-state.json').read_text())
                records = (diagnostic.get('agentCatalog') or {}).get('records', [])
                if legacy:
                    assert not records and not diagnostic['agentTabs'], diagnostic
                    assert any('does not support Claude sessions' in (n.get('label') or '') and n['visible'] for n in nodes(index)), nodes(index)
                    assert not (project/'wire.jsonl').exists(), 'Unsupported create launched a CLI'
                    continue
                expected = 2 if index == 3 and provider == 'codex' else 1
                assert not diagnostic['errors'], diagnostic['errors']
                if mode == 'integrated':
                    assert len(records) == expected and all((r.get('provider') or 'codex') == provider for r in records), diagnostic
                    assert len(diagnostic['agentTabs']) == expected and not diagnostic['terminalEditorTabs'], diagnostic
                    assert diagnostic['workbenchSelectedNode'].startswith('a:'), diagnostic
                    prompt = 'Codex prompt' if provider == 'codex' else 'Claude prompt'
                    assert any(n.get('label') == prompt and n['visible'] and n.get('focused') for n in nodes(index)), nodes(index)
                else:
                    terminals = diagnostic['terminalCatalog']['terminals']
                    assert not records and not diagnostic['agentTabs'], diagnostic
                    assert len(terminals) == expected and all(t['agentProvider'] == provider for t in terminals), diagnostic
                    assert len(diagnostic['terminalEditorTabs']) == expected, diagnostic
                    assert diagnostic['workbenchSelectedNode'].startswith('t:'), diagnostic
                    screen = diagnostic.get('terminalScreen') or {}
                    assert f'EXOSUIT_{provider.upper()}_TERMINAL_READY' in '\n'.join(screen.get('lines', [])), screen
                    launches = [json.loads(v) for v in (project/'terminal-launches.jsonl').read_text().splitlines()]
                    assert len(launches) == expected and all(v['provider'] == provider for v in launches), launches
            print(f'PASS: {provider}/{mode} picker creation, editor tab, reattachment'
                  + (' and toolbar creation' if provider == 'codex' else '')
                  + ('; legacy update error without side effects' if legacy else ''), flush=True)
        except Exception:
            for path in sorted(fixture.glob('app-*.log')):
                print(path.name+'\n'+path.read_text()[-4000:])
            raise
        finally:
            if app is not None and app.poll() is None:
                app.terminate()
                app.wait(timeout=10)
            for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
                try:
                    os.kill(json.loads(endpoint.read_text())['managerPid'], signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError):
                    pass


if options.legacy_agent:
    scenario('claude', 'integrated')
else:
    for mode in ([options.mode] if options.mode else ['integrated', 'terminal']):
        for provider in ([options.provider] if options.provider else ['codex', 'claude']):
            scenario(provider, mode)
