#!/usr/bin/env python3
"""Under Xvfb: one native click leaves a mouse-tracking terminal for workbench controls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'tests/context-menu-ui-smoke/haxeon.json'

subprocess.run([str(ROOT / 'haxeon/scripts/haxeon'), 'build', '--project', str(PROJECT)], check=True)
native = PROJECT.parent / 'build/host/native'
libraries = [ROOT / 'haxeon/out', ROOT / 'haxeon/.tools/hashlink',
             *sorted(p for p in native.iterdir() if p.is_dir())]
for placement in ('panel', 'editor'):
    with tempfile.TemporaryDirectory(prefix='terminal-workbench-click-') as temporary:
        fixture = Path(temporary)
        (fixture / 'Main.hx').write_text('class Main {}\n')
        shell = fixture / 'mouse-shell'
        shell.write_text("#!/bin/sh\nprintf '\\033[?1003h\\033[?1006hTUI mouse tracking ready\\n'\nexec /bin/sh\n")
        shell.chmod(0o755)
        env = dict(os.environ, SHELL=str(shell), EXOSUIT_MENU_TERMINAL=placement,
                   PRAGTICAL_PORTABLE=str(fixture / 'settings'), XDG_STATE_HOME=str(fixture / 'state'),
                   LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)))
        with (fixture / 'app.log').open('w') as log:
            app = subprocess.Popen([str(ROOT / 'haxeon/.tools/hashlink/hl'),
                                    str(PROJECT.parent / 'build/host/main.hl'), str(fixture)],
                                   cwd=ROOT, env=env, stdout=log, stderr=log)
            state = {}

            def wait(predicate, message):
                global state
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((fixture / 'state.json').read_text())
                        if predicate(state):
                            return
                    except (OSError, ValueError):
                        pass
                    assert app.poll() is None, (fixture / 'app.log').read_text()[-3000:]
                    time.sleep(.03)
                raise AssertionError((placement, message, state))

            def xdo(*args):
                return subprocess.check_output(['xdotool', *map(str, args)], text=True).strip()

            def node(key):
                return next(n for n in state['nodes'] if n['key'] == key and n['width'] > 0)

            def move(target, offset=0):
                xdo('mousemove', '--window', window,
                    int(target['x'] + target['width'] / 2 + offset), int(target['y'] + target['height'] / 2))

            def focus_terminal():
                terminal = node('terminal-pane')
                move(terminal)
                xdo('click', 1)
                wait(lambda s: s['focusKey'] == 'terminal-pane', 'Terminal did not gain focus')
                move(terminal, 5)
                time.sleep(.06)

            try:
                wait(lambda s: any(n['key'] == 'terminal-pane' for n in s['nodes']), 'No terminal')
                window = xdo('search', '--onlyvisible', '--name', '^Context menu native input smoke$').splitlines()[-1]
                xdo('windowfocus', '--sync', window)
                time.sleep(.3)
                for _ in range(3):
                    focus_terminal()
                    move(node('layout-menu'))
                    xdo('click', 1)
                    wait(lambda s: s['menuOpen'], 'First Layout click was swallowed')
                    xdo('key', 'Escape')
                    wait(lambda s: not s['menuOpen'], 'Layout did not dismiss')
                    focus_terminal()
                    activity = next(n for n in state['nodes'] if isinstance(n['key'], str)
                                    and n['key'].startswith('activity:') and n['key'][9:] != state['activityId'])
                    move(activity)
                    xdo('click', 1)
                    wait(lambda s: s['activityId'] == activity['key'][9:] and s['sidebarVisible'],
                         'First sidebar click was swallowed')
                print('PASS: single native Layout/sidebar clicks after mouse-tracking terminal focus: ' + placement)
            finally:
                app.terminate()
                app.wait(timeout=10)
