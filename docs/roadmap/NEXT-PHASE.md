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
- `scripts/test-workspace-agents.py` and the contract phase of `scripts/test-workspace-terminals.py` now run on
  Windows (`hl.exe`, `;`-joined `PATH`, a `.cmd` wrapper around the fake Codex, PowerShell commands typed into the
  fixture shells through `TestShell`). `TerminalThemeTests` is skipped there: it needs termios and `/dev/tty`.
- The daemon phase of `scripts/test-workspace-terminals.py` fails on Windows. The `catalog` client mode (a separate
  `hl` process attaching to the manager process over its named pipe) throws "Native terminal catalog timed out", and
  the process then exits with 0xC0000409 (fail-fast), which is the crash once blamed on `TerminalAgentTests`; that
  suite passes in the `contracts` run. Find why the client never receives the catalog, then why the uncaught-exception
  exit path fail-fasts. The driver also cannot delete its temporary folder while the manager holds `agent.lock`.
- Starting a Claude session asks to trust the folder in Claude's own terminal UI, and Codex shows its own trust prompt.
- `tests/agentkit-provider` (run through a Windows copy of `run.py`) prints "PASS: agentkit provider" and then the
  process exits with 0xC0000409 at shutdown, so the script reports a failure. It also happens on `daily` without the
  catalog changes, so it is not new; the shutdown path, not a test, is what fail-fasts. `run.py` itself is POSIX-only.
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

- Done in Phase 6: workspace rows show idle, starting, running or reconnecting, and how many items need attention.
- The Workbench tree has no type-to-find.
- No PrintWindow capture test of the Workbench tree.
- Session and terminal directory failures are strings and loose codes (`invalid_directory`, `invalid_request`);
  give them an error-code enum.
- The other judgement-call smells from that review: go through them with the next change in those files.
- Second review (2026-10-30), deferred:
  - Done in Phase 6: expanding a workspace row starts its service if idle and shows its catalog without switching the
    window; Enter or a double click opens it.
  - Change… in `SessionFolderChooser` is its own flow rather than the group folder picker's; share one.
  - `SessionFolderChooser.newAgentSession` and `newTerminal` repeat one shape.
  - Workbench status rows and row-key prefixes are bare strings (`"empty"`, `"mwsn"`…); give them types along with
    the directory error codes.
  - `WorkspaceDirectories.choose` takes a scratch folder that only tests pass until Phase 4 resolves it in the
    service; `createProviderAgent` stays a forwarder because the Workbench takes it as a two-argument function.
- The workspace root group (2026-10-30), deferred:
  - Creating or moving an item to the root against a service from before the change fails with "Unknown group: "
    (or `invalid_request`); there is no capability check yet. A service from before it cannot open a catalog holding
    a root terminal (ADR 0006, downgrade risk).
  - Per-group tab snapshots (Phase 8) need a file name for the root's empty id.
  - Re-ordering (2026-10-31, done): sessions, terminals and groups share one order within a group, stored by the
    services (`order` on terminal and session records; RPC-VECTORS.md, "Position among siblings"). Dropping on the
    upper or lower part of a row places between siblings with an insertion line; Alt+Up/Down moves the selected row.
    Positions are spaced 1024 apart: a move writes only the moved rows, at the middle between their neighbours, and
    siblings are renumbered only when no gap is left or a neighbour has no position yet. A placement that would
    renumber rows the client may not write is refused with the reason. Re-ordering needs the `workspace.order`
    capability. Compatibility: an old client that moves a row into a group sends no position, so the row keeps the
    position it had in the group it left; an old service drops the positions of any record it rewrites (and refuses
    positions above 1000000, which a new client reaches after about a thousand appends); a client that has not placed
    a row sorts it after the placed ones.
  - New catalogs still seed a Work group: `scripts/test-workbench-actions-ui.py`, `scripts/test-workbench-groups-ui.py`
    and `scripts/import-sakura.py` (default `--parent work`) rely on it.
  - In the `workbench-drag` panel test, a right-click on a session row after some drags opened the background menu
    (key null) instead of the session's; the cause is not known, and the test uses F2 instead.

### M19 after landing (2026-11-01)

Phases 4–7 landed on `main` on 2026-11-01 (exosuit `757db3f1`, haxeon `fd2a332c`). Open:

- **The right panel lists a folder the workspace does not have; the title names the wrong workspace.** Fixed on
  branch `foreign-roots`: `ActiveContext` took its roots from every open project, `Application.openArgument` added
  any folder to the open workspace (the group menu's "Open folder", the Machine view's attach, the toolbar's Open
  Folder), and the title came from the last folder opened. Roots now come from the workspace's folders, opening
  another folder replaces the workspace, "Open folder" on a group focuses the group, and the title names the open
  (or adopted machine) workspace. The exact path that fired in the user's window was not seen; the scenario
  `m19_foreign_roots` (group menu "Open folder") failed before the fix and passes after.
- **Removing the "Work" group in `exosuit` left an empty-state message beside a session, and moved the Activity
  Rail.** After the group was removed, the workspace's root still held "Android live acceptance", yet the Workbench
  showed "Nothing here yet. Sessions and terminals go in the workspace; groups sort them." with New group. At the
  same moment the Activity Rail's destinations (Files, Search, Changes, Remote, Extensions) came back to the left
  rail. The user expected neither. Not investigated; a guess is that the window left the group's context and the
  layout mode (Agents layout moves those destinations to the right panel) changed with it. Fixed on branch `group-remove`
  (window moves to the root, the Agents layout stays, the empty state counts root sessions); the GUI scenario
  `m19_group_remove` fails without the fix and passes with it.
