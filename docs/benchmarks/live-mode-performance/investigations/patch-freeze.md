# Patch freeze: why applying a 3-function live patch blocks the UI thread for ~1.9 s

Key: `patch-freeze`. Date: 2026-10-25. Repos read-only; all experiments in
`C:/Users/corbi/AppData/Local/Temp/claude/C--Users-corbi-projects-exosuit/098c8693-f262-4636-ade8-8878a23492f9/scratchpad/investigations/patch-freeze/`.

## Answer

Almost the whole freeze is one function: **`hash_type_prefix`** in HashLink's `src/hlpatch.c:393`, which
`hl_module_apply_patch` (`src/hlpatch.c:866`) calls on every patch at `src/hlpatch.c:872` to check that the patch's
`type_prefix_hash` matches the module's type table. To hash each type it turns every type name, field name, method
name, enum constructor name and abstract name into a **string-table index** with `hash_type_string_index`
(`src/hlpatch.c:371`). That function is a **linear scan of the whole string table**, calling `hl_get_ustring` and
`ustrlen` on each candidate until it finds a match. The editor module needs 23,287 such lookups, and each scans 4,565
strings on average: **106.3 million string comparisons per patch, about 1.88 s**. The cost depends only on the module
(names × strings, so it grows roughly with the square of app size) and not at all on how many functions the patch
changes. Every patch pays it again, not only the first.

Replacing the scan with a content→index hash map built once per call gives the **same hash** (checked: `EQUAL` on two
patches). The type hash then takes about 5 ms and the whole apply about 10 ms, against 1,885 ms before. That is about
190× faster.

## Evidence

### 1. The trace: the whole 1.89 s is inside the one native call

I exported 19.0–21.5 s from the r6 capture (`hlprof-live export --format pftrace --start-ms 19000 --end-ms 21500`)
and decoded it with a small protobuf reader (`pf.py`, `q2.py`):

```
patchSet 1892.381 ms  depth 0  runtime.Runtime.patchSet
         1892.379 ms  depth 1  $generic:runtime.LoadedModule.access
         1892.378 ms  depth 2  $lambda:runtime.Runtime.patchSet:patchSet#0      (no children)
```

The lambda only calls `RuntimeNative.patch` (`haxeon/src/runtime/Runtime.hx:251-252`), which goes to
`hl_runtime_module_apply_hlp` (`haxeon/native/runtime/module_runtime.c:89-91`). The span has no recorded children,
so the time is inside VM C code, which the instrumenting profiler can't see. During those 1.89 s the main thread
records nothing else. The only other activity is the `nk.local` thread sleeping in `wait_pipe` and `Sleep`, which
covers 1,690 ms. The doc's `live.patch` figure is 1,896 ms, so `File.getBytes(.hlp)` plus the `PatchSet`
constructor took about 4 ms.

### 2. Reproduction outside the editor, with each step timed

**Harness.** I built an instrumented `hl.exe` in scratch (`bin/hl.exe`):
- I recompiled scratch copies of `hlpatch.c` and `hlruntime.c` with QueryPerformanceCounter marks after every step of
  `hl_module_apply_patch` and `hl_runtime_module_apply_hlp`. The diffs are in `hlpatch-instrumented.diff` and
  `hlruntime-instrumented.diff`.
- I added a small `harness.c` main and linked the existing release objects from
  `haxeon/out/cmake/windows-msvc/hashlink/CMakeFiles/hl.dir`, with the same `/O2` flags as the shipped VM.
- The harness loads the editor live module through `hl_runtime_module_load`, from a snapshot of
  `graphical/build/host/live.hl` and `.hli` (revision 1, copied to `mod/`). The module's static initializer is
  skipped.
- It then applies `.hlp` files built by `mkhlp.py`: a valid HLP v8 header and symbols section with the module's real
  base counts and prefix hashes, plus trivial `ORet` bodies for void→void functions. These are chained 1→2 (1
  function), 2→3 (3 functions) and 3→4 (1 function).

