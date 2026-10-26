# Terminal rendering benchmark

Run from the repository root:

```sh
python3 scripts/benchmark-terminal-render.py
```

This builds an isolated native fixture and runs three passes in Xvfb with Mesa software rendering. Requires the normal graphical build dependencies, `xvfb-run`, `glxinfo`, and ImageMagick `import` (host screenshots). Use `--skip-build` after building, `--runs N` to change repetitions, `--output PATH` for a separate result set, or `--display` to use the current desktop. Software rendering remains enabled with `--display` unless `--hardware` is passed. Hardware rendering requires `--display`; the selected OpenGL device is recorded in the results.

The fixture uses the production `TerminalPane`, terminal emulator, ordered `TerminalSession` output, retained row caches, fonts, layout, and desktop rendering. A deterministic backend echoes typed characters and emits ANSI output without shell/PTY or RPC timing variability. It does not measure physical keyboard latency, remote transport, browser rendering, or GPU execution time.

Each pass renders seven scenarios at 1100 × 700 pixels. Each scenario lasts 140 frames; the first 20 frames are excluded from statistics:

- **idle:** unchanged screen with 500 lines of scrollback. These frames are deliberately requested to measure retained-frame cost, not idle CPU consumption.
- **typing:** one character per frame through terminal input encoding, backend echo, and session output; a new prompt every 60 characters.
- **progress:** one colored carriage-return progress line per frame.
- **scroll:** ten roughly 80-character log lines per frame, causing scrolling.
- **ansi-redraw:** every visible row rewritten with changing text and ANSI foreground colors.
- **unicode-redraw:** every visible row rewritten with Japanese, accented Latin, Greek, and arrow text.
- **scrollback:** scroll through the retained log history, changing the viewport each frame.

Output goes to `out/terminal-render-benchmark/` (ignored by Git). `results.json` records environment, revision, dirty working-tree state, per-run medians, combined median/p95/max, allocations, changed rows, and counts over the 16.67 ms frame budget. Each run retains the host frame timeline, fixture samples, screenshot, UI tree, and logs. `summary.md` is a compact table.

Frame cost includes preparation, terminal input/output processing, UI submission, native rendering/presentation calls, and the frame GC hook. Poll cost includes scenario generation/input encoding plus session polling and row refresh; paint cost is the host's context-render phase. Allocations count HashLink-managed allocations, not all native allocations. The fixture's instrumentation adds some overhead. Startup, stage transitions, and first-use shaping are excluded by the warmup; maximum timings remain available for detecting outliers. Frame intervals describe host pacing, whereas frame cost measures time spent inside the render callback. Do not interpret reciprocal frame cost as achieved FPS or software-rendering results as hardware GPU results.

The runner verifies frame alignment and count, echoed input byte count, and retained-row behavior (zero changed rows when idle, at most two for typing). It fails if the application exits unsuccessfully or diagnostics are incomplete. There is no machine-independent timing threshold.

## Baseline: 2026-10-26

Measured on an Intel Core i5-13600K with Mesa llvmpipe 25.2.8 / LLVM 20.1.2, isolated Xvfb, a 128 × 36 terminal grid, and the current dirty working tree. Three passes produced 360 measured frames per scenario (2,520 total), after excluding warmup. Build and all fixture checks passed.

| Scenario | Frame median | Frame p95 | Managed allocation/frame (median) |
|---|---:|---:|---:|
| Idle retained frame | 6.09 ms | 6.89 ms | 145 KiB |
| Typing / echo | 9.28 ms | 11.74 ms | 176 KiB |
| Progress line | 9.21 ms | 19.70 ms | 181 KiB |
| Scrolling logs | 25.74 ms | 34.27 ms | 1,193 KiB |
| ANSI full redraw | 28.27 ms | 36.19 ms | 2,087 KiB |
| Unicode full redraw | 28.20 ms | 37.89 ms | 1,777 KiB |
| Scrollback navigation | 25.84 ms | 32.24 ms | 1,215 KiB |

