#!/usr/bin/env python3
"""Metadata-only JSONL peer; tests inject it at the initialized proxy boundary."""
import json,sys
from pathlib import Path
sys.stdin.reconfigure(encoding='utf-8')
sys.stdout.reconfigure(encoding='utf-8')
root=Path(sys.argv[1])
for line in sys.stdin:
 q=json.loads(line);method=q['method'];p=q['params']
 with (root/'wire.jsonl').open('a') as log:log.write(json.dumps(q)+'\n')
 if method=='thread/read':
  result={'thread':{'id':p['threadId'],'cwd':str(root),'name':json.loads((root/'title.json').read_text())}}
 elif method=='thread/name/set':
  if (root/'unsupported-name-set').exists():
   print(json.dumps({'id':q['id'],'error':{'code':-32601,'message':'Method not found'}}),flush=True);continue
  (root/'title.json').write_text(json.dumps(p['name']))
  print(json.dumps({'method':'thread/name/updated','params':{'threadId':p['threadId'],'threadName':p['name']}}),flush=True)
  result={}
 else: raise AssertionError('Native naming must not start/resume/turn: '+method)
 print(json.dumps({'id':q['id'],'result':result}),flush=True)
