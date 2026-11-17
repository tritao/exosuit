#!/usr/bin/env python3
"""Native adapter tests; --real uses an installed Pi and a local mock model, never paid APIs."""
import json, os, shutil, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from test_driver import HL, MODE, ROOT, haxeon, run_tree, with_libraries

# --real: a local model the installed Pi talks to, in a Pi home of the test's own.
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

def configure_pi(fixture, environment, multiple_models=False):
 server=ThreadingHTTPServer(('127.0.0.1',0),Model)
 Model.requests=[]
 threading.Thread(target=server.serve_forever,daemon=True).start()
 agent=Path(fixture)/'pi-home';agent.mkdir()
 environment['PI_CODING_AGENT_DIR']=str(agent)
 for key in list(environment):
  if key.endswith('_API_KEY') or key in ('ANTHROPIC_AUTH_TOKEN','OPENAI_ACCESS_TOKEN','PI_NO_SESSION','PI_OFFLINE'):
   environment.pop(key)
 models=[{'id':'test-model','name':'Fixture','reasoning':multiple_models,'contextWindow':128000,'maxTokens':4096}]
 if multiple_models: models.append({**models[0],'id':'other-model','name':'Other fixture'})
 (agent/'models.json').write_text(json.dumps({'providers':{'fixture':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','api':'openai-completions','apiKey':'fixture','models':models}}}))
 (agent/'settings.json').write_text(json.dumps({'defaultProvider':'fixture','defaultModel':'test-model'}))
 skills=agent/'skills'/'fixture-skill';skills.mkdir(parents=True)
 (skills/'SKILL.md').write_text('---\nname: fixture-skill\ndescription: Fixture skill discovery\n---\nPI_SKILL_EXPANSION_MARKER: inspect the requested fixture.\n')
 prompts=agent/'prompts';prompts.mkdir()
 (prompts/'fixture-prompt.md').write_text('---\ndescription: Fixture prompt discovery\n---\nPI_TEMPLATE_EXPANSION_MARKER: $ARGUMENTS\n')
 extensions=agent/'extensions';extensions.mkdir()
 (extensions/'fixture.ts').write_text('export default function(pi) { pi.registerCommand("fixture-command", {description: "Fixture extension command", handler: async (_, ctx) => {ctx.ui.notify("PI_COMMAND_EXECUTED", "info");}}); }')
 return server

real='--real' in sys.argv[1:]
inputs='--inputs' in sys.argv[1:]
project=ROOT/'tests/pi-agents'/('real-inputs.haxeon.json' if real and inputs else 'real.haxeon.json' if real else 'inputs.haxeon.json' if inputs else 'haxeon.json')
binary=os.environ.get('EXOSUIT_PI_BIN') or shutil.which('pi')
if real and not binary:
 raise SystemExit('Install Pi or set EXOSUIT_PI_BIN before running --real')
haxeon(['build','--project',str(project),*MODE])
output=project.parent/'build/host'
# The fake is started with EXOSUIT_TEST_PYTHON.
env=dict(with_libraries(dict(os.environ),output/'native'),EXOSUIT_TEST_PYTHON=sys.executable)

with tempfile.TemporaryDirectory(prefix='exosuit-pi-',ignore_cleanup_errors=True) as temporary:
 # Staged images go under the temporary folder of the service (TEMP on Windows, TMPDIR elsewhere); the input test finds
 # its staged fixture in this folder.
 env=dict(env,TMPDIR=temporary,TEMP=temporary,TMP=temporary)
 server=configure_pi(temporary,env) if real else None
 try:
  run_tree([str(HL),str(output/'main.hl'),temporary,binary if real else str(project.parent/'fake-pi.py')],env,timeout=120,cwd=ROOT)
 finally:
  if server:server.shutdown();server.server_close()
 if real and not inputs:
  history=json.dumps(Model.requests[-1]['messages'])
  assert 'after-resume' in history and 'hello' in history and 'auto-edit' in history,'Native Pi resume lost conversation history'
  assert any('PI_SKILL_EXPANSION_MARKER' in json.dumps(r['messages']) for r in Model.requests),'Pi did not expand the chosen skill'
  assert any('PI_TEMPLATE_EXPANSION_MARKER' in json.dumps(r['messages']) for r in Model.requests),'Pi did not expand the prompt template'
  print('PASS: native Pi resume retained history and native skills/templates expanded')
 if real and inputs:
  def last_user(request):
   content=next(m['content'] for m in reversed(request['messages']) if m['role']=='user')
   return content if isinstance(content,str) else '\n'.join(p.get('text','') for p in content)
  delivered=[last_user(r) for r in Model.requests]
  assert 'real-removed' not in delivered and 'real-steer-cleared' not in delivered,delivered
  assert delivered.count('real-follow-up')==1 and delivered.count('real-after-stop')==1 and delivered.count('real-after-restart')==1,delivered
  assert any('PI_SKILL_EXPANSION_MARKER' in text for text in delivered),delivered
  assert 'real-uncertain-steer' not in delivered,delivered
  print('PASS: real Pi steering expansion, FIFO follow-ups, cancellation and explicit resume without duplicate API delivery')
 if not real:
  wire=[json.loads(line) for line in (Path(temporary)/'pi-wire.jsonl').read_text().splitlines()]
  prompts=[v['message'] for v in wire if v.get('type')=='prompt']
  if inputs:
   assert 'queue-cancelled' not in prompts and prompts.count('queue-delivered')==1,prompts
   assert prompts.count('queue-after-stop')==1 and prompts.count('queue-after-restart')==1,prompts
   assert prompts.count('steer-cleared')==1 and prompts.count('steer-delivered')==1 and prompts.count('lost-steer')==1,prompts
   assert prompts.count('queue-after-race')==1 and prompts.count('receipt-0')==1,prompts
   print('PASS: queued and steering messages were never automatically resent')
  else:
   assert prompts.count('crash')==1 and 'must-not-send' not in prompts,prompts
   assert prompts.count('hello')==1,prompts
   assert '/skill:fixture-skill investigate' in prompts and '/fixture-command' in prompts,prompts
   print('PASS: no duplicate or automatically resent prompt side effects')
