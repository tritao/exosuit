# Review of "compiler-multicore": what it would take to run the Haxeon compiler on multiple cores

Key: `compiler-multicore-verify`. Date: 2026-10-25. Adversarial review of `investigations/compiler-multicore.md`.
No repository files were changed. One measurement (about 75 s) was made while holding the measurement lock.
The bench source and outputs are in `investigations/compiler-multicore-verify/` (`AllocBench3.hx`, `ab3.txt`, `ab-orig.txt`).

**Verdict: partly holds.** The two single-threaded findings are real: the frontend restart and the O(n^2) `decodeString`. The code, the logs and the arithmetic all support them. But several numbers are overstated:

- The restart fix's gain counts parse work that is not thrown away.
- The allocator ceiling is optimistic, because allocations over 40 bytes never use the per-thread buffers.
- The Amdahl model counts stop-the-world GC time as work that can run in parallel.

## Confirmed

- **The restart exists.**
  - `FrontendCompilation.run` calls `includeTypedRuntimeDependencies` and, if that adds a dependency, runs `return run(context, entryModule, token, rollbackModules, snapshotDoneAt, ...)`. The code is at `src/compiler/compilation/FrontendCompilation.hx:174-175`; the report cites 179-180, which is off by 5 lines.
  - The restarted call passes on the original start time, and `CompilationPipeline.hx:154` computes `frontendGraphMs = frontendGraphDoneAt - frontendStartedAt`. So the first pass is reported as `graph`.
  - On the second pass, modules already have `ast != null` (`FrontendCompilation.hx:103`), so parsing is skipped. That explains `parse=4.19`.
  - The restart's condition is in `includeTypedRuntimeDependencies` at `:784-814`, and the cited line is accurate.
- **Allocation accounting** (`merged-live-check/run.log:183-184`):
  - The cold build's phases that do not overlap add up to 13.39 + 426.47 + 4428.21 + 657.40 + 69.40 + 1399.33 + 28.38 = 7022.6 MB. The driver reports `compile-bytes=19287455560`, which leaves a 12.26 GB gap.
  - GCs: the phases account for 11 and the driver reports 69. GC time: the phases account for 2185.5 ms and the driver reports 4772.92 ms.
  - The size of the gap (12.3 GB) matches one parse (about 8.1 GB, from the harness) plus one semantic and typing pass (0.43 + 4.43 GB) = 12.96 GB. This strongly supports exactly one restart for graphical.
- **Incremental control** (`run.log:209-210`): the phases add up to 3449.9 MB against `compile-bytes=3479142656`, which is 99.2%, not 99.5%. That figure only holds with `patch-bytes=427 MB` counted.
- **`decodeString` is O(n²).** `Parser.hx:2630-2643` uses `out += c`. `SetiIconData.hx` has one 75,491-character line, the base64 font. The sum of 2 bytes x k over k up to 75,491 is about 5.7 GB. So the real allocation for that file is about 5.7-6.0 GB, not "more than 2 GB". This also matches the parser total of 8109 MB, which is about 6.0 + 2.0 + 0.124 GB.
- **`perfile.tsv` sums:** the 852 other files total 122,615 us and 124,163,016 bytes. This is exact.
- **Harness reruns** (`ab-orig.txt`): the investigator's `allocbench.hl` reproduces within 3%. The no-allocation loop takes 202/106/54/31 ms on 1/2/4/8 threads. The `Node` allocation loop takes 2783/2189/1923/2049 ms.
- **Code citations that check out:**
  - `GC_TLAB_RUN 2048` and the refill under `gc_global_lock` (`gc.c:229`, `gc.c:1013-1033`).
  - `GC_MAX_MARK_THREADS 4` and `HL_GC_THREADS` (`gc.c:101-105`, `gc.c:1727-1732`).
  - The JIT inline allocation path only on Linux x86-64 (`gc.c:963`).
  - The single `haxeon.compile` thread (`CompilerServer.hx:157-166`).
  - The worker with `HL_GC_MARK_THRESHOLD` 0.4 (`CompilerClient.hx:218-247`).
  - The sequential stable IDs in `HlFunctionCache.update` (`:131-148`).
  - The `declarationOwners` copy per parse (`ModuleAnalyzer.hx:60`).
  - The `IrGenerator` statics (`:46-113`).
  - "metadata" really is `typeClassBodies` (`ProgramTyper.hx:210-216, 274`).

## Problems

