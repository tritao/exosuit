# ADR 0005: Machines host workspaces; workspaces hold folders and groups

Status: proposed

## Context

The user's model of Exosuit is:

> I run exosuit on a Machine. That Machine has a list of workspaces, which are a collection of one or more folders.
> All work should be grouped underneath those workspaces on that machine. A remote view should be able to select a
> machine, and then view all the workspaces, with all the workgroups and their sub-groups.

The code has no machine and two unrelated things called "workspace":

1. **The editor's workspace** is a saved list of folders (M18.1, `src/workspace/SavedWorkspace.hx`,
   `src/controller/SavedWorkspaceController.hx`). It lives in a file on disk and never reaches the service.
2. **The workspace service** (the agent's `--manager`) serves exactly one folder. Its state folder is
   `workspaces/<sha256(root)[0..20]>` (`agent/src/app/AgentManager.hx`), its pipe is
   `exosuit-<sha256(root + "\n" + stateDir)[0..20]>`, and groups, terminals, agent sessions and paired devices live in
   that folder's SQLite catalog. Every request carries a `workspace` field, but it is the constant `"workspace"`
   (`agent/src/app/AgentMain.hx:91-119`); the real identity is the root plus the manager's generation.

What that costs today:

- **No first folder, no work.** Groups need a service, a service needs a root, and nothing creates a workspace before
  a folder is open. In Agent mode the user cannot make a group on a fresh start.
- **Builds collide on a folder.** Two builds working on one folder find the same service by its path hash. The
  per-build state folders and the Machine view (`AgentMachine.hx`, `MachineWorkspaces.hx`) were added to work
  around that.
- **Multiple folders stop at the editor.** A saved workspace with three roots still attaches the Workbench to one
  folder's service. The service's file and SCM parts already take up to 16 roots (`WorkspaceScmService.hx:80-89`)
  but are handed `[root]` (`AgentMain.hx:91-92`).
- **The service watches its whole root, at start** (`WorkspaceFileService.startWatcher`, recursive). That rules out a
  broad root such as the user folder.
- **"Machine" means a folder's service in remote access.** The relay's `machineId` is created per state folder
  (`AgentRelayBootstrap.hx:13-27`; 16-remote-workspaces.md calls it "per-workspace machine identity"). The Noise key,
  relay bearer, device pairings (`workspace_devices`) and suit's `relay-hosts/<machineId>.json` are all per folder.
  The Android app heads its list "Machines", but each entry is a paired folder (mobile-app worktree,
  `android/ARCHITECTURE.md`). Pairing a phone with cube means pairing it once per folder.

## Decision

### Vocabulary

Use these words in code, UI and docs. They replace the M18 vocabulary where it differs.

- **Machine**: a computer the user runs Exosuit on, such as `cube`. It has a name (the host name, renameable) and a
  stable id. Remote access pairs with a machine. **suit is the machine's process**: the per-user daemon that holds the
  machine's identity, its relay connection and its paired devices, and starts the machine service.
- **Machine service**: the long-running process that holds a machine's workspaces (today's manager, re-scoped). One
  per user and build on a machine; see *Builds*. suit starts it on demand and supervises it.
- **Workspace**: a named, ordered list of one or more folders on one machine, kept by the machine service. It owns
  groups, and through them terminals and agent sessions. M18's "saved set of folders" is the same idea, moved from a
  local file into the service.
- **Root**: one folder of a workspace.
- **Group** and **sub-group**: unchanged (M14). A group belongs to one workspace; its working directory lies inside
  one of the workspace's roots.
- **Device**: a paired remote client (phone, browser). It pairs with any number of machines, each pairing
  independent, and on each machine is granted workspaces.

### 1. One machine service, many workspaces

The machine service starts without a folder. Its state folder is per machine and build, not per root:
`<stateBase>/machine/` for the default build (see *Builds*). Its catalog gains:

- `workspaces(id, name, revision, order, payload)`, where the payload holds the ordered roots.
- `workspace_id` on groups. Terminals and agent sessions already belong to groups.

The `workspace` field every request already carries becomes the real workspace id. Requests for an unknown id keep
failing with `unknown_workspace` (`WorkspaceService.hx:184`). New methods:

| Method | Does |
|---|---|
| `machine.identity` | machine id and name, build, the workspace list (id, name, roots, revision) |
| `workspace.create` | name and first root; returns the id |
| `workspace.rename`, `workspace.delete` | delete refuses while terminals or agent sessions run, unless forced |
| `workspace.add-root`, `workspace.remove-root` | remove refuses while a group's directory is under that root |
| `workspace.identity` | today's IDENTITY, per workspace, with all roots |

The file and SCM services get each workspace's roots instead of `[root]`, and keep their 16-root limit per workspace.

### 2. Watch on demand, not at start

A root is watched while some client subscribes to files or SCM under it, and unwatched after the last one leaves.
Starting the machine service watches nothing. That keeps a workspace with many or large roots cheap until it is used.

### 3. What the editor shows

- **Agent mode** opens on this machine's workspace list. **New workspace** asks for a name and the first folder;
  **Add folder** adds roots. Selecting a workspace shows its groups. No folder needs to be open first.
- **Editor mode** stays folder-first. Opening a folder uses the workspace whose only root is that folder, and creates
  one if none exists. **Add Folder to Workspace** adds a root to the current workspace in the service.
- A saved `.workspace` file becomes a pointer: machine id and workspace id, with the name and roots as a fallback for
  when that machine's service is unavailable.
