# Review of `compile-slow`: why a 3-function edit takes 8-16 s to compile

Key: `compile-slow-verify`. Date: 2026-10-25. No repository files were changed. Experiments ran on copies in
`investigations/compile-slow-verify/`, with the measurement lock held (15:01-15:02 and 15:04-15:06).

## Verdict: partly holds

The diagnosis holds, and two new experiments make it stronger:
- The 150 spurious functions are real.
- Path-based re-lowering is real, and it is the biggest single defect.
- The whole-file `sourceHash` is real.

Three parts of the fix plan are wrong or overstated:
1. **Fix 2 (sourceHash) helps much less than claimed for a normal edit.** Most edits change the file's length, and
   then half of the module's functions still differ by shifted offsets.
2. **Shrinking the patch will not reduce the 1.9 s live-host apply.** The `patch-freeze` investigation measured that
   cost as fixed per patch.
3. **Fix 4's gain is largely already counted in fix 1.** The full `.hl` encode is slow mostly because of the
   unnecessary re-lowering.

## 1. Numbers re-checked against source data (all match)

- **merged-live-check `run.log`:**
  - l.207 `driver phases (ms): prepare=172.57 compile=8467.45 encode=958.22 write=201.54`.
  - l.208 `ir-assembly=2551.58 ... incremental-backend=2993.45 (... verify=575.72 ... lower-functions=1726.24 lower-debug=475.4) patch=559.75`.
  - l.213 `compiler: 9810 ms, 3 functions retyped`.
  - Cold compile: l.182 `ir-assembly=2379.01`, `incremental-backend=3082.22`.
  - Overflow: l.212 `worker allocations: bytes=-2147483648 ... heap=-2147483648`.
- **r4b, r5 and r6 compiler totals:** 9083/7536/7808, 16461/12748/7967 and 9909 ms (`run.log` l.120/133/146,
  l.160/173/186 and l.154).
- **driver.log:** `edit 1 applied after 14.5s (patches 1, reload lines 0)`.
- **Probe logs** (`compile-slow/out/worker-instr*.log`):
  - No-op: `sameBytesThrows=150 [IR block has no terminator => 150] changed=150`, then
    `selected(affected)=7474 of 13496` and `patch bytes=5622806 changedFunctions=150`.
  - Edit: `selected(affected)=8315` and `patch bytes=6954923 changedFunctions=629`.
- **Code citations, all correct:**
  - `IrInliner.hx:270-277`: sameBytes catches and returns false.
  - `IrFunctionStateCodec.hx:101-102`: throws when the identified encoding meets a null terminator.
  - `IrFunctionStateCodec.hx:206`: writes `sourceHash`.
  - `SourceProvenance.hx:33` and `Source.hx:17-24`: FNV hash of the whole file.
  - `HlLower.hx:85-95`: path-based selection.
  - `ModuleSourceLoader.hx:172-192`: `readDirectory` per path segment, with the comment at `:12-13`.
  - `CompilerDriver.hx:76` and `:115`: full `.hl` write and the SHA-256 `.build-id`.
  - `WatchRun.hx:28` (`Sys.sleep(0.35)`) and `:49-55` (settle loop).
  - `CompilerServer.hx:80-81`: `Math.round` gives a 32-bit Int, hence the overflow.
  - `CompilerClient.hx:170`: the worker is built with stock `haxe -cp ... -hl ... -main`.

## 2. Experiment A: what makes the ExosuitApp functions compare different (the investigator's open inference)

**Method:**
- I copied the investigator's instrumented compiler to `src-v/`.
- I added `IrFunctionStateCodec.probeIgnoreHash`, which writes 0 instead of `location.sourceHash`.
- For each function where `sameBytes` is false, the probe re-compares the two versions with the hash zeroed.
- It also dumps ExosuitApp diffs. The original probe deliberately skipped ExosuitApp
  (`fn.name.indexOf("ExosuitApp") < 0`), so it never looked at those functions.
- Steps: cold, `ez` (`"Spacez: "`, same length as the original), then `e1` (`"Spaces1: "`, one byte longer than
  `ez`).

**Results** (`compile-slow-verify/out/worker-v.log`):

```
ez: changed=624 exoDiff=475 sameIgnoringSourceHash=469 exoSameIgnoringSourceHash=469
e1: changed=627 exoDiff=478 sameIgnoringSourceHash=230 exoSameIgnoringSourceHash=230
```

- **Same-length edit: confirmed.** 469 of the 475 ExosuitApp functions differ only in `sourceHash`. The other 6 are
  the edited code. `out/exo-2-*.txt` shows identical instructions and offsets, with `h-1143685552` against
  `h725359073`.
- **Length-changing edit, which is the normal case: only 230 of 478 differ only by hash.** The other 248 differ in
  absolute offsets: instruction spans and binding `scopeStart`/`scopeEnd` move by +1 (`out/exo-3-*.txt`, for example
  `179668-179677` becomes `179669-179678`). The edit is at byte 97,352 of the 196,363-byte file, so roughly every
  function after it moves.
- **Consequence for fix 2:** leaving out or localizing `sourceHash` alone cuts only the functions before the edit
  point. An edit near the top of a file would gain almost nothing. To make the comparison truly edit-local, positions
  must also be stored relative to the function, or ignored in the "changed" test and refreshed separately in the debug
  data. Either way the runtime would need to accept debug-only updates.

## 3. Experiment B: lower only the regenerated functions (the second half of fix 1)

**Method:**
- `src-f1/` is the same copy, with `HlLower.hx:92` changed to select only `regeneratedNames`.
  `touchesSourcePath` is dropped.
- I built both workers and ran each through cold, e1, e2 and e3 back to back while holding the lock.