1. **The restart fix's gain is overstated as a standalone figure.**
   - The first pass's parse results are kept: the ASTs survive, which is why the second pass shows `parse=4.19`. What is thrown away is the first semantic and typing pass, about 1.2 + 8.5 s plus its GC.
   - On its own, removing the restart saves about 17.4 s minus the first-pass parse (about 3-6.5 s with today's `decodeString`), so about 10-14 s, not "about 15 s".
   - "About 15 s" holds only together with the `decodeString` fix. The combined 33 s to 14-16 s estimate is still consistent.
   - The agent figure ("about 2.7 s of 4.9 s") assumes the whole `graph=2680.18` is recoverable. Parsing and loading 402 sources stays.
   - Agent arithmetic: the semantic + typing pass is about 1.29 s. The allocation gap is 818 MB against about 731 MB for one semantic + typing pass. So there is one restart, and about 1 s of the agent's graph time is unexplained, possibly one-time warm-up. The recoverable part is more like 1.3-1.6 s.
2. **The allocator ceiling of "about 1.3-1.5x" is optimistic, and fix D misses the biggest contention case.**
   - The per-thread buffers serve only sizes up to `GC_SIZES[GC_FIXED_PARTS-1]` = 40 bytes (`allocator.c:49,55`; `gc_tlab_thread` at `gc.c:954`). Every larger allocation takes `gc_global_lock` (`gc.c:1069`). When that lock is contended, the thread also runs `gc_save_context` (`gc.c:356-360`).
   - **Measured** (`ab3.txt`): 80-byte objects take 3317 ms on 1 thread, 11126 ms on 2, 17254 ms on 4 and 26299 ms on 8. That is 8x slower on 8 threads, not merely flat. 24-byte objects on the same run: 2877/2245/1953/2054 ms.
   - Average allocation size in the compiler (bytes / count, `run.log:183,209`):

     | Phase | Average |
     |---|---|
     | typing-lowering | 37 B |
     | ir-assembly | 41.6 B cold, 54 B per edit |
     | backend-functions | 43 B |
     | backend-assembly | 54 B cold, 56 B per edit |
     | backend-debug | 186 B |
     | whole edit compile | 51 B |

     A large share of allocations in exactly the phases proposed for split A and split B therefore bypass the buffers.
   - The only real-code measurement, the parser, is skewed toward small objects, so it cannot stand in for the backend. Splits A and B could gain nothing or even slow down on today's allocator.
   - Fix D proposes larger runs, statistics per thread, optional pages per thread and the inline path. It does not include extending the per-thread buffers to larger size classes and variable-size allocation, which this data says is required.
   - The "about 5M lock acquisitions" figure is a lower bound for a second reason too. `gc_alloc_fixed_run` (`allocator.c:284-335`) returns `min(free span, want)`, so after a GC a fragmented free list hands out runs much shorter than 2 KB. Lazy `flush_free_list` also runs under the lock (`allocator.c:292-293`).
3. **The Amdahl model counts stop-the-world GC as parallel work.**
   - The phase times include GC: typing-lowering has 1350 ms of GC, backend-assembly 466 ms, ir-assembly 220 ms and semantic 149 ms (`run.log:183`).
   - Each edit has `compile-gc-ms=955.47` plus `encode-gc-ms=353.18` (`run.log:210`).
   - Marking stops every thread and uses at most 4 mark threads. So about 2 s of the cold "12.3 s parallel" and about 1.3 s of the edit's "about 7 s parallel" are not parallel work. Both P and the ideal speedups are overstated.
4. **"Parsing after the fix is about 0.26 s" counts only the lexer and parser.**
   - In the compiler, `ModuleAnalyzer.parse` also copies the whole `declarationOwners` map for each module (`:60`, O(modules x declarations)), runs `indexDeclarations`, and builds a `SemanticModel` for each module (`:57-64`).
   - The edit build shows `parse=709.33` with `graph-gc-ms=294.68` (`run.log:208-209`) for a handful of reparsed files.
   - The harness's two parse totals also disagree, and the report does not reconcile them: `ParseSteps` gives a parser total of 6291 ms, while the files in `perfile.tsv` sum to about 2.95 s. That points to GC and live-heap effects that differ from inside the worker.
5. **The cold build may not have run alone.** `run.log:160-180` shows the MSBuild native build of `nativekit_ui` immediately before the cold compile's timing lines. If they ran at the same time, the cold timings are inflated. This was not checked.
6. **Minor points.** The restart is at `FrontendCompilation.hx:174-175`. Seti's allocation is about 6 GB, not "more than 2 GB" (the counter wrapped). The incremental build's coverage is 99.2%.

## Missing angles

- **GC tuning is a cheap single-threaded lever.**
  - The cold compile spends 4.77 s in 69 GCs. Each edit spends 0.96 s in compile GC plus 0.35 s in encode GC, about 300 ms per GC on a live heap of about 1.5 GB.
  - Raising `HL_GC_MARK_THRESHOLD` (now 0.4) or `HL_GC_MIN_TRIGGER` for the resident worker, or keeping long-lived compiler state out of repeated marking, could save about 1 s per edit without any threading.
- **The restart can recurse.** `run` can restart more than once if the second pass finds yet another dependency. Only allocation arithmetic shows a single restart for these two projects. The proposed fix of seeding roots should be checked against repeated restarts and against dependencies that persist across worker restarts: they are stored in `state.dependencies` in memory only.
- **Larger objects need the per-thread buffers before any split.** Extending `GC_TLAB` beyond the 5 smallest size classes, or giving each thread its own allocator for variable sizes, should come before split A or split B, not as "optional".
- **Parallelism across projects already exists.** Each project has its own worker process (`CompilerClient.hx:41-45`). Overlapping the agent and graphical compiles is free if the executor schedules them together, which still needs checking.