Every measured frame in scrolling, full redraw, and scrollback exceeded 16.67 ms. Typing exceeded it once in 360 frames; progress exceeded it 27 times. Idle changed zero row revisions; typing and progress changed one row at the median; scrolling changed 35 and full redraws/scrollback changed 36. The host context-render phase dominates these software-rendering timings (roughly 22.5–23.7 ms median for heavy scenarios), while polling/row refresh costs roughly 2.9–4.4 ms. Native rendering deserves profiling next; these measurements do not isolate shaping, rasterization, compositing, or presentation within that phase.

One progress frame in run 2 (frame 332) took **1,934 ms**, with 1,927 ms in application submission and no reported GC collection. Its cause remains unresolved; it is preserved in the raw timeline and maximum statistics. Other run maxima were 93.53 ms and 47.73 ms. Per-run heavy-scenario medians varied by several milliseconds, so use this as a baseline rather than a precise regression threshold. These are software-rendering measurements; hardware desktop and browser performance need separate measurements.

Raw results: `out/terminal-render-benchmark/results.json`; full frame data and screenshots are under `run-1/` through `run-3/` in that directory.

## Investigating stalls

Use Linux process sampling and additional polling phase timings:

```sh
python3 scripts/benchmark-terminal-render.py --diagnose --runs 5 --output out/terminal-stall-investigation
python3 scripts/benchmark-terminal-render.py --skip-build --diagnose --runs 1 --progress-repeats 1000 --output out/terminal-stall-stress
```

Every poll records elapsed wall time, monotonic milliseconds, main-thread CPU time, backend event dispatch, row-refresh remainder, and UI submission time. Dispatch measures the ordered backend-event application; refresh is the remainder of the production `pane.poll()` call, including reply handling. Phase boundaries add small measurement overhead. Monotonic milliseconds distinguish a wall-clock adjustment from a real delay; thread CPU distinguishes computation from time spent waiting or descheduled.

`--diagnose` additionally records `process-timeline.jsonl` every 20 ms and writes `stall-analysis.json` for frames over 50 ms plus the worst frame. It includes process fault counters, main-thread scheduler CPU/run-queue counters, and sampled kernel wait channels. Counter differences bracket the frame and may include neighboring work. Major faults can reflect file reads as well as swap-in, so their presence alone does not establish swapping as a cause.

`--progress-repeats N` runs N changing progress polls per progress frame, cycling through the same 140 texts, including the original stalled text at index 51. This intentionally increases per-frame work and allocations; its progress-frame results are a stress test and must not be compared with the baseline. Individual extra polls over 50 ms and the worst extra poll are retained as `stressSlowPolls` and `stressMaxPoll` in the application state and stall analysis. Ordinary measurements use N=1. Automatic GC remains governed by the host's normal frame-boundary policy.

### Stall follow-up: 2026-10-26

The original stalled progress frame (run 2, frame 332, tick 51) spent **1,926.81 ms inside polling/row refresh**, with **1,927.13 ms total application submission** and only **7.27 ms context rendering**. It changed one row, consumed 44 output bytes, and reported no GC collection. The preceding and following polls took 0.25 ms and 0.56 ms. The original capture lacks thread CPU, monotonic timing, and OS sampling, so it cannot establish why that poll was slow.

Five instrumented full reruns did **not reproduce** the stall. Their maximum progress poll times were 1.16, 0.69, 1.06, 0.68, and 0.53 ms (see the raw samples for exact values). Across all scenarios including warmup, the worst poll was 38.08 ms during the first Unicode redraw; the worst frame was 83.15 ms in native rendering. The process accumulated 13, 24, 7, 1, and 0 major faults in those runs; the worst frames had zero major faults in their sampling windows.

A further stress pass performed **140,000 progress polls** with the same production poll path. Its worst additional poll took **1.689 ms elapsed / 1.691 ms thread CPU / 2 ms at the monotonic clock's millisecond resolution**, with 0.018 ms in dispatch and 1.671 ms in refresh. No individual extra poll exceeded 50 ms. The process incurred no major faults over that stress run. A supplemental `perf` major-fault recording also contained no fault events.

The machine showed active swap-ins and about 35 GiB of occupied swap during this investigation, making environmental paging a plausible hypothesis. Neither paging, scheduling, lock contention, nor a clock adjustment is established as the cause of the original stall. No renderer fix was made on that evidence. Repeated content tests currently argue against a deterministic trigger in the progress text; the additional diagnostics are retained to distinguish those causes on a future recurrence.

