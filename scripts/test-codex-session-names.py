#!/usr/bin/env python3
"""Installed Codex app-server metadata acceptance on a disposable thread; no turn or prompt."""
import json,os,selectors,shutil,subprocess,sys,tempfile,time
from pathlib import Path
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon
ROOT=Path(__file__).resolve().parent.parent
codex=shutil.which(os.environ.get('EXOSUIT_CODEX_BIN','codex'))
if not codex: raise SystemExit('Install Codex to run this metadata-only acceptance test')
subprocess.run([codex,'app-server','daemon','start'],check=True,capture_output=True,timeout=30)
with tempfile.TemporaryDirectory(prefix='exosuit-native-codex-name-') as directory:
 process=subprocess.Popen([sys.executable,str(ROOT/'scripts/run-codex-proxy.py'),codex],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
 buffer=b'';serial=0;thread=None;events=[]
 def send(value):process.stdin.write((json.dumps(value)+'\n').encode());process.stdin.flush()
 def request(method,params):
  global serial,buffer
  serial+=1;identifier=serial;send({'id':identifier,'method':method,'params':params});deadline=time.monotonic()+20
  while time.monotonic()<deadline:
   while b'\n' in buffer:
    line,buffer=buffer.split(b'\n',1)
    result=json.loads(line)
    if 'method' in result:events.append(result)
    if result.get('id')==identifier:
     if 'error' in result:raise RuntimeError(method+': '+str(result['error']))
     return result['result']
   if selector.select(.1):
    data=os.read(process.stdout.fileno(),65536)
    if not data:raise RuntimeError('Codex proxy closed during metadata test')
    buffer+=data
  raise TimeoutError(method)
 try:
  request('initialize',{'clientInfo':{'name':'exosuit-name-test','version':'1'},'capabilities':{'experimentalApi':False}})
  send({'method':'initialized'})
  value=request('thread/start',{'cwd':directory,'ephemeral':False,'approvalPolicy':'never','sandbox':'read-only'})
  thread=value['thread']['id']
  request('thread/name/set',{'threadId':thread,'name':'Exosuit metadata test α'})
  value=request('thread/read',{'threadId':thread,'includeTurns':False})
  assert value['thread']['name']=='Exosuit metadata test α',value['thread'].get('name')
  request('thread/name/set',{'threadId':thread,'name':'Changed outside Exosuit'})
  value=request('thread/read',{'threadId':thread,'includeTurns':False})
  assert value['thread']['name']=='Changed outside Exosuit'
  assert any(event.get('method')=='thread/name/updated' and event.get('params',{}).get('threadId')==thread for event in events), 'Native name-change notification missing'
  # Empty threads deliberately have no rollout/picker entry before their first model turn.
  # Do not generate a paid turn just to manufacture a persisted test conversation.
  print('PASS: installed Codex native title set/read and change notifications on a disposable thread; no turn, prompt, resume or inference request')
 finally:
  if thread is not None:
   request('thread/delete',{'threadId':thread})
  process.stdin.close();process.terminate();process.wait(timeout=10);selector.close()
