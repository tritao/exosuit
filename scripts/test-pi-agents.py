#!/usr/bin/env python3
"""Native adapter tests; --real uses an installed Pi and a local mock model, never paid APIs."""
import json, os, shutil, subprocess, sys, tempfile
from pi_test_runtime import Model, configure_pi
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
HAXEON=ROOT/'haxeon'
real='--real' in sys.argv[1:]
project=ROOT/'tests/pi-agents'/('real.haxeon.json' if real else 'haxeon.json')
binary=os.environ.get('EXOSUIT_PI_BIN') or shutil.which('pi')
if real and not binary:
 raise SystemExit('Install Pi or set EXOSUIT_PI_BIN before running --real')
subprocess.run([str(HAXEON/'scripts/haxeon'),'build','--project',str(project)],check=True)
output=project.parent/'build/host'
env=dict(os.environ)
env['LD_LIBRARY_PATH']=':'.join(str(p) for p in [HAXEON/'out',HAXEON/'.tools/hashlink',*sorted(p for p in (output/'native').iterdir() if p.is_dir())])

with tempfile.TemporaryDirectory(prefix='exosuit-pi-') as temporary:
 server=configure_pi(temporary,env) if real else None
 try:
  subprocess.run([str(HAXEON/'.tools/hashlink/hl'),str(output/'main.hl'),temporary,binary if real else str(project.parent/'fake-pi.py')],env=env,check=True,timeout=120)
 finally:
  if server:server.shutdown();server.server_close()
 if real:
  history=json.dumps(Model.requests[-1]['messages'])
  assert 'after-resume' in history and 'hello' in history and 'auto-edit' in history,'Native Pi resume lost conversation history'
  assert any('PI_SKILL_EXPANSION_MARKER' in json.dumps(r['messages']) for r in Model.requests),'Pi did not expand the chosen skill'
  assert any('PI_TEMPLATE_EXPANSION_MARKER' in json.dumps(r['messages']) for r in Model.requests),'Pi did not expand the prompt template'
  print('PASS: native Pi resume retained history and native skills/templates expanded')
 if not real:
  wire=[json.loads(line) for line in (Path(temporary)/'pi-wire.jsonl').read_text().splitlines()]
  prompts=[v['message'] for v in wire if v.get('type')=='prompt']
  assert prompts.count('crash')==1 and 'must-not-send' not in prompts,prompts
  assert prompts.count('hello')==1,prompts
  assert '/skill:fixture-skill investigate' in prompts and '/fixture-command' in prompts,prompts
  print('PASS: no duplicate or automatically resent prompt side effects')
