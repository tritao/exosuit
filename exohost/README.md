# exohost

exohost is a per-user daemon that tracks every background process that exosuit
editors start, for any number of editors. On Windows it shows the Exosuit tray
icon. Its command line works with or without the daemon.

```
python scripts/exohost.py list            every exosuit process, grouped by editor; orphans last
python scripts/exohost.py kill --orphans  stop exosuit's processes whose editor is gone
python scripts/exohost.py kill --all --dry-run   what a bulk kill would stop, stopping nothing
python scripts/exohost.py quit            quit Exosuit and end everything it started, terminals included (editors asked to close)
python scripts/exohost.py quit --keep-terminals   the polite quit: everything but terminals; exohost stays up while one runs
python scripts/exohost.py help            all commands
```

It is also the editors' control plane: `exohostctl` (`scripts/exohostctl.cmd`, or
`python scripts/exohost.py --ctl`) is the same program under a second name.

```
exohostctl list                    the open windows: id, pid, context, workspace folders
exohostctl open <folder|file[:line[:col]]>   a folder opens as the workspace that holds it (or a new one); a file in a tab
exohostctl documents | save | focus | status
exohostctl project add|change <folder>
exohostctl quit --mode prompt|recover|save
exohostctl call <method> '<json params>'     any control method, e.g. exosuit.ui.snapshot
exohostctl watch [event...]       print the events asked for, one JSON line each
```

## How processes are known

