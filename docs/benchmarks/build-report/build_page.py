"""Builds the build anatomy page from a run folder's summary.json, optionally against a baseline's.

Usage: python -I build_page.py <run dir> [--baseline <dir or summary.json>] [--notes <notes.json>] [--out <page.html>]
                                         [--print <print.html>]

Every number on the page comes from the summaries. Interpretation (why something changed, what is left to do) is
not computed: it comes from an optional notes file (see README.md), and the page says so where it uses it.
--print also writes a standalone light-theme copy with print rules (A3 landscape) for the PDF.
"""

import argparse
import html
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
APPS = ("agent", "suit", "graphical")


def esc(s):
    return html.escape(str(s))


def load_summary(path: Path):
    path = path / "summary.json" if path.is_dir() else path
    return json.loads(path.read_text(encoding="utf-8-sig")), path


def fmt(v, digits=1):
    return "–" if v is None else f"{v:,.{digits}f}"


def kb(b):
    if b is None:
        return "–"
    return f"{b / 1024 / 1024:.2f} MB" if b >= 1024 * 1024 else f"{b / 1024:.0f} KB"


def delta(before, after, unit=" s", lower_is_better=True, digits=1):
    """The change from before to after as signed text, coloured by whether it is better."""
    if before is None or after is None:
        return "–"
    d = after - before
    pct = f" ({d / before * 100:+.0f}%)" if before else ""
    if abs(d) < 10 ** -digits / 2:
        return f'<span class="d-flat">no change</span>'
    good = (d < 0) == lower_is_better
    sign = "−" if d < 0 else "+"
    return f'<span class="{"d-good" if good else "d-bad"}">{sign}{abs(d):,.{digits}f}{unit}{pct}</span>'


