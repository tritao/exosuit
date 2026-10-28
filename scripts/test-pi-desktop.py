#!/usr/bin/env python3
"""Run under Xvfb: real desktop controls, real Pi CLI, isolated local mock model."""
import hashlib, json, os, shutil, subprocess, tempfile, time, sys
from pathlib import Path
from agent_test_runtime import manager_command, manager_environment
from pi_test_runtime import Model, configure_pi
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

ROOT=Path(__file__).resolve().parent.parent
HAXEON=ROOT/'haxeon'
BINARY=os.environ.get('EXOSUIT_PI_BIN') or shutil.which('pi')
if not BINARY: raise SystemExit('Install Pi or set EXOSUIT_PI_BIN')
if not os.environ.get('DISPLAY'): raise SystemExit('Run with xvfb-run -a python3 scripts/test-pi-desktop.py')
if os.environ.get('PI_UI_SKIP_BUILD') != '1':
 for project in ('agent','graphical'):
  subprocess.run([str(HAXEON/'scripts/haxeon'),'build','--project',str(ROOT/project/'haxeon.json')],check=True)

with tempfile.TemporaryDirectory(prefix='exosuit-pi-ui-') as temporary:
 fixture=Path(temporary);project=fixture/'project';project.mkdir()
 environment=dict(os.environ,XDG_STATE_HOME=str(fixture/'state'),PRAGTICAL_PORTABLE=str(fixture/'settings'),EXOSUIT_PI_BIN=BINARY,
  EXOSUIT_AGENT_LAUNCHER=str(ROOT/'agent/build/host/main.hl'))
 for key in ('EXOSUIT_AGENT_STATE_HOME','EXOSUIT_PI_SCRIPT','EXOSUIT_STABLE_BUNDLE','EXOSUIT_AGENT_ALWAYS_AVAILABLE'):
  environment.pop(key,None)
 model=configure_pi(fixture,environment,multiple_models=True)
 manager_env=manager_environment(ROOT);manager_env.update(environment)
 manager_env['LD_LIBRARY_PATH']=manager_environment(ROOT)['LD_LIBRARY_PATH']
 native=ROOT/'graphical/build/host/native'
 environment['LD_LIBRARY_PATH']=':'.join(map(str,[HAXEON/'out',HAXEON/'.tools/hashlink',*sorted(p for p in native.iterdir() if p.is_dir())]))
 manager=None;app=None;layout=[];snapshot=None;window=None
 title='Pi-acceptance-'+str(os.getpid())
 def xdo(*args):return subprocess.check_output(['xdotool',*args],text=True).strip()
 def locate(label):
  nodes=[n for n in layout if n.get('label')==label and n['visible'] and n['bounds']['width']>0]
  assert nodes,(label,[n.get('label') for n in layout if n.get('label') and n['visible']])
  return nodes[0]['bounds']
 def click(label):
  b=locate(label)
  xdo('mousemove','--window',window,'5','5');time.sleep(.05)
  xdo('mousemove','--window',window,str(round(b['x']+b['width']/2)),str(round(b['y']+b['height']/2)));time.sleep(.15);xdo('click','1')
 def keys(*args):xdo('key','--clearmodifiers',*args)
 def type_text(text):xdo('type','--clearmodifiers','--delay','1',text)
 def prompt(text):
  click('Pi prompt');keys('ctrl+a');type_text(text);time.sleep(.15);keys('Return')
 def phase(name,action=None):
  global app,window,layout,snapshot
  capture=fixture/name
  with (fixture/(name+'.log')).open('w') as log:
   app=subprocess.Popen([str(HAXEON/'.tools/hashlink/hl'),str(ROOT/'graphical/build/host/main.hl'),str(project),
    '--open-workbench','--title='+title,'--record-path='+str(fixture/(name+'-input.jsonl')),'--capture-dir='+str(capture),'--capture-seconds=8'],cwd=ROOT,env=environment,stdout=log,stderr=subprocess.STDOUT)
   end=time.monotonic()+30
   while True:
    result=subprocess.run(['xdotool','search','--onlyvisible','--pid',str(app.pid),'--name',title],capture_output=True,text=True)
    if result.returncode==0 and result.stdout.strip():window=result.stdout.splitlines()[0];break
    assert app.poll() is None,(fixture/(name+'.log')).read_text()
    assert time.monotonic()<end,'Desktop window did not open'
    time.sleep(.05)
   while 'first frame ready' not in (fixture/(name+'.log')).read_text():
    assert time.monotonic()<end,'First frame did not render';time.sleep(.05)
   xdo('windowsize',window,'1280','1000');xdo('windowfocus','--sync',window)
   time.sleep(3)
   if action:action()
   assert app.wait(timeout=30)==0,(fixture/(name+'.log')).read_text()[-5000:]
   app=None
  snapshot=json.loads((capture/'app-state.json').read_text())
  layout=json.loads((capture/'layout.json').read_text())
  assert not snapshot['errors'],snapshot['errors']
  print('PASS: desktop phase '+name,flush=True)
  return snapshot.get('activeAgentSummary')
 def state(expected):
  summary=snapshot.get('activeAgentSummary')
  assert summary and summary['state']==expected,(expected,summary)
 try:
  with (fixture/'manager.log').open('w') as log:
   manager=subprocess.Popen([*manager_command(ROOT),str(project),'--idle-seconds','300'],env=manager_env,stdout=log,stderr=subprocess.STDOUT)
  endpoint=fixture/'state/exosuit/workspaces'/hashlib.sha256(str(project).encode()).hexdigest()[:20]/'endpoint.json'
  end=time.monotonic()+45
  while not endpoint.exists():
   assert manager.poll() is None,(fixture/'manager.log').read_text()
   assert time.monotonic()<end,'Fixture manager failed to start'
   time.sleep(.05)
  phase('00-workbench')
  phase('01-menu',lambda:click('Workbench actions'))
  def create():
   click('Workbench actions');time.sleep(.3);click('New Pi session');time.sleep(2.5)
   # Creation must focus Pi's composer without a separate click.
   type_text('hello');time.sleep(.2);keys('Return')
  phase('01-create-and-send',create);state('completed')
  session=snapshot['activeAgentSummary']['thread']
  if '--inputs' in sys.argv[1:]:
   def compose(text,button):
    click('Pi prompt');keys('ctrl+a');type_text(text);time.sleep(.2);click(button)
   def last_user(request):
    content=next(m['content'] for m in reversed(request['messages']) if m['role']=='user')
    return content if isinstance(content,str) else '\n'.join(p.get('text','') for p in content)
   phase('inputs-01-wait',lambda:prompt('approval'));state('needs-attention')
   count=len(Model.requests)
   phase('inputs-02-queue',lambda:compose('desktop-removed','Queue message'));state('needs-attention')
   assert any('desktop-removed' in (n.get('label') or '') for n in layout),'Queued message not displayed'
   assert len(Model.requests)==count,'Queued follow-up started before the active turn ended'
   phase('inputs-03-rejected-steer',lambda:compose('/fixture-command','Steer now'));state('needs-attention')
   assert any(n.get('label')=='Pi prompt' and n.get('value')=='/fixture-command' for n in layout),'Rejected steering erased the draft'
   phase('inputs-04-steer',lambda:compose('desktop-steer','Steer now'));state('needs-attention')
   assert any('desktop-steer' in (n.get('label') or '') for n in layout),'Native pending steer was not displayed'
   phase('inputs-05-remove',lambda:click('Remove queued message'));state('needs-attention')
   phase('inputs-06-follow-up',lambda:compose('desktop-follow-up','Queue message'));state('needs-attention')
   phase('inputs-07-approve',lambda:click('Approve once'));state('completed')
   delivered=[last_user(r) for r in Model.requests]
   assert delivered.count('desktop-follow-up')==1 and 'desktop-removed' not in delivered,delivered
   assert 'desktop-steer' in json.dumps(Model.requests[-1]['messages']),'Steer did not reach the current conversation'
   phase('inputs-08-stop-wait',lambda:prompt('hold'));state('needs-attention')
   phase('inputs-09-retained',lambda:compose('desktop-retained','Queue message'));state('needs-attention')
   phase('inputs-10-stop',lambda:click('Stop'));state('interrupted')
   count=len(Model.requests)
   phase('inputs-11-resume-pi',lambda:click('Resume session'));state('idle')
   assert len(Model.requests)==count,'Pi reconnect automatically resent pending messages'
   phase('inputs-12-resume-queue',lambda:click('Resume queued messages'));state('completed')
   delivered=[last_user(r) for r in Model.requests]
   assert delivered.count('desktop-retained')==1,delivered
   assert snapshot['activeAgentSummary']['thread']==session,'Queue recovery changed the native conversation'
   print('PASS: desktop Queue/Steer controls, preserved rejected draft, pending display/removal, FIFO delivery, paused recovery and explicit queue resume',flush=True)
  else:
   def settings():
    click('Model');keys('ctrl+a');type_text('Other fixture');time.sleep(.2);keys('Return');time.sleep(.6)
    # Reasoning selector is immediately to the right of the model control.
    click('Reasoning effort');keys('End');time.sleep(.15);keys('Return')
   phase('02-model-thinking',settings)
   record=snapshot['agentCatalog']['records'][0]
   assert record['preferredModel']=='fixture/other-model' and record['preferredEffort']=='high',record
   phase('03-approval',lambda:prompt('approval'));state('needs-attention')
   phase('04-approve',lambda:click('Approve once'));state('completed')
   assert (project/'approved.txt').read_text()=='approved'
   phase('05-decline-request',lambda:prompt('decline'));state('needs-attention')
   phase('06-decline',lambda:click('Decline'));state('completed')
   assert not (project/'declined.txt').exists()
   phase('07-stop-request',lambda:prompt('hold'));state('needs-attention')
   phase('08-stop',lambda:click('Stop'));state('interrupted')
   assert not (project/'stopped.txt').exists()
   def resume():
    click('Resume session');time.sleep(1.4);prompt('after-resume')
   phase('09-resume',resume);state('completed')
   assert snapshot['activeAgentSummary']['thread']==session
   def skill_suggestions():
    # Every phase opens a fresh window with the composer focused; the previous
    # capture may contain suggestions that shifted the field vertically.
    keys('ctrl+a');type_text('$fi')
   b=locate('Pi prompt');assert b['y']>=80 and b['y']+b['height']<=974,'History pushed the composer out of the viewport'
   phase('10-skill-suggestions',skill_suggestions)
   assert any('$fixture-skill' in (n.get('label') or '') and n['visible'] for n in layout),'Missing skill suggestions'
   def skill():
    skill_suggestions();time.sleep(.2)
    count=len(Model.requests);keys('Tab');time.sleep(.2)
    assert len(Model.requests)==count,'Selecting a skill sent it immediately'
    type_text('investigate');keys('Return')
   phase('11-skill-keyboard',skill);state('completed')
   assert 'PI_SKILL_EXPANSION_MARKER' in json.dumps(Model.requests[-1]['messages'])
   def command_suggestions():
    keys('ctrl+a');type_text('/fixture-c')
   phase('12-command-suggestions',command_suggestions)
   suggestion=next(n['label'] for n in layout if n['visible'] and '/fixture-command' in (n.get('label') or ''))
   def command():
    command_suggestions();time.sleep(.2);click(suggestion);time.sleep(.2);keys('Return');time.sleep(.5)
    xdo('mousemove','--window',window,'700','400');time.sleep(.1);xdo('click','--repeat','35','--delay','15','5')
   count=len(Model.requests)
   phase('13-command-pointer',command);state('completed')
   assert len(Model.requests)==count,'Native extension command was sent to the model'
   assert any(n.get('label')=='PI_COMMAND_EXECUTED' and n['visible'] for n in layout),'Extension command result not displayed'
   # A new editor process has been attached for every phase; now restart the service as well.
   manager.terminate();assert manager.wait(timeout=10)==0;manager=None
   with (fixture/'manager-restart.log').open('w') as log:
    manager=subprocess.Popen([*manager_command(ROOT),str(project),'--idle-seconds','300'],env=manager_env,stdout=log,stderr=subprocess.STDOUT)
   end=time.monotonic()+30
   while not endpoint.exists():
    assert time.monotonic()<end,'Manager restart failed';time.sleep(.05)
   phase('14-daemon-restart')
   phase('15-resume-after-restart',resume);state('completed')
   assert snapshot['activeAgentSummary']['thread']==session
   history=json.dumps(Model.requests[-1]['messages'])
   assert 'hello' in history and 'after-resume' in history,'Native history was lost'
   print('PASS: actual desktop Pi creation/focus, model/thinking controls, approvals, stop, editor reattachment, skills/commands and daemon resume',flush=True)

 finally:
  if app and app.poll() is None:app.terminate();app.wait(timeout=10)
  if manager and manager.poll() is None:manager.terminate();manager.wait(timeout=10)
  (fixture/'model-requests.json').write_text(json.dumps(Model.requests,indent=2))
  model.shutdown();model.server_close()
  artifacts=os.environ.get('PI_UI_ARTIFACTS')
  if artifacts:
   destination=Path(artifacts);destination.mkdir(parents=True,exist_ok=True)
   for source in fixture.iterdir():
    if source.name in ('state','settings','pi-home','project'):continue
    if source.is_dir():shutil.copytree(source,destination/source.name,dirs_exist_ok=True)
    else:shutil.copy2(source,destination/source.name)
   print('Artifacts: '+str(destination),flush=True)
