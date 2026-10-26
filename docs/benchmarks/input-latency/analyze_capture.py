"""Input latency from a profiler capture's Perfetto JSON (`hlprof-live export --format perfetto`), for an app that starts
NativeKitRuntime. Usage: analyze_capture.py TRACE.json [--slow-ms 10]

Each input appears twice on the UI thread: `input move|button|key` when NativeKit's handler had it (its "Input age" counter
is the time since the OS stamped it) and `input polled move|button|key` when the application took it off NativeKit's queue
(the "Input polled age" counter). Merged moves report the oldest input they stand for, so the polled age of a move is the
age of the oldest input not yet delivered.

Prints three distributions, as the Windows analyzer does, from the polled ages (the delay a person feels, up to the point
the app reacts):
  ONSET   the first move after at least 100 ms without one
  MOVING  every other polled move
  KEYS    polled key transitions
then SCREEN, the time from the OS stamp to the end of the first frame that starts after the application polled the input,
which is the frame that can show its effect (the end of nk.frame is when the frame was submitted: what the display does
with it is not measured), and, for polled inputs slower than --slow-ms, where their time went on the UI thread: inside nk.frame zones, waiting for
events (nk.wait), or other work.

Resizes the application polled (`resize polled window` and `resize polled surface`) are grouped into drags: resizes less
than 300 ms apart. For each drag it reports how many resizes the application saw, and the frames drawn while it lasted: their
cost, the gaps between them (a frame budget is 16.7 ms) and the time from a polled resize to the end of the next frame. A drag's
resizes are merged in NativeKit's queue, so the application sees fewer than were sent."""
import argparse, collections, json, statistics, sys


def load(path):
    data = json.load(open(path, encoding="utf-8"))
    return data["traceEvents"] if isinstance(data, dict) else data


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def summary(label, ages_ms):
    if not ages_ms:
        print("%-7s none" % label)
        return
    print("%-7s n=%-5d median %.1f  p90 %.1f  p95 %.1f  p99 %.1f  max %.1f ms" % (
        label, len(ages_ms), statistics.median(ages_ms), percentile(ages_ms, 0.90), percentile(ages_ms, 0.95),
        percentile(ages_ms, 0.99), max(ages_ms)))


