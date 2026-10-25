# Why a one-string edit takes 8-16 s to compile (investigation `compile-slow`)

Date: 2026-10-25. Repos read at exosuit `main` c084fd3 and haxeon `main`. No repository files were changed. All
experiments used copies in the scratch directory `investigations/compile-slow/`.

## Answer in brief

- **Most of the incremental time is a fixed cost that does not depend on the edit.** A request to a warm compile
  server with **no source change at all** takes 7.2-8.1 s. The one-string edit in `ExosuitApp.hx` takes 8.0-8.6 s
  (measured in a quiet scratch harness, 2 to 4 runs each). The change itself accounts for well under 1 s of that.
- The compiler runs as **compiled HashLink bytecode** (stock Haxe `-hl`, run by `hl.exe` with the JIT), not under the
  Haxe interpreter. It runs on one thread. The interpreter is not the cause.
- **Three defects make each compile redo work across most of the program:**
  1. **150 functions count as "changed" on every compile, even with no edit.** `IrInliner.sameBytes` decides
     whether a function changed by encoding it with `IrFunctionStateCodec`. For 150 functions the encoder throws
     "IR block has no terminator", so `sameBytes` returns false (`IrInliner.hx:270-277`, codec `:102`). These 150
     functions are re-lowered on every compile and patched into the app on every compile. A no-op compile writes a
     5.6 MB `.hlp` with `changedFunctions=150`.
  2. **The backend re-lowers every function in any file that a changed function comes from**
     (`HlLower.lowerStableMeasured`, `HlLower.hx:85-95`). The 150 spurious functions touch 171 files, so a no-op
     compile re-verifies and re-lowers **7,474 of 13,496 functions**. The edit compile does the same for **8,315**.
     A cold compile lowers 13,496, so most of the cold lowering cost is paid again.
  3. **Editing one file changes all 475 IR functions from that module.** A same-length edit (`"Spacez: "`) also
     changes 475 ExosuitApp functions, so shifted positions are not the cause. The likely cause: every IR source
     location stores a hash of the **whole file** (`SourceLocation.fromSpan` uses `span.file.contentHash()`,
     `SourceProvenance.hx:33`; `Source.hx:17-24`), and the codec compares it (`IrFunctionStateCodec.hx:206`). As a
     result, the 3-function edit ships **629 functions and a 6.95 MB patch** to the live app.
- **Several costs are paid in full on every compile:**
  - The inliner re-inlines 2,873 functions and re-encodes about 2,264 pairs of functions to compare them (1.0-1.3 s).
  - Import resolution makes 6,000-8,000 `readDirectory` calls to check that file names match in case (0.4-0.6 s).
  - The full 40 MB `.hl` is re-encoded and written, then SHA-256-hashed for `.build-id` (0.6-1.0 s).
  - Semantic canonicalization and invalidation (0.6-1.2 s), and IR program assembly (about 0.4-0.6 s).
  - About 1 s of major GC for 3.4 GB allocated per incremental compile.
- **Outside the compiler, save-to-patch adds about 4-5 s:**
  - The watch poll and settle loop: about 0.9 s.
  - The CLI re-resolving the project and SHA-256-hashing 871 inputs, including the 25 MB `haxe.exe`, twice per
    rebuild: about 1.1 s.
  - The live host applying the 6.95 MB / 629-function patch on the UI thread: about 1.9 s (finding 20).
  - The driver's own polling granularity.

## 1. Data: every incremental compile in the run logs

All are warm-server compiles of the one-string edit (`"Spaces: "` changed to `"SpacesN: "`), reported as "3
functions retyped". Values are ms, taken from the `driver phases` / `compiler phases` lines.