**Module size.** 13,496 functions, 646 natives, 14,277 types, 25,080 strings and 4,307 globals. The r6 capture's
`profile.hl` is almost the same size: 14,269 types and 25,051 strings.

Per-step timing for the first patch (`run-linear.txt`). Every step not listed took under 0.05 ms.

| step | ms |
|---|---|
| hl_patch_read (75-byte patch) | 0.013 |
| hash ints / floats | 0.003 / 0.002 |
| hash strings | 1.000 |
| **hash types** | **1,881.9** |
| validate types / stage layout | 0.39 / 0.30 |
| combine strings | 0.63 |
| JIT alloc+init / JIT 1 function / finalize | 0.158 / 0.010 / 0.009 |
| slot patching, live publish, publish tables | 0.001 / 0.014 / 0.016 |
| **total apply** | **1,884.7** |

Repeated patches cost the same, so this is not a one-time warm-up:

| patch | functions | total (ms) | hash types (ms) |
|---|---|---|---|
| 1→2 | 1 | 1,884.8 | 1,881.9 |
| 2→3 | 3 | 1,890.4 | 1,887.5 |
| 3→4 | 1 | 1,886.8 | 1,884.5 |

Counters inside `hash_type_prefix`, the same on every patch:

```
string lookups=23287 scanned=106293721 (avg 4565) first-conversions=424 time=1877.3 ms
global lookups=4116  scanned=8472786                                      time=3.1 ms
```

So the time per scanned string is 1,877 ms / 106.3 M ≈ 17.7 ns. That covers a `ustrlen` over a UCS-2 string, a
length compare, and sometimes a `memcmp`. Only 424 of the scanned strings needed a UTF-8→UCS-2 conversion
(`hl_get_ustring`), so allocation is not the cost. The global lookups (`hash_type_global_index`, `src/hlpatch.c:385`,
also a linear scan) add only 3 ms.

### 3. The fix, tested

With `HLP_FAST=1`, the harness builds an open-addressing hash map from string content to its *first* index, matching
the linear scan's first-match rule, then runs the same `hash_type_prefix` (`run-fast.txt`, `run-compare.txt`):

```
[compare] indexed: build 1.920 ms + hash 5.037 ms -> 2573676373 (linear 2573676373) EQUAL
[compare] indexed: build 1.719 ms + hash 5.566 ms -> 2573676373 (linear 2573676373) EQUAL
HLP_FAST: patch 1→2 total 11.07 ms, 2→3 total 9.60 ms, 3→4 total 10.01 ms
```

The ~5 ms hash time includes about 27k QueryPerformanceCounter calls from my own counters, so the real cost is
lower.

## Why it scales the way it does

- **Measured:** the cost is fixed per patch. One function and three functions cost the same: 1,885 ms vs 1,890 ms.
  The JIT work for the changed functions is about 0.03 ms.
- **From the code:** `hash_type_prefix` is O(L × P̄ × S̄):
  - L = names in all types: object/struct names, fields and protos (`src/hlpatch.c:413-419`), virtual fields
    (`:426`), enum names and constructors (`:429-431`), abstract names (`:406`).
  - P̄ = average string-table position of each name.
  - S̄ = average candidate length.
  - Both L and the string table grow with the app, so the freeze grows roughly with the square of module size.
- **Inferred:** the check was added in hashlink `7827a4e` ("Harden live patch decoding and JIT staging",
  2026-09-05). On the small test modules it was written against, it would have been invisible.
- It runs while `runtime->lock` is held (`src/hlruntime.c` `hl_runtime_module_apply_hlp`), on the thread that calls
  `Runtime.patchSet`. In LiveHost that is the UI thread (`haxeon/src/tools/LiveHost.hx:47-49`).

## Everything else on the patch path is small (measured)

