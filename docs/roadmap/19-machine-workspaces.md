# M19: Machine workspaces, one tree, instant groups, many windows

Implements [ADR 0005](../architecture/0005-machines-and-workspaces.md) and
[ADR 0006](../architecture/0006-workspaces-without-folders.md). Depends on M14 (Workbench groups), M18 (contexts and
per-context layouts) and suit. Read [EXECUTION.md](EXECUTION.md) first, and record evidence in
[STATUS.md](STATUS.md).

## Goal

- A machine (suit) serves any number of workspaces. A workspace is a name with zero or more attached folders.
- Each workspace has one service, which holds its groups. A group is a collection of agent sessions, chats and
  terminals, with an optional folder.
- The Workbench is one tree: machine, then workspaces, then groups and sub-groups, then sessions and terminals.
- Selecting a group switches to it instantly, and its open tabs come with it.
- Several editor windows or instances can be open, each focused on its own workspace and group. Every window sees
  the whole machine, live.
- Remote clients (the phone, octa) use the same model through suit, later.

## Vocabulary

| Word | Meaning | Owned by |
|---|---|---|
| Machine | one computer, one suit | suit (`machine.json`) |
| Workspace | id, name, attached folders (0..n), scratch folder | suit's catalog lists it; its service holds its work |
| Workspace service | one process per workspace (`agent --manager`), by workspace id | started by suit or an editor |
| Group | id, name, parent, order, optional folder; holds sessions and terminals | the workspace service |
| Session | an agent chat or terminal; always has a working directory | the workspace service |
| Window | one editor instance. Focus (its context) and tab sets are per window | the editor |
| Context | the window's focus: one workspace and group | the editor (M18 `ActiveContext`) |

## Principles

- **Shared state lives in services, view state lives in windows.** Workspaces, groups, sessions and terminals are
  shared by every window and device. Focus, open tabs, scroll and pane layout belong to a window.
- **Nothing blocks the frame loop.** Every suit and service call is asynchronous, like `MachineClient`.
- **Switching is a view operation.** Switching group or workspace detaches and attaches views; it never starts,
  stops or reconnects anything on the critical path.
- **Every step can ship.** After each phase the editor still works for daily use. A feature flag guards the
  migration until it is proven.

## Phase 0: protocol, agreed with the mobile-app branch

Mobile-app work is paused (2026-10-29) while the workspace concept changes. Phase 0 is settled on this side first,
and the mobile app resumes against the agreed protocol.

- [ ] Write the wire types in `src/workspace/service/` with frozen vectors in `tests/haxeon-rpc`:
  - `WorkspaceRef {machine, workspace}` names a workspace in every request. A folder becomes an attribute.
  - `CatalogWatch`: a subscription to one service's lightweight catalog (groups, sessions, terminals, status and
    attention counts; no content), with resume tokens. `watch` on terminal open already exists, so reuse its
    connection-scoped change notifications.
  - Sessions and terminals carry `directory` (the resolved working directory) on create and in the catalog.
  - suit's `machine` reply in a v2 shape: workspaces with `folders` (possibly empty), `scratch`, `service`
    (endpoint, pid, running) and `revision`.
- [ ] Review with the mobile-app session, and record the agreed shape in `RPC-VECTORS.md`.

Acceptance: vectors are frozen and both branches build against them. Nothing changes behaviour yet.

## Phase 1: suit, workspaces without folders, scratch folders

- [ ] `MachineCatalog` v2:
  - `folders` may be empty, and removing the last folder is allowed;
  - add `scratch`, created on first use at `~/Exosuit/<name>`, with a numeric suffix if the name is taken, and
    recorded so it never moves;
  - read v1 unchanged.
- [ ] Ops: `workspace-create {name, folders?}` and `workspace-scratch {workspace}`, which creates and returns the
  scratch folder. CLI: `suit workspace new --name N [folder...]`.
- [ ] `MachineClient` exposes the v2 shape.
- [ ] Tests: unit tests (no folders, scratch creation, suffixes, v1 read) and `test-suit.py` machine scenarios.

Acceptance: the Workbench's New Workspace asks only for a name. A folderless workspace survives a suit restart.

## Phase 2: session working directory and the folder chooser

This works inside today's per-folder service, so it is useful before the identity change.

- [ ] Resolve a session's directory in the service (`WorkspaceAgentService`, terminal open), in this order: the
  explicit directory, then the group's folder, then the nearest ancestor's, then the workspace's first folder, then
  the scratch folder (from suit). Record it on the session.
- [ ] New Agent Session… and New terminal show "Folder: <resolved>" with **Change…**. Change… uses the existing folder
  picker (the one group folders use, `desktop.selectDirectory` with the command-view fallback); the home folder is
  one of the choices.
