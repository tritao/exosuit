# Scripted selection-drag benchmark

Run from the repository root (Python 3 and the bootstrapped native Haxeon toolchain required):

```sh
python3 scripts/benchmark-selection-drag.py --output /tmp/selection-drag-1
```

For Linux CI without a desktop:

```sh
xvfb-run -a python3 scripts/benchmark-selection-drag.py --output /tmp/selection-drag-1
```

Use a new output directory for every run. `--skip-build` skips the explicit build step; the CLI may still rebuild stale inputs. The Python runner and managed input driver use no xdotool, AppleScript, or Windows input APIs. Windows and macOS use the same script with a platform-appropriate output path and a graphical session. Only Linux has been verified headlessly with Xvfb; this does not introduce a displayless renderer for other platforms.

The deterministic UTF-8 fixture has 5,000 numbered lines (about 430 KB). A fresh settings directory keeps the 1280 × 840 window, default font/zoom and layout consistent. The scenario scrolls to the middle, holds the primary button, and makes three down/up sweeps. Each edge has a stationary hold, exercising animation-driven selection scrolling. Checkpoints assert that scrolling occurs during every hold, the anchor remains fixed, the final selection spans lines, and all scripted events arrive. Failed validation returns exit code 1 while retaining `result.json` and the full trace. Use `--analyze-only --output <existing-directory>` to recompute the report without replaying input. The file contents are not edited. Workspace services are disabled for this isolated editor workload.

Artifacts include `scenario.json`, `events.jsonl` with selection/scroll checkpoints, capture diagnostics, the full frame timeline, and `result.json`. Results report p50/p95/p99/max for scheduled-input-to-completed-frame latency, dispatch, active-frame duration and frame gaps. Latency retains original deadlines if input falls behind. It excludes OS input delivery, compositor/monitor scanout, and cannot establish physical mouse-to-photon latency. Frame-gap measurements include the normal host scheduling interval. Compare repeated runs on the same hardware, renderer and build; software-rendered Xvfb timings are not interchangeable with native GPU desktop timings.

## Reusing the mechanism

Pass `--input-script=/path/scenario.json` to the graphical app alongside `--capture-dir`, `--capture-seconds` and `--record-path`. The version-1 JSON format is:

```json
{"version":1,"events":[
  {"at":1.0,"kind":"move","x":550,"y":440},
  {"at":1.1,"kind":"down","x":550,"y":440},
  {"at":1.2,"kind":"move","x":550,"y":850},
  {"at":3.0,"kind":"up","x":550,"y":850},
  {"at":3.1,"kind":"checkpoint","label":"released"}
]}
```

`at` is seconds after the first content-ready frame. Coordinates use window logical pixels, including coordinates outside the viewport during capture. `down`/`up` use the primary button without modifiers. `scroll` accepts `dx` and `dy` in logical pixels. Events must have finite, nonnegative, ordered times. Overdue events are drained in order before the next frame through `NativeKitEvents.dispatch`, sharing the real managed input adapter and normal frame scheduling. Checkpoints write application diagnostics without generating input. Timed capture waits for the script and its last input frame to finish; the runner checks completion. This initial format covers pointer/scroll scenarios, not keyboard or text replay.

## Initial Linux measurement

The 2026-10-08 Xvfb run reproduced the responsiveness problem. Across 33 frames completing drag input, scheduled-input latency had a 52 ms median, 3.87 s p95 and 5.76 s maximum. The full timeline counted all 274 input events, the anchor remained fixed and selection spanned multiple lines. Five of six stationary edge holds failed to make the required 100-pixel scrolling progress. The benchmark therefore exited with status 1, identifying a workload failure rather than claiming a passing performance baseline. Two preceding runs also reproduced multi-second stalls. These measurements are specific to this software-rendered Linux environment; they do not establish the cause or other platforms' performance.

## Latency fixes and verification

The follow-up profile attributed the long pauses to GC, with a 6.43-second frame including a 6.35-second collection. Most allocation came from platform text-input selection geometry. The fix clips that geometry to the actual ancestor viewport, skips it on unsupported platforms, and caches canonical grapheme rectangles (at most 8,192 per shaped layout, invalidated on text, width or typography changes). Visual-affinity endpoints retain their separate calculation.