- **Workspaces take a long time to show as connected. Measured and mostly fixed (2026-11-02).** The editor keeps a
  connect timeline (`src/workspace/client/ConnectTimeline.hx`, shown as `timeline` in the automation state; with
  `EXOSUIT_CONNECT_LOG` set it also goes to stderr, and the launcher adds its own phases to the helper's exit event).
  `m19_connect_time` runs four cases with real input and writes the times to `results.json`. Milliseconds, one run
  each on a quiet machine, source checkout, isolated suit:

  | Case | Before | After |
  |---|---|---|
  | Launch to "Workspace connected" (cold service) | 6600 | 4400 |
  | Launch to catalog rows | 6700 | 4500 |
  | Expand an idle workspace to its rows in the tree | 3800 to 10700 (varies with suit) | 2500 |
  | Double click an idle workspace to connected | 5800 | 2900 |
  | Double click a running workspace to connected | 3000 | 1400 |
  | suit `machine` reply | 450 to 600 | unchanged |

  Where the time went: (1) every launcher run in a source checkout hashed every source file for the build identity
  (2.6 to 3 s) before printing its answer, so a discovery of a running service took 2.5 s and a cold start 3 s more;
  the identity is now cached by file names, sizes and times and the listing does fewer lookups (about 0.8 s left, in
  the file walk). (2) A service started from the tree was reached only when suit's next listing named it, 5 to 10 s
  later; the window now connects to the endpoint the starter's launcher printed. Not changed: a cold manager still
  takes about 2 s to come up, the discovery helper is still a process of its own (about 0.2 s), and in the scenario the catalog rows of
  the attached workspace appeared only once the Workbench was shown (not confirmed as a rule). Remaining idea: walk the file list once per
  state home per minute, or let the manager report its build identity, to drop the last 0.8 s.
- **A click on a group row in the Workbench tree did not switch to the group.** Fixed (2026-11-02, `group-entry`): a
  single click or Enter on a group row enters the group, on the open workspace's row its root; the chevron expands.
  `m19_group_entry` failed before (the click only expanded) and passes. The note that Work shares the workspace
  root's context key did not reproduce: the key is `machine/workspace/group id`, Work's key differs from the root's
  and the two keep separate tabs (`m19_group_entry`, and a check in `tests/active-context`).
- **The Workbench tree loses keyboard focus after a click or Enter on a row that switches context.** Cause: a switch
  re-keys the whole workspace view, so every row node gets a new id and focus is dropped. Partly fixed (`group-entry`):
  `TreeView.focusItem` gives the entered row focus on the build that creates it, and a switch from a row no longer
  hands the keyboard to the editor (`UiWorkbenchHost.keepFocusOnSwitch`). Down, Down, Up, Enter now work after a
  switch from Work to the root. Still open: in `m19_group_entry`, entering a context restored from its saved layout
  (the root again, Work again; both have tabs) leaves no focus on the row, so Down and Enter reach nothing. A context
  entered for the first time keeps focus. The editor does not take the focus (no editorResolved focus follows these
  switches), so the row's own request is lost or consumed too early on that path; not found. The selection half is fixed:
  the tree keeps its selection per context, so the re-keyed tree came back with the entered context's old selection (Work
  after clicking the root), and `WorkbenchPanel.selectAfterEnter` now selects the entered row. The automation snapshot now has `focus` (label of the focused widget, `-` for none).
- **Open in New Window on the group Work (resolved).** The tree and quick switch key Work by its own id since the group-entry
  change, so the window's key and the `--context=` key of a new window on Work agree. `tests/active-context` checks that
  the key of a group with the workspace folder is stable, differs from the root's and survives the `--context` round trip.
- `tests/document-test` stops on Windows at "Save As did not assign identity after successful persistence" (the
  comparison of `untitled.path` and `FileSystem.fullPath(saveAsPath)`); it did before this work. Checks after it in that
  file do not run there.
- Manager restart (resolved): `scripts/test-manager-owner-death.py` kills the process that started a detached manager, checks
  the manager survives, kills the manager, and checks the next start replaces it; two starts at once agree on one manager.
  suit's orphan view is not covered.
- `processAlive` (resolved): `AgentManagerNative.processAlive` opens the process, checks its exit status and that its image is the
  same runtime file name, so an exited manager or a reused id is not taken for a live one, on Windows too.
- The key-chords test runs only on Linux.
- Phase 6: no test runs the catalog watch against two real services; `tests/workspace-catalog` uses fakes.
- Phase 7: the click-to-frame budget is measured for the quick switch and Goto Previous (`m19_switch_latency`); the
  cross-workspace switch, which attaches the window to another service, is not.
- The hover crash fixed in haxeon `fd2a332c` (tooltips a patch builds) has no headless regression test; only the
  real-input scenarios cover it.
- 9 of the 15 fixture-argument test projects fail on Windows as they did before (a hard-coded `/bin/sh`,
  `chmod 000`).
- The status-bar test hung once on its first run after a rebuild and did not reproduce in 17 more runs.

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
- A multi-row drop reports the rows it cannot move (fixed with re-ordering); sort orders no longer tie,
  because a placement leaves room between neighbours and renumbers with that room when there is none.
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

Compiler bugs are recorded in [haxeon-compiler-bugs.md](../haxeon-compiler-bugs.md).

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
