#!/usr/bin/env python3
"""Native adapter tests; --real uses an installed Pi and a local mock model, never paid APIs."""
import json, os, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
HAXEON=ROOT/'haxeon'
real='--real' in sys.argv[1:]
project=ROOT/'tests/pi-agents'/('real.haxeon.json' if real else 'haxeon.json')
binary=os.environ.get('EXOSUIT_PI_BIN') or shutil.which('pi')
if real and not binary:
 raise SystemExit('Install Pi or set EXOSUIT_PI_BIN before running --real')
subprocess.run([str(HAXEON/'scripts/haxeon'),'build','--project',str(project)],check=True)
output=project.parent/'build/host'
env=dict(os.environ)
env['LD_LIBRARY_PATH']=':'.join(str(p) for p in [HAXEON/'out',HAXEON/'.tools/hashlink',*sorted(p for p in (output/'native').iterdir() if p.is_dir())])

class Model(BaseHTTPRequestHandler):
 requests=[]
 def log_message(self,*_):pass
 def do_POST(self):
  request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  self.requests.append(request)
  messages=request['messages']
  last=messages[-1]
  users=[m for m in messages if m['role']=='user']
  content=users[-1]['content']
  text=content if isinstance(content,str) else '\n'.join(p.get('text','') for p in content)
  tool=None
  if last['role']=='user':
   if text in ('approval','decline','auto-edit','hold'):
    path={'approval':'approved.txt','decline':'declined.txt','auto-edit':'auto.txt','hold':'stopped.txt'}[text]
    tool={'index':0,'id':'call_'+str(len(messages)),'type':'function','function':{'name':'write','arguments':json.dumps({'path':path,'content':'approved'})}}
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  def emit(delta,finish=None):
   event={'id':'fixture','object':'chat.completion.chunk','model':'test-model','choices':[{'index':0,'delta':delta,'finish_reason':finish}]}
   self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode());self.wfile.flush()
  emit({'role':'assistant'})
  if tool:
   emit({'tool_calls':[tool]});emit({},'tool_calls')
  else:
   emit({'content':'Hello from real Pi'});emit({},'stop')
  self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()

with tempfile.TemporaryDirectory(prefix='exosuit-pi-') as temporary:
 server=None
 if real:
  server=ThreadingHTTPServer(('127.0.0.1',0),Model)
  threading.Thread(target=server.serve_forever,daemon=True).start()
  agent=Path(temporary)/'pi-home';agent.mkdir()
  env['PI_CODING_AGENT_DIR']=str(agent)
  # Remove ambient provider credentials and startup flags from this isolated fixture.
  for key in list(env):
   if key.endswith('_API_KEY') or key in ('ANTHROPIC_AUTH_TOKEN','OPENAI_ACCESS_TOKEN','PI_NO_SESSION','PI_OFFLINE'):
    env.pop(key)
  (agent/'models.json').write_text(json.dumps({'providers':{'fixture':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','api':'openai-completions','apiKey':'fixture','models':[{'id':'test-model','name':'Fixture','reasoning':False,'contextWindow':128000,'maxTokens':4096}]}}}))
  (agent/'settings.json').write_text(json.dumps({'defaultProvider':'fixture','defaultModel':'test-model'}))
 try:
  subprocess.run([str(HAXEON/'.tools/hashlink/hl'),str(output/'main.hl'),temporary,binary if real else str(project.parent/'fake-pi.py')],env=env,check=True,timeout=120)
 finally:
  if server:server.shutdown();server.server_close()
 if real:
  history=json.dumps(Model.requests[-1]['messages'])
  assert 'after-resume' in history and 'hello' in history and 'auto-edit' in history,'Native Pi resume lost conversation history'
  print('PASS: native Pi resume retained the earlier model conversation')
 if not real:
  wire=[json.loads(line) for line in (Path(temporary)/'pi-wire.jsonl').read_text().splitlines()]
  prompts=[v['message'] for v in wire if v.get('type')=='prompt']
  assert prompts.count('crash')==1 and 'must-not-send' not in prompts,prompts
  assert prompts.count('hello')==1,prompts
  print('PASS: no duplicate or automatically resent prompt side effects')
