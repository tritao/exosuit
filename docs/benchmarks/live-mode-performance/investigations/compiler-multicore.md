# What it would take to run the Haxeon compiler on multiple cores

Key: `compiler-multicore`. Date: 2026-10-25. This is a design study: it reads code and existing logs, plus four small timing experiments made while holding the measurement lock. No repository files were changed.

## TL;DR

1. **Fix two single-threaded problems first. Together they are worth more than any realistic threading plan.**
   - **The cold build runs the whole frontend twice.** `FrontendCompilation.run` restarts itself from the beginning when typing finds a runtime dependency on a module that is not yet in the graph (`src/compiler/compilation/FrontendCompilation.hx:179-180`). The timers make this hard to see. The restart resets `graphParseMs` and the allocation baseline, but `frontendStartedAt` keeps its original value. As a result, all of the first pass is reported as `graph`. That is why the cold build shows `graph=17427.66 parse=4.19`: a 17 s graph phase that contains only 4 ms of parsing. The allocation counters confirm it (see section 2.2). About 12.3 GB of the cold build's 19.3 GB, 58 of its 69 GCs and about 2.6 s of its 4.8 s GC time belong to a pass whose result is thrown away. The exosuit-agent build has the same pattern: `graph=2680.18 parse=0.38` out of `compile=4857.28`.
   - **`Parser.decodeString` is O(n²).** It builds each string with `out += c`, one character at a time (`src/compiler/syntax/Parser.hx:2630-2643`). Two generated icon-data files hit this. `graphical/src/ui/SetiIconData.hx` takes 2.43 s and allocates more than 2 GB; the counter wrapped. `graphical/src/app/ApplicationIcons.hx` takes 0.39 s and allocates 2.0 GB. Together they allocate about 8.1 GB per full parse. The other 852 files take 0.12 s and 124 MB in the parser.
   - Fixing both should take the editor's cold compile from about 33 s to roughly 14-16 s on one thread. That is an estimate; see section 5.
2. **HashLink's allocator is the ceiling for threading.** I measured plain small-object allocation across threads in the HashLink fork. It speeds up by only 1.27x on 2 threads, 1.48x on 4 and 1.37x on 8. Non-allocating compute on the same machine speeds up 6.7x on 8 threads. The compiler's own parse code speeds up 1.49x on 4 threads and gets slower beyond that: it is 2x slower on 16 threads than on one. GC marking does not cause this; mark time stays at 0.65-0.70 s whatever the thread count. The likely cause is the global GC lock, taken every 2 KB of allocation when a thread's allocation buffer refills (`vendor/hashlink/src/gc.c:229`, `gc.c:1013-1033`). The compiler allocates 19.3 GB in a cold build and 3.5 GB per live edit. Unless the allocator changes, multithreading the compiler tops out at about 1.3-1.5x.
3. **After both fixes, about 74% of a cold build could run in parallel in principle.** The ideal limit is about 2.2x on 4 cores and 2.8x on 8. With today's allocator, a realistic result is about 1.3x. In order of risk, the best places to split the work are:
   - (A) Backend lowering, verification and encoding per function, followed by a deterministic merge of the symbol tables.
   - (B) Turning typed functions into IR per function, plus a wavefront over the inliner's call graph.
   - (C) Typing class bodies in parallel. This needs a redesign of the shared `TypingSession` and is the riskiest.
   - Parsing in parallel is not worth it: after the `decodeString` fix it takes about 0.26 s.
4. **For live edits, more cores is the wrong tool.** The measured edit retyped 3 functions and still took 8.5 s. Most of that time goes to work done over the whole program on every edit:
   - `ir-assembly=2551.58`, which runs the inliner across the whole program
   - `lower-functions=1726.24`
   - `encode=958.22`, which writes the whole module
   - `patch=559.75`

   Making that work proportional to the edit would help far more than an ideal 2-3x from threads. That is the subject of the "why is a trivial change so slow" investigation.

## 1. How the compiler runs today

