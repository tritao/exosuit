#!/usr/bin/env python3
"""Daemon adapters against the Codex metadata peer and the real pinned Claude metadata SDK."""
import json,os,subprocess,tempfile
from pathlib import Path
from prepare_agent_naming import prepare
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon
ROOT=Path(__file__).resolve().parent.parent
prepare(ROOT, required=True)
subprocess.run([str(ROOT/'haxeon/scripts/haxeon'),'build','--project',str(ROOT/'tests/native-session-names/haxeon.json')],check=True)
output=ROOT/'tests/native-session-names/build/host'
with tempfile.TemporaryDirectory(prefix='exosuit-native-names-') as temporary:
 root=Path(temporary);config=root/'claude-config';session='12345678-1234-1234-1234-123456789abc'
 (root/'title.json').write_text(json.dumps('Native title'))
 project=config/'projects'/''.join(c if c.isascii() and c.isalnum() else '-' for c in str(root));project.mkdir(parents=True)
 (project/(session+'.jsonl')).write_text(json.dumps({'type':'user','sessionId':session,'uuid':'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','parentUuid':None,'cwd':str(root),'isSidechain':False,'timestamp':'2026-01-01T00:00:00Z','message':{'role':'user','content':'Fixture only, never sent'}})+'\n')
 env=dict(os.environ,CLAUDE_CONFIG_DIR=str(config),EXOSUIT_CLAUDE_NAMING_HELPER=str(ROOT/'agent/naming/claude-session-names.mjs'))
 env['LD_LIBRARY_PATH']=':'.join(map(str,[ROOT/'haxeon/out',ROOT/'haxeon/.tools/hashlink',*[p for p in (output/'native').iterdir() if p.is_dir()]]))
 subprocess.run([str(ROOT/'haxeon/.tools/hashlink/hl'),str(output/'main.hl'),str(root),str(ROOT)],env=env,check=True,timeout=60)
 methods=[json.loads(line)['method'] for line in (root/'wire.jsonl').read_text().splitlines()]
 assert set(methods)<= {'thread/read','thread/name/set'} and methods.count('thread/name/set')==2,methods
 print('PASS: native rename emits no resume, start, prompt, turn or duplicate title write')
