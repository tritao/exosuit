# Terminal hosts

Every terminal runs in a terminal host: one process per terminal that owns the program's pseudoconsole and the only
emulator of its screen. A workspace service starts hosts, relays between them and the views, and can stop, crash or
idle out while its terminals go on. The next service takes them back.

## Parts

- `app.TerminalHostMain` (`terminal-host.hl --terminal-host DIR`, the program agent/terminal-host builds beside the
  agent; a bundle's `exosuit-terminal-host.hl`): the host. Runs the program, keeps its emulator (1000 lines
  above the screen, `TerminalHostProtocol.SCROLLBACK_ROWS`), answers the program's terminal queries itself, listens on
  a private pipe and logs to `DIR/host.log`.
- `workspace.runtime.TerminalHosts`: makes the private runtime copy the hosts run from
  (`<state base>/terminal-host/<key>/`: `hl.exe`, the libraries, the host program as `terminal-host.hl`), starts hosts
  detached, finds and ends them, reads their last screens.
- `workspace.runtime.HostedPtyBackend`: the service's connection to one host.
- `workspace.runtime.TerminalHostProtocol`: the messages (one kind byte and a payload, version 2) and the host's files.
- `WorkspaceTerminalManager`: the terminal RPCs of a service. It keeps no emulator: a terminal's screen comes from its
  host, or from the host's last screen on disk.

Per terminal, in the workspace's state folder, `terminal-hosts/<24 hex of sha256(terminal id)>/`:

| File | Written by | What |
|---|---|---|
| `spec.bin` | service | program, arguments, environment, size, pipe, token, and the prelude (below); deleted by the host before it decodes it |
| `host.json` | host | pid, executable, pipe, token, protocol version |
| `terminal.json` | service | which workspace and terminal the host keeps (suit shows it) |
| `screen.bin` | host | the last screen: size, rendered history, exact screen, and whether and how the program ended |
| `host.log` | host | starts, services attaching and leaving, how the program ended |

Isolated runs (tests, worktrees: `EXOSUIT_AGENT_STATE_HOME`, `PRAGTICAL_PORTABLE`) have hosts too. Their folders are
in the isolated state and they register with the isolated suit, so nothing outlives a run unseen. The terminal tests
start the same host program (the one built beside the agent) in the test's folder and kill each one they started
(`TestTerminals.endAll`, `scripts/test-workspace-terminals.py`).

## How a terminal lives

- **Start.** The service writes `spec.bin` and starts the host detached. The host spawns the program, writes
  `host.json` and waits on its pipe. The service attaches with the token; the host sends its size, the rendered
  history, the exact screen and LIVE, then the program's output as it comes. The host sends only what the service
  said it took (CREDIT; at most 512 KiB unacknowledged).
- **Views.** The service keeps a relay journal of the output (2 MiB per terminal, `REPLAY_BYTES`) so views read by
  REPLAY from their cursor. A view that asks for a snapshot (an attach, or a replay gap) is answered when the host
  sends its screen: the service sends SNAPSHOT to the host, and the screen comes in order with the output. History
  limits (`historyLimit`, the phone's 256 KiB) and paging work on that screen.
- **The service goes.** A stopped, killed or idle service detaches; the host keeps the program and its emulator. A
  service stays up only for its clients and busy agent turns: running terminals do not keep it (`WorkspaceLifetime`),
  and suit restarts it onto another build with terminals running.
- **The next service** loads the terminal records and takes back each terminal whose host runs. A record whose host
  does not answer in time is "lost" for now and tried again every 10 seconds, and when a view opens it. A record that
  is not valid is skipped and logged. There is no cap on the number of terminals.
- **The program ends.** The host writes `screen.bin`, then tells the attached service (EXITED); the service says END
  over the pipe and the host ends. With no service attached it ends once the file is written; the next service shows
  the terminal ended, with its exit code, last screen and history, from the file.
- **Last screen on disk.** A running host also writes `screen.bin` while its screen changes, at most every 30 seconds
  (longer for a long history: one second per MiB). After a restart of Windows, when no host runs, a terminal is shown
  lost with that screen.
- **Restart Terminal.** A host that still runs keeps its program: the terminal is taken back, never restarted over it.
  For an ended program its host, which keeps nothing more, is killed, and a new host starts with a prelude: the earlier
  history and screen moved into scrollback and a "Shell restarted" line. Views replay the same prelude.
- **Close Terminal** ends the program and its host (KILL and END over the pipe; the process is killed after 5 seconds
  if it is still there) and removes the last screen.
- **Theme.** The view's colours go to the host (THEME), which answers the program's colour queries.
- **A host that did not answer** (busy, suspended) is never ended for it. A Windows pipe listener that stopped because
  a service connected and left before the host accepted it listens again (docs/haxeon-compiler-bugs.md).

## suit

A host is its own process kind in suit (`terminal-host`): it registers itself, is listed under "Terminals" with its
workspace and terminal, and is never orphaned. Stopping its service or closing its editor leaves it running. suit's
full quit (`suit quit`), `suit kill --all`, "End all terminals (N)", `suit terminals end --all|<workspace>`, the host's
tray submenu and `suit kill <pid>` kill it and its program. The polite quit (`suit quit --keep-terminals`, tray "Quit,
keep terminals running (N)") ends everything else and keeps the hosts; that is what makes "quit, rebuild, start again"
keep terminals. Without suit (PowerShell):

    Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | ? { $_.CommandLine -like '*--terminal-host*' } | select ProcessId, CreationDate, CommandLine
    taskkill /F /T /PID <pid>

## Rules

1. **The host is the agent's bytecode on a copied runtime, not a native program.** A host is a HashLink process (tens
   of MB). The copy keeps the build tree free of locks.
2. **Unused runtime copies are removed when a copy is made.** A copy stays while it is the service's own, was made
   in the last ten minutes, holds the lease of a running host (`host-<pid>.lease`), or cannot be deleted.
3. **A service start ends no host.** A host whose terminal has no record in the loaded catalog is logged and left
   running (suit lists it). A folder with no record, no running host and no `screen.bin` is removed once it is a minute
   old; nothing is removed while the catalog has no terminals at all (a replaced or recreated database).
4. **A host ends its program when its workspace is gone, on firm evidence only**: its folder or the workspace's state
   folder is gone, or suit removed the workspace, on two checks in a row; or the workspace has been missing for 6 hours
   from `machine.json` lists that can be trusted. It keeps the last screen and exit code in `screen.bin`.
5. **A newer host is left alone.** A host whose `host.json` names a newer protocol is left to a newer service.

## Hosts of protocol 1

Hosts started by a build before protocol 2 keep running across the switch and are taken back. They do not know SNAPSHOT
or THEME: the service asks them for the screen by attaching again, and their programs' colour queries go unanswered.
They end when their programs end.

## What remains

- The service's relay journal is a copy of recent output (2 MiB per running terminal); a view behind it takes a
  snapshot from the host.
- Views keep their whole scrollback while their tab is open, also when hidden.
- A full-screen program's history is its screen drawn on the primary screen: after it leaves the alternate screen a
  restored view shows that copy where the shell's earlier lines were.
- Scrollback is 1000 lines everywhere; more needs the emulators' limit and `terminalkit_history_copy`'s bounds raised
  together.
- Older databases keep their `workspace_terminal_history` table; the service no longer reads or writes it.
- Linux and macOS: the code is written for them (Unix socket in the host folder) but has not been run there.
- Not covered by a test: a host ending its program when its workspace is removed.