- [ ] Permission profiles take the resolved directory: Codex `read-only`/`workspace-write` roots, and Pi's
  permission extension.
- [ ] Tests: resolution order (the workspace-agents and terminals harnesses), and a session in a group with no
  folder.

Acceptance: a group with no folder starts sessions in the scratch folder; Change… starts one in the home folder; the
session shows its folder.

## Phase 3: the Workbench is one tree

The model and the UI land first, on today's services. A workspace's groups appear once its service is attached;
Phase 6 makes every workspace live.

- [ ] `WorkbenchTreeModel` gets a top level: machine, then workspaces (from `MachineClient`), then groups and
  sub-groups, then sessions and terminals.
  - Workspace rows: expand and collapse, a running/idle state, and the context menu (Rename, Attach Folder…,
    Remove from This Machine, Open in New Window, from Phase 8).
  - Group rows keep today's menus.
- [ ] Remove `WorkbenchMachineSection`'s separate list; the empty states move into the tree.
- [ ] Expanding a workspace attaches its service, which is started by suit if needed. The tree keeps expanded
  state per window.
- [ ] Keyboard: arrows, Enter to focus, type-to-find. The tree's accessibility labels name the workspace and
  group.
- [ ] Tests: tree model unit tests (the `workbench-drag` and `sidebar-layout` style), and a PrintWindow capture of
  the tree.

Acceptance: the Workbench shows one tree; a workspace's groups and sessions are nested under it; nothing is drawn
as a separate list.

## Phase 4: one service per workspace (identity by workspace id) and migration

This is the riskiest phase. It ships behind `EXOSUIT_WORKSPACE_IDENTITY=workspace` until migration is proven on
real state, and then becomes the default.

- [ ] `AgentManager`:
  - `--manager --workspace <id> [--folder F]...`;
  - the state folder is `workspaces/<workspace id>/`;
  - the pipe is `exosuit-<hash of workspace id and state>`;
  - the lock and generation are per workspace.
  - Today these come from a hash of the folder: `AgentManager.hx:557` and `:904-907`.
- [ ] Re-key everything else the folder keyed:
  - the suit record (`workspace`, `folders`);
  - `WorkspaceStopRequest`;
  - `SuitKinds.orphanRule` (used while an editor has the workspace open, or suit hosts it);
  - the Machine view (`AgentMachine`, `machine.services`);
  - `AgentImageStaging`;
  - relay identity and settings;
  - the content stores.
- [ ] Migration, run once per old state folder, with this procedure:
  1. lock the folder;
  2. back it up (`<state>.bak-<time>`);
  3. move it into the workspace's state;
  4. verify the catalog opens and every group and session id is present;
  5. write a marker.

  Anything it doesn't recognise makes it refuse, and the old state is left in place. A workspace with several old
  folder states merges them, with each folder's groups under a top-level group named after the folder.
- [ ] Tests:
  - migration fixtures made from copies of real states (single folder, two folders, a corrupt catalog);
  - restart idempotence;
  - an old editor build attaching to a migrated workspace is refused with a clear message.

Acceptance: on a copy of this machine's state, every existing group, session and terminal history appears under the
right workspace after migration. A second run changes nothing. The backups restore cleanly.

## Phase 5: several roots in one service; the right panel shows everything

- [ ] File search, file watching and the file service run per attached folder. Replies carry the root, and the UI
  labels them.
- [ ] Source control discovers repositories under every root and every group or session folder (it extends
  `ScmFolderScope` and session SCM sources).
- [ ] The right panel shows a selected group's folder even when it is outside every attached folder.
- [ ] Attach and detach a folder without restarting the service; watchers start and stop with the folder.
- [ ] Tests: `workspace-files`, `workspace-scm` and `scm-watch` with two roots plus an outside group folder.

Acceptance: with two folders attached and a group folder elsewhere, Files, Search and Changes show all three,
labelled, and narrow when a sub-group is selected.

## Phase 6: every window sees the whole machine

- [ ] Every window holds a `CatalogWatch` connection to every running workspace service. suit's `machine` reply
  says which are running.
- [ ] Workspaces that aren't running show as idle from suit's list. Expanding one starts it.
- [ ] A catalog connection carries no session content. Session and terminal streams attach only for open tabs, and a
  terminal not shown is not streamed.
- [ ] One `WorkspaceConnections` pool per window: connect, resume, back off, and drop when suit says a service
  stopped. It reuses `NativeRpcHub` and the existing reconnect fencing.
- [ ] Tests: two workspace services, one window. A session created by another client appears in the tree within
  one catalog event. Killing a service shows it idle; restarting it brings it back.

Acceptance: every workspace's groups, sessions and terminals are in the tree and update live. Memory and connection
counts stay bounded with ten workspaces; measure and record them.

