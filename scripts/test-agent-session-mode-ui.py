#!/usr/bin/env python3
"""Run under xvfb-run: global launch mode and existing CLI session preservation."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
RUNNER = [str(ROOT / 'haxeon/scripts/haxeon'), 'run', '--project', str(ROOT / 'graphical/haxeon.json'), '--']

with tempfile.TemporaryDirectory(prefix='ex-agent-mode-') as temporary:
    fixture = Path(temporary)
    project = fixture / 'project'
    project.mkdir()
    settings = fixture / 'settings'
    settings.mkdir()
    state = fixture / 'state'
    cli = fixture / 'codex'
    cli.write_text('#!/usr/bin/python3\n'
                   'import os,sys,pathlib\n'
                   'if len(sys.argv)>1:\n'
                   f' os.execv(sys.executable,[sys.executable,{str(ROOT / "tests/workspace-agents/fake-codex.py")!r},*sys.argv[1:]])\n'
                   f'p=pathlib.Path({str(project / "interactive-starts")!r})\n'
                   'p.write_text(str(int(p.read_text())+1) if p.exists() else "1")\n'
                   'print("INTERACTIVE_CODEX_READY",flush=True)\n'
                   'for line in sys.stdin: print("INPUT:"+line.strip(),flush=True)\n')
    cli.chmod(0o755)
    env = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(settings),
               EXOSUIT_CODEX_BIN=str(cli), EXOSUIT_AGENT_LAUNCHER=str(ROOT / 'agent/build/host/main.hl'))
    app = None

    def click(window, bounds):
        subprocess.run(['xdotool', 'mousemove', '--window', window,
                        str(round(bounds['x'] + bounds['width'] / 2)),
                        str(round(bounds['y'] + bounds['height'] / 2)), 'click', '1'], check=True)

    try:
        # First capture supplies toolbar coordinates; next creates a CLI session;
        # switching back creates a structured session while retaining the same CLI.
        previous = None
        generation = None
        for index, mode in enumerate(['terminal', 'terminal', 'integrated']):
            values = {} if index < 2 else {'workbench/agents/session_mode': mode}
            (settings / 'settings.json').write_text(json.dumps({'values': values}))
            capture = fixture / str(index)
            with (fixture / f'app-{index}.log').open('w') as log:
                app = subprocess.Popen([*RUNNER, str(project), '--open-workbench',
                                        '--capture-dir=' + str(capture), '--capture-seconds=8'],
                                       env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
                window = subprocess.check_output(['timeout', '60', 'xdotool', 'search', '--sync',
                                                  '--onlyvisible', '--name', '^exosuit$'], text=True).splitlines()[0]
                subprocess.run(['xdotool', 'windowsize', '--sync', window, '1280', '1000'], check=True)
                subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
                time.sleep(2)
                if previous is not None:
                    click(window, previous['testTargets']['newCodex'])
                    if mode == 'terminal':
                        time.sleep(1)
                        subprocess.run(['xdotool', 'type', '--clearmodifiers', 'hello'], check=True)
                        subprocess.run(['xdotool', 'key', 'Return'], check=True)
                assert app.wait(timeout=90) == 0, (fixture / f'app-{index}.log').read_text()[-4000:]
                app = None
            previous = json.loads((capture / 'app-state.json').read_text())
            descriptor = json.loads(next(state.glob('exosuit/workspaces/*/endpoint.json')).read_text())
            if generation is not None:
                assert descriptor['generation'] == generation, 'Window reopen restarted the workspace service'
            generation = descriptor['generation']
            if index >= 1:
                terminals = previous['terminalCatalog']['terminals']
                assert len(terminals) == 1 and terminals[0]['agentProvider'] == 'codex', previous
                assert terminals[0]['state'] == 'running', terminals
                assert (project / 'interactive-starts').read_text() == '1', 'Existing CLI restarted'
            if index == 1:
                assert not previous['agentCatalog']['records'], previous
                assert len(previous['terminalEditorTabs']) == 1, previous
                assert 'INTERACTIVE_CODEX_READY' in json.dumps(previous['terminalScreen']), previous
                assert 'INPUT:hello' in json.dumps(previous['terminalScreen']), previous
            if index == 2:
                assert len(previous['agentCatalog']['records']) == 1 and len(previous['agentTabs']) == 1, previous
        print('PASS: global Terminal/Integrated creation, interactive input, editor tabs and unchanged live CLI across mode change/window reopen')
    except Exception:
        for path in sorted(fixture.glob('app-*.log')):
            print(path.name + '\n' + path.read_text()[-4000:])
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
