#!/usr/bin/env python3
"""Run under Xvfb: actual desktop terminal restores the same daemon-owned shell."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
HAXEON=os.environ.get('HAXEON_BIN',str(Path(os.environ.get('HAXEON_ROOT',str(ROOT.parent/'haxeon')))/'scripts/haxeon'))
INSTALL=Path(sys.argv[1]).resolve(strict=True) if len(sys.argv)>1 else None
MODE=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED')=='1' else []
with tempfile.TemporaryDirectory(prefix='exttyui-') as temporary:
    fixture=Path(temporary); project=fixture/'project'; project.mkdir(); state=fixture/'state'
    environment=dict(os.environ,XDG_STATE_HOME=str(state),PRAGTICAL_PORTABLE=str(fixture/'settings'),SHELL='/bin/sh',EXOSUIT_AGENT_LAUNCHER=str(ROOT/'scripts/run-agent.py'))
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    if INSTALL:
        environment.pop('EXOSUIT_AGENT_LAUNCHER',None)
        environment.update(HAXEON_BIN='/no/source/compiler',HAXEON_ROOT='/no/source/tree',LD_LIBRARY_PATH='')
    app=None
    try:
        for index in range(2):
            capture=fixture/str(index)
            with (fixture/('app-'+str(index)+'.log')).open('w') as log:
                runner=[str(INSTALL/'exosuit')] if INSTALL else [HAXEON,'run','--project',str(ROOT/'graphical/haxeon.json'),*MODE,'--']
                app=subprocess.Popen([*runner,str(project),'--open-terminal','--capture-dir='+str(capture),'--capture-seconds=10'],cwd=fixture if INSTALL else ROOT,env=environment,stdout=log,stderr=subprocess.STDOUT)
                window=subprocess.check_output(['timeout','45','xdotool','search','--sync','--onlyvisible','--name','^exosuit$'],text=True).splitlines()[0]
                subprocess.run(['xdotool','windowfocus','--sync',window],check=True)
                time.sleep(2)
                command="KEEP=desktop; printf '%s\\n' $$ > shell-pid; sleep 12; printf 'WHILE_%s\\n' DETACHED; printf detached > detached-output" if index==0 else "printf '%s %s\\n' \"$KEEP\" $$ > reattached; exit 0"
                subprocess.run(['xdotool','type','--clearmodifiers','--delay','2',command],check=True)
                subprocess.run(['xdotool','key','Return'],check=True)
                assert app.wait(timeout=30)==0,(fixture/('app-'+str(index)+'.log')).read_text()[-4000:]
            snapshot=json.loads((capture/'app-state.json').read_text())
            assert snapshot['workspaceConnection']=='Workspace connected',snapshot
            assert not snapshot['errors'],snapshot
            if index==0:
                assert (project/'shell-pid').exists(),'Desktop terminal did not accept input'
                entries=list(state.glob('exosuit/workspaces/*/endpoint.json'))
                assert len(entries)==1
                first=json.loads(entries[0].read_text())
                deadline=time.monotonic()+20
                while not (project/'detached-output').exists() and time.monotonic()<deadline:
                    assert entries[0].exists(), 'Daemon stopped while terminal was active'
                    time.sleep(.05)
                assert (project/'detached-output').exists(), 'PTY stopped executing after window shutdown'
                assert entries[0].exists(),'Active shell was killed with the window'
            else:
                assert (project/'reattached').read_text().strip()=='desktop '+(project/'shell-pid').read_text().strip(),'Desktop recreated shell ('+str(snapshot['terminalIds'])+'): ' + (project/'reattached').read_text() + ' expected desktop ' + (project/'shell-pid').read_text()
        print('PASS: actual desktop restores terminal ID, shell PID and environment after window shutdown',flush=True)
    finally:
        if app and app.poll() is None: app.terminate(); app.wait(timeout=10)
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try: os.kill(json.loads(endpoint.read_text())['managerPid'],signal.SIGTERM)
            except (FileNotFoundError,ProcessLookupError): pass
        deadline=time.monotonic()+10
        while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic()<deadline: time.sleep(.05)