- **Editors link.** Each editor window holds one connection to the daemon
  (`src/exohost/ExohostLink.hx`, `editor-attach` on exohost's pipe), starting exohost when
  it is not running. Over it the window reports where it is (`exosuit.state`:
  its focused context, workspaces and roots); exohost pushes the machine's
  workspaces and windows (`exosuit.machine.changed`) whenever they change, and
  asks the window to quit (`exosuit.quit`). The daemon's list of linked editors
  is `exohost/src/exohost/EditorDirectory.hx`; a window whose link closes is gone.
  Editors write no registry record.
- **Services.** exohost starts a workspace's service when an editor asks for it
  (`workspace.open` on the editor's link) or a paired device needs it: one
  process per running workspace (`hl <agent> --workspace ID --folder F...`).
  The service connects once it listens (`service-attach` with its workspace,
  pipe, pid, generation, root and build: `src/exohost/ExohostServiceLink.hx`) and
  holds the connection; exohost answers `workspace.open` with that pipe, and
  `machine` lists it as that workspace's service until the connection closes
  (`exohost/src/exohost/ExohostServices.hx`). A service of another build is asked to
  stop after its running agent turn and started again.
- **Registration.** For stopping and listing, the workspace service, once it
  is ready, also writes `<pid>.json` into
  `registry/` in exohost's home, atomically, with their root, state directory and
  generation; terminal hosts write one too. Registration never blocks, and it
  never fails the process. If exohost is not running, the record waits for it.
  The record format is in `src/exohost/ExohostRecord.hx`; the client is
  `src/exohost/ExohostClient.hx`.
- **Validation.** exohost trusts a record only while the pid's start time is no
  later than the time the record was written. A record for a pid that has
  since been reused is ignored, and so is a record for a process that has
  exited; the daemon deletes both. A running process whose start time cannot
  be read (one this user may not open) keeps its record: it is listed with an
  unknown start and never acted on (`ExohostInventory.keepsRecord`).
- **Record times.** Records are written with `ExohostClock.now()`, the wall
  clock in milliseconds with sub-second precision (`Sys.time()`; HashLink's
  `Date.now()` has whole seconds only, which made a record written in its
  process's first second look older than the process). Records carry
  `version: 2`. A version 1 record holds whole seconds, so it is allowed one
  second before the start time (`ExohostClock.registeredAfterStart`).
- **Scanning.** Unless `EXOSUIT_EXOHOST_SCAN=0` is set, exohost also reads the
  command lines of `hl`, `exosuit` and `exosuit-agent` processes, and from
  each one its `EXOSUIT_EXOHOST_HOME` and `PATH` variables. It
  recognizes editors, workspace services, Haxeon compiler workers,
  and live sessions and live hosts.
- **Ownership is positive.** A process is exosuit's only when it registered,
  or when exohost *adopts* it (`ExohostLineage.adoptionOwner`). Adoption needs all
  of these:
  - it is of a kind exosuit starts itself (`ExohostKinds.spawnedByExosuit`): a
    workspace service, a compiler worker, a live session or host;
  - its environment registers with this exohost (`ExohostLineage.registersWith`,
    the one place this policy lives): its exohost home, resolved
    (`EXOSUIT_EXOHOST_HOME`, else the default home), is this exohost's resolved home.
    An environment exohost cannot read (`PATH` missing) does not count;
  - its parent chain reaches a registered process through processes of those
    kinds only, each started no earlier than its parent.

  A build the user runs in an exosuit terminal has a shell between it and the
  workspace daemon, so it is never adopted. The daemon writes a record for an
  adopted process (`adopted: true`, `owner`: the ancestor), so it stays
  exosuit's after that ancestor exits. Everything else exohost finds by scanning,
  such as a compiler worker of a terminal build or another agent's, or a
  test's workspace service, is listed as *Not started by exosuit*. It is never
  orphaned and never included in `kill --orphans`, `kill --all`, Terminate
  all, or Quit; `exohost kill <pid>` still stops it when asked by pid.
- **Reading has no side effects.** `exohost list`, `exohost watch`, `exohost menu` and
  `kill --dry-run` only read. The daemon's inventory alone deletes stale
  records and writes adoption records.
- **Orphans.** Each kind has one rule (`ExohostKinds.orphanRule`):
  - A workspace service belongs to every linked editor that
    uses its workspace or root, whichever editor started it. It is orphaned when none
    does.
  - Compiler workers are resident by design, so they are orphaned only when
    no exosuit editor and no exosuit live session is running.
  - Anything else is orphaned when the process it belongs to is gone: its
    recorded owner, or else its parent.

Process listing, start times and termination are in
`native-packages/processes` (processkit). Every call that acts on a process
takes a pid and a start time, and does nothing unless the start time matches
exactly. A process whose start time is unknown is never acted on. On
Windows, `processkit_started` reports a process it may not open as
`PROCESSKIT_STARTED_DENIED` (-2), not as gone. `processkit_list_open` reads
the environment variables it is asked for from the processes whose command
lines it reads (the process's PEB on Windows, `/proc/<pid>/environ` on
Linux). Windows shows the current environment, Linux the one the process
started with. A block that is not double-NUL terminated (a read torn
by the process changing it) reads as unreadable. A 32-bit processkit reads
no environments, since it cannot follow a 64-bit process's PEB; there every
environment is unreadable, so exohost adopts nothing (registered processes and
stops still work).

## Stopping

Every stop is graceful first:

- **Workspace service.** exohost sends `stop` over the service's link. The
  service stops its agent processes, closes its storage and releases its lock.
- **Editor.** exohost asks the window to quit over its link (`exosuit.quit`).
  Quit asks with `recover`: the window closes at once and keeps unsaved text
  in its recovery store for the next start. Terminating one editor asks with
  `prompt`: the window asks about unsaved work as its own close does. An
  editor that is still open after 10 s is reported and left running. It is
  never killed while it might have unsaved work.

exohost is the final arbiter: its full Quit (`exohost quit`, tray "Quit Exosuit and
end everything") ends everything exosuit started, terminal hosts included, and
the daemon exits only once a fresh inventory holds nothing of exosuit's.
Background processes that reappear during a quit (a service an editor restarts
while closing) are ended again, up to 3 rounds; editors are asked to close
once, and one kept open over unsaved work keeps the daemon up, listed, until it
closes. The polite quit (`exohost quit --keep-terminals`, tray "Quit, keep
terminals running (N)") does the same but leaves terminal hosts running; the
daemon stays up, listing them, and exits after the last one ends. Use it
before a rebuild or a switch of checkout: hosts run from a runtime copy in the
state folder, not from the checkout.

Quit, Terminate and `exohost kill` stop exosuit's own processes: editors,
workspace services, compiler workers, live sessions and hosts, terminal hosts.
Terminals in terminal hosts outlive a service's stop; the full Quit ends their
hosts. exohost never
kills a process tree wholesale, so a program the user started from a terminal
that detached itself from it survives, as it would if the user closed that
terminal.

Once the grace period ends (3 s for services), exohost kills the target if it
still runs, and then sweeps: it kills the target's descendants of kinds
exosuit starts itself (`ExohostKinds.spawnedByExosuit`), reached through such
processes only (`ExohostLineage.exosuitDescendants`), and never one whose
environment says it belongs elsewhere (another exohost's home); an unreadable
environment does not exclude. The sweep covers the
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
exohost does not look below it.

## Terminal hosts

A terminal host (`hl terminal-host.hl --terminal-host DIR`, docs/design/terminal-host-status.md) keeps one terminal
alive while its workspace service is stopped. exohost treats it as its own kind, `terminal-host`:

- It registers itself; one started by an older build is adopted when its environment registers with this exohost and
  `host.json` in the folder its command line names holds its pid.
- It is listed in the group "Terminals" with its workspace and terminal (`terminal.json` in its folder), and counted
  in the summary ("2 terminals"). It is never orphaned, so `exohost kill --orphans` and the orphan sweep never end it.
- The stop of its service and the close of its editor leave it running: that is the feature.
- The full Quit (`exohost quit`, tray "Quit Exosuit and end everything (N terminals)"), "Terminate all background
  processes" and `exohost kill --all` end it. The polite quit (`exohost quit --keep-terminals`, tray "Quit, keep terminals
  running (N)") leaves it running and says how many terminals stay.
- `exohost terminals` lists hosts; `exohost terminals end --all` or `end <workspace>` (id, root or folder name), "End all
  terminals (N)" in the tray, a host's own submenu and `exohost kill <pid>` end them: exohost kills the host and its
  program.
- Removing a workspace (`exohost workspace delete`) ends its hosts.

## What is connected from outside

exohost holds the machine's relay connection and every remote device session itself (`exohost/src/exohost/remote`), so it
lists them and can cut them off:

- `exohost remote` (and `--json`) shows remote access (on or off, relay origin, connected, live sessions) and each paired
  device: name when it gave one, when it was paired (`pairedAt` in `machine-devices.json`, kept for devices paired
  from this build on), connected now or not, and the workspaces it may use. No workspace service dials a relay: this is all the
  remote access there is.
- `exohost remote disconnect <device>` ends a device's live session now (the pairing stays, so the device may dial
  again); `exohost remote revoke <device>` revokes its pairing (cut off for good); `exohost remote off` turns remote access
  off, ending every remote session and the relay connection. The tray has the same under "Paired devices (N)", with
  "Turn remote access off".
- The full Quit ends every remote session and the machine's relay connection at once,
  not only when the daemon exits. Remote access stays configured and is back when exohost next starts. The polite quit
  leaves them.
- A phone cannot be made to quit its app. exohost cuts it off (its session and the relay connection end, or its pairing
  is revoked) and the app shows the machine as offline or unpaired.

## Tray menu (Windows)

The tray menu is built from a fresh scan each time it opens:

- a title with counts, for example "Exosuit: 2 editors, 7 background
  processes (1 orphaned)". The tooltip shows the same counts.
- processes grouped by editor (with that editor's workspaces), then Haxeon,
  then Other, then Orphaned, then Not started by exosuit. Each process shows its kind, workspace and
  uptime, and has a submenu with Terminate.
- Remote access: Paired devices (N), each with Disconnect now and Revoke pairing, and Turn remote access off
- Terminate orphaned processes, Terminate all background processes (editors
  keep running, terminal hosts end; both cover only exosuit's processes), End all terminals (N) and per workspace,
  Open process viewer… (a console running `exohost watch`), Quit Exosuit and end everything (N terminals), and, when
  terminals run, Quit, keep terminals running (N)

`exohost menu` prints the menu as text without clicking.

## Daemon

- **One per user.** It takes an exclusive file lock in its home. The home is
  owner-only, using the private-directory and lock primitives the workspace
  service uses. Starting exohost again is always safe, because a second copy
  exits at once.
- **Endpoint.** The CLI talks to it on `\\.\pipe\exosuit-exohost-<user>`, or on
  `exohost.sock` in its home outside Windows. Setting `EXOSUIT_EXOHOST_HOME` moves
  the registry, the lock and the endpoint, which is how tests stay isolated
  from the user's exohost.
- **Started by.** The editor starts it, detached. `EXOSUIT_EXOHOST_AUTOSTART=0` prevents only this; links and
  registration still try that home.
- **The machine.** exohost keeps the machine's workspaces in memory
  (`machine.json` in its home) and answers `machine` from there, with the
  services that reported themselves and the windows that linked.
- **Idle cost.** It sleeps in the NativeKit event wait and rescans every 10 s
  for the tooltip. It exits after `EXOSUIT_EXOHOST_IDLE_SECONDS` (default 120)
  with nothing to track, so tests and editors that come and go never leave it
  behind.

## Control plane

docs/design/exohostctl/TDD-exosuit-ctl.md is the design. In short:

- **One channel.** Programs send `{op: "control", version: 1, method, params, target}` on exohost's pipe.
  exohost answers `control.hello`, `control.ping`, `instance.status` and `exosuit.instances` itself
  and forwards every other method over the window's link (ExohostLink), so there is no second channel.
  ControlRouter routes: `target.instance_id`, else the window whose workspaces hold `target.path`
  (deepest root), else the most recently used window.
- **Pragtical compatible.** Every linked window also gets a Pragtical control protocol v1 pipe
  (`\\.\pipe\exosuit-exohostctl-<user>-<window>`) and a descriptor in `<home>/runtime/instances`,
  so `pragtical --ctl` with `PRAGTICAL_USERDIR` set to exohost's home finds it (PragticalPipes,
  PragticalCodec). NativeKit's listener stops when a client closes before it is accepted
  (docs/haxeon-compiler-bugs.md); exohost starts it again, but until NativeKit is fixed only
  `pragtical --ctl list` is reliable.
- **Events are opt-in.** A connection that sends `exosuit.events.subscribe {names}` gets those
  events and nothing else; windows are told which events anyone wants (`exosuit.events.want`).
- **Driving a window.** `exosuit.ui.*` input goes into the window's own event queue (SyntheticInput),
  never the OS's, and the user's own recent input holds it back (`busy`). While a program drives a
  window its dialogs wait for `exosuit.dialog.answer`. Calls that change or drive a window are logged
  to `<home>/control.log` (the last 500 to 1000), and the tray tooltip says which windows are driven.
- **Launch forwarding.** `exosuit <folder|file>` hands its paths to an open window through exohost
  and exits; with no window, or with options that need a window of its own, it opens one.

## Tests and unattended runs

exohost is always on: every editor links to it and every service reports to it.
Tests and unattended runs stay out of the user's exohost by giving it a home of
their own (`EXOSUIT_EXOHOST_HOME`), usually with `EXOSUIT_EXOHOST_AUTOSTART=0` so
nothing starts that exohost. This is set in a few central places, and everything
they start inherits it: the run guard
(`docs/benchmarks/perf-harness/run-guarded.ps1`, a temporary home unless the
caller set one), the suites (`scripts/test.sh`, `scripts/ci.sh`,
`scripts/test-windows.ps1`) and the service tests' environment
(`isolated_exohost` in `scripts/test_driver.py`). `scripts/test-exohost.py`
runs exohost itself in its own home, with editor stand-ins that link as editors
do, so it exercises the real link and registration paths without touching the
user's exohost. It runs exohost's unit tests (`exohost/tests`) first; they check the
ownership rules over made-up process snapshots.

## Library path

exohost's natives are found by one rule, implemented twice because one side
starts exohost before any Haxe code runs: `ExohostClient.nativePath` (editors,
bundles, `exohost start`) and `library_path` in `scripts/exohost.py` (source
trees, and `scripts/test-exohost.py`). In order: the directories under the
bytecode's `native/`, `lib/` beside the bytecode's directory, the HashLink
runtime's directory, Haxeon's `out/`, then the inherited value (Haxeon's VM directory
is the runtime's own directory).

## Decisions

- **A HashLink program built like the agent host.** It reuses NativeKit, the
  local RPC transport and the runtime's lock primitives, and the tray is one
  small NativeKit API (`nk_tray_*`).
- **Editors and services connect; other processes drop a file.** An editor
  needs to hear from exohost (the machine, a quit) and exohost needs to know at once
  when a window or a service goes, so both hold a connection. Registration of
  the processes exohost only stops is a file drop: it cannot block and works while
  exohost is down or restarting.
- **`list` and `kill` run in the CLI process.** They work without
  the daemon, and the daemon rescans on its next tick.
- **Compiler workers and live sessions are not registered.** Haxeon is shared
  with other work, so exohost finds them by scanning instead of changing the
  compiler, and adopts those that exosuit started through its own processes.
  A worker exohost never saw under an exosuit process, or one started with
  `cmd /c start` (which breaks the parent chain), stays "not started by
  exosuit", even if exosuit did start it: a missed cleanup is better than
  killing someone else's build.
- **No tree kills.** exohost stops only processes of exosuit's kinds. A
  terminal's processes end when the daemon closes the terminal, as in the
  app; whatever survives that was detached by the user and is the user's.
- **macOS and Linux.** Registration, scanning (Linux `/proc`), kills and the
  CLI are portable. The tray is Windows-only, and macOS process listing is not
  implemented yet.
