#!/usr/bin/env python3
"""Native fake-Codex acceptance; never starts a real inference turn."""
import os,subprocess,tempfile,json
from pathlib import Path
import sys
from haxeon_cli import run_cli
ROOT=Path(__file__).resolve().parent.parent
HAXEON=ROOT/'haxeon'
project=ROOT/'tests/workspace-agents/haxeon.json'
mode=['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED')=='1' else []
if run_cli(ROOT,['build','--project',str(project),*mode])!=0: sys.exit('build failed')
windows=os.name=='nt'
output=project.parent/'build/host'
env=dict(os.environ)
variable='PATH' if windows else 'LD_LIBRARY_PATH'
env[variable]=os.pathsep.join([*(str(p) for p in [HAXEON/'out',HAXEON/'.tools/hashlink',*sorted(p for p in (output/'native').iterdir() if p.is_dir())]),*([env[variable]] if env.get(variable) else [])])
with tempfile.TemporaryDirectory(prefix='exosuit-codex-') as temporary:
 root=Path(temporary)
 # Canonical traversal must terminate cycles and deduplicate directory/file aliases.
 inputs=root/'build-inputs'; source=inputs/'source'; runtime=inputs/'runtime'
 (source/'nested').mkdir(parents=True); (source/'build').mkdir(); runtime.mkdir()
 (source/'one.c').write_text('one'); (source/'nested/two.hx').write_text('two')
 (source/'libmixed.so').write_text('mixed')
 (source/'build/ignored.c').write_text('ignored'); (runtime/'libsample.so.1').write_text('runtime')
 if not windows: # Creating symlinks needs a privilege on Windows; the traversal checks below are POSIX-only there.
  (source/'cycle').symlink_to('.',target_is_directory=True)
  (source/'alias').symlink_to('nested',target_is_directory=True)
  (source/'broken').symlink_to('missing',target_is_directory=True)
  (runtime/'cycle').symlink_to('.',target_is_directory=True)
  (runtime/'libsample.so').symlink_to('libsample.so.1')
 fake=project.parent/'fake-codex.py'
 if windows:
  # The agent runs the CLI directly, so Windows needs an executable wrapper around the Python fake.
  fake=Path(temporary)/'fake-codex.cmd'
  fake.write_bytes(('@"%s" "%s" %%*'%(sys.executable,project.parent/'fake-codex.py')).encode()+bytes([13,10]))
 subprocess.run([str(HAXEON/'.tools/hashlink'/('hl.exe' if windows else 'hl')),str(output/'main.hl'),temporary,str(fake),str(ROOT/'scripts/run-codex-proxy.py')],env=env,check=True,timeout=90)
 state=json.loads((root/'fake-codex.json').read_text())
 # One thread for resource "a", however often it is created, and one for the newer-version resource.
 assert state['starts']==2 and state['prompts']==3,state
 commands=[json.loads(line) for line in (root/'fake-codex-commands.log').read_text().splitlines()]
 assert all(c in [['--version'],['app-server','daemon','start'],['app-server','proxy']] for c in commands),commands
 print('PASS: no duplicate thread/prompt side effects and no shared-daemon stop/restart command')