Native sampling then identified linear GC-root removal in HashLink as the remaining pause bottleneck. Root addresses now have a hash index while the original dense root/owner arrays and highest-index duplicate-removal semantics remain intact. This change lives in `haxeon/vendor/hashlink/src/gc.c`; **rebuild the runtime as well as the graphical app** when reproducing it. On the tested Linux checkout:

```sh
(cd haxeon && ./scripts/build-native.sh)
xvfb-run -a python3 scripts/benchmark-selection-drag.py --output /tmp/selection-drag-fixed
```

Two runs with the final runtime and geometry fixes passed all scenario checks:

| Metric | Initial run | Fixed runs |
| --- | ---: | ---: |
| Input latency p95 | 3,874 ms | 72–93 ms |
| Maximum input latency | 5,759 ms | 105–113 ms |
| Frame time p95 | 3,795 ms | 43–49 ms |
| Maximum GC pause | 6,354 ms (profile run) | 29–40 ms |
| Stationary edge holds making progress | 1/6 | 6/6 |

The software-rendered test still exceeds a 16.7 ms frame budget. These results establish removal of the multi-second pauses, not a claim of 60 FPS on every platform. The full UI framework suite passed before subsequent concurrent theme changes. The latest full-suite run stops at `theme token aliases/default dimensions`; the focused selection suite (`NKUI_SELECTION_TEST_ONLY=1`) passes, including warmed-cache comparisons against fresh layouts for bidi/Unicode selections, reversed endpoints, visual affinity, width/font changes, replacement and edits. Runtime tests passed for 32,768 shuffled roots, root survival through GC, ownership, duplicate registrations, allocation paths, empty-page handling and mark claims.

Reports now include the runtime hash, prepare/submit/render phase timings, allocation statistics and GC pause counters. The root index uses the existing runtime lock and retains separate registrations of the same root address. Windows/macOS builds and performance remain unverified.

The GC root-index regression test is wired into `haxeon/scripts/test.sh` and can also be run directly with `bash haxeon/tests/integration/test-gc-root-index.sh`.

## Selection painting viewport follow-up

The next profile found that highlight painting still requested rectangles for the entire selected range, even though platform text-input geometry was already bounded. `TextEditorLayout.selectionRects` now accepts optional vertical bounds, binary-searches the first intersecting layout chunk, stops after the viewport, and returns only intersecting rectangles. `TextField` supplies its resolved ancestor viewport for both primary and additional selections. Existing callers that need full-document geometry retain the default unbounded behavior. Shaped visual-run selection bounds remain responsible for highlight geometry; no new cache is needed for this path.

A fresh baseline and two runs of the same changed bytecode on Linux/Xvfb gave:

| Metric | Fresh baseline | Viewport painting (two runs) |
| --- | ---: | ---: |
| Input latency p95 | 66.9 ms | 46.2–49.1 ms |
| Frame time p95 | 36.0 ms | 24.2–26.5 ms |
| Median allocation per active frame | 3.47 MB | 2.17–2.25 MB |
| Maximum GC pause | 22.8 ms | 9.6–10.4 ms |
| Scenario checks | Pass | Pass in both runs |

Artifacts: `/tmp/exosuit-selection-next-baseline/result.json`, `/tmp/exosuit-selection-paint-clipped-2/result.json`, and `/tmp/exosuit-selection-paint-clipped-3/result.json`. These comparisons use a fresh baseline because earlier measurements involved a different application build and timing conditions. Both changed runs have the same bytecode and runtime hashes. The focused framework suite passes, including a new comparison of viewport rectangles against filtered full-selection rectangles across multiple layout chunks, wrapped Unicode/bidi text, reversed selections, and off-document bounds. Native rendering and application submission still consume much of the frame budget; these results do not establish consistent 60 FPS.

An existing incremental compiler session failed to process a `#if` while rebuilding the changed `TextField`. The successful benchmark build used `HAXEON_COMPILER_SERVER=0` to perform one-shot compilation; no compiler changes were made for this follow-up.

