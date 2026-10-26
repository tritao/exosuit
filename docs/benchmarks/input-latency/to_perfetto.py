"""to_perfetto.py HOOK APP GC OUT.json: one Chrome-JSON trace (opens in ui.perfetto.dev) of an input-latency session.

Tracks: "OS input" (each event as Windows received it), "UI thread" (waits, frames, GC pauses, input dequeues),
"Input lag" (one slice per input from OS arrival to the app dequeuing it; slices over 10 ms are named "SLOW ...")."""
import bisect, json, sys




def read(path):
    frequency, rows = None, []
    for line in open(path):
        if line.startswith("#"):
            for field in line.split():
                if field.startswith("frequency="):
                    frequency = int(field.split("=")[1])
            continue
        parts = line.split()
        rows.append((parts[0], int(parts[1]), *[int(p) for p in parts[2:]]))
    return frequency, rows


frequency, hook = read(sys.argv[1])
_, app = read(sys.argv[2])
gc = read(sys.argv[3])[1]
t0 = min(r[1] for r in app)
us = lambda t: (t - t0) * 1e6 / frequency
PID, OS, UI, LAG, LAG_SLOW = 1, 1, 2, 3, 4
events = [
    {"ph": "M", "pid": PID, "name": "process_name", "args": {"name": "exosuit input latency"}},
    {"ph": "M", "pid": PID, "tid": OS, "name": "thread_name", "args": {"name": "OS input (hook)"}},
    {"ph": "M", "pid": PID, "tid": UI, "name": "thread_name", "args": {"name": "UI thread"}},
    {"ph": "M", "pid": PID, "tid": LAG, "name": "thread_name", "args": {"name": "Input lag (<= 10 ms)"}},
    {"ph": "M", "pid": PID, "tid": LAG_SLOW, "name": "thread_name", "args": {"name": "Input lag (> 10 ms)"}},
]


def spans(rows, begin, end, name, tid, args=lambda r: {}):
    opened = None
    for row in rows:
        if row[0] == begin:
            opened = row
        elif row[0] == end and opened is not None:
            events.append({"ph": "X", "pid": PID, "tid": tid, "name": name, "ts": us(opened[1]),
                           "dur": max(us(row[1]) - us(opened[1]), 0.1), "args": args(opened)})
            opened = None


spans(app, "W", "w", "wait", UI, lambda r: {"timeout_ms": r[2]})
spans(app, "F", "f", "frame", UI)
spans(gc, "S", "s", "GC pause", UI)
names = {"M": "move dequeued", "B": "button dequeued", "K": "key dequeued", "H": "mouse move", "D": "mouse button"}
for row in app:
    if row[0] in "MBK":
        events.append({"ph": "i", "s": "t", "pid": PID, "tid": UI, "name": names[row[0]], "ts": us(row[1]),
                       "args": {"a": row[2], "b": row[3]}})
first, last = min(r[1] for r in app), max(r[1] for r in app)
for row in hook:
    if first <= row[1] <= last:
        name = names.get(row[0], "key") if row[0] != "K" else f"key vk={row[2]} {'down' if row[3] else 'up'}"
        events.append({"ph": "i", "s": "t", "pid": PID, "tid": OS, "name": name, "ts": us(row[1]),
                       "args": {"a": row[2], "b": row[3], "injected": row[4]}})

# Lag slices: each app dequeue delivers the OS events since the previous one; the slice runs from the oldest of them.
moves = [r for r in app if r[0] == "M"]
xs, ys = [m[2] for m in moves], [m[3] for m in moves]
inside = lambda h: xs and min(xs) <= h[2] <= max(xs) and min(ys) <= h[3] <= max(ys)
hook_moves = [h for h in hook if h[0] == "H" and inside(h)]
hi = 0
for m in moves:
    pending = []
    while hi < len(hook_moves) and hook_moves[hi][1] <= m[1]:
        pending.append(hook_moves[hi])
        hi += 1
    if pending and us(m[1]) - us(pending[0][1]) < 500000:
        lag = (m[1] - pending[0][1]) * 1000.0 / frequency
        events.append({"ph": "X", "pid": PID, "tid": LAG_SLOW if lag > 10 else LAG,
                       "name": f"{'SLOW ' if lag > 10 else ''}move lag {lag:.1f} ms", "ts": us(pending[0][1]),
                       "dur": us(m[1]) - us(pending[0][1]), "args": {"lag_ms": round(lag, 2), "os_moves": len(pending)}})
keys = [r for r in app if r[0] == "K"]
used = set()
for h in (r for r in hook if r[0] == "K"):
    for k, row in enumerate(keys):
        if k not in used and row[1] >= h[1] and row[2] == h[2] and row[3] == h[3]:
            lag = (row[1] - h[1]) * 1000.0 / frequency
            if lag < 500:
                used.add(k)
                events.append({"ph": "X", "pid": PID, "tid": LAG_SLOW if lag > 10 else LAG,
                               "name": f"{'SLOW ' if lag > 10 else ''}key lag {lag:.1f} ms", "ts": us(h[1]),
                               "dur": us(row[1]) - us(h[1]), "args": {"lag_ms": round(lag, 2), "vk": h[2]}})
            break
json.dump({"traceEvents": events, "displayTimeUnit": "ms"}, open(sys.argv[4], "w"))
print(f"{len(events)} events -> {sys.argv[4]}")
