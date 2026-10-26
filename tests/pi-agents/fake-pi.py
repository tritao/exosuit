#!/usr/bin/env python3
"""Deterministic native Pi RPC peer. Never used by the application runtime."""
import json, os, sys
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

def emit(v):
 # Preserve Unicode and unusual separators; LF is the only frame delimiter.
 data=(json.dumps(v,ensure_ascii=False)+'\r\n').encode()
 for i in range(0,len(data),37):
  os.write(sys.stdout.fileno(),data[i:i+37])
def reply(v,data=None):emit({'id':v['id'],'type':'response','command':v['type'],'success':True,'data':data or {}})
def complete():
 global streaming,pending
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
 if kind=='get_state':reply(v,{'sessionFile':session,'model':current,'thinkingLevel':thinking,'isStreaming':streaming})
 elif kind=='get_available_models':reply(v,{'models':[model,{**model,'id':'other-model'}]})
 elif kind=='set_thinking_level':
  thinking=v['level'];reply(v)
 elif kind=='set_model':
  current={**model,'id':v['modelId']};reply(v,current)
 elif kind=='prompt':
  active=v;streaming=True
  text=v['message']
  if text=='crash':os._exit(7)
  if text=='malformed':os.write(sys.stdout.fileno(),b'{broken\n');continue
  if text=='oversized':os.write(sys.stdout.fileno(),b'x'*270000+b'\n');continue
  reply(v,{'disposition':'started'})
  emit({'type':'agent_start'})
  if text in ('approval','large-approval','wait','select','input','editor'):
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
