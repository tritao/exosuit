#!/usr/bin/env python3
"""Two separate native editor clients share a daemon-owned shell across an idle interval."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
from agent_test_runtime import launcher_path, manager_command, manager_environment
from haxeon_cli import run_cli

MANAGER=launcher_path(ROOT)
MANAGER_COMMAND=manager_command(ROOT)
MODE=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED')=='1' else []
PROJECT=ROOT/'tests/workspace-terminals/haxeon.json'
HAXEON_ROOT=Path(os.environ.get('HAXEON_ROOT',str(ROOT/'haxeon'))).resolve()
OUTPUT=PROJECT.parent/'build/host'
RUNNER=[str(HAXEON_ROOT/'.tools/hashlink'/('hl.exe' if os.name=='nt' else 'hl')),str(OUTPUT/'main.hl')]
if run_cli(ROOT,['build','--project',str(PROJECT),*MODE])!=0: sys.exit('build failed')
# A client takes about two seconds to start (it loads the test program, then runs --discover), so a shorter idle
# lets the manager exit before the client connects, and the client then starts a 60 s manager of its own. That start is
# what takes the time on Windows; elsewhere 2 s is enough.
IDLE='6' if os.name=='nt' else '2'
def kill_tree(process):
    """Stop a child and everything it started: a timeout must not leave a manager, a shell or a PTY behind."""
    if process.poll() is not None: return
    if os.name=='nt': subprocess.run(['taskkill','/F','/T','/PID',str(process.pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    else:
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
    try: process.wait(timeout=10)
    except subprocess.TimeoutExpired: pass
def spawn(command,**options):
    return subprocess.Popen(command,start_new_session=os.name!='nt',**options)
def run_tree(command,environment,timeout=40):
    process=spawn(command,env=environment)
    try: status=process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_tree(process); raise
    if status: raise subprocess.CalledProcessError(status,command)
with tempfile.TemporaryDirectory(prefix='extty-',ignore_cleanup_errors=True) as temporary:
    fixture=Path(temporary); root=fixture/'project'; root.mkdir(); state=fixture/'state'
    environment=dict(manager_environment(ROOT, MANAGER),XDG_STATE_HOME=str(state),EXOSUIT_AGENT_STATE_HOME=str(state/'exosuit'),SHELL='/bin/sh')
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in (OUTPUT/'native').iterdir() if path.is_dir())]
    variable='PATH' if os.name=='nt' else 'LD_LIBRARY_PATH'
    environment[variable]=os.pathsep.join(str(path) for path in libraries)+(os.pathsep+environment[variable] if environment.get(variable) else '')
    def endpoints(): return list(state.glob('exosuit/workspaces/*/endpoint.json'))
    run_tree([*RUNNER,'contracts',str(root),str(MANAGER)],environment)
    with (fixture/'manager.log').open('w') as log:
        manager=spawn([*MANAGER_COMMAND,str(root),'--idle-seconds',IDLE],env=environment,stdout=log,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+90
            while not endpoints():
                assert manager.poll() is None,(fixture/'manager.log').read_text()[-5000:]
                assert time.monotonic()<deadline
                time.sleep(.05)
            descriptor=json.loads(endpoints()[0].read_text())
            for mode in ['catalog','create','attach']:
                run_tree([*RUNNER,mode,str(root),str(MANAGER)],environment)
                if mode=='create':
                    time.sleep(5)
                    assert manager.poll() is None,'Active terminal did not keep daemon alive'
                    assert json.loads(endpoints()[0].read_text())['generation']==descriptor['generation']
            assert manager.wait(timeout=12)==0,'Exited terminal prevented idle shutdown'
            assert not endpoints()
            print('PASS: PTY survives complete client-process exit; active runtime retains daemon; shell exit restores idle shutdown',flush=True)
            manager=spawn([*MANAGER_COMMAND,str(root),'--idle-seconds',IDLE],env=environment,stdout=log,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+30
            while not endpoints():
                assert manager.poll() is None and time.monotonic()<deadline
                time.sleep(.05)
            run_tree([*RUNNER,'history-create',str(root),str(MANAGER)],environment)
            if os.name=='nt':
                # terminate() is TerminateProcess here: no cleanup runs. Ask the way suit does.
                (endpoints()[0].parent/'stop-request.json').write_text(json.dumps({'version':1,'generation':json.loads(endpoints()[0].read_text())['generation']})+chr(10))
            else: manager.terminate()
            manager.wait(timeout=10)
            assert not endpoints(), 'Stopped manager retained its endpoint'
            manager=spawn([*MANAGER_COMMAND,str(root),'--idle-seconds',IDLE],env=environment,stdout=log,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+30
            while not endpoints():
                assert manager.poll() is None and time.monotonic()<deadline
                time.sleep(.05)
            run_tree([*RUNNER,'history-restore',str(root),str(MANAGER)],environment)
            assert manager.wait(timeout=12)==0
        except Exception:
            print((fixture/'manager.log').read_text()[-6000:],file=sys.stderr)
            raise
        finally:
            kill_tree(manager)