## Gutter retention follow-up

CPU sampling of the viewport-clipped build still showed rendering dominating frame time (native rendering p95 17.0 ms, application submission p95 9.2 ms). The sample is retained in `/tmp/exosuit-selection-next-perf.data`; the UI process was PID 2278872. Samples include software-renderer worker threads and should not be treated as a native-GPU profile.

Inspection found that gutter labels were assigned by position relative to the first visible line. A one-line scroll therefore changed the text of every label. The bounded label pool now assigns slots by absolute line number modulo the pool size, retaining overlapping labels and reshaping only newly exposed labels while capacity is stable. Capacity still grows to the largest visible line count; growing it can remap existing labels. Font-size, digit-width and editor-geometry invalidation remain in place.

This cleanup did **not** establish a material latency improvement. The profiled baseline had 46.9 ms p95 input latency and 24.9 ms p95 frame time. Two passing changed runs measured 46.0/46.4 ms input p95 and 26.2/24.5 ms frame p95, with similar allocations. Reports are `/tmp/exosuit-selection-render-baseline/result.json`, `/tmp/exosuit-selection-gutter-1/result.json`, and `/tmp/exosuit-selection-gutter-3/result.json`. Another passing run (`gutter-2`) measured 455 ms p95 input latency while a test compiler was running; it is retained as a contention-affected result and excluded from the change comparison. A dedicated performance machine is needed for tighter comparisons.

The gutter pixel regression passed after scrolling and an edit, including alignment around a wrapped paragraph and blank lines. Its scroll distance was reduced from 80 to 20 pixels so both sides of the wrapped paragraph remain visible in the current viewport; the original distance scrolled the preceding lines away and failed the fixture's wrapping-coverage assertion. Artifacts are in `/tmp/exosuit-gutter-check-2`. No full application suite was run for this small change.

## Rejected selection-path batching experiment

The next experiment combined each selection's disjoint highlight rectangles into one multi-contour path and one paint. Independent selections remained separate to preserve overlap compositing. A before/after `selection-clipped` capture was pixel-identical (`/tmp/exosuit-selection-batch-pixels`), and drag checks passed, but end-to-end performance did not improve:

| Build | Input p95 | Frame p95 |
| --- | ---: | ---: |
| Original (`gutter-3`) | 46.4 ms | 24.5 ms |
| Batched, repeat (`batched-2`) | 56.6 ms | 30.5 ms |
| Original restored (`unbatched-confirm`) | 50.5 ms | 28.8 ms |

These runs show timing variability and no evidence for keeping batching. The first batched run overlapped a test build and is not used for the comparison. The experimental `Canvas.fillRects` method and selection-paint changes were removed. The restored bytecode hash matches `gutter-3`, and all restored-run scenario checks pass. Reports are under `/tmp/exosuit-selection-<run>/result.json`.

Further inspection identified another candidate: the native prepared-path cache currently clears all entries when it reaches 256 entries (`prepare_cached_path` in `packages/ui/src/api.cpp`). Frequently created highlight paths can therefore displace reusable paths. A bounded eviction policy that retains frequently used geometry is a candidate for a separately measured change; it has not been implemented or established as the latency cause by this experiment.

## Bounded prepared-path eviction

The prepared-path cache now uses a constant-time LRU list alongside its existing hash map. Hits move an entry to the front; a successful preparation at the 256-entry limit evicts only the entry at the back. Retained-byte accounting subtracts the evicted geometry. Explicit renderer-cache resets still clear both structures. Frame resources keep their shared ownership of prepared geometry, so eviction does not invalidate geometry already referenced by a frame.

`packages/ui/tests/path_cache_retention.cpp` renders one hot path alongside 300 unique temporary paths. It asserts one hit and one miss per iteration after warmup, and stable retained geometry bytes once the cache fills with these equal-sized paths. The test passes with the final implementation and fails with the previous native library at iteration 256. It is registered as `nativekit_ui_path_cache_retention` under the existing CMake graphics-test/Xvfb setup. The Linux regression executable was also compiled and run directly against both libraries.

Both final drag runs passed every scenario check:

