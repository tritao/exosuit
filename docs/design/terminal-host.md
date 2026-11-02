# Terminal hosts: terminals that outlive the service and the editor

Status: proposed (2026-11-01). Research and design only; nothing here is built.

Scope: the workspace service's terminals (Workbench terminals and agent-CLI terminals such as "Claude Code ·
Terminal"). The editor's own dock terminal (`graphical/src/ui/TerminalPane.hx:92`, a PTY inside the editor) and
headless agent provider processes are out of scope; see "Later" at the end.

Line references are to `daily` at `ea279833` (exosuit) and the Haxeon/NativeKit checkout under `haxeon/`.

---

## 1. Summary

Today the workspace daemon (the child `main.hl <pipe> ... catalog.sqlite ...` of `main.hl --manager`) owns every
terminal's PTY, emulator and replay log in its own process. Any restart of that daemon, for an update or a crash,
kills every shell and every program in it, including a live Claude Code session.

The fix is a **terminal host**: a small native program, **one process per terminal**, that owns exactly one PTY,
its job object, its emulator (screen state) and a bounded output journal. It is started by the service but is not
in the service's job and holds none of its handles, so it outlives the service, the manager and the editor. It
speaks a tiny, versioned, binary protocol over a private pipe. A new service generation finds the hosts from files
in its state directory, authenticates with a per-host token, and re-adopts them. Hosts are never replaced in place:
each runs the binary it started with, from a content-addressed copy, and new terminals get the newest binary. The
service keeps everything that changes often (catalog, grants, RPC to editors and devices, persistence); the host
keeps only what must not die.

The cursor space of a terminal (replay sequence and byte offset) becomes the host's, so an editor's replay cursor
stays valid across service restarts. Attach stays "screen snapshot at cursor C, then replay from C", as the fix in
progress makes it, but the snapshot and the journal now come from the host.

---

## 2. How terminals work today (verified in code)

### 2.1 Process tree

```
editor (graphical)
  └─ (helper) main.hl --manager ... --detach          short-lived; starts the manager detached
main.hl --manager --workspace <id> ... --background   AgentManager.runManaged
  └─ main.hl <pipe> <port> <credential> <seed> catalog.sqlite <root> <generation> <idle>   the daemon (AgentMain)
       ├─ conhost/OpenConsole (one per ConPTY)
       └─ pwsh.exe | claude.exe | cmd /d /c claude.cmd ...   the terminal's program, and its descendants
```