| run | e1 wall | e2 wall | e3 wall | incr-backend | lower-functions | verify | encode (full .hl) |
|---|---|---|---|---|---|---|---|
| base (current) | 8,829 | 7,905 | 7,560 | 2,208-2,745 | 1,245-1,558 | 494-580 | 622-839 |
| regenerated only | 6,512 | 5,776 | 6,019 | 637-792 | 198-277 | 130-146 | 144-289 |

- Functions lowered per edit fell from 8,315 to 629.
- **The mean edit compile fell from 8,098 to 6,102 ms, about 2.0 s or 25%.** This comes from one condition change,
  without the `sameBytes` fix.
- **The output did not change.** The final `live.hl` from both runs is byte-identical (`cmp`, 39,771,478 bytes). The
  `.hlp` files differ in only 4 bytes, at offsets 13-16, which look like a per-session identity; their sizes are
  identical.
- This also explains why re-lowering is wasted work: `HlModuleAssembler.hx:233-242` patches only `regenerated`. The
  other ~7,700 re-lowered functions are never shipped.
- **Encode drops too.** `HlWriterCache` keys encoded bodies by `HlFunction` object identity (`HlWriter.hx:134-138`,
  `HlWriterCache.hx:9`). Every re-lowered function is therefore a new object, which must be re-encoded and
  re-validated. The investigator treats the full `.hl` write as an independent whole-program cost (fix 4, 0.7-1.1 s).
  Once fix 1 is in, it is only about 0.15-0.3 s of encode plus 0.18 s of write.
- **Caveat:** commit 62dc58d2 ("Reuse unchanged HashLink function lowering"), which added `touchesSourcePath`, gives no
  reason for the path rule. Its test only asserts that functions from unchanged files are reused. Three edits gave
  identical output, but layout changes and debug-file-table changes were not tested.

## 4. Problems with the report

1. **Fix 2 is overstated** (see §2). Its stated effect, "the patch shrinks ... to the retyped few plus their
   inliners", holds only for a same-length edit, or for functions before the edit point.
2. **The patch-apply attribution is refuted by `patch-freeze.md`.**
   - That investigation found the 1.9 s is `hash_type_prefix` (`hlpatch.c:393`, a linear string-table scan).
   - The cost is fixed per patch: "One function and three functions cost the same: 1,885 ms vs 1,890 ms".
   - So fix 1's "shrink the patch for the 1.9 s freeze" and fix 2's "most of the live-host patch time" are wrong. A
     smaller patch saves only `hl_patch_read`, about 10 ms.
3. **Fixes 1 and 4 overlap more than the report says** (see §3). Fix 4's extra gain after fix 1 is about 0.3-0.5 s
   (encode leftover, 0.18 s write, 0.1 s build-id), not 0.7-1.1 s.
4. **The description of the selection is imprecise.** The report says it re-lowers "every function in any file a
   changed function comes from". In the code (`collectSourcePaths`/`touchesSourcePath`, `HlLower.hx:443-470`), the
   paths include the files of every inlined callee in a regenerated function. A function is selected if any of its
   instructions, including inlined ones, point at any of those paths. That is how 150 try/catch lambdas expand to
   171 paths and 7,474 functions.
5. **The "dumps are identical" evidence is weak, and "drop dead blocks" may be unsafe.**
   - The text dump prints each `IrValue` as its class name (`probeText` uses `Std.string(ins.value)`), so it does not
     show value wiring. The throw alone does explain the 150, so the conclusion stands.
   - In the dump (`diff-2-1-a.txt`), the empty unterminated block is the target of `BeginTry(1,2)`. Deleting it would
     leave a dangling reference. Terminating it (for example with an unreachable terminator) is the safe option.
6. **Fix 1's two halves are not ranked.** The path-selection half alone gives about 2.0 s, as measured. The
   `sameBytes` half removes 150 functions from the patch and the lowering. Lowering 629 functions costs only about
   0.2-0.3 s, so that half mainly shrinks patch-encode work and the source-snapshot count.

## 5. Angles the report did not consider

- **GC cost scales with the retained heap, not just allocation.**
  - `heap` overflows the 32-bit field, so the live heap is over 2 GB. It holds the cached IR, `HlFunction`s, encoded
    bytes and debug caches for 13.5k functions.
  - Each major GC (3 per compile, about 320 ms each) marks all of it.
  - Fix 1 cuts allocation, and so how often GC runs, but not the cost of each GC.
- **The runtime is HashLink JIT bytecode from a stock `haxe -hl` build** (`CompilerClient.hx:170`, with no
  optimization defines). HL/C compilation of the worker could plausibly be faster. Not measured.
- **The patch phase (0.4-0.9 s) is unexplained.** Part of it is that the patch embeds every referenced source file:
  3.88 MB of the 6.95 MB `.hlp` is source snapshots (from patch-freeze). The 150 spurious functions pull in snapshots
  for 171 files.
- **Why 2,873 functions miss the inliner memo on a no-op is not explained.** The memo requires the same `source`
  object (`IrInliner.hx:288-292`). The report mentions only `__init$partN` and dependency identity.

## Files

- Probe copies: `compile-slow-verify/src-v/` (sourceHash probe) and `compile-slow-verify/src-f1/` (regenerated-only
  lowering).
- Workers: `worker-v.hl` and `worker-f1.hl`.
- Harness: `drive.py`, the investigator's harness pointed at their `gsrc` copy.
- Data in `compile-slow-verify/out/`:
  - `worker-v.log` and `exo-*.txt`.
  - `results-base.json` and `results-f1.json`.
  - `live-base.hl` and `live-f1.hl`, which are byte-identical.