- `hash_string_prefix`: 1.0 ms. It is O(total string bytes).
- Combining strings: 0.5–0.8 ms. It copies all 25k strings into a fresh blob on every patch (`src/hlpatch.c`, in
  `hl_module_apply_patch`).
- `stage_patch_layout`: 0.3 ms. It copies the whole function table.
- `hl_jit_init`: 0.09–0.16 ms. It allocates `jit_debug` for every function.
- `patch_live_publish`: 0.014 ms.

These are all whole-module costs, but they add up to about 3 ms.

Not measured: `hl_patch_read` on a large real patch. The merged-live-check `.hlp` was 6.95 MB, made of a 623 KB
functions section, 2.45 MB of debug data and 3.88 MB of source snapshots. That file was overwritten by another
investigator's build before I could copy it. From the r6 numbers, everything except the type hash fits in about
10 ms: 1,896 ms `live.patch` minus about 1,885 ms of hash.

## Fixes (most effective first)

1. **Index the string table inside `hash_type_prefix`.** Build a content→first-index map once per call, or keep one
   on the module. This keeps the HLP format and the hash value (verified), and needs no compiler change.
   - Effort: about 40 lines of C in `hlpatch.c`, plus a test that compares against the linear result.
   - Gain: about 1,875 ms per patch (1,885 → ~10 ms), measured in the harness.
2. **Index the globals as well** (an address→index map, or a sort of `globals_indexes`).
   - Effort: about 15 lines.
   - Gain: about 3 ms.
3. **Cache the prefix hashes on the module and extend them incrementally.** A patch must have `base_*_count` equal to
   the module's current counts (`src/hlpatch.c:871`), so the expected hash is always the hash of the whole current
   table. FNV is streaming, so `m->type_prefix_hash` (and the int, float and string hashes) could be computed once at
   load, or lazily, and extended over only the appended entries after each commit. Patches can only append
   FUN/ABSTRACT/REF/NULL types (`validate_patch_types`). Per-patch hashing then becomes O(appended).
   - Effort: moderate (about 60 lines). It needs a check that hashed type data, such as `global_value` pointers,
     never changes after load.
   - Gain: removes even the ~7 ms left after fix 1. It also takes the remaining string hashing off the patch path.
4. **Optional, larger: stage patches off the UI thread.** Read, validate and JIT on a worker, and run only the commit
   (the slot patching and publish, which are under 0.1 ms) on the UI thread. After fixes 1–3, the remaining cost is
   about 5 ms, so this is probably not worth doing for freeze reasons alone.
5. **Optional cleanups**, about 1–2 ms per patch in total:
   - Stop re-copying all strings on every patch. Append to a growable table instead.
   - Stop copying the whole function table into `layout.functions` on every patch.

## Files

All paths are absolute under
`C:/Users/corbi/AppData/Local/Temp/claude/C--Users-corbi-projects-exosuit/098c8693-f262-4636-ade8-8878a23492f9/scratchpad/investigations/patch-freeze/`:

- `bin/hl.exe`: the instrumented harness VM.
- `build.cmd`: rebuilds it from `hl/src`.
- `env.sh`: sets PATH, takes the lock and runs the harness.
- `hlpatch-instrumented.diff`, `hlruntime-instrumented.diff`: the instrumentation, including the `HLP_FAST`
  indexed-lookup prototype.
- `mkhlp.py`, `hlp.py`: HLP builder and parser.
- `p12.hlp`, `p23.hlp`, `p34.hlp`: the test patches.
- `mod/live.hl`, `mod/live.hl.hli`: the module snapshot.
- `run-linear.txt`, `run-compare.txt`, `run-fast.txt`: raw output of the runs.
- `win.pftrace`, `pf.py`, `q2.py`, `q4.py`: the r6 trace window and the decoder and queries.

To reproduce, run `. env.sh; lock; run "$W\p12.hlp" "$W\p23.hlp"; unlock`. Add `HLP_FAST=1` or `HLP_COMPARE=1` to try
the fix.
