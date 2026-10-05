#!/usr/bin/env python3
"""Two separate native editor clients share a daemon-owned shell across an idle interval."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
MANAGER=ROOT/'scripts/run-agent.py'
HAXEON=os.environ.get('HAXEON_BIN',str(Path(os.environ.get('HAXEON_ROOT',str(ROOT.parent/'haxeon')))/'scripts/haxeon'))
MODE=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED')=='1' else []
PROJECT=ROOT/'tests/workspace-terminals/haxeon.json'
HAXEON_ROOT=Path(os.environ.get('HAXEON_ROOT',str(ROOT.parent/'haxeon'))).resolve()
OUTPUT=PROJECT.parent/'build/host'
RUNNER=[str(HAXEON_ROOT/'.tools/hashlink/hl'),str(OUTPUT/'main.hl')]
subprocess.run([HAXEON,'build','--project',str(PROJECT),*MODE],check=True)
with tempfile.TemporaryDirectory(prefix='extty-') as temporary:
    fixture=Path(temporary); root=fixture/'project'; root.mkdir(); state=fixture/'state'
    environment=dict(os.environ,XDG_STATE_HOME=str(state),SHELL='/bin/sh')
    environment.pop('EXOSUIT_AGENT_ALWAYS_AVAILABLE',None)
    libraries=[HAXEON_ROOT/'out',HAXEON_ROOT/'.tools/hashlink',*sorted(path for path in (OUTPUT/'native').iterdir() if path.is_dir())]
    environment['LD_LIBRARY_PATH']=':'.join(str(path) for path in libraries)+(':'+environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
    def endpoints(): return list(state.glob('exosuit/workspaces/*/endpoint.json'))
    subprocess.run([*RUNNER,'contracts',str(root),str(MANAGER)],env=environment,check=True,timeout=40)
    with (fixture/'manager.log').open('w') as log:
        manager=subprocess.Popen([sys.executable,str(MANAGER),str(root),'--idle-seconds','2'],env=environment,stdout=log,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+90
            while not endpoints():
                assert manager.poll() is None,(fixture/'manager.log').read_text()[-5000:]
                assert time.monotonic()<deadline
                time.sleep(.05)
            descriptor=json.loads(endpoints()[0].read_text())
            for mode in ['catalog','create','attach']:
                subprocess.run([*RUNNER,mode,str(root),str(MANAGER)],env=environment,check=True,timeout=40)
                if mode=='create':
                    time.sleep(5)
                    assert manager.poll() is None,'Active terminal did not keep daemon alive'
                    assert json.loads(endpoints()[0].read_text())['generation']==descriptor['generation']
            assert manager.wait(timeout=12)==0,'Exited terminal prevented idle shutdown'
            assert not endpoints()
            print('PASS: PTY survives complete client-process exit; active runtime retains daemon; shell exit restores idle shutdown',flush=True)
        except Exception:
            print((fixture/'manager.log').read_text()[-6000:],file=sys.stderr)
            raise
        finally:
            if manager.poll() is None: manager.terminate(); manager.wait(timeout=10)
