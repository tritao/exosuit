#!/usr/bin/env python3
"""Run under Xvfb. Real Workbench clicks, workspace RPC and per-rendered-frame diagnostics."""
import argparse,json,math,os,signal,subprocess,sys,time,tempfile
from pathlib import Path
from agent_test_runtime import manager_environment
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--responsive',action='store_true',help='Resize the window through responsive pane transitions')
p.add_argument('--resize',action='store_true',help='Drag the Workbench divider while a synchronized TUI redraws')
p.add_argument('--pixels',action='store_true',help='Capture every rendered frame; excludes meaningful latency measurements')
p.add_argument('--skip-build',action='store_true')
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
(out/'frames').mkdir();(out/'state').symlink_to(tempfile.mkdtemp(prefix='ess-'));project=out/'project';project.mkdir();settings=out/'settings';settings.mkdir()
(settings/'settings.json').write_text(json.dumps({'values':{'workbench/agents/session_mode':'terminal'}}))
# Generate the instrumented entry from the current production entry; keep startup identical.
fixture=ROOT/'tests/session-switch-benchmark'
source=(ROOT/'graphical/src/app/GraphicalMain.hx').read_text()
marker='var app:Null<ExosuitApp> = null;'
assert source.count(marker)==1
source=source.replace('class GraphicalMain {','@:access(ui.TerminalPane)\nclass SessionSwitchBenchmarkMain {').replace(marker,(fixture/'frame-probe.hx.inc').read_text().strip())
source=source.replace('app = instance;', 'var priorPoll = context.onPoll;\n            context.onPoll = function() {\n                if (pendingPixelFrame >= 0) {\n                    Sys.command("import", ["-window",host.title, haxe.io.Path.directory(report) + "/frame-" + pendingPixelFrame + ".png"]);\n                    pendingPixelFrame = -1;\n                }\n                if (priorPoll != null) priorPoll();\n            };\n            app = instance;')
entry=fixture/'src/app/SessionSwitchBenchmarkMain.hx';entry.parent.mkdir(parents=True,exist_ok=True);entry.write_text(source)
if not a.skip_build:
 for name in ['agent','tests/session-switch-benchmark']:
  subprocess.run([str(ROOT/'haxeon/scripts/haxeon'),'build','--project',str(ROOT/name/'haxeon.json')],check=True)
fixture=ROOT/'tests/session-switch-benchmark';native=fixture/'build/host/native'
env=manager_environment(ROOT);env.update(HAXEON_ROOT=str(ROOT/'haxeon'),XDG_STATE_HOME=str((out/'state').resolve()),PRAGTICAL_PORTABLE=str(settings),EXOSUIT_SWITCH_REPORT=str(out/'frames'),EXOSUIT_SWITCH_PIXELS='1' if a.pixels else '0')
env['LD_LIBRARY_PATH']=':'.join([str(x) for x in native.iterdir() if x.is_dir()]+[env.get('LD_LIBRARY_PATH','')])
fake=out/'fake-codex.py'
fake.write_text('import os,sys\nprint("\\033[?25l\\033[?1003h\\033[?1006hSESSION_"+str(os.getpid())+"\\r\\n"+("agent content "+str(os.getpid())+"\\r\\n")*15,flush=True)\nfor line in sys.stdin: pass\n')
if a.resize:
 fake.write_text("import os,signal,sys,time\nchanged=True\nsignal.signal(signal.SIGWINCH,lambda *_: globals().__setitem__('changed',True))\nprint('\\x1b[?25l\\x1b[?1003h\\x1b[?1006h',end='',flush=True)\nwhile True:\n if changed:\n  changed=False\n  print('\\x1b[?2026h\\x1b[2J\\x1b[HPARTIAL_RESIZE',end='',flush=True)\n  time.sleep(.06)\n  print('\\x1b[HSESSION_'+str(os.getpid())+' COMPLETE RESIZE\\r\\n'+('complete content\\r\\n'*15),end='',flush=True)\n  time.sleep(.06)\n  print('\\x1b[?2026l',end='',flush=True)\n time.sleep(.005)\n")
env.update(EXOSUIT_CODEX_BIN=sys.executable,EXOSUIT_CODEX_SCRIPT=str(fake))
log=(out/'app.log').open('w');app=subprocess.Popen([str(ROOT/'haxeon/.tools/hashlink/hl'),str(fixture/'build/host/main.hl'),str(project),'--open-workbench','--title=Session switch benchmark','--capture-dir='+str(out/'capture'),'--capture-seconds=120'],env=env,cwd=ROOT,stdout=log,stderr=log)
def frames():
 try:return [json.loads(p.read_text()) for p in sorted((out/'frames').glob('*.json'),key=lambda p:int(p.stem))]
 except (FileNotFoundError,json.JSONDecodeError):return []