| Fact | Where |
|---|---|
| The manager is started detached: `sys.io.Process.spawn(..., true)`. | `agent/src/app/AgentManager.hx:748` |
| Detached spawn on Windows adds `CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB` and no job. | `haxeon/native/runtime/child_processes.c:384,405-406` |
| The manager starts the daemon non-detached: `sys.io.Process.spawn(Sys.executablePath(), [launcher].concat(daemonArgs), ...)`. | `AgentManager.hx:898-904` |
| A non-detached child gets a new job with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK`, assigned before it runs. | `child_processes.c:384-388,414` |
| Child stdio are inherited pipes (`bInheritHandles = TRUE` with a handle list of the three pipe ends). | `child_processes.c:370-376,407` |
| The daemon builds `WorkspaceTerminalManager` in-process. | `agent/src/app/AgentMain.hx:152` |
| The manager's lock descriptor is passed to the daemon (`EXOSUIT_AGENT_LOCK_FD`); the daemon guards it at start. | `AgentManager.hx:1083-1084`, `AgentMain.hx:76` |
| Only one manager per state directory: `agent.lock`. | `AgentManager.hx:841-847` |

### 2.2 Creating a terminal

1. `OPEN` with `create: true` (method 110) reaches `WorkspaceTerminalManager.bind`
   (`agent/src/workspace/runtime/WorkspaceTerminalManager.hx:354-466`).
2. Limits: 16 live terminals (`count >= 16`, line 385), 256 catalog records (line 381).
3. The directory comes from the group, the explicit directory, or the root (`WorkspaceDirectories.forSession`,
   lines 389-396).
4. A record is saved as `starting` before the spawn (lines 397-416), then `running` after (lines 441-450).
5. The profile: `TerminalProfile.shell(cwd)` (pwsh from PATH, then Windows PowerShell, then `ComSpec`) or
   `TerminalProfile.agent(provider, cwd)` (resolves `claude`/`codex`/`pi` on PATH, `.cmd` shims run under
   `cmd /d /c`) (`native-packages/terminal/session/haxe/terminalsession/TerminalProfile.hx:139-200`).
6. Environment: a snapshot of the **daemon's** whole environment, minus `NO_COLOR`, plus `TERM=xterm-256color`
   (`TerminalProfile.hx:212-229`). So a terminal inherits whatever the daemon inherited from the manager.
7. `LocalPtyBackend.spawn` calls `nk_pty_spawn` (`LocalPtyBackend.hx:26-33`).

### 2.3 Who holds the PTY (Windows, ConPTY)

`win_spawn` in `haxeon/vendor/nativekit/src/core/pty.cpp:445-605`:

| Step | Lines |
|---|---|
| Two anonymous pipes; `CreatePseudoConsole(size, in, out, 0, &console)`. | 496-506 |
| A **per-terminal job** with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. | 507-516 |
| `CreateProcessW(..., bInheritHandles = FALSE, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED, ...)` with the pseudoconsole attribute; no breakaway flag. | 526-543 |
| The child is assigned to the per-terminal job before it resumes, so its descendants are in it too. | 549-558 |
| Three threads per PTY: reader (into a 1 MiB pending buffer), writer, exit monitor. | 266-336, 565-602 |
| Kill = `TerminateJobObject`. | 338-344 |
| Close: kill if alive, `ClosePseudoConsole`, join threads, close process, job and pipe handles. | 346-375 |
| A NativeKit runtime shutdown hook closes every PTY. | 383-390, 564 |

Consequences. Three independent mechanisms tie a terminal to the daemon process:

1. **The per-terminal job handle** is held only by the daemon. When the daemon exits for any reason, the last
   handle closes and `KILL_ON_JOB_CLOSE` terminates the shell and all its descendants.
2. **The daemon's own job.** The terminal's program is created without `CREATE_BREAKAWAY_FROM_JOB`, so it is also in
   the job the manager created for the daemon (nested jobs). When the manager closes that job, or exits, the
   terminal dies even if the per-terminal job did not exist. `child.cancel()` in the manager (`AgentManager.hx:974`)
   is one such path.
3. **The ConPTY.** The `HPCON` belongs to the daemon. When the daemon closes it (or dies and its handles close), the
   console host ends the session: `ClosePseudoConsole` "will send CTRL_CLOSE_EVENT to each client application that
   is still connected" ([ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole)).
   An `HPCON` cannot be handed to another process through any documented API.

So no change inside the daemon can keep a ConPTY session across a daemon restart. Some process other than the
daemon has to own the `HPCON`, the job and the pipes, and that process must not be in the daemon's job.

### 2.4 POSIX

`forkpty` with `close_range(3, ~0)` in the child before `execve` (`pty.cpp:755-781`); the daemon holds the master
fd with `FD_CLOEXEC`. Close sends `SIGKILL` to the PTY's process group (`kill_pty_group`, `pty.cpp:70-77,93-111`).
When the daemon dies, the master closes and the session gets `SIGHUP`. Same conclusion: the master fd must live in
a process that outlives the service.

### 2.5 Output flow

`WorkspaceTerminalManager.poll` runs every daemon tick (`AgentMain.hx:241-282`, a 10 ms event wait):

- `backend.pollEvents` reads up to 4 × 64 KiB per tick (`LocalPtyBackend.hx:60-83`).
- Each chunk is fed to the daemon's emulator (`Emulator.open(columns, rows, 1000, "xterm-256color", false)`,
  1000 lines of scrollback, `WorkspaceTerminalManager.hx:37`), the emulator's replies (DA, OSC 10/11 answers) are
  written back to the PTY, and the chunk is appended to the replay journal (`WorkspaceTerminalManager.hx:716-723`).
- The journal (`src/workspace/service/TerminalReplayLog.hx`) holds output and geometry records with a sequence
  (cursor) and a byte offset, bounded to 16 MiB and 4096 records (`TerminalReplayLog.hx:35-47`;
  limit `16777216` at `AgentMain.hx:152`). Trimming moves `startCursor`.
- Rendered history (`terminalkit_history_copy`, at most 4 MiB, `native-packages/terminal/include/terminalkit.h:99-102`)
  is saved to SQLite at most every 2 s (`WorkspaceTerminalManager.hx:178-185,734-735`) in
  `workspace_terminal_history` (`agent/src/workspace/storage/WorkspaceSqliteStore.hx:102`). Records are in
  `workspace_terminals` (`WorkspaceSqliteStore.hx:60`).
- `SNAPSHOT` (119) returns `emulator.screenSnapshot()` and `replay.endCursor` (`WorkspaceTerminalManager.hx:504-523`).
  The snapshot format "PTSMVTS" v2 is encoded in Haxe (`native-packages/terminal/haxe/terminalkit/Emulator.hx:181-219`)
  and decoded in C (`terminalkit_restore_screen_snapshot`, `terminalkit.h:103-106`).
- `REPLAY` (138) serves journal batches of at most 128 records / 64 KiB (`TerminalReplayLog.hx:48-59`).
- `CHANGED` (139) notifications are coalesced per tick (`WorkspaceTerminalManager.hx:689-707`).

### 2.6 Input, resize, control

- `INPUT` (112): the connection must be the controller; per-connection sequence numbers; the sequence is reserved
  before writing, and a failed write is reported as ambiguous, never retried (`WorkspaceTerminalManager.hx:548-580`).
- `RESIZE` (113): resizes PTY, emulator and journal geometry (lines 582-616).
- `TERMINATE` (114): `nk_pty_kill` (lines 617-634). `RESTART` (156): new shell in the same record, after moving the
  old screen into scrollback (lines 635-686).

### 2.7 What happens on service exit and restart

- Update: the editor sees another build (`serviceUpdateAvailable`, `src/workspace/client/LocalWorkspaceClient.hx:179-181`;
  label "Workspace update available", lines 506-507). It runs `--prepare-update` (a build), then sends `UPDATE`
  with mode `idle` or `now` (lines 185-220, 243-256). It auto-requests `idle` only when the service reports zero
  terminals and zero agents (lines 306-311).
- The daemon restarts only when `pending && (force || terminals == 0 && agents == 0)`
  (`src/workspace/service/WorkspaceUpdatePolicy.hx:14-17`, checked at `AgentMain.hx:291`). So today an update
  either waits for every terminal to end, or ("now") kills them.
- On exit the daemon calls `terminals.dispose()` (`AgentMain.hx:306`), which saves history and closes every PTY
  (`WorkspaceTerminalManager.hx:753-763`), then prints `STOPPED: exosuit-agent update` and the manager starts a new
  generation (`AgentManager.hx:923-924,951,990-991`).
- Idle exit: the daemon stays up while it has clients or active sessions (`WorkspaceLifetime.hx:14-22`,
  `AgentMain.hx:295`), so running terminals keep it alive today.
- A new generation loads the catalog; every record whose `instance` is another generation and whose state is
  `running` or `starting` becomes `lost` (`WorkspaceTerminalManager.hx:86-90`). Opening it gives a read-only view
  built from saved history (`restoreHistory`, lines 157-177).
- Every terminal request carries `instance` and is refused unless it equals the daemon's generation (`valid`,
  lines 222-223). The editor notices a new generation and **resets** its view: drops queued input, sets
  `replayCursor = 0`, and starts over (`src/workspace/client/RpcTerminalBackend.hx:399-409`).
- `unknown_terminal` and `replay_gap` become user-visible failures (`RpcTerminalBackend.hx:206-216`); a
  `snapshot_unavailable` reply shows "Terminal screen snapshot is unavailable" (lines 600-601). This is problem 2;
  the in-progress fix moves attach to snapshot + replay from the snapshot's cursor.

### 2.8 suit

- Kinds: `workspace-manager`, `workspace-host` (the daemon), compiler workers, live sessions (`src/suit/SuitKind.hx:37-46`).
- Stop policy: the manager by `stop-request.json`, the daemon through its manager (`SuitKind.hx:63-70`).
- After a stop's grace period suit kills the target and sweeps its descendants of exosuit kinds, never a whole tree
  (`suit/README.md`, "Stopping"; `SuitLineage.exosuitDescendants`, `suit/src/suit/SuitLineage.hx:70`). Terminals end
  because the daemon closes its PTYs, and a program in a terminal is never adopted because a shell sits between it
  and the daemon (`suit/README.md`, "Ownership is positive").
- Registration is a file drop into suit's registry (`src/suit/SuitRecord.hx`), validated by pid start time.
- Process identity uses pid plus start time (`native-packages/processes/include/processkit.h:99-114`).
- `AgentManager.processAlive` always answers true on Windows (`AgentManager.hx:701-705`), noted as a gap in
  `docs/roadmap/NEXT-PHASE.md`.

### 2.9 Transport security available to reuse

- NativeKit's named pipes: a DACL with one ACE for the current user, `PIPE_REJECT_REMOTE_CLIENTS`, and
  `FILE_FLAG_FIRST_PIPE_INSTANCE` on the first instance so a squatter makes listening fail
  (`haxeon/vendor/nativekit/src/transport/transport.cpp:313-366`). The server records the client's pid
  (`GetNamedPipeClientProcessId`, line 2181) and has `process_is_current_user` (line 368).
- The local workspace pipe has no token; it relies on that ACL (`WorkspaceRpcServer.acceptLocal`,
  `src/workspace/transport/WorkspaceRpcServer.hx:150-152`). The loopback WebSocket uses the 64-hex credential file
  (`AgentManager.hx:1067-1075`, `WorkspaceRpcServer.hx:160-162`).
- Pipe names today: `\\.\pipe\exosuit-<sha256(key + "\n" + stateDir)[0..20]>`; Unix sockets in the state directory,
  at most 100 characters (`AgentManager.hx:895-896,1127-1131`).

---

## 3. Requirements

| # | Requirement |
|---|---|
| R1 | A terminal's program keeps running, with its screen, across a restart, update or crash of the workspace daemon, the manager, the editor and suit. |
| R2 | A new service generation re-adopts every live terminal without user action, and an attached editor continues where it was (no reset, no lost or repeated input). |
| R3 | The process that owns the PTY changes rarely, and when its code changes, live terminals are unaffected. |
| R4 | A crash of one terminal's owner affects only that terminal. |
| R5 | Only the same OS user can reach a terminal; nothing remote; no new privilege. |
| R6 | No terminal is ever silently duplicated, respawned, or left without anyone able to see or end it. |
| R7 | Input latency does not get noticeably worse (`live-responsiveness-first`): at most +1 ms p95 keystroke to echo. |
| R8 | No modal dialogs, no hangs: everything unattended exits or times out (`CLAUDE.md`). |
| R9 | Works on Windows first; Linux and macOS with the same protocol. |
| R10 | Old services and old catalogs keep working; downgrades never corrupt state. |

Non-goals: surviving a reboot or logout (processes cannot); moving terminals between machines; live code
replacement of a running host on Windows.

---

## 4. Prior art

| System | Who owns the PTY | Survives client restart | Survives owner update | Screen on reattach |
|---|---|---|---|---|
| tmux | one server per socket, all sessions | yes | no: a client and server with different `PROTOCOL_VERSION` refuse to talk ("protocol version mismatch"); the advice is to kill the server, losing sessions ([discussion](https://wiki.neonvagabond.xyz/content/unix.stackexchange.com_en_all_2024-05/questions/122238/protocol-version-mismatch-client-8-server-6-when-trying-to-upgrade)) | server's grid, full redraw |
| GNU screen | one process per session | yes | the running session keeps its old binary; attach across incompatible versions fails | own grid |
| dtach / abduco | one tiny process per session | yes | yes in practice: the protocol is a few raw-byte messages that never change | none; the program must redraw (Ctrl-L / SIGWINCH) |
| shpool | one daemon per user, many sessions | yes | daemon restart loses shells | keeps "an in-memory render of terminal state" (vt100) and redraws it on reattach ([README](https://github.com/shell-pool/shpool)) |
| VS Code | one pty host process (node-pty) per app, separate from windows | window reload: yes; detached terminals are kept for a grace time (`LocalReconnectConstants.GraceTime = 60000`, [terminal.ts](https://github.com/microsoft/vscode/blob/main/src/vs/platform/terminal/common/terminal.ts)) | no: on app restart or pty host restart, processes are lost (`onPtyHostRestart`: "its pty has been lost") and are "revived" as new processes with the old buffer | headless xterm in the pty host, serialized |
| Windows Terminal | the Terminal process owns each `HPCON` | no | no | can restore buffer text into new shells (persisted layouts); processes are new |
| Zellij | one server per session | yes | no; "session resurrection" saves layout and commands and re-runs them behind "Press ENTER to run..." ([docs](https://zellij.dev/documentation/session-resurrection.html)) | optional serialized viewport and scrollback |

Lessons taken:

1. **A server that also does everything else cannot be updated without killing sessions** (tmux, Zellij, VS Code,
   and Exosuit today). The PTY owner must be separate from the code that changes.
2. **The smallest owners survive best** (dtach, abduco): a protocol that never changes means any client generation
   can attach.
3. **Keep the screen next to the PTY** (shpool, VS Code's pty host, tmux): reattach must not depend on replaying an
   unbounded history. dtach's "let the program redraw" is not enough for Claude Code or `less`.
4. **One process per session** (screen, dtach) bounds the damage of a crash and lets versions coexist; one server
   for all (tmux, shpool, VS Code) saves memory but turns every owner bug or update into a total loss.
5. **Revive is a fallback, not the fix** (VS Code, Zellij, Windows Terminal). Exosuit already has it
   (`RESTART` from saved history).

---

## 5. Design

### 5.1 Components

```
editor ──RPC (unchanged methods)──▶ workspace daemon ──host protocol (new, tiny)──▶ terminal host ──ConPTY/PTY──▶ shell
                                    (changes often)                                  (one per terminal,
                                                                                      changes rarely)
