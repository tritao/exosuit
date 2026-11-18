# Handoff: haxeon port (overnight 11-17/18 + follow-up)

## Goal

Move Exosuit onto tritao's latest haxeon so it behaves exactly as before but uses upstream's reactive, low-allocation UI.
The full results are in `C:\Users\corbi\projects\exosuit-port\REPORT-PORT.md`.

## Done (verified, committed, nothing pushed)

**exosuit worktree:** `C:\Users\corbi\projects\exosuit-port`, based on main `6ee0435b`.

- **`haxeon-port`**: the working history (~80 commits). Tip `748325b0`.
- **`haxeon-port-topics`**: the same tree as 11 topic commits. Tip `100d317d`. Push this one.
- The port pins haxeon `5d2c7ab19`, which is upstream `ff7e29aac` plus our 21 commits.
- The results:
  - Every GUI scenario behaves identically to the baseline.
  - It allocates 5–15 % less per frame, and up to 72 % less overall.
  - It draws 35–64 % fewer frames where the baseline rebuilt on every pointer move.
  - Latency is equal within noise.
  - The retention check is clean on the final binaries.

**haxeon branches:** these exist ONLY inside the exosuit-port worktree's repository,
`C:\Users\corbi\projects\exosuit\.git\worktrees\exosuit-port\modules\haxeon`. Push them before you remove that worktree.

- **`exosuit-upstream`** (`5d2c7ab19`): the upstreamable series, our 21 commits on `ff7e29aac`.
- **`tooltip-scope-fix`** (`7f5ad7510`): `exosuit-upstream` plus the fix for a render scope's tooltip lift, with tests.
- **`exosuit-upstream-2`** (`553150bb9`, NEW, in flight): the 21 commits plus the tooltip fix, rebased onto upstream
  `origin/main` (22 commits on top; `origin/main` is now `68657687a`).

**Baseline worktree:** `C:\Users\corbi\projects\exosuit-baseline`, detached at `6ee0435b`, on old haxeon `fa128931e`,
built. It's the behavioural reference; its env script is `exosuit-port\.port\env-baseline.ps1`.

## In flight: stopped cleanly at 13:43 for the terminal restart

This is the follow-up the user chose on 11-18: move to the new upstream tip, then the editor caret/status-bar scope
(F3b), then make Problems an observing dock panel. Workflow `wf_5b54adfd-c09` was stopped.

- **Stage 1, haxeon rebase:** the rebase is done (`exosuit-upstream-2`, above). The toolchain rebuild, check-self-hosting
  and the test subset on it had **not finished**, so `exosuit-port\haxeon\out` may be half-built for the new branch. I
  stopped the agent's compiler worker.
- **Stage 1, inventory:** written to `exosuit-port\.port\docs\F-upstream-delta.md`. It lists the 65 new upstream
  commits and what exosuit must follow.
- **Stages 2–4 did not start:** exosuit on the new pin, F3b, and Problems observing.
- **Uncommitted:** in `exosuit-port`, the `haxeon` gitlink shows as modified, because the submodule is checked out at
  `exosuit-upstream-2` while the committed pin is still `5d2c7ab19`. **Do not commit it** until exosuit compiles on
  the new pin.
  - To get back to the verified state: `git -C exosuit-port\haxeon checkout exosuit-upstream`, then
    `git submodule update --init --recursive` in `haxeon`, then rebuild the toolchain.

## Next steps

1. Resume the follow-up. Re-run the workflow with `resumeFromRunId: wf_5b54adfd-c09` and its saved script, or redo the
   stages by hand:
   - toolchain + self-hosting + test subset on `exosuit-upstream-2`;
   - exosuit fixes from `F-upstream-delta.md`;
   - build and suites;
   - captures G01/G08/G14/G03/G04/G12/G10/G13a/G16b, plus the verify runs;
   - F3b;
   - Problems.
2. **"daily-2", proposed and not started.** The user wants a local daily build of the port to test, keeping all
   terminals.
   - **Findings:**
     - Terminal hosts are separate processes, and a workspace service adopts them by terminal id. The host protocol is
       version 2 on both the old and new builds, so adoption works.
     - The catch: the old daemon `suit` keeps the workspace catalog (`machine.json`) in
       `%LOCALAPPDATA%\exosuit\suit`. The new `exohost` reads `%LOCALAPPDATA%\exosuit\exohost`, which has no catalog,
       so it would create new workspace ids and never adopt the terminals.
     - Workspace state (`%LOCALAPPDATA%\Exosuit\workspaces\<id>\terminal-hosts`) is unaffected.
   - **Plan:**
     1. `suit quit --keep-terminals`.
     2. Stop only the old daemon process. First check in code that the hosts don't depend on it.
     3. Copy `exosuit\suit\*` to `exosuit\exohost\`.
     4. Start daily-2 from a worktree `C:\Users\corbi\projects\exosuit-daily-2` at `haxeon-port-topics`, built with the
        real state paths (not `.port\env.ps1`, which isolates state).
   - The session that asked for this handoff is moving the editor from suit to exohost now, so this may already be
     done by the time you read it.

## State outside the repo

- **`exosuit-port\.port\` (git-excluded):**
  - `env.ps1` and `env.sh` isolate the env, including `PRAGTICAL_PORTABLE=temp` and compiler session
    `%LOCALAPPDATA%\haxeon\compiler-port`.
  - `env-baseline.ps1`.
  - `docs\` holds the A–F phase docs.
  - `e-run.ps1` (one capture), `e-batch.ps1`, `parity.py`, `with-build-lock.ps1`, `e-summary.txt`, `e-logs\`.
- **Capture runs:** `exosuit-port\docs\benchmarks\perf-harness\runs\` (gitignored). These are the final port/base pairs
  plus `compare-*.txt`.
- **Compiler session folders:** `%LOCALAPPDATA%\haxeon\compiler-port`, `compiler-baseline` and `compiler-fix`, with no
  workers running.
- **Leftovers the user must delete** (my delete was denied): `exosuit\haxeon\out\native-cache\host\`
  `exosuit-ui-native-5c873c8ea8*` and `pluginhost-ef9e216aec*`.
- **Memory:** `haxeon-port-overnight-1117.md` in this project's auto-memory.