def wait(pred):
 end=time.monotonic()+30
 while time.monotonic()<end:
  fs=frames()
  if fs and pred(fs[-1]):return fs[-1]
  assert app.poll() is None,(out/'app.log').read_text()[-3000:]
  time.sleep(.01)
 raise AssertionError('Timed out: '+str(frames()[-1:])[-2000:])
def xdo(*args):return subprocess.check_output(['xdotool',*map(str,args)],text=True).strip()
def click(b):
 xdo('mousemove','--window',window,round(b['x']+b['width']/2),round(b['y']+b['height']/2))
 at=time.time();xdo('mousedown',1,'mouseup',1);return at
try:
 f=wait(lambda f:f['state']['testTargets']['newCodex'] is not None and f['state']['terminalCatalog'] is not None)
 window=xdo('search','--onlyvisible','--name','^Session switch benchmark$').splitlines()[-1];xdo('windowfocus','--sync',window)
 for n in range(2):
  click(f['state']['testTargets']['newCodex'])
  f=wait(lambda f:len(f['state']['terminalEditorTabs'])==n+1 and 'SESSION_' in str(f['state']['terminalScreen']))
  time.sleep(.2)
 f=wait(lambda f:len([x for x in f['state']['treeItems'] if x['key'].startswith('t:')])==2);rows=[x for x in f['state']['treeItems'] if x['key'].startswith('t:')]
 assert len(rows)==2,rows
 if a.responsive:
  observations=[]
  for width in [1200,960,840,713,680,640,600,660,700,840,960,1200]:
   xdo('windowsize','--sync',window,width,840)
   f=wait(lambda f:f['state']['viewport']['width']==width)
   time.sleep(.15);f=frames()[-1]
   terminal=f['state']['testTargets']['terminalPane'];right=any(n['key']=='context-panel-content' for n in f['nodes'])
   observations.append({'width':width,'compact':f['state']['viewport']['phoneLayout'],'sidebar':f['state']['viewport']['sidebarVisible'],'right':right,'terminalWidth':terminal['width'] if terminal else 0})
   assert terminal is not None,'Responsive resize replaced the active terminal with navigation'
   assert width>713 or not right,'Secondary panel remained at narrow width'
  assert observations[-1]['right'],'Widening did not restore the preferred right panel'
  xdo('windowsize','--sync',window,600,840);f=wait(lambda f:f['state']['viewport']['width']==600)
  click(f['state']['testTargets']['workbenchActivity']);f=wait(lambda f:f['state']['viewport']['sidebarVisible'])
  row=next(x for x in f['state']['treeItems'] if x['key'].startswith('t:'));click(row['bounds'])
  f=wait(lambda f:not f['state']['viewport']['sidebarVisible'] and f['state']['testTargets']['terminalPane'] is not None)
  assert len(f['state']['terminalEditorTabs'])==2,'Responsive navigation replaced terminal sessions'
  result={'scenario':'responsive-window','observations':observations,'drawerSelectionPassed':True}
  (out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));sys.exit(0)
 if a.resize:
  first=frames()[-1]['index']
  for side in ('left','right'):
   f=frames()[-1];terminal=f['state']['testTargets']['terminalPane']
   x=round(terminal['x']-2 if side=='left' else terminal['x']+terminal['width']+2);y=round(terminal['y']+200)
   xdo('mousemove','--window',window,x,y);xdo('mousedown',1)
   for offset in [*range(0,161,8),*range(160,-81,-8),*range(-80,1,8)]:
    xdo('mousemove','--window',window,x+offset,y);time.sleep(.04)
   xdo('mouseup',1);time.sleep(.7)
  fs=[f for f in frames() if f['index']>first]
  partial=[f['index'] for f in fs if 'PARTIAL_RESIZE' in str(f.get('renderedTerminalRows',[]))]
  empty=[f['index'] for f in fs if not any('SESSION_' in row for row in f.get('renderedTerminalRows',[]))]
  widths=sorted(set(f['state']['terminalColumns'] for f in fs))
  captured=sum((out/f"frame-{f['index']}.png").exists() for f in fs)
  pixel_failures=[]
  if a.pixels:
   from PIL import Image
   time.sleep(.3)
   for f in fs:
    n=next((n for n in f['nodes'] if n['key']=='terminal-pane'),None)
    path=out/f"frame-{f['index']}.png"
    if n is None or not path.exists():pixel_failures.append(f['index']);continue
    im=Image.open(path).convert('RGB');x=round(n['x']);y=round(n['y']);bg=im.getpixel((x+4,y+4))
    ink=sum(max(abs(c-b) for c,b in zip(im.getpixel((xx,yy)),bg))>40
      for xx in range(x+8,x+200) for yy in range(y+4+2*19,y+4+5*19))
    if ink<150:pixel_failures.append(f['index'])
  result={'scenario':'panel-resize','frames':len(fs),'columnCounts':widths,'partialFrames':partial,'emptyFrames':empty,'screenshots':captured,'pixelFailures':pixel_failures}
  (out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
  assert len(widths)>5,'Divider drag did not resize the terminal'
  assert not partial and not empty and not pixel_failures,'Resize exposed an incomplete terminal frame'
  sys.exit(0)
 events=[]
 for i in range(24):
  row=rows[i%2];before=frames()[-1]['index'];at=click(row['bounds'])
  f=wait(lambda f:f['index']>before and f['state']['workbenchSelectedNode']==row['key'] and f.get('pointerUpAt',0)>=at)
  events.append({'at':at,'before':before,'observedAt':f['at'],'frame':f['index'],'selected':f['state']['workbenchSelectedNode'],'label':row['key'],'latencyMs':(f['at']-at)*1000,'clickReleaseToRenderMs':(f['at']-f['pointerUpAt'])*1000})
  time.sleep(.08)
 (out/'events.json').write_text(json.dumps(events,indent=2))
 fs=frames();failures=[]
 markers={}
 for f in fs:
  text=(f['state'].get('terminalScreen') or {}).get('lines',[])
  if text and text[0].startswith('SESSION_'):markers.setdefault(f['state']['workbenchSelectedNode'],text[0])
 for e in events:
  relevant=[f for f in fs if e['before']<f['index']<=e['frame']]
  for f in relevant:
   text='\n'.join((f['state'].get('terminalScreen') or {}).get('lines',[]))
   if f.get('pointerUpAt',0)>=e['at'] and f['state']['workbenchSelectedNode']!=e['selected']:failures.append({'frame':f['index'],'error':'stale selection after click release'})
   if markers.get(f['state']['workbenchSelectedNode']) not in text:failures.append({'frame':f['index'],'error':'blank terminal'})
   if not any(n['key']=='terminal-pane' for n in f['nodes']):failures.append({'frame':f['index'],'error':'missing terminal view'})
 pixel_checks=0
 if a.pixels:
  from PIL import Image
  import hashlib,collections
  pixel_hashes=collections.defaultdict(collections.Counter)
  for f in fs:
   if f['index']<=events[0]['before']:continue
   n=next((n for n in f['nodes'] if n['key']=='terminal-pane'),None)
   if n is None:continue
   path=out/f"frame-{f['index']}.png"
   if not path.exists():
    # The final callback may have been recorded before its post-presentation capture.
    time.sleep(.2)
   if not path.exists():failures.append({'frame':f['index'],'error':'missing presented screenshot'});continue
   im=Image.open(path).convert('RGB');x=round(n['x']);y=round(n['y'])
   crop=im.crop((x+80,y+4+3*19,x+250,y+4+10*19))
   digest=hashlib.sha256(crop.tobytes()).hexdigest()
   pixel_hashes[f['state']['workbenchSelectedNode']][digest]+=1;pixel_checks+=1
  for selected,counts in pixel_hashes.items():
   if len(counts)!=1:failures.append({'selected':selected,'error':'inconsistent presented session pixels','hashes':dict(counts)})
  if len(pixel_hashes)!=2 or len({next(iter(v)) for v in pixel_hashes.values()})!=2:
   failures.append({'error':'two sessions did not render distinct pixel content'})
 values=sorted(e['latencyMs'] for e in events)
 delivered=sorted(e['clickReleaseToRenderMs'] for e in events)
 result={'presentedPixelChecks':pixel_checks,'clickReleaseToRenderMs':{'median':delivered[len(delivered)//2],'p95':delivered[math.ceil(len(delivered)*.95)-1],'max':max(delivered)},'switches':len(events),'pixels':a.pixels,'latencyMs':{'median':values[len(values)//2],'p95':values[math.ceil(len(values)*.95)-1],'max':max(values)},'unexpectedFrames':failures,'scope':'X11 injection to completed render callback; includes process dispatch, excludes physical display; diagnostics serialized after timestamp'}
 (out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));assert not failures
finally:
 app.terminate();app.wait(timeout=10);log.close()
 for ep in (out/'state').glob('exosuit/workspaces/*/endpoint.json'):
  try:os.kill(json.loads(ep.read_text())['managerPid'],signal.SIGTERM)
  except (OSError,KeyError):pass
