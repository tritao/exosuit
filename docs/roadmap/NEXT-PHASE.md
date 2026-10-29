# Next-phase work

Recorded 2026-10-28, from the final review of `daily` against `main` (live mode, suit, suit-relay, Workbench, Agent
Mode). The blockers and high-severity findings were fixed before the merge. Everything below was deliberately left
for the next work phase. Severity is the reviewer's, not a priority order.

## Decided, revisit later

- **Quit leaves relay hosting running.** Quitting the suit tray stops suit, but persistent relay hosting stays
  attached by design so workspaces stay reachable remotely. Revisit if Quit should mean "stop everything".
- **Git hooks on the atomic scoped commit.** `GitScopedCommit` falls back to `git commit` when hooks, signing or a
  non-default cleanup are configured. Make hooks run as git would on the atomic path, too.
- **Worktrees outside the project folder.** Confirm that an Agent Mode group pointed at a linked worktree outside the
  project folder works end to end, and relax the "worktrees live under the project" assumption.

## Medium

- **suit: Quit with an editor kept open.** suit exits, then the editor respawns services that nothing tracks. Either
  keep suit alive while editors run, or have the editor restart suit before spawning.
- **Live: a removed method is still reachable through dynamic dispatch.** Guards cover closures and direct calls.
  A `Dynamic` call or reflection lookup can still reach a dropped method.
- **Workbench: Ctrl-click focus jumps.** `TreeView.toggleSelection` picks the focused key from hash order, so the
  scope can jump to an arbitrary selected row.
- **Workbench: `syncScmDocumentMarkers` runs every 50 ms.** It resolves the scope three times per tick and stats
  folders, so a network drive can block the UI thread. Cache the scope and recompute on change.

## Low

### suit

- Tray tooltip text is cut at 128 characters.
- Terminate is offered on processes that exosuit did not start.
- An orphaned compiler worker can be missed for up to 10 s after its parent exits.
- The client map has no bound.
- In the adoption sweep, a process whose environment cannot be read counts as included.
- Linux and macOS C changes (chunked `/proc/environ` read, `execle` in the contract test) have not been compiled on
  those platforms.
- A 32-bit build reads no environments, so suit adopts nothing there (documented).
- No automated test covers the editor's "suit disabled: state folder is temporary" notice or the manager's log line.

### Workbench and Agent Mode

- Groups cannot be closed in bulk.
- A multi-row drop silently skips rows it cannot move.
- Sort orders can tie after a batch move.
- An Activity Rail drag swallows the next keyboard activation.
- Search can index a very large scoped folder with no limit.
- Collapsing a group drops the selection.
- `RpcScmSource.scoped_commit` is dead code.
- Detecting an unset `core.ignorecase` relies on the text of `GitProcess.mapError` for an empty-stderr exit 1. Expose
  the exit code on `ScmError` instead.
- Remote workspaces show "Not scoped". Real folder scoping needs remote file, search and SCM support.

### Live mode

- Hook identities are fixed when the module loads. A `liveRelease`/`liveRebuild` added by a patch is not called
  until restart.
- Reserved slot names are changed before `hl_gc_exclusive_begin`.
- A second refusal in a row shows the wrong retract message.
- `Runtime.hx`: two doc comments are stacked above `patchSetRebuilding`. The first belongs on `patchSet`.
- Static closures are guarded only on x64. The arm64 JIT (`jit_arm64.c`) was not updated.
- No constructor-specific adapter test.
- A throwing `liveRelease`/`liveRebuild` is reported with a generic message, because `callVoid` does not pass on the
  app's exception text.
- Arena blocks the patch JIT allocates (`temp.ctx.alloc`) are leaked instead of freed with the module.
- Diff matching (`SourceLineMap`) lives only in memory, so a restored session matches lambdas by code alone. Persist
  the places and sources.
- Adapters fill in only literal defaults. Any other default forces a guard.
- A thread stopped inside old code finishes it after the commit, so up to about one object per thread per patch is
  created without an added field.
- A migration initializer that waits on another thread deadlocks.
- Renamed lambdas keep their old runtime type names, because patches hash the published names. Only tools that print
  type names show it.
- 22 failures in the full haxeon suite predate this work, are Windows-only, or come from missing tooling. Triage them
  separately.

### Haxeon compiler

- Declaring a local function partway through a function ends null narrowing for locals declared before it
  (`mutationDiscovery` in `ScmGitTestMain`). There is no minimal repro yet.

## Standards cleanup

Hard violations:

- Untyped statics in `haxeon/tests/runtime/LambdaRenumberPatchMain.hx` (lines 16 and 31) and `LiveCallerPatchMain.hx`
  (line 14).
- `native-packages/processes/tests/run.sh:10` runs `ctest`. Run the test executable through the guard instead
  (see `CLAUDE.md`).
- `AgentManager.hx:213-214`: a string literal contains an accidental raw newline.

The review also flagged about 35 judgement-call smells (naming, duplicated shapes, data clumps). Go through them with
the next round of changes in those files, not as a separate pass.
