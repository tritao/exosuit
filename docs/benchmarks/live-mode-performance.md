# Live mode performance (2026-10-25)

Why the editor felt unusably slow under `python scripts/run.py --live` on Windows, measured with the instrumenting
profiler. This also records every bug and gap found along the way, fixed or not.

## Method

Four runs of the same scripted interaction, each recorded with `--profile` (instrumentation, 1 µs short-call
threshold) from launch to exit:

| Run | Mode | Trace |
| --- | --- | --- |
| 1 | `run.py` | `1-normal-run.pftrace` |
| 2 | `run.py --watch` | `2-watch-mode.pftrace` |
| 3 | `run.py --live`, no edits | `3-live-fresh.pftrace` |
| 4 | `run.py --live`, three edits patched in before the interaction | `4-live-after-3-patches.pftrace` |

- Each run starts from an empty state folder (`PRAGTICAL_PORTABLE`) and opens the exosuit folder and
  `src/editor/TextBuffer.hx` from the command line.
- The interaction is an `--input-script`. One second after the first frame, the pointer sweeps the left activity bar
  (x 28, y 60–270) for 14 s, then scrolls `TextBuffer.hx` down and up twice for 24 s.
- `--capture-dir` records every frame; `--capture-seconds` ends the run.
- Run 4 changes the status-bar string `"Spaces: "` three times; each patched in about 12 s.
- Numbers below are for the UI thread, per frame, inside the hover and scroll windows only. They come from the
  app's frame records and from per-function call statistics of the instrumented calls.
- The probes cost the same in every run, so absolute times are inflated but comparisons hold.

## Results

Frame time, from the app's own records (median / p95, ms):

| Run | Hover | Scroll | Input delivery lag, scroll (median) |
| --- | --- | --- | --- |
| Normal | 19.7 / 30.7 | 19.4 / 20.8 | 0.6 ms |
| Watch | 21.5 / 33.9 | 19.6 / 21.0 | 0.5 ms |
| Live, fresh | 22.5 / 41.1 | 25.3 / 45.1 | 14.8 ms |
| Live, after patches | 21.7 / 22.7 | 22.6 / 23.8 | 8.9 ms |

UI-thread time outside the app's tick during the 24 s scroll window:

| Run | `GraphicalMain.tick` total | Outside the tick | Ticks | Outside per tick |
| --- | --- | --- | --- | --- |
| Normal | 23.5 s | ~0.5 s | 2526 | ~0.2 ms |
| Live, fresh | 15.0 s | ~9.0 s | 668 | ~13.5 ms |
| Live, after patches | 14.0 s | ~10.0 s | 1106 | ~9.1 ms |

### 1. The live host re-reads and re-parses a 1 MB file after every tick (the main cost)

- `LiveHost.main` (haxeon `src/tools/LiveHost.hx`) calls `tryDescription(path)` after every `tick`. That reads
  `live.hl.live.json` (1,027,368 bytes, mostly the identity table and `changedFunctions`) and `Json.parse`s it on the
  UI thread, only to compare `revision` and `moduleIdentity`.
- In the scroll window this took about 40% of the UI thread: 9–13 ms per tick. `ucrtbase!fread` ran 1141 times for
  1106 ticks.
- That is where the fewer frames per second and the 9–15 ms input lag come from.
- The host's own Haxe code is not instrumented, so the parse shows in the trace only as gaps between `tick` slices,
  plus the `fread` and `_wfopen` boundary calls.
- *Fixed* in haxeon d08c1d35: the compiler publishes a small `.live.stamp` (the publication key) after the
  description, and the host parses the description only when the stamp changes.

### 2. The per-call cost of a patchable module (smaller)

- Steady state, after patches, scroll: Haxe self time went from 7.7 to 11.5 ms per frame, and native from 10.4 to
  11.5 ms.
- Part of that is more calls being kept: leaf functions slowed past the 1 µs threshold stop being dropped. Kept Haxe
  calls went from 3750 to 4475 per frame (`BuildContext.id` 35→173, `Theme.semanticColor` 0→139,
  `ResolvedLayoutItem.decode` 16→106, `LayoutTransaction.appendNode` 67→156).
- Mean self time per kept Haxe call rose about 25% while scrolling (2.06 → 2.58 µs) and about 1% while hovering.
- Allocation per frame rose from 1.12 to about 1.5 MB in both live runs, and `FrameGcScheduler.idle` time grew to
  match. Not yet explained.
