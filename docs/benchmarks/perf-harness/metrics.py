"""Summarizes a profiler capture of a scenario.py run. Usage: metrics.py TRACE.pftrace [--scenario SCENARIO.json]
[--json OUT.json]

Prints, for the whole run and per scenario phase: frames (count, rate, duration percentiles), input latency (OS stamp
to the end of the first frame after the app polled the input) by kind, and NativeKit's input ages; then the time and
call counts of the functions behind known problems (call counts are exact only in instrumented captures).

Needs the `perfetto` Python package (trace processor); PERFETTO_PYLIB can point at a directory that holds it."""

import json
import os
import sys
import bisect

for extra in (os.environ.get("PERFETTO_PYLIB"),
              r"C:\Users\corbi\AppData\Local\Temp\claude\C--Users-corbi-projects-exosuit\7131dd1d-0006-4e04-bc61-bafabc552448\scratchpad\pylib"):
    if extra and os.path.isdir(extra):
        sys.path.insert(0, extra)
from perfetto.trace_processor import TraceProcessor  # noqa: E402

WATCH = [
    ("layout submit", "haxeon.ui.LayoutSession.submit"),
    ("ui submitInternal", "haxeon.ui.core.UiContext.submitInternal"),
    ("ui render", "haxeon.ui.core.UiContext.render"),
    ("glyph publish", "nkui::TextEngine::published_glyphs_for_line"),
    ("glyph append", "nkui::`anonymous namespace'::append_render_glyph"),
    ("render compile", "nkui::LayoutRenderCompiler::compile"),
    ("gpu timing readback", "nkui_renderer_get_gpu_frame_time"),
    ("scm markers", "ui.ExosuitApp.syncScmDocumentMarkers"),
    ("pollBackground", "ui.ExosuitApp.pollBackground"),
    ("pumpApplication", "ui.ExosuitApp.pumpApplication"),
    ("anim requestFrame", "haxeon.ui.animation.AnimationScheduler.requestFrame"),
    ("app requestFrame", "ui.ExosuitApp.requestFrame"),
    ("nk request frame", "nk_surface_request_frame"),
]


def pct(values, p):
    if not values:
        return None
    values = sorted(values)
    return round(values[min(len(values) - 1, int(p * len(values)))], 1)


def dist(values):
    return {"n": len(values), "p50": pct(values, .5), "p90": pct(values, .9), "p99": pct(values, .99),
            "max": round(max(values), 1) if values else None}


