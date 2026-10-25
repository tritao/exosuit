"""Compares per-function self time per frame across runs for one phase, on each run's busiest thread (the UI thread).
Usage: compare.py PHASE [TOP]"""
import csv, json, os, sys, collections

base = os.path.dirname(os.path.abspath(__file__))
RUNS = ['r1-plain', 'r2-watch', 'r3-live', 'r4b-live-patched']
phase = sys.argv[1]; top = int(sys.argv[2]) if len(sys.argv) > 2 else 30

def frames_in(run):
    marks = {}
    for line in open(os.path.join(base, 'runs', run, 'record.jsonl')):
        r = json.loads(line)
        if r.get('kind') == 'checkpoint': marks[r['label']] = r['at']
    a, b = marks[phase + '-start'], marks[phase + '-end']
    return sum(1 for l in open(os.path.join(base, 'runs', run, 'frames', 'frame-timeline.jsonl'))
               if a <= json.loads(l)['startedAtSeconds'] < b)

data, info = {}, {}
for run in RUNS:
    rows = list(csv.reader(open(os.path.join(base, 'stats', f'{run}-{phase}.tsv'), encoding='utf-8', errors='replace'), delimiter='\t'))
    per_tid = collections.Counter()
    for tid, count, self_ms, total_ms, name in rows:
        if name not in ('kernel32!Sleep', 'msvcp140!_Cnd_wait', 'kernel32!SleepConditionVariableSRW'):
            per_tid[tid] += float(self_ms)
    ui = next(r[0] for r in sorted(rows, key=lambda r: -int(r[1])) if r[4] == 'haxeon.ui.core.RenderNode.walk')
    n = frames_in(run)
    d = {}
    for tid, count, self_ms, total_ms, name in rows:
        if tid == ui: d[name] = (int(count) / n, float(self_ms) / n, float(total_ms) / n)
    data[run] = d
    info[run] = (ui, n, per_tid[ui] / n, sum(v[0] for v in d.values()))

print(f'phase {phase}: UI thread busy time per frame (instrumented calls, self, excluding waits)')
for run in RUNS:
    ui, n, busy, calls = info[run]
    print(f'  {run:18} tid {ui:>6}  {n:4} frames  {busy:7.2f} ms/frame  {calls:9.0f} calls/frame')

ref = data['r1-plain']
names = sorted(set().union(*[set(d) for d in data.values()]), key=lambda k: -max(d.get(k, (0, 0, 0))[1] for d in data.values()))
print(f'\ntop {top} by self ms/frame:  calls/frame | self ms/frame for ' + ' / '.join(RUNS))
for name in names[:top]:
    vals = [data[r].get(name, (0, 0, 0)) for r in RUNS]
    print(f'  {vals[0][0]:8.0f} | ' + ' '.join(f'{v[1]:7.3f}' for v in vals) + f'  {name[:110]}')

print('\nlargest increase, fresh live vs normal (self ms/frame):')
deltas = sorted(names, key=lambda k: -(data['r3-live'].get(k, (0, 0, 0))[1] - ref.get(k, (0, 0, 0))[1]))
for name in deltas[:top]:
    a, b, c = ref.get(name, (0, 0, 0)), data['r3-live'].get(name, (0, 0, 0)), data['r4b-live-patched'].get(name, (0, 0, 0))
    print(f'  +{b[1] - a[1]:6.3f} (patched +{c[1] - a[1]:6.3f})  calls {a[0]:7.0f}->{b[0]:7.0f}  self {a[1]:6.3f}->{b[1]:6.3f}  {name[:100]}')