- Choosing a group's directory offers folders inside the workspace's roots. Picking a folder outside them offers to
  add its folder as a root first. The service enforces it.

### 4. suit wraps the machine

suit today hosts relay links per folder (`relay-hosts/<machineId>.json`, one machine socket per hosted workspace). It
becomes the machine:

- **Identity.** suit creates and keeps the machine id and name in its home, with the Noise static key and relay
  bearer in the OS credential store under the machine id. One machine, one relay identity, one machine socket.
- **Devices.** Paired devices and their grants move from each folder's `workspace_devices` to suit's own store.
  Grants become per workspace: a device holds a set of `(workspace id, capabilities)` pairs. Pairing grants nothing
  until the owner picks workspaces, so a device paired with a machine still sees only what it was given.
- **Channels.** suit terminates Noise for each device channel, checks the device's pin, and forwards the channel's RPC
  to the machine service over the local pipe, with the device's grants attached. The machine service enforces the
  grants per request, as `WorkspaceRpcServer.acceptRemote(secure, grants)` does now.
- **Service lifecycle.** suit starts the default build's machine service when a client or device needs it, and
  lists every build's machine service for the Machine view. Nothing starts at login unless the user opts in, as now.

This reverses one rule of the suit-relay design (16-remote-workspaces.md, "Relay hosting under suit"): suit now holds
the Noise key and device pins. The reason that rule existed, keeping secrets in the process that owns the catalog,
now points at suit, because the machine and its devices are suit's.

### 5. Remote: a device pairs with many machines

- A device keeps a list of paired machines: relay origin, machine id, its own device id and key per machine. Pairing
  with `cube` and with a laptop are two independent pairings; revoking one leaves the other.
- The remote view lists the paired machines (online or offline), then a machine's granted workspaces, then their
  groups and sub-groups, from `machine.identity` and the per-workspace group catalog.
- The Android app's "Machines" list becomes what its title says: one entry per machine, not per folder. The web
  client's saved-machine selection (`BrowserRemoteWorkspaceClient.hx`) is already keyed by machine id and keeps
  that shape.

### 6. Builds

Several builds of Exosuit run on one machine during development (worktrees, the mobile-app branch). Each build's
machine service keeps its own state, as the per-build state folders do now: the default build at `machine/`, others
at `machine-<launcherKey>/`. "Start one on this editor's build" copies the default's catalog, as it does today. The
Machine view lists machine services instead of per-folder managers. Remote access pairs with the default build's
service only.

### 7. Migration

On first start, the machine service imports every per-root state folder under `workspaces/` into a workspace with
that one root and the folder's name. Groups, terminals and agent sessions (with their stored transcripts) come across;
the operation and event logs do not, so clients resynchronize. A folder whose manager is still running is imported
later, when it stops. The imported folders stay on disk until the user removes them.

Paired devices and relay identities do not migrate: each per-folder `machineId` cannot become the machine's one id.
Devices pair again, once, with the machine. This is acceptable while the only paired devices are development ones.

## Build order

Each step is shippable and tested on its own.

1. **Workspaces in the catalog.** Add the workspaces table and `workspace_id` on groups; make the `workspace` field
   real; add the `workspace.*` methods. The service still starts per root and holds one workspace, so nothing else
   changes yet.
2. **Watch on demand** (section 2).
3. **Machine service.** Start without a root at `machine/`; serve many workspaces; the file and SCM services take
   each workspace's roots. Editor's client attaches to the machine and selects a workspace.
4. **Agent mode workspace list**, New workspace, Add folder; group directory picker limited to roots.
5. **Editor mode**: open folder maps to a one-root workspace; Add Folder writes to the service; `.workspace` files
   become pointers.
6. **Migration** of per-root state folders (section 7); the Machine view lists machine services.
7. **suit as the machine**: machine identity, one relay socket, devices and per-workspace grants in suit, channel
   forwarding to the machine service (section 4).
8. **Remote clients**: machine list, workspace list and group tree in web and Android; one device paired with several
   machines (section 5).

## Consequences

- One process holds every workspace on the machine, so a crash in it drops all of them, not one. Terminals and
  agent sessions already survive client restarts, not service crashes; this widens that blast radius. Recovery
  (`docs/recovery.md`) must restart the service and reattach every workspace.
- The per-root pipe name, `endpoint.json` per root, the per-root registry in `AgentMachine.hx` and suit's
  per-workspace relay hosts are removed after migration (steps 6 and 7), not kept alongside.
- suit becomes required for remote access, and it holds secrets it did not before. Its private-file and pipe checks
  (16-remote-workspaces.md, "Attach checks") now guard the machine's keys.
- Clients and services of different versions do not mix: a client that sends the constant `"workspace"` gets
  `unknown_workspace` from a machine service. The handshake version is raised in step 3.
- M18.7 open decision 1 ("authorize multiple roots") is decided: yes, a workspace's roots are its authorized
  folders.

## Open questions

1. **Group directories outside every root.** This ADR requires adding the folder as a root first. Earlier work
   allowed groups to point at any folder. Is the extra step acceptable?
2. **One process, or one per workspace.** One process is simpler and is what section 1 says. A process per workspace,
   started by the machine service, would contain crashes but costs a supervisor. Revisit if crashes happen.
3. **Workspace names.** Unique per machine, or free text with the id as identity? Default: free text.
4. **Remote access to other builds.** Section 6 pairs devices with the default build's service only. Should a device
   also reach a worktree build's service through suit? Default: no, until needed.
