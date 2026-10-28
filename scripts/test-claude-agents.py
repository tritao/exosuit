#!/usr/bin/env python3
"""Build and run native Claude adapter tests with a deterministic CLI protocol peer."""
import json,os,subprocess,tempfile,sys,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
HAXEON=ROOT/'haxeon'
real='--real' in sys.argv[1:]
project=ROOT/('tests/claude-agents/real.haxeon.json' if real else 'tests/claude-agents/haxeon.json')
subprocess.run([str(HAXEON/'scripts/haxeon'),'build','--project',str(project)],check=True)
output=project.parent/('build-real/host' if real else 'build/host')
env=dict(os.environ)
env['LD_LIBRARY_PATH']=':'.join(str(p) for p in [HAXEON/'out',HAXEON/'.tools/hashlink',*sorted(p for p in (output/'native').iterdir() if p.is_dir())])
with tempfile.TemporaryDirectory(prefix='exosuit-claude-') as temporary:
 subprocess.run([str(HAXEON/'.tools/hashlink/hl'),str(output/'main.hl'),temporary,(os.environ.get('EXOSUIT_CLAUDE_BIN') or shutil.which('claude')) if real else str(project.parent/'fake-claude.py')],env=env,check=True,timeout=200)
 if real: sys.exit(0)
 wire=[json.loads(line) for line in (Path(temporary)/'wire.jsonl').read_text().splitlines()]
 prompts=[v['message']['content'] for v in wire if v['type']=='user']
 assert prompts.count('crash')==1 and 'must-not-send' not in prompts,prompts
 assert prompts.count('hello')==1,prompts
 print('PASS: no duplicate or automatically resent prompt side effects')