Evidence is retained under `out/terminal-stall-investigation/` and `out/terminal-stall-stress/`. The original baseline artifacts remain under `out/terminal-render-benchmark/`.


## hlprof-live function profiling

```sh
python3 scripts/profile-terminal-render.py
```

The runner uses `haxeon run --profile=instrument,sampling`, which launches `hlprof-live` before application entry, and builds Haxe instrumentation separately from the ordinary build. Calls shorter than 10 microseconds are filtered. Recording uses Xvfb and software rendering, the default progress sequence, and disposable settings/state directories. The fixture names warmup/measured scenarios and polling/UI-submission phases with profiler spans.

Artifacts are in `out/terminal-hlprof/instrument/`: `profile.hlpc` is the raw recording, `profile.pftrace` is the Perfetto trace, `profile.json` is the JSON trace, `analysis.json` contains per-scenario inclusive function timings and sampled boundaries, and `summary.md` contains mean frame costs. `*-samples.txt` are the profiler's source-line reports for each elapsed scenario window. Reanalyze a recording with `python3 scripts/profile-terminal-render.py --analyze-only --output PATH`.

The analyzer verifies all seven scenarios have 120 measured frames and computes timings only inside those main-thread frames. Warmup, startup, and event waits outside the frames are excluded. The profiler's text reports cover continuous scenario windows, so they can also include pacing waits. Function durations are inclusive and overlap; instrumentation and sampling add overhead, and short-call filtering understates totals for very short functions. Compare profile timings separately from unprofiled benchmark medians.

The initial Linux recording primarily attributed opaque native execution to its nearest named Haxe boundary. A large `UiHostRuntime.render` sample count therefore does not imply that the Haxe method itself is CPU-heavy. The native CPU capture below separates the native rendering and driver calls that those boundaries did not resolve.

### Profile findings: 2026-10-26

The first mixed capture recorded 24,247 samples, zero unresolved frames in the profiler report, zero dropped records, and zero profiler-buffer stalls. There were 120 measured frames per scenario. The frame costs below are **profiled arithmetic means**, rather than the unprofiled medians above.

| Scenario | Frame | Render phase | Terminal poll | Text shaping (`setText`) | Foreground ranges (`setColorRanges`) |
|---|---:|---:|---:|---:|---:|
| Idle | 6.42 ms | 5.73 ms | 0.04 ms | 0.00 ms | 0.00 ms |
| Typing | 9.42 ms | 8.34 ms | 0.37 ms | 0.07 ms | <0.01 ms |
| Progress | 8.49 ms | 7.48 ms | 0.38 ms | 0.07 ms | 0.02 ms |
| Scrolling logs | 26.69 ms | 23.22 ms | 2.91 ms | 1.11 ms | <0.01 ms |
| ANSI redraw | 28.75 ms | 23.62 ms | 4.55 ms | 1.13 ms | 1.38 ms |
| Unicode redraw | 28.32 ms | 23.52 ms | 4.25 ms | 1.45 ms | 1.00 ms |
| Scrollback | 27.89 ms | 24.21 ms | 3.11 ms | 1.15 ms | <0.01 ms |

Rendering accounts for roughly 82–87% of heavy-frame duration. UI tree submission outside terminal polling is only about 0.44–0.50 ms per heavy frame. Copying/converting row cells takes roughly 0.78–0.85 ms per heavy frame. Foreground-range application is comparable to shaping in the colored redraw cases; coalescing contiguous foreground ranges is a specific candidate to measure. Scrolling row reuse could avoid both rebuilding and rerendering existing rows. The largest opportunity remains the opaque native render phase, which this Linux capture cannot subdivide. These findings support prioritizing native rendering and row reuse over broad Haxe UI-tree changes.

A second end-to-end capture using `scripts/profile-terminal-render.py --output out/terminal-hlprof/verify` confirmed the split: heavy-frame means were 25.15–27.91 ms, with 21.77–22.68 ms in rendering and 2.86–4.68 ms in polling. Both captures verified all 840 measured frames and had no profiler-buffer stalls. Measured main-thread frames contained 16,181 and 15,487 stack samples respectively; the first capture's 24,247 total samples also include startup, warmup, pacing waits, and other sampled work.