def main():
    trace = sys.argv[1]
    scenario = json.load(open(sys.argv[sys.argv.index("--scenario") + 1])) if "--scenario" in sys.argv else None
    out_json = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    tp = TraceProcessor(trace=trace)
    q = lambda s: list(tp.query(s))

    frames = [(r.ts, r.ts + r.dur) for r in q("select ts, dur from slice where name='nk.frame' order by ts")]
    frame_starts = [f[0] for f in frames]
    submit = {r.ts: r.dur for r in q("select ts, dur from slice where name='ui.submit'")}
    render = [r.dur / 1e6 for r in q("select dur from slice where name='ui.render'")]
    kinds = {r.ts: r.name.split()[-1] for r in q("select ts, name from slice where name like 'input polled %'")}
    polled = q("select c.ts, c.value v from counter c join counter_track t on c.track_id=t.id "
               "where t.name='Input polled age' order by c.ts")
    dequeued = q("select c.ts, c.value v from counter c join counter_track t on c.track_id=t.id "
                 "where t.name='Input age' order by c.ts")
    moves = {r.ts for r in q("select ts from slice where name='input move'")}

    # Every frame has a ui.submit span; one that reused the last submission takes almost no time.
    submit_starts = sorted(t for t, d in submit.items() if d > 500000)

    def has_submit(s, e):
        k = bisect.bisect_left(submit_starts, s)
        return k < len(submit_starts) and submit_starts[k] < e

    inputs = []  # (os_time, kind, polled_age_ms, latency_ms)
    for p in polled:
        os_time = p.ts - p.v
        k = bisect.bisect_right(frame_starts, p.ts)
        latency = (frames[k][1] - os_time) / 1e6 if k < len(frames) else None
        inputs.append((os_time, kinds.get(p.ts, "move"), p.v / 1e6, latency))

    offset = None
    if scenario and scenario.get("first_move_ns"):
        first = next((d.ts - d.v for d in dequeued if d.ts in moves), None)
        if first is not None:
            offset = first - scenario["first_move_ns"]

    def summarize(a, z):
        fr = [(s, e) for s, e in frames if a <= s < z]
        durs = [(e - s) / 1e6 for s, e in fr]
        ins = [i for i in inputs if a <= i[0] < z]
        result = {"seconds": round((z - a) / 1e9, 2), "frames": len(fr),
                  "frames_per_s": round(len(fr) / max((z - a) / 1e9, 1e-9), 1), "frame_ms": dist(durs),
                  "rebuild_frames": sum(1 for s, e in fr if has_submit(s, e))}
        for kind in ("move", "button", "key"):
            lat = [i[3] for i in ins if i[1] == kind and i[3] is not None]
            if lat:
                result[f"{kind}_input_to_frame_ms"] = dist(lat)
                result[f"{kind}_over_50ms_pct"] = round(100 * sum(1 for x in lat if x > 50) / len(lat))
        ages = [i[2] for i in ins]
        if ages:
            result["polled_age_ms"] = dist(ages)
        return result

    start = frames[0][0] if frames else 0
    end = frames[-1][1] if frames else 0
    report = {"trace": trace, "whole_run": summarize(start, end + 1),
              "input_age_ms": dist([d.v / 1e6 for d in dequeued]),
              "ui_submit_ms": dist([d / 1e6 for d in submit.values()]), "ui_render_ms": dist(render)}
    if offset is not None:
        report["phases"] = {ph["name"]: summarize(ph["start_ns"] + offset, ph["end_ns"] + offset)
                            for ph in scenario["phases"]}
    watch = {}
    for label, name in WATCH:
        r = q("select count(*) n, coalesce(sum(dur), 0) d from slice where name = '%s'" % name.replace("'", "''"))[0]
        watch[label] = {"calls": r.n, "ms": round(r.d / 1e6, 1),
                        "ms_per_frame": round(r.d / 1e6 / max(len(frames), 1), 2)}
    report["watch"] = watch
    dropped = q("select coalesce(sum(c.value), 0) s from counter c join counter_track t on c.track_id=t.id "
                "where t.name='Short calls dropped per frame'")[0].s
    report["short_calls_dropped"] = dropped
    # Render plan reuse: cumulative counters, so the run's total is the last value minus the first.
    plan = {}
    for row in q("select t.name n, max(c.value) hi, min(c.value) lo from counter c join counter_track t on c.track_id=t.id "
                 "where t.name like 'ui.plan.%' group by t.name"):
        plan[row.n[len("ui.plan."):]] = int(row.hi - row.lo)
    report["render_plan"] = plan

    if out_json:
        json.dump(report, open(out_json, "w"), indent=1)
    w = report["whole_run"]
    print(f"trace {trace}")
    print(f"frames {w['frames']} ({w['frames_per_s']}/s, {w['rebuild_frames']} rebuilt) frame_ms {w['frame_ms']}")
    print(f"ui.submit {report['ui_submit_ms']}  ui.render {report['ui_render_ms']}")
    print(f"input age (OS->NativeKit) {report['input_age_ms']}")
    for kind in ("move", "button", "key"):
        if f"{kind}_input_to_frame_ms" in w:
            print(f"{kind:6s} input->frame {w[f'{kind}_input_to_frame_ms']} >50ms {w[f'{kind}_over_50ms_pct']}%")
    for name, ph in report.get("phases", {}).items():
        line = f"  phase {name:12s} {ph['seconds']:5.1f}s frames {ph['frames']:4d} ({ph['frames_per_s']:5.1f}/s, {ph['rebuild_frames']} rebuilt) frame p50 {ph['frame_ms']['p50']} max {ph['frame_ms']['max']}"
        for kind in ("move", "button", "key"):
            if f"{kind}_input_to_frame_ms" in ph:
                d = ph[f"{kind}_input_to_frame_ms"]
                line += f" | {kind} p50 {d['p50']} p90 {d['p90']} max {d['max']}"
        print(line)
    if "phases" not in report:
        print("  (no phase breakdown: no scenario file or no injected move found in the trace)")
    for label, v in watch.items():
        print(f"  watch {label:20s} {v['ms']:9.1f} ms  {v['ms_per_frame']:7.2f} ms/frame  calls {v['calls']}")
    print(f"short calls dropped {dropped:.3g}")
    if plan:
        print("  render plan " + ", ".join(f"{k} {v}" for k, v in sorted(plan.items())))


if __name__ == "__main__":
    main()
