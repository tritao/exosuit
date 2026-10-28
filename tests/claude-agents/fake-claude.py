#!/usr/bin/env python3
"""Deterministic protocol peer for the native Haxe adapter; not a runtime bridge."""
import base64,json,sys,os
from pathlib import Path
args=sys.argv[1:]
session=args[args.index('--resume')+1] if '--resume' in args else args[args.index('--session-id')+1]
log=open('wire.jsonl','a',buffering=1)
def emit(v): print(json.dumps(v),flush=True)
def reply(v,response=None): emit({'type':'control_response','response':{'subtype':'success','request_id':v['request_id'],'response':response or {}}})
def result():emit({'type':'result','session_id':session,'is_error':False})
for line in sys.stdin:
 if '--silent' in args: continue
 v=json.loads(line);log.write(json.dumps(v)+'\n');t=v['type']
 if t=='control_request':
  sub=v['request']['subtype']
  if sub=='initialize':reply(v,{'models':[{'value':'test-model','displayName':'Fixture model'}]})
  elif sub=='interrupt':reply(v);emit({'type':'control_cancel_request','request_id':'cancel-me'});result()
  else:reply(v)
 elif t=='user':
  text=v['message']['content']
  if isinstance(text,list):
   blocks=text
   text=''.join(part['text'] for part in blocks if part.get('type')=='text')
   images=[part for part in blocks if part.get('type')=='image']
   assert all(i['source']['type']=='base64' and i['source']['media_type']=='image/png' for i in images)
   if text.startswith('image maximum'):
    expected=Path('expected-claude-image.png').read_bytes()
    assert len(images)==2 and len(expected)==2*1024*1024
    assert all(base64.b64decode(i['source']['data'],validate=True)==expected for i in images)
   emit({'type':'user','uuid':'echo-image','message':{'content':images}})
  emit({'type':'system','subtype':'init','session_id':session,'model':'test-model'})
  if text in ('crash','image-crash'):os._exit(7)
  if text=='malformed':print('{broken',flush=True);continue
  if text=='oversized':sys.stdout.write('x'*(6*1024*1024+1));sys.stdout.flush();continue
  if text in ('approval','question','question-structured','wait','large-approval'):
   tool='AskUserQuestion' if text in ('question','question-structured') else 'Bash'
   inp={'questions':[{'question':'Choose a color','options':[{'label':'Blue'},{'label':'Red'}]}]} if text=='question' else {'command':'sleep 30' if text=='wait' else 'echo '+('x'*3000 if text=='large-approval' else 'ok')}
   if text=='question-structured': inp={'questions':[{'header':'Color','question':'Choose a color','options':[{'label':'Blue','description':'Blue color'}]},{'header':'Colors','question':'Choose colors','multiSelect':True,'options':[{'label':'Red','description':'Red color'},{'label':'Green','description':'Green color'}]}]}
   emit({'type':'control_request','request_id':'cancel-me' if text=='wait' else 'approval-1','request':{'subtype':'can_use_tool','tool_name':tool,'input':inp}})
  else:
   emit({'type':'stream_event','event':{'type':'message_start','message':{'id':'message-'+text}}})
   emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'type':'text_delta','text':'Hello 界'}}})
   emit({'type':'assistant','message':{'id':'message-'+text,'content':[{'type':'text','text':'Hello 界'}]}})
   result()
 elif t=='control_response':
  r=v['response']['response']
  if r['behavior']=='allow' and 'questions' in r['updatedInput']:
   expected={'Choose a color':'Blue','Choose colors':'Red, Green'} if len(r['updatedInput']['questions'])==2 else {'Choose a color':'Blue'}
   assert r['updatedInput']['answers']==expected,r
  result()
