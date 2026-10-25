# Review of "Why are scroll frames slower in live mode" (live-scroll-slowdown)

Reviewer key: `live-scroll-slowdown-verify`, 2026-10-25. Scripts and new runs in
`C:/Users/corbi/AppData/Local/Temp/claude/C--Users-corbi-projects-exosuit/098c8693-f262-4636-ade8-8878a23492f9/scratchpad/investigations/live-scroll-slowdown-verify/`
(`nodes.py` is new; `gc.py`, `odd.py`, `run.ps1`, `drive.ps1` and `script.json` are copies of the investigator's; runs are in `runs/plain-a`, `live-a`, `plain-b` and `live-b`).

## Verdict: partly holds

The qualitative story holds. The r6 slowdown comes from human input (a different UI state), and live mode really costs
more in Haxe tree-and-style, allocation and GC pauses. The headline number "+1 ms per layout frame (+9%)" does not hold:
it comes from one pair of runs, and the baseline run in that pair was contaminated by human input. Some mechanism
claims are presented as code-confirmed when only the code path is confirmed, not its share of the cost.

## What I re-checked and found correct

- **Their tables reproduce exactly.** Re-running `gc.py` on r1, r4b, r6, plain-noprof, live-noprof and merged-live-check gives the same numbers as the report
  (for example r4b scroll: 204 collections at 8.3 ms, 7.1% of wall time; r6 scroll: 20 at 26.7 ms; layout-frame medians 19.69, 22.84 and 30.25 ms).
- **Unscripted input in r6 (`odd.py`).** Scroll window: 370 PointerMove, 30 PointerButton, 9 PointerScroll and 13 Key events. Before the window: 132 moves and 13 wheel events.
  r1, r4b, live-noprof and merged-live-check have none beyond a single gap move.
- **New: node-count breakdown of r6 (`nodes.py`).** This supports their main claim more directly than anything in their report:
  r6 scroll frames at 420/421 nodes have a median of 22.93/22.45 ms, the same as r4b scroll at 412 nodes (22.84 ms). At 502/503 nodes they take 31.16/32.30 ms.
  Native layout goes 10.85 → 15.28 ms and render 5.73 → 8.44 ms with the node count. So r6's extra time comes from the UI state, not from the runtime.
- **Per-function statistics** (`live-perf/stats/*.tsv`). `ui.SetiIconData.iconId`: 12.19 ms over 3246 calls (3.75 µs per call) in r1 scroll, against 56.74 ms over 2873 calls (19.75 µs) in r4b.
  `style.Theme.semanticColor`: 79 against 29,244 kept calls. `FrameGcScheduler.idle`: 48.4 → 906.6 ms. `ucrtbase!fread`: 291.7 ms over 1141 calls. All confirmed.
  `Theme.semanticColor` (`src/style/Theme.hx:144`) is a string `switch`, and so is `iconId` (`graphical/src/ui/SetiIconData.hx:30`).
- **Code**
  - `hlruntime.c:169`: `hl_module_init(module,HL_MODULE_PATCHABLE)`.
  - `module.c:1168-1171`: `gc_owner` is set on every type.
  - `gc.c:953-960`: `gc_tlab_thread` requires `owner == NULL`. TLAB is compiled on Windows x64 (`gc.c:223-224`, needs HL_THREADS), so the fast path really is lost for owned types.
  - `gc.c:1140-1146`: one malloc per owned allocation.
  - `gc.c:248-262`: `gc_sweep_owned_allocs`, called inside `gc_mark` (`gc.c:1501`), which runs inside stop-the-world in `gc_major`. Its time is therefore in the measured pause.
  - `BackendAssembly.hx:51-52`: `stringConstants` is true only when not live.
  - `HlLower.hx:1287-1300`: `lowerStringLiteral` emits LoadString + LoadInt + New + 2 FieldSet. Commit 23104c59 says the same.
  - `jit_emit.c:707-722`: CALL_REG through `functions_ptrs` when the module is patchable.
  - `module.c:747-772` and `jit.c:497-524`: a 12-byte `mov rax, imm64; jmp [rax]` stub.
  - The ownership ledger is read only by `hl_gc_owner_live_count` and `hl_gc_owner_root_count` (`module.c:1252-1257`), so it does nothing during steady-state frames.

## New measurements (lock held; 4 runs, all clean per `odd.py`, unprofiled, same script)

Layout frames, medians in ms:

| run | phase | frame | t&s | nl | render | ms/GC | alloc/frame |
|---|---|---|---|---|---|---|---|
| plain-a | scroll | 11.07 | 2.01 | 2.69 | 4.97 | 3.8 | 1.15 MB |
| live-a | scroll | 11.39 | 2.78 | 2.72 | 4.77 | 18.1 | 1.52 MB |
| plain-b | scroll | 10.61 | 1.94 | 2.62 | 4.80 | 3.8 | 1.15 MB |
| live-b | scroll | 13.18 | 3.13 | 3.08 | 5.52 | 22.1 | 1.52 MB |
| plain-a | hover | 12.69 | 2.54 | 3.28 | 5.38 | 3.8 | 1.04 MB |
| live-a | hover | 11.35 | 2.93 | 2.83 | 4.43 | 22.5 | 1.24 MB |
| plain-b | hover | 11.85 | 2.35 | 3.08 | 5.09 | 3.3 | 1.04 MB |
| live-b | hover | 14.99 | 3.97 | 3.58 | 5.55 | 26.1 | 1.24 MB |

Order: plain-a 14:40, live-a 14:44, plain-b 14:47, live-b 14:50. Each live run rebuilt `live.hl` (37.8 s, 11903 functions).

## Problems

1. **"+1 ms per layout frame (+9%)" is a single-sample number.** In my clean pairs the scroll gap is +0.32 ms (a) and +2.57 ms (b).
   In hover it is −1.34 ms (a, live faster) and +3.14 ms (b). The four live scroll runs (12.21, 11.39, 13.18, and 11.88 for merged) spread over 1.8 ms.
   The whole-frame live cost is therefore anywhere from about 0 to 2.6 ms and is not resolved by n=1. Robust signals that hold in every pair:
   tree-and-style +0.39 to +1.19 ms, GC pause 18–26 ms against 3.3–3.8 ms, and allocation +0.37 MB per scroll frame and +0.20 MB per hover frame.
2. **The plain-noprof baseline was contaminated, and that changes the allocation figure.** The report says the human input left plain-noprof at 400 nodes
   and "only" affected native and render. But its scroll allocation was 1.34 MB per frame, against 1.15 MB in both clean plain runs (and r1).
   The clean live-mode allocation increase in scroll is therefore **+0.37 MB per frame (about 15k 24-byte Strings)**, not +0.18 MB.
   Clean tree-and-style in scroll is 1.94–2.01 ms, not 2.04, so their scroll t&s gap is about right.
3. **The mechanisms are labelled "code-confirmed", but only the code paths are confirmed.** None of the three mechanisms' share of the cost was measured:
   - "This explains the 5× pause" (ledger walk): plausible, but untested. Another possible cause is a larger live heap in live mode. The LiveHost
     description holds 13,496 identity objects, `File.getBytes(path)` keeps the module bytes, and there is the runtime/patch metadata, all in the same GC heap (`LiveHost.hx:27-30`).
     The 40 ms pause after one patch is not explained either. Turning ownership off in a scratch VM would settle it.
   - "This explains the +0.18–0.41 MB per frame" (literals): plausible, but there is no count of String allocations per frame. Other per-evaluation allocations that differ between live and normal lowering were not ruled out.
   - The argument against call indirection relies on per-call means of *kept* calls (≥1 µs). Those are biased by the threshold, so `RenderNode.walk` 0.60 → 0.57 µs does not show that indirection is cheap.
4. **The "profiler inflates the gap 3×" comparison is not apples to apples.** r4b also parsed 1 MB of JSON every tick (204 GCs, `fread` 291.7 ms) and had 3 patches, while the unprofiled live run had none.
   With the unprofiled gap itself ranging from 0.3 to 2.6 ms, the "3×" factor is unsupported. The general point (compare unprofiled runs only) holds.
5. **The r6-hover baseline is also contaminated.** The report calls r6 hover "the part that matches r4b", but r6 hover has 12 PointerButton, 9 PointerScroll and 82 PointerMove unscripted events,
   and its node count moves through 408/409/410/420. The 23.21 against 21.70 ms comparison mixes those states. The cleaner match is r6 scroll at 420/421 nodes (22.45–22.93 ms) against r4b scroll (22.84 ms): no difference.
6. **Fix 1 expectation ("GC pause back to about 4 ms")** depends on the ledger being the whole pause difference (see 3). It is unverified.
   **Fix 2 expectation ("most of the remaining tree-and-style gap")** is inference. A 1–2 line A/B (scratch compiler with `stringConstants` forced on for live, with no patching) would test it cheaply,
   since a no-edit live run never needs to add a global.

## Missing angles

- Run-to-run variance of unprofiled runs: one sample per mode cannot resolve a ~1 ms effect. Use at least 3 alternating pairs and report spread. live-b slowed native and render too, which points to system noise.
- GC pause cost in the frame-time distribution: live medians hide 18–40 ms pauses that land inside frames (frame drops). p95/p99 frame time should be reported, not just medians.
- A cheap A/B to split the causes: (a) a no-edit live run with `stringConstants` forced on; (b) a VM with `gc_owner = NULL` for patchable modules (a retirement-accounting loss is acceptable for a test).
- The mark-time contribution of host-held objects (LiveHost description, module bytes) to the live pause.
- Whether the profiler disables TLAB in both modes (via `gc_profile_allocation_callback` in `GC_TLAB_POLICY`, `gc.c:945-950`). That would make profiled allocation cost comparisons uninformative about the TLAB loss.