## Foreground color-run optimization: 2026-10-26

`TerminalPane` now combines adjacent colored cells with the same packed color and cursor color role before decoding them and constructing immutable `TextColorRange` values. Default-color gaps, wide/combining character codepoint offsets, and the unfocused cursor's swapped-color interpretation are preserved. This reduces both per-cell color decoding and the number of ranges converted/passed to the native layout. The renderer's background, shaping, and raster-cache paths are unchanged by this optimization.

Two ordinary benchmark passes per version are retained in `out/terminal-color-ranges-before/` and `out/terminal-color-ranges-after/`. Across those runs:

| Metric (median per frame) | Before | After |
|---|---:|---:|
| ANSI redraw managed allocations | 2,090 KiB | 1,291 KiB |
| Unicode redraw managed allocations | 1,780 KiB | 1,228 KiB |
| ANSI redraw polling | 4.03 ms | 3.50 ms |
| Unicode redraw polling | 4.17 ms | 3.86 ms |
| ANSI full frame | 27.05 ms | 29.47 ms |
| Unicode full frame | 26.75 ms | 29.14 ms |

Managed allocations fell by roughly **38% (ANSI)** and **31% (Unicode)**. The first post-change pass improved ANSI frame time from 27.16 to 24.45 ms and Unicode frame time from 28.91 to 24.55 ms relative to the first baseline pass. However, the second post-change pass had broad wall-time spikes, including scenarios with no colored text. The machine also recorded CPU/memory pressure during the investigation. The combined full-frame medians above regressed; these runs do **not** establish a stable end-to-end frame-time improvement. The allocation reduction is consistent across passes.

A follow-up `hlprof-live` capture is in `out/terminal-hlprof/color-runs-after/`. Recorded inclusive `TextLayout.setColorRanges` time dropped from 1.377 to 0.074 ms per ANSI frame and from 1.003 to 0.014 ms per Unicode frame. Calls below 10 microseconds are filtered in both captures, so these totals undercount short calls. Rendering in that capture was also affected by large outliers; its ANSI full-frame mean was 98.38 ms and its Unicode mean 34.15 ms. No profiler-buffer stalls were recorded. Native rendering remains the dominant unresolved cost.

Correctness was checked using the expanded terminal cursor smoke with ANSI, indexed and truecolor runs, default-color gaps, inverse video, and wide/combining Unicode content. Both themes' focus, blur, refocus, hidden-cursor, selection, and color fixtures passed. **All fourteen before/after screenshots were pixel-identical** under isolated Xvfb. Evidence is in `out/terminal-colors-isolated-before/`, `out/terminal-colors-isolated-after/`, and `out/terminal-colors-visual-comparison.json`.

To retain visual artifacts for a future comparison:

```sh
env -u DISPLAY LIBGL_ALWAYS_SOFTWARE=1 TERMINAL_CURSOR_ARTIFACTS="$PWD/out/terminal-colors-visual" python3 scripts/test-terminal-cursor-ui.py
```

## Direct retained-row drawing: 2026-10-26

Terminal rows now use `CachePolicy.None` for their custom paint plane. Their shaped text, glyph caching, and retained display lists are still reused. This removes the additional row-sized offscreen raster/composite layer that previously wrapped each row. No framework or native submodule source was changed for this optimization.

The fixture and runner accept `--row-cache raster|none|default` to compare policies without changing production code. Each override is fixed for an entire fresh application process. The default uses the policy in `TerminalPane`. For example:

```sh
python3 scripts/benchmark-terminal-render.py --runs 2 --row-cache raster --output out/terminal-raster
python3 scripts/benchmark-terminal-render.py --skip-build --runs 2 --row-cache none --output out/terminal-direct
# Use the current desktop's GPU rather than Xvfb/software rendering:
python3 scripts/benchmark-terminal-render.py --skip-build --display --hardware --runs 2 --row-cache none --output out/terminal-direct-gpu
```

