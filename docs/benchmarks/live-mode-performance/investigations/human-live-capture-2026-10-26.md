# Human live-mode capture, 2026-10-26: why the editor is slow and lags

A person used the editor in live mode for 90 s on Windows (desktop focused throughout): hovering, clicking, scrolling,
opening files, a few keys. A live patch was applied at 45 s. The run was recorded with `scripts/run.py --live --profile`
(instrumented build, no stack samples) through `drive.ps1 -AppSeconds 90 -EditAtAppSeconds 45`, on the `input-timing`
branches, so NativeKit stamped each input with the steady clock from low-level hooks (sub-millisecond; before, the
stamp was the 15.6 ms system tick).

Capture: `graphical/build/host/profile/profile-20261026-115158/profile.pftrace` (2.1 GB; open it with
`trace_processor_shell --httpd` and Perfetto's native acceleration). Times below are trace seconds from launch.

## What it felt like, in numbers

| Input | OS stamp to the end of the first frame after the app polled it |
|---|---|
| Click (60) | p50 39 ms, **p90 370 ms**, p95 674 ms; 40% over 50 ms |
| Pointer move (1383) | p50 8.9 ms, p90 31 ms, p95 62 ms, p99 256 ms, max 831 ms |
| Key (6) | p50 40 ms, max 53 ms |

- Frames: p50 19.5 ms, p90 29 ms (below 60 Hz even when nothing is wrong). Only 1% exceed 33 ms.
- The UI thread spent 47 s of the first 63 s inside frames; the median gap between frames is 0.8 ms.
- At 63.3 s opening a file froze the editor until the end (27 s at about 3.6 frames a second, no input polled).
- The live patch was clean: `live.patch` took 16.6 ms at 49.16 s and input around it waited about 1 ms.

## Problem matrix

Costs are totals over the 63 s before the freeze unless stated; "per frame" is averaged over the 2814 frames.

| # | Problem | Evidence | Mechanism | What it causes | Where | Fix direction |
|---|---|---|---|---|---|---|
| 1 | **Input starved by frame messages** | Worst waits 450–730 ms (15.1, 19.7, 36.6, 50.8 s) have Input age = Input polled age: the input sat in the Windows queue. 17–86 frames ran back to back meanwhile, with no `nk.wait`. | Frames are driven by a posted message; Windows hands out posted messages before input, and each frame requests the next. | The click/hover tail: p90 click 370 ms. | NativeKit, Windows pump | Take queued input before a frame message (`GetQueueStatus(QS_INPUT)` / `PM_QS_INPUT`), or drive frames from a waitable timer instead of posted messages. |
| 2 | **Frames rendered inside the poll** | 6.78 s: a move dequeued promptly waited 809 ms to be polled while 86 frames (≤10 ms each) ran inside `nk_poll_event`. | `pump_events` renders surface frames before it returns the queued event to the app. | Same tail, even when Windows delivered the input. | NativeKit, `pump_events` | Return a queued event before pumping again; bound frames per poll. |
| 3 | **An animation that never sleeps** | 10–15 s: 8 inputs, 211 frames; `AnimationScheduler.requestFrame` 204 times for 79 `ScrollbarVisibilityController.advance` calls. | During the scrollbar's 0.5 s idle grace `animating()` stays true, so the scheduler requests a full frame every frame just to count down. Each scroll or hover-leave per scroll view: 0.3 s fade-in + 0.5 s countdown + 0.2 s fade-out at full rate. | Continuous ~40 fps redraw while idle; it feeds #1. | haxeon UI (`AnimationScheduler`, `ScrollbarVisibilityController`) | Wake at the deadline (timer) for waiting phases; request frames only while opacity changes. |
| 4 | **Layout runs three times per rebuild** | Every frame that rebuilds (1440 of 1440) calls `LayoutSession.submit` 3×; a 21.5 ms frame spends 12.3 ms there. Layout total 15.2 s. | `submitInternal`'s feedback loop: a `setResolved` callback calls `requestLayoutFeedback()` on each pass, so the whole tree is laid out again twice. The requester's call is under 1 µs and not recorded. Candidates: `EditorPane` (source geometry, content width), `ScrollView` extent, `StatusBarView`, `EditorGutter`, `MiddleEllipsisText`. | ~5.4 ms per frame; the largest share of frame cost. | haxeon UI + exosuit widgets | Find the requester (counter or span per call site), request feedback only on a real change, relayout only the affected subtree. |
| 5 | **Text glyphs republished every frame** | `TextEngine::published_glyphs_for_line` 8.7 s, 192k calls (~45 µs a line). | Each visible line's glyphs are rebuilt on every render, changed or not. | ~3.1 ms per frame. | nkui text engine | Cache published glyphs per line by layout revision. |
| 6 | **Render plan recompiled every frame** | `LayoutRenderCompiler::compile` 4.6 s, 1.6 ms per frame. | The sealed render plan is rebuilt even for render-only (animation) frames. | ~1.6 ms per frame. | nkui renderer | Reuse the plan when the layout did not change; compile incrementally. |
| 7 | **GPU timing readback stalls the CPU** | `nkui_renderer_get_gpu_frame_time` 5.9 s, 2.1 ms per frame (`Renderer.pollGpuFrameTime`). | Reading the timestamp query waits for the GPU. | ~2.1 ms per frame of the UI thread waiting. | nkui renderer (D3D11) | Read queries from earlier frames without blocking (`D3D11_ASYNC_GETDATA_DONOTFLUSH`, a ring of queries), or turn timing off outside diagnostics. |
| 8 | **Long lines draw every glyph** | Opening `graphical/src/app/ApplicationIcons.hx` (140 lines, 482 KB, lines up to 4102 chars) at 63.33 s: 110–128k glyphs per frame (1–3k before), 275 ms frames; `append_render_glyph` 1.6 s of 2.2 s. | No horizontal culling: glyphs far right of the viewport are emitted. | The freeze. | nkui text render / editor | Cull glyph runs to the viewport; cap layout width for very long lines. |
| 9 | **Redraw loop keeps the freeze going** | 66–90 s, no input: `ExosuitApp.pumpApplication` requests ~2 frames a second; every frame is the 275 ms frame. | Background work requests frames although nothing visible changed. | The editor never recovers on its own. | exosuit `pumpApplication` / `core.Application.update` | Request a frame only when presented state changed. |
| 10 | **SCM markers recomputed every poll** | `syncScmDocumentMarkers` 2.45 s over 981 calls (2.5 ms each): `LocalScmSource.snapshot` 781 ms, `repositories` 439 ms, `scmRelativePath` 1.09 s. | Runs on each background poll whether or not SCM state or open documents changed. | ~2.5 ms on the UI thread per poll, between frames. | exosuit `ExosuitApp` | Run on SCM change or document open/close; cache relative paths. |
| 11 | **Waits that miss input** | 63 of 1637 inputs arrived during an `nk.wait` that kept sleeping 2–11 ms. | The wait is a condition variable (`wait_for_wake` → `SleepConditionVariableSRW`) with a timeout; some window input does not signal it. | Up to a frame of extra delay on some inputs. | NativeKit wait | Wake on queue input (`MsgWaitForMultipleObjectsEx` with `QS_INPUT`, or signal from the input path). |
| 12 | **Big rebuilds** | First frame 1.48 s (build 1.41 s); rebuilds of 35–40 ms on some clicks (15.5 s, 36.6 s); opening a tab 377 ms. | Whole-tree build on large changes. | Startup and click hitches. | haxeon UI build | Lower priority than 1–9. |
| 13 | **The profiler inflates everything** | 856 M short calls dropped (each still pays its ~16 ns probe, ~13.7 s, ~22% of wall time) plus 21.8 M recorded calls. | The live host runs the instrumented build. | Absolute numbers above are 20–30% high, more in leaf code; the problems themselves are structural. | haxeon profiler | Validate fixes with a sampling-only capture (`--profile=sampling`); exclude hot native leaves from instrumentation. |
| 14 | Minor | `LiveHost.readStamp` (fopen/fread/fclose each tick) 472 ms + `functionId` 179 ms (~1%); GC 36 collections, ~137 ms marking, none inside frames; language server ~0.3 s. | | | | Not worth fixing first. |

## A typical frame (21.5 ms at 43.85 s)

- `ui.submit` 17.4 ms: build 2.7 ms, style invalidation compares 1.3 ms, **`LayoutSession.submit` ×3 = 12.3 ms**
  (`LayoutTransaction.encodeInto` ~1.4 ms + native Clay layout ~2.6 ms each).
- `ui.render` 4.1 ms: `nkui_layout_session_render_frame` 3.5 ms (render compile 1.7 ms, glyph publishing).

Averaged over all frames: layout ~5.4 ms, glyph publishing ~3.1 ms, GPU timing readback ~2.1 ms, render compile
~1.6 ms, build and the rest ~3–4 ms.

## Order of work

1. Responsiveness: #1, #2, #3 (and #11). These decide whether input waits behind frames.
2. Frame cost: #4, #5, #6, #7 together are most of the 19.5 ms median frame.
3. The freeze: #8, #9.
4. Background polling: #10.
5. Re-measure each with a sampling-only capture (#13), then a human capture like this one.
