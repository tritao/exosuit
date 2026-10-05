#!/usr/bin/env python3
"""Native fake-Codex acceptance; never starts a real inference turn."""
import os,subprocess,tempfile,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
HAXEON=ROOT/'haxeon'
project=ROOT/'tests/workspace-agents/haxeon.json'
mode=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED')=='1' else []
subprocess.run([str(HAXEON/'scripts/haxeon'),'build','--project',str(project),*mode],check=True)
output=project.parent/'build/host'
env=dict(os.environ)
env['LD_LIBRARY_PATH']=':'.join(str(p) for p in [HAXEON/'out',HAXEON/'.tools/hashlink',*sorted(p for p in (output/'native').iterdir() if p.is_dir())])
with tempfile.TemporaryDirectory(prefix='exosuit-codex-') as temporary:
 root=Path(temporary)
 subprocess.run([str(HAXEON/'.tools/hashlink/hl'),str(output/'main.hl'),temporary,str(project.parent/'fake-codex.py'),str(ROOT/'scripts/run-codex-proxy.py')],env=env,check=True,timeout=90)
 state=json.loads((root/'fake-codex.json').read_text())
 assert state['starts']==1 and state['prompts']==3,state
 commands=[json.loads(line) for line in (root/'fake-codex-commands.log').read_text().splitlines()]
 assert all(c in [['--version'],['app-server','daemon','start'],['app-server','proxy']] for c in commands),commands
 print('PASS: no duplicate thread/prompt side effects and no shared-daemon stop/restart command')
