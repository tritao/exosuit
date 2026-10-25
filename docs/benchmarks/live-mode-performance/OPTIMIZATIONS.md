# Live mode optimizations: tracker

The goal is a live mode (`run.py --live`) that is effectively instant: a short save-to-patch latency, and run-time speed
equal to normal mode. Evidence and root causes are in `../live-mode-performance.md` and `investigations/`.

Work is stacked on local `live-mode-speed` branches (hashlink, haxeon, exosuit). It is reviewed as a whole before it is
merged to mainline and pushed. Fixes may land in batches that are measured with one capture; if a batch misses its
expected range, bisect within it.

Status: ✅ done · 🔨 in progress · ⬜ todo · ⏸ deferred

## Edit latency: save to applied patch (about 10 s now)

| # | Optimization | Expected gain | Effort | Status | Commits / measured |
|---|---|---|---|---|---|
| 1 | LiveHost polls a small stamp file instead of re-parsing the 1 MB `.live.json` every frame | input lag 8.9 → 3 ms | small | ✅ | measured 8.9 → 3 ms |
| 2 | Patch freeze: indexed type-name lookup when hashing types for a patch (and reject struct/method types) | 1.9 s freeze → ~10 ms | small | ✅ | hashlink fba14f4; measured 1,927 ms → no visible gap |
| 3 | Lower only the regenerated functions | compile 8.1 → 5.6 s | small | ✅ | haxeon 5c14a23d; editor compile 9.8 → 6.5 s |
| 4 | Stop ~150 functions counting as "changed" each compile: encode unreachable open IR blocks (4a) | 0.3–0.6 s | small | ✅ | haxeon 41facedf; lowering 430–760 → 210–340 ms |
| 5 | CLI: reuse file digests across watch rebuilds, cache the worker identity and resolved project (4b) | ~1 s | small | ⬜ | |
| 6 | Cache directory listings when resolving imports (4c) | 0.4–0.6 s per edit; several s cold | small | ⬜ next | The cold parse still takes 6.3 s after #12–#13; directory listings are a likely part of it |
| 7 | Watch loop: file-change notifications instead of polling plus a 0.5 s settle (4d) | 0.6–0.8 s | small–medium | ⬜ | |
| 8 | Live edits write only the patch and stamp; defer the 40 MB `.hl`, its build-id hash and the side files | 0.7–1.1 s | small–medium | ⬜ | |
| 9 | Incremental inliner: stop re-encoding ~2k function pairs per compile (4e) | 1–1.5 s | medium | ⬜ | |
| 10 | Edit-local "changed" comparison plus a separate debug-position refresh in patches (4f) | 0.5–1 s, and a much smaller patch | medium | ⬜ | |
| 11 | Remaining whole-program floor: semantic canonicalization and invalidation, IR assembly, re-reading sources | 1–2 s | large | ⬜ | |

## Cold build (about 33 s compile)

| # | Optimization | Expected gain | Effort | Status | Commits / measured |
|---|---|---|---|---|---|
| 12 | The frontend restarts when typing finds a runtime module the graph lacks | measured 3.6 s (the "17 s" estimate counted the parse, which runs once anyway) | small | ✅ | haxeon 3befffc9 (drop the unused `runtime.DynamicObject` dependency on HL, report restarts in the compile phases), c1e71a38 + exosuit `SemanticTokenCodec` (type the 2 Dynamic arithmetic sites). No restart; cold 25.5 s with #13. Seeding the modules instead grew small programs 2 KB → 53 KB, so it was dropped |
| 13 | `decodeString` and interpolated-string parsing build literals in O(n²) time | several s (about 8 GB of allocation) | small | ✅ | haxeon 39218b1d; parse 11.4 → 6.3 s |

Cold compile, measured with one batch and then bisected: baseline 35.7 s → #12 only 32.1 s → #12 + #13 24.8 s. Allocation 19.3 → 8.3 GB, GC 5.0 → 2.6 s.

## Run time: live mode as fast as normal mode

| # | Optimization | Expected gain | Effort | Status | Commits / measured |
|---|---|---|---|---|---|
| 14 | GC ownership ledger makes GC pauses 5–6× longer in live mode | the largest run-time gap | medium (HashLink C) | ⬜ | |
| 15 | String literals allocate on every evaluation in live builds (+0.37 MB per frame) | less GC pressure | medium | ⬜ | |
| 16 | Direct calls instead of indirect calls in live modules | small | medium (JIT) | ⬜ | |
| 17 | LiveHost per-frame work: look up the tick function's ID once | tiny | small | ⬜ | |
| 18 | App code: `SetiIconData` (852 literals) and `Theme.semanticColor` lookups | helps both modes | small | ⬜ | |
| 19 | Flag captures that recorded human input (measurement hygiene, not a speedup) | — | small | ⬜ | |

## Upstream work by tritao (checked 2026-10-25, merged into `live-mode-speed`)

Read patch by patch against this list. None of it implements a tracked item; nothing here is duplicated.

| Upstream commit(s) | What it does | Relation to this list |
|---|---|---|
| haxeon a6736d27, ee7c2357; exosuit ff6e4af, f783468, 813227e | `NativeKitFileWatch`: typed file watch with `Ready`/`Lost`/`Overflow` events and directory exclusions. Exosuit's watchers use it; SCM watches change in place, leave out ignored directories (12k of 17k), and share one watch per repository | **#7 should be built on `NativeKitFileWatch`.** The haxeon CLI watch loop (`src/build`) is untouched and still polls. The SCM changes also cut UI-thread directory walks at startup (outside this list) |
| haxeon 6252b583, a9dcd71e, ab7cf25d, d7fd872c | Editor run time: cached visual rows per paragraph group; incremental layout for edits the owner makes; layouts kept across width changes that cannot affect them; semantic values compared by revision instead of rebuilding the whole text every frame | Not on this list. They are per-frame and per-keystroke app costs in both modes, like #18 but different code. **Run-time baselines for #14–#16 must be taken after this merge**, or their gains would be mixed up with these |
| haxeon 590a0a7d, 84db03da, f0ec7295; hashlink 4891279, e1517a4, 99c48e3, 9e0da2c | Profiler: native frames on Linux/macOS, unbroken FFI stacks (libffi fork, frame pointers), running vs waiting samples, a sampler that cannot hang | Helps attribution (#19-style tooling). Touches the stack capture in hashlink `module.c`, not `gc.c`/`jit*.c`/`hlpatch.c`, so it doesn't conflict with #14/#16 |
| haxeon 8978c52d | Formats LiveHost and two of our live tests | Our new commits should be run through the formatter before the stack is merged |

## Multicore compiler (deferred)

⏸ Parallel lowering, a second parallel split, parallel typing, and removing HashLink's global allocator lock
(`investigations/compiler-multicore.md`). Without the allocator change, threading tops out at about 1.3–1.5×, so items
5–13 come first.

## Projection

With 5–10 done: edit compile about 6 s → about 3 s, save-to-patch about 10 s → about 5 s. With 12–13: cold compile about
33 s → roughly 15 s. Going lower needs 11 and the multicore track.
