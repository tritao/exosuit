# Why live-mode scroll frames are slower, and why r6 looked worse than r4b

Investigator key: `live-scroll-slowdown`, 2026-10-25. Scripts and new runs:
`C:/Users/corbi/AppData/Local/Temp/claude/C--Users-corbi-projects-exosuit/098c8693-f262-4636-ade8-8878a23492f9/scratchpad/investigations/live-scroll-slowdown/`
(`phases.py`, `timeline.py`, `gc.py`, `odd.py`, `stats.py`; runs in `runs/plain-noprof`, `runs/live-noprof`).

## Short answer

1. **r6 is not the same workload as r4b.** A person was using the editor window during r6. The run recorded 754 input
   events that the script did not send: 650 pointer moves, 48 button events, 31 wheel events with dy=40/80/120/160
   (the script only sends dy=±1), 15 Ctrl key events and 5 enter/leave events. Explorer clicks at x≈30 between 15.8 and
   18.1 s and later clicks changed the view. `nodeCount` went 408 → 420 → 251/269 → 502/503 during the scroll window,
   compared with a constant 412 in r4b and 400 in r1. Most r6 scroll frames lay out 22% more nodes with an editor open,
   so the 27.4 ms median is mostly a different workload, not a runtime regression. On the part of r6 that matches r4b
   (hover, 408 nodes, though with stray mouse moves), layout frames take 23.2 ms against 21.7 ms (+7%).
2. **The real live-mode cost, measured without the profiler, is about +1 ms per layout frame (+9%) plus 5–6× longer
   GC pauses.** New unprofiled runs with the same script, scroll window, layout frames:
   normal 11.15 ms, live 12.21 ms. Tree-and-style (Haxe) went from 2.04 to 2.94 ms (+44%). Native layout, render and
   reconcile did not change (±0.2 ms). Each GC pause went from 3.7 ms to 19.4 ms. Allocation went from 1.34 to 1.52 MB per frame.
3. **The profiler inflates that gap from about 1 ms to 3.2 ms** (r1 19.69 → r4b 22.84 ms). Live code makes more
   calls longer than 1 µs, so more of them are recorded (kept calls per frame 3750 → 4475). Native layout under the profiler is
   10 ms against 2.7–3 ms without it.
4. **Mechanisms (code-confirmed)**, in the order I expect them to matter:
   - **Every allocation of a module type takes the slow path and mallocs a ledger node** in a patchable module
     (`module.c:1168-1171`, `gc.c:1140-1146`, `gc.c:953-960`), and every collection walks that whole ledger
     (`gc.c:248-262`, called at `gc.c:1501`). This explains the 5× pause and part of the allocation cost.
   - **A string literal allocates a fresh 24-byte String every time it is evaluated** in a live build
     (`HlLower.hx:1287-1300`, `BackendAssembly.hx:51-52`, commit 23104c59). String `switch`es are hit hardest:
     `SetiIconData.iconId` has 852 literals, and its self time per call went 3.8 → 19.7 µs. `Theme.semanticColor` went from 79 to
     29,244 kept calls. This explains the +0.18–0.41 MB per frame.
   - **Every Haxe-to-Haxe call goes through two indirections**: it loads `functions_ptrs[findex]`, makes an indirect call to a
     12-byte entry stub, and the stub does `mov rax,&patch_targets[slot]; jmp [rax]` (`jit_emit.c:707-722`,
     `module.c:747-772`, `jit.c:497-524`). This cost is small per call and I did not measure it on its own.

## 1. Data: frame phases in the scroll window

`phases.py` (all frames in `scroll-start`..`scroll-end`, median in ms):

| run | frames | frame | submit | tree&style | native layout | render | reconcile | alloc/frame | nodes | GC pause (last) |
|---|---|---|---|---|---|---|---|---|---|---|
| r1 plain, profiled | 734 | 19.42 | 13.72 | 3.00 | 9.35 | 5.71 | 1.27 | 1.149 MB | 400 | 3.0 |
| r2 watch, profiled | 722 | 19.62 | 13.88 | 3.03 | 9.48 | 5.72 | 1.28 | 1.149 MB | 400 | – |
| r4b live patched, profiled | 552 | 22.60 | 16.19 | 4.35 | 10.29 | 6.29 | 1.43 | 1.559 MB | 412 | 8.3 |
| r5 live, host instrumented, profiled | 246 | 34.33 | 24.04 | 6.93 | 14.66 | 9.98 | 2.18 | 1.573 MB | 416 | – |
| r6 live, stamp fix, profiled | 739 | 27.40 | 20.57 | 5.79 | 13.49 | 7.66 | 1.96 | 1.498 MB | **502** | 23.9 |

