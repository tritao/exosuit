"""Turns one measured build (stamped log + sampler JSONL + typeperf CSV) into a JSON summary.

Usage: python -I analyze.py <run dir> <run name>
Reads <run>.log, <run>.jsonl, <run>.cpu.csv, <run>.meta.json and the ccache counters; writes <run>.analysis.json.

A process belongs to the build when its parent chain reaches stamped-build.ps1, when its command line names the
checkout (or the haxeon folder its junction points at), or, for a short-lived compiler or linker whose parent was
never sampled, when it started during the build and names no sibling checkout.
"""

import csv
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

HERE = Path(".")
OWN = []          # path fragments that name this build's checkout, set in main()
OTHER = None      # regex for paths of sibling checkouts, set in main()
TOOLS = ["cl.exe", "link.exe", "lib.exe", "MSBuild.exe", "cmake.exe", "ninja.exe", "hl.exe", "python.exe", "node.exe",
         "git.exe", "mt.exe", "rc.exe", "cvtres.exe", "Tracker.exe", "clang-cl.exe", "pwsh.exe", "cmd.exe", "vctip.exe",
         "mspdbsrv.exe", "VBCSCompiler.exe", "ctest.exe", "npm.exe", "haxe.exe", "ccache.exe"]
SHORT_TOOLS = ("cl.exe", "link.exe", "lib.exe", "MSBuild.exe", "mt.exe", "rc.exe", "cvtres.exe", "vctip.exe", "Tracker.exe",
               "mspdbsrv.exe", "ccache.exe")


def names_own(cmd: str) -> bool:
    low = cmd.lower().replace("/", "\\")
    return any(o in low for o in OWN)


def names_other(cmd: str) -> bool:
    return OTHER is not None and OTHER.search(cmd.replace("/", "\\")) is not None


def ccache_counters(path: Path) -> dict:
    """The tab-separated counters of `ccache --print-stats` in a measure.ps1 ccache file."""
    counters = {}
    if not path.exists():
        return counters
    for line in path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        if line.startswith("# ccache --show-stats"):
            break
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].strip().lstrip("-").isdigit():
            counters[parts[0].strip()] = int(parts[1])
    return counters


def ccache_delta(run_dir: Path, run: str):
    before = ccache_counters(run_dir / f"{run}.ccache-before.txt")
    after = ccache_counters(run_dir / f"{run}.ccache-after.txt")
    if not after:
        return None
    delta = {k: after[k] - before.get(k, 0) for k in after if not k.endswith("_timestamp") and k not in ("stats_updated_timestamp", "stats_zeroed_timestamp")}
    hits = delta.get("direct_cache_hit", 0) + delta.get("preprocessed_cache_hit", 0)
    misses = delta.get("cache_miss", 0)
    return {"counters": delta, "hits": hits, "directHits": delta.get("direct_cache_hit", 0),
            "preprocessedHits": delta.get("preprocessed_cache_hit", 0), "misses": misses,
            "uncacheable": sum(v for k, v in delta.items() if k not in ("direct_cache_hit", "preprocessed_cache_hit", "cache_miss", "direct_cache_miss", "preprocessed_cache_miss", "cache_size_kibibyte", "files_in_cache", "local_storage_hit", "local_storage_miss", "local_storage_read_hit", "local_storage_read_miss", "local_storage_write", "recache", "cleanups_performed", "remote_storage_hit", "remote_storage_miss", "remote_storage_read_hit", "remote_storage_read_miss", "remote_storage_write", "remote_storage_error", "remote_storage_timeout") and v > 0),
            "hitRate": round(hits / (hits + misses), 3) if hits + misses else None,
            "cacheSizeKiB": after.get("cache_size_kibibyte"), "filesInCache": after.get("files_in_cache")}


def load_log(path: Path):
    lines = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"^(\d{13}) (.*)$", raw)
        if match:
            lines.append((int(match.group(1)), match.group(2)))
    return lines


