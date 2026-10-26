# Input latency with real input

Measures how long the editor takes to react to real input: from the moment Windows receives a mouse move, button or
key, to the moment the editor takes it off its queue, and what the UI thread was doing meanwhile. Scripted benchmarks
(`../live-mode-performance/`) inject input into the app's own queue, so they cannot see this delay; these tools can.
The Windows tools below are `hook.py`, `driver.py`, `session.sh` and `analyze.py`. Linux has its own, which read the
profiler's capture instead of three text files: see [Linux](#linux).

## How it works

Three recorders share one clock, `QueryPerformanceCounter`, so their files merge onto one timeline:

| Recorder | Enabled by | Records |
|---|---|---|
| `hook.py` (low-level mouse and keyboard hooks) | running it | each input as Windows receives it, before any app; `injected` marks `SendInput` events |
| NativeKit | `NK_LATENCY_TRACE=<file>` | each input message the app dequeues, each wait for events, each on-demand frame |
| HashLink | `HL_GC_TIMELINE=<file>` | each stop-the-world GC pause |

With the variables unset, the app-side trace points cost one check each.

`driver.py` replaces the human: it sends input with `SendInput`, which takes the same path through Windows as a
physical device. It sweeps the mouse at 1 kHz with pauses between sweeps (so movement onsets can be measured), then
clicks the text area and taps and holds arrow keys (no file changes).

## Running

```bash
# A person drives: hover over the editor (with pauses), then click the text and use the arrow keys.
docs/benchmarks/input-latency/session.sh human-normal C:/path/to/project C:/path/to/project/file.hx
docs/benchmarks/input-latency/session.sh human-live --live C:/path/to/project C:/path/to/project/file.hx

# The driver drives (keep the desktop unlocked: SendInput does not reach a locked session).
docs/benchmarks/input-latency/session.sh driven-live --drive 60 --live C:/path/to/project C:/path/to/project/file.hx
```

Each run writes `runs/<name>/`: the three raw files, `summary.txt` and `<name>.pftrace`. The editor process is limited
to 150 s.

## Reading the results

`analyze.py HOOK APP GC` prints three distributions, each with a 2 ms histogram and, for inputs slower than 10 ms, how
that time split between waiting, frames, GC and other UI-thread work:

- **ONSET**: the first move after at least 100 ms of stillness until the app dequeues a move. The app has nothing to
  draw then, so this is the delay a person feels when they start moving.
- **MOVING**: during continuous movement, the oldest move each dequeue delivered.
- **KEYS**: each key transition until the app dequeues it.

`to_perfetto.py HOOK APP GC OUT.pftrace` writes a trace for <https://ui.perfetto.dev> with tracks for OS input, the UI
thread (waits, frames, GC pauses, dequeues) and one bar per input from arrival to dequeue; bars over 10 ms are named
`SLOW`. To open it from a local file, drag it into the Perfetto UI, or serve the folder with
`../live-mode-performance/serve_dir.py runs/<name>` and open
`https://ui.perfetto.dev/#!/?url=http://127.0.0.1:9001/<name>.pftrace`.

## Known limits

- "Inside the window" is the bounding box of the positions the app received. A move over the title bar or borders
  (`WM_NCMOUSEMOVE`, not traced yet) or over another window covering the editor counts as pending for the editor, which
  inflates ONSET and MOVING. Tracing non-client moves and recording the window under the cursor in the hook removes this.
- The hook runs in Python; each callback adds well under a millisecond to input delivery for every app.

## Findings so far (2026-10-26, human input, before fixes)

| | Normal | Live |
|---|---|---|
| ONSET median / p90 / p95 | 24 / 57 / 59 ms | 26 / 131 / 186 ms |
| MOVING median / p90 | 7.3 / 50 ms | 12.3 / 53 ms |
| KEYS median / p90 / p95 | 11 / 58 / 189 ms (30 keys) | 9 / 29 / 34 ms (274 keys) |

