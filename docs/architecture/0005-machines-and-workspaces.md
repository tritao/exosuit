# ADR 0005: suit is the machine; a machine's workspaces are lists of folder services

Status: proposed

## Context

The user's model of Exosuit is:

> I run exosuit on a Machine. That Machine has a list of workspaces, which are a collection of one or more folders.
> All work should be grouped underneath those workspaces on that machine. A remote view should be able to select a
> machine, and then view all the workspaces, with all the workgroups and their sub-groups.

and, on the parts:

> the phone should be able to pair with n-machines. The suit itself wraps a machine, not a folder. A Machine can
> provide a series of folder services, so there's not a lot of change that's necessary.

What the code has today:

- **Folder services.** The workspace service (the agent's `--manager`) serves one folder. Its state folder is
  `workspaces/<sha256(root)[0..20]>` (`agent/src/app/AgentManager.hx`), and its catalog holds that folder's groups,
  terminals, agent sessions and paired devices. Several can run per folder, one per build
  (`AgentMachine.hx`, `MachineWorkspaces.hx`, the Machine view).
- **The editor's workspace** is a saved list of folders (M18.1, `src/workspace/SavedWorkspace.hx`). It is a local
  file, and the Workbench attaches to one folder's service even when it lists three.
- **suit** is the per-user daemon (`suit/src/suit/SuitDaemon.hx`). It tracks Exosuit's processes, and it hosts the
  relay link for each folder service that has remote hosting on (`relay-hosts/<machineId>.json`). The editor and
  managers start it on demand (`SuitClient.ensureDaemon`).
- **Remote "machines" are folders.** The relay `machineId` is created per folder service
  (`AgentRelayBootstrap.hx:13-27`), with its own Noise key, relay bearer, and `workspace_devices` pairings. The
  Android app's "Machines" list holds one entry per paired folder (mobile-app worktree, `android/ARCHITECTURE.md`).

What that costs:

- **No first folder, no work.** Nothing holds a workspace before a folder is open, so Agent mode cannot create a
  group on a fresh start.
- **A workspace with several folders stops at the editor.** Its groups live in only one folder's service.
- **Remote access pairs per folder.** Pairing a phone with cube means pairing it once per folder, and nothing can list
  cube's workspaces.

## Decision

### Vocabulary

- **Machine**: a computer the user runs Exosuit on, such as `cube`, with a stable id and a name (the host name,
  renameable). **suit is the machine's process.** A machine serves zero or more workspaces; a fresh machine has
  none, and its first offer is New workspace.
- **Folder service**: today's workspace service, unchanged: one folder, its groups, terminals and agent sessions.
  A machine provides any number of them.
- **Workspace**: a named, ordered list of one or more folders on one machine. suit keeps the list. A workspace's
  work lives in its folders' services.
- **Group** and **sub-group**: unchanged (M14). A group lives in the folder service of the folder its directory is
  in, so a group belongs to every workspace that lists that folder.
- **Device**: a paired remote client (phone, browser). It pairs with any number of machines, each pairing
  independent, and on each machine is granted workspaces.

### 1. suit keeps the machine and its workspaces

suit gains a small catalog in its home:

- the machine id and name;
- workspaces: id, name, ordered folders.

and a local RPC surface on its existing control pipe:

| Method | Does |
|---|---|
| `machine.identity` | machine id and name, and the workspace list |
| `workspace.create` | name and first folder; returns the id |
| `workspace.rename`, `workspace.delete` | delete removes the list only; folder services and their groups stay |
| `workspace.add-folder`, `workspace.remove-folder` | edits the list |
| `machine.services` | the running folder services, by folder and build: today's `--machine` listing, moved into suit |
| `folder.start` | starts the folder service for a folder on a build, as the editor does now |

Folder services do not change: same state folders, same pipes, same catalogs, same per-build choice.

### 2. One client model: machines, then workspaces, then groups

The desktop editor, the web client and the Android app are the same kind of client. Each shows a list of machines,
each machine's workspaces, and each workspace's groups and sub-groups. They differ only in how they reach a machine:

- the desktop editor reaches its own machine through suit's local pipe;
- every client reaches other machines through the relay, as a paired device. The editor on cube pairs with octa
  (a MacBook running suit) exactly as a phone does.

So suit runs on every machine the user works on, Windows and macOS, and the editor's Workbench shows the same tree the
phone shows.

### 3. What the editor shows

- **The Workbench's top level is machines**, this machine first, then paired ones, online or offline. Under each,
  its workspaces, which may be none. **New workspace** is in the Workbench, on any machine where this client may
  create one: it asks for a name and the first folder on that machine. **Add folder** adds more.
- **Agent mode** opens on the Workbench. Selecting a workspace attaches to each of its folders' services and shows
  their groups, one section per folder. New group asks which folder when the workspace has more than one.
- **One tree.** Groups and sessions nest under their workspace, not in a separate list below the workspaces:

  ```
  cube · this machine
    ▸ exosuit
    ▾ resume-2026
        ▾ Work
            Codex · Terminal
    ▸ eon-series
    + New Workspace…
  ```

  First, only the open workspace is expanded: expanding another opens it, and the previous one collapses. Later
  (with step 3 and the remote view), every expanded workspace shows its groups at once, which needs a client per
  workspace's folder services, the same attachment remote clients need. The first Workbench (step 2) still shows the
  open workspace's groups as a list under the workspace list; users read that list as unrelated to the workspaces.
- **Editor mode** stays folder-first. Opening a folder uses a workspace whose only folder it is, and creates one if
  none exists. **Add Folder to Workspace** writes to suit's list.
- A saved `.workspace` file becomes a pointer to the machine and workspace id, with name and folders as a fallback
  when suit is unavailable.
- Without suit (`EXOSUIT_SUIT=off`), the editor behaves as today: the open folders are the workspace, held locally.

The client change is attaching to several folder services at once. Today `LocalWorkspaceClient` serves one folder;
the Workbench gets one client per folder of the workspace.

### 4. Remote: devices pair with the machine

- **Identity.** suit holds one relay identity per machine: the machine id, and the Noise static key and relay bearer
  in the OS credential store under it. One machine socket per machine.
- **Devices and grants.** Paired devices move from each folder's `workspace_devices` to suit. A device is granted
  workspaces, each with capabilities. Pairing grants nothing until the owner picks workspaces.
- **Channels.** suit terminates Noise for each device channel, checks the device's pin, and serves
  `machine.identity` filtered to the device's grants. When the device opens a folder of a granted workspace, suit
  forwards that stream to the folder service over its local pipe with the grants attached. The folder service enforces
  them per request, as `WorkspaceRpcServer.acceptRemote(secure, grants)` does now.
- **Many machines per device.** A device keeps a list of paired machines: relay origin, machine id, and its own device
  id and key per machine. Pairing with cube and with a laptop are independent; revoking one leaves the other.
- **The remote view** lists paired machines (online or offline), then a machine's granted workspaces, then their
  groups and sub-groups. The Android "Machines" list becomes one entry per machine.

This reverses one rule of the suit-relay design (16-remote-workspaces.md, "Relay hosting under suit"): suit now holds
the Noise key, device pins and grants. That rule kept secrets with the process that owned the pairings; the machine's
pairings are now suit's.

### 5. Builds

Unchanged. Each build runs its own folder services on its own state folders, and the Machine view picks which one
the editor uses per folder. suit lists them all (`machine.services`). Devices reach the default build's folder
services only.

### 6. Migration

- suit creates the machine id and name on first start, and one workspace per existing folder service state folder
  (`workspaces/<hash>`), named after the folder. Nothing in the folder services moves.
- Per-folder relay identities retire. Devices pair again, once, with the machine. This is acceptable while the only
  paired devices are development ones.

## Build order

Each step is shippable and tested on its own. The mobile app is built concurrently on its own branch, so the protocol
comes first and both sides build against it.

0. **Protocol.** Define `machine.identity`, `workspace.*` and the folder-stream open as Haxe protocol types with
   wire vectors (as in RPC-VECTORS.md), and agree them with the mobile-app branch before either side implements.
   Until step 6, the mobile app keeps using today's per-folder pairing; nothing it relies on changes earlier.
1. **suit's machine catalog and local RPC** (section 1), with migration of existing folders into workspaces.
2. **Workbench top level: this machine and its workspaces**, with New workspace and Add folder. This is what lets
   a fresh editor start work without opening a folder.
3. **Workbench over several folder services**: one client per folder, groups shown per folder.
4. **Editor mode**: open folder and Add Folder go through suit; `.workspace` files become pointers.
5. **Machine view** reads `machine.services` from suit; `--machine` stays for scripts.
6. **suit relay identity per machine**, devices and grants in suit, channel forwarding (section 4).
7. **Other machines in every client**: the editor pairs with octa; web and Android show machines, workspaces and
   groups; one device, many machines.

## Consequences

- suit becomes required for workspaces and remote access, but not for editing a folder. It must run on macOS as
  well as Windows.
- suit holds secrets it did not before. Its private-file and pipe checks (16-remote-workspaces.md, "Attach checks")
  now guard the machine's keys.
- A group can still point anywhere its folder service allows today. Workspaces do not narrow that.
- A crash in one folder service still affects only that folder.

## Open questions

1. **A group in a folder listed by two workspaces** shows in both. Is that wanted, or should a group name its
   workspace? Default: show in both; it is the same work.
2. **Workspace names.** Unique per machine, or free text with the id as identity? Default: free text.
3. **Remote access to other builds.** Should a device reach a worktree build's folder services through suit?
   Default: no, until needed.