| Final run | Input latency p95 | Frame time p95 | Path preparations per rendered frame |
| --- | ---: | ---: | ---: |
| `lru-final-1` | 61.3 ms | 31.6 ms | 16.02 |
| `lru-final-2` | 49.9 ms | 30.0 ms | 16.58 |

The earlier full-reset run (`unbatched-confirm`) measured 50.5 ms input p95, 28.8 ms frame p95, and 17.58 preparations per frame. Concurrent application edits changed bytecode between that run and the final runs, so these are not a fully controlled attribution of latency to cache eviction. The two final runs share the same bytecode hash. There is no confirmed end-to-end latency improvement; the regression establishes preservation of hot entries and bounded cache occupancy. Reports are `/tmp/exosuit-selection-lru-final-{1,2}/result.json`. The tested final native UI library SHA-256 is `6d6fca2529a745b498c7d37d274df37f6715acb113767ed31d9f24d5d0b8cf94`.

An initial implementation scanned the bounded map to find its oldest entry; the final implementation replaces that scan with list operations. No full UI suite or Windows/macOS run was performed for this change.

## Adaptive text-row raster caching

Smooth scrolling changes the subpixel placement of text. Previously each visible row could create a fresh cached render target every frame, even when its new fractional placement would never recur. The layout-session renderer now draws glyphs directly when a text resource's subpixel phase or linear transform changes. Once the phase repeats, row-texture caching resumes. Whole-pixel movement preserves the phase and remains eligible for reuse. Resource-slot release resets this history.

Pixel comparisons exposed a related rounding issue at 2× scale: `std::round` rounds negative half-pixels away from zero, so translating glyphs into row-local coordinates could change their position by a pixel. Origin and quad snapping now use `floor(value + 0.5)`, preserving rounding under whole-pixel translations. Direct and cached output matches exactly in the new regression at 1×, 1.5× and 2× scale.

The benchmark now accepts `--app-binary <frozen.hl>` to launch bytecode directly without a CLI rebuild, and `--native-library-dir <directory>` to select a saved set of native UI libraries. Reports also include the native UI library hash. This allows native-only comparisons with identical application bytecode despite concurrent application edits:

```sh
xvfb-run -a python3 scripts/benchmark-selection-drag.py \
  --app-binary /tmp/exosuit-row-raster-baseline/main.hl \
  --native-library-dir /tmp/exosuit-row-raster-baseline/native \
  --output /tmp/selection-native-baseline
```

Omit `--native-library-dir` to use the workspace's built native UI libraries. The frozen-bytecode launch path uses the bootstrapped HashLink runtime and platform library-path variable; this new launch mode has been verified on Linux only.

Two baseline and two final Linux/Xvfb runs used the same frozen application and runtime:

| Metric | Previous renderer | Adaptive renderer |
| --- | ---: | ---: |
| Median active-frame time | 18.3–20.5 ms | 11.0–12.4 ms |
| Active-frame time p95 | 26.5–32.4 ms | 18.5–21.5 ms |
| Scheduled-input latency p95 | 47.8–57.6 ms | 44.2–48.0 ms |
| Raster-cache misses per rendered frame | 42.9–44.2 | 0.65–0.80 |
| Scenario checks | Both pass | Both pass |

Reports are `/tmp/exosuit-row-cache-{before,before-2,final-2,final-3}/result.json`. All four share bytecode hash `a6e7563f53fe397f9f08aba0e07176de19210626b79c0d4be1b460487caff6b2`; the previous and final native UI hashes are `6d6fca2529a745b498c7d37d274df37f6715acb113767ed31d9f24d5d0b8cf94` and `4a816266b148c6152b600b9377763802768e823afd7292299fc8a96fbca480b9`. Timing still varies on the shared machine. The frame-time improvement is clearer than the smaller input-latency change, and p95 frames still exceed the 16.7 ms budget.

The new CTest case `nativekit_ui_moving_rows` runs the existing session-render executable with `NKUI_MOVING_ROWS_TEST_ONLY=1`. It checks that fractional movement avoids new raster-cache misses, stationary text populates and reuses the cache, and cached pixels match direct output at all three tested scales. It passes with the final library and fails against the saved previous library (exit 61). The prepared-path retention test also passes with the final library.