def table(headers, rows, numeric=(), cls=""):
    out = [f'<div class="scroll {cls}"><table><thead><tr>']
    for i, h in enumerate(headers):
        out.append(f'<th class="{"n" if i in numeric else ""}">{h}</th>')
    out.append("</tr></thead><tbody>")
    for r in rows:
        if isinstance(r, dict) and r.get("group"):
            out.append(f'<tr class="group"><td colspan="{len(headers)}">{r["group"]}</td></tr>')
            continue
        out.append("<tr>" + "".join(f'<td class="{"n" if i in numeric else ""}">{c}</td>' for i, c in enumerate(r)) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def src(text):
    return f'<p class="src">Source: {text}</p>'


def legend(items):
    return '<div class="legend">' + "".join(f'<span style="--c: var({c})">{esc(t)}</span>' for t, c in items) + "</div>"


# ---------------------------------------------------------------- facts computed from one summary

def dur(a):
    return None if a is None or a.get("end") is None else a["end"] - a["start"]


def action(run, prefix, app):
    for a in run["actions"]:
        if a["id"].startswith(prefix) and a["app"] == app:
            return a
    return None


def generator_of(summary):
    gens = {t["generator"] for t in summary["trees"] if t["generator"]}
    return ", ".join(sorted(gens)) or "?"


def critical_chain(run, app):
    """The app's longest native chain: one package's configure followed by its build."""
    best = None
    for a in run["actions"]:
        if a["app"] != app or a["kind"] != "native-cmake-configure":
            continue
        b = action(run, f"native-cmake-build:{a['package']}", app)
        c, d = dur(a) or 0, dur(b) or 0
        if best is None or c + d > best["configure"] + best["build"]:
            best = {"package": a["package"], "configure": c, "build": d}
    return best or {"package": None, "configure": 0, "build": 0}


def phase(run, app):
    for p in run["projects"]:
        if p["app"] == app:
            return p["e"] - p["s"]
    return None


def facts(summary, kind="cold"):
    run = summary["runs"].get(kind)
    if run is None:
        return None
    chains = {app: critical_chain(run, app) for app in APPS}
    configures = [dur(a) for a in run["actions"] if a["kind"] == "native-cmake-configure" and dur(a)]
    builds = [dur(a) for a in run["actions"] if a["kind"] == "native-cmake-build" and dur(a)]
    haxe = {}
    for a in run["actions"]:
        if a["kind"] == "compile-project" and dur(a) is not None:
            haxe[a["app"]] = {"wall": dur(a), "s": a["start"], "ms": a.get("compilerMs"), "retyped": a.get("retyped")}
    dup = summary["duplicates"].get("nativekit", {"configured": [], "built": []})
    configured_nk = [t for t in summary["trees"] if "nativekit" in t["projects"]]
    return {
        "wall": run["wall"], "chains": chains,
        "critConfigure": sum(c["configure"] for c in chains.values()), "critBuild": sum(c["build"] for c in chains.values()),
        "sumConfigure": sum(configures), "sumBuild": sum(builds), "configures": len(configures), "builds": len(builds),
        "phases": {app: phase(run, app) for app in APPS}, "haxe": haxe, "stats": run["stats"],
        "nkBuilt": len(dup["built"]), "nkConfigured": len(configured_nk),
        "tryCompiles": sum(t["tryCompiles"] or 0 for t in summary["trees"]),
        "ccache": run.get("ccache"),
    }


def compile_seconds(summary, app, package, project):
    for r in summary["inventory"]:
        if (r["app"], r["package"], r["project"]) == (app, package, project):
            return r["seconds"]
    return None


# ---------------------------------------------------------------- page

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--baseline")
    ap.add_argument("--notes")
    ap.add_argument("--out")
    ap.add_argument("--print", dest="print_out")
    args = ap.parse_args()
    A, a_path = load_summary(Path(args.run))
    B, b_path = load_summary(Path(args.baseline)) if args.baseline else (None, None)
    notes = json.loads(Path(args.notes).read_text(encoding="utf-8-sig")) if args.notes else {}
    out = Path(args.out) if args.out else a_path.parent / ("build-anatomy-after.html" if B else "build-anatomy.html")
    page = render(A, B, notes, a_path, b_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    print("written", out, len(page))
    if args.print_out:
        Path(args.print_out).write_text(printable(page), encoding="utf-8")
        print("written", args.print_out)


def printable(page):
    head = '<!doctype html><html lang="en" data-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head><body>'
    page = page.replace('startOnLoad: false, theme: "base", securityLevel: "strict",',
                        'startOnLoad: false, theme: "base", securityLevel: "strict", flowchart: { htmlLabels: false, wrappingWidth: 400 },')
    page = page.replace('fontFamily: "IBM Plex Sans, Segoe UI, sans-serif", fontSize: "13px"', 'fontFamily: "Segoe UI, Arial, sans-serif", fontSize: "13px"')
    rules = """<style>
@page { size: A3 landscape; margin: 12mm; }
@media print {
  html, body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .scroll, .scroll.wide, .scroll.mid { overflow: visible !important; max-height: none !important; }
  .scroll.wide table, .scroll.mid table { min-width: 0 !important; }
  pre, pre * { white-space: pre-wrap !important; word-break: break-all !important; overflow: visible !important; }
  td code { white-space: normal !important; overflow-wrap: anywhere !important; }
  th { position: static !important; }
  .tip { display: none !important; }
  tr, .kpi, .kpis, .findings li { break-inside: avoid; }
  .chart, .mermaid { break-inside: avoid; }
  .chart svg, pre.mermaid svg { display: block; max-width: 100% !important; max-height: 250mm !important; width: auto !important; height: auto !important; margin: 0 auto; }
  h2, h3, .runlabel { break-after: avoid; }
}
</style>"""
    return head + page + rules + "</body></html>"


def render(A, B, notes, a_path, b_path):
    fa, fb = facts(A), (facts(B) if B else None)
    fa_noop, fb_noop = facts(A, "noop"), (facts(B, "noop") if B else None)
    fa_warm = facts(A, "warm")
    cmp = B is not None
    ra, rb = A["runs"], (B["runs"] if B else {})
    machine = A.get("machine") or {}
    logical = machine.get("logical") or 32

    def side(after_html, before_html, label_a="After", label_b="Before", stacked=False):
        if not cmp or before_html is None:
            return after_html
        if stacked:
            return f'<p class="runlabel">{label_b}</p>{before_html}<p class="runlabel">{label_a}</p>{after_html}'
        return f'<div class="pair"><div><p class="runlabel">{label_b}</p>{before_html}</div><div><p class="runlabel">{label_a}</p>{after_html}</div></div>'

    def chart(kind, key, wall=None, extra=""):
        w = f' data-wall="{wall:.2f}"' if wall else ""
        return f'<div class="chart" data-chart="{kind}" data-run="{key}"{w}{extra}></div>'

    # Chart data: only what the charts read.
    data_runs = {}
    for prefix, runs in (("a", ra), ("b", rb)):
        for kind, run in runs.items():
            data_runs[f"{prefix}-{kind}"] = {k: run[k] for k in ("wall", "gantt", "cpuTotal", "cpuBuild", "heat", "conc")}

    def wall2(kind):
        walls = [r[kind]["wall"] for r in (ra, rb) if kind in r]
        return max(walls) if walls else None

    # ------------------------------------------------ headline numbers
    bars = {"headline": {"unit": " s", "rows": []}, "configure": {"unit": " s", "rows": []}, "cores": {"unit": "", "rows": []}}
    bars["headline"]["rows"].append({"label": "Cold build", "before": fb["wall"] if fb else None, "after": fa["wall"]})
    if fa_noop:
        bars["headline"]["rows"].append({"label": "No-op build", "before": fb_noop["wall"] if fb_noop else None, "after": fa_noop["wall"]})
    if fa_warm:
        bars["headline"]["rows"].append({"label": "Rebuild after deleting app build folders", "before": None, "after": fa_warm["wall"]})
    for label, key in (("Configure on the critical path", "critConfigure"), ("Native build on the critical path", "critBuild"),
                       ("All configures, summed", "sumConfigure"), ("All native builds, summed", "sumBuild")):
        bars["configure"]["rows"].append({"label": label, "before": round(fb[key], 1) if fb else None, "after": round(fa[key], 1)})
    bars["cores"]["rows"].append({"label": "Cores this build used, mean", "before": fb["stats"]["buildCoresMean"] if fb else None, "after": fa["stats"]["buildCoresMean"]})
    bars["cores"]["rows"].append({"label": "Cores this build used, peak", "before": fb["stats"]["buildCoresMax"] if fb else None, "after": fa["stats"]["buildCoresMax"]})
    if fa_warm:
        bars["cores"]["rows"].append({"label": "Warm rebuild, mean cores", "before": None, "after": fa_warm["stats"]["buildCoresMean"]})
    data = {"machine": {"logical": logical}, "runs": data_runs, "bars": bars}

    # ------------------------------------------------ machine note
    def busy_line(name, f):
        s = f["stats"]
        return (f"{name}: {s['machinePre']:.1f} of {logical} logical cores busy in the baseline before it, {s['machineBusy']:.1f} during it; "
                f"other checkouts' compilers or linkers present in {s['foreignShare'] * 100:.0f}% of samples")
    lines = [busy_line("before, cold", fb)] if fb else []
    lines.append(busy_line("after, cold" if cmp else "cold", fa))
    if fa_warm:
        lines.append(busy_line("after, warm rebuild" if cmp else "warm rebuild", fa_warm))
    machine_note = ('<div class="note"><b>How quiet the machine was.</b> ' + "; ".join(esc(l) for l in lines) + ". "
                    + notes.get("machineNote", "") + "</div>")

    # ------------------------------------------------ What changed (comparison only)
    what_changed = ""
    if cmp:
        def tile(value, unit, label, before, after, sub, lower=True, digits=1):
            was = f'<div class="was">was {fmt(before, digits)}{unit} · {delta(before, after, unit, lower, digits)}</div>' if before is not None else ""
            return f'<div class="kpi"><div class="v">{value}<small>{unit}</small></div><div class="l">{esc(label)}</div>{was}<div class="s">{esc(sub)}</div></div>'
        cc = fa["ccache"] or {}
        wc = (fa_warm or {}).get("ccache") or {}
        tiles = [
            tile(f"{fa['wall']:.0f}", " s", "Cold build, wall", fb["wall"], fa["wall"], "scripts/build-windows.ps1 -SkipBootstrap in a fresh checkout"),
        ]
        if fa_noop:
            tiles.append(tile(f"{fa_noop['wall']:.1f}", " s", "No-op build, wall", fb_noop["wall"] if fb_noop else None, fa_noop["wall"], "right after the cold build"))
        if fa_warm:
            tiles.append(tile(f"{fa_warm['wall']:.0f}", " s", "Rebuild after deleting the app build folders", None, fa_warm["wall"],
                              f"configure again, compiles from ccache: {wc.get('hits', 0)} hits, {wc.get('misses', 0)} misses. Before, the same rebuild was a cold build ({fb['wall']:.0f} s)"))
        tiles.append(tile(f"{fa['stats']['buildCoresMean']:.1f}", f" of {logical}", "Cores this build used, mean (cold)", fb["stats"]["buildCoresMean"], fa["stats"]["buildCoresMean"],
                          f"peak {fa['stats']['buildCoresMax']:.0f} (before {fb['stats']['buildCoresMax']:.0f})", lower=False, digits=2))
        tiles.append(tile(f"{fa['critConfigure']:.0f}", " s", "Configure on the critical path", fb["critConfigure"], fa["critConfigure"],
                          f"build on it: {fa['critBuild']:.0f} s (before {fb['critBuild']:.0f} s)"))
        tiles.append(tile(f"{fa['nkBuilt']}×", "", "NativeKit compiled / configured", None, None,
                          f"compiled {fb['nkBuilt']}×, configured {fb['nkConfigured']}× before; configured {fa['nkConfigured']}× now"))
        rows = [
            ["Cold build, wall", fmt(fb["wall"]), fmt(fa["wall"]), delta(fb["wall"], fa["wall"])],
            ["No-op build, wall", fmt(fb_noop["wall"] if fb_noop else None), fmt(fa_noop["wall"] if fa_noop else None),
             delta(fb_noop["wall"] if fb_noop else None, fa_noop["wall"] if fa_noop else None)],
            ["Rebuild after deleting the app build folders", f"≈ {fb['wall']:.0f} (a cold build: no cache)", fmt(fa_warm["wall"] if fa_warm else None),
             delta(fb["wall"], fa_warm["wall"]) if fa_warm else "–"],
        ]
        for app in APPS:
            rows.append([f"&nbsp;&nbsp;{app} phase (haxeon-cli build), cold", fmt(fb["phases"][app]), fmt(fa["phases"][app]), delta(fb["phases"][app], fa["phases"][app])])
        rows += [
            ["Configure on the critical path (longest chain per app, summed)", fmt(fb["critConfigure"]), fmt(fa["critConfigure"]), delta(fb["critConfigure"], fa["critConfigure"])],
            ["Native build on the critical path", fmt(fb["critBuild"]), fmt(fa["critBuild"]), delta(fb["critBuild"], fa["critBuild"])],
            [f"All configure actions, summed ({fb['configures']} → {fa['configures']})", fmt(fb["sumConfigure"]), fmt(fa["sumConfigure"]), delta(fb["sumConfigure"], fa["sumConfigure"])],
            [f"All native build actions, summed ({fb['builds']} → {fa['builds']})", fmt(fb["sumBuild"]), fmt(fa["sumBuild"]), delta(fb["sumBuild"], fa["sumBuild"])],
            ["try_compiles in all configures", f"{fb['tryCompiles']}", f"{fa['tryCompiles']}", delta(fb["tryCompiles"], fa["tryCompiles"], "", digits=0)],
            ["Cores this build used, mean / peak", f"{fb['stats']['buildCoresMean']:.2f} / {fb['stats']['buildCoresMax']:.0f}",
             f"{fa['stats']['buildCoresMean']:.2f} / {fa['stats']['buildCoresMax']:.0f}", delta(fb["stats"]["buildCoresMean"], fa["stats"]["buildCoresMean"], "", False, 2)],
            ["Compilers alive at once, peak / mean (sampled)", f"{fb['stats']['clMax']} / {fb['stats']['clMean']:.2f}", f"{fa['stats']['clMax']} / {fa['stats']['clMean']:.2f}",
             delta(fb["stats"]["clMean"], fa["stats"]["clMean"], "", False, 2)],
            ["cl.exe CPU seconds (sampled, lower bound)", fmt(fb["stats"]["toolCpu"].get("cl.exe")), fmt(fa["stats"]["toolCpu"].get("cl.exe")),
             delta(fb["stats"]["toolCpu"].get("cl.exe"), fa["stats"]["toolCpu"].get("cl.exe"))],
            ["NativeKit core compiled / configured", f"{fb['nkBuilt']} / {fb['nkConfigured']}", f"{fa['nkBuilt']} / {fa['nkConfigured']}", delta(fb["nkConfigured"], fa["nkConfigured"], "", digits=0)],
            ["ccache hits / misses, cold", "no cache on Windows", f"{cc.get('hits', 0)} / {cc.get('misses', 0)}", "–"],
        ]
        if fa_warm:
            rows.append(["ccache hits / misses, warm rebuild", "–", f"{wc.get('hits', 0)} / {wc.get('misses', 0)}" + (f" ({wc['hitRate'] * 100:.0f}% hits)" if wc.get("hitRate") is not None else ""), "–"])
        head_table = table(["Measure", "Before, s", "After, s", "Change"], rows, numeric=(1, 2, 3), cls="mid")

        def items(key, cls=""):
            entries = notes.get(key) or []
            if not entries:
                return ""
            body = "".join(f'<li><div class="body"><b>{e["title"]}</b>{e["body"]}<div class="src">Source: {e.get("source", "")}</div></div><div class="stake">{e.get("stake", "")}</div></li>' for e in entries)
            return f'<ol class="findings {cls}">{body}</ol>'
        what_changed = f"""
<h2 id="changed">What changed</h2>
<div class="kpis">{"".join(tiles)}</div>
{notes.get("changedLead", "")}
<div class="chart" data-chart="bars" data-bars="headline" data-label="Before and after wall times"></div>
{legend([("before (" + esc(B["meta"]["cold"].get("exosuitCommit", "")[:8]) + ")", "--s-before"), ("after (" + esc(A["meta"]["cold"].get("exosuitCommit", "")[:8]) + ")", "--s-compile")])}
{head_table}
{src(f"before: {esc(b_path)}; after: {esc(a_path)}. Each value is computed the same way from both runs (build_page.py facts()).")}
<h3>Which change produced which saving</h3>
{items("changes")}
<h3>What got worse or did not change</h3>
{items("worse", "worse")}
<h3>What is still left</h3>
{items("left")}
<p class="src">The attributions above are interpretation: they combine the measured numbers with what each commit changed. Where a share is split between two changes, the text says how.</p>
"""

    # ------------------------------------------------ Where the time goes
    def where_kpis(f, noop_f):
        k = [(f"{f['wall']:.0f}<small> s</small>", "Cold build, wall", "#start → #exit of build-windows.ps1 -SkipBootstrap"),
             (f"{noop_f['wall']:.1f}<small> s</small>" if noop_f else "–", "No-op build, wall", "right after the cold build"),
             (f"{f['critConfigure']:.0f}<small> s</small>", "Configure on the critical path", "the longest configure → build chain of each app, configure part, summed"),
             (f"{f['critBuild']:.0f}<small> s</small>", "Native build on the critical path", "the same chains' build part"),
             (f"{f['stats']['buildCoresMean']:.1f}<small> of {logical}</small>", "Cores this build used, mean", f"peak {f['stats']['buildCoresMax']:.0f}; CPU-time deltas of sampled processes (a lower bound)")]
        return '<div class="kpis">' + "".join(f'<div class="kpi"><div class="v">{v}</div><div class="l">{esc(l)}</div><div class="s">{esc(s)}</div></div>' for v, l, s in k) + "</div>"
    phase_rows = []
    for app in APPS:
        ca, cb = fa["chains"][app], (fb["chains"][app] if fb else None)
        ha, hb = fa["haxe"].get(app, {}), (fb["haxe"].get(app, {}) if fb else {})
        row = [app]
        if cmp:
            row += [fmt(fb["phases"][app]), fmt(fa["phases"][app]), delta(fb["phases"][app], fa["phases"][app]),
                    f"{esc(cb['package'])}: {cb['configure']:.1f} + {cb['build']:.1f}", f"{esc(ca['package'])}: {ca['configure']:.1f} + {ca['build']:.1f}",
                    fmt(hb.get("wall")), fmt(ha.get("wall"))]
        else:
            row += [fmt(fa["phases"][app]), f"{esc(ca['package'])}: {ca['configure']:.1f} + {ca['build']:.1f}", fmt(ha.get("wall"))]
        phase_rows.append(row)
    phase_table = (table(["App", "Phase before, s", "Phase after, s", "Change", "Longest native chain before (configure + build, s)", "Longest native chain after", "Haxe compile before, s", "Haxe compile after, s"], phase_rows, numeric=(1, 2, 3, 6, 7), cls="wide")
                   if cmp else table(["App", "Phase, s", "Longest native chain (configure + build, s)", "Haxe compile, s"], phase_rows, numeric=(1, 3)))
    findings = "".join(f'<li><div class="body"><b>{e["title"]}</b>{e["body"]}<div class="src">Source: {e.get("source", "")}</div></div><div class="stake">{e.get("stake", "")}</div></li>' for e in notes.get("findings", []))
    where = f"""
<h2 id="summary">Where the time goes{" now" if cmp else ""}</h2>
{where_kpis(fa, fa_noop)}
{notes.get("whereLead", "")}
<h3>Per app: the phase, its longest native chain and its Haxe compile</h3>
{phase_table}
{src("&lt;run&gt;.analysis.json: haxeon-cli build process lifetimes, action spans")}
{"<h3>Ranked findings</h3><ol class='findings'>" + findings + "</ol>" if findings else ""}
"""

    # ------------------------------------------------ Timeline
    gantt_legend = legend([("setup / scripts", "--s-msbuild"), ("haxeon-cli build (one app)", "--s-bg"), ("CMake configure", "--s-cmake"),
                           ("cmake --build", "--s-compile"), ("one target's compiles (MSBuild: its cl.exe; Ninja: its edges)", "--s-link"), ("Haxe compile", "--s-haxe"), ("scripts/build.py", "--s-python")])

    def gantt(key, kind, label):
        return f'<div class="scroll"><div class="chart" data-chart="gantt" data-run="{key}" data-wall="{wall2(kind):.2f}" data-min-width="760" data-label="{esc(label)}"></div></div>'

    def actions_table(kind):
        a_run, b_run = ra.get(kind), rb.get(kind)
        before = {(x["app"], x["id"]): x for x in b_run["actions"]} if b_run else {}
        rows = []
        for app in APPS:
            rows.append({"group": app})
            seen = set()
            for x in a_run["actions"]:
                if x["app"] != app:
                    continue
                seen.add(x["id"])
                bx = before.get((app, x["id"]))
                extra = ""
                if x["kind"] == "compile-project" and x.get("compilerMs") is not None:
                    extra = f"compiler {x['compilerMs']} ms, {x['retyped']:,} retyped"
                elif x.get("procCounts"):
                    extra = ", ".join(f"{n.replace('.exe', '')} ×{c}" for n, c in sorted(x["procCounts"].items(), key=lambda kv: -kv[1])[:4])
                elif x["clean"]:
                    extra = "fingerprint match"
                cpu = sum(x["cpuSeconds"].values()) if x.get("cpuSeconds") else None
                row = [f"<code>{esc(x['id'])}</code>", fmt(x["start"]), fmt(dur(x))]
                if cmp:
                    row += [fmt(dur(bx)), delta(dur(bx), dur(x))]
                row += ["–" if cpu is None else f"{cpu:.0f}", esc(extra)]
                rows.append(row)
            if cmp and b_run:
                for bx in b_run["actions"]:
                    if bx["app"] == app and bx["id"] not in seen:
                        rows.append([f"<code>{esc(bx['id'])}</code> <span class='tag inferred'>gone</span>", "–", "–", fmt(dur(bx)), delta(dur(bx), 0), "–", "only in the before run"])
        heads = ["Action", "Start, s", "Wall, s"] + (["Before, s", "Change"] if cmp else []) + ["CPU s (sampled)", "Processes seen / notes"]
        return table(heads, rows, numeric=(1, 2, 3, 4, 5) if cmp else (1, 2, 3), cls="wide" if cmp else "mid")

    def noop_table():
        a_run, b_run = ra.get("noop"), rb.get("noop")
        if not a_run:
            return ""
        before = {(x["app"], x["id"]): x for x in b_run["actions"]} if b_run else {}
        gen_a, gen_b = generator_of(A), (generator_of(B) if B else "")
        rows = []
        for app in APPS:
            rows.append({"group": app})
            for x in a_run["actions"]:
                if x["app"] != app:
                    continue
                bx = before.get((app, x["id"]))
                how = lambda y, gen: "fingerprint match" if y and y["clean"] else (("Ninja" if "Ninja" in gen else "MSBuild") + " up-to-date pass" if y and y["kind"] == "native-cmake-build" else "")
                row = [f"<code>{esc(x['id'])}</code>", fmt(dur(x), 2), how(x, gen_a)]
                if cmp:
                    row[2:2] = [fmt(dur(bx), 2) if bx else "–", delta(dur(bx), dur(x), " s", True, 2) if bx else "new"]
                    row.append(how(bx, gen_b) if bx else "–")
                rows.append(row)
        heads = ["Action", "Wall, s"] + (["Before, s", "Change", "How it finished", "Before: how"] if cmp else ["How it finished"])
        return table(heads, rows, numeric=(1, 2, 3) if cmp else (1,), cls="mid")

    def timings_table():
        rows = []
        for label, runs in (("before", rb), ("after", ra)) if cmp else (("", ra),):
            for kind in ("cold", "noop", "warm"):
                run = runs.get(kind)
                if not run:
                    continue
                marks = run["timings"]
                for i, app in enumerate(APPS):
                    chunk = marks[i * 3:(i + 1) * 3]
                    if len(chunk) == 3:
                        built = run["appBuilt"].get(app, {}).get("seconds")
                        rows.append([f"{label} {kind}".strip(), app, f"{chunk[0]['ms']:.0f}", f"{chunk[1]['ms']:.1f}", f"{chunk[2]['ms'] / 1000:.1f}", "–" if built is None else built])
        return table(["Run", "App", "resolve, ms", "plan and lower, ms", "execute, s", "build.py “built in”, s"], rows, numeric=(2, 3, 4, 5))

    warm_block = ""
    if "warm" in ra:
        warm_block = f"""
<h3>Rebuild after deleting the app build folders ({ra['warm']['wall']:.0f} s)</h3>
<p class="prose">The new case: <code>agent/build</code>, <code>suit/build</code> and <code>graphical/build</code> deleted, then the same command. Every package configures again; the compiles go through ccache, which holds the cold build's objects for these same paths. Drawn on the cold build's time scale.</p>
{gantt_legend}
<div class="scroll"><div class="chart" data-chart="gantt" data-run="a-warm" data-wall="{wall2('cold'):.2f}" data-min-width="760" data-label="Warm rebuild Gantt chart"></div></div>
{actions_table("warm")}
{src("warm.log, warm.jsonl, warm.static.json (.ninja_log edge times)")}
"""
    timeline = f"""
<h2 id="timeline">1 · Timeline</h2>
<h3>Cold build ({(str(round(rb['cold']['wall'])) + ' s → ') if cmp else ''}{ra['cold']['wall']:.0f} s)</h3>
<p class="prose">Every haxeon action of the three <code>haxeon-cli build</code> runs, plus each target's compile window inside the native builds (indented lanes).{" Both charts use the same time scale, so the after chart's length is the saving." if cmp else ""} Hover a bar for its exact times.</p>
{gantt_legend}
{side(gantt("a-cold", "cold", "Cold build after"), gantt("b-cold", "cold", "Cold build before") if cmp else None, stacked=True)}
{src("&lt;run&gt;.log action lines with ms timestamps; &lt;run&gt;.jsonl cmake.exe lifetimes; MSBuild: object write times and sampled cl.exe; Ninja: .ninja_log edges")}
<h3>All actions, cold</h3>
{actions_table("cold")}
{src("&lt;run&gt;.analysis.json. CPU seconds are summed from sampled processes and miss processes shorter than one 0.5 s sample: lower bounds.")}
{warm_block}
<h3>No-op build ({(str(rb['noop']['wall']) + ' s → ') if cmp and 'noop' in rb else ''}{ra['noop']['wall'] if 'noop' in ra else '–'} s)</h3>
{gantt_legend}
{side(gantt("a-noop", "noop", "No-op after"), gantt("b-noop", "noop", "No-op before") if cmp and "noop" in rb else None, stacked=True) if "noop" in ra else ""}
{noop_table()}
{src("noop.log “clean (fingerprint match)” lines; noop.jsonl")}
<h3>haxeon's own timing lines (--timings)</h3>
{timings_table()}
{src("“Timings:” blocks printed by each haxeon-cli build; the after build.py also prints “== &lt;app&gt; built in N s”")}
"""

    # ------------------------------------------------ Parallelism
    cpu_legend = legend([("machine-wide busy cores (typeperf _Total)", "--s-bg"), ("this build's sampled processes", "--s-compile")])
    heat_legend = legend([("< 10 %", "--heat-0"), ("10–35 %", "--heat-1"), ("35–65 %", "--heat-2"), ("65–90 %", "--heat-3"), ("≥ 90 %", "--heat-4")])
    keys = []
    for runs in (ra, rb):
        for kind in runs:
            for k in runs[kind]["conc"]["keys"]:
                if k not in keys:
                    keys.append(k)
    names = {"foreign": "other checkouts' build tools"}
    color = {"cl.exe": "--s-compile", "ccache.exe": "--s-cache", "link.exe": "--s-link", "lib.exe": "--s-lib", "MSBuild.exe": "--s-msbuild",
             "ninja.exe": "--s-ninja", "cmake.exe": "--s-cmake", "hl.exe": "--s-haxe", "foreign": "--s-bg"}
    conc_legend = legend([(names.get(k, k), color[k]) for k in keys])
    conc_max = max((sum(run["conc"]["series"][k][i] for k in run["conc"]["keys"]) for runs in (ra, rb) for kind, run in runs.items() if kind == "cold" for i in range(len(run["conc"]["t"]))), default=0)

    def serial_table(run):
        rows = [[f"{s['s']:.0f}–{s['e']:.0f}", f"{s['len']:.1f}", f"{s['buildCores']:.2f}", f"{s['machineCores']:.1f}", "<br>".join(esc(x) for x in s["active"])] for s in run["serial"]]
        return table(["Window, s", "Length, s", "Build cores", "Machine busy cores", "Running actions"], rows, numeric=(1, 2, 3)) if rows else "<p class='prose'>None.</p>"

    def tool_table():
        names_all = []
        for runs in (rb, ra):
            if "cold" in runs:
                for n, v in runs["cold"]["stats"]["toolCpu"].items():
                    if v >= 0.1 and n not in names_all:
                        names_all.append(n)
        rows = []
        for n in names_all:
            av = ra["cold"]["stats"]["toolCpu"].get(n)
            ac = ra["cold"]["stats"]["toolCount"].get(n, 0)
            if cmp:
                bv = rb["cold"]["stats"]["toolCpu"].get(n)
                bc = rb["cold"]["stats"]["toolCount"].get(n, 0)
                rows.append([f"<code>{esc(n)}</code>", fmt(bv), fmt(av), delta(bv or 0, av or 0), bc, ac])
            else:
                rows.append([f"<code>{esc(n)}</code>", fmt(av), ac])
        return table(["Process", "CPU s before", "CPU s after", "Change", "Seen before", "Seen after"] if cmp else ["Process", "CPU seconds", "Processes seen"],
                     rows, numeric=(1, 2, 3, 4, 5) if cmp else (1, 2))
    warm_par = ""
    if "warm" in ra:
        warm_par = f"""<h3>CPU, warm rebuild</h3>{cpu_legend}{chart("cpu", "a-warm", wall2("cold"))}"""
    parallel = f"""
<h2 id="parallelism">2 · Parallelism</h2>
<p class="prose">The machine has {machine.get('cores', '?')} cores / {logical} logical processors. The blue area is the CPU this build's processes used, measured as CPU-time deltas between 0.5 s samples. The grey area behind it is everything the machine did.</p>
<h3>CPU, cold</h3>
{cpu_legend}
{side(chart("cpu", "a-cold", wall2("cold")), chart("cpu", "b-cold", wall2("cold")) if cmp else None, stacked=True)}
{src("&lt;run&gt;.cpu.csv (typeperf \\Processor(*)\\% Processor Time, 1 s), &lt;run&gt;.jsonl")}
{warm_par}
<h3>Per-core utilisation, cold (5 s bins)</h3>
{heat_legend}
{side(chart("heat", "a-cold", wall2("cold")), chart("heat", "b-cold", wall2("cold")) if cmp else None, stacked=True)}
<h3>Concurrent build processes, cold</h3>
<p class="prose">Processes alive at each 0.5 s sample, by name, on a shared scale. Peak compilers: {fb['stats']['clMax'] if cmp else ''}{' → ' if cmp else ''}{fa['stats']['clMax']}; mean {fb['stats']['clMean'] if cmp else ''}{' → ' if cmp else ''}{fa['stats']['clMean']}. Under Ninja with ccache each compile is a <code>ccache.exe</code> that starts <code>cl.exe</code>; most live less than one sample, so these counts are lower bounds.</p>
{conc_legend}
{side(chart("conc", "a-cold", wall2("cold"), f' data-max="{conc_max}"'), chart("conc", "b-cold", wall2("cold"), f' data-max="{conc_max}"') if cmp else None, stacked=True)}
{src("&lt;run&gt;.jsonl (Win32_Process every 0.5 s; attribution by parent chain, checkout path in the command line, or time)")}
<h3>Serial stretches</h3>
<p class="prose">Windows of at least 8 s in which this build used fewer than 1.5 cores, and what was running in them.</p>
{side(serial_table(ra["cold"]), serial_table(rb["cold"]) if cmp else None)}
<h3>CPU time by process, cold</h3>
{tool_table()}
{src("&lt;run&gt;.jsonl, kernel + user time at each process's last sample (lower bounds)")}
{notes.get("parallelNote", "")}
"""

    # ------------------------------------------------ Inventory and duplicates
    inv_rows = []
    b_inv = {(r["app"], r["package"], r["project"]): r for r in (B["inventory"] if B else [])}
    for app in APPS:
        inv_rows.append({"group": f"{app}/haxeon.json"})
        keys_here = []
        for r in A["inventory"]:
            if r["app"] == app and r["type"] != "Utility" and r["sources"]:
                keys_here.append((r["package"], r["project"], r, b_inv.get((app, r["package"], r["project"]))))
        if cmp:
            seen = {(p, n) for p, n, _, _ in keys_here}
            for (bapp, bp, bn), br in b_inv.items():
                if bapp == app and br["type"] != "Utility" and br["sources"] and (bp, bn) not in seen:
                    keys_here.append((bp, bn, None, br))
        for package, project, r, br in keys_here:
            built = r is not None and r["objects"] > 0
            row = [esc(package), f"<code>{esc(project)}</code>", esc((r or br)["type"] or ""), (r or br)["sources"],
                   (r["objects"] if built else ("not built" if r else "<span class='tag inferred'>gone</span>"))]
            if cmp:
                bbuilt = br is not None and br["objects"] > 0
                row += [fmt(br["seconds"]) if bbuilt else ("not built" if br else "–"), fmt(r["seconds"]) if built else "–",
                        delta(br["seconds"] if bbuilt else None, r["seconds"] if built else (0 if bbuilt else None)),
                        fmt(r.get("edgeSeconds")) if built and r.get("edgeSeconds") is not None else "–"]
            else:
                row += [fmt(r["seconds"]) if built else "–", fmt(r.get("edgeSeconds")) if built and r.get("edgeSeconds") is not None else "–"]
            row.append(kb(r["objectKB"] * 1024) if built else "–")
            inv_rows.append(row)
    inv_heads = (["Package", "Target", "Type", "Sources", "Objects", "Compile s before", "Compile s after", "Change", "Sum of edge times, s", "Objects size"] if cmp
                 else ["Package", "Target", "Type", "Sources", "Objects", "Compile s", "Sum of edge times, s", "Objects size"])
    inv_table = table(inv_heads, inv_rows, numeric=(3, 4, 5, 6, 7, 8, 9) if cmp else (3, 4, 5, 6, 7), cls="wide")

    dup_rows = []
    names_d = list(A["duplicates"])
    if cmp:
        names_d += [n for n in B["duplicates"] if n not in names_d]
    for name in sorted(names_d, key=lambda n: (-len(A["duplicates"].get(n, {}).get("built", [])), n)):
        da = A["duplicates"].get(name, {"configured": [], "built": []})
        db = B["duplicates"].get(name, {"configured": [], "built": []}) if cmp else None
        if len(da["configured"]) < 2 and (not db or len(db["configured"]) < 2):
            continue
        row = [f"<code>{esc(name)}</code>"]
        if cmp:
            row += [len(db["built"]), len(da["built"]), len(db["configured"]), len(da["configured"])]
        else:
            row += [len(da["built"]), len(da["configured"])]
        row.append("<br>".join(esc(w) for w in da["built"]) or "–")
        dup_rows.append(row)
    dup_table = table(["Target", "Built before", "Built after", "In configured trees before", "In configured trees after", "Built in (after)"] if cmp
                      else ["Target", "Built", "In configured trees", "Built in"], dup_rows, numeric=(1, 2, 3, 4) if cmp else (1, 2), cls="mid")
    out_rows = [[esc(o["app"]), esc(o["package"]), f"<code>{esc(o['name'])}</code>", kb(o["bytes"]) if o["bytes"] else "0 (placeholder)"]
                for o in A["outputs"] if o["name"].endswith((".dll", ".hdll"))]
    inventory = f"""
<h2 id="inventory">3 · Inventory and duplicates</h2>
<p class="prose">Every target that compiles code. “Compile s” is the target's compile window: for Ninja, the first compile edge's start to the last edge (or link) end in <code>.ninja_log</code>; for MSBuild, the sampled <code>cl.exe</code> start to the last object written. “Sum of edge times” adds up the Ninja edges, so it exceeds the window when compiles ran side by side.{" Rows marked gone exist only in the before run." if cmp else ""}</p>
{inv_table}
{src("&lt;run&gt;.static.json: build.ninja, compile_commands.json, .ninja_log and objects (Ninja); .vcxproj, .tlog and objects (MSBuild)")}
<h3>How many times each thing is built</h3>
<p class="prose">Targets that appear in more than one configured tree. A tree that is configured but does not build a target still pays for its configure.</p>
{dup_table}
{notes.get("dupesNote", "")}
<h3>What ends up next to each main.hl{" (after)" if cmp else ""}</h3>
{table(["App", "Package", "Runtime file", "Size"], out_rows, numeric=(3,))}
"""

    # ------------------------------------------------ Flags
    flag_rows, seen = [], set()
    for r in A["inventory"]:
        if not r["cl"] or r["project"] in seen or not r["objects"]:
            continue
        seen.add(r["project"])
        c = r["cl"]
        apps = sorted({x["app"] for x in A["inventory"] if x["project"] == r["project"] and x["objects"]})
        link = r["link"]["flags"] if r["link"] else "–"
        flag_rows.append([f"<code>{esc(r['project'])}</code>", ", ".join(apps), esc(r["type"]), esc(r["generator"]), f"<code>{esc(c['opt'])}</code>",
                          "<span class='flag-ok'>none</span>" if c["debug"] == "none" else f"<code>{esc(c['debug'])}</code>",
                          f"<code>{esc(c['runtime'])}</code>", "yes" if r.get("launcher") else "–", esc(c["pch"]), f"<code>{esc(c['warn'])}</code>",
                          f"<code>{esc(c['lang'])} {esc(c['std'] if c['std'] != '-' else '')} {esc(c['eh'] if c['eh'] != '-' else '')}</code>", c["defines"], f"<code>{esc(link)}</code>"])
    flags_table = table(["Target", "Apps", "Type", "Generator", "Optimization", "Debug info", "CRT", "ccache", "PCH", "Warnings", "Language", "/D count", "Link"], flag_rows, numeric=(11,), cls="wide")
    tree_rows = []
    b_trees = {(t["app"], t["package"]): t for t in (B["trees"] if B else [])}
    keys_t = [(t["app"], t["package"]) for t in A["trees"]] + ([k for k in b_trees if k not in {(t["app"], t["package"]) for t in A["trees"]}] if cmp else [])
    a_trees = {(t["app"], t["package"]): t for t in A["trees"]}
    for k in keys_t:
        ta, tb = a_trees.get(k), b_trees.get(k)
        row = [esc(k[0]), esc(k[1])]
        if cmp:
            row += [esc(tb["generator"]) if tb else "–", esc(ta["generator"]) if ta else "–",
                    tb["tryCompiles"] if tb and tb["tryCompiles"] is not None else "–", ta["tryCompiles"] if ta and ta["tryCompiles"] is not None else "–",
                    len(tb["projects"]) if tb else "–", len(ta["projects"]) if ta else "–", "yes" if ta and ta["fetch"] else "–"]
        else:
            row += [esc(ta["generator"]), ta["tryCompiles"] if ta["tryCompiles"] is not None else "–", len(ta["projects"]), "yes" if ta["fetch"] else "–"]
        row += [f"<code>{esc(ta['dir'])}</code>" if ta else "–", f"<code>{esc(ta['cRelease'] or '')}</code>" if ta else "–"]
        tree_rows.append(row)
    trees_table = table((["App", "Package", "Generator before", "Generator after", "try_compiles before", "after", "Targets before", "after", "WebView2 fetch", "Tree", "CMAKE_C_FLAGS_RELEASE"] if cmp
                         else ["App", "Package", "Generator", "try_compiles", "Targets", "WebView2 fetch", "Tree", "CMAKE_C_FLAGS_RELEASE"]), tree_rows,
                        numeric=(4, 5, 6, 7) if cmp else (3, 4), cls="wide")
    boot_rows = []
    for label, s in (("before", B), ("after", A)) if cmp else (("", A),):
        for b in s["bootstrap"]:
            boot_rows.append([label, f"<code>{esc(b['tree'])}</code>", b["outputs"], b["objects"], f"{b['edgeSeconds']:.1f}", f"{b['spanSeconds']:.1f}",
                              ", ".join(f"{esc(n)} {v:.1f} s" for n, v in b["slowest"][:3])])
    boot_table = table(["Run", "Ninja tree", "Outputs", "Objects", "Sum of edge times, s", "Span, s", "Slowest edges"], boot_rows, numeric=(2, 3, 4, 5))
    br = A.get("bootstrapRun")
    boot_run = ""
    if br:
        steps = "".join(f"<li><code>{s[0]:.1f} s</code> {esc(s[1])}" + (f" (next line {s[2]:.1f} s later)" if len(s) > 2 and s[2] >= 0.5 else "") + "</li>" for s in br["steps"][:40])
        boot_run = f"""<p class="prose">The after run's haxeon (<code>{esc((br.get('haxeonCommit') or '')[:10])}</code>) was bootstrapped fresh for this measurement, separately from the app builds: <b>{br['seconds']:.0f} s</b> (exit {br['exitCode']}), including the downloads of the pinned Haxe, formatter and ccache. Milestones from bootstrap.log:</p><ul class="prose">{steps}</ul>"""
    samples_a = A["samples"]
    flags = f"""
<h2 id="flags">4 · Compiler and linker flags</h2>
<p class="prose">The actual command lines{" after the change" if cmp else ""}: from <code>compile_commands.json</code> and <code>build.ninja</code> for Ninja trees, from the <code>.tlog</code> files for MSBuild trees. Every package builds Release.</p>
{flags_table}
{src("&lt;run&gt;.static.json")}
{notes.get("flagsNote", "")}
<h3>One nativekit compile, verbatim</h3>
<div class="scroll"><pre>{esc(samples_a.get("nativekitCompile", "–"))}</pre></div>
<h3>One libwebsockets compile</h3>
<div class="scroll"><pre>{esc(samples_a.get("websocketsCompile", "–")[:1600])}…</pre></div>
<h3>The nativekit link</h3>
<div class="scroll"><pre>{esc(samples_a.get("nativekitLink", "–")[:900])}…</pre></div>
<h3>CMake trees</h3>
{trees_table}
{src("CMakeCache.txt and CMakeFiles/CMakeConfigureLog.yaml of each tree" + ("; before: try_compile counts as reported in the first report (65 per NativeKit tree, 74 for exosuit-ui-native)" if cmp else ""))}
<h3>The haxeon bootstrap</h3>
{boot_run}
{boot_table}
{src("haxeon/out/cmake/windows-msvc and out/libffi/*/.ninja_log" + ("; before: the main checkout's logs (not rebuilt for the first report); after: the fresh bootstrap of this run's haxeon" if cmp else ""))}
"""

    # ------------------------------------------------ Dependencies
    lines_m = ["flowchart LR"]
    nk_where = []
    for app in APPS:
        lines_m.append(f'  subgraph {app.upper()}["{app}/haxeon.json → {app}/build/host/main.hl"]')
        for t in A["trees"]:
            if t["app"] != app:
                continue
            node = f"{app[:2].upper()}_{t['package'].replace('-', '_')}"
            built = ", ".join(t["built"][:6]) + ("…" if len(t["built"]) > 6 else "")
            lines_m.append(f'    {node}["{t["package"]}<br/>{t["generator"]}: {built or "nothing built"}"]')
            if "nativekit" in t["projects"]:
                nk_where.append(node)
        lines_m.append("  end")
    lines_m.append(f'  NK[("haxeon/vendor/nativekit<br/>full tree configured {len(nk_where)}×")]')
    if nk_where:
        lines_m.append("  NK -.-> " + " & ".join(nk_where))
    lines_m.append('  HL["hl.exe (haxeon/.tools/hashlink)<br/>loads main.hl, .hdll, DLLs via PATH"]')
    for app in APPS:
        lines_m.append(f"  {app.upper()} --> HL")
    deps = f"""
<h2 id="deps">5 · Dependencies</h2>
<p class="prose">Which app builds which native package, and which targets each tree compiles{" after the change" if cmp else ""}. Every package with <code>native.cmake</code> in its <code>haxeon.json</code> becomes one configure and one build action in the app that depends on it; each app gets its own <code>&lt;app&gt;/build/host/native/&lt;package&gt;/</code> tree.</p>
<div class="scroll"><pre class="mermaid">{esc(chr(10).join(lines_m))}</pre></div>
{notes.get("depsNote", "")}
{src("&lt;run&gt;.static.json (trees and the targets that produced objects)")}
"""

    # ------------------------------------------------ Haxe compile
    hx_rows = []
    for app in APPS:
        ha, hb = fa["haxe"].get(app, {}), (fb["haxe"].get(app, {}) if fb else {})
        row = [app]
        if cmp:
            row += [fmt(hb.get("ms", 0) / 1000 if hb.get("ms") else None), fmt(ha.get("ms", 0) / 1000 if ha.get("ms") else None),
                    f"{hb.get('retyped', 0):,}" if hb else "–", f"{ha.get('retyped', 0):,}" if ha else "–", fmt(hb.get("s")), fmt(ha.get("s"))]
        else:
            row += [fmt(ha.get("s")), fmt(ha.get("wall")), fmt(ha.get("ms", 0) / 1000 if ha.get("ms") else None), f"{ha.get('retyped', 0):,}"]
        hx_rows.append(row)
    hx_table = table(["App", "compiler: before, s", "after, s", "Functions retyped before", "after", "Starts at before, s", "after, s"] if cmp
                     else ["App", "Starts at, s", "Action wall, s", "compiler: line, s", "Functions retyped"], hx_rows, numeric=(1, 2, 3, 4, 5, 6) if cmp else (1, 2, 3, 4))
    haxe_sec = f"""
<h2 id="haxe">6 · Haxe compile</h2>
{hx_table}
{src("“compiler: N ms, M functions retyped” lines")}
{notes.get("haxeNote", "")}
"""

    # ------------------------------------------------ Generator, tools and no-op
    cc_rows = []
    for kind in ("cold", "noop", "warm"):
        run = ra.get(kind)
        if not run or not run.get("ccache"):
            continue
        c = run["ccache"]
        cc_rows.append([kind, c["hits"], c["directHits"], c["preprocessedHits"], c["misses"], c["uncacheable"],
                        "–" if c["hitRate"] is None else f"{c['hitRate'] * 100:.0f}%", kb((c.get("cacheSizeKiB") or 0) * 1024), c.get("filesInCache", "–")])
    cc_table = table(["Run", "Hits", "direct", "preprocessed", "Misses", "Uncacheable / other", "Hit rate", "Cache size after", "Files in cache"], cc_rows, numeric=(1, 2, 3, 4, 5, 6, 7, 8)) if cc_rows else "<p class='prose'>No ccache counters (ccache was not used).</p>"
    cc_detail = ""
    for kind in ("cold", "warm"):
        c = (ra.get(kind) or {}).get("ccache")
        if c:
            nz = ", ".join(f"{k} {v}" for k, v in sorted(c["counters"].items()) if v and k not in ("cache_size_kibibyte", "files_in_cache"))
            cc_detail += f"<p class='src'>{kind}: {esc(nz)}</p>"
    meta_a = A["meta"]["cold"]
    vs_line = ""
    for text in (ra["cold"]["markers"].get("vsLine"), ra["cold"]["markers"].get("msvcLine")):
        if text:
            vs_line += esc(text) + "; "
    noop_vs_a = ra.get("noop", {}).get("markers", {}).get("vsEnvLoaded")
    noop_vs_b = rb.get("noop", {}).get("markers", {}).get("vsEnvLoaded") if cmp else None
    tools = f"""
<h2 id="tools">7 · Generator, tools and no-op cost</h2>
<div class="prose-block"><ul>
<li><b>Toolchain:</b> {vs_line}</li>
<li><b>Generator:</b> {esc(generator_of(A))}{(" (before: " + esc(generator_of(B)) + ")") if cmp else ""}. ccache: {esc(meta_a.get("ccache") or "not used")}, cache directory <code>{esc(meta_a.get("ccacheDir") or "–")}</code>.</li>
<li><b>No-op:</b> {ra['noop']['wall'] if 'noop' in ra else '–'} s{(" (before " + str(rb['noop']['wall']) + " s)") if cmp and 'noop' in rb else ""}; loading the VS environment took {fmt(noop_vs_a)} s{(" (before " + fmt(noop_vs_b) + " s)") if noop_vs_b is not None else ""}.</li>
</ul></div>
{notes.get("toolsNote", "")}
<h3>ccache counters per run</h3>
{cc_table}
{cc_detail}
{src("`ccache --print-stats` before and after each run (&lt;run&gt;.ccache-before.txt / -after.txt), differenced")}
"""

    # ------------------------------------------------ Method
    def meta_li(label, m):
        return (f"<li><b>{label}:</b> checkout <code>{esc(m.get('worktree'))}</code> at exosuit <code>{esc(str(m.get('exosuitCommit'))[:10])}</code> "
                f"({esc(m.get('exosuitSubject') or '')}), haxeon <code>{esc(str(m.get('haxeonCommit'))[:10])}</code> ({esc(m.get('haxeonSubject') or '')}). "
                f"{esc(m.get('note') or '')}</li>")
    method_items = []
    if cmp:
        method_items.append(meta_li("Before", B["meta"]["cold"]))
    for kind in ("cold", "noop", "warm"):
        if kind in A["meta"]:
            m = A["meta"][kind]
            method_items.append(meta_li(f"{'After, ' if cmp else ''}{kind}", m) if kind == "cold" else
                                f"<li><b>{'After, ' if cmp else ''}{kind}:</b> started {esc(m.get('started', '')[:19])}, exit {m.get('exitCode')}, baseline {m.get('baselineSeconds')} s.</li>")
    def activity_li(label, m):
        o = m.get("otherActivity")
        if not o:
            return f"<li><b>Other activity, {label}:</b> not recorded.</li>"
        tools_seen = ", ".join(f"{esc(n.replace('.exe', ''))} ×{c}" for n, c in (o.get("otherBuildTools") or {}).items()) or "none"
        first = "" if o.get("firstOtherSeconds") is None else f", the first starting {o['firstOtherSeconds']:.0f} s into the build"
        checkouts = o.get("otherCheckoutCount")
        where = "" if checkouts is None else f"; they came from {checkouts} other checkout{'s' if checkouts != 1 else ''}"
        return (f"<li><b>Other activity, {label}:</b> machine-wide {fmt(o['cpuBaselineCores'])} busy cores in the baseline before the build, "
                f"{fmt(o['cpuDuringCores'])} during it. Other build tools alive during the build: {tools_seen}{first}{where}. "
                f"Their names and command lines are in the run folder's meta.json, not in the summary.</li>")
    if cmp:
        for kind in ("cold", "noop"):
            if kind in B["meta"]:
                method_items.append(activity_li(f"before, {kind}", B["meta"][kind]))
    for kind in ("cold", "noop", "warm"):
        if kind in A["meta"]:
            method_items.append(activity_li(f"{'after, ' if cmp else ''}{kind}", A["meta"][kind]))
    method_items += [
        "<li><b>Command:</b> <code>measure.ps1</code> starts the sampler, records a 30 s baseline, and runs "
        "<code>scripts/build-windows.ps1 -SkipBootstrap --timings</code> under <code>run-guarded.ps1</code>; stamped-build.ps1 prefixes every output line with a millisecond timestamp.</li>",
        "<li><b>Sampler:</b> Win32_Process for build tools every ~0.5 s (pid, parent, start time, command line, kernel + user CPU), a full Get-Process CPU snapshot every ~5 s, "
        "and <code>typeperf \\Processor(*)\\% Processor Time</code> at 1 s.</li>",
        "<li><b>Attribution:</b> a process belongs to the build when its parent chain reaches stamped-build.ps1, when its command line names the checkout (or the folder its haxeon junction points at), "
        "or, for a short-lived compiler or linker whose parent was never sampled, when it started during the build and names no sibling checkout.</li>",
        "<li><b>Limits:</b> processes shorter than one sample are missed, so CPU seconds and core counts are lower bounds; with ccache most compiles are that short.</li>",
    ]
    method_items += notes.get("method", [])
    method = f"""
<h2 id="method">8 · Method and sources</h2>
<div class="prose-block"><ul>{"".join(method_items)}</ul>
<p><b>Data:</b> after: <code>{esc(a_path.parent)}</code>{("; before: <code>" + esc(b_path.parent) + "</code>") if cmp else ""}. Built by docs/benchmarks/build-report (measure.ps1, report.ps1).</p></div>
"""

    css = (HERE / "page.css").read_text(encoding="utf-8")
    js = (HERE / "page.js").read_text(encoding="utf-8")
    title = notes.get("title") or ("Exosuit Build Anatomy, After" if cmp else "Exosuit Build Anatomy")
    heading = notes.get("heading") or ("Exosuit build anatomy, after the build-speed changes" if cmp else "Exosuit build anatomy")
    started = (meta_a.get("started") or "")[:10]
    cpu_name = machine.get("cpu", "?")
    sub = notes.get("subtitle") or ("Where the time goes in <code>scripts/build-windows.ps1 -SkipBootstrap</code>: an instrumented cold build in a fresh checkout, the no-op build right after it"
                                    + (", a rebuild after deleting the app build folders" if "warm" in ra else "") + ", and the build files they left behind. Every number names the file it came from; anything inferred says so.")
    page = f"""<title>{esc(title)}</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<style>
{css}
</style>
<main>
<header>
<p class="src">Exosuit · Windows build · measured {esc(started)} on {esc(cpu_name)} ({machine.get('cores', '?')} cores / {logical} threads, {machine.get('memoryGB', '?')} GB)</p>
<h1>{esc(heading)}</h1>
<p class="sub">{sub}</p>
</header>
{machine_note}
{what_changed}
{where}
{timeline}
{parallel}
{inventory}
{flags}
{deps}
{haxe_sec}
{tools}
{method}
</main>
<script type="application/json" id="build-data">{json.dumps(data, separators=(",", ":"))}</script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js"></script>
<script>
{js}
</script>
"""
    return page


if __name__ == "__main__":
    main()
