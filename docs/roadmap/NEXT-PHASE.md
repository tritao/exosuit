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

### From the landing review (2026-10-28)

Agent sessions (`ui-exploration`):

- `RpcWorkspaceWorkbenchClient.hx` (around 697 and 740) runs `Json.stringify` on the old and new view and a
  `MessagePack.encode` on every publish, on the UI thread, for up to 4 MiB of history. Compare by revision instead.
- `CodexSessionPanel.hx` Ctrl+V reads the clipboard synchronously and can PNG-encode a 4096-square bitmap on the UI
  thread.
- `AgentImageStaging.hx`: draft images expire after 10 minutes, but the composer still shows them as attached until
  sending fails.
- `CodexProvider.hx` pins images before `turn/start`. If that fails, the session is "uncertain", the images stay
  pinned, and the two-image limit blocks new uploads until it reconciles. Pi and Claude have similar leftovers.
- `uikit-native/artifact_preview.cpp` `fail()` opens a modal `MessageBoxW`, which stalls unattended smoke runs
  (`CLAUDE.md`). Report the failure through the return value.
- `GitScmRepositoryHandle` creates worktrees inside the repository, so the parent's status shows them as untracked.
  This is part of "worktrees outside the project folder" above.
- `SessionSvgView.hx` hashes the whole SVG twice per build. Cache the hash.
- `CodexMarkdown.imageAt` runs without the inline budget for every `!`, so a line like `![![![` is quadratic.
- `CodexHistoryPages.following` evicts the newest older cursor after 128 handles, so very deep paging forces
  "Reset to latest".

Live mode and suit:

- The patching thread's callee-saved registers are not scanned (`hlpatch.c` and `hl_gc_root_holder`), so a static
  closure held only in a register by a JIT caller is missed. LiveHost patches between ticks and is not affected;
  embedders that patch from inside the app are. `setjmp` into a local and scan it.
- The conservative scan of other threads' stacks can refuse a patch over a stale spill slot that `liveRelease`
  cannot clear.
- `SuitTray.show` clears its actions even when NativeKit ignores the call because a menu is already open, so a choice
  from the visible menu does nothing.
- `nativekit_win.cpp` `cancel_tray_menu`: after the 3 s timeout the abandoned thread can still post its close message,
  which a newer menu may take as its own choice. Tag the message with the menu's generation.
- `run_tray_menu` registers its window class under the exe's `HINSTANCE`. Use the DLL's, so a reload doesn't keep the
  old window procedure.
- `UiContext.releaseRetained` leaves animations and commands in place, so handlers they hold can still refuse a
  guarded patch after release. Note this in `LIVE_PATCHING.md`.

### From GUI verification (2026-10-28)

- Agent CLIs that are command shims (`codex.cmd`) start as `cmd /d /c <path>`. A path with parentheses (for example
  under `Program Files (x86)`) or with `&` or `^` still fails, because NativeKit's `append_argument` escapes quotes in
  a way `cmd` does not understand. Add a NativeKit spawn option that takes a verbatim command line, then pass
  `/d /s /c ""<path>""`.
- A live patch without guards calls `liveRebuild` but not `liveRelease`, so `UiContext.customPaintKeys` and
  self-updating builders are kept. An edit to a custom paint handler's body may not show until its key changes.
- The workspace service keeps its state in `%LOCALAPPDATA%\Exosuit\workspaces\<hash>`, which `PRAGTICAL_PORTABLE`
  does not cover, so editor sessions on a test workspace leave state there.
- `scripts/test-workspace-agents.py` is POSIX-only (the bash `haxeon` wrapper, symlinks, `LD_LIBRARY_PATH`, running
  `fake-codex.py` directly). A Windows run works with a `.cmd` wrapper around the fake, `;`-joined `PATH` entries and
  `hl.exe`; make the script do that.
- Starting a Claude session asks to trust the folder in Claude's own terminal UI, and Codex shows its own trust prompt.
  Consider passing the workspace's trust decision through, or explaining the prompt.

### From the session-scope review (2026-10-28)

- The session Commit button finds the repository through the session's own source, but hands it to the panel's source
  (`ExosuitApp.hx` around 1562). When the session folder is outside the narrowed panel scope, the button focuses a commit
  box that cannot commit. Disable it there, or point the panel at the session source.
- A group folder can be any existing folder, including a drive root or the home folder, and session links, context and
  images then reach everything under it. Consider refusing filesystem roots.
- `sessionSourceControlSource` resolves the session folder and checks every context root about ten times per session
  per frame. Cache the normalized folder per `cwd`.
- `FileSystemService.normalize` does not resolve Windows junctions, so a junction inside a session folder can point
  outside it (the workspace root already had this gap).
- `agent-image-staging` reads an icon relative to its working directory, so it cannot run from `scripts/test.sh` yet.
- "New session in …" does not offer groups whose folder is outside the workspace (`SessionGroupDirectory.resolve`).

### M19 Phases 1–3 review: deferred

- Workspace rows have no running/idle marker yet (Phase 3 asks for one; Phase 6 knows which services run).
- The Workbench tree has no type-to-find.
- No PrintWindow capture test of the Workbench tree.
- Session and terminal directory failures are strings and loose codes (`invalid_directory`, `invalid_request`);
  give them an error-code enum.
