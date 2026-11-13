# Terminal hosts: what is built

Status: first version built 2026-11-12 on branch `term-survive`. The design is `terminal-host.md`; this file says what
exists, where it differs from the design, and what remains.

## Why

Evidence from the user's state (copy of 2026-11-12, `%LOCALAPPDATA%\Exosuit`):

| Cause | Count | Evidence |
|---|---|---|
| The service process ended while the terminal ran | 8 of 9 terminal records | `workspace_terminals` state `lost`; in the main workspace the 6 lost terminals belong to 4 different service generations |
| The terminal's program exited | 1 of 9 | state `exited`, exit code 1 |
| Service stopped with no stop line (killed, or stopped by suit or a restart request: none of these was logged) | 14 of 24 service starts in the current workspaces' `manager.log` | `READY` lines without a following `STOPPED` |
| Service stopped itself for an update | 2 of 24 | `STOPPED: exosuit-agent update`; this happens only with no terminal running |
| Service stopped itself when idle | 3 of 24 | `STOPPED: exosuit-agent idle`; only with no terminal running |

A service stays up while it has a running terminal, and updates itself only without one, so closing the editor or
rebuilding it does not by itself end terminals. What ends them is the service being stopped: the daily routine before
a rebuild or a switch of the checkout was "quit Exosuit and suit", because a build cannot replace `hl.exe` and the
libraries a running service has loaded. Every such stop ended every terminal. With hosts the routine is: polite quit
(`suit quit --keep-terminals`), `suit stop` (the daemon runs from the checkout), switch, build, start; the hosts run
from a runtime copy in the state folder and live through it (`exosuit-wt/switch-daily.ps1` does exactly this).

## What is built

- `app.TerminalHostMain` (`main.hl --terminal-host DIR`): one process per terminal. Owns the PTY and an emulator, listens
  on a private pipe, logs to `DIR/host.log`.
- `workspace.runtime.TerminalHosts`: makes the private runtime copy (`<state base>/terminal-host/<key>/`: `hl.exe`, the
  libraries, the bytecode as `terminal-host.hl`), starts hosts detached, finds the hosts a previous generation left.
- `workspace.runtime.HostedPtyBackend`: the service's view of a hosted terminal, a `TerminalBackend` like the in-process one.
- `workspace.runtime.TerminalHostProtocol`: the messages (one kind byte and a payload).
- `WorkspaceTerminalManager`: starts terminals through hosts when it has them, adopts kept terminals at start, detaches
  instead of ending them when the service stops.
- `manager.log` now holds dated lines for service starts and stops (with the cause) and terminal starts and ends.

Added 2026-11-12 on branch `host-harden`:

