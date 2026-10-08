#!/usr/bin/env python3
"""Portable scripted drag-selection benchmark. Linux CI: xvfb-run -a python3 scripts/benchmark-selection-drag.py --output /tmp/selection-drag"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys

from haxeon_cli import run_cli

ROOT = Path(__file__).resolve().parent.parent

def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New directory for isolated fixture, trace, captures and results')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--app-binary', type=Path, help='Run frozen HashLink bytecode directly, without rebuilding')
    parser.add_argument('--native-library-dir', type=Path, help='Native UI libraries for a frozen-bytecode run')
    parser.add_argument('--analyze-only', action='store_true', help='Recompute results from an existing artifact directory')
    args = parser.parse_args()
    out = args.output.resolve()
    if args.analyze_only: return analyze(out)
    out.mkdir(parents=True, exist_ok=False)
    project = out / 'project'; project.mkdir()
    text = ''.join(f'{i:05d} ordinary editable source text with café and selection measurement; value = {i % 97};\n' for i in range(5000))
    fixture = project / 'medium.txt'; fixture.write_text(text, encoding='utf-8')
    events = []
    def add(at, kind, **fields): events.append(dict(at=round(at, 6), kind=kind, **fields))
    add(1, 'move', x=550, y=440)
    add(1.1, 'scroll', dx=0, dy=54000)
    add(2, 'checkpoint', label='middle')
    add(2.1, 'down', x=550, y=440)
    # Three down/up sweeps. Each has 0.75 s of motion and 1.25 s held outside
    # the viewport; stationary holds verify animation-driven edge scrolling.
    at = 2.2; current = 440
    for i, target in enumerate([850, 55, 850, 55, 850, 55]):
        for step in range(1, 46):
            add(at + step / 60, 'move', x=550, y=current + (target-current)*step/45)
        add(at + .85, 'checkpoint', label=f'edge-{i}')
        add(at + 2, 'checkpoint', label=f'hold-{i}')
        current = target; at += 2.1
    add(at, 'up', x=550, y=current)
    add(at + .2, 'checkpoint', label='released')
    script = out / 'scenario.json'; script.write_text(json.dumps(dict(version=1, events=events), indent=2)+'\n')
    environment = dict(PRAGTICAL_PORTABLE=str(out/'settings'), XDG_STATE_HOME=str(out/'state'),
                       EXOSUIT_AGENT_LAUNCHER=str(out/'no-agent-needed'))
    mode = ['--self-hosted'] if os.environ.get('HAXEON_SELF_HOSTED') == '1' else []
    if args.native_library_dir and not args.app_binary: parser.error("--native-library-dir requires --app-binary")
    if not args.skip_build and not args.app_binary:
        if run_cli(ROOT, ['build','--project',str(ROOT/'graphical/haxeon.json'),*mode]): return 1
    command = ['run','--project',str(ROOT/'graphical/haxeon.json'),*mode,'--',str(fixture),
               '--input-script='+str(script),'--capture-dir='+str(out/'capture'),
               '--capture-seconds=17','--record-path='+str(out/'events.jsonl')]
    toolchain=Path(os.environ.get('HAXEON_ROOT',str(ROOT/'haxeon')))
    runtime=next((toolchain/'.tools/hashlink'/name for name in ['libhl.so','libhl.dylib','libhl.dll','hl.dll'] if (toolchain/'.tools/hashlink'/name).exists()), None)
    binary=args.app_binary.resolve() if args.app_binary else ROOT/'graphical/build/host/main.hl'
    native_dir=args.native_library_dir.resolve() if args.native_library_dir else ROOT/'graphical/build/host/native/exosuit-ui-native'
    if args.app_binary:
        library_dirs=[native_dir, ROOT/'graphical/build/host/native/pluginhost', ROOT/'graphical/build/host/native/terminalkit', toolchain/'out', toolchain/'.tools/hashlink']
        variable='PATH' if os.name == 'nt' else ('DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH')
        environment[variable]=os.pathsep.join([str(p) for p in library_dirs]+[os.environ.get(variable,'')])
        hashlink=toolchain/'.tools/hashlink'/('hl.exe' if os.name == 'nt' else 'hl')
        status=subprocess.run([str(hashlink),str(binary),*command[command.index('--')+1:]],
                              cwd=ROOT, env={**os.environ,**environment}, check=False).returncode
    else:
        status=run_cli(ROOT, command, environment)
    native_ui=next((native_dir/name for name in ['libnativekit_ui.so','libnativekit_ui.dylib','nativekit_ui.dll','libnativekit_ui.dll'] if (native_dir/name).exists()),None)
    native_kit=next((native_dir/name for name in ['libnativekit.so','libnativekit.dylib','nativekit.dll','libnativekit.dll'] if (native_dir/name).exists()),None)
    identity=dict(runtimeSha256=hashlib.sha256(runtime.read_bytes()).hexdigest() if runtime else None,
                  nativeKitSha256=hashlib.sha256(native_kit.read_bytes()).hexdigest() if native_kit else None,
                  nativeUiSha256=hashlib.sha256(native_ui.read_bytes()).hexdigest() if native_ui else None,
                  gcThreads=os.environ.get('HL_GC_THREADS','default'), bytecodeSha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  platform=platform.platform(), frameGc=os.environ.get('MATERIA_FRAME_GC','default'))
    (out/'build.json').write_text(json.dumps(identity,indent=2)+'\n')
    if status: return status
    return analyze(out)

def analyze(out):
    fixture=out/'project/medium.txt'
    script=out/'scenario.json'
    events=json.loads(script.read_text())['events']
    frames = [json.loads(s) for s in (out/'capture/frame-timeline.jsonl').read_text().splitlines()]
    trace = [json.loads(s) for s in (out/'events.jsonl').read_text().splitlines()]
    checkpoints = {e['label']:e for e in trace if e['kind']=='checkpoint'}
    failures=[]
    def check(condition, message):
        if not condition: failures.append(message)
    check(len(checkpoints)==14, f'Missing checkpoints: {list(checkpoints)}')
    def selection(label):
        selections = checkpoints[label]['appState']['editorSelections']
        assert len(selections)==1, selections
        return selections[0]
    if any(label not in checkpoints for label in ['middle','released',*[f'{kind}-{i}' for i in range(6) for kind in ['edge','hold']]]):
        partial=dict(validationPassed=False,validationFailures=failures,checkpoints=checkpoints,frameCount=len(frames))
        (out/'result.json').write_text(json.dumps(partial,indent=2)+'\n')
        print(json.dumps(partial,indent=2)); return 1
    middle = selection('middle')
    anchor=selection('edge-0')
    check(1500 < anchor['anchorLine'] < 3500, f'Not in middle of file: {anchor}')
    for i in range(6):
        edge, hold = selection(f'edge-{i}'),selection(f'hold-{i}')
        check((hold['scrollY']-edge['scrollY'])*(1 if i%2==0 else -1) > 100, f'Edge auto-scroll failed during hold {i}')
        check((hold['anchorLine'],hold['anchorColumn']) == (selection('released')['anchorLine'],selection('released')['anchorColumn']), 'Drag anchor moved')
    final=selection('released')
    check(final['cursorLine'] != final['anchorLine'], f'No multiline selection: {final}')
    check(checkpoints['released']['delivered']==sum(e['kind']!='checkpoint' for e in events), 'Dropped scripted input')
    start,end=checkpoints['middle']['at'],checkpoints['released']['at']
    active=[f for f in frames if start<=f['startedAtSeconds']<=end+.25]
    inputs=[f for f in active if f.get('scriptedInputCount',0)>0]
    middle_at=next(e['at'] for e in events if e.get('label')=='middle')
    expected=sum(e['kind']!='checkpoint' and e['at']>middle_at for e in events)
    check(sum(f['scriptedInputCount'] for f in inputs)==expected, 'Some drag input had no measured completion frame')
    check(len(inputs)>20, f'Insufficient input frames: {len(inputs)}')
    def stats(values):return dict(p50=percentile(values,.5),p95=percentile(values,.95),p99=percentile(values,.99),max=max(values) if values else None)
    identity=json.loads((out/'build.json').read_text()) if (out/'build.json').exists() else {}
    result=dict(validationPassed=not failures, validationFailures=failures, platform=platform.platform(), bytes=fixture.stat().st_size, lines=5000,
        scenarioSha256=hashlib.sha256(script.read_bytes()).hexdigest(),
        metric='script deadline to completed frame; excludes OS input delivery and display scanout',
        inputTimingVersion=2 if inputs and all(f.get('scriptedInputDeliveryAgeSeconds') is not None for f in inputs) else 1,
        inputFrames=len(inputs), activeFrames=len(active),
        phasesMs={field:stats([1000*f[field] for f in active if f.get(field) is not None]) for field in ['prepareSeconds','applicationSubmitSeconds','contextRenderSeconds','viewSeconds','nativeLayoutSeconds','nativeRenderSeconds','frameGcSeconds']},
        inputLatencyMs=stats([1000*(f['scriptedInputRequestAgeSeconds']+f['frameSeconds']) for f in inputs]),
        scheduledInputToFrameStartMs=stats([1000*f['scriptedInputRequestAgeSeconds'] for f in inputs]),
        scheduledInputToDeliveryMs=stats([1000*(f['scriptedInputRequestAgeSeconds']-f['scriptedInputDeliveryAgeSeconds']) for f in inputs if f.get('scriptedInputDeliveryAgeSeconds') is not None]),
        deliveredInputToFrameCompleteMs=stats([1000*(f['scriptedInputDeliveryAgeSeconds']+f['frameSeconds']) for f in inputs if f.get('scriptedInputDeliveryAgeSeconds') is not None]),
        latestFrameRequestToStartMs=stats([1000*f['requestAgeSeconds'] for f in inputs if f.get('requestAgeSeconds') is not None]),
        frameMs=stats([1000*f['frameSeconds'] for f in active]),
        dispatchMs=stats([1000*f['scriptedInputDispatchSeconds'] for f in inputs]),
        frameGapMs=stats([1000*(b['startedAtSeconds']-a['startedAtSeconds']) for a,b in zip(active,active[1:])]),
        frameAllocationBytes=stats([f['allocatedBytes'] for f in active]),
        gcCollections=sum(f.get('gcCollections',0) for f in active),
        maxGcPauseMs=max((1000*f.get('gcLastPauseSeconds',0) for f in active),default=0),
        framesOver16ms=sum(f['frameSeconds']>1/60 for f in active),
        checkpoints={label:selection(label) for label in checkpoints},
        build=identity)
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='checkpoints'},indent=2))
    return 0 if not failures else 1

if __name__=='__main__':raise SystemExit(main())