def load_samples(path: Path):
    procs, samples, alls, meta = {}, [], [], {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        record = json.loads(raw)
        kind = record["kind"]
        if kind == "proc":
            procs[(record["pid"], record["created"])] = {
                "pid": record["pid"], "ppid": record["ppid"], "name": record["name"], "created": record["created"],
                "cmd": record["cmd"], "first": record["t"], "last": record["t"], "cpu0": None, "cpu": 0, "ws": 0}
        elif kind == "sample":
            samples.append(record)
            for pid, created, cpu, ws in record["procs"]:
                proc = procs.get((pid, created))
                if proc is None:
                    continue
                proc["last"] = record["t"]
                if proc["cpu0"] is None:
                    proc["cpu0"] = cpu
                proc["cpu"] = cpu
                proc["ws"] = max(proc["ws"], ws)
        elif kind == "all":
            alls.append(record)
        else:
            meta[kind] = record
    return procs, samples, alls, meta


def load_cpu(path: Path):
    rows = []
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        reader = csv.reader(handle)
        header = next(reader)
        cores = [i for i, h in enumerate(header) if re.search(r"Processor\((\d+)\)", h)]
        core_ids = [int(re.search(r"Processor\((\d+)\)", header[i]).group(1)) for i in cores]
        total = [i for i, h in enumerate(header) if "_Total" in h][0]
        for row in reader:
            try:
                stamp = datetime.strptime(row[0], "%m/%d/%Y %H:%M:%S.%f").timestamp() * 1000
                values = [float(row[i]) for i in cores]
                rows.append({"t": int(stamp), "total": float(row[total]),
                             "cores": [v for _, v in sorted(zip(core_ids, values))]})
            except (ValueError, IndexError):
                continue
    return rows


OTHER_TOOLS = ("cl.exe", "clang-cl.exe", "ninja.exe", "hl.exe", "cmake.exe", "link.exe", "lib.exe", "MSBuild.exe", "ccache.exe")


def other_activity(procs, ours, t_start, t_end, cpu, background, logical):
    """What else ran during the build: the CPU baseline before it, and other build tools alive while it ran."""
    others = [p for p in procs.values() if p["name"] in OTHER_TOOLS and not ours(p) and p["last"] >= t_start and p["created"] <= t_end]
    by_name, by_tree = defaultdict(int), defaultdict(int)
    for p in others:
        by_name[p["name"]] += 1
        match = OTHER.search((p["cmd"] or "").replace("/", "\\")) if OTHER else None
        by_tree[match.group(0).rstrip("\\\"") if match else "(no checkout in the command line)"] += 1
    starts = [p["created"] for p in others if p["created"] >= t_start - 60000]
    before = [r["total"] * logical / 100 for r in cpu if r["t"] < t_start]
    during = [r["total"] * logical / 100 for r in cpu if t_start <= r["t"] <= t_end]
    top = defaultdict(float)
    span = 0.0
    for b in background:
        if t_start <= b["t"] <= t_end:
            span += b["dt"]
            for name, cores in b["top"]:
                top[name] += cores * b["dt"]
    return {
        "cpuBaselineCores": round(sum(before) / len(before), 2) if before else None,
        "cpuDuringCores": round(sum(during) / len(during), 2) if during else None,
        "otherBuildTools": dict(sorted(by_name.items(), key=lambda kv: -kv[1])),
        "otherCheckouts": dict(sorted(by_tree.items(), key=lambda kv: -kv[1])),
        # When the first of them started that was not already running a minute before the build (an editor's hl.exe is).
        "firstOtherSeconds": round((min(starts) - t_start) / 1000, 1) if starts else None,
        "backgroundTop": [[n, round(v / span, 2)] for n, v in sorted(top.items(), key=lambda kv: -kv[1])[:6]] if span else [],
    }


def main() -> int:
    global HERE, OTHER
    HERE = Path(sys.argv[1])
    run = sys.argv[2]
    meta_path = HERE / f"{run}.meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8-sig")) if meta_path.exists() else {}
    worktree = meta.get("worktree") or (sys.argv[3] if len(sys.argv) > 3 else "")
    if worktree:
        own = {os.path.normpath(worktree)}
        haxeon = os.path.join(worktree, "haxeon")
        if os.path.exists(haxeon):
            own.add(os.path.normpath(os.path.realpath(haxeon)))
        OWN.extend(o.lower() + "\\" for o in own)
        OWN.extend(o.lower() + '"' for o in own)
        parent = os.path.dirname(os.path.normpath(worktree))
        leaves = "|".join(re.escape(os.path.basename(o)) for o in own)
        OTHER = re.compile(re.escape(parent) + r"\\(?!(?:" + leaves + r")[\\\"])[^\\\"]+[\\\"]", re.I)
    log = load_log(HERE / f"{run}.log")
    procs, samples, alls, sampler_meta = load_samples(HERE / f"{run}.jsonl")
    cpu = load_cpu(HERE / f"{run}.cpu.csv")
    interval = 500
    t_start = log[0][0]
    t_end = log[-1][0]
    for _, text in log:
        pass

    # Process tree rooted at the stamped-build pwsh.
    by_pid = defaultdict(list)
    for proc in procs.values():
        by_pid[proc["pid"]].append(proc)
    roots = [p for p in procs.values() if "stamped-build.ps1" in (p["cmd"] or "")]
    root_keys = {(p["pid"], p["created"]) for p in roots}

    def parent_of(proc):
        candidates = [c for c in by_pid.get(proc["ppid"], []) if c["created"] <= proc["created"] + 1000]
        return max(candidates, key=lambda c: c["created"]) if candidates else None

    membership = {}

    def ours(proc, depth=0):
        key = (proc["pid"], proc["created"])
        if key in membership:
            return membership[key]
        if key in root_keys:
            membership[key] = True
            return True
        cmd = proc["cmd"] or ""
        result = None
        parent = parent_of(proc) if depth < 40 else None
        if parent is not None:
            result = ours(parent, depth + 1)
        if result is None or result is False:
            if names_own(cmd):
                result = True
            elif proc["created"] >= t_start - 2000 and proc["name"] in SHORT_TOOLS and not names_other(cmd):
                # Short-lived tools whose parent was never sampled: attribute by time when no other build tree is named.
                result = "time" if parent is None else result
        membership[key] = result
        return result

    build = {k: p for k, p in procs.items() if ours(p) and p["created"] >= t_start - 5000}
    foreign = {k: p for k, p in procs.items() if not ours(p) and p["created"] >= t_start - 5000 and p["created"] <= t_end
               and p["name"] in ("cl.exe", "link.exe", "lib.exe", "MSBuild.exe", "cmake.exe", "ninja.exe", "clang-cl.exe", "ccache.exe")}

    # Log events.
    actions = []
    compiler_lines = []
    timings = []
    markers = {}
    for t, text in log:
        # haxeon action lines: "[kind:package:...] ...". Ninja's own "[12/214] Building ..." lines have no colon.
        match = re.match(r"^\[([a-z][\w-]*:[^\]]+)\] (.*)$", text)
        if match:
            if match.group(2).startswith("clean (fingerprint match)"):
                for open_action in reversed(actions):
                    if open_action["id"] == match.group(1) and open_action.get("cleanAt") is None:
                        open_action["cleanAt"] = t
                        break
            else:
                actions.append({"id": match.group(1), "desc": match.group(2), "start": t})
        match = re.match(r"^compiler: (\d+) ms, (\d+) functions retyped", text)
        if match:
            compiler_lines.append({"t": t, "ms": int(match.group(1)), "retyped": int(match.group(2))})
        match = re.match(r"^\s+(resolve|plan and lower|execute): ([\d.]+) ms", text)
        if match:
            timings.append({"t": t, "name": match.group(1), "ms": float(match.group(2))})
        if text.startswith("Visual Studio "):
            markers["vsEnvLoaded"] = t
            markers["vsLine"] = text
        if text.startswith("MSVC "):
            markers["msvcLine"] = text
        if text.startswith("== Exosuit build done"):
            markers["buildDone"] = t
            markers["buildDoneLine"] = text
        if text.startswith("== Exosuit build") and "done" not in text:
            markers["buildStart"] = t
        if text.startswith("#exit"):
            markers["exit"] = t
        match = re.match(r"^== (\w+) built in (\d+) s", text)
        if match:
            markers.setdefault("appBuilt", {})[match.group(1)] = {"t": t, "seconds": int(match.group(2))}

    # haxeon-cli build processes, one per app.
    projects = []
    for proc in build.values():
        cmd = proc["cmd"] or ""
        match = re.search(r"haxeon-cli\.hl\"?\s+build\s+--project\s+\"?([^\"]+?haxeon\.json)", cmd)
        if proc["name"] == "hl.exe" and match:
            app = Path(match.group(1)).parent.name
            projects.append({"app": app, "start": proc["created"], "end": proc["last"] + interval // 2, "pid": proc["pid"]})
    projects.sort(key=lambda p: p["start"])

    def app_at(t):
        for p in projects:
            if p["start"] - 1000 <= t <= p["end"] + 1000:
                return p["app"]
        return None

    # The app of each action: build.py builds agent, suit, graphical in order; each prints "Timings:" when it ends.
    timing_marks = [t for t, text in log if text.startswith("Timings:")]
    app_order = ["agent", "suit", "graphical"]

    def app_at(t):
        index = sum(1 for m in timing_marks if m < t)
        return app_order[index] if index < len(app_order) else None

    # Match action spans.
    cmake_procs = [p for p in build.values() if p["name"] == "cmake.exe"]
    for action in actions:
        action["app"] = app_at(action["start"])
        kind = action["id"].split(":")[0]
        action["kind"] = kind
        pkg = action["id"].split(":")[1] if ":" in action["id"] else None
        action["package"] = pkg
        action["end"] = None
        if kind in ("native-cmake-configure", "native-cmake-build") and action["app"]:
            tree = f"{action['app']}/build/host/native/{pkg}/"
            best = None
            for proc in cmake_procs:
                cmd = (proc["cmd"] or "").replace("\\", "/")
                if not cmd.lstrip('"').lower().startswith("cmake"):
                    continue
                is_build = "--build" in cmd
                if re.search(re.escape("/" + tree) + r'cmake(-ninja)?"', cmd) and is_build == (kind == "native-cmake-build") and abs(proc["created"] - action["start"]) < 15000:
                    if best is None or abs(proc["created"] - action["start"]) < abs(best["created"] - action["start"]):
                        best = proc
            if best is not None:
                action["end"] = best["last"] + interval // 2
                action["proc"] = (best["pid"], best["created"])
                action["procStart"] = best["created"]
    for action in actions:
        if action["kind"] == "native-cmake-build" and action["app"]:
            needle = "\\".join(["", action["app"], "build", "host", "native", action["package"], ""])
            limit = min([m for m in timing_marks if m > action["start"]] or [t_end])
            hits = [t for t, text in log if action["start"] <= t <= limit and "vcxproj ->" in text and needle in text]
            if hits:
                action["logEnd"] = hits[-1]
                if action.get("end") is None or action["end"] < action.get("procStart", action["start"]) or (t_end - t_start) < 60000:
                    action["end"] = hits[-1] + 50
                    action.pop("procStart", None) if (t_end - t_start) < 60000 else None
    # Ninja's last line of a build ("ninja: no work to do." or "[k/k] ...") names no tree. When a build's cmake process
    # was too short to sample, or the run is a short one, match those lines to the open builds of the app in start order.
    short_run = (t_end - t_start) < 60000
    for app in app_order:
        open_builds = sorted((a for a in actions if a["kind"] == "native-cmake-build" and a["app"] == app
                              and (short_run or a.get("end") is None or a["end"] < a["start"])), key=lambda a: a["start"])
        if not open_builds:
            continue
        limit = min([m for m in timing_marks if m > open_builds[0]["start"]] or [t_end])
        finals = [t for t, text in log if open_builds[0]["start"] <= t <= limit
                  and (text.startswith("ninja: no work to do") or re.match(r"^\[(\d+)/\] ", text))]
        for action in open_builds:
            hit = next((t for t in finals if t >= action["start"]), None)
            if hit is None:
                continue
            finals.remove(hit)
            action["end"] = hit + 1
            action["endFrom"] = "ninja's last line, matched in start order"
            action.pop("procStart", None)
    for action in actions:
        if action.get("cleanAt") is not None and action.get("end") is None:
            action["end"] = action["cleanAt"]
            action["clean"] = True
    # compile-project actions end at the compiler line that follows them in the same app.
    for action in actions:
        if action["kind"] == "compile-project":
            following = [c for c in compiler_lines if c["t"] >= action["start"] and app_at(c["t"]) == action["app"]]
            if following:
                action["end"] = following[0]["t"]
                action["compilerMs"] = following[0]["ms"]
                action["retyped"] = following[0]["retyped"]

    # Per action CPU: processes descending from the action's cmake process.
    children = defaultdict(list)
    for key, proc in build.items():
        parent = parent_of(proc)
        if parent is not None:
            children[(parent["pid"], parent["created"])].append(key)

    def subtree(key):
        out, stack = [], [key]
        while stack:
            k = stack.pop()
            out.append(k)
            stack.extend(children.get(k, []))
        return out

    for action in actions:
        if "proc" in action:
            keys = subtree(action["proc"])
            by_name = defaultdict(float)
            counts = defaultdict(int)
            for k in keys:
                p = build[k]
                by_name[p["name"]] += (p["cpu"] - (0 if p["created"] >= t_start else (p["cpu0"] or 0))) / 1e7
                counts[p["name"]] += 1
            life = defaultdict(float)
            for k in keys:
                p = build[k]
                life[p["name"]] += (p["last"] + interval / 2 - p["created"]) / 1000
            action["lifeSeconds"] = {n: round(v, 1) for n, v in life.items()}
            action["cpuSeconds"] = {n: round(v, 2) for n, v in by_name.items()}
            action["procCounts"] = dict(counts)

    # Concurrency per sample.
    series = []
    for sample in samples:
        if sample["t"] < t_start - 2000 or sample["t"] > t_end + 2000:
            continue
        counts = defaultdict(int)
        foreign_count = 0
        for pid, created, cpu_time, ws in sample["procs"]:
            key = (pid, created)
            if key in build:
                counts[build[key]["name"]] += 1
            elif key in foreign:
                foreign_count += 1
        series.append({"t": sample["t"], "counts": dict(counts), "foreign": foreign_count})

    # Cores used by this build's sampled processes, from CPU-time deltas between consecutive samples.
    build_cores = []
    prev = None
    for sample in samples:
        if sample["t"] < t_start - 2000 or sample["t"] > t_end + 2000:
            prev = None
            continue
        current = {(pid, created): cpu_time for pid, created, cpu_time, ws in sample["procs"] if (pid, created) in build}
        if prev is not None:
            dt = (sample["t"] - prev[0]) / 1000
            used = 0.0
            for key, value in current.items():
                before = prev[1].get(key)
                if before is not None:
                    used += max(0, value - before) / 1e7
                elif build[key]["created"] >= prev[0] - 50:
                    used += value / 1e7
            build_cores.append([sample["t"], round(used / dt, 2)])
        prev = (sample["t"], current)

    # CPU time by tool over the whole build.
    tool_cpu = defaultdict(float)
    tool_count = defaultdict(int)
    for p in build.values():
        base = 0 if p["created"] >= t_start else (p["cpu0"] or 0)
        tool_cpu[p["name"]] += (p["cpu"] - base) / 1e7
        tool_count[p["name"]] += 1

    # Background CPU: processes not in the build, from the 5 s snapshots.
    build_pids = {p["pid"] for p in build.values()}
    background = []
    for a, b in zip(alls, alls[1:]):
        dt = (b["t"] - a["t"]) / 1000
        before = {pid: (name, c) for pid, name, c in a["procs"]}
        used = defaultdict(float)
        ours_used = 0.0
        for pid, name, c in b["procs"]:
            if pid in before and before[pid][0] == name:
                delta = max(0.0, c - before[pid][1])
                if pid in build_pids:
                    ours_used += delta
                else:
                    used[name] += delta
        top = sorted(used.items(), key=lambda kv: -kv[1])[:6]
        background.append({"t": b["t"], "dt": dt, "backgroundCores": round(sum(used.values()) / dt, 2),
                           "buildCores": round(ours_used / dt, 2),
                           "top": [[n, round(v / dt, 2)] for n, v in top]})

    result = {
        "run": run,
        "meta": meta,
        "ccache": ccache_delta(HERE, run),
        "tStart": t_start, "tEnd": t_end,
        "wallSeconds": (t_end - t_start) / 1000,
        "markers": markers,
        "projects": projects,
        "actions": actions,
        "compilerLines": compiler_lines,
        "timings": timings,
        "toolCpuSeconds": {k: round(v, 1) for k, v in sorted(tool_cpu.items(), key=lambda kv: -kv[1])},
        "toolProcessCount": dict(tool_count),
        "concurrency": series,
        "buildCores": build_cores,
        "cpu": [r for r in cpu if t_start - 60000 <= r["t"] <= t_end + 5000],
        "background": background,
        "foreignBuildProcesses": [{"name": p["name"], "created": p["created"], "last": p["last"], "cmd": (p["cmd"] or "")[:200]} for p in foreign.values()],
        "samplerStart": sampler_meta.get("start", {}).get("t"),
        "processes": [{"name": p["name"], "pid": p["pid"], "ppid": p["ppid"], "created": p["created"], "last": p["last"],
                       "cpu": round((p["cpu"] - (0 if p["created"] >= t_start else (p["cpu0"] or 0))) / 1e7, 2),
                       "ws": p["ws"], "cmd": (p["cmd"] or "")[:400], "attribution": membership.get((p["pid"], p["created"])) if not isinstance(membership.get((p["pid"], p["created"])), bool) else "tree"}
                      for p in build.values()],
    }
    result["otherActivity"] = other_activity(procs, ours, t_start, t_end, cpu, background, len(cpu[0]["cores"]) if cpu else 32)
    (HERE / f"{run}.analysis.json").write_text(json.dumps(result, indent=1))
    if meta_path.exists():
        meta["otherActivity"] = result["otherActivity"]
        meta_path.write_text(json.dumps(meta, indent=1), encoding="utf-8")
    print(f"{run}: wall {result['wallSeconds']:.1f} s, {len(actions)} actions, {len(build)} build processes, {len(foreign)} foreign")
    for a in actions:
        dur = (a["end"] - a["start"]) / 1000 if a.get("end") else None
        print(f"  {a['app']:10} {a['id'][:60]:60} start {(a['start'] - t_start) / 1000:7.1f} dur {dur}")
    print("tool cpu:", result["toolCpuSeconds"])
    if foreign:
        trees = defaultdict(int)
        for p in foreign.values():
            match = OTHER.search((p["cmd"] or "").replace("/", "\\")) if OTHER else None
            trees[match.group(0).rstrip("\\\"") if match else "(no checkout named)"] += 1
        first = min(p["created"] for p in foreign.values())
        print(f"WARNING: {len(foreign)} build processes of other checkouts ran during this build, from {(first - t_start) / 1000:.0f} s:",
              ", ".join(f"{k} ({v})" for k, v in sorted(trees.items(), key=lambda kv: -kv[1])[:5]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