- Scrollback: a view that attaches asks the service for the rendered history with the screen snapshot (one paged
  SNAPSHOT call, `history` field) and gets the lines above the screen, including output printed while no service ran.
  Restoring a screen snapshot no longer clears the emulator's scrollback, which is what had left an adopting service
  (and every view) with one screen. Retained: 1000 lines above the screen (`TerminalHostProtocol.SCROLLBACK_ROWS`; the
  host's, the service's and the view's emulators each keep that many), at most 4 MiB rendered. This holds for every
  attach, hosted or not.
- A view that sees a new service generation keeps what it shows until the new service's history and screen arrive,
  replaces it in one step and stays scrolled up by the same number of lines.
- Reconnect in place: a service whose connection to a live host closes opens it again (20 seconds, at most five times
  a minute); attached views take history and screen again through a replay gap.
- Final screen: a host whose program ended with no service attached writes `final.bin` (size, history, screen, exit
  code) and ends at once; the next service reads it in place of a host and removes it. A host that cannot write the
  file waits a day as before.
- An idle host (no service, quiet or ended program) wakes four times a second instead of a hundred.
- A host of a newer protocol number is left alone by an older service; a host that answers late keeps its record; a
  service that fails while reading a host does not end the program; closing or restarting a lost terminal ends its host.

Added 2026-11-12 on branch `fix-host-lifecycle`: end requests name their host (`pid` and `instance`, the id each host
writes in `host.json`); a host ignores a request for another and removes one for a process that is gone. Restart
Terminal asks the old host to end over its pipe and with an addressed request, holds its process, and kills it after 5
seconds if it still runs (a host that runs without answering is why a terminal shows as lost). A host leaves
`final.bin` only while `host.json` is still its own, and a new host removes a predecessor's. A host folder is made
private to the user (as `LocalServiceDescriptor` wants a descriptor's folder) and `spec.bin` is checked to be private
before a host starts; the host deletes `spec.bin` before decoding it, and the service deletes it when the host fails
or does not become ready. A folder that cannot be made private (one an older build made outside a private state
folder) gets no host: the terminal runs inside the service.

Per terminal, in the workspace's state folder: `terminal-hosts/<24 hex of sha256(terminal id)>/` with `spec.bin` (written
by the service, read and deleted by the host: program, arguments, environment, size, pipe, token), `host.json` (written
by the host: pid, pipe, token) and `host.log`.

Switch: `EXOSUIT_TERMINAL_HOST=1` turns hosts on, `0` off. With the variable unset they are on for Windows services on
the user's own state and off under an isolated state (`EXOSUIT_AGENT_STATE_HOME`, `PRAGTICAL_PORTABLE` or
`XDG_STATE_HOME` set), so test runs do not leave hosts behind.

To see the hosts that run and to end them: `suit terminals` lists them with their workspaces, `suit terminals end --all`
(or `end <workspace>`, or "End all terminals" in the tray) ends them, `suit kill <pid>` ends one, and suit's full quit
(`suit quit`, tray "Quit Exosuit and end everything (N terminals)") ends them with everything else. Before a rebuild
use the polite quit, `suit quit --keep-terminals` (tray "Quit, keep terminals running (N)"), which ends everything
else and leaves the hosts. Without suit (PowerShell):

    Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | ? { $_.CommandLine -like '*--terminal-host*' } | select ProcessId, CreationDate, CommandLine
    taskkill /F /T /PID <pid>

Each host's folder holds `host.log`: when it started, which services attached and left, and how its program ended.

## Memory (branch `term-memory`, 2026-11-12)

The user's rule: some memory for live terminals is fine (about 100 MB of text for long sessions, several such
terminals at once), but a dead terminal should cost nothing in memory; its history may live on disk.

Where a terminal's text lived (10000 lines above the screen, `TerminalHostProtocol.SCROLLBACK_ROWS`): the host's
emulator; the service's emulator plus its replay journal of raw output (up to 16 MiB); and the emulator of every view
(editor tab, phone). An emulator with a full scrollback of full-width coloured lines is 22.5 MiB at 80 columns and
54.8 MiB at 200 (24 bytes a cell; shell output with short lines is much less, see 8196488f). A dead terminal kept
the service's emulator and journal until it was closed, for as long as the service ran.

Changed:

