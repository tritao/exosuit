#!/usr/bin/env python3
"""Version-matched shared app-server fixture. State survives proxy exits."""
import json, os, sys, base64, hashlib, struct
from pathlib import Path
root=Path(os.getcwd())
state=root/'fake-codex.json'
def load(): return json.loads(state.read_text()) if state.exists() else {'threads':{},'starts':0,'prompts':0}
def save(v): state.write_text(json.dumps(v))
with (root/'fake-codex-commands.log').open('a') as log: log.write(json.dumps(sys.argv[1:])+'\n')
if sys.argv[1:]==['--version']:
 print('codex-cli 0.999.0' if (root/'newer-version').exists() else 'codex-cli 0.160.0');sys.exit()
if sys.argv[1:]==['app-server','daemon','start']: sys.exit()
assert sys.argv[1:]==['app-server','proxy'],sys.argv
# The real proxy is a raw WebSocket byte tunnel, not JSONL.
header=b''
while not header.endswith(b'\r\n\r\n'):
 byte=sys.stdin.buffer.read(1)
 if not byte: sys.exit()
 header+=byte
 assert len(header)<8192
key=next(line.split(b':',1)[1].strip() for line in header.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:'))
accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
sys.stdout.buffer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n');sys.stdout.buffer.flush()
def send_payload(payload,opcode=1,fin=True):
 n=len(payload)
 head=bytes([(0x80 if fin else 0)|opcode,n]) if n<126 else bytes([(0x80 if fin else 0)|opcode,126 if n<=65535 else 127])+struct.pack('!H' if n<=65535 else '!Q',n)
 sys.stdout.buffer.write(head+payload);sys.stdout.buffer.flush()
def send(v):
 payload=json.dumps(v,ensure_ascii=False).encode()
 if v.get('method')=='item/agentMessage/delta':
  midpoint=len(payload)//2
  send_payload(payload[:midpoint],1,False)
  send_payload(b'ping',9)
  send_payload(payload[midpoint:],0)
 else:send_payload(payload)
def exact(n):
 result=b''
 while len(result)<n:
  part=sys.stdin.buffer.read(n-len(result))
  if not part: raise EOFError()
  result+=part
 return result
def messages():
 try:
  while True:
   a,b=exact(2);assert b&128
   n=b&127
   if n==126: n=struct.unpack('!H',exact(2))[0]
   elif n==127: n=struct.unpack('!Q',exact(8))[0]
   assert n<=262144
   mask=exact(4);payload=exact(n)
   decoded=bytes(byte^mask[i%4] for i,byte in enumerate(payload))
   if a==0x8a: assert decoded==b'ping';continue
   assert a==0x81
   yield decoded.decode()
 except EOFError:return

def event(method,params): send({'method':method,'params':params})
def reply(i,result): send({'id':i,'result':result})
pending={}
loaded=set()
for line in messages():
 message=json.loads(line); method=message.get('method');params=message.get('params',{});i=message.get('id')
 if method=='initialize':
  assert message.get('jsonrpc') is None
  reply(i,{'userAgent':'codex-cli/0.162.0','codexHome':'fixture','platformFamily':'unix','platformOs':'linux'})
 elif method=='initialized': pass
 elif method=='thread/start':
  assert params['sandbox']=='workspace-write' and params['approvalPolicy']=='on-request'
  v=load();v['starts']+=1;t={'id':'thread-'+str(v['starts']),'cwd':params['cwd'],'status':{'type':'idle'},'turn':None}
  v['threads'][t['id']]=t;save(v);reply(i,{'thread':t})
  loaded.add(t['id'])
 elif method=='thread/list':
  data=[t for t in load()['threads'].values() if t['cwd']==params['cwd']]
  if params['cwd']==str(root): data.append({'id':'owned','cwd':str(root),'status':{'type':'idle'},'turn':None})
  reply(i,{'data':data[:6],'nextCursor':None})
 elif method=='thread/read':
  v=load();t=v['threads'].get(params['threadId'])
  if params['threadId']=='foreign': t={'id':'foreign','cwd':str(root.parent),'status':{'type':'idle'},'turn':None}
  if params['threadId']=='owned': t={'id':'owned','cwd':str(root),'status':{'type':'idle'},'turn':None}
  if t is None: send({'id':i,'error':{'code':-32000,'message':'Unknown thread'}})
  elif params['threadId']!='foreign' and params['threadId'] not in loaded:
   send({'id':i,'error':{'code':-32000,'message':'thread not loaded: '+params['threadId']}})
  else: reply(i,{'thread':t})
 elif method=='thread/resume':
  if params['threadId']=='owned':
   send({'id':i,'error':{'code':-32000,'message':'Thread already has an active writer in another Codex client'}});continue
  loaded.add(params['threadId'])
  reply(i,{'thread':load()['threads'][params['threadId']]})
 elif method=='thread/turns/list':
  t=load()['threads'][params['threadId']]
  reply(i,{'data':[] if not t['turn'] else [t['turn']]})
 elif method=='thread/items/list':
  reply(i,{'data':[{'turnId':'history','item':{'id':'historical-message','type':'agentMessage','text':'Persisted history'}}]})
 elif method=='model/list':
  reply(i,{'data':[
   {'id':'fixture-model','model':'fixture-model','displayName':'Fixture model','hidden':False,
    'defaultReasoningEffort':'low','supportedReasoningEfforts':[{'reasoningEffort':'low'},{'reasoningEffort':'high'}]},
   {'id':'override-model','model':'override-model','displayName':'Override model','hidden':False,
    'defaultReasoningEffort':'low','supportedReasoningEfforts':[{'reasoningEffort':'low'},{'reasoningEffort':'high'}]}
  ], 'nextCursor':None})
 elif method=='turn/start':
  v=load();t=v['threads'][params['threadId']];v['prompts']+=1
  turn={'id':'turn-'+str(v['prompts']),'status':'inProgress'}
  t['turn']=turn;t['status']={'type':'active'};save(v)
  text=params['input'][0]['text']
  v['lastPrompt']=text;v['lastModel']=params.get('model');v['lastEffort']=params.get('effort');save(v)
  if text.startswith('界'): assert params.get('model')=='fixture-model'
  if text=='disconnect': sys.exit()
  if text=='oversize':
   send_payload(b'x'*300000);continue
  reply(i,{'turn':turn})
  event('turn/started',{'threadId':t['id'],'turn':turn})
  event('item/started',{'threadId':t['id'],'turnId':turn['id'],'item':{'id':'message','type':'agentMessage','text':''}})
  event('item/agentMessage/delta',{'threadId':t['id'],'turnId':turn['id'],'itemId':'message','delta':'Hello streamed world'})
  for _ in range(2): event('item/completed',{'threadId':t['id'],'turnId':turn['id'],'item':{'id':'message','type':'agentMessage','text':'Hello streamed world'}})
  event('item/completed',{'threadId':t['id'],'turnId':turn['id'],'item':{'id':'command-output','type':'commandExecution','command':'echo test','cwd':t['cwd'],'aggregatedOutput':'test','exitCode':0,'status':'completed'}})
  event('item/completed',{'threadId':t['id'],'turnId':turn['id'],'item':{'id':'file-change','type':'fileChange','changes':[{'path':'README.md','kind':{'type':'update'},'diff':'+fixture line'}],'status':'completed'}})
  event('item/completed',{'threadId':t['id'],'turnId':turn['id'],'item':{'id':'wrapped-message','type':'agentMessage','text':'Wrapped conversation text exercises paragraph measurement. '*12}})
  event('item/completed',{'threadId':t['id'],'turnId':turn['id'],'item':{'id':'code-message','type':'agentMessage','text':'Example `primes`:\n\n```python\ndef primes():\n    return 2 # 界\n```'}})
  send({'id':799,'method':'item/commandExecution/requestApproval','params':{'threadId':'another-clients-thread','turnId':'foreign-turn','itemId':'foreign-command','command':'unrelated'}})
  pending[700]={'threadId':t['id'],'turnId':turn['id'],'itemId':'command','command':'echo test','cwd':t['cwd'],'reason':'Fixture approval'}
  send({'id':700,'method':'item/commandExecution/requestApproval','params':pending[700]})
 elif method=='turn/interrupt':
  v=load();t=v['threads'][params['threadId']];assert params['turnId']==t['turn']['id']
  t['turn']['status']='interrupted';t['status']={'type':'idle'};save(v)
  reply(i,{})
  event('turn/completed',{'threadId':t['id'],'turn':t['turn']})
 elif method is None and i==799: raise AssertionError('Exosuit answered another client’s request')
 elif method is None and i==700:
  assert message['result']['decision'] in ('accept','decline')
  p=pending[700];event('serverRequest/resolved',{'threadId':p['threadId'],'requestId':700})
  pending[701]=p
  send({'id':701,'method':'item/tool/requestUserInput','params':{'threadId':p['threadId'],'turnId':p['turnId'],'itemId':'question','questions':[{'id':'choice','header':'Choice','question':'Pick a choice','options':[{'label':'yes','description':'Proceed'}]}]}})
 elif method is None and i==701:
  assert message['result']['answers']=={'choice':{'answers':['yes']}}
  p=pending[701];v=load();t=v['threads'][p['threadId']];t['turn']['status']='completed';t['status']={'type':'idle'};save(v)
  event('serverRequest/resolved',{'threadId':p['threadId'],'requestId':701})
  event('turn/completed',{'threadId':t['id'],'turn':t['turn']})
 else:
  send({'id':i,'error':{'code':-32601,'message':'Method not found'}})