- Next step: fix item 1, then re-measure before deciding whether direct calls for unpatched functions are worth it.

### 3. Run 3 is contaminated by background load

- Same tree as run 1 (400 nodes, 182 style resolutions, 1686 glyphs per frame), yet native code such as
  `append_render_glyph` ran 46% slower with identical call counts.
- That run's interaction started right after a 35 s live startup compile, while other processes were still busy.
- Use run 4 as the live comparison.

### 4. What every mode spends on a frame where little changes

Scroll, normal run, self ms per frame:

- `nkui append_render_glyph`: 3.4 ms for ~1700 glyphs, about 2 µs per glyph. All visible text is re-emitted every
  frame.
- `haxeon.ui.LayoutTransaction.encodeInto`: 1.9 ms over 2 calls. The whole layout is serialized each frame.
- Clay layout (`Clay__CalculateFinalLayout`, `PositionTreeRoots`, `SizeContainersAlongAxis`): about 1.6 ms.
- `RenderNode.walk` 0.7 ms, `StyleDiff.compare` 0.48 ms, `KeyScope.prune` 0.3 ms, `BuildContext.pruneKeyCaches`
  0.28 ms.
- **Version-control and file-system work on the UI thread during a scroll:** `scm.ScmTrustStore.key` (6 calls, 0.6 ms),
  `workspace.FileSystemService.normalize` (0.35 ms), `scm.LocalScmSource.normalize`, and `_wfopen` about once a frame
  (633 opens in 24 s) even in the normal run.
- `nk::windows_joystick::pump`: 7 calls per frame, about 50 µs each (0.36 ms per frame), polling for game controllers.
- Hundreds of millions of sub-µs calls are dropped per run (633 M in run 1). The most frequent are
  `Clay__Array_RangeCheck` (95 M), `LayoutTransaction.writeFloat` (57 M), `.finite`, `.writeInt`,
  `ComputedStyle.isSet` and HarfBuzz script-tag lookups (~8.5 M each). Hot paths worth slimming, and candidates for
  compile-time excludes.

### 5. Startup: about 1 s in system font fallback on the first frame

- Frame 1 takes 1.1–1.3 s in every run.
- 1.045 s of it is `nkui system_font_fallback` inside `skb_font_collection_match_fonts`, under `haxeon.ui.TextLayout.create`
  for the editor tabs.

## Bugs and gaps found

### Live patching (HashLink)

1. **A static closure of a native was rejected** ("Invalid static closure"). Any edited function that uses a native
   as a value could not patch, so every edit to the status-bar code reloaded the module. The JIT's patch-staging path
   for `OStaticClosure` also took the type from `code->functions` for a native index, which reads past the table.
   *Fixed* in hashlink 1c0478d (branch `live-patch-native-closure`). Test: haxeon `NativeClosurePatchMain`.
2. **About 30 opcodes were rejected by the patch validator** ("Unsupported patch opcode"), though the JIT compiles
   them. *Fixed* in hashlink 4a90f4f for the register-only ones: `OIncr ODecr ONeg ONot OGetType OGetTID ORef
   OUnref OSetref ORefData OUDiv OUMod OGetI8 OGetI16 OGetMem OSetI8 OSetI16 OSetMem ORefOffset`. Of these, Haxeon
   emits only `ORefData` and the memory gets and sets (an array write is `ORefData` then `OSetMem`). Test: haxeon
   `ArrayWritePatchMain`. The validator still checks only register indexes, not types; the load path doesn't check
   types either. **Still rejected:** `OBytes`,
   `OVirtualClosure`, `ODynGet`, `ODynSet`, `OSwitch` (its jump table must also be followed by the trap-flow walker),
   `OSetEnumField`, `OAssert`, `ONop`, `OPrefetch`, `OAsm`, `OCatch`. Any edit to a function containing one still
   reloads; `OSwitch` is the one real code hits most.
3. **The rejection reason is dropped.** `hl_runtime_patch` returns status 4 and discards the error string, so the log
   says only "HashLink rejected the patch transaction (status 4)". Finding items 1 and 2 needed a temporary `fprintf`.
4. **The first edit after a launch reloads when the compile server starts cold**: "revision 1 cannot patch revision 1
   (module identity changed ...)".
