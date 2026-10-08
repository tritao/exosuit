#!/usr/bin/env python3
"""Run under Xvfb: resize the actual desktop terminal and restore its daemon-owned shell."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
HAXEON_ROOT=Path(os.environ.get('HAXEON_ROOT',str(ROOT/'haxeon'))).resolve()
HAXEON=os.environ.get('HAXEON_BIN',str(HAXEON_ROOT/'scripts/haxeon'))
INSTALL=Path(sys.argv[1]).resolve(strict=True) if len(sys.argv)>1 else None
MODE=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED')=='1' else []
if not INSTALL:
    for project in ['agent','graphical']:
        subprocess.run([HAXEON,'build','--project',str(ROOT/project/'haxeon.json'),*MODE],check=True)
with tempfile.TemporaryDirectory(prefix='exttyui-') as temporary:
    fixture=Path(temporary); project=fixture/'project'; project.mkdir(); state=fixture/'state'
    environment=dict(os.environ,XDG_STATE_HOME=str(state),PRAGTICAL_PORTABLE=str(fixture/'settings'),SHELL='/bin/sh',EXOSUIT_AGENT_LAUNCHER=str(ROOT/'agent/build/host/main.hl'))
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    if INSTALL:
        environment.pop('EXOSUIT_AGENT_LAUNCHER',None)
        environment.update(HAXEON_BIN='/no/source/compiler',HAXEON_ROOT='/no/source/tree',LD_LIBRARY_PATH='')
    else:
        native=ROOT/'graphical/build/host/native'
        libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in native.iterdir() if path.is_dir())]
        environment['LD_LIBRARY_PATH']=os.pathsep.join(map(str,libraries))+(
            os.pathsep+environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
    app=None
    try:
        for index in range(2):
            capture=fixture/str(index)
            with (fixture/('app-'+str(index)+'.log')).open('w') as log:
                # Observe the app process itself. CLI output pipes can remain open
                # in detached daemon children after the window has closed.
                runner=[str(INSTALL/'exosuit')] if INSTALL else [str(HAXEON_ROOT/'.tools/hashlink/hl'),str(ROOT/'graphical/build/host/main.hl')]
                app=subprocess.Popen([*runner,str(project),'--open-terminal','--capture-dir='+str(capture),'--capture-seconds=10'],cwd=fixture if INSTALL else ROOT,env=environment,stdout=log,stderr=subprocess.STDOUT)
                window=subprocess.check_output(['timeout','45','xdotool','search','--sync','--onlyvisible','--name','^exosuit$'],text=True).splitlines()[0]
                subprocess.run(['xdotool','windowfocus','--sync',window],check=True)
                time.sleep(2)
                if index == 0:
                    # Resize requests can supersede one another while RPC output
                    # is in flight. The shell must remain usable after settling.
                    for width,height in [(420,300),(1280,840),(320,200),(800,600),(480,400),(1100,700)]*2:
                        subprocess.run(['xdotool','windowsize',window,str(width),str(height)],check=True)
                        time.sleep(.06)
                    subprocess.run(['xdotool','windowsize',window,'1280','840'],check=True)
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
        print('PASS: actual desktop survives rapid resizing and restores terminal ID, shell PID and environment after window shutdown',flush=True)
    finally:
        if app and app.poll() is None: app.terminate(); app.wait(timeout=10)
        for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
            try: os.kill(json.loads(endpoint.read_text())['managerPid'],signal.SIGTERM)
            except (FileNotFoundError,ProcessLookupError): pass
        deadline=time.monotonic()+10
        while list(state.glob('exosuit/workspaces/*/endpoint.json')) and time.monotonic()<deadline: time.sleep(.05)