def histogram(label, ages_ms, width=2.0, limit=20):
    if not ages_ms:
        return
    buckets = collections.Counter(min(int(age // width), limit) for age in ages_ms)
    parts = []
    for bucket in range(limit + 1):
        if buckets[bucket]:
            name = "%g+" % (limit * width) if bucket == limit else "%g-%g" % (bucket * width, (bucket + 1) * width)
            parts.append("%s:%d" % (name, buckets[bucket]))
    print("        %s histogram (ms): %s" % (label, "  ".join(parts)))


def intervals(events, thread, names):
    """The slices on one thread whose name is in names, as (start, end, name) in microseconds."""
    stack, found = [], []
    for e in events:
        if e.get("tid") != thread:
            continue
        if e.get("ph") == "B":
            stack.append((e["ts"], e["name"]))
        elif e.get("ph") == "E" and stack:
            start, name = stack.pop()
            if name in names:
                found.append((start, e["ts"], name))
    return sorted(found)


def overlap(spans, start, end):
    return sum(max(0.0, min(end, b) - max(start, a)) for a, b, _ in spans)


def report_resizes(events, resize_events):
    if not resize_events:
        return
    import bisect
    thread = resize_events[0]["tid"]
    frames = intervals(events, thread, {"nk.frame"})
    starts = [a for a, _, _ in frames]
    windows = [e for e in resize_events if e["name"] == "resize polled window"] or resize_events
    drags, current = [], [windows[0]]
    for e in windows[1:]:
        if e["ts"] - current[-1]["ts"] > 300_000:
            drags.append(current)
            current = []
        current.append(e)
    drags.append(current)
    print("\nRESIZE  %d drags, %d resizes polled by the application" % (len(drags), len(windows)))
    all_after, all_cost, all_gaps = [], [], []
    for n, drag in enumerate(drags, 1):
        first, last = drag[0]["ts"], drag[-1]["ts"]
        lo, hi = bisect.bisect_left(starts, first), bisect.bisect_right(starts, last + 100_000)
        inside = frames[lo:hi]
        cost = [(b - a) / 1000 for a, b, _ in inside]
        gaps = [(inside[i + 1][0] - inside[i][0]) / 1000 for i in range(len(inside) - 1)]
        after = []
        for e in drag:
            i = bisect.bisect_left(starts, e["ts"])
            if i < len(frames):
                after.append((frames[i][1] - e["ts"]) / 1000)
        all_after += after
        all_cost += cost
        all_gaps += gaps
        seconds = max((last - first) / 1e6, 1e-3)
        a, b = drag[0]["args"], drag[-1]["args"]
        print("  drag %-2d %3d resizes in %.2f s (%dx%d -> %dx%d): %3d frames (%.0f/s), cost median %.1f max %.1f ms, "
              "gap p90 %.1f max %.1f ms" % (
                  n, len(drag), seconds, a["a"], a["b"], b["a"], b["b"], len(inside), len(inside) / seconds,
                  statistics.median(cost) if cost else 0, max(cost) if cost else 0,
                  percentile(gaps, 0.90) if gaps else 0, max(gaps) if gaps else 0))
    if all_cost:
        print("  frames during drags: n=%d, cost median %.1f  p90 %.1f  p99 %.1f  max %.1f ms; %d over 16.7 ms, %d over 50 ms" % (
            len(all_cost), statistics.median(all_cost), percentile(all_cost, 0.90), percentile(all_cost, 0.99), max(all_cost),
            sum(c > 16.7 for c in all_cost), sum(c > 50 for c in all_cost)))
    if all_gaps:
        print("  time between frame starts: median %.1f  p90 %.1f  p99 %.1f  max %.1f ms" % (
            statistics.median(all_gaps), percentile(all_gaps, 0.90), percentile(all_gaps, 0.99), max(all_gaps)))
    summary("  RESIZE→FRAME", all_after)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace")
    parser.add_argument("--slow-ms", type=float, default=10.0)
    args = parser.parse_args()
    events = load(args.trace)

    resize_events = sorted((e for e in events if e.get("cat") == "hl.input" and e.get("ph") == "i"
                            and e.get("name") in ("resize polled window", "resize polled surface")), key=lambda e: e["ts"])
    inputs = sorted((e for e in events if e.get("cat") == "hl.input" and e.get("ph") == "i"
                     and not e["name"].startswith("resize")), key=lambda e: e["ts"])
    ages = sorted((e for e in events if e.get("cat") == "hl.input" and e.get("ph") == "C"), key=lambda e: e["ts"])
    if not inputs and not resize_events:
        print("no input or resize events: was the run recorded with NativeKit's trace sink?", file=sys.stderr)
        return 1
    if not inputs:
        report_resizes(events, resize_events)
        return 0
    # An age counter is written right after its instant, with the same timestamp.
    age_at = {}
    for e in ages:
        age_at.setdefault((e["name"], e["ts"]), e["args"]["ns"])
    handled, polled = [], []
    for e in inputs:
        name = e["name"]
        counter = "Input polled age" if "polled" in name else "Input age"
        age = age_at.get((counter, e["ts"]))
        if age is None:
            continue
        (polled if "polled" in name else handled).append((e["ts"], name, age / 1e6, e["tid"]))

    print("%d inputs reached NativeKit's handler, %d were polled by the application" % (len(handled), len(polled)))
    handler_moves = [age for _, name, age, _ in handled if name == "input move"]
    summary("HANDLER", handler_moves)

    onset, moving, keys = [], [], []
    last_move = None
    onset_records = []
    for ts, name, age, thread in polled:
        if name == "input polled move":
            # A move's stamp is when the OS got it; a still period is measured between the stamps of successive polled moves.
            stamp = ts - age * 1000
            first = last_move is None or stamp - last_move >= 100_000
            (onset if first else moving).append(age)
            if first:
                onset_records.append((ts, age, thread))
            last_move = ts
        elif name == "input polled key":
            keys.append(age)
    print()
    summary("ONSET", onset)
    histogram("ONSET", onset)
    summary("MOVING", moving)
    histogram("MOVING", moving)
    summary("KEYS", keys)
    histogram("KEYS", keys)

    thread = polled[0][3]
    frame_spans = intervals(events, thread, {"nk.frame"})
    if frame_spans:
        durations = [(b - a) / 1000 for a, b, _ in frame_spans]
        busy = sum(b - a for a, b, _ in frame_spans)
        window = max(e["ts"] for e in events if "ts" in e) - min(e["ts"] for e in events if "ts" in e)
        print("\nFRAMES  n=%d  median %.1f  p90 %.1f  p99 %.1f  max %.1f ms; the UI thread spent %.0f%% of the capture in them" % (
            len(durations), statistics.median(durations), percentile(durations, 0.90), percentile(durations, 0.99), max(durations),
            100 * busy / window))

    # The first frame that starts after each poll. An input that no frame follows within 50 ms did not change the screen.
    import bisect
    starts = [a for a, _, _ in frame_spans]
    screen = {"input polled move": [], "input polled key": []}
    for ts, name, age, _ in polled:
        if name not in screen:
            continue
        i = bisect.bisect_left(starts, ts)
        if i < len(frame_spans) and frame_spans[i][0] - ts < 50_000:
            screen[name].append((frame_spans[i][1] - (ts - age * 1000)) / 1000)
    print()
    summary("SCREEN", screen["input polled move"] + screen["input polled key"])
    summary(" moves", screen["input polled move"])
    summary(" keys", screen["input polled key"])

    report_resizes(events, resize_events)

    slow = [r for r in polled if r[2] >= args.slow_ms]
    print("\n%d of %d polled inputs took %.0f ms or more" % (len(slow), len(polled), args.slow_ms))
    if not slow:
        return 0
    thread = polled[0][3]
    spans = intervals(events, thread, {"nk.frame", "nk.wait", "ui.frame", "ui.frame.gc", "ui.events"})
    frame = [s for s in spans if s[2] == "nk.frame"]
    wait = [s for s in spans if s[2] == "nk.wait"]
    gc = [s for s in spans if s[2] == "ui.frame.gc"]
    totals = collections.Counter()
    for ts, name, age, tid in slow:
        start, end = ts - age * 1000, ts
        total = end - start
        in_frames = overlap(frame, start, end)
        in_wait = overlap(wait, start, end)
        in_gc = overlap(gc, start, end)
        totals["total"] += total
        totals["frames"] += in_frames
        totals["waiting"] += in_wait
        totals["gc"] += in_gc
    other = totals["total"] - totals["frames"] - totals["waiting"]
    print("their time, summed: %.0f ms in nk.frame (%.0f%%, of which %.0f ms in GC), %.0f ms waiting for events (%.0f%%), "
          "%.0f ms other UI-thread work (%.0f%%)" % (
              totals["frames"] / 1000, 100 * totals["frames"] / totals["total"], totals["gc"] / 1000,
              totals["waiting"] / 1000, 100 * totals["waiting"] / totals["total"], other / 1000, 100 * other / totals["total"]))
    print("worst polled inputs:")
    for ts, name, age, _ in sorted(slow, key=lambda r: -r[2])[:8]:
        start = ts - age * 1000
        print("  %-20s %7.1f ms  (frame %.1f, wait %.1f)" % (name, age, overlap(frame, start, ts) / 1000, overlap(wait, start, ts) / 1000))
    return 0


if __name__ == "__main__":
    sys.exit(main())
