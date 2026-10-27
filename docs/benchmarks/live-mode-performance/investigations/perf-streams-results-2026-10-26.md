# Perf streams: results (2026-10-26)

Fixes for the problem matrix in `human-live-capture-2026-10-26.md`, measured with the perf harness
(`docs/benchmarks/perf-harness/`, fixed SendInput scenario, phases aligned on injected keys and clicks).
Baselines: `runs/base-baseline*`. Final: `runs/main-final2-*`. Same machine, same scenario.

## Before / after

| Metric (sampling unless noted) | Before | After |
|---|---|---|
| Frame p50 / p99 | 9.1 / ~25 ms | 4.6 / 8.2 ms |
| `ui.render` p50 | 4.2 ms | 0.8 ms |
| Move input→frame p50 / p99 / max (in phases) | 5.9 / 86 / 315 ms | 5.0 / 10.9 / 13.6 ms |
| Key input→frame p50 / p99 | 15.3 / 25.5 ms | 6.9 / 15.4 ms |
| Click input→frame p90 | 86.6 ms | 11.9 ms |
| Input age (OS→NativeKit) p99 | 75.7 ms | 2.3 ms |
| Inputs over 50 ms | up to 8% | 0% |
| Idle frames/s (start / after scroll / end) | 5.6 / 38 / 22 | 2.6 / 2.0 / 0.0 |
| Layout passes per rebuilt frame (instrument) | ~2.5 | ~1 |
| Render plans reused (instrument) | 0 | 452 of 884 frames |
| GPU timing readback | 2.2 ms/frame | ~0 |
| Background poll + SCM markers | 2.7 s per run | ~0.25 s |
| Long-line file (4102-char lines): frame p50 / p99 | 170 / 197 ms | 4.7 / 8.2 ms |
| Long-line file: key input→frame p50 | 1610 ms | 6.8 ms |

Idle after scrolling (2.0/s) is the caret blink. Idle-start includes the editor's first settling frames.

## What changed, by problem

- #1, #2, #11 input starvation and waits (NativeKit Windows pump): input is drained before posted messages (with sent
  messages), typed characters follow their keys (system keys keep their own place), `nk_poll_event` returns queued
  events before pumping again (at most 64 polls between pumps), a frame message waits at most one pump for an unpolled
  event, and the idle wait is `MsgWaitForMultipleObjectsEx` on a wake event plus window input.
- #3 animations: delayed animations (scrollbar fade countdown) sleep until their deadline instead of drawing.
- #4 layout feedback loop: tooltips, minimap and scrollbar seed rebuilt placements from the last layout.
- #5 glyph republishing: row glyph snapshots are retained between frames; per-row colour ranges are a slice.
- #6 render plan: reused while its inputs are unchanged; retained custom paint keeps rectangle resources so identical
  repaints record identical commands; miss counters (`ui.plan.*`) explain every recompile.
- #7 GPU timing: the render thread publishes the frame time; the poll no longer waits for the frame in flight.
- #8 long lines: only the visible horizontal window of lines over 1024 codepoints is published.
- #9 idle redraws: the root cause was the desktop host redrawing for every NativeKit event it did not handle,
  including transport and PTY I/O; a live workspace connection (agent reads every 0.2 s) kept an idle editor at
  5–10 frames/s. The host now skips transport, PTY, task and HTTP events; code that consumes them requests frames on
  change (terminal rows, catalog/agent revisions, formatting and server edits, external reloads). Agent revisions
  change only when content changes.
- #10 SCM markers: per-document repository/path caches, rescans keyed on snapshot identity.

## Harness lessons

- Phase alignment on the first injected move was wrong whenever the editor missed the first moves; idle phases then
  counted real input. `metrics.py` now aligns on every injected key and click and prints how many matched.
- Instrumented captures drop calls under ~1 µs, so short functions such as `requestFrame` can vanish from a trace;
  when a requester is missing, log it at the source instead.

## Open

- Opening a 482 KB long-line file: one ~0.4–0.6 s submit.
- Long-line file: one ~200 ms frame when scrolling crosses a 1024-unit glyph window chunk.
- One move with a 295 ms input→frame and a 250 ms input age in `main-final2-sampling`, outside the scenario phases
  (startup), not investigated.
- #12 big rebuilds: not started. The first frame takes 1.48 s (a 1.41 s whole-tree build), some clicks rebuild for
  35–40 ms and opening a tab takes 377 ms. The next candidate after these streams.
- #13 (profiler overhead) needs no fix: these results come from sampling captures, as it recommends.
- Pre-existing test failures (fail identically before the streams): language-controller-test (definition picker),
  scm-watch, NativeKit transport_contract / win_create_destroy / capability_conformance, nkui backend_smoke /
  session_render_smoke / path_cache_retention, FrameworkSmoke scaled click. win_file_watch is flaky on both.
