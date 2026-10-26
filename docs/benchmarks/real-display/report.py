#!/usr/bin/env python3
"""Summarizes run.sh results: for each phase of a session (its "<phase>-start" and "<phase>-end" checkpoints), the frames
drawn, their time (median, 95th percentile, worst), how many missed a 60 Hz frame, and the worst delay between input
and its delivery. Frame times are the app's own; opening phases also show the longest frame, which is usually the
one that shows the file.

Usage: report.py OUT_DIR [OUT_DIR...]"""
import json
import os
import sys

BUDGET = 1 / 60


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(p / 100 * len(ordered)))] if ordered else float("nan")


def phases(record):
    starts, result = {}, []
    for line in open(record):
        entry = json.loads(line)
        if entry.get("kind") != "checkpoint":
            continue
        label = entry["label"]
        if label.endswith("-start"):
            starts[label[:-6]] = entry["at"]
        elif label.endswith("-end") and label[:-4] in starts:
            result.append((label[:-4], starts.pop(label[:-4]), entry["at"]))
    return result


for run in sys.argv[1:]:
    frames = [json.loads(line) for line in open(os.path.join(run, "capture", "frame-timeline.jsonl")) if line.strip()]
    print(f"== {run}: {len(frames)} frames")
    print(f"  {'phase':24} {'frames':>6} {'p50 ms':>7} {'p95 ms':>7} {'worst':>7} {'missed 60 Hz':>13} {'input lag':>10}")
    for name, start, end in phases(os.path.join(run, "record.jsonl")):
        chosen = [f for f in frames if start <= f["startedAtSeconds"] < end]
        times = [f["frameSeconds"] * 1000 for f in chosen]
        missed = sum(1 for f in chosen if f["frameSeconds"] > BUDGET)
        lag = [(f.get("scriptedInputDeliveryAgeSeconds") or 0) * 1000 for f in chosen]
        share = f"{missed} ({100 * missed / max(1, len(chosen)):.0f}%)"
        print(f"  {name:24} {len(chosen):6} {percentile(times, 50):7.1f} {percentile(times, 95):7.1f} {max(times or [0]):7.1f}"
              f" {share:>13} {max(lag or [0]):8.1f}ms")