The reported comparisons used **alternating raster/direct runs**, two unprofiled runs per policy, with 240 measured frames per scenario and policy. Software results exclude the initial raster pass captured with `perf`: that recording introduced overhead and lost 63 samples, so it is only exploratory native profiling evidence. The trace and reports remain in `out/terminal-raster-comparison/`. All reported policy comparisons below are unprofiled.

| Scenario | Software raster → direct median | GTX 1060 raster → direct median |
|---|---:|---:|
| Idle retained frame | 7.43 → 6.44 ms | 2.78 → 2.72 ms |
| Typing | 10.69 → 4.10 ms | 4.06 → 3.10 ms |
| Progress | 11.52 → 3.87 ms | 4.06 → 3.17 ms |
| Scrolling logs | 30.28 → 15.43 ms | 36.25 → 23.14 ms |
| ANSI redraw | 29.93 → 15.01 ms | 39.31 → 23.63 ms |
| Unicode redraw | 27.95 → 15.85 ms | 39.74 → 24.89 ms |
| Scrollback | 26.60 → 17.75 ms | 42.10 → 25.21 ms |

Direct row drawing reduced heavy-frame medians by **33–50% under software rendering** and **36–40% on the GTX 1060 3GB / NVIDIA 550.144.03**. Software typing/progress improved by 62–66%. The hardware result was consistent in both alternating pairs; individual timings still varied with machine load. Hardware rows continued to exceed 16.67 ms in most heavy frames, so this is not a claim of consistent 60 Hz rendering. Hardware timing includes driver/presentation behavior on the physical X11 desktop and should not be compared directly to Xvfb as an isolated GPU speed comparison.

A separate build and benchmark with the new production default completed successfully, without an override. The terminal smoke checks passed using the default policy under both isolated software rendering and the NVIDIA desktop. All fourteen software reference images (both themes, focused/unfocused/refocused/hidden cursors, window blur, selection, and mixed colors/Unicode) were **pixel-identical** between raster and direct drawing. The retained-row checks also passed: idle changed no row revisions and typing changed at most two.

Raw comparison data and compact reports: `out/terminal-raster-comparison/comparison.json` / `comparison.md` and `out/terminal-raster-hardware/comparison.json` / `comparison.md`. Default-policy validation: `out/terminal-direct-default/`. Software visual references: `out/terminal-raster-visual/` and `out/terminal-direct-default-visual/`, with `out/terminal-raster-comparison/pixel-comparison.json`. GPU default-policy visual checks: `out/terminal-direct-hardware-visual/`. A later optional GPU raster-reference recapture failed its focus assertion when the physical desktop sent an extra focus-loss event in the refocus case; it did not produce a complete GPU reference set and is not used for pixel-equivalence claims.

## Bounded row reuse: 2026-10-26

The renderer now keeps a viewport-sized pool of row records containing a text layout, rendered text, background fills, and snapshot metadata. Moving a line within the viewport reuses its record when **both its stable line ID and rendered-content hash match**. The hash includes text, cell widths, and packed colors. It is exposed through the additive `terminalkit_row_hash` API and `Emulator.rowHash()`; the native snapshot already computed it, so retrieving it does not perform another hash pass.

Rows are matched before unused storage is recycled. Cursor-bearing rows are excluded from cross-position reuse because unfocused cursors repair libtsm's swapped colors. Font changes recreate layout storage, theme/forced refreshes rebuild styles, and selection/edit changes invalidate the content hash. Plain scrolling uses ordinary refresh rather than forcing all rows. Storage stays bounded by the emulator grid; there is no extra history/LRU cache.

Each storage record has a stable serial used for its UI/widget identity and a cached paint key updated when its rendered content changes. The identities move with retained rows and remain bounded when new log lines arrive. This allows encoded display lists to move as well, without repeatedly constructing long hash strings during idle frames. The existing per-viewport revision diagnostics remain available, so `changedRows` reports viewport changes rather than the number of layouts reshaped or canvases re-encoded. The existing framework prunes retired paint nodes and has bounded style caches.