5. **A reload restarts the app's capture timer and input script.** A run with reloads went on for 4 minutes and
   627 MiB instead of about 100 s.

### Profiler

6. **`hlprof-live report` and `export --format folded` ignore instrumented calls.** Both print empty tables for an
   instrument-only capture, and the Chrome JSON export has no call stacks either. Only `.pftrace` shows calls. This
   analysis used a temporary aggregator in `pf_stack_call` ([`call-stats-aggregator.patch`](live-mode-performance/call-stats-aggregator.patch))
   writing count, self and total time per function. A `report` mode for instrumented calls should replace it.
7. **A windowed export runs past `--end-ms` and invents durations.** Records about 2 s past the end are still
   emitted, from the reorder window, and every call still open at the last record is closed there. Calls that began
   after the requested end then show 1.45 s durations ending together at the export's last timestamp. A whole-capture
   export has no such calls after startup. Either clip the window to `--end-ms` exactly, or close open calls at the
   window end and mark them as cut.
8. **Trace size.** About 265k kept calls per second gives 4.8 MB/s of HLPC and 16 MB/s of `.pftrace`, roughly 60 bytes
   per call or 3.3× the capture. The export closes and reopens every open call-stack slice at each frame boundary
   (`pf_stack_frame`), which multiplies slice events for deep stacks. Worth measuring.
9. **Host code was a blind spot.** `LiveHost` was built with stock Haxe, so its 9–13 ms per tick appeared only as gaps.
   *Fixed* in haxeon b63db7c0: `run --live` builds the host with Haxeon, instrumented under `--profile`. The host runs
   the app's tick on the same thread, so host and app calls share one track.

### Haxeon compiler and live runtime