| run (run.log line) | compiler total | prepare | compile | frontend (graph / semantic) | typing | ir-assembly | incr-backend | patch | encode | write | compile GC ms |
|---|---|---|---|---|---|---|---|---|---|---|---|
| r4b #1 (l.114-120) | 9,083 | 171 | 7,773 | 1,372 (423 / 949) | 599 | n/a | n/a | n/a | 605 | 526 | 1,029 |
| r4b #2 (l.127-133) | 7,536 | 156 | 6,638 | 1,166 (566 / 600) | 491 | | | | 557 | 176 | 661 |
| r4b #3 (l.140-146) | 7,808 | 182 | 6,804 | 1,526 (628 / 897) | 477 | | | | 610 | 196 | 1,016 |
| r5 #1 (l.154-160) | **16,461** | 465 | 14,028 | 2,406 (1,193 / 1,213) | 841 | | | | 1,673 | 282 | 1,035 (+686 encode) |
| r5 #2 (l.167-173) | 12,748 | 328 | 10,734 | 2,240 (1,225 / 1,016) | 800 | | | | 1,352 | 316 | 994 (+537) |
| r5 #3 (l.180-186) | 7,967 | 252 | 6,851 | 980 (454 / 526) | 594 | | | | 666 | 190 | 735 |
| r6 (l.148-154) | 9,909 | 484 | 8,150 | 1,231 (507 / 724) | 617 | | | | 983 | 275 | 843 (+416, +302 prepare) |
| merged-live-check (l.207-213) | 9,810 | 173 | 8,467 | 1,459 (754 / 705) | 682 | **2,552** | **2,993** | 560 | 958 | 202 | 955 (+353) |

The merged-live-check line breaks `compile` down further:
- snapshot 11, candidate 31, frontend 1,459, typing 682, **ir-assembly 2,552**, abi 128.
- **incremental-backend 2,993**: lower-functions 1,726, verify 576, lower-debug 475.
- patch 560.

In the cold compile of the same run (l.181-187):
- ir-assembly is 2,379 (**less** than incremental) and incremental-backend is 3,082 (about the same).
- Only frontend (18,658, of which graph 17,428) and typing (8,543) shrink.

The large spread (7.5-16.5 s) tracks machine load:
- r5 ran with the instrumented host and a 1.3 GB profiler capture alongside it.
- Those runs show higher GC milliseconds (`encode-gc-ms=686` etc.).

## 2. Reproduction in scratch (quiet machine, measurement lock held)

**Harness**:
- Files: `investigations/compile-slow/drive.py`, `worker.hl`, `request-args.json`.
- `worker.hl` is `compiler.tools.CompilerServer`, built exactly as `CompilerClient.ensureArtifact` builds it
  (`haxe -cp haxeon/src -hl ... -main compiler.tools.CompilerServer`).
- It is started like the real worker: `hl.exe worker.hl <state>`, cwd haxeon, `HL_GC_MARK_THRESHOLD=0.4`.
- The request carries the exact arguments the build lowers for `graphical/haxeon.json --live`. They were obtained by a
  read-only probe (`probe/Probe.hx`) that calls `PlanLowerer.lower`.
- Only `--output` and the graphical source root were changed: they point at a scratch copy of `graphical/src`, so edits
  never touch the repo.

**Results** (run t7, `out/results-t7.json`):

| request | wall ms | compile | frontend (graph/semantic) | typing | ir-assembly | incr-backend (lower-fns / verify / debug) | patch | encode | write |
|---|---|---|---|---|---|---|---|---|---|
| cold | 37,458 | 36,122 | 20,498 (19,143 / 1,356) | 9,383 | 2,680 | 3,423 (1,772 / 899 / 539) | 0 | 867 | 203 |
| **no change** | **8,095** | 7,073 | 1,180 (4 / 1,176) | 364 | 2,244 | 2,700 (1,650 / 484 / 362) | 386 | 608 | 200 |
| edit "Spaces1" | 8,320 | 7,352 | 1,138 (496 / 641) | 863 | 2,225 | 2,538 (1,041 / 523 / 440) | 417 | 536 | 206 |
| edit "Spaces2" | 8,604 | 7,693 | 1,113 | 600 | 2,211 | 2,656 | 897 | 496 | 198 |
| edit "Spaces3" | 8,006 | 6,906 | 1,063 | 571 | 2,176 | 2,348 | 556 | 666 | 204 |
| no change | 7,199 | 6,013 | 858 | 316 | 2,133 | 1,901 | 628 | 448 | 197 |
| revert | 7,997 | 6,917 | 1,060 | 567 | 2,155 | 2,378 | 558 | 654 | 203 |

