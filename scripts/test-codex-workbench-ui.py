#!/usr/bin/env python3
"""Xvfb desktop acceptance with fake Codex, including saved conversation tabs."""
import json,os,signal,subprocess,tempfile,time,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
INSTALL=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else None
RUNNER=[str(INSTALL/'exosuit')] if INSTALL else [str(ROOT/'haxeon/scripts/haxeon'),'run','--project',str(ROOT/'graphical/haxeon.json'),'--']
with tempfile.TemporaryDirectory(prefix='excodexui-') as temporary:
 fixture=Path(temporary);project=fixture/'project';project.mkdir();state=fixture/'state'
 env=dict(os.environ,XDG_STATE_HOME=str(state),PRAGTICAL_PORTABLE=str(fixture/'settings'),EXOSUIT_CODEX_BIN=str(ROOT/'tests/workspace-agents/fake-codex.py'),EXOSUIT_AGENT_LAUNCHER=str(INSTALL/'tools/exosuit-agent.hl' if INSTALL else ROOT/'agent/build/host/main.hl'))
 if INSTALL: env.update(HAXEON_BIN='/no/source/compiler',HAXEON_ROOT='/no/source/tree',LD_LIBRARY_PATH='')
 app=None
 def nodes(index): return json.loads((fixture/str(index)/'layout.json').read_text())
 def locate(layout,label,focus=False):
  matching=[n for n in layout if n.get('label')==label and n['visible'] and (not focus or n.get('focusable')) and n['bounds']['width']>0]
  assert matching,(label,[n.get('label') for n in layout if n['visible']])
  return matching[0]['bounds']
 def click(window,b):
  subprocess.run(['xdotool','mousemove','--window',window,str(round(b['x']+b['width']/2)),str(round(b['y']+b['height']/2)),'click','1'],check=True)
 def field(window,layout,value):
  click(window,locate(layout,'Codex prompt',True))
  subprocess.run(['xdotool','key','--clearmodifiers','ctrl+a'],check=True)
  subprocess.run(['xdotool','type','--clearmodifiers','--delay','1',value],check=True)
 try:
  for index in range(8):
   capture=fixture/str(index)
   with (fixture/('app-'+str(index)+'.log')).open('w') as log:
    app=subprocess.Popen([*RUNNER,str(project),'--open-workbench','--capture-dir='+str(capture),'--capture-seconds=10'],env=env,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    window=subprocess.check_output(['timeout','60','xdotool','search','--sync','--onlyvisible','--name','^exosuit$'],text=True).splitlines()[0]
    subprocess.run(['xdotool','windowfocus','--sync',window],check=True);time.sleep(2)
    if index==1: click(window,locate(nodes(0),'New Codex'))
    elif index==2:
     click(window,locate(nodes(1),'Codex · idle'));time.sleep(1)
     # Opening changes the layout; capture here via the next restart before prompting.
    elif index==3:
     model_button=locate(nodes(2),'Choose model…')
     click(window,model_button);time.sleep(1)
     click(window,model_button)
     subprocess.run(['xdotool','key','--clearmodifiers','ctrl+a'],check=True)
     subprocess.run(['xdotool','type','--clearmodifiers','Fixture model'],check=True)
     subprocess.run(['xdotool','key','--clearmodifiers','Return'],check=True)
     time.sleep(.3)
     field(window,nodes(2),'hello')
     subprocess.run(['xdotool','key','--clearmodifiers','shift+KP_Enter'],check=True)
     time.sleep(.2)
     result=json.loads((project/'fake-codex.json').read_text())
     assert result['prompts']==0, 'Shift+keypad Enter submitted the draft'
     subprocess.run(['xdotool','type','--clearmodifiers','--delay','1','second line'],check=True)
     subprocess.run(['xdotool','key','--clearmodifiers','KP_Enter'],check=True)
    elif index==4: click(window,locate(nodes(3),'Approve once'))
    elif index==5:
     field(window,nodes(4),'choice=yes')
     click(window,locate(nodes(4),'Answer using prompt (id=value per line)'))
    elif index==6: click(window,locate(nodes(5),'Show details'))
    elif index==7:
     # Restored agent shares the editor rail; close its view through the tab button.
     layout=nodes(6)
     close=[n for n in layout if n.get('label')=='Close Codex' and n['visible']]
     if close: click(window,close[0]['bounds'])
     else: subprocess.run(['xdotool','key','--clearmodifiers','ctrl+w'],check=True)
    assert app.wait(timeout=90)==0,(fixture/('app-'+str(index)+'.log')).read_text()[-4000:]
    app=None
   diagnostic=json.loads((capture/'app-state.json').read_text())
   if index>=1:
    assert len(diagnostic['agentCatalog']['records'])==1,diagnostic
   if 2<=index<=6:
    assert len(diagnostic['agentTabs'])==1,diagnostic
   if index==5: assert diagnostic['agentCatalog']['records'][0]['state']=='completed',diagnostic
   if index==3:
    labels=[(n.get('label') or '') for n in nodes(index) if n['visible']]
    assert labels.count('Hello streamed world')==1,labels
    assert 'echo test' in labels and 'update README.md' in labels,labels
    assert 'Copy code' in labels and 'python' in labels,labels
    assert any(n.get('label')=='Code block: python' and n.get('focusable') for n in nodes(index)),nodes(index)
    assert not any('```python' in label for label in labels),labels
    assert 'Session details' in labels and 'Stop' not in labels,labels
    assert 'Enter to send · Shift+Enter for newline' in labels,labels
    sent=json.loads((project/'fake-codex.json').read_text())
    assert sent['lastPrompt']=='hello\nsecond line',sent
    assert sent['lastModel']=='fixture-model',sent
    assert not any('item/completed' in label for label in labels),labels
    wrapped=[n for n in nodes(index) if (n.get('label') or '').startswith('Wrapped conversation text')]
    assert len(wrapped)==1 and wrapped[0]['bounds']['height']>30,wrapped
   if index==6:
    assert any('Exit code: 0' in (n.get('label') or '') for n in nodes(index) if n['visible']),nodes(index)
   if index==7: assert diagnostic['agentTabs']==[],diagnostic
  result=json.loads((project/'fake-codex.json').read_text())
  assert result['starts']==1 and result['prompts']==1,result
  print('PASS: one-click Codex creation, shared editor tab, structured messages/commands/files, folded tool details, approval/input controls, saved resource restoration and close-view lifecycle')
 except Exception:
  for path in sorted(fixture.glob('app-*.log')): print(path.name+'\n'+path.read_text()[-3500:])
  raise
 finally:
  if app is not None and app.poll() is None: app.terminate();app.wait(timeout=10)
  for endpoint in state.glob('exosuit/workspaces/*/endpoint.json'):
   try: os.kill(json.loads(endpoint.read_text())['managerPid'],signal.SIGTERM)
   except (FileNotFoundError,ProcessLookupError): pass