- The other judgement-call smells from that review: go through them with the next change in those files.
- Second review (2026-10-30), deferred:
  - Expanding a workspace row switches the whole window to it. Phase 3 asks for expansion to attach the workspace's
    service and leave the window alone; that needs Phase 6's per-window attach.
  - Change… in `SessionFolderChooser` is its own flow rather than the group folder picker's; share one.
  - `SessionFolderChooser.newAgentSession` and `newTerminal` repeat one shape.
  - Workbench status rows and row-key prefixes are bare strings (`"empty"`, `"mwsn"`…); give them types along with
    the directory error codes.
  - `WorkspaceDirectories.choose` takes a scratch folder that only tests pass until Phase 4 resolves it in the
    service; `createProviderAgent` stays a forwarder because the Workbench takes it as a two-argument function.

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

## Build times (measured 2026-10-29, after the build-speed changes 2026-10-30)

`scripts/build-windows.ps1 -SkipBootstrap` on cube. On 2026-10-29, in a fresh worktree on a loaded machine (the
Android emulator held about 6 cores, and a WSL job was running):

| Build | Time | Where it goes |
|---|---|---|
| Cold | 1,291 s (21.5 min) | about 1,140 s native C/C++; Haxe: editor 125 s (13,765 functions), agent 18 s, suit 7 s |
| Nothing changed | 42 s | per-project MSBuild up-to-date checks; every step was a fingerprint match |

On 2026-10-30 the machine was quieter (another worker was building), so the baseline was taken again before the
changes, at f73024b. Times are the "Exosuit build" step; `scripts/build.py` now prints each app's time.

| Build | Before (Visual Studio generator) | After (Ninja, ccache, module-only packages) |
|---|---|---|
| Cold, build folders deleted | 429 s | 104 s (agent 33 s, suit 33 s, editor 37 s) |
| Cold, nothing in the compiler cache for these paths | 429 s | 130 s in a fresh second worktree (39, 37, 53 s) |
| Nothing changed | 9 s (13 s with the script) | 3 s (6 s with the script) |

What changed, in Haxeon (pinned by this branch):

- **Ninja on Windows.** MSVC builds of CMake packages use Ninja instead of the Visual Studio generator, which compiled
  a project's files one at a time and ran MSBuild's up-to-date check on every project. Haxeon loads the newest Visual
  Studio's environment itself when the build is not in a developer prompt, so `scripts/run.py` from a plain shell gets
  Ninja too. Switching between such a shell and `build-windows.ps1` (whose PATH differs) reconfigures the trees.
- **ccache on Windows.** The bootstrap pins it (optional: offline it warns), and the Ninja builds compile through it,
  keyed by the MSVC toolset, SDK and include path rather than cl.exe's size and time. It has no base directory on
  Windows: ccache hands cl the relative paths it keys by, and cl fails on paths over 260 characters, which deep build
  trees reach. So the cache reuses objects of the same build tree only: a reconfigured tree, or build folders that were
  deleted (104 s with it, 194 s without, one measurement each).
- **haxeon-credentials and haxeon-filesystem build only their NativeKit module**, not all of NativeKit, which cost
  each a libwebsockets configure (65 compiler checks) and a WebView2 download for one or two source files.

What is left, in order of payoff:

1. **NativeKit is still configured and built three times**, by the agent, suit and editor. Configuring it is now the
   largest cost: libwebsockets' 65 checks take about 30 s, one at a time, in each. Sharing it needs one CMake tree for
   the three apps, such as Haxeon's workspace builds already make (they share a tree per CMake source and target), and
   the agent and suit to use one native source for it. The apps' runtime library paths assume one folder per app.
2. **Build the apps side by side.** Tried: 162 s against 132 s one after another, as their configures contended. Worth
   another look once NativeKit is configured once.
3. **A compiler cache shared across worktrees on Windows** needs paths that stay under 260 characters (a short build
   root) or a cache that normalizes paths without rewriting the compile command.
4. **Profile the editor's Haxe compile** (about 50 s now, overlapping the native builds). The live session patches
   incrementally, but a full compile at this size needs a profile.
5. One cold build, without ccache, failed once with "Access violation" in the Haxeon CLI while it ran configures in
   parallel. The likely cause, launches restoring environment values that `Sys.putEnv` had freed, is fixed in the
   pinned Haxeon; watch for it again.

From the review of the build-speed fixes (2026-10-30), none blocking:

- Planning can hang: `HostCommand` (vcvarsall, vswhere, `ninja --version`) has no timeout, never drains stderr and
  leaks the process on an exception, and the bootstrap's downloads (ccache and the others) have no
  `INACTIVITY_TIMEOUT`. Merge `HostCommand` into `ProcessRunner.capture`, which already does this job, with a timeout.
- `MsvcEnvironment` calls `Sys.putEnv` outside the launch lock. It runs before executor threads start today; take
  the lock anyway so a resident session or the live warmup cannot race it.
- `NativeCMakeProvider` caches `ninja --version` under the bare name. Asked before vcvars puts Visual Studio's Ninja
  on PATH, the empty answer turns Ninja off for the whole build.
- A Visual Studio install path containing `&` or `^` breaks the `cmd /u` command that reads its environment.
- `nativekit-module.cmake` skips NativeKit's `if(ANDROID) set(NK_BUILD_SHARED ON)`.
- The ProcessRunner regression test can pass without the fix, because freed memory often keeps its bytes.
