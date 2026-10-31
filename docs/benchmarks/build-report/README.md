# Build report

Measures where the time goes in Exosuit's Windows build (`scripts/build-windows.ps1 -SkipBootstrap`) and writes
the "build anatomy" page: a timeline of every haxeon action and native target, CPU use per core, the processes that
ran, every compiled target with its flags, how often each is configured and built, ccache's hits, and the no-op
cost. Given a baseline, every section shows before and after, led by a "What changed" summary.

## What it measures

One run is one build of the three apps (agent, suit, graphical) in an already bootstrapped checkout:

- `cold`: the apps' build folders do not exist (a fresh checkout). With a fresh `-CcacheDir`, nothing is cached.
- `noop`: the same command right after a build.
- `warm`: deletes `agent/build`, `suit/build` and `graphical/build`, then builds. CMake configures again and the
  compiles come from the ccache the previous build filled (Windows ccache reuses objects of the same build tree only).

During a run, `sampler.ps1` records every build tool process every ~0.5 s (parent, command line, CPU time),
`typeperf` records per-core CPU every second, and `stamped-build.ps1` timestamps every line of build output.
Afterwards `measure.ps1` records ccache's counters, collects the static facts of every native build tree
(`collect_static.py`: CMake cache, try_compile count, `build.ninja` / `compile_commands.json` / `.ninja_log`, or
`.vcxproj` / `.tlog` for Visual Studio trees) and analyses the run (`analyze.py`).

`bootstrap.ps1` times the Haxeon toolchain bootstrap of a checkout separately (downloads, HashLink, the native
runtime, the Haxeon CLI and language server), since measured builds skip it.

## How to run it

```powershell
# A fresh checkout with a bootstrapped haxeon (a junction to a bootstrapped haxeon, or run bootstrap.ps1 first).
$tool = 'docs/benchmarks/build-report'
pwsh -NoProfile -File $tool/bootstrap.ps1 -Worktree C:\src\exosuit-fresh          # optional, timed separately
pwsh -NoProfile -File $tool/measure.ps1 -Worktree C:\src\exosuit-fresh -Kind cold -CcacheDir $env:LOCALAPPDATA\Exosuit\build-reports\exosuit-fresh\ccache
pwsh -NoProfile -File $tool/measure.ps1 -Worktree C:\src\exosuit-fresh -Kind noop -CcacheDir $env:LOCALAPPDATA\Exosuit\build-reports\exosuit-fresh\ccache
pwsh -NoProfile -File $tool/measure.ps1 -Worktree C:\src\exosuit-fresh -Kind warm -CcacheDir $env:LOCALAPPDATA\Exosuit\build-reports\exosuit-fresh\ccache

# The page, compared with the 2026-10-30 baseline, plus the PDF:
pwsh -NoProfile -File $tool/report.ps1 -Run $env:LOCALAPPDATA\Exosuit\build-reports\exosuit-fresh -Baseline $tool/baselines/2026-10-30 -Pdf
```