```

| Component | Owns | Changes when |
|---|---|---|
| **Terminal host** `exosuit-term-host` (new, native) | one PTY (`HPCON` or master fd), its job (Windows) or session (POSIX), the child, one emulator, one output journal, exit status | PTY or emulator bugs; protocol revisions |
| **Workspace daemon** (existing) | catalog records, names, groups, order, grants, controller arbitration, editor and device RPC, SQLite history, spawning hosts, adopting hosts | any service change |
| **Editor** (existing) | views | any UI change |
| **suit** (existing) | inventory and display of hosts, stopping them on request, cleanup of dead host directories | tray and machine changes |

### 5.2 Decision: one host per terminal

| | One host per terminal | One host per workspace | One host per user (in suit or a new daemon) |
|---|---|---|---|
| Crash damage | one terminal | all terminals of the workspace | all terminals |
| Update | each terminal keeps its version; new terminals take the new one | the host must be replaced, or every terminal waits for the last to end | same, wider |
| Code | no multiplexing, no catalog, no internal lifetime policy | needs ids, per-terminal flow control, its own lifetime rules | as per workspace, plus cross-workspace security |
| Process count | one per terminal (plus the conhost per ConPTY that exists today) | one per workspace | one |
| Memory | a native host is a few MB plus its buffers (5.12) | slightly less | slightly less |

The extra process per terminal is cheap next to what each terminal already costs (a conhost and a shell, often a
node process for an agent CLI), and the cap is 16 per workspace (`WorkspaceTerminalManager.hx:385`). Isolation and
version coexistence are the requirements (R3, R4) that a shared host cannot meet without becoming the thing we are
escaping. Chosen: **one host per terminal**.

### 5.3 Decision: a native host, not a HashLink one

The host is a small C++ program built with CMake. It links statically:

- NativeKit's PTY core (`pty.cpp` and the core runtime it needs: handles, events), built module-only the way
  `haxeon-credentials` builds only its NativeKit module (`docs/roadmap/NEXT-PHASE.md`, build notes), or a trimmed
  copy of `win_spawn`/`posix` spawn if the core's runtime proves too heavy;
- TerminalKit and libtsm (`native-packages/terminal/src/terminalkit.c`, `vendor/libtsm`);
- the pipe security code from `transport.cpp:313-366` (copied into a small helper, or linked).

Why not a HashLink host built like the daemon:

- It would depend on `hl.exe`, `libhl`, `nativekit.dll`, hdlls and the Haxeon compiler and runtime, which change
  weekly (`docs/haxeon-compiler-bugs.md`, live-mode work). Each change is a new host version, and a runtime bug
  (for example the 0xC0000409 fail-fast exits in NEXT-PHASE "From GUI verification") would kill terminals.
- Windows locks loaded EXEs and DLLs. A long-lived HL host would lock `nativekit.dll` and the hdlls in the build
  tree, and builds would fail to overwrite them (the "hdll lock" problem in the merge-gate notes). A single static
  EXE copied to a versioned folder locks nothing in the build tree.
- Loader and HashLink fatal-error dialogs (`CLAUDE.md`) cannot happen in a static native EXE with no DLL search.
- Memory: an HL process with the GC heap is tens of MB; a native host is a few MB (5.12).

The cost is a second language for about 2,000-3,000 lines. The protocol is specified with byte vectors and tested
from both Haxe and C (Phase 1), so the two sides cannot drift. Open question Q2 asks the user to confirm.

### 5.4 Process model and ownership

#### Windows

The daemon spawns the host with a dedicated launch call (new; the existing `sys.io.Process.spawn` cannot do it,
see below):

| Setting | Why |
|---|---|
| `CREATE_BREAKAWAY_FROM_JOB` | Leave the daemon's job, which has `BREAKAWAY_OK` (`child_processes.c:386-387`). The manager already broke away from the editor's jobs (`child_processes.c:406`), so there is no outer job that forbids it. |
| No new job for the host itself | Nothing may hold a kill-on-close job over the host except the host. |
| `bInheritHandles = FALSE`, stdio to `NUL`, `STARTF_USESTDHANDLES` with null handles | The host must not inherit the manager's lock (`EXOSUIT_AGENT_LOCK_FD`, `AgentManager.hx:1083-1084`) or the daemon's pipes. An inherited lock handle would keep `agent.lock` held for as long as any terminal lives, and the next manager would refuse to start (`AgentManager.hx:841-847`). `sys.io.Process.spawn` always inherits three pipes (`child_processes.c:370-376,407`), so it is not used. |
| `CREATE_NO_WINDOW`, `CREATE_NEW_PROCESS_GROUP` | No console window; Ctrl-C to the service's group does not reach the host. |
| Current directory: the host's own state folder | The host must not pin the workspace folder (Windows cannot rename a folder that is some process's current directory). The shell still starts in the terminal's directory. |
| Environment: exactly the block the daemon would have given the shell (5.6) | The host passes it to the PTY child unchanged. |

Inside the host:

- `SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX)` for itself, and
  `CREATE_DEFAULT_ERROR_MODE` on the PTY child, so the user's programs keep normal error reporting while the host
  never shows a dialog (R8). Release build, static CRT, no `assert`/`abort` dialogs.
- The PTY job keeps `KILL_ON_JOB_CLOSE` (`pty.cpp:507-516`), now held by the host. If the host dies, its terminal's
  processes end. That is intended: a terminal is never left running with no owner anyone can reach (R6).
- The PTY child is created without breakaway, so it is in the host's PTY job only.

If `CREATE_BREAKAWAY_FROM_JOB` fails with `ERROR_ACCESS_DENIED` (an outer job without `BREAKAWAY_OK`, for example
a manager started from a restricted harness), the daemon asks suit to start the host (5.9); suit is started
detached and is in no exosuit job. If that also fails, the daemon falls back to the in-process PTY of today and
marks the terminal `hosted: false`, so the UI can say "This terminal ends if the workspace service restarts".

#### Linux and macOS

`posix_spawn` (or `fork`) then, in the host: `setsid()` (new session and process group, no controlling
terminal), `SIGHUP` ignored, all descriptors above 2 closed (`close_range`), stdio to `/dev/null`, `chdir` to
the host folder. The PTY child is created by `forkpty` in the host and gets its own session (`pty.cpp:755-781`).
The service's death neither closes the master nor signals the host's group.

Caveats, documented, not solved:

- Under a systemd user unit with `KillMode=control-group`, stopping the unit kills everything in its cgroup,
  hosts included. Exosuit does not run under a unit today (no login autostart). If it ever does, hosts are started
  with `systemd-run --user --scope` or by suit outside the unit.
- logind's `KillUserProcesses=yes` ends hosts at logout. Acceptable (non-goal).

### 5.5 Files on disk

Per terminal, under the workspace's state directory (already private and owner-checked by the manager):

```
<stateDir>/terminal-hosts/<hostKey>/          hostKey = hex(sha256(terminalId))[0..24]; private directory
    spec.bin        written by the daemon, read and deleted by the host at start (5.6)
    host.json       written atomically by the host when ready (below)
    host.log        bounded (1 MiB, then truncated to the last half); never contains input or environment
    final.bin       written by the host when its program exits with no owner attached (5.8)