Layout frames only (`treeAndStyleSeconds > 0`), from `gc.py`. The "events" column counts input the script did not send:

| run | profiled | phase | layout frames | frame | t&s | nl | render | GCs | ms/GC | GC % of wall | alloc/frame | events |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1 | yes | scroll | 581 | 19.69 | 3.07 | 9.48 | 5.72 | 16 | 3.0 | 0.2 | 1.15 MB | none |
| r4b | yes | scroll | 434 | 22.84 | 4.41 | 10.38 | 6.36 | 204 | 8.3 | 7.1 | 1.56 MB | none |
| r6 | yes | hover | 519 | 23.21 | 4.48 | 10.86 | 6.11 | 11 | 25.4 | 2.0 | 1.27 MB | human |
| r6 | yes | scroll | 642 | 30.25 | 6.12 | 14.38 | 8.04 | 20 | 26.7 | 2.2 | 1.76 MB | human |
| **plain-noprof** (new) | no | scroll | 873 | **11.15** | 2.04 | 2.69 | 5.27 | 27 | **3.7** | 0.4 | 1.34 MB | 64 moves, 27 wheel, 2 clicks (human) |
| **live-noprof** (new) | no | scroll | 577 | **12.21** | 2.94 | 2.84 | 5.11 | 21 | **19.4** | 1.7 | 1.52 MB | clean |
| plain-noprof | no | hover | 834 | 13.28 | 2.71 | 3.35 | 5.65 | 18 | 3.8 | 0.5 | 1.03 MB | human |
| live-noprof | no | hover | 790 | 12.39 | 3.18 | 3.01 | 4.70 | 18 | 22.5 | 2.8 | 1.24 MB | clean |
| merged-live-check (1 patch) | no | scroll | 1008 | 11.88 | 2.96 | 2.90 | 4.71 | 19 | 40.3 | 3.2 | 1.55 MB | – |

Notes:
- r2 (watch, not live) matches r1. A compile server sitting idle in the background costs nothing measurable.
- The new plain-noprof run also picked up human input (`odd.py`: 43 moves, 2 clicks and 1 key in hover; 64 moves,
  27 wheel and 2 clicks in scroll). Its tree stayed at 400 nodes, but its hover native and render numbers are higher than
  live's. That is noise from the extra events. Haxe tree-and-style is the robust signal: +17% in hover and +44% in scroll for live.
- The new runs used `run.ps1 -NoProfile` (copied to the scratch dir) under the measurement lock: plain at 14:30–14:32 and live
  at 14:32–14:34. The live run rebuilt `live.hl` uninstrumented (37.0 s, 11903 functions), then ran with no edit.

### r6 timeline (2-second bins, `timeline.py`)

The human input starts 5.5 s before `interaction-start`: PointerEnter, then wheel dy=40. Node count per bin:
0–6 s: 408 · 6–12 s: 409/410/420 · 14–16 s: 269/420 · 16–18 s: 251/257/269 · 20–22 s: 459/477/488 · 22–40 s: 502/503.
Frame medians follow the node count: about 22.5 ms at 408 nodes and 31.5–32.6 ms at 502–503 nodes. Ctrl (key 341) was
pressed with clicks at 11.96 s, 31.34 s and 32.18–33.13 s.

## 2. Why live frames are slower: mechanisms

### 2a. GC ownership ledger in patchable modules (HashLink)
- `hlruntime.c:169` loads the live module with `HL_MODULE_PATCHABLE`.
- `module.c:1168-1171`: "Allocation ownership costs a ledger entry per allocation and a walk of the whole ledger per
  collection, and only runtime-owned (patchable) modules are ever retired against it." Every type in the module gets
  `gc_owner = m`, and so do types a patch adds (`hlpatch.c:923`).
- `gc.c:953-960`: the thread-local allocation buffer (TLAB) fast path requires `owner == NULL`. Every owned allocation
  therefore takes `gc_alloc_gen_owner_full`: the global lock, `gc_allocator_alloc`, and then `malloc(sizeof(gc_owned_alloc))`
  pushed onto a global list (`gc.c:1140-1146`).
- `gc.c:248-262`: `gc_sweep_owned_allocs` walks the whole list on every collection (inside `gc_mark`, `gc.c:1501`), checks
  each node's mark bit and `free()`s the dead ones. The pause therefore grows with live objects plus the objects allocated since the
  last collection. The pause measurement (`gc.c:1541-1551`) covers stop-the-world plus mark plus this walk.