Other runs (t1, prof, instr, instr5) agree: no-op compiles take 7.1-8.3 s and edit compiles 8.0-9.2 s.
**The edit adds only about 0.2-0.5 s on top of the no-op cost.**

## 3. Sampling profile of the warm compile (where the 8 s goes)

**Method**:
- The worker ran under `hl --diagnostics 47811 --diagnostics-wait`, recorded by `hlprof-live --sources sampling
  --rate 1000` (`out/worker.hlpc`).
- Request windows were taken from `drive.py` timestamps and exported with `export --format folded --start-ms/--end-ms`.
- The stacks were summarized with `folded.py`, counting only stacks under `CompilerDriver.compile` (1 sample = 1 ms).
- The worker's main thread is idle in `Lock.wait`. All compile work is on one thread.

Edit request "Spaces1" (8,663 ms on the compile thread):

| inclusive ms | what | notes |
|---|---|---|
| 2,370 | `HlLower.lowerStableMeasured` | lowerProgram 1,843 (lowerFunction 1,037, allocation 452, span groups 126) + `IrVerifier.verifyFunctions` 435. **8,315 functions lowered** (probe) |
| 1,844 | `IrInliner.run` | **`sameBytes` 983** + `inlinedVersion` 822 (`inlineCalls` 644). 3,255 functions recomputed, 2,675 `sameBytes` comparisons |
| 674 | `SemanticAssembly.run` | importAliases 160, PurityInference 143, ... |
| 671 | `HlWriter.writeFile` (driver "encode") | writeCode 547 + HlValidator 124: the full 40 MB module |
| 609 | `ModuleSourceLoader.exactPath` (inside parse and semantic) | readDirectory 318, exists 155, isDirectory 128: **7,616 calls, 8,040 readDirectory** (probe) |
| 534 | `HlPatchWriter.encode` | `encodeDebug` 448 (debug rows for 629 functions) |
| 513 | `Typer` → `ProgramTyper.refreshCachedClasses` → `typeClassMethods` | 465; re-types ExosuitApp's methods |
| 454 | "parse" = `ModuleAnalyzer.parse` | real parsing only 17 ms; **importAliases 358 (filesystem probing)** |
| 378 | `IrGenerator.assemble` 195 + `staticInitializersFrom` 103 + `codeFingerprint` 80 | whole-program IR assembly |
| 218 | `CompilerSession.prepare` | reads all 854 sources 3-4 times, lexes the changed one twice |
| 107 | `ContentDigest.makeHex` | SHA-256 of the 40 MB `.hl` for `.build-id` (`CompilerDriver.hx:115`) |
| ~996 | `gc_major` (inside the rows above) | lowerProgram 353, inliner 331, typer 312 |

The no-op request has the same shape (8,238 ms):
- lowerFunction 1,517, `sameBytes` 967, `inlineCalls` 550, exactPath 438, writeFile 611, encodeDebug 333, gc_major 930.

## 4. Root causes in the code

### 4.1 Spurious "changed" functions (no edit needed)

`IrInliner.run` (`IrInliner.hx:236-261`) compares each re-inlined function with the one published last time. It
calls `sameBytes`, which encodes both with `IrFunctionStateCodec.encode` and treats any exception as "different"
(`:270-277`).

An instrumented copy of the compiler (`src-instr/`, counters only) showed, for a no-op request:

```
[probe] inliner functions=13496 memoHits=10623 recomputed=2873 impure=45 sameBytesCalls=2264 sameBytesTrue=2114
        sameBytesThrows=150 [IR block has no terminator => 150] changed=150
[probe] lower regenerated=150 regeneratedSourcePaths=171 selected(affected)=7474 of 13496
[probe] lowered functions=7474 exactPath calls=5936 readDirectory calls=6093 patch bytes=5622806 changedFunctions=150
```

