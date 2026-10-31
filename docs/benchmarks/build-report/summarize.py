"""Condenses a folder of measured runs into summary.json: everything the report page needs, and nothing else.

Usage: python -I summarize.py <run dir> [--bootstrap-from <static.json>]

Reads, for each run that measure.ps1 recorded (<name>.meta.json with kind cold, noop or warm): <name>.analysis.json
and <name>.static.json; and bootstrap.meta.json / bootstrap.log when bootstrap.ps1 ran. Writes <run dir>/summary.json.
The summary is small (a few hundred KB), so a folder can be kept as a baseline after its raw data is gone.

A summary is meant to be shareable: every path in it is written relative to placeholders (<worktree>, <vs>, <sdk>,
<home>), the machine's name is left out, and of what else ran during a build only counts and CPU load are kept. The
names of other checkouts and programs stay in the raw run folder.
"""

import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

KINDS = ("cold", "noop", "warm")
# Visual Studio and the Windows SDK, in long and 8.3 form.
VS_PATH = re.compile(r"[A-Za-z]:[\\/](?:Program Files|PROGRA~1)[\\/](?:Microsoft Visual Studio|MICROS~\d)[\\/]\d+[\\/][^\\/\"\s]+", re.I)
SDK_PATH = re.compile(r"[A-Za-z]:[\\/](?:Program Files \(x86\)|PROGRA~2)[\\/](?:Windows Kits|WI3CF2~1)[\\/]\d+", re.I)
HOME_PATH = re.compile(r"(?:[A-Za-z]:|/[a-z])[\\/]Users[\\/][^\\/\"\s]+", re.I)


def scrubber(worktrees):
    """A function that rewrites the absolute paths in a string with placeholders."""
    patterns = []
    for w in sorted({w for w in worktrees if w}, key=len, reverse=True):
        variants = {w, w.replace("\\", "/")}
        for v in variants:
            patterns.append(re.compile(re.escape(v), re.I))

    def scrub(text):
        for pattern in patterns:
            text = pattern.sub("<worktree>", text)
        text = VS_PATH.sub("<vs>", text)
        text = SDK_PATH.sub("<sdk>", text)
        return HOME_PATH.sub("<home>", text)
    return scrub


def scrub_all(value, scrub):
    if isinstance(value, str):
        return scrub(value)
    if isinstance(value, list):
        return [scrub_all(v, scrub) for v in value]
    if isinstance(value, dict):
        return {scrub(k) if isinstance(k, str) else k: scrub_all(v, scrub) for k, v in value.items()}
    return value


def public_meta(meta, run_dir):
    """The run's meta without the machine's name and with only counts of what else ran."""
    meta = dict(meta)
    cache = meta.get("ccacheDir") or ""
    run = str(run_dir.resolve())
    if cache.lower().startswith(run.lower()):
        meta["ccacheDir"] = "<run folder>" + cache[len(run):]
    machine = dict(meta.get("machine") or {})
    machine.pop("name", None)
    meta["machine"] = machine
    other = meta.get("otherActivity")
    if other:
        meta["otherActivity"] = {
            "cpuBaselineCores": other.get("cpuBaselineCores"), "cpuDuringCores": other.get("cpuDuringCores"),
            "otherBuildTools": other.get("otherBuildTools"), "otherCheckoutCount": len([k for k in other.get("otherCheckouts", {}) if not k.startswith("(")]),
            "firstOtherSeconds": other.get("firstOtherSeconds"),
        }
    return meta


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def rel(run, t_ms):
    return (t_ms - run["tStart"]) / 1000


def short_id(ident):
    return ident.rsplit(":windows", 1)[0]


# ---------------------------------------------------------------- compile windows