```

Host binaries, per user, outside any build tree:

```
%LOCALAPPDATA%\Exosuit\terminal-host\<sha256 of the exe, 16 hex>\exosuit-term-host.exe
~/.local/state/exosuit/terminal-host/<hash>/exosuit-term-host        (XDG_STATE_HOME), macOS: ~/Library/Application Support/Exosuit/...
```

`host.json` (private file, at most 16 KiB, checked like `endpoint.json` in `AgentManager.readDiscovery`,
`AgentManager.hx:637-670`):

```json
{
  "version": 1,
  "protocol": {"min": 1, "max": 1},
  "host": "<exe hash>",
  "terminal": "<terminal id>",
  "stream": "<32 hex, random per host start>",
  "pid": 1234,
  "started": 1761990000.123,
  "endpoint": "\\\\.\\pipe\\exosuit-term-<32 hex random>",
  "token": "<64 hex>"
}
```

`started` is the process start time as processkit reports it (`processkit_started`, `processkit.h:99`), so a reused
pid is never mistaken for the host. The token lives here, not on a command line: command lines are readable by any
process of the user and suit scans them (`suit/README.md`, "Scanning").

### 5.6 Spawn handshake

1. The daemon saves the record `starting` (as today, `WorkspaceTerminalManager.hx:397-416`), with `host` set to the
   new `hostKey` and a fresh `stream` value it chose.
2. It writes `spec.bin` atomically and privately: protocol version, terminal id, stream, token, endpoint, program,
   argv, cwd, the complete environment block (`TerminalProfile.childEnvironment()`), columns, rows, scrollback lines
   (1000), journal limit, theme colors, and optional seed history bytes (for `RESTART`, 5.10).
3. It launches the installed host binary with one argument: the host folder.
4. The host reads and deletes `spec.bin`, creates its pipe (first instance), spawns the PTY, writes `host.json`,
   and starts serving.
5. The daemon connects (retry every 20 ms, deadline 5 s), sends `HELLO`, and on `WELCOME` saves the record
   `running`. On timeout it kills the host by pid and start time (`processkit_terminate`, `processkit.h:108`) and
   saves `failed`.

The spec carries secrets that the environment may hold (API keys), so it is private, short-lived, and the host
never logs it.

### 5.7 Protocol v1

Design rules:

- Frames: `u32 length` (of what follows), `u16 type`, `u16 flags`, `u32 id` (request id; 0 for notifications),
  then the payload. Little-endian. Maximum frame 4 MiB + 64 bytes (a history reply).
- Payloads are fixed fields followed by length-prefixed byte strings. A newer version may only **append** fields;
  a reader ignores trailing bytes it does not know. Types are never reused. Unknown types get `ERROR unsupported`.
- Versions are negotiated once in `HELLO`/`WELCOME`. Features inside a version are capability bits in `WELCOME`.
- The service must speak every protocol version a live host may run (rule in 5.11). The host never needs to know a
  newer service.
- No message makes the host run anything other than its one program. There is no spawn, exec, file or environment
  message. The protocol surface is what an attached keyboard and screen can do.

Messages (S = service to host, H = host to service):

| Type | Dir | Payload | Reply |
|---|---|---|---|
| `HELLO` 1 | S | protocol min/max, token (32 bytes), client kind (service, suit, diagnostic), client build (string), `takeover` flag | `WELCOME` or `ERROR` |
| `WELCOME` 2 | H | protocol, capabilities (u64), host build, terminal id, stream, pid, state (`running`/`exited`), exit code, signal, columns, rows, journal `startCursor`/`endCursor`/`startOffset`/`endOffset`, owner flag | |
| `SNAPSHOT` 3 | S | none | `SCREEN`: PTSMVTS v2 bytes and the cursor they correspond to (atomic) |
| `READ` 4 | S | cursor, max bytes | `EVENTS`: records `{sequence, offset, data, columns, rows}`, exactly `TerminalReplayEvent` (`WorkspaceTerminalProtocol.hx:66-73`), `next`, `end`; or `ERROR gap` |
| `SUBSCRIBE` 5 | S | cursor, credit (bytes) | host pushes `EVENTS` notifications from the cursor while credit lasts |
| `CREDIT` 6 | S | bytes | adds credit |
| `INPUT` 7 | S | sequence (u64), bytes (at most 64 KiB) | `ACK` sequence; a sequence at or below the last applied one on this connection is acknowledged without writing |
| `RESIZE` 8 | S | columns, rows | `ACK`; a geometry record is appended to the journal |
| `COLORS` 9 | S | foreground, background | `ACK`; emulator replies (palette notifications) go to the PTY, as `applyTheme` does today (`WorkspaceTerminalManager.hx:100-106`) |
| `SIGNAL` 10 | S | `interrupt` (Ctrl-C byte / SIGINT), `terminate` (job / process group), `hangup` (POSIX) | `ACK` |
| `HISTORY` 11 | S | none | `HISTORY`: `terminalkit_history_copy` bytes (at most 4 MiB) and the cursor |
| `EXITED` 12 | H | exit code, signal, final cursor; sent after the journal holds every byte the program wrote (the drain rule of `pty.cpp:318-336`) | |
| `RELEASE` 13 | S | none | `ACK`, then the host closes the PTY (killing what is left), deletes its folder and exits |
| `PING` 14 | S/H | nonce | `PONG` |
| `OWNER_LOST` 15 | H | none | sent to the previous owner on takeover, then that connection closes |
| `ERROR` 16 | H | code, message | |

Ownership: a host has at most one **owner** connection. Only the owner may send `INPUT`, `RESIZE`, `COLORS`,
`SIGNAL`, `RELEASE`. Other authenticated connections (suit, diagnostics) may read. `HELLO` with `takeover` makes
the caller the owner and sends `OWNER_LOST` to the old one. Two service generations of one workspace never run at
the same time because of `agent.lock`, so takeover races are not expected; the rule makes the last valid owner win
if they ever happen.

Flow: the host reads the PTY continuously, whether or not anyone is attached. Output always goes into the emulator
and the journal, so a slow or missing service never blocks the program and the snapshot is always current.
`SUBSCRIBE` pushes are bounded by credit. If the service falls behind the journal's start, it gets `gap` and takes a
`SNAPSHOT`.

Errors: `unauthorized`, `unsupported`, `not_owner`, `gap`, `invalid`, `exited`, `busy`. Three failed `HELLO`s on
one connection close it.

Wire vectors for every message go in `docs/roadmap/RPC-VECTORS.md`'s style, in a new
`docs/roadmap/TERMINAL-HOST-PROTOCOL.md`, and are checked by both the C and the Haxe codecs (Phase 1).

### 5.8 Host lifecycle

```
start ─▶ running ──program exits──▶ exited ──RELEASE──▶ gone
            │                          │
            │ (no owner, any time)     └─ no owner: write final.bin, exit after 60 s with no owner ─▶ gone
            └─ owner disconnects: keep running, keep reading, wait for a new owner