Runs start at once. Each records what else shared the machine (the CPU baseline before the build, busy cores
during it, the other checkouts' cl / ninja / hl / cmake / ccache processes alive while it ran) in `<run>.meta.json`,
and the page summarises it in Method. The build leaves haxeon's resident compiler worker running; it exits on its
idle timeout, or stop it.

### measure.ps1

| Parameter | Default | Meaning |
|---|---|---|
| `-Worktree` | (required) | The Exosuit checkout to build. Its `haxeon` must be bootstrapped (`haxeon/out/haxeon-cli.hl`). |
| `-Kind` | `cold` | `cold`: no app build folders may exist. `noop`: a build right after another. `warm`: deletes `agent/build`, `suit/build` and `graphical/build` first. |
| `-Name` | the kind | The run's name: the prefix of its files, so several runs of one kind can share a folder. |
| `-Out` | `%LOCALAPPDATA%\Exosuit\build-reports\<checkout folder name>` | The run folder. Keep it out of the repository: a cold run's process samples are several MB. |
| `-CcacheDir` | the user's cache | ccache's directory for this build. A separate one keeps other builds out of the counters; an empty one makes a cold build cold. |
| `-TimeoutSeconds` | 1500 | The guard's hard limit for the build (exit 124 when it is reached). |
| `-BaselineSeconds` | 30 | How long the sampler records before the build starts, to show the machine's load. |
| `-WaitQuiet` | off | Wait for a machine without other builds first (`wait-quiet.ps1`). |
| `-QuietChecks` | 2 | With `-WaitQuiet`: consecutive quiet checks, 30 s apart. Raise it when other work builds in bursts. |
| `-QuietMinutes` | 40 | With `-WaitQuiet`: give up (and fail) after this long. |

### bootstrap.ps1

| Parameter | Default | Meaning |
|---|---|---|
| `-Worktree` | (required) | The Exosuit checkout whose `haxeon` to bootstrap: downloads, HashLink, the native runtime, the CLI and language server. |
| `-Name` | `bootstrap` | The prefix of its files. |
| `-Out` | as for measure.ps1 | The run folder. |
| `-TimeoutSeconds` | 1800 | The guard's hard limit. |
| `-WaitQuiet`, `-QuietChecks`, `-QuietMinutes` | off, 2, 40 | As for measure.ps1. |

### report.ps1

| Parameter | Default | Meaning |
|---|---|---|
| `-Run` | (required) | A run folder. Its analysed runs are condensed into `summary.json` first. |
| `-Baseline` | none | Another run folder, or a folder or file holding a `summary.json` (such as `baselines/2026-10-30`). Adds before and after to every section. |
| `-Notes` | none | A JSON file of interpretation (see Notes below). |
| `-Out` | `<Run>\build-anatomy.html`, or `build-anatomy-after.html` with a baseline | The page. |
| `-Pdf` | off | Also write `<Out>.print.html`, print it to PDF with headless Edge and check the PDF's text. |
| `-PdfOut` | `<Out>` with `.pdf` | The PDF. |
| `-Edge` | Microsoft Edge's usual path | The Chromium browser to print with. |

### The Python steps

`measure.ps1` and `report.ps1` run these with `python -I`; they can also be run on their own:
`collect_static.py <checkout> <out.json>`, `analyze.py <run folder> <run name>`, `summarize.py <run folder>`,
`build_page.py <run folder> [--baseline <dir or summary.json>] [--notes <json>] [--out <html>] [--print <html>]`,
`pdf_check.py <rendered dom.html> <pdf> [<png folder>]`.

## How long it takes

On a 24-core i9-13900K: the bootstrap of a fresh haxeon about 40 s; a cold build 8 minutes with the Visual Studio
generator (2026-10-30), about 3 minutes with Ninja and ccache; a rebuild after deleting the app build folders about
2 minutes; a no-op about 10 s; plus a 30 s baseline before each run
(and, with `-WaitQuiet`, the wait for a quiet machine). `report.ps1` takes a few seconds, about 20 s more with `-Pdf`.

## What it needs

- Windows, Visual Studio 2026 with the C++ tools (as `scripts/build-windows.ps1` does), PowerShell 7.
- Python 3.10 or newer on PATH. The page needs only the standard library; `-Pdf` needs `pymupdf`
  (`python -m pip install pymupdf`) for the text check.
- Microsoft Edge for `-Pdf` (headless; `-Edge` names another Chromium). The page loads Mermaid 10.9.1 from
  cdnjs and the IBM Plex fonts from Google Fonts, so printing needs network access for the dependency diagram.

## How to read the output

A run folder holds, per run: `<run>.log` (timestamped build output), `<run>.jsonl` (process samples),
`<run>.cpu.csv` (typeperf), `<run>.guard.log`, `<run>.ccache-before.txt` / `-after.txt`, `<run>.meta.json`
(checkout, commits, machine), `<run>.static.json` and `<run>.analysis.json`. `report.ps1` adds `summary.json`
(a few hundred KB: everything the page needs) and the page. The summary can be shared: its paths are written
with `<worktree>`, `<vs>`, `<sdk>` and `<home>` placeholders, it leaves out the machine name, and of other activity it
keeps counts and CPU load only. The raw run folder keeps the full detail.

The page's sections: What changed (with a baseline), Where the time goes, Timeline (Gantt charts of every action and
of each target's compile window), Parallelism (CPU, per-core heat map, concurrent processes, serial stretches),
Inventory and duplicates, Compiler and linker flags (with the bootstrap's own Ninja trees), Dependencies, Haxe
compile, Generator / tools / no-op cost (with ccache counters), Method. Every table names the file it came from.

Read the CPU numbers as lower bounds: a process that lives less than one 0.5 s sample is missed, and with ccache
most compiles are that short. The compile window of a Ninja target comes from `.ninja_log` (exact); of an MSBuild
target, from its sampled `cl.exe` and object write times.

### Notes

`-Notes` takes a JSON file whose values are HTML snippets, all optional: `title`, `heading`, `subtitle`,
`machineNote`, `changedLead`, `whereLead`, `parallelNote`, `dupesNote`, `flagsNote`, `depsNote`, `haxeNote`,
`toolsNote`; lists of `{stake, title, body, source}` for `changes` (which change produced which saving), `worse`,
`left` and `findings`; and `method`, a list of extra `<li>` items.

## Baselines

`baselines/2026-10-30/summary.json` is the first measurement: exosuit `f73024b` with haxeon `727ebf0c`, the Visual
Studio generator, no ccache (cold 488 s, no-op 11 s). Pass the folder as `-Baseline`. To keep a new baseline, copy
a run folder's `summary.json` into `baselines/<date>/`.