def compile_windows(static, run):
    """Where each target compiled. Ninja: the .ninja_log edges. MSBuild: the sampled cl.exe and the object times."""
    cls = [p for p in run["processes"] if p["name"] == "cl.exe"]
    out = []
    for tree in static["trees"]:
        for p in tree["projects"]:
            if not p["objects"] or not p["firstObjectWrite"]:
                continue
            if p.get("generator") == "Ninja":
                if p.get("windowStart") is None:
                    continue
                s = p["windowStart"] * 1000
                e = max(p["windowEnd"], p.get("linkEnd") or 0) * 1000
                if e < run["tStart"] or s > run["tEnd"] + 5000:
                    continue
                how = f"{p['edges']} ninja compile edges, {p['edgeSeconds']:.1f} s of edge time"
            else:
                first = p["firstObjectWrite"] * 1000
                last = p["lastObjectWrite"] * 1000
                if last < run["tStart"] or first > run["tEnd"]:
                    continue
                match = [c for c in cls if c["created"] <= first + 300 and c["last"] + 800 >= last]
                if match:
                    c = max(match, key=lambda c: c["created"])
                    s, e, how = c["created"], last, "sampled cl.exe start to last object write"
                else:
                    s, e, how = first - 500, last, "object write times only (cl.exe too short to sample)"
            out.append({"app": tree["app"], "package": tree["package"], "project": p["name"], "objects": p["objects"],
                        "generator": p.get("generator", "Visual Studio"),
                        "s": round(rel(run, s), 1), "e": round(rel(run, e), 1), "seconds": round((e - s) / 1000, 1),
                        "edgeSeconds": p.get("edgeSeconds"), "how": how})
    return out


def gantt_rows(run, static=None):
    rows = []
    m = run["markers"]
    if "vsEnvLoaded" in m:
        rows.append({"lane": "build-windows.ps1: load VS env", "kind": "setup", "s": 0, "e": rel(run, m["vsEnvLoaded"]), "label": "vcvars64.bat + vswhere"})
    for proc in run["processes"]:
        if proc["name"] == "python.exe" and "build.py" in proc["cmd"]:
            rows.append({"lane": "scripts/build.py", "kind": "python", "s": rel(run, proc["created"]), "e": rel(run, proc["last"]) + 0.25, "label": "scripts/build.py (whole)"})
        if proc["name"] == "node.exe" and "npm" in proc["cmd"].lower():
            rows.append({"lane": "npm (language server)", "kind": "setup", "s": rel(run, proc["created"]), "e": rel(run, proc["last"]) + 0.25, "label": "ensure_language_server: npm"})
    for p in run["projects"]:
        rows.append({"lane": f"{p['app']}: haxeon build", "kind": "project", "s": rel(run, p["start"]), "e": rel(run, p["end"]), "label": f"haxeon-cli build --project {p['app']}/haxeon.json"})
    for a in run["actions"]:
        if a.get("end") is None:
            continue
        start = a.get("procStart", a["start"])
        if a["kind"] == "compile-project":
            lane, kind = f"{a['app']}: Haxe compile", "haxe"
            note = f"compiler: {a.get('compilerMs')} ms, {a.get('retyped')} functions retyped"
        elif a["kind"] == "native-cmake-configure":
            lane, kind, note = f"{a['app']}: {a['package']} configure", "configure", None
        elif a["kind"] == "native-cmake-build":
            lane, kind, note = f"{a['app']}: {a['package']} build", "build", None
        else:
            lane, kind, note = f"{a['app']}: {a['kind']}", "other", None
        rows.append({"lane": lane, "kind": kind, "s": rel(run, start), "e": rel(run, a["end"]), "label": a["id"], "note": note})
    if static:
        for item in compile_windows(static, run):
            what = "ninja edges" if item["generator"] == "Ninja" else "one cl.exe"
            rows.append({"lane": f"{item['app']} · {item['project']} ({'ninja' if item['generator'] == 'Ninja' else 'cl.exe'})", "kind": "link",
                         "s": item["s"], "e": item["e"], "label": f"{item['project']}: {item['objects']} objects, {what}", "note": item["how"]})
    order = {"setup": 0, "python": 1}
    rows.sort(key=lambda r: (order.get(r["kind"], 2), r["s"]))
    for r in rows:
        r["s"], r["e"] = round(r["s"], 2), round(r["e"], 2)
    return rows


