"""Per-phase frame-time summary for each run, from the app's own frame records and scripted checkpoints.
Usage: frames.py RUN_DIR..."""
import json, sys, statistics as st, os

def pct(values, p):
    if not values: return float('nan')
    v = sorted(values); return v[min(len(v) - 1, int(p / 100 * len(v)))]

FIELDS = ['frameSeconds', 'treeAndStyleSeconds', 'applicationSubmitSeconds', 'nativeLayoutSeconds', 'renderSeconds', 'gcSeconds']
for run in sys.argv[1:]:
    frames = [json.loads(l) for l in open(os.path.join(run, 'frames', 'frame-timeline.jsonl'))]
    marks = {}
    for line in open(os.path.join(run, 'record.jsonl')):
        r = json.loads(line)
        if r.get('kind') == 'checkpoint': marks[r['label']] = r['at']
    print(f"== {os.path.basename(run)}: {len(frames)} frames; checkpoints: {', '.join(sorted(marks, key=marks.get))}")
    for phase, a, b in (('hover', 'hover-start', 'hover-end'), ('scroll', 'scroll-start', 'scroll-end')):
        if a not in marks or b not in marks: print(f"  {phase}: missing checkpoints"); continue
        sel = [f for f in frames if marks[a] <= f['startedAtSeconds'] < marks[b]]
        span = marks[b] - marks[a]
        line = f"  {phase:6} {len(sel):4} frames in {span:5.1f}s ({len(sel)/span:5.1f} fps)"
        for k in FIELDS:
            vals = [f.get(k) or 0.0 for f in sel]
            line += f" | {k.replace('Seconds','')} med {1000*pct(vals,50):6.2f} p95 {1000*pct(vals,95):6.2f}"
        print(line)
        lag = [f['scriptedInputDeliveryAgeSeconds'] for f in sel if f.get('scriptedInputDeliveryAgeSeconds') is not None]
        if lag: print(f"         input delivery lag med {1000*pct(lag,50):.1f} ms, p95 {1000*pct(lag,95):.1f} ms, max {1000*max(lag):.1f} ms")
