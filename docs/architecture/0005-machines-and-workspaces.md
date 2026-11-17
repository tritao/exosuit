# ADR 0005: exohost is the machine; devices pair with the machine

Status: accepted, built. [ADR 0006](0006-workspaces-without-folders.md) sets what a workspace is and that each one
has one service. How the parts work together now is in [ARCHITECTURE.md](../ARCHITECTURE.md).

## Context

The owner's model of Exosuit:

> I run exosuit on a Machine. That Machine has a list of workspaces, which are a collection of one or more folders.
> All work should be grouped underneath those workspaces on that machine. A remote view should be able to select a
> machine, and then view all the workspaces, with all the workgroups and their sub-groups.

and:

> the phone should be able to pair with n-machines. The exohost itself wraps a machine, not a folder.

## Decision

### Vocabulary

- **Machine**: a computer the user runs Exosuit on, with a stable id and a name (the host name, renameable). **exohost
  is the machine's process**, one per user. A fresh machine has no workspaces; its first offer is New Workspace.
- **Workspace**: a named entry in the machine's list, with zero or more folders (ADR 0006). Its sessions, terminals and
  groups live in its service.
- **Group** and **sub-group**: named collections of sessions and terminals inside a workspace.
- **Device**: a paired remote client (the phone, the browser). It pairs with any number of machines, each pairing
  independent, and on each machine is granted workspaces.

### 1. exohost keeps the machine and its workspaces

exohost keeps `machine.json` in its home: the machine id and name, and per workspace an id, name, ordered folders,
scratch folder and revision (`src/exohost/MachineCatalog.hx`). Only the daemon writes it. Requests on exohost's pipe change
it: `machine`, `machine-rename`, `workspace-create`, `workspace-rename`, `workspace-delete`, `workspace-add-folder`,
`workspace-remove-folder`, `workspace-scratch`. Deleting a workspace removes its entry and ends its terminals; its
folders are untouched. The `machine` reply (version 2, [RPC-VECTORS.md](../RPC-VECTORS.md)) adds each workspace's
running service.

### 2. One client model: machines, then workspaces, then groups

The desktop editor, the browser client and the phone show the same tree: a machine's workspaces, and each
workspace's groups, sessions and terminals. They differ only in how they reach the machine: the editor through exohost's
local pipe, devices through the relay as paired devices. All of them hold one `WorkspaceLink` per workspace in use.

### 3. Remote: devices pair with the machine

- **Identity.** exohost holds the machine's relay identity: a relay id per relay, the Noise static key and the relay
  bearer in the OS credential store ([relay-identity.md](../mobile/relay-identity.md)). One machine socket to the
  relay.
- **Devices and grants.** exohost keeps the paired devices and their grants in `machine-devices.json`. Pairing grants
  only the machine directory; the owner grants workspaces, each with capabilities (presets read, edit, all, or an
  explicit list). Grants are live: changing or removing one closes that device's streams to the workspace; revoking
  the device closes its channel.
- **Channels.** A device has one Noise channel to the machine, carrying stream frames. Stream 0 is the machine
  directory (`exosuit-machine/1`: `DIRECTORY`, `OPEN`, `CLOSE`, `CHANGED`), listing only granted workspaces. `OPEN`
  starts an idle workspace's service and returns a stream that exohost forwards, unread, to the service's local pipe.
- **Enforcement stays in the service.** exohost's first message on that pipe is an intro (`EXFW`, `{version, device,
  grants}`, `ForwardedStream`); the service serves the connection with only those grants. A workspace not granted
  answers `unknown_workspace`, as one that does not exist.
- **No workspace service dials the relay.** exohost's machine remote is the only remote access there is.

## Consequences

- exohost is required: it holds the workspace list, starts services and holds remote access. It must run on every
  system Exosuit runs on; the tray is Windows only.
- exohost holds secrets: device pins and grants in its home, which is private to the user, and keys in the OS
  credential store.
- A crash in one workspace's service affects only that workspace.