- Measured: the pause is 3.7 ms normal and 19.4–22.5 ms live, both unprofiled. It was 40 ms after one patch (merged-live-check), and
  in profiled runs 3.0 ms (r1) against 8.3 ms (r4b, frequent small GCs triggered by the host's JSON parsing) and 26.7 ms (r6).
  `FrameGcScheduler.idle` self time in the r4b scroll window was 906.6 ms against 48.4 ms for r1 (`stats.py`), with 113 calls against 23.
- The ledger is used only for `hl_gc_owner_live_count`/`root_count` (`module.c:1253-1257`), that is, retiring a module after a reload.

### 2b. String literals allocate on every evaluation in live builds (compiler)
- `BackendAssembly.hx:51-52`: only the non-live assembler is created with `stringConstants = true`. `HlLower.hx:1287-1300`:
  without it, a `ConstString` becomes `LoadString` + `LoadInt` + `New` + 2×`FieldSet`, a fresh 24-byte String each time.
  Commit 23104c59 says so: "A live module keeps the per-evaluation path, because a patch cannot add a global."
- A String switch evaluates its case literals. `SetiIconData.iconId` (graphical/src/ui/SetiIconData.hx:30) has 852 string
  literals. Its self time per call went from 3.76 µs (r1, 3246 calls) to 19.7 µs (r4b, 2873 calls).
  `style.Theme.semanticColor` (src/style/Theme.hx:144) went from 79 to 29,244 kept calls, so its calls now take more than 1 µs.
  `SemanticPresentation.foreground` went from 81 to 304 µs per call.
- Measured allocation per layout frame, unprofiled: 1.34 → 1.52 MB in scroll (+0.18 MB, about 7.5k Strings) and 1.03 → 1.24 MB
  in hover. Profiled: 1.15 → 1.56 MB. The findings doc lists the allocation rise as "Not yet explained"; this is the explanation.
- Inference: each of these allocations is also owned (see 2a), so it takes the slow path plus a malloc, and later a free in the sweep.

### 2c. Call indirection in the JIT
- `jit_emit.c:707-722`: in a patchable module, a bytecode call loads `functions_ptrs[findex]` and calls through the register.
- `module.c:747-772`: `functions_ptrs[slot]` is a 12-byte entry stub, written by `hl_jit_patch_method` (`jit.c:497-524`):
  `mov rax, &patch_targets[slot]; jmp [rax]`. Each call therefore costs an extra load, an indirect call and an indirect jump through memory.
- Not measured on its own. Inference: about 1 ns per call when the branch is predicted. At a few hundred thousand calls per
  frame that is roughly 0.1–0.4 ms per frame, so it is a smaller contributor than 2a and 2b.

### 2d. What the per-function statistics show (profiled, r1 against r4b scroll window, `stats.py`)
- The heavy framework functions cost the same per call in both: `StyleDiff.compare` 2.52 µs in both,
  `RenderNode.walk` 0.60 against 0.57 µs, `LayoutTransaction.encodeInto` 0.92 against 0.96 ms, native `append_render_glyph` 2.03 against 2.02 µs.
- The cost grows in functions that evaluate string literals or allocate, mostly build lambdas and app code:
  the `TreeViewRow.build` lambda 4.5 → 8.7 µs, `Button.buildScoped` 3.0 → 5.0 µs, `Text.build` 2.05 → 3.14 µs, `iconId`
  3.8 → 19.7 µs, `DirectoryTreeModel.buildItemWithIcons` 1.9 → 3.6 µs. This matches 2a and 2b better than a uniform
  call overhead (2c), which would slow `RenderNode.walk` as well.
- Live-only costs that fall outside the frame: `ucrtbase!fread` 291.7 ms (1141 calls, the host's 1 MB JSON parse, since fixed),
  `FrameGcScheduler.idle` +858 ms, `_wfopen`/`fclose` +60 ms.

### 2e. Why the profiled gap (3.2 ms) is 3× the unprofiled one (1.06 ms)
- The profiler drops calls under 1 µs and keeps the rest. Leaf functions that slow down in live code (2b) cross that
  threshold, so they are recorded with full cost: kept Haxe calls rose from 3750 to 4475 per frame (findings doc §2).
- Native layout is 9.4–10.4 ms profiled against 2.7–2.9 ms unprofiled. `Clay__Array_RangeCheck` alone dropped 95 M calls per run.
  Profiled native and render times also vary about ±7% between runs (r2 hover native layout 10.36 against r1 9.63), so the
  profiled +0.9 ms in native layout and +0.6 ms in render for r4b are mostly profiler overhead and noise. Unprofiled, these phases do not change.
- Conclusion: compare frame times only on unprofiled runs. Use profiled runs for attribution.

## 3. Why r6 is worse than r4b

| contributor | evidence | size |
|---|---|---|
| Human input, different UI state | 754 unscripted events; 502–503 nodes for 22–40 s of the scroll window against 412 | most of it: 31.5–32.6 ms at 502 nodes against about 22.5 ms at 408 |
| GC moved inside frames | r4b: 204 GCs of 8.3 ms, many triggered by the host's JSON parsing between ticks. r6: 20 GCs of 26.7 ms, triggered by app allocation inside frames | mean `frameGcSeconds` 0.05 → 0.28 ms per frame; median unaffected; adds 25 ms spikes |
| Profiled run-to-run noise plus human mouse moves | r6 hover at 408 nodes 23.21 against r4b 21.70 ms | about +1.5 ms (+7%) |
| Background CPU | r6 scroll at driver time 112.9–136.9 s; the only compile (edit 1) finished at 90.2 s. One `hl` process went 222 → 468 MB at 126.3 s (probably the workspace agent reacting to the human opening files; CPU not recorded) | unknown, probably small |
| Host instrumented | Host probes run only in host code between ticks. The app module is the same instrumented `graphical/build/host/live.hl` in both runs (11891 functions, same compile). The host now reads `live.hl.live.stamp` every tick (`LiveHost.hx:38`, 26-byte file) and calls `functionId` once a tick, a linear scan that reaches index 4072 of 13,496 identities (`LiveHost.hx:37,198-203`) | outside frame phases; affects ticks per second, not per-frame time (inference) |

Input lag improved in r6 (scripted input delivery median 8.67 s → 1.81 s) because the per-tick 1 MB JSON parse is gone.
The frame-time "regression" is the different workload created by the human input, plus GC pauses now landing inside frames.

r5 (34 ms) is a separate case: an instrumented host still parsing 1 MB of JSON every tick. Delivery lag was 53 s, and every
phase, native included, was about 50% slower. I attribute that to profiler pressure from millions of host probe events per tick
(inference; not verified).

## 4. Fixes

1. **Make GC ownership cheap or optional** (HashLink, medium effort). Possible approaches: keep the ownership ledger only while a
   reload retirement is pending; track ownership per GC page or arena instead of per allocation, by giving owned types their own
   pages so the TLAB fast path still works; or store an owner bit in the block metadata. Expected: GC pause back to about 4 ms
   (removing 15–35 ms pauses and 1.5–3% of wall time), the allocation fast path back, and part of the +0.9 ms in tree-and-style recovered.
2. **String literals in live builds without per-evaluation allocation** (compiler plus runtime, medium effort). Options:
   reserve a module-owned literal table that a patch can append to, with a new `hlp` section that creates the Strings at patch time;
   allow patches to add constant globals; or a cheap equality fast path for String switches (compare length and data against
   `LoadString` without allocating a String). Expected: −0.18 MB per frame, and `iconId`/`semanticColor`-style switches back to
   normal cost. Most of the remaining tree-and-style gap (inference).
3. **Direct calls in live modules** (JIT, medium effort, small gain). Emit `CALL_FUN` direct calls and redirect a patched function by
   overwriting its old entry with the jump that `hl_jit_patch_method` already writes, keeping the stub only for added
   functions. Expected: about 0.1–0.4 ms per frame (inference). Do this after 1 and 2, then re-measure.
4. **Measurement hygiene** (small effort). Have `frames.py`/the driver flag runs whose `record.jsonl` contains events the
   script did not send (see `odd.py`). r6 and today's plain-noprof both had them. Compare frame times on unprofiled runs only.
   Optionally the driver could make the window non-interactive or warn the user.
5. **LiveHost per-tick work** (small effort). Cache `functionId(entry + ".tick")` once (it is constant until a reload), and poll the
   stamp on a timer or file-change notification instead of on every tick. This does not change frame phases, but keeps the host off the UI thread's time.
6. **App-level** (small effort, helps both modes): `SetiIconData.iconId` (852 literals) and `Theme.semanticColor` could use a
   `Map` built once, or switch on interned values.

## 5. Open questions
- How much of the unprofiled +0.9 ms in tree-and-style comes from 2a, 2b and 2c? Separating them needs a build with
  `stringConstants` forced on for live, or a VM with ownership disabled. Both need edits in a scratch copy.
- Why the pause doubled after one patch (merged-live-check 40 ms against live-noprof 19–22 ms): more retained objects, or the patch's staging allocations?
- Whether the profiled live build's per-call probe placement differs from the normal instrumented build (same IR instrumentation is assumed).
- What the `hl` process that grew to 468 MB during r6's scroll window was doing.
