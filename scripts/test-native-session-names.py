#!/usr/bin/env python3
"""Daemon adapters against the Codex metadata peer and the real pinned Claude metadata SDK."""
import json,os,sys,tempfile
from pathlib import Path
from prepare_agent_naming import prepare
from test_driver import ROOT, build_test, run_tree, with_libraries
prepare(ROOT, required=True)
RUNNER=build_test('native-session-names')
output=ROOT/'tests/native-session-names/build/host'
with tempfile.TemporaryDirectory(prefix='exosuit-native-names-',ignore_cleanup_errors=True) as temporary:
 root=Path(temporary).resolve();config=root/'claude-config';session='12345678-1234-1234-1234-123456789abc'
 (root/'title.json').write_text(json.dumps('Native title'))
 project=config/'projects'/''.join(c if c.isascii() and c.isalnum() else '-' for c in str(root));project.mkdir(parents=True)
 (project/(session+'.jsonl')).write_text(json.dumps({'type':'user','sessionId':session,'uuid':'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','parentUuid':None,'cwd':str(root),'isSidechain':False,'timestamp':'2026-01-01T00:00:00Z','message':{'role':'user','content':'Fixture only, never sent'}})+'\n')
 env=dict(with_libraries(dict(os.environ),output/'native'),CLAUDE_CONFIG_DIR=str(config),ANTHROPIC_API_KEY='',ANTHROPIC_AUTH_TOKEN='',EXOSUIT_TEST_PYTHON=sys.executable,
          EXOSUIT_CLAUDE_NAMING_HELPER=str(ROOT/'agent/naming/claude-session-names.mjs'))
 run_tree([*RUNNER,str(root),str(ROOT)],env,timeout=60)
 methods=[json.loads(line)['method'] for line in (root/'wire.jsonl').read_text().splitlines()]
 assert set(methods)<= {'thread/read','thread/name/set'} and methods.count('thread/name/set')==2,methods
 print('PASS: native rename emits no resume, start, prompt, turn or duplicate title write')
