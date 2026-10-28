# suit

suit is a per-user daemon that tracks every background process that exosuit
editors start, for any number of editors. On Windows it shows the Exosuit tray
icon. Its command line works with or without the daemon.

```
python scripts/suit.py list            every exosuit process, grouped by editor; orphans last
python scripts/suit.py kill --orphans  stop exosuit's processes whose editor is gone
python scripts/suit.py kill --all --dry-run   what a bulk kill would stop, stopping nothing
python scripts/suit.py quit            quit Exosuit: editors are asked to close, exosuit's own processes stop
python scripts/suit.py help            all commands
```

## How processes are known

- **Registration.** A process registers by writing `<pid>.json` into
  `registry/` in suit's home, atomically:
  - the editor, when it starts, with the workspace roots it uses
  - the workspace manager and the workspace daemon, once they are ready, with
    their root, state directory and generation

  Registration never blocks, and it never fails the process. If suit is not
  running, the record waits for it. The record format is in
  `src/suit/SuitRecord.hx`; the client is `src/suit/SuitClient.hx`.
- **Validation.** suit trusts a record only while the pid's start time is no
  later than the time the record was written. A record for a pid that has
  since been reused is ignored, and so is a record for a process that has
  exited; the daemon deletes both. A running process whose start time cannot
  be read (one this user may not open) keeps its record: it is listed with an
  unknown start and never acted on (`SuitInventory.keepsRecord`).
- **Record times.** Records are written with `SuitClock.now()`, the wall
  clock in milliseconds with sub-second precision (`Sys.time()`; HashLink's
  `Date.now()` has whole seconds only, which made a record written in its
  process's first second look older than the process). Records carry
  `version: 2`. A version 1 record holds whole seconds, so it is allowed one
  second before the start time (`SuitClock.registeredAfterStart`).
- **Scanning.** Unless `EXOSUIT_SUIT_SCAN=0` is set, suit also reads the
  command lines of `hl`, `exosuit` and `exosuit-agent` processes, and from
  each one its `EXOSUIT_SUIT`, `EXOSUIT_SUIT_HOME`, state (`PRAGTICAL_PORTABLE`,
  `XDG_STATE_HOME`, `EXOSUIT_AGENT_STATE_HOME`) and `PATH` variables. It
  recognizes editors, workspace managers and daemons, Haxeon compiler workers,
  and live sessions and live hosts.
- **Ownership is positive.** A process is exosuit's only when it registered,
  or when suit *adopts* it (`SuitLineage.adoptionOwner`). Adoption needs all
  of these:
  - it is of a kind exosuit starts itself (`SuitKinds.spawnedByExosuit`): a
    workspace manager or daemon, a compiler worker, a live session or host;
  - its environment registers with this suit (`SuitLineage.registersWith`,
    the one place this policy lives): its mode by the rule below is not off,
    and its suit home, resolved (`EXOSUIT_SUIT_HOME`, else the default home),
    is this suit's resolved home. An environment suit cannot read (`PATH`
    missing) does not count;
  - its parent chain reaches a registered process through processes of those
    kinds only, each started no earlier than its parent.

  A build the user runs in an exosuit terminal has a shell between it and the
  workspace daemon, so it is never adopted. The daemon writes a record for an
  adopted process (`adopted: true`, `owner`: the ancestor), so it stays
  exosuit's after that ancestor exits. Everything else suit finds by scanning,
  such as a compiler worker of a terminal build or another agent's, or a
  test's workspace manager, is listed as *Not started by exosuit*. It is never
  orphaned and never included in `kill --orphans`, `kill --all`, Terminate
  all, or Quit; `suit kill <pid>` still stops it when asked by pid.
- **Reading has no side effects.** `suit list`, `suit watch`, `suit menu` and
  `kill --dry-run` only read. The daemon's inventory alone deletes stale
  records and writes adoption records.
- **Orphans.** Each kind has one rule (`SuitKinds.orphanRule`):
  - A workspace manager or daemon belongs to every registered editor that
    uses its root, whichever editor started it. It is orphaned when none
    does, unless suit hosts that workspace for remote access
    (`SuitRelayHosts.active`: a host record, and relay settings that are not
    paused). suit starts and keeps those services itself, so while hosting
    is on they are listed under Other and Terminate orphaned leaves them.
  - Compiler workers are resident by design, so they are orphaned only when
    no exosuit editor and no exosuit live session is running.
  - Anything else is orphaned when the process it belongs to is gone: its
    recorded owner, or else its parent.