**What this shows:**
- Every one of the 150 "changes" comes from the encoder throwing `"IR block has no terminator"`
  (`IrFunctionStateCodec.hx:102`). Examples:
  - `$lambda:$generic:runtime.Runtime.invoke[layout]<Int>:invoke#0`
  - `$lambda:$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#0:build#17`
  - `$lambda:compiler.ffi.HxiValidator.validateOutputType:validateOutputType#0`
- A text dump of both versions (instructions, provenance, bindings) is identical. The functions did not change; they
  only cannot be encoded.

**Consequences on every compile, edit or not:**
- The 150 functions go into `regenerated`.
- They are re-lowered.
- They are encoded into the patch: 5.6 MB for a no-op.
- They are re-applied by the live host.

### 4.2 Lowering selection by source path

`HlLower.lowerStableMeasured` (`HlLower.hx:74-96`) collects every source path that appears in any regenerated
function's provenance. It then selects every function whose instructions touch any of those paths
(`touchesSourcePath`, `:465`). Those functions are re-verified, and `lowerProgramWithNatives` (`:346-356`) re-lowers
every one of them instead of reusing the cached `HlFunction`.

**Why this is too broad:**
- Re-lowering a whole file is presumably meant to refresh debug positions after that file's text changed.
- But it is applied to paths of functions that changed only through inlining, or, as in 4.1, not at all.
- The edit compile re-lowers 8,315 of 13,496 functions. Lowering costs about 0.13-0.2 ms per function
  (1,037-1,517 ms over 7.5-8.3 k functions), so this is about 1-1.5 s of lowering plus 0.4-0.8 s of verification.

### 4.3 Editing a module republishes the whole module

**Evidence:**
- With the edit, `changed=624` from the inliner, and `regenerated 629` once the 3 retyped functions and 167
  `module-semantic-snapshot` invalidations are added.
- Of these, 475 are ExosuitApp functions, including lambdas and adapters.
- A same-length edit ("Spacez") gives the same 475, so this is not caused by shifted offsets.

**Likely cause (not proven):**
- Every `SourceLocation` stores `sourceHash = span.file.contentHash()` (`SourceProvenance.hx:33`).
- That value is an FNV hash of the entire file (`Source.hx:17-24`), and the state codec compares it
  (`IrFunctionStateCodec.hx:206`).
- So any byte changed anywhere in a file makes every function from that file compare different.

**Result:**
- 629 functions are lowered and patched.
- The `.hlp` is 6,954,923 bytes for a 3-function source change.

### 4.4 Whole-program work that runs on every request

- **Inliner memo misses.** 2,873-3,255 functions are re-inlined per request:
  - The generated initializer functions (`__init$partN`) are rebuilt on every compile (comment at `IrInliner.hx:250`).
  - The memo checks callee identity (`dependenciesCurrent`, `:337-342`).
  - Impure functions (45) are never memoized.

  `sameBytes` then encodes both the previous and the new version of each function: about 1.0-1.3 s per request
  (`sameBytesMs=976..1339`).
- **Case-exact path probing.** On Windows, `ModuleSourceLoader.exactPath` lists the directory for every path segment
  to check case (`ModuleSourceLoader.hx:172-192`). The `missing` cache starts empty for every compile copy (comment at
  `:12-13`). Cost per request:

  | request | exactPath calls | readDirectory calls | time |
  |---|---|---|---|
  | no-op | 5,936 | 6,093 | 0.4-0.6 s |
  | edit | 7,616 | 8,040 | 0.4-0.6 s |
  | cold | 71,768 | 82,071 | |

  Most of the "parse=445 ms" phase is this probing; real parsing is 17 ms.
- **Full module output on every patch.**
  - The driver writes the full 40 MB `.hl` through `HlWriter` (`CompilerDriver.hx:76`): 0.5-0.95 s.
  - It then hashes the file for `.build-id` (`:115`): 0.1 s.
  - It also writes `.functions` (0.8 MB) and `.live.json` (1 MB of identities), even when it publishes a patch.
- **Whole-program assembly.** `IrGenerator.assemble`, `staticInitializersFrom`, `codeFingerprint`, `RuntimeAbi.describe`
  and `PatchPlanner.plan` run over the whole program (`FrontendCompilation.hx:494-525`): about 0.4-0.6 s.