- **An ended terminal gives up its emulator in the service.** Once its history is saved and no view has read it for
  30 seconds (`WorkspaceTerminalManager.UNLOAD_SECONDS`) the service closes the emulator and drops the journal. The
  saved history (the service's store, written on exit as before) is the copy; opening the terminal, asking for its
  snapshot, restarting it or taking control loads it again. A view that still shows it keeps what it shows: letting
  go sends no change notice, and the view asks again only when something changes. Its journal is numbered on from
  where it was, so a view that read it before is not refused. The host of an ended program already ends (it says
  EXITED to its service, or writes `final.bin` when none is attached), so an ended terminal holds no emulator outside
  the views.
- **The service's replay journal keeps 2 MiB per terminal** (`WorkspaceTerminalManager.REPLAY_BYTES`, was 16 MiB): it
  only bridges a view's reads; a view further behind takes a snapshot.
- **Attach reads history through a window of 16 page requests**, in 128 KiB pages on a local connection (32 KiB
  remote), instead of one page per round trip once more than 16 remained.

Measured (2026-11-12, private bytes):

- Attach: a view of a hosted terminal with 10000 lines above an 80-column screen attached in 312 ms with all of them
  (`scripts/test-terminal-hosts.py`, part three, through the windowed paging; no measurement from before the change).
- An ended terminal is unloaded and comes back from disk with its whole history (`TerminalHistoryTests`).
- The four-terminal measurement (`EXOSUIT_TERMINAL_MEMORY=1 scripts/test-terminal-hosts.py`, last part) did not get
  past filling the terminals; it found a bug instead (below). What it showed: an empty service is 315 MiB (and a
  second process of 36 MiB); each host that printed 10000 lines of 200-column coloured output is 144-262 MiB, about
  three times its emulator (HashLink runtime and heap); in one run the service reached 908 MiB with four such
  terminals. A host is far heavier than its text: the native host (design 5.3) would matter more than any scrollback
  format.

Found and fixed (branch `fix-host-flood`): **fast coloured output made the service lose a hosted terminal.** Four
terminals printing 10000 lines of 200 coloured cells each: within one to three seconds every host connection closed,
the terminals turned `failed`, and their hosts kept running with nothing attached. The cause: a NativeKit stream reads
its peer as fast as the peer writes into a 1 MiB receive buffer and closes with `receive_overflow` when more waits
unread; the host sent as fast as its pipe took it, the service takes coloured output in more slowly, and each
reconnect's history overflowed the same way. Now the service acknowledges what it takes (CREDIT, see
TerminalHostProtocol) and a host keeps at most 512 KiB unacknowledged; a dropped connection to a host that runs is
opened again instead of given up; a view keeps at most 512 KiB of snapshot pages in flight (16 local pages had the same
overflow); and the history table holds 16 MiB (it still had the 4 MiB CHECK of 1000-line scrollback, so every save of a
long history failed and was retried every two seconds, growing the service by about 20 MB a second).

Measured after the fix (`EXOSUIT_TERMINAL_MEMORY=1`, private bytes, service = launcher + daemon): empty service
315.6 + 35.8 MiB; four full terminals 320.8 + 2593.2 MiB with hosts of 181 MiB each; right after two ended
323.0 + 3122.1 MiB; once the ended two were let go 328.0 + 266.0 MiB with hosts of 192 MiB. A view attaches a full
200-column terminal (4163 lines, the 16 MiB bound) in about 4 s.