- **The compiler runs as compiled HashLink code, not in the interpreter.** For `haxeon run --live` the build uses a resident worker. `CompilerClient.run` builds `compiler.tools.CompilerServer` once with the bundled Haxe (`-hl`) and starts it as `hl.exe <worker>.hl <state.json>`, with `HL_GC_MARK_THRESHOLD=0.4` (`src/build/execution/CompilerClient.hx:49-56`, `:218-247`). The worker programs are in `%LOCALAPPDATA%/haxeon/compiler/*.hl` (about 2.18 MB each). The run log confirms this with lines such as `reusing compiler session` and `worker allocations: ...`.
  - The CLI itself runs in Haxe's interpreter (`scripts/haxeon.ps1` runs `haxe --run tools.HaxeonCli`).
  - The interpreter is used for compiling only when the worker cannot be used. On Windows that is when the CLI itself is interpreted (`CompilerClient.hx:28-30`). The one-shot compiled-HL fallback exists only on Linux and macOS (`CompilerClient.hx:192-193`).
- **One compile runs on one thread.** `CompilerServer.serve` handles one request at a time. `compileConnected` starts a single `haxeon.compile` thread so the main thread can watch the socket for a cancelled request (`src/compiler/tools/CompilerServer.hx:139-175`). Apart from `ProcessOutputCapture` (process pipes) and the `CancellationToken` mutex, the compiler has no threading today.
- **Thread support in HashLink:**
  - Haxe's `sys.thread` provides `Thread`, `Mutex`, `Lock`, `Deque`, `Tls` and `FixedThreadPool`/`ElasticThreadPool`.
  - The fork's GC can mark in parallel with up to 4 mark threads (`GC_MAX_MARK_THREADS 4`, `gc.c:101-105`; `HL_GC_THREADS` changes the count, `gc.c:1727-1732`). Collection still stops every other thread.
  - Each thread has small allocation buffers (`GC_TLAB`, `gc.c:223-229`) of only `GC_TLAB_RUN 2048` bytes. Every refill takes `gc_global_lock` and updates shared statistics under it (`gc.c:1013-1033`).
  - Allocations too large for the buffers take the global lock every time (`gc.c:1069`).
  - The JIT's inline fast path for allocation is compiled only on Linux x86-64 (`gc.c:963`). On Windows every allocation is a C call.

## 2. Where the time goes (measured)

### 2.1 Phase timings

Source: `docs/benchmarks/live-mode-performance/runs/merged-live-check/run.log`, cold build at lines 181-184, one-edit rebuild at lines 207-211.

| Phase (ms) | Cold (first build of the worker) | One edit (3 functions retyped) |
|---|---|---|
| driver prepare / compile / encode / write | 201 / **32787** / 792 / 185 | 173 / **8467** / 958 / 202 |
| graph (parse within it) | **17428** (parse 4.19) | 754 (parse 709) |
| semantic (canonicalization) | 1230 (976) | 705 (357) |
| typing/lowering | 8543 (declarations 793, metadata 4000, bodies 166) | 682 (metadata 202) |
| ir-assembly | 2379 | **2552** |
| abi | 79 | 128 |
| incremental-backend | 3082 (verify 830, lower-functions 1578, lower-debug 473) | 2993 (verify 576, lower-functions 1726, lower-debug 475) |
| patch | 0 | 560 |
| GC inside compile | 69 GCs, 4773 ms | 3 GCs, 955 ms |

The r5 and r6 cold builds agree: `graph=17251.8 parse=3.81` and `graph=19679.12 parse=3.94`.

### 2.2 The cold build's first pass is discarded

- **Code path:**
  - `FrontendCompilation.run` takes the start time as an argument; `CompilationPipeline` computes `frontendGraphMs = frontendGraphDoneAt - frontendStartedAt` (`CompilationPipeline.hx:154`).
  - After typing, `includeTypedRuntimeDependencies` (`FrontendCompilation.hx:784-814`) adds any typed runtime dependency whose module is not yet reachable. If it added one, the function calls `return run(context, …)` (`FrontendCompilation.hx:179-180`), which starts the frontend over.
  - The restarted call resets `graphParseMs` and `allocationAtStart`. It also re-runs the graph, semantic and typing phases.
- **The allocation counters confirm the restart.** In the cold build, the phases that do not overlap add up to 7.02 GB:
  - graph 13.4 MB
  - semantic 426.5 MB
  - typing-lowering 4428.2 MB
  - ir-assembly 657.4 MB
  - abi 69.4 MB
  - backend-assembly 1399.3 MB
  - source-snapshots 28.4 MB

  The driver reports `compile-bytes=19287455560`, so **12.27 GB (64%) is not attributed to any phase**. GCs: the phases account for 11, the driver reports `compile-gcs=69`. GC time: the phases account for 2185 ms, the driver reports `compile-gc-ms=4772.92`.
