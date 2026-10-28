#!/usr/bin/env python3
"""Read-only real-daemon qualification. No daemon start, threads or inference turns."""
import json,os,queue,shutil,subprocess,sys,tempfile,threading
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
peers=[]
servers=[]
def codex_command():
 if os.environ.get('EXOSUIT_CODEX_BIN'):
  return [os.environ['EXOSUIT_CODEX_BIN'],*([os.environ['EXOSUIT_CODEX_SCRIPT']] if os.environ.get('EXOSUIT_CODEX_SCRIPT') else [])]
 if os.name=='nt':
  shim=shutil.which('codex.cmd')
  if shim:
   directory=Path(shim).resolve().parent
   node=directory/'node.exe'
   cli=directory/'node_modules'/'@openai'/'codex'/'bin'/'codex.js'
   if node.is_file() and cli.is_file():return [str(node),str(cli)]
 return ['codex']
def connect():
 p=subprocess.Popen([sys.executable,str(ROOT/'scripts/run-codex-proxy.py'),*codex_command()],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
 p.responses=queue.Queue()
 def read_responses():
  try:
   for line in p.stdout:p.responses.put(line)
  finally:p.responses.put(None)
 threading.Thread(target=read_responses,daemon=True).start()
 peers.append(p)
 return p
def request(p,i,method,params):
 p.stdin.write(json.dumps({'id':i,'method':method,'params':params})+'\n');p.stdin.flush()
 deadline=10
 while deadline>0:
  try:line=p.responses.get(timeout=min(.5,deadline))
  except queue.Empty:
   deadline-=.5
   continue
  if line is None:raise RuntimeError('Codex proxy closed')
  if line:
   v=json.loads(line)
   if v.get('id')==i:
    if 'error' in v:raise RuntimeError('Codex rejected '+method)
    return v['result']
 raise TimeoutError('Codex '+method+' timed out')
try:
 with tempfile.TemporaryDirectory(prefix='exosuit-readonly-codex-') as root:
  a,b=connect(),connect()
  for p in [a,b]:
   r=request(p,1,'initialize',{'clientInfo':{'name':'exosuit','title':'Exosuit','version':'1'},'capabilities':{'experimentalApi':False}})
   assert isinstance(r.get('userAgent'),str) and r['userAgent'], 'Codex initialize omitted userAgent'
   if r['userAgent'] not in servers:servers.append(r['userAgent'])
   p.stdin.write(json.dumps({'method':'initialized'})+'\n');p.stdin.flush()
   page=request(p,2,'thread/list',{'cwd':root,'limit':6,'archived':False})
   assert page['data']==[], 'Unexpected thread in fresh read-only fixture directory'
  a.terminate();a.wait(timeout=10)
  page=request(b,3,'thread/list',{'cwd':root,'limit':6,'archived':False})
  assert page['data']==[]
  print('PASS: real shared Codex WebSocket initialization, two simultaneous metadata clients and continued query after sibling disconnect; server: '+', '.join(servers)+'; no threads/inference created')
finally:
 for p in peers:
  if p.poll() is None:p.terminate()
  p.wait(timeout=10)