Found and fixed (branch `fix-history-save`): **the daemon's gigabytes were garbage from the periodic history save.** A
terminal with new output saved its history every two seconds: a 16 MiB export and its encoded copy each time. HashLink's
collector did not count these buffers towards starting a collection (its heap counters stayed under 70 MiB while the
process held 2.7 GiB), so they stayed until other allocation reached its 64 MB trigger, about a minute later; a major
collection after each save kept the daemon near 300 MiB. Now the pause after a save grows with the size saved (one
second per MiB, at least two: 16 s for a full history), and the manager starts a major collection itself once 64 MiB of
such buffers (saves and views' history exports) were dropped (1-17 ms measured), and when it lets go of ended
terminals. An ended terminal, a restart and a service stop still save at once.

Measured (`EXOSUIT_TERMINAL_MEMORY=1`, daemon private bytes; the launcher is a steady 318-335 MiB beside it), before /
after: highest while four terminals filled 2771 / 464 MiB; four full terminals 30-60 s after they printed 2746-2772 / 344-364
MiB, a minute and a half after 309 (a collection had run at last) / 377 MiB; right after two ended 866 / 334 MiB; once those two were let go 883 / 270 MiB.
Not done, and why:

- **The service still keeps a full copy of a live hosted terminal.** The plan was a tail of a few hundred lines in the
  service and the history taken from the host on attach. It needs a new host message (history on request; the reply
  arrives in order with the output, so the service's screen at that moment matches it), a SNAPSHOT that answers
  later, and the saved history taken from the host on exit and periodically, or a dead terminal would keep only the
  tail on disk. Terminals that run inside the service (hosts off) keep the full copy there in any case.
- **Views keep their whole scrollback while their tab is open, also when hidden.** Dropping a hidden tab's history
  (libtsm's `tsm_screen_set_max_sb` trims it in place) needs the editor to say which tabs are hidden; the pane cannot
  tell a hidden tab from a visible idle one by itself, and losing what the person scrolled up to read is worse than
  the memory. Fetching older lines on demand as the view scrolls needs scrollback that can grow at the top, which
  libtsm does not have.
- **No compact scrollback in libtsm.** Every reader of scrollback lines (drawing, selection, history export, resize)
  reads 24-byte cells; a text-plus-attribute-runs form for lines that leave the screen would change all of them.
  Trimming trailing blank cells (8bd5203) already makes ordinary shell output cost what it printed.
- **The saved history of a dead terminal is in the service's SQLite store, not a separate compressed file**; it is
  removed when the terminal is closed (FORGET), as before. No total cap beyond the 256 terminal records and 16 MiB
  per history.

## Decisions the user may want to reverse

1. **The host is the agent's bytecode on a copied runtime, not a native program.** The design chose a static native EXE
   (section 5.3). Building one was not possible in the time; the copy removes the main objection (locks in the build tree)
   but not the others: a host is a HashLink process (tens of MB), and a runtime bug can end a terminal.
2. **suit is the final arbiter of hosts; only the polite quit keeps them** (branch `suit-hosts`, revised the same day
   on `suit-arbiter` after the user's rule that suit can end everything). A host is its own process kind in suit
   (`terminal-host`): it registers itself, is shown in the group "Terminals" with its workspace and terminal, and is
   never orphaned (the orphan sweep and `suit kill --orphans` leave it). The stop of its service and the close of its
   editor leave it running; that is the feature. suit's full quit (`suit quit`, tray "Quit Exosuit and end everything
   (N terminals)"), "Terminate all background processes" and `suit kill --all` end it. The polite quit
   (`suit quit --keep-terminals`, tray "Quit, keep terminals running (N)") ends everything else and keeps hosts, with
   the suit daemon staying up to list them until the last one ends; that is what makes "quit, rebuild, start again"
   keep terminals. The other kill switches are "End all terminals (N)" in the tray (one entry per workspace when
   several have terminals), `suit terminals end --all|<workspace>`, the host's own tray submenu and `suit kill <pid>`.
   suit ends a host by writing `end-request.json` into its folder; the host ends its program and itself, and is killed
   after 3 seconds if it did not (a host from a build before this one never reads the file).
3. **A service with running terminals still does not update itself.** It could now (its terminals would be adopted by
   the new generation), but that is left off until adoption has been used for a while. "Restart now" in Remote Access
   does it on request, and its warning says which sessions a restart ends.
4. **Unused runtime copies are removed when a service with hosts starts.** A copy is kept while it is the starting
   service's own, was made in the last ten minutes, holds the lease of a running host (`host-<pid>.lease`), or its
   executable cannot be deleted (Windows refuses while a host runs from it).
5. **A host ends itself when its workspace is gone, on firm evidence only.** With no service attached it checks every
   30 seconds; when its folder or the workspace's state folder is gone, or suit removed the workspace (suit's
   workspace-delete leaves `removed-workspaces/<id>.json` beside `machine.json`), on two checks in a row, it ends its
   program. A `machine.json` that merely lacks the workspace is weak evidence (a reset or badly rewritten catalog says
   the same): only after 6 hours of absence from lists that can be trusted (not empty, same machine id, not fewer
   workspaces than when the workspace was last listed) does the host end its program, and it then keeps the last screen
   and exit code in `final.bin` (2026-11-12, `fix-host-lifecycle`).
6. **A service start ends no host.** A host whose terminal has no record in the loaded catalog is logged and left
   running (suit lists it; the user ends it); the folder of a terminal with no record, no running host and no
   `final.bin` is removed once it is a minute old, and nothing is removed while the catalog has no terminals at all (a
   replaced or recreated database). Until 2026-11-12 such hosts were asked to end, so a replaced catalog ended every
   running terminal of its workspace.

## What was checked

- `scripts/test-terminal-hosts.py` (headless): a service with hosts on makes a terminal and is stopped with a stop
  request; the host process is still there and a new service adopts the terminal; that service's manager is killed; the
  host is still there; a service started without hosts records the terminal as lost and is stopped; a last service with
  hosts takes the terminal back, and the existing attach check passes against it (same shell pid and shell state,
  screen, input, resize, exit code); the host ends with its program.
- `docs/benchmarks/perf-harness/gui_scenarios/term_survive.py` (real input, through `measure.ps1 -Drive term_survive`):
  an editor makes a terminal and starts a loop in it; the editor is closed and the service stopped; the loop keeps
  running; a new editor lists the terminal as running and its tab shows the whole screen, including lines printed while
  no service ran, from the same process and the same host.

- `scripts/test-terminal-hosts.py`, second part (2026-11-12, passed once after the last change): four hosted terminals
  in two workspaces; both services stopped and started; each view gets its own terminal back, one with 1000 lines
  above the screen and the 40 lines printed while no service ran; a full-screen program (alternate screen, bracketed
  paste, colours) kept running and its view has the same modes as before; another connection takes a host over and
  the service connects again in the same generation; a program exits with code 9 while no service runs, its host
  leaves `final.bin` and ends, and the next service shows it exited with code 9, its last screen and its scrollback.
  Mouse reporting and cursor-key mode could not be checked this way: the Windows pseudoconsole does not pass them on
  from a console program.

Not checked: a restart of Windows (hosts do not survive it; the terminal is then lost with its saved history, as before), more than
one hosted terminal at a time in the editor, Claude Code or Codex as the terminal's program.

## What remains

- The three ways a host was left running unseen are closed (2026-11-12): while `EXOSUIT_TERMINAL_HOST=0` is set the
  host stays (the next service with hosts takes the terminal back) but suit lists it, the service logs that it runs,
  and removing the lost terminal ends its host; suit ends a removed workspace's hosts, and a host ends itself when its
  workspace is gone; a terminal closed before its host answered leaves an end request in the host's folder.
  Not covered by a test: the workspace-removed case and the closed-before-answered case (the test program cannot
  remove a terminal or a workspace); `scripts/test-terminal-hosts.py` covers the rest.
- An adopted host whose pipe does not open in time keeps its `host.json` while its process runs (the terminal shows
  as lost and the next service tries again); the record is removed only when the process is gone.
- The cursor space is still the service's: an attached editor takes history and screen again when the service
  generation changes. Its content is replaced in one step and its scroll position kept, but a selection is lost and
  the replay does not continue as the design wants (R2). Not checked in a running editor.
- Scrollback is 1000 lines everywhere. More needs the emulators' limit and `terminalkit_history_copy`'s 1000-row and
  4 MiB bounds raised together.
- A full-screen program's history is its screen drawn on the primary screen: after it leaves the alternate screen a
  restored view shows that copy where the shell's earlier lines were.
- `host.json` is not checked to be a private file the way `LocalServiceDescriptor` checks descriptors.
- A `final.bin` whose terminal was already recorded as exited (the service got the exit code and died before saying
  END) stays in the host folder until the terminal is removed or restarted.
- Linux and macOS: the code is written for them (Unix socket in the host folder) but was never run; hosts are off there
  unless asked for.
- Native host (design 5.3), version negotiation beyond the single protocol number, memory measurements, latency
  measurements (R7), tests in the suites.
