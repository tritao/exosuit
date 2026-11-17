# ADR 0006: Workspaces and groups do not need folders; a workspace service per workspace

Status: accepted (2026-10-29; agreed with tritao), built. Refines [ADR 0005](0005-machines-and-workspaces.md).

## Context

A folder used to do three jobs:

1. **Identity.** A service's state folder, pipe, exohost record and relay identity were keyed by a hash of its folder.
2. **Working directory.** Agent sessions and terminals start in their group's folder, or else the service's.
3. **File features.** Files, Search and Changes (source control) are rooted at it.

Only job 2 is a real requirement, and only of a session: Codex, Claude, Pi and a shell each need a working
directory. A workspace or a group does not. Tying the other jobs to a folder meant a workspace could not exist before
a folder was chosen, and a workspace with several folders needed a service per folder.

## Decision

### Model

- **Workspace.** It has an id, a name and a machine, and zero or more **attached folders**. An attached folder
  enables file features for that folder. It does not define the workspace. A workspace with no folders is valid, and
  it still has groups, sessions and terminals.
- **The workspace is its own root group.** Sessions and terminals can sit directly under the workspace, in no named
  group. A root item's group is the empty id (`WorkspaceProtocol.ROOT_GROUP`). New sessions and terminals go to the
  root unless a group, or an item in one, is selected. A new catalog has no groups.
- **Group.** It has an id, a name, a parent, an order and an optional folder.
- **Session (agent or terminal).** It always has a working directory, resolved once, when it is created:
  1. the directory chosen for the session;
  2. else its group's folder, or the nearest ancestor group's (`GroupFolders`);
  3. else the workspace's first attached folder;
  4. else the workspace's **scratch folder**, a visible folder `~/Exosuit/<workspace name>`, made on demand by exohost
     and recorded in `machine.json`, so renaming the workspace does not move it. A name already taken gets a numeric
     suffix.

  Starting a session or terminal offers its resolved folder with **Change…** (`SessionFolderChooser`).
- **Groups hold sessions, chats and terminals**, and each group has its own set of open tabs, so switching groups
  swaps the tabs with it (per-context layouts, keyed by machine, workspace and group).
- **Every window sees the whole machine.** Each window shows every workspace on the machine with its groups,
  sessions and terminals, updated live, and is focused on one workspace and group. Focus and tabs belong to a window;
  the workspaces, groups and sessions are shared.

### A workspace service per workspace

The service's identity is the **workspace id**:

- One service holds the workspace's groups, sessions and terminals, wherever their directories are.
- Its state folder and pipe are named after the workspace id (`workspaces/<workspace id>/`).
- Attached folders are roots inside that service. File search, file watching and source control serve several roots,
  each labelled; `workspace.folders.manage` (method 153) changes them.
- exohost stays the only machine-level process. It lists the workspaces, starts their services, holds the machine's
  identity and devices, and routes each device to a workspace service by workspace id.
- Isolation stays per workspace: a crash, a hang or a garbage collection pause affects one workspace.

A single global service for every workspace was rejected: a crash or hang would take every session down, HashLink's
stop-the-world collection and the service's mostly single-threaded work would stall every workspace together, and a
build or restart would interrupt everything.

## Consequences

- A workspace is something you make in order to work. Folders are tools it can use.
- One service per workspace means one connection per workspace for every client.
- The service handles several roots.

## Resolved questions

1. **Scratch folder:** visible, at `~/Exosuit/<workspace name>`. A session's folder can be changed when it starts.
2. **A group's folder outside every attached folder:** Files, Search and Changes show it.
3. **Upstream:** tritao agrees with the per-workspace service.