- **The incremental build is a control.** Its phases add up to 3.46 GB against `compile-bytes=3479142656`, which is 99.5%. Everything is accounted for when no restart happens.
- **Inference:** about 17 s of the 32.8 s cold compile is a first pass whose result is thrown away. That pass includes the only real parse of all 854 sources, and the icon-literal problem below accounts for about 8 GB of its allocation. I did not log which dependency triggers the restart. A one-line stderr print at `FrontendCompilation.hx:179` would show it.

### 2.3 Parsing (measured with harnesses that use the compiler's own Lexer and Parser unchanged)

The harnesses are in `investigations/compiler-multicore/harness/` (`ParseSteps.hx`, `ParseFiles.hx`, `ParseBench.hx`, `ParseBench2.hx`, `AllocBench.hx`). Each was built with `.tools/haxe/haxe -hl` and run with `.tools/hashlink/hl.exe`.

- **Parse steps for all 854 files, one thread** (`ParseSteps`):

  | Step | Time | Allocated |
  |---|---|---|
  | conditional compilation | 10 ms | 2 MB |
  | lexer | 157 ms | 136 MB |
  | parser | **6291 ms** | **8109 MB** |
- **Parse per file** (`ParseFiles`, results in `harness/perfile.tsv`):

  | File | Size | Time | Allocated |
  |---|---|---|---|
  | `SetiIconData.hx` | 104,761 bytes | 2,431,535 us | over 2 GB (the counter wrapped) |
  | `ApplicationIcons.hx` | 482,584 bytes, 379 tokens, 4102-character lines of base64 | 391,185 us | 2,006,063,064 bytes |
  | **all other 852 files** | 3.59 MB | **122,615 us** | **124 MB** |
- **Cause:** `decodeString` (`Parser.hx:2630-2643`) uses `out += c` for every character, so each literal costs O(n²) to build. `parseStringExpression` (`Parser.hx:2752-2800`) has the same `literal += character` pattern for interpolated strings. A fast path for literals without escapes (`text.substr(1, len-2)`) or a `StringBuf` makes this linear.

### 2.4 How HashLink scales with threads (measured)

All runs hold the lock; the machine reports `nproc` = 32. Times are wall clock.

| Workload | 1 thread | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| Non-allocating integer loop, 200M iterations | 193 ms | 98 | 52 | 29 | – |
| Small-object allocation (200M x `Node`) | 2784 ms | 2188 | 1875 | 2034 | – |
| Compiler parse (conditional, lexer, parser), 852 ordinary files x 40 rounds | 10447 ms | 7607 | 7013 | 9787 | 21137 |
| Same parse run, GC collections / mark ms | 154 / 651 | 155 / 664 | 155 / 674 | 155 / 699 | – |
| Same, `HL_GC_THREADS=1` | 10539 | – | 6968 | – | – |

- Speedup on the parse workload: 1.37x on 2 threads, 1.49x on 4, 1.07x on 8 and 0.49x on 16.
- With the two icon files included, the parse of 853 files peaks at 1.68x on 4 threads (2814 ms per round down to 1674 ms) and also gets slower at 16 threads.
- GC collections and mark time do not change with the thread count, so marking is not the limit. Contention on the global lock that serializes allocation-buffer refills is the most likely cause; this is inferred, not profiled. With 2 KB refills and 10.4 GB allocated, the parse run takes about 5 million lock acquisitions.

## 3. Shared mutable state, and what needs a deterministic order

Deterministic output matters for live patching. Each slot and stable ID must keep the same meaning from one revision to the next, and an unchanged function should encode to the same bytes so it is not reported as changed.