- **Semantic assembly.** About 0.6-1.2 s, mostly canonicalization and invalidation, also whole-program. On a no-op,
  semantic still takes 855-1,176 ms.
- **GC.** About 0.9-1.0 s of major GC per request. Driver `compile-bytes` is about 3.46 GB per incremental compile,
  against 19.3 GB cold.

## 5. Latency outside the compiler (save to applied patch)

**Watch loop** (`haxeon/src/tools/WatchRun.hx`):
- It polls every 0.35 s (`:28`) with a stat snapshot of 1,303 files, which costs 112-136 ms (measured by
  `probe/Probe.hx`).
- After a change it waits 0.5 s and re-snapshots until stable (`:49-55`).
- Expected delay: about 0.3 s to notice the change plus about 0.62 s to settle, so roughly **0.9 s**.

**CLI rebuild before the request is sent** (`HaxeonCli.hx:685-696` → `HaxeonProjectBuild.build`), measured by
`probe.hl` running the same code under `hl.exe`, two runs:

| step | ms |
|---|---|
| project re-resolution (`PackageResolver.resolve`) | 229-250 |
| plan and lower | about 1 |
| compile-action fingerprint (`Executor.fingerprintFor` → `ActionFingerprint.compute`), with a fresh `ContentDigestCache` every build | 579-633 |
| `CompilerClient.run` worker-identity fingerprint, with its own fresh digest cache (`CompilerClient.hx:38-44`) | 279-282 |
| **total** | **about 1.1-1.2 s** |

The compile-action fingerprint SHA-256-hashes 871 inputs: `haxe.exe` (25 MB), `haxeon/src` (406 files, 5.4 MB),
`stdlib`, and the 854 sources. The worker-identity fingerprint hashes `haxe.exe`, `src` and `stdlib` a second time.

**Compile server:** 9.8 s in the merged unprofiled run, 8.0-8.6 s on a quiet machine.

**Live host:** it reads the stamp every tick, then applies the patch. The r6 capture shows `Runtime.patchSet` taking
1,896 ms on the UI thread (finding 20). That patch held 629 functions / 6.95 MB, almost all of them unnecessary
(sections 4.1 and 4.3).

**Driver measurement:**
- `drive.ps1` reports "applied after 14.5 s".
- Its loop walks the process tree with `Get-CimInstance` every iteration, so its detection lags by about 0.5-1.5 s.

**Budget for merged-live-check:**

| part | s |
|---|---|
| watch detection | 0.9 |
| CLI | 1.15 |
| compile | 9.8 |
| patch apply | 1.9 |
| log relay and driver lag | about 0.5-1 |
| **total** | **about 14.3-14.8** |

The total matches the observed 14.5 s.

## 6. Fixes, ranked by expected gain

Gains are for the 3-function edit. They overlap partly, because fewer changed functions also means less GC and a
smaller patch.

1. **Stop false "changed" functions, and restrict re-lowering to files whose text changed** (4.1 + 4.2).
   - Make `sameBytes` handle unterminated dead blocks: drop or terminate dead blocks before encoding, or let the codec
     encode them.
   - Pass `HlLower` the set of source files that actually changed, rather than every path a regenerated function
     touches.
   - Expected effect: lowered functions fall from 8,315 to roughly the edited module.
   - Expected gain: **about 2-3 s of compile** (lower-functions, verify and patch-debug shrink, plus GC).
   - It would also shrink the patch the live host applies; for the 1.9 s freeze investigation, the patch would drop
     from 629 to about 479 functions even before fix 2.
   - Effort: small to medium.
2. **Make IR comparison and provenance edit-local** (4.3).
   - Store a per-span or per-function content hash instead of the whole-file hash, or leave `sourceHash` out of the
     "changed" comparison and refresh debug data separately.
   - Expected effect: the patch shrinks from 629 functions to the retyped few plus their inliners.
   - Expected gain: about 0.5-1 s of compile and most of the live-host patch time.
   - Effort: medium; the runtime's debug and source-snapshot use of `sourceHash` needs care.
