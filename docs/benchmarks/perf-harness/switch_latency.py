"""switch_latency.py RESULT_DIR: input to first frame of the new group, from a m19_switch_latency.py run.

Reads sent.txt (the driver's inputs and its tags, one per switch, on the QueryPerformanceCounter clock) and switch.txt
(the app's S/E/R marks, see src/devtools/SwitchTrace.hx). For each tag it takes the first S mark for the target context
after the tag, the input that triggered it (the last one sent before S), the E mark after S (whether the target was
rebuilt from its snapshot) and the first rendered frame (R) that shows the target. Prints, per kind (warm/cold) and
input (click, previous, quick), median / p90 / max of input -> first frame, with the split into input -> S (OS delivery,
the app taking the input, the handler up to the context change), S -> E (the switch itself), E -> first frame, and the
number of frames rendered from the input to that frame, counting it."""
import statistics
import sys
from collections import defaultdict


def read(path):
    frequency, rows = None, []
    for line in open(path, encoding="utf-8"):
        if line.startswith("#"):
            for field in line.split():
                if field.startswith("frequency="):
                    frequency = int(field.split("=")[1])
            continue
        parts = line.rstrip("\n").split(" ", 2)
        if len(parts) >= 2 and parts[1].isdigit():
            rows.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))
    return frequency, rows


def pick(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))]


def stats(values):
    return "n=%d median %.1f p90 %.1f max %.1f" % (len(values), statistics.median(values), pick(values, 0.9), max(values)) if values else "n=0"


def matches(directory):
    frequency, sent = read(directory + "/sent.txt")
    _, app = read(directory + "/switch.txt")
    ms = 1000.0 / frequency
    inputs = [row for row in sent if row[0] != "tag"]
    tags = [row for row in sent if row[0] == "tag"]
    result = []
    for tag in tags:
        warm_cold, how, expect = tag[2].split(" ", 2)
        s = next((r for r in app if r[0] == "S" and r[1] >= tag[1] and r[2] == expect), None)
        if s is None:
            continue
        trigger = max((i for i in inputs if tag[1] <= i[1] <= s[1]), key=lambda i: i[1], default=None)
        e = next((r for r in app if r[0] == "E" and r[1] >= s[1]), None)
        frame = next((r for r in app if r[0] == "R" and r[1] >= s[1] and r[2] == expect), None)
        if trigger is None or e is None or frame is None:
            continue
        cold = e[2].endswith(" 1")
        frames = sum(1 for r in app if r[0] == "R" and trigger[1] <= r[1] <= frame[1])
        result.append({"input": how, "cold": cold, "total": (frame[1] - trigger[1]) * ms, "to_switch": (s[1] - trigger[1]) * ms,
                       "switch": (e[1] - s[1]) * ms, "to_frame": (frame[1] - e[1]) * ms, "frames": frames, "target": expect})
    return result


def main():
    rows = matches(sys.argv[1])
    groups = defaultdict(list)
    for row in rows:
        groups[("cold" if row["cold"] else "warm", row["input"])].append(row)
        groups[("cold" if row["cold"] else "warm", "all")].append(row)
    print("%d switches matched" % len(rows))
    for key in sorted(groups):
        items = groups[key]
        print("%s %s: input->frame ms: %s" % (key[0], key[1], stats([r["total"] for r in items])))
        print("      frames: %s   input->S: %s   S->E: %s   E->frame: %s" % (
            stats([float(r["frames"]) for r in items]), stats([r["to_switch"] for r in items]),
            stats([r["switch"] for r in items]), stats([r["to_frame"] for r in items])))


if __name__ == "__main__":
    main()