- **Function order and stable IDs:** `HlFunctionCache.update` assigns slots and `nextStableId++` in the order of `program.functions` (`src/compiler/hl/incremental/HlFunctionCache.hx:131-148`). This step must stay sequential, but it is cheap.
- **Symbol interning in the backend:** `HlLower` interns ints, floats, strings, types and globals into the shared `HlSymbolTable` in the order it first meets them while lowering functions one by one (`src/compiler/ir/hl/HlLower.hx:346-356`, `internString` / `internType` at `:577-972`). Published indices only grow; the table grows the module's constant pools. Parallel lowering therefore needs a symbol table per function plus a sequential merge in function order. That merge assigns the global indices and rewrites the operands. Its output is identical to today's.
- **Parser:** the parser has no static mutable state. The lambda numbering in `lambdaCounts` belongs to each parser instance. `ModuleAnalyzer.parse` writes to the shared `declarationOwners` and `lookupParses` (`src/compiler/semantic/ModuleAnalyzer.hx:55-66`), so that write would have to happen sequentially after parsing. Line 60 also copies the whole `declarationOwners` map once for every module it parses, which is O(modules x declarations).
- **Typing:** `TypingSession` (`src/compiler/types/typing/TypingSession.hx:34-205`) is one mutable hub. It holds:
  - lookup state: `signatures`, `methodInfo`, `lambdaCache`
  - closure state: `closureConversion`
  - generated types: `anonymousTypes`, `genericSpecializations` (generic code is specialized on demand), `emittedGenericBodies`
  - generated helpers: `wireCodecRequests`, `jsonCodecRequests`, `equalityRequests`
  - analysis results: `purityQueries`, `noReturnQueries`, `runtimeDependencyTracker`
  - naming counters: `functionAdapterCounts`, `substrCounts`

  The counters and the on-demand specialization make generated names depend on the order in which bodies are typed. Static state also exists: `SemanticSignature.anonymousSpellings` (`semantic/SemanticSignature.hx:29`) and `WireCodecGenerator.jsonMode/syntheticSpan` (`types/typing/WireCodecGenerator.hx:45,176`).
- **IR generation:** `IrGenerator` keeps 9 static fields (`ir/IrGenerator.hx:46-113`). Each compile sets them before generating any functions (`FrontendCompilation.hx:157-163`, `:225`). After that they are read-only, so threads could share them safely. The real constraint is that `generateFunction` results are written into `ModuleState` through `context.writableState`, a copy-on-write rollback snapshot (`FrontendCompilation.hx:240-277`). Workers should return their results, and one thread should then write them into the module state in order.
- **Inliner:** `IrInliner.inlinedVersion` works recursively, finishing callees before their callers, and keeps a memo (`ir/IrInliner.hx:230-310`). Running it in parallel needs a schedule that follows the call graph: process strongly connected components (groups of mutually recursive functions) level by level, then publish in a fixed order.
- **Other:**
  - `CancellationToken.check()` takes a mutex on every call. It is called inside many loops, so with workers it becomes contention.
  - `AllocationMeter` reads process-wide GC counters, so phase attribution blurs once phases overlap.
  - Haxe `Map` iteration order on HashLink depends on the order of inserts. The code sorts names in most places, for example `names.sort`, `regenerated.sort` and `cachedNames.sort`. Workers must never insert into shared maps.
  - Error reporting must stay in a fixed order: report the first error in program order, not whichever worker hits one first.

## 4. Candidate places to split the work

All gain figures below come from the merged-live-check cold build after both single-threaded fixes. They are ideal speedups unless stated otherwise.

### A. Per-function backend lowering, verification, debug spans and encoding (recommended first)

- **What it covers:**
  - `IrVerifier.verify` (830 ms)
  - `lowerFunction` (1578 ms)
  - the debug span groups (473 ms)
  - the driver's `encode` in `HlWriter` (792 ms cold, 958 ms per edit)

  That is about 3.6 s of cold time and about 3.4 s of each edit.
- **Changes needed:**
  - Give each function its own symbol table, then merge sequentially in function order.
  - Make the shared parts of `HlLower` (`code`, the type and index maps) read-only, or give each worker a copy.
  - Encode each function's bytes separately and concatenate them in order.
- **Determinism:** the merge in function order reproduces today's indices exactly. This can be proven by comparing `.hl` output byte for byte on the corpus.
- **Effort:** about 1-2 weeks.
- **Gain:** about 2.7 s cold and about 2.5 s per edit with 4 ideal cores. With today's allocator, at about 1.5x, it is closer to 1.2 s.

### B. IR generation per typed function and post-inlining IR passes

- **What it covers:**
  - `IrGenerator.generateFunction` for each typed function (`FrontendCompilation.hx:263-270`). The `publication-functions` phase allocates 1.86 GB in the cold build.
  - The part of `ir-assembly` spent running passes on each function (2379 ms cold, 2552 ms per edit).
- **Changes needed:**
  - Workers return their results; one thread writes them into `ModuleState` in order.
  - The inliner needs a schedule over strongly connected components of the call graph, with its memo merged deterministically.
- **Effort:** about 1-2 weeks.
- **Gain:** roughly 2-3.5 s cold at 4 ideal cores.

### C. Typing class bodies in parallel (the `metadata` phase, 4000 ms cold)