Process listing, start times, termination and "close your windows" are in
`native-packages/processes` (processkit). Every call that acts on a process
takes a pid and a start time, and does nothing unless the start time matches
exactly. A process whose start time is unknown is never acted on. On
Windows, `processkit_started` reports a process it may not open as
`PROCESSKIT_STARTED_DENIED` (-2), not as gone. `processkit_list_open` reads
the environment variables it is asked for from the processes whose command
lines it reads (the process's PEB on Windows, `/proc/<pid>/environ` on
Linux). Windows shows the current environment, Linux the one the process
started with; the adoption rule re-applies the temp-folder rule to the state
variables, so a process that set `EXOSUIT_SUIT=off` on itself at startup is
judged alike on both. A block that is not double-NUL terminated (a read torn
by the process changing it) reads as unreadable. A 32-bit processkit reads
no environments, since it cannot follow a 64-bit process's PEB; there every
environment is unreadable, so suit adopts nothing (registered processes and
stops still work).

## Stopping

Every stop is graceful first:

- **Workspace manager.** suit writes `stop-request.json` for the manager's
  generation. The manager stops its daemon, removes its endpoint and releases
  its lock, as it does for a restart, but it does not start again.
- **Workspace daemon.** It is stopped through its manager.
- **Editor.** suit asks it to close its windows, so the editor can save or
  prompt. An editor that is still open after 10 s is reported and left
  running. It is never killed while it might have unsaved work.

Quit, Terminate and `suit kill` stop exosuit's own processes: editors,
workspace managers and daemons, compiler workers, live sessions and hosts.
Terminals end the way closing them in the app ends them: the manager's
graceful stop makes the daemon close its PTYs and ConPTY sessions. suit never
kills a process tree wholesale, so a program the user started from a terminal
that detached itself from it survives, as it would if the user closed that
terminal.

Once the grace period ends (3 s for services), suit kills the target if it
still runs, and then sweeps: it kills the target's descendants of kinds
exosuit starts itself (`SuitKinds.spawnedByExosuit`), reached through such
processes only (`SuitLineage.exosuitDescendants`), and never one whose
environment says it belongs elsewhere (`EXOSUIT_SUIT=off`, another suit's
home); an unreadable environment does not exclude. The sweep covers the
descendants captured before anything was stopped and whatever a fresh
snapshot finds under the target or under them. Killing the target first means
it cannot start a child after the sweep's last snapshot; the sweep repeats
with a fresh snapshot until a round kills nothing (at most 4 rounds). Targets
that reach their deadline together share each round's snapshot.

A child counts as one only if it started no earlier than its parent; an older
process naming that pid as its parent belongs to a reused pid. If a snapshot
lists the target's pid with a later start time, the target exited and its pid
was reused: only children that started before the new process are the
target's. With an earlier start time the snapshot predates the target, and
suit does not look below it.

## Tray menu (Windows)

The tray menu is built from a fresh scan each time it opens:

- a title with counts, for example "Exosuit: 2 editors, 7 background
  processes (1 orphaned)". The tooltip shows the same counts.
