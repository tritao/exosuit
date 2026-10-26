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
| 5 | CLI: reuse file digests across watch rebuilds, cache the worker identity and resolved project (4b) | ~1 s | small | ✅ | haxeon 4d9ee155 + review fix aa024d78 (a re-resolved project is kept when its build fails). Measured by the implementer: CLI time before the compile request ~1.14–1.21 s → ~0.13 s on the editor project; end to end on a small project 750–850 → 122–130 ms. Follow-ups: fewer syscalls in `ActionFingerprint.appendPath` (~50–80 ms), and `PackageResolver`'s per-file `fullPath` |
| 6 | Cache directory listings when resolving imports (4c) | 0.4–0.6 s per edit; several s cold | small | ✅ | haxeon 7b15e72b. A cold compile listed 120 directories 82,513 times. Implementer's paired runs: cold graph 7.6–8.2 → 2.0–2.2 s (cold request 24.8–29.1 → 19.3–19.8 s), no-op frontend 0.91–1.22 → 0.49 s, edit graph 0.50–0.62 → 0.04 s. Output byte-identical |
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
| 14 | GC ownership ledger makes GC pauses 5–6× longer in live mode | the largest run-time gap | medium (HashLink C) | ✅ | hashlink dfd8022, 7ffa4a8; haxeon tests 05381153, 565e4784, bfd34c14. Each owner (a patchable module) gets its own page class in the allocator, so its blocks are counted from its pages by popcount and the per-block ledger is gone; inline-JIT allocation and the TLAB fast path keep the owner. Windows benchmark, owned module: mean GC pause 45 → 8.4 ms (normal 8.7), max 56 → 9 ms, 8.1 → 18.8 M allocs/s. Linux: builds under WSL, native owner-page and allocation-path tests pass; the Haxe GC tests ran on Windows only |
| 15 | String literals allocate on every evaluation in live builds (+0.37 MB per frame) | less GC pressure | medium | ✅ | hashlink ff8e5af (patches add globals with constant String initialisers), haxeon b5edf1c3. Every build path lowers a literal to a global holding one String; a patch adds the literal globals it introduces. The new runtime test checks that literals in a live module and in a patched function allocate nothing. Along the way: hashlink 54ec103 fixes an upstream JIT bug (no Windows home space when a function's only call never returns, which corrupted the caller's frame on throw). Builds through `HlBackend.lower` now also use constants and come out slightly smaller; the end-to-end GC gain is measured in the batch run |
| 16 | Direct calls instead of indirect calls in live modules | small | medium (JIT) | ✅ | hashlink 0bd7f9a, haxeon test 1334f4ae. Base code of a patchable module calls directly (x86-64); every function starts with an 8-byte nop that the first patch turns into a jump with one atomic store. Micro-benchmark: patchable 1.95–2.2 → 1.10–1.21 ns/call (normal ~1.0–1.1); a call into patched code is unchanged (~1.9 ns). Linux build syntax-checked under WSL; the Linux profiler path is untested at run time |
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