- **Changes needed:**
  - Split `TypingSession` into read-only declaration data plus results per worker.
  - Make generic specialization a separate pass: collect requests, then specialize in sorted order.
  - Derive the names of generated adapters, `substr` helpers and anonymous types from content or position instead of counters.
  - Merge purity, no-return and runtime-dependency facts deterministically.
- **Effort:** 4-8 weeks. The risk is high, because almost every typing component reaches into the session.
- **Gain:** up to about 3 s cold. Little for edits, where typing is about 0.7 s.

### D. A prerequisite in HashLink: an allocator that scales

- **Changes needed:**
  - Make the allocation-buffer runs much larger, for example 32-64 KB instead of 2 KB.
  - Keep allocation statistics per thread.
  - Consider giving each thread its own pages, so refills do not take the global lock.
  - Port the JIT's inline allocation path to Windows x64.
- **Effort:** 1-3 weeks of C work in `vendor/hashlink/src/gc.c`. It needs careful testing against the GC's mark and sweep rules.
- **Why it matters:** without it, A and B deliver about 1.3-1.5x on their phases at best.

### Not worth doing

- **Parallel parsing:** about 0.26 s total once `decodeString` is fixed.
- **Parallel semantic canonicalization:** 976 ms cold and 357 ms per edit. Possible later, but it touches the shared `SemanticWorkspace` and alias tables.
- **Splitting across processes:** each project already compiles in its own worker, but that does not help the single 854-module editor build.

## 5. Amdahl estimate (inference)

**Cold build, single pass, after the parse fix.** About 15.4 s compile plus 0.8 s encode, 0.2 s write and 0.2 s prepare, so about 16.6 s in total.

Work that could run in parallel in principle:

| Work | Time | Share assumed parallel |
|---|---|---|
| canonicalization | 0.98 s | all |
| class-body typing | 4.17 s | all |
| unattributed typing/lowering remainder | 3.49 s | about 60% (IR generation) |
| ir-assembly | 2.38 s | about 70% |
| backend verify + lower + debug | 2.88 s | all |
| encode | 0.79 s | about 75% |

That is about 12.3 s, so P ≈ 0.74.

Limits:

| Cores | Ideal | With today's allocator (~1.5x on the parallel parts) |
|---|---|---|
| 4 | 4.4 + 12.3/4 ≈ 7.5 s (2.2x) | about 12.6 s (1.3x) |
| 8 | ≈ 5.9 s (2.8x) | – |
| unlimited | 4.4 s (3.8x) | – |

**Only A and B (about 5.5 s parallel):** about 12.5 s ideal on 4 cores, and about 14.9 s with today's allocator.

**One edit:** about 9.8 s end to end. About 7 s of it could be parallelized in principle (ir-assembly, backend, patch, encode), which gives about 4.6 s ideal on 4 cores and about 7.5 s with today's allocator. Making the work proportional to the edit should do better than either.

## 6. Recommended order

1. **Make `decodeString` and `parseStringExpression` linear.** About 1 hour. Saves about 8 GB of allocation and about 3 s or more in every full parse, plus GC pressure.
2. **Stop the cold build from discarding its first frontend pass.** About 1-3 days. Log which dependency triggers the restart. Then either seed known runtime modules as roots (`Compiler.addRootModule`), or extend the graph and re-type only what changed instead of restarting from scratch. Expected gain: about 15 s of the 33 s cold build, and about 2.7 s of the 4.9 s agent build.
3. **Make the incremental work proportional to the edit** (the other investigation): the inliner over the whole program, relowering, re-encoding the whole module, and patch planning.
4. **Then split A, then B, behind a switch that defaults to off.** Check that the output stays byte-identical by comparing `.hl`, `.hli` and `.live.json` with threads on and off on the editor corpus.
5. **Make the HashLink allocator scale (D) before expecting more than 1.5x.** Attempt C only if cold builds still matter after all of the above.

## Open questions

- Which typed runtime dependency triggers the restart in the graphical and agent projects? Needs a one-line log.
- How much of the first pass is GC caused by the icon-literal garbage, compared with real typing work? Measure after the `decodeString` fix.
- Is contention on the allocation-buffer refill lock really the scaling limit? Rerun `AllocBench` with a larger `GC_TLAB_RUN` in a scratch build of HashLink to confirm.
- Does the Windows build executor already run the agent and graphical compiles at the same time? The run log interleaves them with native builds, but I did not check the executor's settings for compile actions.
- What would parallel workers do to peak memory? The worker already reaches about 1.5 GB live on Linux according to `CompilerClient.hx:83`, and each worker's allocation buffers add to it.