- processes grouped by editor (with that editor's workspaces), then Haxeon,
  then Other, then Orphaned, then Not started by exosuit. Each process shows its kind, workspace and
  uptime, and has a submenu with Terminate.
- Remote access: each hosting workspace with its relay state, Stop hosting,
  Stop all hosting, and Open Remote Access…
- Terminate orphaned processes, Terminate all background processes (editors
  keep running; both cover only exosuit's processes), Open process viewer… (a console running `suit watch`), and
  Quit Exosuit

Two commands show the menu without clicking. `suit menu` prints it as text.
`suit tray-check` creates the icon, builds the native menu and removes both.

## Daemon

- **One per user.** It takes an exclusive file lock in its home. The home is
  owner-only, using the private-directory and lock primitives the workspace
  manager uses. Starting suit again is always safe, because a second copy
  exits at once.
- **Endpoint.** The CLI talks to it on `\\.\pipe\exosuit-suit-<user>`, or on
  `suit.sock` in its home outside Windows. Setting `EXOSUIT_SUIT_HOME` moves
  the registry, the lock and the endpoint, which is how tests stay isolated
  from the user's suit.
- **Started by.** The editor and the background workspace manager start it,
  detached. `EXOSUIT_SUIT_AUTOSTART=0` prevents only this; registration still
  happens.
- **Idle cost.** It sleeps in the NativeKit event wait and rescans every 10 s
  for the tooltip. It exits after `EXOSUIT_SUIT_IDLE_SECONDS` (default 120)
  with nothing to track, so tests and editors that come and go never leave it
  behind.

## Tests and unattended runs

`EXOSUIT_SUIT` decides what an exosuit process does with suit:

- `on`: register with the user's suit (or `EXOSUIT_SUIT_HOME`), and start it.
- `isolated`: register only with the suit at `EXOSUIT_SUIT_HOME`, and start
  that one. Without `EXOSUIT_SUIT_HOME` this is `off`.
- `off`, or any other value: neither register nor start suit.
- unset: `on`, unless the process keeps its state in the system temp folder
  (`TEMP`/`TMP` on Windows, `TMPDIR` or `/tmp` elsewhere): its
  `PRAGTICAL_PORTABLE`, `XDG_STATE_HOME` or `EXOSUIT_AGENT_STATE_HOME`, or a
  workspace manager's `--state-dir`. Then it is `off` (`SuitClient.modeOf`).

`SuitClient.mode` only answers. Each process settles its mode once at
startup, before it spawns anything (`SuitClient.resolve`, called by the
editor, the workspace manager and the workspace daemon). When the mode is
off only because the state folder is temporary, `resolve` logs `suit
disabled: state folder is temporary (set EXOSUIT_SUIT=on to enable)`, sets
`EXOSUIT_SUIT=off` in its own environment so every child it spawns starts
with it, and an editor window shows that message as a notice once per
session. Registration, the daemon start and relay hosting all use the
resolved mode (`SuitClient.current`).

The temp-folder rule is the central fix for tests run by hand: every test
keeps its state in a disposable temp directory (the suites require a
disposable `PRAGTICAL_PORTABLE`), and a user's editor never does, so a test
script run outside the suites and the guard still stays out of the user's
suit. An explicit `EXOSUIT_SUIT` always wins. A real editor can land there
too, for example a portable build unzipped under `%TEMP%` or `/tmp`; the log
line and the notice say so, and `EXOSUIT_SUIT=on` turns suit back on.

`off` is also set in a few central places, and everything they start
inherits it: the run guard (`docs/benchmarks/perf-harness/run-guarded.ps1`),
the suites (`scripts/test.sh`, `scripts/ci.sh`) and the manager tests'
environment (`manager_environment` in `scripts/agent_test_runtime.py`).
`scripts/test-suit.py` sets `isolated` with its own home, so it exercises the
real registration path without touching the user's registry. It runs suit's
unit tests (`suit/tests`) first; they check the ownership rules over made-up
process snapshots.

## Library path

suit's natives are found by one rule, implemented twice because one side
starts suit before any Haxe code runs: `SuitClient.nativePath` (editors,
bundles, `suit start`) and `library_path` in `scripts/suit.py` (source
trees, and `scripts/test-suit.py`). In order: the directories under the
bytecode's `native/`, `lib/` beside the bytecode's directory, the HashLink
runtime's directory, Haxeon's `out/` and `.tools/hashlink/`, then the
inherited value.

## Decisions

- **A HashLink program built like the agent host.** It reuses NativeKit, the
  local RPC transport and the runtime's lock primitives, and the tray is one
  small NativeKit API (`nk_tray_*`).
- **Registration is a file drop, not a pipe call.** It cannot block, it works
  while suit is down or restarting, and it needs no client code in the
  processes that register. The pipe carries only control requests: status,
  quit and stop.
- **`list`, `kill` and `relay` run in the CLI process.** They work without
  the daemon, and the daemon rescans on its next tick.
- **Compiler workers and live sessions are not registered.** Haxeon is shared
  with other work, so suit finds them by scanning instead of changing the
  compiler, and adopts those that exosuit started through its own processes.
  A worker suit never saw under an exosuit process, or one started with
  `cmd /c start` (which breaks the parent chain), stays "not started by
  exosuit", even if exosuit did start it: a missed cleanup is better than
  killing someone else's build.
- **No tree kills.** suit stops only processes of exosuit's kinds. A
  terminal's processes end when the daemon closes the terminal, as in the
  app; whatever survives that was detached by the user and is the user's.
- **macOS and Linux.** Registration, scanning (Linux `/proc`), kills and the
  CLI are portable. The tray is Windows-only, and macOS process listing is not
  implemented yet.
