# ADR 0006: Workspaces and groups do not need folders; a workspace service per workspace

Status: accepted (2026-10-29; agreed with tritao). Plan of work: [M19](../roadmap/19-machine-workspaces.md).

Amends [ADR 0005](0005-machines-and-workspaces.md), which keeps one workspace service per folder and makes a
workspace "one or more folders".

Amended 2026-10-30: **the workspace is its own root group.** Sessions and terminals can sit directly under the
workspace, in no named group; named groups such as Work are optional sub-folders. A root item's group is the empty id
(`WorkspaceProtocol.ROOT_GROUP`). No group can have that id, so the wire types and stored records are unchanged and
existing groups and items need no migration. A root session starts in the workspace's first folder, else its scratch
folder (which the editor passes as the explicit folder until Phase 4). New sessions and terminals go to the root unless
a group, or an item in one, is selected; new catalogs still seed a Work group.

Downgrade risk: a service from before this change cannot open a catalog that holds a root terminal. It rejects the
stored record ("Invalid persisted terminal record") and does not start. Creating or moving an item to the root
against such a service fails with "Unknown group". An editor and its service ship together, so this only bites when
going back to an older build. Editors from before this change do not show root items, and a terminal such an editor
starts without a group (Ctrl+`) now lands at the root, where it cannot see it.

Amended 2026-10-30: **the Workbench tree starts at the workspaces.** The machine is no longer a tree row. A dropdown
above the tree names it ("cube · this machine"); it lists this machine only, and remote machines join it as further
choices later. New Workspace… stays the last row of the workspace list. With suit off the tree is unchanged.

## Context

A folder does three jobs today:

1. **Identity.** A workspace service's state folder is named after a hash of its folder
   (`AgentManager.hx`, `workspaces/<20 hex>`), and so is its pipe (`\\.\pipe\exosuit-<hash of folder and state>`).
   Its suit record, relay identity, image staging (`AgentImageStaging`) and the Machine view all key on the folder.
2. **Working directory.** Agent sessions and terminals start in their group's folder, or else the service's.
3. **File features.** Files, Search and Changes (source control) are rooted at it.

Only job 2 is a real requirement, and only of a session: Codex, Claude, Pi and a shell each need a working
directory. A workspace or a group does not. Tying the other two jobs to a folder causes these problems:

- A workspace cannot exist before a folder is chosen. Wanting to start work is enough reason to make one.
- A workspace with several folders needs a service per folder, and the Workbench has to stitch their groups
  together (ADR 0005, step 3).
- Groups may already point anywhere, so "a folder's groups" only means "the groups stored in whichever service holds
  them".
- Remote access gives each folder its own identity.

## Decision

### Model

- **Workspace.** It has an id, a name and a machine, and zero or more **attached folders**. An attached folder
  enables file features for that folder. It does not define the workspace. A workspace with no folders is valid,
  and it still has groups, sessions and terminals.
- **Group.** It has an id, a name, a parent and an order, and an optional folder. The protocol already allows a group
  with no folder (`cwd: null`).
- **Session (agent or terminal).** It always has a working directory, resolved once, when it is created:
  1. the directory chosen for the session;
  2. else its group's folder, or the nearest ancestor group's;
  3. else the workspace's first attached folder;
  4. else the workspace's **scratch folder**, a visible folder `~/Exosuit/<workspace name>`. It is created on
     demand. Its path is recorded in suit's catalog when it is created, so renaming the workspace does not move it.
     A name that is already taken gets a numeric suffix.

  The scratch folder is the default instead of the home folder, so that by default an agent writes files somewhere
  that belongs to the workspace. Starting a session or terminal offers its resolved folder with **Change…**, which
  uses the existing folder picker (the one groups use); the home folder is one choice there. The session's directory
  is shown where the session is.
- **Groups are collections of sessions, chats and terminals.** Each group also has its own set of open tabs, so
  switching groups is instant and swaps the tabs with it (M18.4's per-context layouts, keyed by workspace and group).
- **Every window sees the whole machine.** Several editor windows or instances can be open, each focused on its own
  workspace and group. Each still shows every workspace on the machine with its groups, sessions and terminals,
  updated live. Focus and tabs belong to a window; the workspaces, groups and sessions are shared. On restart, each
  group's tabs come from the last window that saved them (stored per group, so windows never overwrite each other's
  other groups). The last window closed is the one reopened.

### A workspace service per workspace

The service's identity becomes the **workspace id**, not a folder. This is the same choice as moving from one
service per folder to one service per workspace. It gives the following:

- One service holds the workspace's groups, sessions and terminals, wherever their directories are.
- Its state folder and pipe are named after the workspace id: `workspaces/<workspace id>/`,
  `\\.\pipe\exosuit-<hash of workspace id and state>`.
- Attached folders are roots inside that service. File search, file watching and source control serve several roots,
  each labelled. The right panel's group scope still narrows to a group's folder when the group has one.
- suit stays the only machine-level process. It lists the workspaces (ADR 0005), starts their services, holds the
  machine's identity and devices, and routes each device to a workspace service by workspace id.
- Isolation stays per workspace: a crash, a hang or a garbage collection pause affects one workspace.

A single global daemon was considered and rejected:

- A crash or hang would take every session on the machine down with it.
- HashLink's stop-the-world garbage collection, and the service's mostly single-threaded work, would stall every
  workspace together.
- A build or restart would interrupt everything.

## What changes

1. **suit** (`MachineCatalog`):
   - A workspace may have no folders. `create` takes a name and optional folders, and removing the last folder is
     allowed.
   - `machine.json` keeps folders as an optional list. Version 2 reads version 1 unchanged.
2. **Workspace service identity** (`agent`):
   - `--manager` is started by workspace id, with the attached folders as arguments or read from suit.
   - The state folder, pipe, suit record (`workspace` id, `folders`), relay identity and image staging are keyed by
     workspace id.
   - `WorkspaceStopRequest`, orphan rules (`SuitKinds.orphanRule`: a service is used by an editor that has its
     workspace open) and the Machine view switch from roots to workspace ids.
3. **Sessions:**
   - Session creation resolves the working directory as above and records it on the session.
   - The scratch folder is created on demand.
   - Agent permission profiles that use the working directory (Codex `read-only`, Pi's permission extension) take
     the resolved directory.
4. **Several roots in one service:**
   - File search, file watching and source control run per attached root, and replies say which root each result
     comes from.
   - Source control already discovers repositories per directory (session folders outside the workspace,
     `ScmFolderScope`); this extends it to every root.
5. **Editor:**
   - The Workbench creates a workspace with a name only. Attaching a folder is a separate, optional action.
   - The Workbench shows one tree of workspaces, groups and sessions, below a dropdown that chooses the machine.
     With no folders, Files, Search and Changes show an empty state with "Attach Folder…".
   - Editor mode opens a folder by attaching it to a workspace (ADR 0005, step 4).
6. **Protocol and clients:** requests name the workspace by id; a folder becomes an optional attribute. This is
   agreed with the mobile-app branch before either side builds it, as ADR 0005 step 0 requires.

## Migration

- Each existing per-folder service state (`workspaces/<hash>`) becomes one workspace's state, with that folder
  attached. Its groups, sessions and history keep their ids.
- suit's `machine.json` workspaces from ADR 0005 already have ids. Each one is mapped to the migrated state of its
  first folder.
- A workspace that ADR 0005 listed with several folders has one service per folder today. Their states are merged
  into one: the groups of each folder go under a top-level group named after that folder, so nothing collides.
- Remote devices pair again once with the machine, as ADR 0005 already requires.

## Build order

This replaces ADR 0005 step 3 (several folder services per workspace) and comes before it, so the per-folder
stitching is never built.

1. suit: workspaces with no folders (small; the editor's New Workspace asks for a name only).
2. Session working directory resolution and the scratch folder, inside today's per-folder service. This is useful
   on its own, because it means sessions in groups with no folder work.
3. Service identity by workspace id, with migration. One attached folder per workspace at first.
4. Several attached folders per service: search, watching and source control per root.
5. The Workbench tree, and empty states for file features.
6. Protocol by workspace id for remote clients, with the mobile-app branch.

## Consequences

- A workspace is something you make in order to work. Folders are tools it can use.
- One service per workspace means fewer processes than one per folder, and one connection per workspace for every
  client.
- The service must handle several roots. This is the main new complexity, and it replaces the per-folder stitching
  in the client.
- Migration has to be careful. It moves the state that today's sessions and terminals depend on, so it runs once,
  keeps a backup of each state folder, and refuses rather than guessing on anything it does not recognise.

## Resolved questions

1. **Scratch folder:** it is visible, at `~/Exosuit/<workspace name>`. When a session starts, its folder can be
   changed with the existing folder picker.
2. **A group's folder outside every attached folder:** Files, Search and Changes show it. This is an editor, so
   everything a group works in is visible.
3. **Upstream:** tritao agrees with the per-workspace service.
