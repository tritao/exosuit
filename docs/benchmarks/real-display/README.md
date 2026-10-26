# Frame costs on the real display

Scripted sessions run in exosuit on a real display (its GPU, compositor and window size, which Xvfb does not have),
with each phase of a session summarized as frame times against a 60 Hz budget. The app plays the input into its own
window through `--input-script`, so it never reaches other windows, and its state is kept apart from yours. Linux.

```bash
python3 scripts/build.py                                             # the build to measure
docs/benchmarks/real-display/run.sh sustained /tmp/bench --no-profile  # one scenario, ~40 s
docs/benchmarks/real-display/report.py /tmp/bench
```

Without `--no-profile` the run also records a sampling profile (`OUT/profile.hlpc`, 1 kHz) to read with
`haxeon/.tools/hashlink/hlprof-live report` or export to Perfetto; profiling adds cost, so compare frame times between
runs without it.

## Scenarios (`scenarios.py`)

| Scenario | Phases |
|---|---|
| `session` | Startup with a 10 MB file, sidebar switching, hovering the activity bar, typing, wheel scrolling, paging |
| `open` | Opening a source file of a few thousand lines, then the 10 MB file, through the file finder (Ctrl+P) |
| `selection` | Per file: select all and deselect; drag-select past the bottom edge (auto-scroll) and back |
| `sustained` | Per file: a character per frame for three seconds, then wheel scrolling every frame; whether the editor keeps up with a frame's work per frame |

The workspace holds `ExosuitApp.hx` (a real source file), `Document.hx` (a small one) and `big.txt` (10 MB, one
emoji per line).

## Reading the report

Per phase: frames drawn, frame time median, 95th percentile and worst, frames over 16.7 ms, and the worst age of
scripted input when it was delivered (what a person would feel as lag). Frame time is the app's own work for a frame,
measured by its host. Phases with slower input than 60 Hz show frame cost, not frame rate: the editor draws on
demand. The machine's load shows in these numbers; compare runs made close together, or the CPU samples of profiled
runs.