def cpu_series(run, logical):
    total = [[round(rel(run, r["t"]), 2), round(r["total"] * logical / 100, 2)] for r in run["cpu"] if run["tStart"] - 1000 <= r["t"] <= run["tEnd"] + 1000]
    build = [[round(rel(run, t), 2), v] for t, v in run["buildCores"]]
    return total, build


def heat(run, bin_s, logical):
    wall = run["wallSeconds"]
    n = int(wall // bin_s) + 1
    sums = [[0.0] * n for _ in range(logical)]
    counts = [0] * n
    for r in run["cpu"]:
        t = rel(run, r["t"])
        if t < 0 or t > wall:
            continue
        i = int(t // bin_s)
        counts[i] += 1
        for c, v in enumerate(r["cores"][:logical]):
            sums[c][i] += v
    return {"bin": bin_s, "t0": 0, "rows": [[round(sums[c][i] / counts[i]) if counts[i] else 0 for i in range(n)] for c in range(logical)]}


CONC_KEYS = ["cl.exe", "ccache.exe", "link.exe", "lib.exe", "MSBuild.exe", "ninja.exe", "cmake.exe", "hl.exe", "foreign"]
CONC_COLORS = {"cl.exe": "var(--s-compile)", "ccache.exe": "var(--s-cache)", "link.exe": "var(--s-link)", "lib.exe": "var(--s-lib)",
               "MSBuild.exe": "var(--s-msbuild)", "ninja.exe": "var(--s-ninja)", "cmake.exe": "var(--s-cmake)", "hl.exe": "var(--s-haxe)",
               "foreign": "var(--s-bg)"}


def concurrency(run):
    present = [k for k in CONC_KEYS if k == "foreign" or any(s["counts"].get(k) for s in run["concurrency"])]
    out = {"t": [], "series": {k: [] for k in present}, "keys": present, "colors": {k: CONC_COLORS[k] for k in present}}
    for s in run["concurrency"]:
        out["t"].append(round(rel(run, s["t"]), 2))
        for k in present:
            out["series"][k].append(s["foreign"] if k == "foreign" else s["counts"].get(k, 0))
    return out


def serial_stretches(run, build, total, min_len, threshold=1.5):
    stretches, start, last_t = [], None, None
    for t, v in build:
        if v < threshold:
            if start is None:
                start = t
        else:
            if start is not None and t - start >= min_len:
                stretches.append([start, t])
            start = None
        last_t = t
    if start is not None and last_t - start >= min_len:
        stretches.append([start, last_t])
    out = []
    for s, e in stretches:
        active = []
        for a in run["actions"]:
            if a.get("end") is None:
                continue
            a0, a1 = rel(run, a.get("procStart", a["start"])), rel(run, a["end"])
            if a0 < e and a1 > s:
                active.append(short_id(a["id"]))
        inside_b = [v for t, v in build if s <= t <= e]
        inside_t = [v for t, v in total if s <= t <= e]
        out.append({"s": round(s, 1), "e": round(e, 1), "len": round(e - s, 1), "buildCores": round(sum(inside_b) / max(1, len(inside_b)), 2),
                    "machineCores": round(sum(inside_t) / max(1, len(inside_t)), 1), "active": active})
    return out


# ---------------------------------------------------------------- flags and inventory

def parse_cl(command):
    flags = {}
    tokens = re.findall(r'"[^"]*"|\S+', command)
    flags["opt"] = " ".join(t for t in tokens if re.fullmatch(r"[/-]O[d12x]|[/-]Ob\d|[/-]Os|[/-]Ot", t, re.I)) or "(none)"
    flags["debug"] = " ".join(t for t in tokens if re.fullmatch(r"[/-]Z[i7I]", t)) or "none"
    flags["runtime"] = " ".join(t for t in tokens if re.fullmatch(r"[/-]M[DT]d?", t)) or "?"
    flags["mp"] = " ".join(t for t in tokens if t.upper().startswith(("/MP", "-MP"))) or "absent"
    flags["gl"] = " ".join(t for t in tokens if t.upper() in ("/GL", "-GL")) or "absent"
    flags["pch"] = " ".join(t for t in tokens if t.startswith(("/Yu", "/Yc", "-Yu", "-Yc"))) or "none"
    flags["warn"] = " ".join(t for t in tokens if re.fullmatch(r"[/-]W[0-4]|[/-]Wall|[/-]WX-?|[/-]external:W\d", t)) or "-"
    flags["std"] = " ".join(t for t in tokens if t.startswith(("/std:", "-std:"))) or "-"
    flags["lang"] = " ".join(t for t in tokens if t in ("/TC", "/TP", "-TC", "-TP")) or "-"
    flags["eh"] = " ".join(t for t in tokens if t.startswith(("/EH", "-EH"))) or "-"
    flags["defines"] = len([t for t in tokens if t in ("/D", "-D")]) + len([t for t in tokens if re.match(r"^[/-]D\w", t)])
    return flags


def parse_link(command):
    tokens = re.findall(r'"[^"]*"|\S+', command)
    keep = [t for t in tokens if t.upper().lstrip("/-").startswith(("INCREMENTAL", "DEBUG", "LTCG", "OPT:", "MACHINE", "DLL", "SUBSYSTEM"))]
    libs = [t for t in tokens if t.upper().endswith(".LIB")]
    return {"flags": " ".join(keep) or "-", "libs": len(libs)}


def inventory(static, run):
    windows = {(w["app"], w["package"], w["project"]): w for w in compile_windows(static, run)}
    out = []
    for tree in static["trees"]:
        for p in tree["projects"]:
            kind = "Utility" if p["configurationType"] in (None, "Utility") and not p["objects"] else p["configurationType"]
            cl = parse_cl(p["clCommands"][0]["command"]) if p["clCommands"] else None
            link = None
            if p["linkCommands"]:
                link = parse_link(p["linkCommands"][0]["command"])
            elif p["libCommands"]:
                link = {"flags": "lib.exe " + " ".join(re.findall(r"[/-]MACHINE:\S+|[/-]LTCG", p["libCommands"][0]["command"], re.I)), "libs": 0}
            w = windows.get((tree["app"], tree["package"], p["name"]))
            out.append({
                "app": tree["app"], "package": tree["package"], "project": p["name"], "type": kind, "generator": p.get("generator", "Visual Studio"),
                "sources": p["sources"], "objects": p["objects"], "objectKB": round(p["objectBytes"] / 1024),
                "seconds": w["seconds"] if w else None, "edgeSeconds": p.get("edgeSeconds"), "how": w["how"] if w else None,
                "cl": cl, "link": link, "launcher": (p["clCompile"] or {}).get("LAUNCHER"),
                "mpSetting": (p["clCompile"] or {}).get("MultiProcessorCompilation"),
            })
    return out


def outputs(static):
    rows, seen = [], set()
    for tree in static["trees"]:
        for o in tree["outputs"]:
            if o["name"].lower().endswith((".dll", ".hdll", ".lib", ".exe")):
                key = (tree["app"], tree["package"], o["name"])
                if key not in seen:
                    seen.add(key)
                    rows.append({"app": tree["app"], "package": tree["package"], "name": o["name"], "bytes": o["bytes"]})
    return rows


def trees(static):
    out = []
    for t in static["trees"]:
        c = t["cache"]
        out.append({"app": t["app"], "package": t["package"], "dir": Path(t["tree"]).name, "generator": c.get("CMAKE_GENERATOR"),
                    "buildType": c.get("CMAKE_BUILD_TYPE"), "cRelease": c.get("CMAKE_C_FLAGS_RELEASE"), "cxxRelease": c.get("CMAKE_CXX_FLAGS_RELEASE"),
                    "cmakeVersion": ".".join(str(c.get(k, "?")) for k in ("CMAKE_CACHE_MAJOR_VERSION", "CMAKE_CACHE_MINOR_VERSION", "CMAKE_CACHE_PATCH_VERSION")),
                    "compiler": c.get("CMAKE_CXX_COMPILER") or c.get("CMAKE_C_COMPILER"), "launcher": c.get("CMAKE_C_COMPILER_LAUNCHER") or c.get("CMAKE_CXX_COMPILER_LAUNCHER"),
                    "makeProgram": c.get("CMAKE_MAKE_PROGRAM"), "fetch": t["fetchContent"], "configureLogBytes": t["configureLogBytes"],
                    "tryCompiles": t.get("tryCompiles"), "projects": [p["name"] for p in t["projects"]],
                    "built": [p["name"] for p in t["projects"] if p["objects"]]})
    return out


def duplicates(static):
    """How many trees configure and build each compiled target."""
    built, configured = defaultdict(list), defaultdict(list)
    for t in static["trees"]:
        where = f"{t['app']}/{t['package']}"
        for p in t["projects"]:
            if p["sources"]:
                configured[p["name"]].append(where)
                if p["objects"]:
                    built[p["name"]].append(where)
    return {name: {"configured": configured[name], "built": built.get(name, [])} for name in configured}


def samples(static):
    """One nativekit compile, one libwebsockets compile and the nativekit link, verbatim, from the first app that has them."""
    out = {}
    for t in static["trees"]:
        for p in t["projects"]:
            if p["name"] == "nativekit" and p["clCommands"] and "nativekitCompile" not in out:
                out["nativekitCompile"] = p["clCommands"][0]["command"]
                if p["linkCommands"]:
                    out["nativekitLink"] = p["linkCommands"][0]["command"]
            if p["name"] == "websockets" and p["clCommands"] and "websocketsCompile" not in out:
                out["websocketsCompile"] = p["clCommands"][0]["command"]
    return out


# ---------------------------------------------------------------- runs

def run_stats(run, logical):
    inside = [r["total"] * logical / 100 for r in run["cpu"] if run["tStart"] <= r["t"] <= run["tEnd"]]
    before = [r["total"] * logical / 100 for r in run["cpu"] if r["t"] < run["tStart"]]
    conc = run["concurrency"] or [{"counts": {}, "foreign": 0}]
    compilers = [s["counts"].get("cl.exe", 0) for s in conc]
    return {
        "buildCoresMean": round(statistics.mean(v for t, v in run["buildCores"]), 2) if run["buildCores"] else None,
        "buildCoresMax": round(max((v for t, v in run["buildCores"]), default=0), 1),
        "machineBusy": round(statistics.mean(inside), 2) if inside else None,
        "machinePre": round(statistics.mean(before), 2) if before else None,
        "foreignShare": round(sum(1 for s in conc if s["foreign"] > 0) / len(conc), 3),
        "clMax": max(compilers), "clMean": round(statistics.mean(compilers), 2),
        "toolCpu": run["toolCpuSeconds"], "toolCount": run["toolProcessCount"],
    }


def trim_actions(run):
    out = []
    for a in run["actions"]:
        item = {"id": short_id(a["id"]), "app": a["app"], "kind": a["kind"], "package": a.get("package"), "clean": bool(a.get("clean")),
                "start": round(rel(run, a.get("procStart", a["start"])), 2), "logStart": round(rel(run, a["start"]), 2),
                "end": round(rel(run, a["end"]), 2) if a.get("end") else None}
        for key in ("compilerMs", "retyped", "cpuSeconds", "procCounts"):
            if key in a:
                item[key] = a[key]
        out.append(item)
    return out


def bootstrap_run(run_dir: Path):
    meta_path = run_dir / "bootstrap.meta.json"
    log_path = run_dir / "bootstrap.log"
    if not meta_path.exists() or not log_path.exists():
        return None
    meta = load(meta_path)
    lines = []
    for raw in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^(\d{13}) (.*)$", raw)
        if m:
            lines.append((int(m.group(1)), m.group(2)))
    t0 = lines[0][0]
    steps = []
    for i, (t, text) in enumerate(lines):
        if re.match(r"^-- (Downloading|Haxeon)", text) or text.startswith("=="):
            following = lines[i + 1][0] if i + 1 < len(lines) else t
            steps.append([round((t - t0) / 1000, 1), text[:160], round((following - t) / 1000, 1)])
    return {"seconds": round((lines[-1][0] - t0) / 1000, 1), "exitCode": meta.get("exitCode"), "haxeonCommit": meta.get("haxeonCommit"),
            "steps": steps[:80], "ccacheDownload": [s for s in steps if "ccache" in s[1].lower()]}


def main():
    run_dir = Path(sys.argv[1])
    metas = {}
    for path in sorted(run_dir.glob("*.meta.json")):
        meta = load(path)
        if meta.get("kind") in KINDS and (run_dir / f"{meta['name']}.analysis.json").exists():
            metas.setdefault(meta["kind"], meta)
    if "cold" not in metas:
        raise SystemExit(f"{run_dir}: no analysed cold run")
    logical = int((metas["cold"].get("machine") or {}).get("logical") or 32)
    scrub = scrubber([m.get("worktree") for m in metas.values()])
    metas = {k: public_meta(m, run_dir) for k, m in metas.items()}
    result = {"version": 1, "machine": metas["cold"].get("machine") or {}, "meta": metas, "runs": {}, "bootstrapRun": bootstrap_run(run_dir)}
    statics = {}
    for kind, meta in metas.items():
        run = load(run_dir / f"{meta['name']}.analysis.json")
        static_path = run_dir / f"{meta['name']}.static.json"
        static = load(static_path) if static_path.exists() else None
        statics[kind] = static
        total, build = cpu_series(run, logical)
        long_run = run["wallSeconds"] > 60
        result["runs"][kind] = {
            "name": meta["name"], "wall": round(run["wallSeconds"], 1),
            "gantt": gantt_rows(run, static if kind != "noop" and static else None),
            "cpuTotal": total, "cpuBuild": build,
            "heat": heat(run, 5 if long_run else 1, logical),
            "conc": concurrency(run),
            "serial": serial_stretches(run, build, total, 8.0 if long_run else 2.0),
            "stats": run_stats(run, logical),
            "actions": trim_actions(run),
            "timings": run["timings"],
            "markers": {k: (round(rel(run, v), 2) if isinstance(v, int) else v) for k, v in run["markers"].items() if k != "appBuilt"},
            "appBuilt": {k: {"t": round(rel(run, v["t"]), 2), "seconds": v["seconds"]} for k, v in run["markers"].get("appBuilt", {}).items()},
            "projects": [{"app": p["app"], "s": round(rel(run, p["start"]), 2), "e": round(rel(run, p["end"]), 2)} for p in run["projects"]],
            "compilerLines": [{"t": round(rel(run, c["t"]), 2), "ms": c["ms"], "retyped": c["retyped"]} for c in run["compilerLines"]],
            "ccache": run.get("ccache"),
            "windows": compile_windows(static, run) if static else [],
        }
    cold_static = statics["cold"]
    cold_run = load(run_dir / f"{metas['cold']['name']}.analysis.json")
    result["inventory"] = inventory(cold_static, cold_run)
    result["outputs"] = outputs(cold_static)
    result["trees"] = trees(cold_static)
    result["duplicates"] = duplicates(cold_static)
    result["samples"] = samples(cold_static)
    result["bootstrap"] = cold_static.get("bootstrap") or []
    if len(sys.argv) > 3 and sys.argv[2] == "--bootstrap-from":
        result["bootstrap"] = load(Path(sys.argv[3])).get("bootstrap", [])
    text = json.dumps(scrub_all(result, scrub), separators=(",", ":"))
    (run_dir / "summary.json").write_text(text)
    print(f"summary.json: {len(text) // 1024} KB, runs {sorted(result['runs'])}")


if __name__ == "__main__":
    main()