### Session-render regression cleanup

The full native session-render test now passes. Investigation of its pre-existing failure found two incorrect test assumptions, rather than discarded text-row rasters:

- Inserting a newline creates an empty row, which has no glyph texture. The expected cache-miss increase is one (the enclosing custom-node raster), while the moved text rows still hit their cache. Deleting the newline still expects two misses. The existing pixel checks for moved and restored rows remain unchanged and pass.
- The zoom-spacing check measured a clipped glyph band's edge as if it were a complete row. It now scans framebuffer pixels from the top and compares only complete bands inside the fixture's custom-node bounds. It still requires at least two complete rows and the expected scaled 24-pixel spacing.

Applying only these test corrections to the original session-render source also passes against the saved previous native library (`/tmp/exosuit-session-corrected-baseline`). This confirms the corrections independently of adaptive caching. The current complete executable (`/tmp/exosuit-row-cache-smoke`) passes all existing assertions and the adaptive-cache regression.

The adaptive regression additionally checks that a two-layout-pixel translation (whole device pixels at 1×, 1.5× and 2×) increases cache hits without new misses. Fractional movement, stationary population, exact direct/cached pixel equality, and whole-pixel reuse are now covered together. These changes affect tests and documentation only; the native renderer and measured benchmark binaries are unchanged. Windows/macOS execution and the full framework suite remain unverified.


## Reuse native selection-query geometry

The next CPU profile (`/tmp/exosuit-selection-next-perf.data`) highlighted `skb_layout_iterate_text_range_bounds_with_offset`. The public selection-buffer API computes the same geometry once for buffer sizing and again for filling. Repeated painting also asks for unchanged selections in fully selected paragraph chunks.

`TextEngine::selection_rects` now retains its last normalized query, keyed by active layout ID, native layout generation, both endpoint offsets, and both affinities. A native generation change invalidates reuse after incremental ASCII edits; new layouts invalidate it after Unicode edits, wrapping or style changes. Returned vectors remain independent values. Retention is limited to 256 rectangles (4 KiB of rectangle data per text engine); larger results bypass retention and clear the cached query. This is separate from the existing grapheme cache used for IME geometry.

Two alternating baseline/optimized Linux/Xvfb comparisons used identical frozen application bytecode and runtime. No application rebuild or test compilation overlapped these timed runs:

| Metric | Previous renderer | Selection-query cache |
| --- | ---: | ---: |
| Median active-frame time | 10.6–10.7 ms | 8.8–9.0 ms |
| Active-frame time p95 | 17.6–17.8 ms | 14.8–15.3 ms |
| Median application submission | 6.3 ms | 3.8–4.2 ms |
| Median native layout/submission phase | 4.4 ms | 2.3–2.5 ms |
| Scheduled-input latency p95 | 43.0–45.1 ms | 43.8–43.9 ms |
| Scenario checks | Both pass | Both pass |

Frame time improves consistently in these runs; input latency does not show a clear improvement. The input metric also includes the scheduling delay before a frame begins. Results are `/tmp/exosuit-selection-query-{before,after}-{1,2}/result.json`. Baseline native libraries are saved under `/tmp/exosuit-selection-query-baseline/native`. Application bytecode remains `a6e7563f53fe397f9f08aba0e07176de19210626b79c0d4be1b460487caff6b2`; baseline and optimized native UI hashes are `4a816266b148c6152b600b9377763802768e823afd7292299fc8a96fbca480b9` and `81416e63f02240b49c5f646316232ef9459af5211526cbb266124cff836d181f`.

The complete native text-engine test passes, including new fresh-layout comparisons after an incremental ASCII edit, Unicode fallback, width and font-size changes, reversed and affinity-specific endpoints, mixed-direction text, mutation of a returned copy, and a large uncached selection. The complete native session-render regression also passes with this library. Tests were compiled/run directly against the graphical native build; no full framework suite or Windows/macOS run was performed for this change.

