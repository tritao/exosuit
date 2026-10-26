# Input latency with real input

Measures how long the editor takes to react to real input: from the moment Windows receives a mouse move, button or
key, to the moment the editor takes it off its queue, and what the UI thread was doing meanwhile. Scripted benchmarks
(`../live-mode-performance/`) inject input into the app's own queue, so they cannot see this delay; these tools can.
Windows only for now.

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