The final GPU comparison alternated two baseline and two optimized runs on the GTX 1060, with 240 measured frames per scenario and variant. Both variants already include the preceding color-run and direct-drawing optimizations. Full source snapshots, the exact bytecode modules, run order, source hashes, and raw timelines are retained under `out/terminal-row-reuse-gpu/`; `cached-comparison.json` is the final comparison. Recorded source snapshots include the workspace’s pre-existing background-fill coalescing. Earlier exploratory variants are retained separately and are not the source of the following figures.

| Scenario | GPU frame median before → after | Managed allocation before → after |
|---|---:|---:|
| Idle | 3.05 → 2.98 ms | 137 → 127 KiB |
| Typing | 3.07 → 3.17 ms | 170 → 167 KiB |
| Progress | 3.20 → 3.22 ms | 168 → 166 KiB |
| Scrolling logs | 18.17 → 17.25 ms | 1,188 → 491 KiB |
| ANSI redraw | 18.88 → 18.29 ms | 1,281 → 1,291 KiB |
| Unicode redraw | 17.43 → 17.96 ms | 1,218 → 1,227 KiB |
| Scrollback | 17.58 → 15.57 ms | 1,210 → 303 KiB |

Scrolling polling fell from 3.07 to 1.33 ms (about 57%), and scrollback polling from 3.25 to 0.94 ms (about 71%). Managed allocations fell by about 59% and 75%, respectively. End-to-end medians improved by about 5% for scrolling and 11% for scrollback in the final alternating GPU runs. Typing/progress were largely unchanged, and full redraws showed no consistent improvement; the small Unicode regression is retained in the table. Driver/rendering cost and timing variability still dominate many frames. This does not establish consistent 60 Hz rendering.

The final software benchmark is in `out/terminal-row-reuse-cached-key/`, with the starting baseline in `out/terminal-row-reuse-before/`. Software timings were also variable; the strongest repeatable results are reduced scroll processing and allocation. A final mixed `hlprof-live` capture is in `out/terminal-hlprof/row-reuse-final/`. Its first launch exposed a stale local native runtime missing `__dir_watch_close`; rebuilding the existing `haxeon-native` target repaired the toolchain without changing project source. Contract and visual checks were rerun on the rebuilt runtime. GPU before/after measurements both used the same runtime before that repair.

The visual smoke now contains an automated differential test: an optimized pane and a forced-refresh reference render side by side through scrolling, scrollback, an edit, selection, theme/font changes, alternate-screen transitions, resizing, and cursor focus changes. **All 50 frame comparisons are pixel-identical** across both themes. Each frame also checks native screen text, unique mutable layout ownership, and row-storage bounds. A scrolling interval asserts that the same six row widget identities remain in use. The committed static cursor/color cases also pass independently of the workspace’s pre-existing terminal-name and selection-fixture edits.

The native contract suite additionally checks row hashes across movement, style-only edits, selection, and resizing, and passes both native tests plus the Haxe contract runner. Native HXI declarations were audited on Linux, Windows, Intel/ARM macOS; the generated wasm32 declarations were audited for WASI and Emscripten. Browser rendering and performance were not measured for this change.

Run the durable visual regression test with:

```sh
env -u DISPLAY LIBGL_ALWAYS_SOFTWARE=1 python3 scripts/test-terminal-cursor-ui.py
native-packages/terminal/tests/run.sh
```

Final visual artifacts are in `out/terminal-row-reuse-validated-visual/`; the differential captures are the `comparison-*.png` files within each theme's `row-reuse` directory.

## Native text raster caching: 2026-10-26

Linux `perf` identified a second raster layer inside custom text rendering, independently of `CanvasView.cachePolicy`. It admitted stationary text based only on placement, even when its content changed each frame. New row textures caused GPU image creation/destruction and NVIDIA driver waits. The initial whole-process capture had 4,308 samples and zero lost samples; inclusive sampled CPU shares were 28% for `beginRasterPass` and 21% for `create_target`. These overlap and include startup; they are diagnostic CPU attribution, not GPU execution times or measured-frame percentages.

Two internal UIKit changes address that work:

- Admit a row texture only after the same glyph publication repeats at a stable placement. Changing text and colors use the direct glyph path; settled text still gains raster reuse. Candidates follow publication identity across line insertion/deletion, and only the current eligible visible rows are retained (up to 96 per layout).
- Hash scissor coordinates only when scissoring is enabled. Row textures render locally without a viewport scissor; stale coordinates previously invalidated their cache keys when unchanged rows moved.