3. **Make the inliner incremental** (4.4).
   - Cache the encoding or fingerprint of each published function, so only the new side is encoded.
   - Make the generated `__init$partN` IR stable across compiles (reuse unchanged parts), so their dependents hit the
     memo.
   - Expected gain: **about 1-1.5 s.** Effort: medium.
4. **Live mode: do not write the full module on a patch.**
   - Write only `.hlp` and the stamp. Defer the 40 MB `.hl`, `.build-id` hash, `.functions` and `.live.json`, or write
     them on a background thread or while idle; they are only needed for the next reload or launch.
   - Expected gain: **about 0.7-1.1 s** of time before the patch is published. Effort: small to medium.
5. **CLI: skip fingerprinting in the watch rebuild path.**
   - The compile action always runs after a source change in `--watch`, so there is no point hashing 871 inputs.
   - Also cache the worker identity per CLI process, and reuse the resolved project unless a `haxeon.json` changed.
   - Expected gain: **about 1.0-1.1 s.** Effort: small.
6. **Cache directory listings in `ModuleSourceLoader`** for the length of a compile (or across compiles, checked by
   directory mtime), or use one case-preserving lookup per path.
   - Expected gain: **about 0.4-0.6 s** per incremental compile. On a cold compile it saves 82 k readDirectory calls,
     probably several seconds. Effort: small.
7. **Watch loop: use change notifications instead of polling and a 0.5 s settle.** The Windows file watcher merged on
   2026-10-23 is in the editor, not in `WatchRun`. A short debounce of about 50-100 ms would do.
   - Expected gain: **about 0.6-0.8 s.** Effort: small to medium.
8. **Remaining whole-program floor** (semantic canonicalization and invalidation about 0.6-1.2 s, IR assembly about
   0.4-0.6 s, ABI describe and patch plan about 0.1 s, `prepare` reading every source 3-4 times about 0.2 s).
   - These need real incremental structures.
   - Expected gain: about 1-2 s. Effort: large.

**Expected result:**
- Fixes 1-7 together should bring the edit compile from about 8-10 s to about 3-4 s.
- Save-to-patch should go from about 14.5 s to roughly 5-6 s, before any multicore work.
- Lowering, verification and per-function encoding are independent per function and would parallelize, if more
  cores are wanted later.

## 7. Side observations

- The worker's message prints `worker allocations: bytes=-2147483648 ... heap=-2147483648` (merged-live-check run.log,
  lines after 211). This is a 32-bit overflow in `CompilerServer.hx:80-81` formatting.
- The scratch harness's first edit failed only because the driver script itself dropped a quote. That was my bug, not
  the compiler's.

## 8. Measured vs inferred

**Measured:**
- Every timing table above.
- The probe counters: inliner, lowering selection, exactPath/readDirectory counts, patch bytes.
- The `sameBytes` exception text and count.
- The same-length edit result.
- The CLI step timings.
- The profile attributions.

**Inferred:**
- That the whole-file `sourceHash` is why all 475 ExosuitApp functions compare different. This is consistent with the
  code and the same-length experiment, but no experiment isolated it.
- The gain estimates in section 6. They come from the profile shares, not from implementing the fixes.
- Whether the 1.9 s patch-apply time is proportional to the 629 functions. It comes from another capture and was not
  investigated here.

## Files

Scratch directory: `investigations/compile-slow/`. Raw data is in `out/`.

**Harness and probes:**
- `drive.py`: the scratch compile-server harness.
- `worker.hl` and `worker-instr.hl`: the worker, plain and instrumented; `src-instr/` is the instrumented compiler
  copy.
- `probe/Probe.hx`: the CLI-side timings, which also extracts the request arguments.
- `folded.py`: the profile summarizer.

**Raw data:**
- Profile: `out/worker.hlpc` (profile run `out/drive-prof.txt`, folded stacks `out/folded-*.txt`).
- Timing results: `out/results-t7.json`, `out/results-instr*.json`.
- Probe counters: `out/worker-instr.log` and `out/worker-instr5.log`.
- Changed-function lists: `out/diffs/changed-*.txt`.
