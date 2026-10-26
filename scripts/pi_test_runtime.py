"""Isolated real-Pi fixtures shared by native and desktop acceptance tests."""
import json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

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
