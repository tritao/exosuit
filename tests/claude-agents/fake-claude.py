#!/usr/bin/env python3
"""Deterministic protocol peer for the native Haxe adapter; not a runtime bridge."""
import base64,json,sys,os,re
from pathlib import Path
args=sys.argv[1:]
session=args[args.index('--resume')+1] if '--resume' in args else args[args.index('--session-id')+1]
log=open('wire.jsonl','a',buffering=1)
# With FAKE_CLAUDE_HOME set the peer keeps Claude Code's own record of each conversation
# (<home>/projects/<folder slug>/<session id>.jsonl) and, like the CLI, resumes only a conversation it has a record of
# and begins only one it has none of.
home=os.environ.get('FAKE_CLAUDE_HOME')
record=Path(home)/'projects'/re.sub(r'[^A-Za-z0-9]','-',os.getcwd())/(session+'.jsonl') if home else None
if record is not None and '--silent' not in args:
 if '--resume' in args and not record.exists(): sys.stderr.write('No conversation found with session ID: '+session+'\n');sys.exit(1)
 if '--session-id' in args and record.exists(): sys.stderr.write('Session ID '+session+' is already in use.\n');sys.exit(1)
 log.write(json.dumps({'type':'launch','session':session,'resume':'--resume' in args})+'\n')
def remember(kind,message):
 if record is None: return
 record.parent.mkdir(parents=True,exist_ok=True)
 with open(record,'a') as out: out.write(json.dumps({'type':kind,'uuid':os.urandom(8).hex(),'sessionId':session,'isSidechain':False,'message':message})+'\n')
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
  if isinstance(text,list): remember('user',{'role':'user','content':[part if part.get('type')=='text' else {'type':'image'} for part in text]})
  else: remember('user',{'role':'user','content':text})
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
   remember('assistant',{'id':'message-'+text,'role':'assistant','content':[{'type':'text','text':'Hello 界 '+'long '*1200 if text=='long' else 'Hello 界'}]})
   result()
 elif t=='control_response':
  r=v['response']['response']
  if r['behavior']=='allow' and 'questions' in r['updatedInput']:
   expected={'Choose a color':'Blue','Choose colors':'Red, Green'} if len(r['updatedInput']['questions'])==2 else {'Choose a color':'Blue'}
   assert r['updatedInput']['answers']==expected,r
  result()
