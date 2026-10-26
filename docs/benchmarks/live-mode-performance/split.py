"""UI-thread self time per frame split into Haxe (JIT) and native code, per run and phase, with the Haxe call rate.
Usage: split.py"""
import csv, json, os, re, collections

base = os.path.dirname(os.path.abspath(__file__))
RUNS = ['r1-plain', 'r2-watch', 'r3-live', 'r4b-live-patched']
WAITS = ('kernel32!Sleep', 'msvcp140!_Cnd_wait', 'kernel32!SleepConditionVariableSRW')
HAXE = re.compile(r'^(\$[a-z-]+:)?[a-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_$]+)+(\[.*\])?(<.*>)?(:.*)?$')

def frames(run, phase):
    marks = {}
    for line in open(os.path.join(base, 'runs', run, 'record.jsonl')):
        r = json.loads(line)
        if r.get('kind') == 'checkpoint': marks[r['label']] = r['at']
    a, b = marks[phase + '-start'], marks[phase + '-end']
    return sum(1 for l in open(os.path.join(base, 'runs', run, 'frames', 'frame-timeline.jsonl'))
               if a <= json.loads(l)['startedAtSeconds'] < b)

for phase in ('hover', 'scroll'):
    print(f'== {phase}: per frame on the UI thread')
    print(f'  {"run":18} {"frames":>6} {"haxe ms":>8} {"native ms":>9} {"wait ms":>8} {"haxe calls":>10} {"native calls":>12} {"ns/haxe call":>12}')
    for run in RUNS:
        rows = list(csv.reader(open(os.path.join(base, 'stats', f'{run}-{phase}.tsv'), encoding='utf-8', errors='replace'), delimiter='\t'))
        busy = collections.Counter()
        for tid, c, s, t, name in rows:
            if name not in WAITS: busy[tid] += float(s)
        ui = next(r[0] for r in sorted(rows, key=lambda r: -int(r[1])) if r[4] == 'haxeon.ui.core.RenderNode.walk'); n = frames(run, phase)
        hx = nat = wait = hc = nc = 0.0
        for tid, c, s, t, name in rows:
            if tid != ui: continue
            if name in WAITS: wait += float(s)
            elif HAXE.match(name): hx += float(s); hc += int(c)
            else: nat += float(s); nc += int(c)
        print(f'  {run:18} {n:6} {hx / n:8.2f} {nat / n:9.2f} {wait / n:8.2f} {hc / n:10.0f} {nc / n:12.0f} {1e6 * hx / max(hc, 1):12.0f}')
