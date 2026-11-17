"""port_frames.py RESULT_DIR [OTHER_RESULT_DIR] [--json OUT]: frames, input -> frame and allocations per stage of a GUI
scenario run, and the two runs side by side (the port first, the baseline second).

Reads, from a measure.ps1 -Drive result folder (runs/<Name>/result):
- switch.txt: the app's `R <ticks> <context>` line per rendered frame (EXOSUIT_SWITCH_TRACE, src/devtools/SwitchTrace.hx);
- marks.txt: the port scenarios' `stage`, `input` and `end` marks (gui_scenarios/port_common.py), or else sent.txt of a
  real-input scenario (its `tag` lines start stages, its key and button downs are the inputs); a run with neither is one
  stage, `all`. Both are on the QueryPerformanceCounter clock; the frequency comes from their header;
- census.txt when present (a PORT_MEASURE=alloc run): hashlink's allocation census, counted from the app's 20th frame to
  its exit.

Per stage: frames rendered, frames per second, the interval between frames (p50/p90/max ms), and input -> first frame
(p50/p90/max ms over the inputs followed by a frame before the next input; `none` counts the others). With two runs,
each number of the first is compared with the second: WORSE when it exceeds it by more than 10 % or 2 ms (whichever is
larger) for times, or renders more frames per second in an idle stage (one whose name starts with "idle"). The census
prints objects and bytes in total and per rendered frame, and the 15 types with the most bytes; with two runs, WORSE when
the first allocates more per frame. Exit status 1 when anything is WORSE, else 0."""
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def read_marks(path):
    frequency, rows = None, []
    for line in open(path, encoding="utf-8"):
        if line.startswith("#"):
            for field in line.split():
                if field.startswith("frequency="):
                    frequency = int(field.split("=")[1])
            continue
        parts = line.rstrip("\n").split(" ", 2)
        if len(parts) >= 2 and parts[1].lstrip("-").isdigit():
            rows.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))
    return frequency, rows


def stages_of(directory):
    """[(name, start, end, [input ticks])], frequency."""
    marks, sent = os.path.join(directory, "marks.txt"), os.path.join(directory, "sent.txt")
    frames = frame_ticks(directory)
    if os.path.isfile(marks):
        frequency, rows = read_marks(marks)
        stages, current = [], None
        for kind, ticks, text in rows:
            if kind in ("stage", "end"):
                if current:
                    stages.append((current[0], current[1], ticks, current[2]))
                current = (text, ticks, []) if kind == "stage" else None
            elif kind == "input" and current:
                current[2].append(ticks)
        if current:
            stages.append((current[0], current[1], frames[-1] + 1 if frames else current[1], current[2]))
        return stages, frequency
    if os.path.isfile(sent):
        frequency, rows = read_marks(sent)
        inputs = [t for kind, t, _ in rows if kind in ("down", "keydown")]
        tags = [(t, text) for kind, t, text in rows if kind == "tag"]
        stop = max([frames[-1] + 1 if frames else 0] + [t + 1 for _, t, _ in rows])
        if not tags:
            return [("all", rows[0][1] if rows else 0, stop, inputs)], frequency
        stages = []
        for index, (start, text) in enumerate(tags):
            finish = tags[index + 1][0] if index + 1 < len(tags) else stop
            stages.append((text, start, finish, [t for t in inputs if start <= t < finish]))
        return stages, frequency
    return [("all", frames[0] if frames else 0, frames[-1] + 1 if frames else 0, [])], None


def frame_ticks(directory):
    path = os.path.join(directory, "switch.txt")
    if not os.path.isfile(path):
        return []
    ticks = []
    for line in open(path, encoding="utf-8"):
        parts = line.split(" ", 2)
        if len(parts) >= 2 and parts[0] == "R" and parts[1].isdigit():
            ticks.append(int(parts[1]))
    return ticks


def pick(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))]


def spread(values):
    if not values:
        return None
    return {"n": len(values), "p50": round(statistics.median(values), 2), "p90": round(pick(values, 0.9), 2), "max": round(max(values), 2)}


def analyze(directory):
    frames = frame_ticks(directory)
    stages, frequency = stages_of(directory)
    if frequency is None:
        frequency = qpc_frequency()
    ms = 1000.0 / frequency
    result = {"directory": directory, "frames": len(frames), "stages": []}
    for name, start, stop, inputs in stages:
        inside = [t for t in frames if start <= t < stop]
        seconds = max(1e-9, (stop - start) / frequency)
        intervals = [(b - a) * ms for a, b in zip(inside, inside[1:])]
        latencies, missed = [], 0
        for index, sent in enumerate(inputs):
            following = inputs[index + 1] if index + 1 < len(inputs) else stop
            first = next((t for t in frames if sent <= t < following), None)
            if first is None:
                missed += 1
            else:
                latencies.append((first - sent) * ms)
        result["stages"].append({"stage": name, "seconds": round(seconds, 2), "frames": len(inside), "fps": round(len(inside) / seconds, 2),
                                 "interval_ms": spread(intervals), "input_ms": spread(latencies), "inputs": len(inputs),
                                 "inputs_without_frame": missed})
    census = os.path.join(directory, "census.txt")
    if os.path.isfile(census):
        try:
            with open(census, encoding="utf-8") as f:
                data = json.load(f)
            types = data.get("types", [])
            objects = int(data.get("allocations", sum(t.get("count", 0) for t in types)))
            total_bytes = sum(int(t.get("bytes", 0)) for t in types)
            counted = max(1, len(frames) - 20)
            top = sorted(types, key=lambda t: -int(t.get("bytes", 0)))[:15]
            result["census"] = {"objects": objects, "bytes": total_bytes, "frames": counted,
                                "objects_per_frame": round(objects / counted, 1), "bytes_per_frame": round(total_bytes / counted, 1),
                                "top": [{"type": str(t.get("type")), "count": int(t.get("count", 0)), "bytes": int(t.get("bytes", 0))} for t in top]}
        except (OSError, ValueError) as error:
            result["census"] = {"error": str(error)}
    return result