## Phase 7: instant group switching, with tabs

M18.4 already keeps per-context layouts and switches them in memory (`UiWorkbenchHost.switchContext`), and saves
them per context.

- [ ] The context key becomes `machine/workspace/group`. Switching across workspaces is the same operation as
  switching within one.
- [ ] Keep each recently used group's views attached: detach on switch, don't dispose. The last N groups stay warm,
  and older ones are rebuilt from their saved snapshot.
- [ ] Switching never waits on the network. Tabs whose session isn't loaded yet show their last content (snapshot)
  until the stream catches up.
- [ ] Quick switch: a palette entry listing workspaces and groups, plus Ctrl+Tab between the last groups.
- [ ] A budget, measured with the input-latency tools (`docs/benchmarks/input-latency`): click or key to first frame
  of the new group ≤ 2 frames for a warm group, ≤ 100 ms for a cold one.
- [ ] Tests: a per-context tab round trip across two workspaces (dirty buffers, carets, scroll kept), and a capture
  measuring the switch.

Acceptance: switching between groups in different workspaces is instant and swaps the tabs; switching back restores
them exactly.

## Phase 8: many windows and instances in parallel

- [ ] Each window registers with suit (it already does) with its focused workspace and group, so the tree can show
  "open in another window".
- [ ] "Open in New Window" on a workspace or group starts another editor instance focused there.
- [ ] **Tabs belong to the window.** Two windows on the same group each keep their own tabs, and both see the same
  sessions live. Input to a session from one window shows in the other.
- [ ] **Restore: the last write wins, per group.**
  - A window saves a group's tab snapshot when it switches away from that group, when it closes, and periodically,
    so a crash loses little.
  - Snapshots are stored one file per `machine/workspace/group`, written atomically. Two windows therefore never
    overwrite each other's other groups, and the most recent writer of a group wins for that group.
  - On restart exosuit opens one window, the last one closed: its focus, and its tabs for that group. Every other
    group restores from its most recent snapshot, whichever window wrote it. Other windows are not reopened
    automatically; Open in New Window brings back any workspace or group.
  - This replaces the single `session.conf` tab section for contexts. The window-level chrome (window size and the
    last focused context) stays in one small file written by the window that closes last.
- [ ] The same file open in two windows: the existing file-safety rules (external change detection and save
  conflicts) apply. Add a test.
- [ ] suit's orphan rules and Quit already handle several editors. Check that per-workspace services stay up while
  any window uses them.
- [ ] Tests: two editor processes, different workspaces. Each sees the other's new group and session. Closing one
  leaves the other's services running.

Acceptance:
- Two windows work in parallel on different workspaces. Each sees all of the machine's state live, and neither
  disturbs the other's focus or tabs.
- Two windows on the same group change their tabs differently and then close in order A, B. After a restart, the
  window shows B's tabs for that group, and A's tabs for any group only A touched.
- Killing a window mid-session loses at most the last periodic save.

## Phase 9: remote clients by workspace (ADR 0005 steps 6 and 7)

- [ ] suit holds the machine's relay identity, devices and per-workspace grants, and routes a device's stream to a
  workspace service by id.
- [ ] Web and Android show machine, workspaces, groups and sessions with the Phase 0 protocol; one device pairs with
  many machines.

## Order and size

| Phase | Depends on | Size | Ships on its own |
|---|---|---|---|
| 0 protocol | | S | no (contract) |
| 1 suit folderless | 0 | S | yes |
| 2 session directory | 1 | M | yes |
| 3 one tree | 1 | M | yes |
| 4 service by workspace | 0, 2 | L | flagged, then yes |
| 5 several roots | 4 | M | yes |
| 6 whole machine in every window | 3, 4 | M | yes |
| 7 instant switching | 3, 6 | M | yes |
| 8 many windows | 6, 7 | M | yes |
| 9 remote | 0, 4 | L | yes |

Phases 1–3 can go in parallel after 0. Phase 4 is the critical path, and it starts as soon as 2 lands.

## Risks

- **Migration** moves the state that live sessions depend on. Mitigations: backups, refuse on anything unknown, a
  flag, rehearsal on a copy of this machine's state, and a restore command.
- **Connection fan-out**, with every window connected to every service. Mitigations: catalog-only connections,
  measured limits, and idle services shown from suit's list without connecting.
- **Switch latency** depends on views staying attached. Mitigations: a warm-group cap and a measured budget.
- **The mobile app** is paused until Phase 0 is agreed. When it resumes, nothing before Phase 9 changes what it
  relies on.
- **Platform API migration** (haxeon `56c690f4`) is pending. Doing it before Phase 4 avoids changing these files
  twice.