These changes are in the `haxeon` submodule's UIKit sources. They add no public ABI or terminal-specific rendering mode. Font, color, atlas, scale and placement changes still participate in the existing glyph publication and raster identities.

The benchmark runner now records native stacks on Linux and reports frame-budget overrun percentages:

```sh
python3 scripts/benchmark-terminal-render.py --display --hardware --runs 3 --output out/terminal-native-check
python3 scripts/benchmark-terminal-render.py --skip-build --display --hardware --native-profile --runs 1 --output out/terminal-native-profile
```

Each profiled run retains `perf.data`, `native-leaf.txt`, and `native-calls.txt`. Profiling uses user-space CPU-clock sampling at 499 Hz with DWARF call stacks. Its timings are labeled as profiled and must be kept separate from unprofiled comparisons. The existing `--diagnose` option can additionally collect scheduling/fault evidence. A frame-budget overrun means the measured host callback cost exceeds 16.67 ms; it does not count physical display drops or establish achieved FPS.

The final comparison alternated three baseline and three optimized GTX 1060 desktop runs, with **360 measured frames per scenario and variant**. Both variants used the same bytecode and dependent libraries; only the UIKit library changed. Source snapshots, native libraries, bytecode hashes, run order, and raw timelines are retained in `out/terminal-native-next/`; `comparison.json` and `comparison.md` contain the final results. The initial candidate and its earlier results are retained separately.

| Scenario | Median before → after | p95 before → after | Budget misses before → after |
|---|---:|---:|---:|
| idle | 2.82 → 3.02 ms | 3.45 → 3.69 ms | 0.0% → 0.0% |
| typing | 3.09 → 2.57 ms | 14.70 → 3.34 ms | 3.3% → 0.0% |
| progress | 3.20 → 2.56 ms | 17.04 → 3.19 ms | 5.8% → 0.0% |
| scroll | 19.09 → 8.05 ms | 39.80 → 20.53 ms | 63.1% → 13.3% |
| ansi-redraw | 24.25 → 6.95 ms | 42.14 → 8.61 ms | 84.7% → 0.0% |
| unicode-redraw | 23.39 → 6.84 ms | 40.09 → 8.79 ms | 88.1% → 0.0% |
| scrollback | 19.79 → 6.61 ms | 39.79 → 19.77 ms | 68.9% → 15.6% |

The largest repeatable gains are in full redraws: all 360 ANSI and all 360 Unicode measured frames stayed below 16.67 ms after the change. Scrolling and scrollback still exceed the budget in 13–16% of measured frames, with p95 around 20 ms. Idle median cost increased by about 0.2 ms. Desktop load and driver/presentation timing varied between runs, so these results do not establish consistent 60 Hz rendering.

Whole-scenario row-raster misses fell from 20,260 to 2,185 (about 89%), while hits increased from 4,914 to 10,381. A final native capture is in `out/terminal-native-next/final-native-profile/`, with zero lost samples. Its inclusive sampled CPU shares for `beginRasterPass` / `create_target` fell to about 9% / 8%; sampling percentages are diagnostic and are not additive or unprofiled timings.

One optimized scrollback frame still took 122.20 ms: 118.77 ms in application submission, including only 0.98 ms of polling, and 3.39 ms in native rendering; no frame GC was reported. This points outside the native rendering work addressed here, but the cause is unresolved. It is retained in the raw maximum statistics. The original 1.93-second polling stall was not reproduced or established as fixed.

Validation includes the native backend, text engine, layout/render compiler, public renderer, and session renderer test groups. Tests verify changing text/colors avoid row-raster allocation, settled text resumes caching, inactive clip coordinates preserve cache hits, enabled clips invalidate correctly, and editor edits/newline insertion/deletion retain unchanged rows. The new changing-text regression fails against the baseline library. Terminal visual checks also cover both themes and optimized-versus-full-refresh rendering; the before/after software screenshot comparison is retained in `out/terminal-native-next/visual-comparison.json`. No browser or non-Linux runtime performance was measured.