def qpc_frequency():
    if os.name != "nt":
        return 1_000_000_000
    import ctypes
    frequency = ctypes.c_int64()
    ctypes.windll.kernel32.QueryPerformanceFrequency(ctypes.byref(frequency))
    return frequency.value


def worse_time(mine, theirs):
    return mine is not None and theirs is not None and mine - theirs > max(0.1 * theirs, 2.0)


def fmt(spread_value):
    return "-" if not spread_value else "%.1f/%.1f/%.1f (n=%d)" % (spread_value["p50"], spread_value["p90"], spread_value["max"], spread_value["n"])


def report(first, second=None):
    verdicts = []
    print("%s: %d frames" % (first["directory"], first["frames"]) + ("" if not second else "   vs   %s: %d frames" % (second["directory"], second["frames"])))
    others = {s["stage"]: s for s in second["stages"]} if second else {}
    for stage in first["stages"]:
        other = others.get(stage["stage"])
        print("\n[%s] %.1f s" % (stage["stage"], stage["seconds"]))
        print("  frames %d  fps %.2f   interval ms p50/p90/max %s   input->frame ms %s   inputs %d, %d without a frame"
              % (stage["frames"], stage["fps"], fmt(stage["interval_ms"]), fmt(stage["input_ms"]), stage["inputs"], stage["inputs_without_frame"]))
        if not second:
            continue
        if other is None:
            print("  (no stage %r in the second run)" % stage["stage"])
            continue
        print("  frames %d  fps %.2f   interval ms p50/p90/max %s   input->frame ms %s   inputs %d, %d without a frame   <- second"
              % (other["frames"], other["fps"], fmt(other["interval_ms"]), fmt(other["input_ms"]), other["inputs"], other["inputs_without_frame"]))
        found = []
        for key in ("input_ms", "interval_ms"):
            for p in ("p50", "p90"):
                mine, theirs = (stage[key] or {}).get(p), (other[key] or {}).get(p)
                if worse_time(mine, theirs):
                    found.append("%s %s %.1f > %.1f ms" % (key, p, mine, theirs))
        if stage["stage"].startswith("idle") and stage["fps"] > other["fps"] * 1.1 + 0.2:
            found.append("idle fps %.2f > %.2f" % (stage["fps"], other["fps"]))
        if stage["inputs_without_frame"] > other["inputs_without_frame"]:
            found.append("%d inputs drew no frame (second: %d)" % (stage["inputs_without_frame"], other["inputs_without_frame"]))
        print("  " + ("WORSE: " + "; ".join(found) if found else "ok"))
        verdicts += [stage["stage"] + ": " + f for f in found]
    for run in [first] + ([second] if second else []):
        census = run.get("census")
        if not census:
            continue
        print("\ncensus %s" % run["directory"])
        if "error" in census:
            print("  unreadable: " + census["error"])
            continue
        print("  objects %d, bytes %d over %d frames: %.1f objects and %.0f bytes per rendered frame"
              % (census["objects"], census["bytes"], census["frames"], census["objects_per_frame"], census["bytes_per_frame"]))
        for item in census["top"]:
            print("  %12d B %10d  %s" % (item["bytes"], item["count"], item["type"]))
    if second and first.get("census") and second.get("census") and "error" not in first["census"] and "error" not in second["census"]:
        if first["census"]["objects_per_frame"] > second["census"]["objects_per_frame"]:
            verdicts.append("census: %.1f objects per frame > %.1f" % (first["census"]["objects_per_frame"], second["census"]["objects_per_frame"]))
            print("\nWORSE: more objects per rendered frame than the second run")
    if second:
        print("\n%s" % ("WORSE in %d place(s)" % len(verdicts) if verdicts else "not worse than the second run anywhere"))
    return verdicts


def main():
    args = sys.argv[1:]
    out = None
    if "--json" in args:
        index = args.index("--json")
        out = args[index + 1]
        del args[index:index + 2]
    if not args or len(args) > 2:
        print(__doc__)
        return 2
    runs = [analyze(path) for path in args]
    verdicts = report(*runs)
    if out:
        with open(out, "w") as f:
            json.dump({"runs": runs, "worse": verdicts}, f, indent=1)
    return 1 if verdicts else 0


if __name__ == "__main__":
    sys.exit(main())