A later verification rebuild included concurrent edits to `clay_layout_backend.cpp` and produced native UI hash `4fc44bed3326018f9c2d5b7097cbb4f7f32d536385862248af31a2a891940f99`. The full session-render test passes on that combined build too, but the timings above belong specifically to the recorded optimized hash `81416e…`; the combined build was not benchmarked in this comparison. Concurrent layout and application edits are outside this selection-query change.


## GTK event waiting and input latency

Input timing decomposition showed approximately 10.2 ms between the latest managed frame request and the render callback. NativeKit previously slept on its own condition variable between nonblocking GTK pumps, quantizing OS input and frame-clock handling to a fixed 10 ms polling interval.

GTK waits now block in the GLib main context. A sequence-aware source checks queued events and explicit wakeups before and after polling, and core event publication/wake calls wake that context. A timeout source preserves the existing bounded poll interval for services such as joystick polling. Completing a GTK surface render wakes the host so it can process managed input and animation requests immediately. Other platform backends retain their existing wait implementation. This change does not shorten the polling interval or introduce busy polling.

A rejected host-level experiment woke the event loop when a new frame became requested. It did not improve input latency and was removed. The controlled native comparison uses its frozen experimental bytecode with `NKUI_EXPERIMENT_FRAME_WAKE=0` for both baseline and candidate, so the host wake change is disabled throughout. No experimental switch remains in production source.

| Metric | Previous native wait | GTK main-context wait |
| --- | ---: | ---: |
| Scheduled-input latency median | 31.9 ms | 23.0–24.7 ms |
| Scheduled-input latency p95 | 42.6–43.4 ms | 31.9–32.8 ms |
| Scheduled input to frame-start p95 | 31.3–31.6 ms | 19.9–21.1 ms |
| Latest frame request to frame-start median | 10.2 ms | 3.2–4.1 ms |
| Latest frame request to frame-start p95 | 10.2–10.3 ms | 7.2 ms |
| Active-frame time p95 | 16.1–16.5 ms | 14.3–15.6 ms |
| Scenario checks | Both pass | Both pass |

Baseline reports are `/tmp/exosuit-frame-wake-before-2/result.json` and `/tmp/exosuit-native-wait-before-3/result.json`; candidate reports are `/tmp/exosuit-native-wait-after-{2,3}/result.json`. All share bytecode hash `30da4c62ee4ace3ebbaf565fb52f0b3c45bb0d3826721d6304ac3a8ced364cb5`, runtime `c665602d27c1061fcad2e7367acf8142b7ef3d5470e771689894723a53a30236`, and native UI `4fc44bed3326018f9c2d5b7097cbb4f7f32d536385862248af31a2a891940f99`. NativeKit core hashes are `20c3c74400f296e51bb876406dffdbd9716f1c5c1012d3b52433b8a40108d8d5` before and `5108609b1efc9b230c7900a64470ffcb8402f130c4029232becd3c6854cced93` after. Saved binaries/libraries are under `/tmp/exosuit-frame-wake-experiment` and `/tmp/exosuit-native-wait-candidate/native`.

The first candidate run (`native-wait-after-1`) overlapped unrelated compiler activity and showed large frame stalls (77.9 ms frame p95 and 213.6 ms input p95). It is retained in the artifacts but excluded from the table; the subsequent two candidate runs agree. This remains a shared-machine software-rendered measurement, excluding OS input delivery and scanout.

The benchmark now reports scheduled-input-to-frame-start and latest-frame-request-to-start separately, and records the NativeKit core library hash. The latest-request metric is not the age of the earliest coalesced request.

Native time/wakeup tests and the full native session-render regression pass. A new CTest regression, `gtk_event_wait`, checks that unrelated GLib timers do not prematurely finish a wait, explicit wakeups are preserved, and a completed frame returns control before a watchdog fires. The regression passes against the candidate and fails against the saved old native library at the frame/watchdog assertion. These tests were compiled and run directly against the graphical native build. Windows/macOS execution remains unverified; this optimization is specific to the GTK backend.

A final application rebuild with the host experiment removed passes every scenario check (`/tmp/exosuit-native-wait-final/result.json`). That verification uses current application sources, including concurrent edits, and is separate from the controlled frozen-bytecode comparison above.
