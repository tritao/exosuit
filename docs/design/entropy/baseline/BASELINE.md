# Step 0 baseline (2026-11-15)

Measured before any Step 0 deletion, at `cf25bf0e` (branch `entropy-s0`: `entropy-1115` 25f645cc plus the marks), one
run, Windows 11, 32 logical CPUs, other workers building in parallel on the same machine. Every number is milliseconds
from the editor's own connect timeline (`src/workspace/client/ConnectTimeline.hx`), so the driver's polling is not in
it. Raw run: [results-2026-11-15.json](results-2026-11-15.json) and [timeline-2026-11-15.json](timeline-2026-11-15.json).

## Numbers

| Path | Marks | ms |
|---|---|---|
| Editor start → first frame | `startup-main` → `first-frame` | **420** |
| — window opened | → `window-open` | 226 |
| — `ExosuitApp` built | → `app-constructed` | 244 (18) |
| — workspace clients attached | → `workspace-clients` | 245 (1) |
| — start context restored | → `context-started` | 245 (0) |
| — first frame drawn | → `first-frame` | 420 (175) |
| Editor start → own workspace's rows on screen (cold: its service started by the launch helper) | `startup-main` → `rows-frame` | **8,064** (helper launch alone 263 → 7,864) |
| Click expanding an idle workspace → first frame of its rows | `start-requested` → `rows-frame` | **1,176** (launch 52 → endpoint 932) |
| Double click opening an idle workspace → first frame of its rows | `open-workspace` → `rows-frame` | **867** (connected at 786) |
| Double click opening a running workspace → first frame of its rows | `open-workspace` → `rows-frame` | **228** (connected at 121) |
| New Agent Session (Claude, terminal mode) → tab accepts input | `new-agent-session` → `terminal-attached` | **63** |
| — its first screen shown | → `terminal-shown` | 247 |
| suit `machine` request → reply | `suit-begin` → `suit-reply` | **235** (first, at startup), then 109, 120, 117, 133 |

What the numbers say, against the plan's §5:

- The cold launch of the window's own workspace (7.6 s inside the launch helper) is by far the largest wait. The same
  chain for an idle workspace opened later takes 0.7–0.9 s, so most of the startup case is a first-start cost of the
  launcher → manager → daemon chain (Step 5), not the editor.
- Opening a running workspace is 121 ms to "connected" and 228 ms to its rows on screen (§5 recorded 79–128 ms to
  connected). Step 7 makes this a focus change.
- suit's `machine` reply is 109–235 ms here, with `EXOSUIT_SUIT_SCAN=0` in the fixture (no process scan); §5's
  440–490 ms was with the scan. Step 4 answers from memory.
- New Agent Session reaches an input-ready terminal in 63 ms once the chooser closes; a terminal host was already
  running in this workspace's service.

## The marks

All in `ConnectTimeline` (shown in the automation state as `timeline`, echoed to stderr with `EXOSUIT_CONNECT_LOG=1`):

- `startup-main`, `window-open`, `app-constructed`, `workspace-clients`, `context-started`, `app-built`, `first-frame`
  (`graphical/src/app/GraphicalMain.hx`). Time before `main` (loading the runtime) is not included.
- `rows-frame <workspace> own|other`: the first drawn frame after a workspace's rows became visible
  (`ConnectTimeline.markAtNextFrame`, flushed from the host's per-frame callback). It follows `open-workspace` (a row
  opened) or `start-requested` (an idle row expanded).
- `new-agent-session <workspace> <provider>` when a provider is chosen; `terminal-attached` when the terminal's OPEN is
  answered and it takes input; `terminal-shown` when its first screen is drawn from the snapshot.
- `suit-begin` / `suit-reply`, the reply's detail ending in the request's milliseconds (`MachineClient`).

## How to reproduce

Build the worktree, then run the scenario through the measurement script (one GUI run at a time on the machine; it
holds a global lock). In a primary-session worktree, through `wt-run.ps1`:

```
pwsh -NoProfile -File C:\Users\corbi\projects\exosuit-wt\wt-run.ps1 -Worktree <worktree> -TimeoutSeconds 400 -Exe pwsh `
  "-ArgLine:-NoProfile -File <worktree>/docs/benchmarks/perf-harness/measure.ps1 -Name baseline -Drive baseline_marks -DriveSeconds 100"
```

The scenario is `docs/benchmarks/perf-harness/gui_scenarios/baseline_marks.py`: isolated state and an isolated suit
with three workspaces (Alpha open, Beta and Gamma idle), the fake Claude TUI (`tests/workspace-terminals/fake-claude-tui.py`)
as the Claude CLI. It moves the real mouse. The editor runs about 15 s; the whole run took 127 s here, 62 of them
`scripts/run.py` rebuilding native libraries before the editor started. Results land in
`docs/benchmarks/perf-harness/runs/<Name>/result/` (`results.json`, `timeline.json`).
