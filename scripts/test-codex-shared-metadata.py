#!/usr/bin/env python3
"""Read-only real-daemon qualification. No daemon start, threads or inference turns."""
import json,selectors,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
peers=[]
def connect():
 p=subprocess.Popen(['python3',str(ROOT/'scripts/run-codex-proxy.py'),'codex'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
 peers.append(p)
 return p
def request(p,i,method,params):
 p.stdin.write(json.dumps({'id':i,'method':method,'params':params})+'\n');p.stdin.flush()
 selector=selectors.DefaultSelector()
 try:
  selector.register(p.stdout,selectors.EVENT_READ)
  for _ in range(20):
   if not selector.select(.5):continue
   line=p.stdout.readline()
   if not line:raise RuntimeError('Codex proxy closed')
   v=json.loads(line)
   if v.get('id')==i:
    if 'error' in v:raise RuntimeError('Codex rejected '+method)
    return v['result']
  raise TimeoutError('Codex '+method+' timed out')
 finally:selector.close()
try:
 with tempfile.TemporaryDirectory(prefix='exosuit-readonly-codex-') as root:
  a,b=connect(),connect()
  for p in [a,b]:
   r=request(p,1,'initialize',{'clientInfo':{'name':'exosuit','title':'Exosuit','version':'1'},'capabilities':{'experimentalApi':False}})
   assert any(v in r.get('userAgent','') for v in ['0.160.0','0.160.1','0.161.0'])
   p.stdin.write(json.dumps({'method':'initialized'})+'\n');p.stdin.flush()
   page=request(p,2,'thread/list',{'cwd':root,'limit':6,'archived':False})
   assert page['data']==[], 'Unexpected thread in fresh read-only fixture directory'
  a.terminate();a.wait(timeout=10)
  page=request(b,3,'thread/list',{'cwd':root,'limit':6,'archived':False})
  assert page['data']==[]
  print('PASS: real shared Codex WebSocket initialization, two simultaneous metadata clients and continued query after sibling disconnect; no threads/inference created')
finally:
 for p in peers:
  if p.poll() is None:p.terminate()
  p.wait(timeout=10)
