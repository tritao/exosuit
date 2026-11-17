# Architecture

How Exosuit's processes fit together. The decisions behind it are in
[ADR 0005](architecture/0005-machines-and-workspaces.md) and [ADR 0006](architecture/0006-workspaces-without-folders.md),
the [Workbench design](design/workbench/WORKBENCH-DESIGN.md) and the [suitctl design](design/suitctl/TDD-exosuit-ctl.md).

```
                     ┌───────────────────────────────────────────────────────────┐
                     │ suit  (one per user; the only server; tray on Windows)    │
                     │  machine.json      the machine and its workspaces         │
                     │  EditorDirectory   one entry per linked editor window     │
                     │  SuitServices      the services it started, + a spare     │
                     │  ControlRouter     suitctl / Pragtical v1 / automation    │
                     │  MachineRemote     relay socket, paired devices, grants   │
                     └──▲──────────────────▲───────────────────────▲─────────────┘
       editor link      │  spawn, adopt,   │ service-attach        │ relay socket (Noise channels,
   (machine.changed,    │  stop            │                       │ stream frames)
   control, quit)       │                  │                       │
┌───────────────────────┴──┐   ┌───────────┴─────────────┐   ┌─────┴──────────────────┐
│ editor window            │   │ workspace service       │   │ relay Worker           │
│  SuitLink                │   │ (one process per        │   │ (Cloudflare)           │
│  MachineClient           │   │  running workspace)     │   └─────▲──────────────────┘
│  WorkspaceLinks ─────────┼──▶│  SQLite catalog         │         │
│  focus = ActiveContext   │   │  files, SCM, agents     │   ┌─────┴──────────────────┐
│  Workbench (one tree)    │   │  terminal manager       │   │ phone, browser         │
└──────────────────────────┘   │  catalog-snapshot.bin   │   │  RemoteMachines        │
      local pipe: catalog      └───────────┬─────────────┘   │  WorkspaceLinks over   │
      watch, typed RPCs                    │ host pipe       │  relay streams         │
                               ┌───────────┴─────────────┐   └────────────────────────┘
                               │ terminal host, one per  │
                               │ terminal; owns the PTY; │
                               │ outlives the service    │
                               └─────────────────────────┘
```

A device's streams reach a service through suit: suit forwards each one to the service's local pipe.

## Code layout

| Folder | What |
|---|---|
| `src/` | The headless core shared by every app: editor model and controllers (`core`, `controller`, `editor`), the workspace protocol (`workspace/service`), its clients (`workspace/client`), transports (`workspace/transport`), suit's client side (`suit`) |
| `graphical/` | The desktop editor: `app.GraphicalMain` and the UIKit shell (`ui.ExosuitApp` and its parts) |
| `agent/` | The workspace service (`app.AgentMain`), the terminal host (`app.TerminalHostMain`), the agent providers |
| `suit/` | suit and suitctl (`app.SuitMain`) |
| `android/`, `web/` | The phone app and the browser build; both run the same `ExosuitApp` |
| `relay/worker/` | The relay: a Cloudflare Worker with a SQLite Durable Object per machine |
| `native-packages/` | C libraries the apps bind: processes, terminal, sqlite, noise, oniguruma, plugin host |
| `haxeon/` | The compiler, runtime, UIKit and NativeKit (a submodule) |

## suit

suit is one daemon per user (`suit/src/suit/SuitDaemon.hx`), always on: an editor window starts it when it does not
answer. It holds an exclusive lock in its home (`%LOCALAPPDATA%\exosuit\suit`, or `$XDG_STATE_HOME/exosuit/suit`) and
listens on one pipe (`\\.\pipe\exosuit-suit-<user>`, or `suit.sock` in its home). `EXOSUIT_SUIT_HOME` moves the home
and the pipe. It is the only server; editors and services are its clients.