```

- **Running, no owner.** Normal during a service restart. The host keeps running indefinitely. Every 30 s, if the
  screen changed and no owner is attached, it writes `final.bin` (history copy, geometry, cursor), so a reboot
  during a long service outage still leaves recent history.
- **Exited, owner attached.** The host sends `EXITED`, keeps serving `SNAPSHOT`/`READ`/`HISTORY`, and waits for
  `RELEASE`. The service saves history and the record (`exited`, code), then sends `RELEASE`.
- **Exited, no owner.** The host writes `final.bin` with the exit code and signal, waits 60 s for an owner, then
  exits. The next service imports `final.bin` into SQLite, marks the record `exited`, and deletes the folder.
  An exit status is never lost (R6).
- **Explicit end.** `FORGET` with `terminate` or `TERMINATE` from the editor becomes `SIGNAL terminate`, then
  `RELEASE` once exited.

### 5.9 Discovery and re-adoption by a new service generation

At daemon start, before serving RPC, `WorkspaceTerminalManager` replaces the "mark lost" loop
(`WorkspaceTerminalManager.hx:83-93`) with:

1. For each record with a `host` key whose state is `running` or `starting`:
   1. Read `host.json` (private-file and size checks). Missing: go to 1.4.
   2. Check `pid` and `started` with `processkit_identify` (`processkit.h:106`). Not alive: go to 1.4.
   3. Connect, `HELLO` with `takeover`, compare `terminal` and `stream` with the record. Mismatch: log, treat as
      not adoptable, leave the host alone (it may belong to another record after a `RESTART`; step 2 handles it).
   4. On success: the record keeps `running`, `instance` becomes this generation, revision + 1. On failure with the
      process alive but not answering within 2 s: state `unreachable` in memory (not persisted as a new state, see
      10), retry with backoff; never spawn a replacement. On failure with the process gone: import `final.bin` if
      present (state `exited`), else `lost` as today.
2. Scan `terminal-hosts/` for folders no record references (a crash between spawn and the `running` save). If the
   host is alive and its `terminal` id has a `starting` record, adopt it. Otherwise keep it in an "unclaimed" list
   that the service exposes to suit and to the Machine view; never kill it automatically (it may be a user's
   program).
3. Delete folders whose host is gone and whose `final.bin` was imported.

Adoption is fast: one file read, one process check and one round trip per terminal. 16 terminals adopt in well
under 100 ms locally.

Editor side: the service reports the host's cursors as the terminal's cursors and adds `stream` to `TerminalInfo`
(new optional field 17). `RpcTerminalBackend` keeps its replay cursor across a generation change when `stream` is
unchanged, instead of resetting (`RpcTerminalBackend.hx:399-409` changes): it drops queued input as now (input is
never retried across connections, `WorkspaceTerminalProtocol.hx:153`), re-`OPEN`s with the new instance, and
continues `REPLAY` from its cursor. If `stream` changed (a restarted shell) or is absent (an old service), it
resets as today.

### 5.10 Service-side changes

`WorkspaceTerminalManager` today mixes catalog logic with the in-process runtime (`RuntimeTerminal`). Split it:

```haxe
interface TerminalRuntime {
  var state(default, null):String; var exitCode(default, null):Int;
  var columns(default, null):Int;  var rows(default, null):Int;
  var startCursor(get, never):Int64; var endCursor(get, never):Int64;
  var startOffset(get, never):Int64; var endOffset(get, never):Int64;
  var stream(default, null):Null<String>;
  function read(cursor:Int64, done:ReplayBatch->Void, failed:String->Void):Void;   // REPLAY
  function snapshot(done:{data:Bytes, cursor:Int64}->Void, failed:String->Void):Void;
  function history(done:Bytes->Void, failed:String->Void):Void;
  function write(sequence:Int, bytes:Bytes):Void;          // throws on ambiguous delivery
  function resize(columns:Int, rows:Int):Void;
  function colors(theme:TerminalTheme):Void;
  function terminate():Void;
  function detach():Void;                                   // service exit: host keeps running
  function release():Void;                                  // the terminal is finished
  function poll(changed:Void->Void):Void;
}
```

- `InProcessTerminal`: today's `RuntimeTerminal` + `LocalPtyBackend` + emulator + `TerminalReplayLog`. Kept as the
  fallback (5.4), for read-only history views (`restoreHistory`), and for platforms without a host binary.
- `HostedTerminal`: a `TerminalHostClient` (Haxe codec of 5.7 over a NativeKit local transport). It caches the
  most recent journal window the editor is reading, so `REPLAY` is usually served without a round trip.
- `SNAPSHOT`, `REPLAY` and `OUTPUT` become asynchronous in the handlers (`c.respond` later); `RpcConnection`
  handlers already respond asynchronously (`HAXEON-RPC.md`, RPC.1).
- `dispose()` calls `detach()` on hosted terminals instead of closing PTYs (today `WorkspaceTerminalManager.hx:753-763`).
- `RESTART` (lines 635-686): spawn a new host with the old history as seed (the separator logic moves to the spec),
  new `stream`; the old host is `RELEASE`d.
- History persistence: every 2 s while dirty, `HISTORY` from the host, saved to SQLite as today.
- `TerminalRecord` gets optional `host` (hostKey) and `stream`. States stay in the existing set
  (`starting/running/exited/failed/lost`) so an older service can still load the catalog (10).

Lifecycle and update policy:

- `WorkspaceUpdatePolicy.shouldRestart` counts only in-process terminals (`AgentMain.hx:291`); hosted ones do not
  block an update.
- `WorkspaceServiceStatus` reports `terminals` = in-process count (what blocks an update) and a new
  `hostedTerminals`. The editor's automatic `idle` update (`LocalWorkspaceClient.hx:306-311`) then happens while
  hosted terminals run.
- The label (`LocalWorkspaceClient.hx:506-507`) stays "Workspace update available"; the update confirmation says
  "Terminals keep running" when every live terminal is hosted, and lists the ones that will end otherwise.
- Idle exit: hosted terminals still count as activity for `WorkspaceLifetime` at first (unchanged behaviour,
  `AgentMain.hx:295`), so exit codes and history flow into SQLite promptly. Correctness does not depend on it (5.8);
  letting the service idle out while hosts run is open question Q4.

### 5.11 Updating the host itself

- **Install.** At daemon start the daemon hashes the host binary of its build and copies it to
  `terminal-host/<hash>/` if absent (write to a temp name, then rename). New terminals use that path. The build
  tree's copy is never executed, so builds never hit a locked EXE.
- **Coexistence.** Live hosts keep running the version they started with. A host's version is in `host.json` and
  `WELCOME`.
- **Compatibility window.** A service must speak protocol versions `[oldest live, current]`. The service refuses to
  drop support for a version while any `host.json` under its state names it; tests keep vectors for every released
  version. In practice protocol v1 should last a long time; a new version is needed only for a new capability that
  cannot be a capability bit.
- **Garbage collection.** A version folder is deleted when no `host.json` on the machine references it and it is
  not the newest. suit does this (it sees every workspace's state, 5.13); without suit, each daemon cleans the
  versions its own hosts no longer use, never deleting a file in use (Windows refuses anyway).
- **A host bug or security fix.** Live hosts are not changed. The UI marks terminals running a withdrawn host
  version ("This terminal runs an outdated terminal host; restart it when convenient"), and "Restart Terminal"
  replaces it with a new host seeded with the history. A list of withdrawn versions ships with the service.
- **POSIX live upgrade (later, optional).** A POSIX host can `execve` a newer binary in place, keeping the master fd
  and its child (the pid stays, so `waitpid` still works), passing its emulator state with `terminalkit_checkpoint`
  (`terminalkit.h:95-98`) and the journal through a memfd. Windows cannot do this: the `HPCON` and job belong to the
  process. Not planned until there is a need.

### 5.12 Costs

| Item | Per terminal | Notes |
|---|---|---|
| Host code and runtime | about 2-4 MB private working set | static native EXE; three PTY threads as today plus one I/O thread |
| Emulator | 1000 scrollback lines × columns × cell size; about 2-5 MB at 200 columns | today the same emulator lives in the daemon; it moves, it does not double. The daemon keeps no emulator for hosted terminals. |
| Journal | default **4 MiB** (today 16 MiB in the daemon) | attach no longer needs deep replay (snapshot + cursor); 4 MiB covers reconnect gaps. Configurable. |
| Daemon cache | at most 256 KiB per attached terminal | recent journal window |
| CPU idle | zero; the host blocks in waits | no polling loop; today's daemon polls every 10 ms for all terminals |
| CPU under output | one extra copy and one local pipe hop per chunk | the emulator feed moves from daemon to host, so total emulator work is unchanged |
| Latency | one extra local pipe hop on input and on output, tens of microseconds | measured in Phase 2 with `docs/benchmarks/input-latency`; budget +1 ms p95 (R7). Output may get faster: the host pushes instead of waiting for the daemon's 10 ms tick. |
| Processes | +1 per terminal | cap 16 per workspace |

### 5.13 suit's role

suit does not own terminals. It must not: it is a HashLink app that changes and restarts often and exits when idle
(`suit/README.md`, "Daemon"), which would recreate the problem one level up. Its jobs:

1. **Inventory.** New kind `terminal-host` in `SuitKind` (`src/suit/SuitKind.hx:37-108`). The daemon writes the
   host's registry record after the spawn (`adopted: true`, `owner`: none, `stateDir`, `workspace`). Scanning
   recognizes `exosuit-term-host` processes by name (`SuitClassifier`).
2. **Never swept with its parent.** The host's parent pid is the daemon even after breakaway. `terminal-host` must
   not be in `spawnedByExosuit` (`SuitKind.hx:86-91`) and must be excluded from `exosuitDescendants`
   (`SuitLineage.hx:70`), so stopping a workspace service does not kill its terminals. Its orphan rule is `Never`:
   "Terminate orphaned" never ends a user's terminal.
3. **Stop on request.** Terminate on a host's menu entry: suit reads `host.json` (same user, private file),
   connects as a non-owner reader to show what runs, and sends `SIGNAL terminate` through a short `HELLO` with
   `takeover` only after the user confirms. Fallback: `processkit_terminate` by pid and start time.
4. **Spawner of last resort** when the daemon cannot break away from its job (5.4). Request on suit's control pipe:
   `terminal.spawnHost {hostFolder}`; suit launches the installed binary with the same settings. suit validates
   that the folder is under a known workspace state directory and that a `spec.bin` exists there.
5. **Cleanup.** Removes dead host folders whose workspace service is not running and whose `final.bin` is older than
   30 days (the next service would import it; this is for abandoned workspaces), and unused host versions.
6. **Display.** Tray: "Terminals: 5 running in 2 workspaces"; a workspace with no running service but live hosts is
   shown, with "Start service" (which adopts them).
7. **Quit semantics.** Today Quit ends terminals through the daemon's graceful stop (`suit/README.md`, "Stopping").
   With hosts, Quit stops services and asks about terminals (open question Q1).

### 5.14 Security

| Threat | Control |
|---|---|
| Another local user connects to the pipe | DACL with only the current user, as `CurrentUserPipeSecurity` (`transport.cpp:313-350`); POSIX socket in a 0700 directory plus `getpeereid`/`SO_PEERCRED` uid check |
| Remote connection | `PIPE_REJECT_REMOTE_CLIENTS` (`transport.cpp:365`); Unix sockets are local |
| A process squats the pipe name before the host | random 128-bit name, `FILE_FLAG_FIRST_PIPE_INSTANCE` (`transport.cpp:364`); the daemon reads the name only from the private `host.json` |
| A sandboxed (AppContainer / low-integrity) process of the same user | the DACL grants only the user SID, which AppContainer tokens do not match; the token is also required |
| A same-user process that can read the user's files | can already run code as the user; the token protects against confused deputies and accidents, not against the user's own code. Stated, not claimed otherwise. |
| Token leak through command lines or logs | the token is only in private files (`spec.bin`, deleted after start; `host.json`); never in argv, environment or logs; constant-time comparison |
| Handle and lock leakage | the host inherits nothing (5.4); the PTY child inherits nothing (`pty.cpp:536-543`) |
| The protocol as an execution primitive | no spawn/exec/file/env messages (5.7); input is the only way in, as at a keyboard |
| Grants for editors and devices | unchanged: enforced by the service (`WorkspaceRpcServer.acceptRemote`, `WorkspaceRpcServer.hx:165-175`). Editors and devices never talk to hosts. |

### 5.15 Failure modes

| Failure | Result | Recovery |
|---|---|---|
| Daemon crash or update | hosts keep running, unowned | the next generation adopts them (5.9); editors continue from their cursors |
| Manager killed, its job closed | daemon dies; hosts are outside that job and keep running | as above |
| Editor crash or restart | nothing happens to terminals | editor reattaches: snapshot + replay from cursor |
| suit crash, restart or quit | nothing happens to terminals (except Quit, Q1) | suit rescans |
| Host crash | that terminal's job closes; its programs end | service sees the pipe close and the pid gone: imports `final.bin` if any, else saved SQLite history; record `lost`; "Restart Terminal" offers a new shell with history (today's path) |
| Host hung (alive, no answer) | service marks it unreachable after 2 s `PING` timeout, keeps retrying; input refused | the user can terminate it from the terminal's menu or suit (pid + start time) |
| Program exits while no service runs | `final.bin` with the exit code; host exits after 60 s | the next service imports it (5.8) |
| Host started, daemon died before saving `running` | folder exists, record says `starting` | adopted by step 2 of 5.9 |
| Spec written, host never started | `spec.bin` left, no `host.json`, no process | the next service deletes the folder and marks the record `failed` |
| `host.json` corrupt or not private | not trusted | not adopted; process left alone; shown as unclaimed with its pid; log |
| pid reused | `processkit_identify` with the start time fails | treated as gone |
| Disk full | `host.json` write fails | host exits before reporting ready; spawn fails as `terminal_spawn_failed` |
| Reboot or logout | all hosts end | records `lost` with saved history and the latest `final.bin` checkpoint; restart from history |
| State directory deleted while hosts run | hosts keep running; nothing can find them | suit lists them as unclaimed by scanning; terminate from there |
| Old service starts (downgrade) | it does not know `host`; marks records `lost` (`WorkspaceTerminalManager.hx:86-90`); hosts keep running unowned | a new service adopts them again. Risk: the user restarts a `lost` record in the old service while its host still runs: two shells for one record. Mitigation in 10. |
| Breakaway refused | no host | suit spawns it; else in-process fallback with a visible "not protected" note |

---

## 6. Rejected alternatives

| Alternative | Why not |
|---|---|
| Keep PTYs in the daemon and avoid restarts with Haxeon live patching | Live patching has known gaps (removed methods via dynamic dispatch, constructor adapters, register scanning; `NEXT-PHASE.md`, "Live mode"). Native, runtime or compiler changes cannot be patched. A crash still kills everything. |
| Hand the ConPTY from the old daemon to the new one | No documented way to transfer an `HPCON`; its internals (signal pipe, reference handle, console host process) are private. The job and parent relationships also stay with the old process. POSIX fd passing (`SCM_RIGHTS`) works for the master but the child's parent dies, so `waitpid` is lost without a subreaper; and Windows cannot do the equivalent at all. |
| One host per workspace (VS Code's pty host shape) | One crash or update loses every terminal of the workspace; needs multiplexing and its own lifetime rules; VS Code itself loses processes when its pty host restarts. |
| suit owns all PTYs | Same as above at machine scope, inside a process that changes and idles out often. |
| A HashLink host | 5.3: runtime churn, DLL locks, loader dialogs, memory. |
| tmux or screen as the backend | Not on Windows; the upgrade problem remains (tmux protocol mismatch). |
| dtach-style host without an emulator | Reattach would need the program to redraw; Claude Code and full-screen programs do not reliably redraw on attach; the existing snapshot format would be unused. |
| Revive only (VS Code, Zellij, Windows Terminal) | Ends the process; a live agent session would be lost. Kept only as the fallback after a host crash or reboot. |
| A stable "core" service that keeps everything long-lived and a restartable "worker" for the rest | The core would be most of today's service (RPC, grants, catalog), so it would still change often. The terminal host is the minimum that must not die. |
| Editors connect to hosts directly | Bypasses the service's grants, controller arbitration and the relay; would multiply protocol clients. Possible later as an optimization with service-minted per-connection tickets if latency measurements require it. |

---

## 7. Implementation plan

Each phase lands as a reviewed commit stack (`goal-m19` rules), with tests, before the next starts.

### Phase 0: prerequisites (small, independent)

1. Move the PTSMVTS v2 encoder into C: `terminalkit_screen_snapshot(kit, buffer, capacity, written)` next to
   `terminalkit_restore_screen_snapshot`. `Emulator.screenSnapshot()` (`Emulator.hx:181-219`) calls it. Contract
   test: byte-identical output to the current Haxe encoder on the existing snapshot fixtures. Coordinate with the
   worker fixing problem 2; this does not change the format.
2. A real Windows `processAlive` via `processkit_identify` (`AgentManager.hx:701-705`).
3. A detached launch primitive with no inherited handles, stdio to `NUL`//dev/null, breakaway, no job, chosen cwd:
   `nk_process_spawn_detached` in NativeKit or `Process.spawnDetached` in `child_processes.c`, with a test that the
   child holds none of the parent's handles (on Windows, check the lock: a second process can take `agent.lock`
   after the parent exits while the child runs).

### Phase 1: the host and its protocol, standalone

New package `native-packages/terminal-host/` (CMake, static):

- `src/host.cpp` (main loop, ownership, lifecycle), `src/protocol.{h,cpp}` (codec), `src/journal.{h,cpp}`
  (ring, same semantics as `TerminalReplayLog`), `src/endpoint_win.cpp`, `src/endpoint_posix.cpp`.
- `docs/roadmap/TERMINAL-HOST-PROTOCOL.md` with byte vectors for every message.
- Haxe client: `src/workspace/terminalhost/TerminalHostProtocol.hx` (codec) and `TerminalHostClient.hx`
  (connect, `HELLO`, requests, pushes) over a NativeKit local transport.
- Tests (all launched through `docs/benchmarks/perf-harness/run-guarded.ps1` with timeouts):
  - codec vectors, C and Haxe, both directions;
  - host contract (C test driver): spawn `cmd.exe`/`/bin/sh`, input and echo, resize, colors, exit drain with a
    large final burst (as `pty_contract_win.cpp` floods), gap, auth failures, non-owner writes refused, takeover;
  - **survival**: a Haxe test process spawns a host, attaches, writes, is killed with `TerminateProcess`/`SIGKILL`;
    a second process reads `host.json`, attaches, gets a snapshot with the earlier output, keeps the same shell pid,
    and continues from its cursor;
  - Windows: the spawning process is placed in a kill-on-close job; closing the job leaves the host running;
  - no dialogs: a PTY child that crashes shows WER normally (default error mode) while the host keeps running.

Exit criterion: the survival test passes on Windows and Linux, under the guard, ten runs in a row.

### Phase 2: the service uses hosts (behind `EXOSUIT_TERMINAL_HOST=1`)

- Split `TerminalRuntime` (5.10); `InProcessTerminal` keeps today's code; `HostedTerminal` uses the client.
- Install the host binary per build hash (5.11); spawn handshake (5.6); adoption at start (5.9); `dispose()` detaches.
- `TerminalRecord.host`/`stream`; `TerminalInfo.stream` (field 17).
- Update policy and status counts (5.10).
- Tests: extend `scripts/test-workspace-terminals.py` and `tests/workspace-attachment` (`AttachmentTestMain.hx`
  update modes, lines 175-253): start a service, open a terminal running a counter, request update `now`, assert
  the counter's process id is unchanged and its output continues in the new generation; crash the daemon
  (`TerminateProcess`) mid-output and assert the same; kill the host and assert `lost` with history.
- Measure input latency with `docs/benchmarks/input-latency` (hook + driver tools), hosted against in-process.

Exit criterion: with the flag on, a service update while Claude Code runs in a terminal keeps the session, on the
user's real workflow, verified on a scratch workspace with isolated state (`PRAGTICAL_PORTABLE` temp,
`EXOSUIT_SUIT=isolated`, `EXOSUIT_AGENT_STATE_HOME` temp).

### Phase 3: editor continuity, suit, UI

- `RpcTerminalBackend` keeps its cursor across generations when `stream` matches (5.9).
- suit: `terminal-host` kind, exclusion from sweeps, tray entries, terminate, cleanup, spawner of last resort.
- UI: update confirmation text; "not protected" note for in-process terminals; "outdated terminal host" note.

### Phase 4: default on, migration

- Flag default on; `EXOSUIT_TERMINAL_HOST=0` keeps the in-process path for diagnosis.
- Migration (section 10).
- Soak: 24 h with a service restart every 10 minutes and continuous output in 8 terminals; host and daemon memory
  flat; no lost or duplicated bytes (journal offsets checked against a generated stream).

### Later

- POSIX in-place host upgrade (5.11).
- Direct editor-to-host streaming if Phase 2 latency numbers require it.
- The editor's dock terminal (`TerminalPane.hx:92`) through a host.
- Headless agent provider processes (Claude, Codex, Pi through `ProcessManager`) also die with the daemon; a
  "pipe host" with the same ownership model could keep them.

### First steps, concretely

1. Phase 0.1: add `terminalkit_screen_snapshot` to `native-packages/terminal/src/terminalkit.c` and
   `include/terminalkit.h`, switch `Emulator.screenSnapshot`, add the byte-equality contract test.
2. Phase 0.3: the detached launch primitive and its handle-leak test.
3. Write `TERMINAL-HOST-PROTOCOL.md` with the message table of 5.7 and the first vectors (`HELLO`, `WELCOME`,
   `INPUT`, `EVENTS`), and get it reviewed before any host code.
4. Skeleton host: read spec, create pipe, spawn PTY, `HELLO`/`WELCOME`, `INPUT`, `SUBSCRIBE`; then the survival test.

---

## 8. Test plan (summary)

| Level | What | Where |
|---|---|---|
| Codec | every message, both directions, truncated and oversize frames, unknown types, appended fields | `native-packages/terminal-host/tests`, Haxe `tests/terminal-host-protocol` |
| Host contract | spawn, I/O, resize, colors, signals, exit drain, gap, auth, ownership, takeover, linger, `final.bin` | C driver |
| Survival | kill the client, reattach from another process | Haxe test process pair |
| Job semantics (Windows) | spawner in a kill-on-close job; breakaway refused path; no inherited lock | C driver |
| Service | adoption, unreachable host, unclaimed folders, `final.bin` import, restart from history, downgrade (old service on a hosted catalog) | `scripts/test-workspace-terminals.py`, `tests/workspace-terminals` |
| End to end | update `now` and `idle` with running terminals; daemon crash; editor restart; suit restart | `tests/workspace-attachment` |
| Latency | keystroke to echo, hosted vs in-process | `docs/benchmarks/input-latency` |
| Soak | 24 h, periodic restarts, memory, byte accounting | scripted, guarded, hard timeout |

Rules for every run: through `run-guarded.ps1` with a timeout of 2-4× the expected time (`timeouts-fit-the-job`);
Release or RelWithDebInfo native builds; isolated state; tests kill every host they started (by pid and start
time) in a `finally`, and the driver checks that no `exosuit-term-host` from its own state folder remains.

---

## 9. Data model changes

| Item | Change | Compatibility |
|---|---|---|
| `TerminalRecord` (`WorkspaceTerminalProtocol.hx:113-127`) | optional `host` (id 13), `stream` (id 14) | new optional ids; verify that the MessagePack decoder of the oldest supported service ignores unknown ids (RPC-VECTORS rules) before shipping |
| `TerminalInfo` (`:27-45`) | optional `stream` (id 17), `hosted` (id 18) | optional |
| `WorkspaceServiceStatus` | optional `hostedTerminals` | optional |
| Record states | unchanged set | an old service's `validRecord` accepts only the existing states (`WorkspaceTerminalManager.hx:110-121`); a new state would make it throw at startup (line 85) |
| SQLite | none; history table unchanged | |
| State folder | `terminal-hosts/` | ignored by old services |

---

## 10. Migration

- Terminals already running in an old daemon are in-process and cannot move into hosts. The first update to a
  host-capable build behaves as today: `idle` waits for them to end; `now` ends them. The update dialog says so once:
  "After this update, terminals keep running across updates."
- After that update, every new terminal is hosted.
- Downgrade: an old service rewrites hosted `running` records to `lost` at startup (`WorkspaceTerminalManager.hx:86-90`)
  and cannot see the hosts, which keep running unowned. Its `RESTART` refuses only `running`/`starting` records
  (line 641), so a user could restart a `lost` record there and get a second shell while the host still runs.
  Mitigation: when a new service starts again, it finds the live host whose `stream` no longer matches the record,
  shows both (the record's new shell, and the host as an unclaimed terminal with its screen), and never kills
  either. Downgrades are rare in practice (daily and worktree builds use separate state folders,
  `stable-build-for-daily-use`), so this is a documented edge, not a blocker.

---

## 11. Open questions for the user

1. **Quit and "Terminate all".** Should Quit Exosuit end hosted terminals? Proposal: Quit asks "5 terminals are
   running: Keep running / End them"; "Terminate all background processes" never includes terminals.
2. **Native C++ host.** Is a non-Haxe component acceptable here, given the reasons in 5.3? The alternative is an HL
   host with its costs.
3. **Exited terminals with no service.** Keep the host 60 s and write `final.bin` (proposal), or keep it until a
   service attaches?
4. **Service idle exit.** Should the service be allowed to stop when idle while hosted terminals run (saves memory;
   exit codes and history reach SQLite later), or keep today's rule that running terminals keep it up (proposal for
   now)?
5. **Scope.** Should the editor's dock terminal and headless agent processes follow in the same project, or later?
6. **Journal size.** 4 MiB per terminal (proposal) instead of today's 16 MiB?
7. **Fallback visibility.** When a terminal cannot be hosted (breakaway refused and suit unavailable), should
   creation fail, or run in-process with a "not protected" note (proposal)?
