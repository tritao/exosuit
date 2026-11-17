# Roadmap

Open work only. Finished work is in git history; how the system works now is in [ARCHITECTURE.md](ARCHITECTURE.md).
Compiler bugs are in [haxeon-compiler-bugs.md](haxeon-compiler-bugs.md).

## Editor

- **Responsive file loading.** One pipeline for tree clicks, commands and session restore, with loading, ready, failed
  and cancelled states. The tab shows at once; a spinner after about 150 ms. Read and validate off the UI thread;
  closing a loading tab cancels it. Look at size and sample bytes before reading a whole file, so a binary file shows
  its warning and byte preview without a full read. Large text files offer "Open Text" or "View Bytes" and a mode
  without minimap and syntax analysis.
- **Stepped minimap scaling** at higher zoom: row pitch and mark size grow together at thresholds, with hysteresis.
- **One file identity for symlink aliases.** Ctrl-P still lists a file reached through a symlinked folder twice.
  Resolve identities while indexing and reuse them for picker merging and document lookup.

## Workbench and sessions

- Type-to-find in the Workbench tree.
- Ctrl-click can move keyboard focus to an arbitrary selected row (`TreeView` picks it from hash order).
- `syncScmDocumentMarkers` resolves the scope three times every 50 ms and stats folders; a network drive can block
  the UI thread. Cache the scope.
- Groups cannot be closed in bulk; collapsing a group drops the selection; an Activity Rail drag swallows the next
  keyboard activation; Search can index a very large scoped folder with no limit.
- Session and terminal directory failures are strings and loose codes, and status rows and row-key prefixes are bare
  strings. Give them types.
- `SessionFolderChooser`: Change… has its own flow instead of the group folder picker's, and `newAgentSession` and
  `newTerminal` repeat one shape.
- A group folder can be a drive root or the home folder; session links, context and images then reach everything
  under it. Consider refusing filesystem roots. `FileSystemService.normalize` does not resolve Windows junctions.
- "New session in …" does not offer groups whose folder is outside the workspace (`SessionGroupDirectory.resolve`).
- The session Commit button finds the repository through the session's source but hands it to the panel's; outside
  the narrowed panel scope it focuses a commit box that cannot commit. `sessionSourceControlSource` resolves the
  session folder several times per frame; cache it per `cwd`.
- Remote workspaces show "Not scoped": real folder scoping needs remote file, search and SCM support.

## Agents

- `RpcWorkspaceWorkbenchClient` compares agent views with `Json.stringify` and encodes them on every publish, on the UI
  thread, for up to 4 MiB of history. Compare by revision.
- `CodexSessionPanel` Ctrl+V reads the clipboard synchronously and can PNG-encode a large bitmap on the UI thread.
- Draft images expire after 10 minutes (`AgentImageStaging`) but the composer still shows them attached.
  `CodexProvider` pins images before `turn/start`; when that fails the images stay pinned and the two-image limit
  blocks uploads until the session reconciles. Pi and Claude have similar leftovers.
- `CodexMarkdown.imageAt` is quadratic on lines like `![![![`; `SessionSvgView` hashes the SVG twice per build;
  `CodexHistoryPages.following` evicts cursors after 128 handles, forcing "Reset to latest" in very deep paging.
- `uikit-native/artifact_preview.cpp` opens a modal `MessageBoxW` on failure, which stalls unattended runs.
- Agent CLIs that are command shims (`codex.cmd`) fail from a path with parentheses, `&` or `^`: NativeKit's argument
  quoting is not `cmd`'s. Needs a verbatim command line spawn option.
- Claude and Codex ask to trust the folder in their own UI. Pass the workspace's trust decision through, or explain it.
- What [design/agent-sessions.md](design/agent-sessions.md) lists under "Not done".

## Source control

- Hooks, signing and non-default cleanup make `GitScopedCommit` fall back to `git commit`; run hooks on the atomic
  path too.
- Worktrees outside the project folder: `GitScmRepositoryHandle` creates them inside the repository, so the parent
  lists them as untracked. Check an Agent Mode group on a linked worktree outside the project end to end.
- `RpcScmSource.scoped_commit` is dead code. Detecting an unset `core.ignorecase` relies on the text of
  `GitProcess.mapError`; expose the exit code on `ScmError`.

## Workspace files

- Windows qualification of file watching and search (ignore and glob rules, stale results, scan and byte limits,
  responsiveness under concurrent search, watch and terminal traffic).

## Remote access, phone and browser

- Invitations: QR code sharing, and the copied URL as a web-app deep link.
- Relay Worker qualification: hibernation recovery, forwarding limits, quotas, fault injection.
- `wss` against a real Worker across networks (CA export), the phone on an arm64 device, a Release build, and a real
  Android browser (file browsing, agent prompts and approvals, terminal input, suspension, network changes).
- Touch and narrow layouts for the browser client; optional installable web app.
- The phone opens one workspace at a time.
- A message on a device stream is at most 65487 bytes (`MachineStreamFrame.MAX_PAYLOAD`); a larger file read or terminal
  burst has to be split by the service.
- In automated phone acceptance the Read only strip sometimes did not repaint after another viewer took control; the
  script warns instead of failing.

## exohost

- The tray tooltip is cut at 128 characters. Terminate is offered on processes exosuit did not start.
- An orphaned compiler worker can be missed for up to 10 s after its parent exits. The daemon's client list has no
  bound. In the adoption sweep a process whose environment cannot be read counts as included.
- NativeKit's tray menu: `ExohostTray.show` clears its actions even when a menu is already open; a cancelled menu's thread
  can post its close message to a newer menu; the menu window class is registered under the exe's `HINSTANCE`.
- macOS process listing is not implemented; the Linux and macOS C changes (chunked `/proc/environ` read) have not been
  compiled there.

## Live mode

- A removed method is still reachable through `Dynamic` calls and reflection.
- The patching thread's callee-saved registers are not scanned; the scan of other threads' stacks can refuse a patch
  over a stale spill slot. Static closures are guarded only on x64 (`jit_arm64.c` not updated).
- Hook identities are fixed at module load; a `liveRelease`/`liveRebuild` added by a patch runs only after a restart.
  A patch without guards calls `liveRebuild` but not `liveRelease`, so custom paint keys survive.
  `UiContext.releaseRetained` leaves animations and commands in place.
- A throwing `liveRelease`/`liveRebuild` is reported with a generic message. Arena blocks of the patch JIT leak.
  `SourceLineMap` lives only in memory. Adapters fill in only literal defaults. Renamed lambdas keep their old type
  names. A migration initializer that waits on another thread deadlocks.

## Build

- NativeKit is configured and built three times (agent, exohost, editor); libwebsockets' configure checks cost about
  30 s in each. Share one CMake tree, then build the apps side by side.
- A compiler cache shared across worktrees on Windows needs paths under 260 characters.
- Profile the editor's Haxe compile (about 50 s).
- `HostCommand` (vcvarsall, vswhere, `ninja --version`) has no timeout and never drains stderr; merge it into
  `ProcessRunner.capture`. `MsvcEnvironment` calls `Sys.putEnv` outside the launch lock. `NativeCMakeProvider` caches
  an empty `ninja --version` answer. A Visual Studio path with `&` or `^` breaks the environment read.

## Tests

- `tests/document-test` stops on Windows at "Save As did not assign identity after successful persistence".
- 9 of the 15 fixture-argument test projects fail on Windows (a hard-coded `/bin/sh`, `chmod 000`).
- `native-packages/processes/tests/run.sh` runs `ctest`; run the test executable through the guard instead.
