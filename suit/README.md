# suit

suit is a per-user daemon that tracks every background process that exosuit
editors start, for any number of editors. On Windows it shows the Exosuit tray
icon. Its command line works with or without the daemon.

```
python scripts/suit.py list            every exosuit process, grouped by editor; orphans last
python scripts/suit.py kill --orphans  stop processes whose editor is gone
python scripts/suit.py quit            quit Exosuit: editors are asked to close, everything else stops
python scripts/suit.py help            all commands
```

## How processes are known

- **Registration.** A process registers by writing `<pid>.json` into
  `registry/` in suit's home, atomically:
  - the editor, when it starts, with the workspace roots it uses
  - the workspace manager and the workspace daemon, once they are ready

  Registration never blocks, and it never fails the process. If suit is not
  running, the record waits for it. A record holds the process's kind, its
  root, its state directory and generation, and its owner. The owner is the
  editor that started the service, passed down in `EXOSUIT_SUIT_OWNER`.
- **Validation.** suit trusts a record only while the pid's start time is
  earlier than the time the record was written. A record for a pid that has
  since been reused is deleted, and so is a record for a process that has
  exited.
- **Scanning.** Unless `EXOSUIT_SUIT_SCAN=0` is set, suit also reads the
  command lines of `hl`, `exosuit` and `exosuit-agent` processes. It
  recognizes editors, workspace managers and daemons, Haxeon compiler workers,
  and live sessions and live hosts. These show up marked *unregistered*, which
  catches stragglers from older builds and crashes.
- **Orphans.** A workspace service is orphaned when no running editor started
  it and no running editor uses its root. Compiler workers are resident by
  design, so they count as orphaned only when no editor and no live session is
  running. Any other process is orphaned when its owner is gone, or its parent
  if it has no owner.

Process listing, start times, termination and "close your windows" are in
`native-packages/processes` (processkit). Every call that acts on a process
takes a pid and a start time, and does nothing if the start time no longer
matches.

## Stopping

Every stop is graceful first:

- **Workspace manager.** suit writes `stop-request.json` for the manager's
  generation. The manager stops its daemon, removes its endpoint and releases
  its lock, as it does for a restart, but it does not start again.
- **Workspace daemon.** It is stopped through its manager.
- **Editor.** suit asks it to close its windows, so the editor can save or
  prompt. An editor that is still open after 10 s is reported and left
  running. It is never killed while it might have unsaved work.

Once the grace period ends (3 s for services), suit kills what is left of the
process tree, deepest first. The tree is captured before anything is stopped.

## Tray menu (Windows)

The tray menu is built from a fresh scan each time it opens:

- a title with counts, for example "Exosuit: 2 editors, 7 background
  processes (1 orphaned)". The tooltip shows the same counts.
- processes grouped by editor (with that editor's workspaces), then Haxeon,
  then Other, then Orphaned. Each process shows its kind, workspace and
  uptime, and has a submenu with Terminate.
- Remote access: each hosting workspace with its relay state, Stop hosting,
  Stop all hosting, and Open Remote Access…
- Terminate orphaned processes, Terminate all background processes (editors
  keep running), Open process viewer… (a console running `suit watch`), and
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
  detached. Set `EXOSUIT_SUIT_AUTOSTART=0` to prevent this. The test scripts
  (`scripts/test*.sh`, `scripts/test-*.py`) and the run guard set it by default;
  export `EXOSUIT_SUIT_AUTOSTART=1` to test autostart itself.
- **Idle cost.** It sleeps in the NativeKit event wait and rescans every 10 s
  for the tooltip. It exits after `EXOSUIT_SUIT_IDLE_SECONDS` (default 120)
  with nothing to track, so tests and editors that come and go never leave it
  behind.

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
  compiler.
- **macOS and Linux.** Registration, scanning (Linux `/proc`), kills and the
  CLI are portable. The tray is Windows-only, and macOS process listing is not
  implemented yet.