- **The machine.** `machine.json` holds the machine's id and name and its workspaces: id, name, folders, scratch
  folder, revision (`src/suit/MachineCatalog.hx`). Only suit writes it. It answers `machine` from memory and pushes
  `exosuit.machine.changed` (the workspaces with their running services, and every window's focus) to every linked
  window when anything in it changes. The requests that change it (`workspace-create`, `workspace-rename`,
  `workspace-delete`, `workspace-add-folder`, `workspace-remove-folder`, `workspace-scratch`, `machine-rename`) come
  from editors and from the `suit` CLI.
- **Editors.** Each editor window holds one link (`src/suit/SuitLink.hx`; `editor-attach`). `EditorDirectory` lists
  a window from its attach until its link closes; nothing about editors is written to disk. Over the link the window
  reports its state (`exosuit.state`: focused context, workspaces, roots), suit pushes machine changes, and suit sends
  the window requests: control methods and `exosuit.quit {mode}`.
- **Services.** `SuitServices` starts one service process per running workspace. On `workspace.open {workspace}` from
  an editor, or `OPEN` from a device, it hands the workspace to the warm spare if one is ready, else spawns
  `hl <agent> --workspace ID [--folder F]... [--scratch S]`. The service reports itself once it listens
  (`service-attach`: workspace, pipe, pid, generation, root, build) and keeps that connection open; suit answers the
  open with the pipe, and learns the service stopped when the connection closes. Opens of a workspace whose start is
  under way wait for that start. A service of another build is asked to stop once no agent turn runs and is started
  again; its terminals carry on. While an editor is linked suit keeps one **warm spare** (`--spare`, linked as
  `service-spare`, adopted with `adopt`).
- **Inventory and quit.** suit lists every Exosuit process (`SuitInventory`): linked editors, services and terminal
  hosts that register a record in `registry/`, and processes it adopts by scanning command lines and parent chains.
  It rescans every 10 s for the tray tooltip. The full Quit asks every editor to close (keeping unsaved work for the
  next start) and ends everything Exosuit started, terminal hosts included; the polite quit (`--keep-terminals`) leaves
  terminal hosts running. See [suit/README.md](../suit/README.md).
- **Control plane.** `ControlRouter` serves the `control` op and Pragtical control protocol v1 (below).
- **Remote.** `MachineRemote` holds the relay socket and the paired devices (below).

It exits after `EXOSUIT_SUIT_IDLE_SECONDS` (120) with nothing to track, unless started at login.

## The editor

`app.GraphicalMain` opens the window and builds `ui.ExosuitApp`, the shell over the headless `core.Application`. On
Windows and Linux it then makes the window's suit link, a `MachineClient` over it, and the window's `WorkspaceLinks`.

- **Links.** `WorkspaceLinks` holds one `WorkspaceLink` per workspace the window uses: the one it shows, running
  workspaces whose rows are expanded, and workspaces with terminals open in the window. A link is one connection to the
  workspace's service: it asks suit for the pipe (`MachineClient.open`, which starts the service when it is idle),
  connects, checks the service's IDENTITY against what suit reported, and watches the catalog. A link not used for 30 s
  closes; closing a link never stops a service. A link the window still needs asks suit again when its service goes,
  which starts a new one.
- **Focus.** `ActiveContext` is the `machine/workspace/group` the window shows. Files, Search, Changes, the title and
  the tab set follow it. Switching workspaces moves the focus between links that stay connected; each context keeps
  its own tabs.
- **Workbench.** One tree: the machine's workspaces in suit's order, each with its groups, sessions and terminals
  (`WorkbenchTreeModel`, `WorkbenchRows`). A workspace's rows come from its link's catalog once read, else from the
  catalog snapshot its service left (`CatalogSnapshots`), so idle rows draw without starting anything. Every row has
  its full menu; the row actions are `WorkbenchActions`. A click opens a workspace; an action on another workspace's
  row runs through that workspace's link.
- **The shell's parts.** `ExosuitApp` builds the window and owns one of each part: source control
  (`ScmPanelController`), agent tabs (`AgentTabs`), terminal tabs (`TerminalTabs`), files read through a service
  (`RemoteFileTabs`), the Files view (`ExplorerPanelController`), the served folders (`ServedFolders`), the Settings tab
  (`SettingsTab`), the dock's response to width (`ResponsiveLayout`), context switching (`ContextSwitching`) and what
  automation reads (`ExosuitDiagnostics`).
- **Push, not poll.** suit pushes machine changes; a service pushes catalog CHANGED, after which the window reads the
  lists again. Nothing reads on a timer while nothing changes.
- **Launch forwarding.** `exosuit <folder|file>` with a window open hands the paths to it through suit
  (`LaunchForwarding`, one second at most) and exits; a folder opens as the workspace that holds it, or as a new one
  named after it.

## The workspace service

One process per running workspace (`agent/src/app/AgentMain.hx`; details in [agent/README.md](../agent/README.md)).

- **State.** `workspaces/<id>/` under `%LOCALAPPDATA%\Exosuit` (or `$XDG_STATE_HOME/exosuit`): `agent.lock` (one
  service per workspace), `workspace.json`, `catalog.sqlite`, `service.log`, `catalog-snapshot.bin`, and a folder per
  terminal host. `EXOSUIT_AGENT_STATE_HOME` moves it.
- **Pipe.** A same-user named pipe (or `agent.sock` in the state folder). It listens and reports to suit before the
  catalog, terminals and agents are up; early connections wait in the pipe.
- **Catalog.** The workspace's groups, agent sessions and terminal records, in SQLite (`WorkspaceSqliteStore`). The
  catalog watch (`WorkspaceCatalogService`) serves CATALOG pages and pushes CHANGED to watching connections.
- **Catalog snapshot.** `catalog-snapshot.bin` holds the whole catalog, written once changes settle and on exit
  (`CatalogSnapshotFile`). Editors draw idle workspaces from it.
- **Files and source control** serve every attached folder as a root (`WorkspaceFileService`, `WorkspaceScmService`).
- **Agents.** `WorkspaceAgentService` with the Codex, Claude and Pi providers, each built on first use. An agent
  session is a provider terminal (the default) or a chat session.
- **Idle stop.** It stops after 600 s (`EXOSUIT_SERVICE_IDLE_SECONDS`) with no client and no busy agent turn. Running
  terminals do not keep it; idle chat processes lengthen the wait to at most ten minutes. suit can ask it to stop at
  once or after the running turn.

## Terminal hosts

Every terminal runs in a terminal host (`agent/src/app/TerminalHostMain.hx`): one process per terminal that owns the
pseudoconsole and the only emulator of its screen, run from a private copy of the runtime outside any build tree. The
service starts hosts detached, attaches over each host's private pipe (`TerminalHostProtocol`: ATTACH, INPUT, RESIZE,
SNAPSHOT, THEME, END and the host's replies) and relays between hosts and views. A host outlives its service; the next
service adopts it. suit lists hosts as their own kind, the full Quit ends them, the polite quit keeps them. Details:
[terminal-host-status.md](design/terminal-host-status.md). How agent sessions resume:
[agent-sessions.md](design/agent-sessions.md).

## The workspace protocol

Typed Haxeon RPC over the service's pipe (or a relay stream): a handshake negotiates capabilities, then requests,
responses and notifications with permanent method and field ids. The frozen wire vectors and the rules for changing
the protocol are in [RPC-VECTORS.md](RPC-VECTORS.md).

| Ids | What | Capabilities |
|---|---|---|
| 100, 104, 105 | groups query, identity, group changes | `workspace.read`, `workspace.identity`, `workspace.groups.*`, `workspace.order` |
| 110–119, 138, 139, 155, 156 | terminals: open, input, resize, list, replay, snapshot, restart; CHANGED | `workspace.terminals.catalog`, `.read`, `.control` |
| 120–129 | agent sessions | `workspace.agents.read`, `.control` |
| 140–151 | files: roots, stat, list, reads, watches, search | `workspace.files.read` |
| 153 | the workspace's folders | `workspace.folders.manage` (local only) |
| 160–169 | source control | `workspace.scm.read`, `.write`, `.remote` |
| 170–172 | catalog watch: CATALOG, UNWATCH, CHANGED | `workspace.catalog` |
| 180–183 | machine directory (devices, suit's stream 0): DIRECTORY, OPEN, CLOSE, CHANGED | `machine.directory` |

## Devices: the phone and the browser

A device is a paired client. It pairs once with a machine (suit) and sees the workspaces the owner granted it.

- **Relay.** suit holds one socket to the relay Worker (`relay/worker`) under the machine's relay id
  (`WorkspaceRelayHost`). A device dials the relay with a ticket; the relay forwards bytes between the device and the
  machine socket.
- **Pairing.** A one-time invitation from the Remote Access panel (`RemoteAccessPanel`, suit's `remote-*` ops), Noise
  XX over the relay's pairing socket, a code both sides compare, and the owner's approval. The device side is
  `DevicePairing`; suit keeps pins and grants in `machine-devices.json` (`MachineDeviceStore`), keys in the OS
  credential store. Details: [relay-identity.md](mobile/relay-identity.md).
- **Channel.** Each device has one Noise channel carrying stream frames (`StreamMultiplexer`). Stream 0 is the
  machine directory, served by suit (`MachineDeviceSession`) and filtered to the device's grants. `OPEN` starts an
  idle service and opens a stream that suit forwards, unread, to the service's pipe after an intro naming the device
  and its grants (`ForwardedStream`, `EXFW`). The service enforces the grants per request.
- **Client.** The phone and the browser share `RemoteMachines` (every paired machine), `RemoteMachine` (one machine:
  `DeviceRpcConnector`, `DeviceMachine` on stream 0, its `WorkspaceLinks` over streams) and the same `WorkspaceLink`
  the desktop uses. Their Workbench tree comes from the machine directory by the desktop's rule: the Workbench sees its
  machine through `WorkbenchMachine`, which is suit's on the desktop (`SuitWorkbenchMachine`) and a paired machine's
  directory on a device (`DeviceWorkbenchMachine`, which cannot create, rename or remove workspaces). The phone keeps pairings in a Keystore file
  (`PhoneCredentials`), the browser in IndexedDB (`BrowserPairedMachines`). Details:
  [android.md](mobile/android.md), [web/README.md](../web/README.md).

`suit remote` lists devices and sessions and can disconnect or revoke a device or turn remote access off.

## The control plane

suit is the single control plane (`suit/src/suit/control`):

- **`control` op** on suit's pipe: `{op: "control", version: 1, method, params, target}`. suit answers `control.hello`,
  `control.ping`, `instance.status`, `exosuit.instances` and `exosuit.workspaces.list` itself and forwards every other
  method, unchanged, over the routed window's link. Routing: `target.instance_id`; else the window whose workspaces
  hold the path (deepest folder first), then a window showing that workspace, then the most recently used.
- **Pragtical compatibility.** Each linked window gets a Pragtical control protocol v1 pipe and a descriptor in
  `<suit home>/runtime/instances` (`PragticalPipes`, `PragticalCodec`), so `pragtical-ctl` with `PRAGTICAL_USERDIR`
  set to suit's home finds Exosuit windows.
- **Events are opt-in.** A connection that sends `exosuit.events.subscribe {names}` receives those events; windows are
  told which events anyone wants (`exosuit.events.want`).
- **The window's side** is `graphical/src/ui/control/EditorControl.hx`: Pragtical's methods (`window.focus`,
  `editor.open`, `editor.documents`, `editor.save`, `project.add`, `project.change`), `exosuit.quit`, and automation:
  `exosuit.ui.snapshot`, `exosuit.state.get`, commands, workspaces and windows, terminals and agent sessions, dialogs
  (`DrivenDialogs`), and element input (`SyntheticInput`) delivered into the window's own event queue, never as OS
  input. Real input always wins: injected input waits while the user typed or clicked in the last second.
- **CLI.** `suitctl` is suit run as `--ctl` (`scripts/suitctl.cmd`): `list`, `status`, `focus`, `open`, `documents`,
  `save`, `project`, `call`, `quit`, `watch`. `suit` itself keeps the process commands (`list`, `kill`, `terminals`,
  `quit`, `remote`, `machine`, `workspace`, `login`) and also takes the window commands.

Calls that change or drive a window are logged in `<suit home>/control.log`.

## Tests and isolation

Tests never touch the user's suit or state. They give suit a home of their own (`EXOSUIT_SUIT_HOME`, with
`EXOSUIT_SUIT_AUTOSTART=0` so nothing starts that suit by accident) and isolate the editor's and services' state
(`PRAGTICAL_PORTABLE`, `EXOSUIT_AGENT_STATE_HOME`). This is set in a few places and inherited by everything they
start: the run guard (`docs/benchmarks/perf-harness/run-guarded.ps1`), the suites (`scripts/test.sh`,
`scripts/ci.sh`, `scripts/test-windows.ps1`) and the service tests' environment (`isolated_suit` in
`scripts/test_driver.py`). The suites both runners run are listed once, in `tests/suites.txt`. There is no second code path for tests: the same suit, links and services run
against the isolated home. GUI scenarios (`docs/benchmarks/perf-harness/gui_scenarios/`) drive a real window over the
control plane; only latency captures use OS input.