Slow inputs spent about 40% of their delay in frames and 40-70% in other UI-thread work; waiting and GC were small.
The worst live onsets show the editor drawing frames back to back or pumping short waits while a move goes undequeued
for 200+ ms. Two explanations remain open: Windows hands an app posted messages (NativeKit's frame message) before
mouse input, so a stream of frames can starve input; and the bounding-box limit above.

## Linux

`session_linux.sh NAME [--seconds S] [--live]` runs the editor on its own sources in a private Xvfb display, drives it with
X11 input (`driver_x11.py`, through the XTEST extension), records a profiler capture and prints the tables from
`analyze_capture.py`. Output is in `runs/NAME/`. Nothing reaches your desktop. Build the editor first
(`python3 scripts/build.py`).

It reads NativeKit's trace points from the capture (see `haxeon/docs/PROFILING.md`). Each input appears twice on the UI
thread: when NativeKit's handler had it (`Input age`: time since the X server stamped it) and when the application took
it off NativeKit's queue (`Input polled age`). A move that the queue merged into a newer one reports the oldest input it
stands for. ONSET, MOVING and KEYS are the polled ages, as the Windows analyzer defines them, and slow inputs are split by
what the UI thread was doing (`nk.frame`, `nk.wait`, other).

`session_linux.sh NAME --resize --seconds 40` resizes the window instead (`driver_x11.py --mode resize`, configure requests
every 8 ms, shrinking and growing between pauses, no window manager) and the tables gain a RESIZE section: for each drag the
resizes the application polled, the frames drawn while it lasted (their cost, the gaps between them against a 16.7 ms
budget) and the time from a polled resize to the end of the next frame. It works with `--human` too: drag the window edge.

To measure on your own display, with your GPU and devices, run `session_linux.sh NAME --human --seconds 60`: the editor opens
on `$DISPLAY`, nothing is injected, and you move the mouse over it with pauses, click in the text and use the arrow keys.
The capture is analyzed when it ends. The recorder is given 30 s to finalize after the editor is stopped.

### Limits

- **Software rendering.** Xvfb draws with llvmpipe, even on a machine with a GPU (Xephyr with glamor does too). Frames are
  slower than on a real display, and frame cost dominates the numbers. `--human` measures a real display.
- **XTEST skips the kernel.** The X server stamps input when the driver script sends it, so the leg from a device through
  evdev to the server is not measured. The X time stamp has 1 ms resolution.
- **The machine's load shows.** The runs below were made at load average 5 to 9 with other jobs running.

### Findings (2026-10-26, Xvfb, software GL, busy machine; 45 s of input, 30 sweeps and 33 key actions)

| Run | HANDLER median / p99 | ONSET median / p90 | MOVING median / p90 / p99 | KEYS median / p99 | FRAMES median / p99 |
|---|---|---|---|---|---|
| normal, run 1 | 1.7 / 14.7 ms | 1.7 / 16.9 ms | 17.1 / 35.4 / 41.7 ms | 1.7 / 25.1 ms | 13.6 / 22.6 ms |
| normal, run 2 | 1.9 / 16.6 ms | 1.7 / 16.5 ms | 17.1 / 34.5 / 42.4 ms | 1.7 / 14.3 ms | 13.4 / 20.6 ms |
| live | 1.8 / 16.1 ms | 1.7 / 2.2 ms | 16.9 / 33.3 / 39.9 ms | 1.9 / 20.4 ms | 13.6 / 20.9 ms |

- **Live mode matches normal mode** here. The Windows finding that live onsets are worse does not show on Linux.
- **Handlers and keys are prompt**, and so is the first move after a pause (ONSET). The slow case is continuous movement.
- **A move reaches NativeKit's handler in about 1.7 ms, and is polled about 15 ms later.** In 80% of the time slow inputs
  spent, the UI thread was inside `nk.frame` (almost none in GC, and 5% waiting). With input at 1 kHz and frames about
  14 ms long, the oldest unpolled move is about a frame old when the application polls. `nk_poll_event` pumps the platform
  first, and a pump can draw a frame, so a move already queued can also wait behind a frame it does not need.
- **SCREEN, input to a submitted frame** (the OS stamp to the end of the first `nk.frame` that starts after the poll; what
  the display does with the frame is not measured): moves median 31 to 33 ms and p90 46 to 50 ms, keys median 15.6 to
  16.2 ms. A move waits about a frame to be polled and then a frame to be drawn.
- **Candidate, not adopted:** handing over a queued event before pumping again (at most 16 polls in a row) left MOVING and
  SCREEN medians unchanged (18 and 33 ms), cut the move p90 from about 34 to 23 ms (polled) and from 50 to 40 ms (SCREEN)
  in two runs each, and made keys about 2 ms slower (SCREEN median 15.6 to 17.4 ms). It removes moves that waited through
  two frames but does not shorten the typical one, and it changes when frames draw relative to input, so it stays out.
- **What a frame costs** (1 kHz on-CPU profile of the same runs, share of all on-CPU samples after the fixes below):
  - 37% is llvmpipe and LLVM, the software rasterizer, which a GPU would not spend.
  - 26% is `UiContext.submitInternal`: building the widget tree 13% (`withScopeUnder`, a rebuild on every submit), native
    layout 7% (`LayoutSession.submit`), and the tree walks 7% together (`RenderNode.walk` from `submitInternal`, from
    `UiStyleInvalidationMetrics.compare`, which decides whether native layout can be reused, and from `render`).
  - Two fixes came out of the first profile:
    - GTK resolved `glGetIntegerv` with `dlsym(RTLD_DEFAULT)` on every frame-target query, several times a frame: 4.7% of
      on-CPU time, now none (NativeKit, "Resolve glGetIntegerv once per surface").
    - `BuildContext.pruneKeyCaches` walked every cached key path, hashing strings, after each UI submit: 3.9% of on-CPU
      time, now none. It runs when the mounted nodes or the cached ids change; the empty scopes a build creates and drops
      (about six a frame) wait until 256 have collected.
  - Their latency effect is below this machine's run-to-run noise of about a millisecond. They are fixed costs off every
    frame, so they matter more once a GPU makes frames shorter.
  - Still open: the tree build is the largest Haxe-side cost and is the retained-subtree design itself; the five or so
    separate walks of the node tree in `submitInternal` could be fused.
- In the probe app under Xvfb every mouse move reaches GTK's handler twice (80 handler events for 40 moves). The editor
  shows about two handler events per polled move too, with merging. Whether real hardware does it is unchecked.

### Resizing (2026-10-26, Xvfb, software GL, busy machine; 33 drags, 2208 configure requests at 125 per second)

| | |
|---|---|
| resizes the application polled | 2209, one per request: they are not merged here |
| frames during drags | 664, about 30 a second against a 60 Hz budget; time between frame starts median 34 ms, p90 51 ms |
| frame cost during drags | median 18.0, p90 26.3, p99 35.7 ms (ordinary frames: median 13.1); 58% over 16.7 ms, none over 50 ms |
| polled resize to a submitted frame | median 29, p90 40, p99 51 ms |

- The editor keeps up with the stream in the sense that every resize is taken and drawn within about two frames, but it
  draws at about half the budget. A resize needs a full native layout (nothing can be reused when the size changes), and
  the CPU profile of the drags is that of ordinary frames (building the tree 12%, native layout 5%, style comparison 4%)
  plus buffer churn: `memset`, `memmove` and `malloc` are 20% of samples, almost all inside llvmpipe resizing its render
  targets and GDK copying the result. A GPU would not pay that, so a real display is needed to say how much is left.
- Two long frames occur in every run and are not resizes: one of 260 to 300 ms before the first input (the first frame of
  the editor), and one of about 150 ms that came 16 s into the input phase in both normal runs. The second was not
  diagnosed.
