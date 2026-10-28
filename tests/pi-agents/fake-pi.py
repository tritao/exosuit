#!/usr/bin/env python3
"""Deterministic native Pi RPC peer. Never used by the application runtime."""
import base64, json, os, sys
from pathlib import Path
args=sys.argv[1:]
if '--silent' in args:
 for _ in sys.stdin: pass
 sys.exit(0)
assert args[:2]==['--mode','rpc'] and '--extension' in args,args
extension=Path(args[args.index('--extension')+1]).read_text()
assert 'pi.on("tool_call"' in extension
session=args[args.index('--session')+1] if '--session' in args else str(Path.cwd()/('session-'+str(os.getpid())+'.jsonl'))
Path(session).touch(exist_ok=True)
log=open('pi-wire.jsonl','a',buffering=1)
log.write(json.dumps({'launch':args,'session':session})+'\n')
streaming=False
model={'provider':'fixture','id':'test-model','name':'Fixture model','reasoning':True,'thinkingLevelMap':{'xhigh':None,'max':None}}
current=model.copy()
pending=None
active=None
thinking="medium"
steering=[]
held_state=None
race=False

def emit(v):
 # Preserve Unicode and unusual separators; LF is the only frame delimiter.
 data=(json.dumps(v,ensure_ascii=False)+'\r\n').encode()
 size=4096 if len(data)>100000 else 37
 for i in range(0,len(data),size):
  os.write(sys.stdout.fileno(),data[i:i+size])
def reply(v,data=None):emit({'id':v['id'],'type':'response','command':v['type'],'success':True,'data':data or {}})
def queue_update():emit({'type':'queue_update','steering':steering,'followUp':[]})
def complete():
 global streaming,pending
 for text in list(steering):
  steering.remove(text);queue_update()
  emit({'type':'message_start','message':{'role':'user','content':[{'type':'text','text':text}]}})
  emit({'type':'message_start','message':{'role':'assistant'}})
  emit({'type':'message_update','assistantMessageEvent':{'type':'text_delta','contentIndex':0,'delta':'Steered reply'}})
 streaming=False;pending=None
 emit({'type':'agent_settled','aborted':False})
def message():
 emit({'type':'message_start','message':{'role':'assistant'}})
 for kind,text in [('thinking_delta','Consider this'),('text_delta','Hello 界\u2028Pi')]:
  emit({'type':'message_update','assistantMessageEvent':{'type':kind,'contentIndex':0,'delta':text}})
 emit({'type':'message_end','message':{'role':'assistant','stopReason':'stop'}})
 complete()
mode='acceptEdits' if 'const mode = \"acceptEdits\"' in extension else 'fullAccess' if 'const mode = \"fullAccess\"' in extension else 'supervised'
if not Path('no-hook').exists():
 emit({'type':'extension_ui_request','method':'notify','message':'exosuit-permissions/v1:'+mode})
for line in sys.stdin:
 v=json.loads(line);log.write(json.dumps(v)+'\n');kind=v['type']
 if kind=='get_state':
  if race:
   held_state=v;emit({'type':'extension_ui_request','method':'notify','message':'RACE_PROBE_HELD'});continue
  reply(v,{'sessionFile':session,'model':current,'thinkingLevel':thinking,'isStreaming':streaming,'pendingMessageCount':len(steering)})
 elif kind=='clear_queue':
  cleared=list(steering);steering.clear();queue_update();reply(v,{'steering':cleared,'followUp':[]})
 elif kind=='get_commands':
  if Path('commands-broken').exists():
   emit({'id':v['id'],'type':'response','command':kind,'success':False,'error':'Discovery unavailable'})
  else:
   commands=[{'name':'fixture-command','description':'An extension command','source':'extension','sourceInfo':{'scope':'user'}},
    {'name':'fixture-prompt','description':'A project prompt template','source':'prompt','sourceInfo':{'scope':'project'}},
    {'name':'skill:fixture-skill','description':'A project skill','source':'skill','sourceInfo':{'scope':'project'}}]
   if Path('commands-new').exists(): commands.append({'name':'new-command','source':'extension'})
   reply(v,{'commands':commands})
 elif kind=='get_available_models':reply(v,{'models':[model,{**model,'id':'other-model'}]})
 elif kind=='set_thinking_level':
  thinking=v['level'];reply(v)
 elif kind=='set_model':
  current={**model,'id':v['modelId']};reply(v,current)
 elif kind=='prompt':
  active=v
  text=v['message']
  if v.get('images'):
   if text.startswith('image echo '):
    expected=Path('expected-pi-image.png').read_bytes()
    assert len(v['images'])==2 and len(expected)==2*1024*1024
    assert all(base64.b64decode(image['data'],validate=True)==expected for image in v['images'])
   for image in v['images']:
    assert image['type']=='image' and image['mimeType'] in ('image/png','image/jpeg','image/gif')
    assert len(base64.b64decode(image['data'],validate=True))>0
   emit({'type':'message_start','message':{'role':'user','content':v['images']}})
  if v.get('streamingBehavior')=='steer' and streaming:
   if text=='reject-steer':
    emit({'id':v['id'],'type':'response','command':'prompt','success':False,'error':'Steer rejected before acceptance'});continue
   steering.append(text);queue_update()
   if text=='lost-steer':os._exit(7)
   reply(v,{'disposition':'queued'});continue
  if text=='race-steer':
   race=False
   if held_state:
    reply(held_state,{'sessionFile':session,'model':current,'thinkingLevel':thinking,'isStreaming':False,'pendingMessageCount':0});held_state=None
  streaming=True
  if text=='crash':os._exit(7)
  if text=='malformed':os.write(sys.stdout.fileno(),b'{broken\n');continue
  if text=='oversized':os.write(sys.stdout.fileno(),b'x'*(6*1024*1024+1));continue
  if text=='/fixture-command':
   streaming=False
   emit({'type':'extension_ui_request','method':'notify','message':'Fixture command ran'})
   reply(v,{'disposition':'handled'});continue
  reply(v,{'disposition':'started'})
  emit({'type':'agent_start'})
  if text=='settle-race':
   streaming=False;race=True;emit({'type':'agent_settled','aborted':False});continue
  if text in ('approval','large-approval','wait','select','input','editor','race-steer'):
   method=text if text in ('select','input','editor') else 'confirm'
   pending=method
   emit({'type':'extension_ui_request','id':'reused-native-id','method':method,'title':'Allow bash?' if method=='confirm' else 'Pick a value','message':'x'*3000 if text=='large-approval' else 'echo ok','options':['Blue','Red'] if method=='select' else None})
  elif text=='tool':
   emit({'type':'tool_execution_start','toolCallId':'tool-1','toolName':'read','args':{'path':'a.txt'}})
   emit({'type':'tool_execution_update','toolCallId':'tool-1','toolName':'read','partialResult':{'content':[{'type':'text','text':'partial'}]}})
   emit({'type':'tool_execution_end','toolCallId':'tool-1','toolName':'read','result':{'content':[{'type':'text','text':'complete'}]},'isError':False})
   message()
  else:message()
 elif kind=='extension_ui_response':
  if pending=='select' and not v.get('cancelled'):assert v['value']=='Blue',v
  if pending in ('input','editor') and not v.get('cancelled'):assert v['value']=='An answer',v
  complete()
 else:raise AssertionError(v)