17. **A `try … catch` used as an expression needs a `;` after the catch block.** Haxeon's parser rejects
    `var x = try f() catch (e:Dynamic) { … }` followed by a new statement ("E0002: Expected Semicolon, got
    Identifier"), where Haxe accepts it.
18. **A parsed `Dynamic` cannot be cast to a structure type.** `var d:LiveDescription = Json.parse(text)` fails at
    run time with "Can't cast dynobj to $anon:{…}"; Haxe converts the object. `LiveHost` now builds the structure
    field by field.
19. **An edit to three functions takes 8–16 s to compile** with a warm compile server ("compile=14028 ms, 3 functions
    retyped"). That is most of the edit-to-patch delay a user feels. Not investigated.
20. **Applying a patch freezes the editor for about 2 s.** In a capture with the stamp fix (one edit, three functions),
    `live.patch` / `runtime.Runtime.patchSet` ran 1,896 ms on the UI thread. *Fixed* in hashlink fba14f4: the VM
    scanned the whole string table for each of 23,287 type names when hashing the type prefix; a content index makes it
    milliseconds, and an unprofiled live edit no longer leaves a frame gap (1,927 ms before). See
    [`investigations/patch-freeze.md`](live-mode-performance/investigations/patch-freeze.md).
22. **The module files and the description can pair across builds.** `.hl`, `.hli` and `.hlp` are published before
    `.live.json` but the host reads them after it; if a newer build lands in between, the host can apply build N+1's
    `.hlp` with build N's description (or, at startup, load N+1 with N's function ids). Existed before the stamp,
    found in review, not fixed.

### Tooling and environment

10. **The main checkout's HashLink tools and runtime were stale** (from before the profiler work). The editor failed
    with "Invalid signature for function haxeon_runtime@__sys_profile_counter : POBi_d_v required but PiOBi_d_v found
    in hdll". `run.py` does not rebuild `haxeon/.tools/hashlink` or `haxeon/out` when the HashLink submodule moves; a
    manual `cmake --build --preset windows-msvc` in `haxeon` was needed.
11. **That signature failure still raised a modal "Fatal Error" dialog** although the run's stdout and stderr went to
    files. The app launched by `haxeon run` is evidently not treated as piped.
12. **The workspace agent (manager and host `hl.exe`) outlives the editor** and keeps `hl.exe` locked, which breaks
    rebuilding HashLink (LNK1104). The same as the known "agent managers ignore --idle-seconds".
13. **Compile servers inherit the launcher's stdout and stderr handles**, so a redirected log stays locked after the run.
14. Watch-mode output contains `'import' is not recognized as an internal or external command` (some step passes a
    POSIX or Python line to cmd). Not investigated.
15. Every capture directory gets `screenshot-error.txt`: the frame capture's screenshot fails. Not investigated.
16. The Chrome profile used for browser automation blocked all page scripts (Perfetto stopped at its boot spinner;
    a `data:` script failed on example.com too). It's a browser setting, not a profiler bug.
21. **Two Haxeon tooling tests fail on Windows, with or without this work** (checked against haxeon e4661b98):
    `LspProtocolMain` ("projected FFI constant definition did not reach its ABI declaration") and
    `CompilerSessionMain` ("runtime library path must be restored exactly"). Not investigated. In the runtime suite, 9
    of 68 fail on Windows for portability reasons: four integration scripts call `cc` (`GcAllocationPaths`,
    `GcEmptyPages`, `JitInlineAllocation`, `JitBoxedAllocation`), four tests start `.tools/hashlink/hl` without `.exe`
    (`nullable-enum-pattern`, `static-init-order`, `loaded-array-cast`, `dynamic-string`), and `BytesAsciiMain` runs
    a command cmd does not recognize.

## Investigations (2026-10-25)

Four questions were investigated in parallel, each report then checked by an adversarial reviewer; both are in
[`live-mode-performance/investigations/`](live-mode-performance/investigations/):

- `patch-freeze`: the 1.9 s patch freeze (fixed, item 20). The review also found that patches could append struct
  and method types the VM could not stage; they are now rejected.
- `compile-slow`: why a 3-function edit takes 8-16 s. Mostly fixed costs: the backend re-lowers every function that
  touches a changed file (8,315 of 13,496; lowering only regenerated functions measured 8.1 -> 6.1 s with identical
  output), 150 functions count as changed on every compile, and source locations hash the whole file.
- `live-scroll-slowdown`: run 6's slower frames came from a person using the window; the real live-mode cost is GC
  ownership tracking (5-6x longer pauses), per-evaluation string literals (+0.37 MB per frame) and call indirection.
- `compiler-multicore`: fix the frontend restart and the O(n^2) string decoding first; threading is capped by the
  allocator's global lock.

## Reproducing

The driver and analysis scripts are in [`live-mode-performance/`](live-mode-performance/) and run in place; their
output (`runs/`, `traces/`, generated `script*.json`) is ignored by git. The checkout path is fixed at
`C:/Users/corbi/projects/exosuit`.

- `run.ps1` and `drive.ps1` run one capture. The driver enforces a hard deadline, kills the process tree, reads any
  error dialog's text, makes the scripted source edits and restores the file, and stops leftover compile servers and
  workspace agents. Progress goes to `runs/<name>/driver.log`.
- `make_script.py OFFSET OUT` writes the input script: the interaction starts OFFSET seconds after the first frame.
- `windows.py RUN_DIR CAPTURE.hlpc` maps the run's checkpoints to capture milliseconds; `frames.py`, `compare.py`
  and `split.py` do the rest of the analysis.
- `serve_dir.py DIR [SECONDS]` serves the `.pftrace` files in DIR to ui.perfetto.dev. Perfetto fetches only from
  `127.0.0.1:9001`, and the server lists its files at start, so restart it after adding a trace. Open
  `https://ui.perfetto.dev/#!/?url=http://127.0.0.1:9001/<name>.pftrace`.
- `call-stats-aggregator.patch` is the temporary `hlprof-live` aggregator, applied to the HashLink submodule.

A capture's trace (the editor process, launch to exit) stays at or under 120 s. The build before launch doesn't count.

```powershell
cd docs/benchmarks/live-mode-performance
python make_script.py 1 script.json            # ordinary runs: interaction 1 s after the first frame
python make_script.py 25 script-one-edit.json  # live with one edit: starts once the edit has patched
./run.ps1 -Name normal -Seconds 44
./run.ps1 -Name watch -Mode '--watch' -Seconds 44
./run.ps1 -Name live -Mode '--live' -Seconds 44
./run.ps1 -Name live-edit -Mode '--live' -Script 'script-one-edit.json' -Seconds 68 -Deadline 360 -Patch -OneEdit
```

`-Patch` alone makes three edits (`"Spaces: "` in `ExosuitApp.hx`); `-OneEdit` keeps only the first. Each run's
`run.log` names its `profile.pftrace`; link it into `traces/` under a descriptive name before serving.
