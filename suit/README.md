# suit

suit is a per-user daemon that tracks every background process that exosuit
editors start, for any number of editors. On Windows it shows the Exosuit tray
icon. Its command line works with or without the daemon.

```
python scripts/suit.py list            every exosuit process, grouped by editor; orphans last
python scripts/suit.py kill --orphans  stop exosuit's processes whose editor is gone
python scripts/suit.py kill --all --dry-run   what a bulk kill would stop, stopping nothing
python scripts/suit.py quit            quit Exosuit: editors are asked to close, everything else stops
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
  since been reused is deleted, and so is a record for a process that has
  exited. A process whose start time cannot be read is not trusted.
- **Scanning.** Unless `EXOSUIT_SUIT_SCAN=0` is set, suit also reads the
  command lines of `hl`, `exosuit` and `exosuit-agent` processes. It
  recognizes editors, workspace managers and daemons, Haxeon compiler workers,
  and live sessions and live hosts.
- **Ownership is positive.** A process is exosuit's only when it registered,
  or when its parent chain leads to a registered process. In the second case
  suit *adopts* it: it writes a record (`adopted: true`, `owner`: the
  ancestor), so the process stays exosuit's after that ancestor exits.
  Everything else suit finds by scanning, such as a compiler worker of a
  terminal build or another agent's, or a test's workspace manager, is listed
  as *Not started by exosuit*. It is never orphaned and never included in
  `kill --orphans`, `kill --all`, Terminate all, or Quit; `suit kill <pid>`
  still stops it when asked by pid.
- **Orphans.** Each kind has one rule (`SuitKinds.orphanRule`):
  - A workspace manager or daemon belongs to every registered editor that
    uses its root, whichever editor started it. It is orphaned when none
    does.
  - Compiler workers are resident by design, so they are orphaned only when
    no exosuit editor and no exosuit live session is running.
  - Anything else is orphaned when the process it belongs to is gone: its
    recorded owner, or else its parent.

Process listing, start times, termination and "close your windows" are in
`native-packages/processes` (processkit). Every call that acts on a process
takes a pid and a start time, and does nothing unless the start time matches
exactly. A process whose start time is unknown is never acted on.

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
process tree, deepest first: the tree captured before anything was stopped,
plus whatever a fresh snapshot finds under it. It snapshots again until no new
descendant turns up, so a child started during the grace period does not
survive. A child counts as one only if it started no earlier than its parent;
an older process naming that pid as its parent belongs to a reused pid.

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

- unset or `on`: register with the user's suit (or `EXOSUIT_SUIT_HOME`), and
  start it.
- `isolated`: register only with the suit at `EXOSUIT_SUIT_HOME`, and start
  that one. Without `EXOSUIT_SUIT_HOME` this is `off`.
- `off`, or any other value: neither register nor start suit.

`off` is set in a few central places, and everything they start inherits it:
the run guard (`docs/benchmarks/perf-harness/run-guarded.ps1`), the suites
(`scripts/test.sh`, `scripts/ci.sh`) and the manager tests' environment
(`manager_environment` in `scripts/agent_test_runtime.py`). Set it yourself
when you run a test script by hand outside them. `scripts/test-suit.py` sets
`isolated` with its own home, so it exercises the real registration path
without touching the user's registry.

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
  compiler, and adopts those that descend from a registered exosuit process.
  A worker suit never saw under an exosuit process stays "not started by
  exosuit", even if exosuit did start it: a missed cleanup is better than
  killing someone else's build.
- **macOS and Linux.** Registration, scanning (Linux `/proc`), kills and the
  CLI are portable. The tray is Windows-only, and macOS process listing is not
  implemented yet.
