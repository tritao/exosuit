"""Converts a run's scripted checkpoints (Unix seconds) into capture milliseconds for hlprof-live --start-ms/--end-ms.
Usage: windows.py RUN_DIR CAPTURE.hlpc   -> prints 'phase start_ms end_ms' lines"""
import json, struct, sys, os

run, capture = sys.argv[1], sys.argv[2]
pairs = []  # (unix_ns, elapsed_ns)
with open(capture, 'rb') as f:
    f.read(24)
    while True:
        h = f.read(16)
        if len(h) < 16: break
        kind, size, elapsed = struct.unpack('<IIQ', h)
        if kind == 18:
            payload = f.read(size)
            ticks, mono, unix = struct.unpack('<QQQ', payload[:24])
            pairs.append((unix, elapsed))
        else:
            f.seek(size, 1)
if not pairs: sys.exit('no clock frames')
pairs.sort()

def to_ms(unix_s):
    t = int(unix_s * 1e9)
    best = min(pairs, key=lambda p: abs(p[0] - t))
    return (best[1] + (t - best[0])) / 1e6

marks = {}
for line in open(os.path.join(run, 'record.jsonl')):
    r = json.loads(line)
    if r.get('kind') == 'checkpoint': marks[r['label']] = r['at']
for phase, a, b in (('hover', 'hover-start', 'hover-end'), ('scroll', 'scroll-start', 'scroll-end')):
    print(phase, int(to_ms(marks[a])), int(to_ms(marks[b])))
