"""analyze.py HOOK APP [GC]: input latency from the moment Windows received each input to the app taking it off its
queue, with what the UI thread was doing meanwhile. HOOK is hook.py's file, APP NativeKit's NK_LATENCY_TRACE file,
GC HashLink's HL_GC_TIMELINE file. All share the QueryPerformanceCounter clock."""
import bisect, sys


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
gc = read(sys.argv[3])[1] if len(sys.argv) > 3 else []
ms = 1000.0 / frequency


def intervals(rows, begin, end):
    spans, opened = [], None
    for row in rows:
        if row[0] == begin:
            opened = row[1]
        elif row[0] == end and opened is not None:
            spans.append((opened, row[1]))
            opened = None
    return spans


waits, frames, pauses = intervals(app, "W", "w"), intervals(app, "F", "f"), intervals(gc, "S", "s")


def overlap(spans, start, end):
    """Milliseconds of [start, end] covered by spans."""
    total = 0
    i = bisect.bisect_left(spans, (start,)) - 1
    for a, b in spans[max(i, 0):]:
        if a > end:
            break
        total += max(0, min(b, end) - max(a, start))
    return total * ms


moves = [r for r in app if r[0] == "M"]
keys = [r for r in app if r[0] == "K"]
if not moves:
    sys.exit(f"no app mouse moves ({len(app)} app lines); was the pointer over the window?")
xs, ys = [m[2] for m in moves], [m[3] for m in moves]
inside = lambda h: min(xs) <= h[2] <= max(xs) and min(ys) <= h[3] <= max(ys)
move_times = [m[1] for m in moves]
hook_moves = [h for h in hook if h[0] == "H"]
injected = sum(1 for h in hook if h[-1] == 1)
print(f"{len(hook)} OS input events ({injected} injected), {len(moves)} app moves, {len(keys)} app keys, "
      f"{len(frames)} frames, {len(waits)} waits, {len(pauses)} GC pauses")


def summary(name, values):
    values = sorted(values)
    if not values:
        print(f"{name}: no samples")
        return
    pick = lambda p: values[min(len(values) - 1, int(p * len(values)))]
    print(f"{name}: n={len(values)} median={pick(0.5):.1f} p90={pick(0.9):.1f} p95={pick(0.95):.1f} max={values[-1]:.1f} ms")


def attribute(label, samples):
    """samples: (os_time, app_time). Splits each delay into time the UI thread spent waiting, in frames, in GC, other."""
    delays = [(b - a) * ms for a, b in samples]
    summary(label, delays)
    if not samples:
        return
    slow = [(a, b) for a, b in samples if (b - a) * ms > 10]
    if slow:
        parts = {"waiting": 0.0, "frame": 0.0, "gc": 0.0}
        for a, b in slow:
            parts["waiting"] += overlap(waits, a, b)
            parts["frame"] += overlap(frames, a, b)
            parts["gc"] += overlap(pauses, a, b)
        total = sum((b - a) * ms for a, b in slow)
        other = total - parts["waiting"] - parts["frame"] - parts["gc"]
        print(f"  {len(slow)} over 10 ms; where their {total:.0f} ms went: " +
              ", ".join(f"{k} {100 * v / total:.0f}%" for k, v in parts.items()) + f", other UI-thread work {100 * other / total:.0f}%")
    buckets = [0] * 6
    for d in delays:
        buckets[min(5, int(d // 2))] += 1
    print("  histogram (2 ms buckets, last >= 10 ms):", buckets)


# Onsets: the first move inside the window after >= 100 ms of stillness, when the app has nothing to draw.
onsets = []
for i in range(1, len(hook_moves)):
    h = hook_moves[i]
    if inside(h) and (h[1] - hook_moves[i - 1][1]) * ms >= 100:
        j = bisect.bisect_left(move_times, h[1])
        if j < len(move_times) and (move_times[j] - h[1]) * ms < 500:
            onsets.append((h[1], move_times[j]))
attribute("ONSET  mouse starts moving -> app dequeues it", onsets)

# Continuous movement: the oldest OS move each dequeue delivered.
continuous, hi, previous = [], 0, None
inside_moves = [h for h in hook_moves if inside(h)]
for _, t, *_ in moves:
    pending = []
    while hi < len(inside_moves) and inside_moves[hi][1] <= t:
        pending.append(inside_moves[hi])
        hi += 1
    if previous is not None and pending and (t - pending[0][1]) * ms < 500:
        continuous.append((pending[0][1], t))
    previous = t
attribute("MOVING oldest pending move -> app dequeues it", continuous)

# Keys: each OS key transition to the app's matching K line.
key_samples, used = [], set()
for h in (r for r in hook if r[0] == "K"):
    for k, row in enumerate(keys):
        if k not in used and row[1] >= h[1] and row[2] == h[2] and row[3] == h[3]:
            if (row[1] - h[1]) * ms < 500:
                key_samples.append((h[1], row[1]))
                used.add(k)
            break
attribute("KEYS   key event -> app dequeues it", key_samples)
