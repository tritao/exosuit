# M19: Machine workspaces, one tree, instant groups, many windows

Implements [ADR 0005](../architecture/0005-machines-and-workspaces.md) and
[ADR 0006](../architecture/0006-workspaces-without-folders.md). Depends on M14 (Workbench groups), M18 (contexts and
per-context layouts) and suit. Read [EXECUTION.md](EXECUTION.md) first, and record evidence in
[STATUS.md](STATUS.md).

Status (2026-11-01): Phases 1–7 are on `main` (exosuit `757db3f1`, haxeon `fd2a332c`). Phase 0 waits on the
mobile-app review; Phase 7's budget is met for warm and cold switches inside a workspace (cross-workspace is not measured); Phases 8 and 9 are not started. Ten real-input
GUI scenarios (`docs/benchmarks/perf-harness/gui_scenarios/m19_*.py`, run through `measure.ps1 -Drive`) cover
Phases 3–7 on Windows. Open problems found after landing are in NEXT-PHASE.md under "M19 after landing".

## Goal

- A machine (suit) serves any number of workspaces. A workspace is a name with zero or more attached folders.
- Each workspace has one service, which holds its sessions, terminals and groups. Sessions and terminals belong to
  the workspace itself or to a group; a group is an optional collection of them, with an optional folder.
- The Workbench is one tree: workspaces, then groups and sub-groups, then sessions and terminals. A dropdown above it
  chooses the machine.
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
| Group | id, name, parent, order, optional folder; optional, sorts sessions and terminals (those in no group belong to the workspace itself, its root) | the workspace service |
| Session | an agent chat or terminal; always has a working directory | the workspace service |
| Window | one editor instance. Focus (its context) and tab sets are per window | the editor |
| Context | the window's focus: one workspace, and a group or the workspace root | the editor (M18 `ActiveContext`) |

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

- [x] Write the wire types in `src/workspace/service/` with frozen vectors in `tests/haxeon-rpc`
  (`WorkspaceCatalogProtocol.hx`, `RpcCompatibilityTests.catalogVectors`, `SuitUnitTests.machineReply`):
  - `WorkspaceRef {machine, workspace}` names a workspace in every request. A folder becomes an attribute.
  - `CatalogWatch`: a subscription to one service's lightweight catalog (groups, sessions, terminals, status and
    attention counts; no content), with resume tokens. `watch` on terminal open already exists, so reuse its
    connection-scoped change notifications.
  - Sessions and terminals carry `directory` (the resolved working directory) on create and in the catalog.
  - suit's `machine` reply in a v2 shape: workspaces with `folders` (possibly empty), `scratch`, `service`
    (endpoint, pid, running) and `revision`.
- [ ] Review with the mobile-app session, and record the agreed shape in `RPC-VECTORS.md`. The proposed shape, and what the
  mobile branch would change, are in `RPC-VECTORS.md` under "Workspace refs and the catalog watch".

Acceptance: vectors are frozen and both branches build against them. Nothing changes behaviour yet.

## Phase 1: suit, workspaces without folders, scratch folders

Done 2026-10-29 (`d9e44abb`).

- [x] `MachineCatalog` v2:
  - `folders` may be empty, and removing the last folder is allowed;
  - add `scratch`, created on first use at `~/Exosuit/<name>`, with a numeric suffix if the name is taken, and
    recorded so it never moves;
  - read v1 unchanged.
  (v1 files are read and rewritten as v2 on the next change; `EXOSUIT_SCRATCH_HOME` overrides `~/Exosuit` for tests.)
- [x] Ops: `workspace-create {name, folders?}` and `workspace-scratch {workspace}`, which creates and returns the
  scratch folder. CLI: `suit workspace new --name N [folder...]` and `suit workspace scratch <id> [--json]`.
- [x] `MachineClient` exposes the v2 shape (`create` takes a folder list; `scratch` reads the scratch reply).
- [x] Tests: `SuitUnitTests` cover no folders, scratch creation, suffixes and the v1 read.

Acceptance: the Workbench's New Workspace asks only for a name. A folderless workspace survives a suit restart.

## Phase 2: session working directory and the folder chooser

This works inside today's per-folder service, so it is useful before the identity change.

Done 2026-10-29 (`e2adae9a` service, `4c60737a` editor).

- [x] Resolve a session's directory in the service (`WorkspaceAgentService`, terminal open), in this order: the
  explicit directory, then the group's folder, then the nearest ancestor's, then the workspace's first folder, then
  the scratch folder (from suit). Record it on the session. (`GroupFolders` holds the walk so the editor shows the
  same answer; an asked-for folder that does not exist is refused with `invalid_directory`. The scratch folder came
  from suit through the editor until Phase 4 keyed the service by workspace.)
- [x] New Agent Session… and New Terminal… show "Folder: <resolved>" with **Change…**: "Choose folder…" (the native
  picker), "Home folder" and "Current", or a typed full path. Tabs show their session's folder in the tooltip.
- [x] Permission profiles take the resolved directory: Codex, Claude, Pi, the built-in agent and terminals start in
  it, and Pi's acceptEdits mode approves edits only inside it.
- [x] Tests: resolution order (`tests/workspace-directories`, the workspace-agents and terminals harnesses), and a
  session in a group with no folder.

Acceptance: a group with no folder starts sessions in the scratch folder; Change… starts one in the home folder; the
session shows its folder.

## Phase 3: the Workbench is one tree

The model and the UI land first, on today's services. A workspace's groups appear once its service is attached;
Phase 6 makes every workspace live.

Done 2026-10-29 (`a8ff1dc1`), except type-to-find and a PrintWindow capture of the tree (NEXT-PHASE.md, "M19 Phases
1–3 review: deferred").

- [x] `WorkbenchTreeModel` gets a top level: workspaces (from `MachineClient`), then groups and sub-groups, then
  sessions and terminals. The machine is chosen in a dropdown above the tree, not shown as a row (decided
  2026-10-30, ADR 0006 amendment); it lists this machine until remote machines are added later.
  - Workspace rows: expand and collapse, a running/idle state, and the context menu (Rename, Attach Folder…,
    Remove from This Machine, Open in New Window, from Phase 8).
  - Group rows keep today's menus.
- [x] Remove `WorkbenchMachineSection`'s separate list; the empty states move into the tree.
- [x] Expanding a workspace attaches its service, which is started by suit if needed. The tree keeps expanded
  state per window. (Phase 6 does this through catalog connections: expanding starts an idle workspace's service and
  shows its catalog; it no longer switches the window. Enter or a double click on a workspace row opens it.)
- [ ] Keyboard: arrows, Enter to focus, type-to-find. The tree's accessibility labels name the workspace and
  group. (Arrows and Enter work, and Enter or a double click opens a row through `TreeView.onActivate`; type-to-find
  is not built.)
- [ ] Tests: tree model unit tests (the `workbench-drag` and `sidebar-layout` style), and a PrintWindow capture of
  the tree. (`tests/workbench-tree` covers the projection, and real-input GUI scenarios drive the tree
  (`docs/benchmarks/perf-harness/gui_scenarios/m19_*.py`); there is no PrintWindow capture.)
- [x] The workspace is its own root group (decided 2026-10-30, ADR 0006 amendment). Sessions and terminals in no
  group (`WorkspaceProtocol.ROOT_GROUP`, the empty id) sit under the workspace row after its groups. New Agent
  Session… and New Terminal… on the open workspace's row create there, and so do the header's New terminal and New
  Codex unless a group or an item in one is selected. Dragging an item onto that row, or choosing Workspace in Move to
  Group… (terminals and sessions), moves it there; dragging a sub-group onto it makes it top level. Selecting a root
  item scopes the right panel to the workspace.

Acceptance: the Workbench shows one tree; a workspace's groups and sessions are nested under it; nothing is drawn
as a separate list.

## Phase 4: one service per workspace (identity by workspace id) and migration

This is the riskiest phase. It shipped behind a flag until the migration was rehearsed on a copy of real state
(`scripts/rehearse-workspace-migration.py`, 2026-10-31), and is now the default; `EXOSUIT_WORKSPACE_IDENTITY=folder`
goes back to a service per folder.

- [x] `AgentManager`:
  - `--manager --workspace <id> [--folder F]...`;
  - the state folder is `workspaces/<workspace id>/`;
  - the pipe is `exosuit-<hash of workspace id and state>`;
  - the lock and generation are per workspace.
  - Today these come from a hash of the folder: `AgentManager.hx:557` and `:904-907`.
- [x] Re-key everything else the folder keyed:
  - the suit record (`workspace`, `folders`);
  - `WorkspaceStopRequest`;
  - `SuitKinds.orphanRule` (used while an editor has the workspace open, or suit hosts it);
  - the Machine view (`AgentMachine`, `machine.services`);
  - `AgentImageStaging`;
  - relay identity and settings;
  - the content stores.
- [x] Migration, run once per old state folder, with this procedure:
  1. lock the folder;
  2. back it up (`<state>.bak-<time>`);
  3. move it into the workspace's state;
  4. verify the catalog opens and every group and session id is present;
  5. write a marker.

  Anything it doesn't recognise makes it refuse, and the old state is left in place. A workspace with several old
  folder states merges them, with each folder's groups under a top-level group named after the folder.
- [x] Tests:
  - migration fixtures made from copies of real states (single folder, two folders, a corrupt catalog);
  - restart idempotence;
  - an old editor build attaching to a migrated workspace is refused with a clear message.

Acceptance: on a copy of this machine's state, every existing group, session and terminal history appears under the
right workspace after migration. A second run changes nothing. The backups restore cleanly.

## Phase 5: several roots in one service; the right panel shows everything

- [x] File search, file watching and the file service run per attached folder. Replies carry the root, and the UI
  labels them.
- [x] Source control discovers repositories under every root and every group or session folder (it extends
  `ScmFolderScope` and session SCM sources).
- [x] The right panel shows a selected group's folder even when it is outside every attached folder.
- [x] Attach and detach a folder without restarting the service; watchers start and stop with the folder.
- [x] Tests: `workspace-files`, `workspace-scm` and `scm-watch` with two roots plus an outside group folder.

Detaching a folder: `root` means the first surviving attached folder, so its folder can change when the first one is
detached (the next folder takes the id; other ids never change). Watchers of a detached or promoted root get one last
change event, and editor tabs follow their folder by path: a tab whose folder is now `root` is re-keyed, one whose
folder left is closed. A search queued over several roots skips one that goes away (error code `unknown_root`) and
shows any other error. The folder list is applied leniently: nested, missing and relative folders are skipped and
reported, the rest are served.

Known gaps:

- Reordering the folders does not change which one is `root`; only a detach does.
- The nesting check compares paths as spelled; symlinks and junctions are not resolved.
- A folder attached while a search runs is missed by that search.
- There is no explicit "root removed" message; a watcher learns by the final change event and its next listing.

Acceptance: with two folders attached and a group folder elsewhere, Files, Search and Changes show all three,
labelled, and narrow when a sub-group is selected.

## Phase 6: every window sees the whole machine

Done 2026-10-31: the client side (`41456449`, `9e7d4b56`), and the service side (`6a0aa70d`, `186709fd`, `2f52ed26`):
the workspace service answers CATALOG and UNWATCH with a resumable, paged catalog filtered by the connection's read
grants, and suit's `machine` reply fills `service` (`c8b07c93`).

The catalog watch is local-only for now: only local connections are offered `workspace.catalog`. Remote peers (devices
through the relay) get it with the mobile adaptation; the service already filters a connection's catalog by its grants.

- [x] Every window holds a `CatalogWatch` connection to every running workspace service. suit's `machine` reply
  says which are running. (`WorkspaceCatalogWatch`; the window's own attached workspace keeps its full client and
  gets no second connection, and a window holds at most `WorkspaceConnections.LIMIT` (64).)
- [x] Workspaces that aren't running show as idle from suit's list. Expanding one starts it. (`WorkspaceStarter`
  runs `--manager --workspace ID ... --detach`; the row says idle, starting, running or reconnecting, and how many
  items need attention. Expanding a running workspace only expands it.)
- [x] A catalog connection carries no session content. Session and terminal streams attach only for open tabs, and a
  terminal not shown is not streamed. (The pool speaks only CATALOG, UNWATCH and CHANGED, and offers only the
  `workspace.catalog` capability. Tabs attach through `LocalTerminalWorkspacePool` and the attached client as before,
  so a row that is not open streams nothing. Opening an item of another workspace switches the window to it and opens
  the item once attached; Phase 7 makes that instant.)
- [x] One `WorkspaceConnections` pool per window: connect, resume, back off, and drop when suit says a service
  stopped. It reuses `NativeRpcHub` and the existing reconnect fencing. (`RpcClient` backoff; a lost connection
  resumes from its token; a changed pid or endpoint replaces the watch; a down connection makes the window ask suit
  again after 1.5 s instead of 5 s.)
- [x] Tests: two workspace services, one window. A session created by another client appears in the tree within
  one catalog event. Killing a service shows it idle; restarting it brings it back. (`tests/workspace-catalog` runs
  the pool against fake services over in-memory transports; `workbench-tree` covers the projection. A test against
  two real services follows the service side.)

Acceptance: every workspace's groups, sessions and terminals are in the tree and update live. Memory and connection
counts stay bounded with ten workspaces; measure and record them.

Measured (`tests/workspace-catalog`, ten fake services of 6 groups, 30 sessions and 12 terminals each, in one HashLink
process, in-memory transports): the window holds 10 connections (one per workspace; 0 after dispose) and mirrors 480
catalog items. The heap grows 38 KiB per watched workspace (384 KiB for ten), counting both ends of each connection
because the fakes share the process, so the editor's share is smaller. One change on one service costs one CATALOG
read on one connection; the other nine are untouched, and a CHANGED with our own token costs none. Paged catalogs
(seven items at three per page) arrive as three reads and replace the old copy only at the last page. Real pipes add
the OS handles and the service's per-connection state, which the service-side change measures.

## Phase 7: instant group switching, with tabs

M18.4 already keeps per-context layouts and switches them in memory (`UiWorkbenchHost.switchContext`), and saves
them per context.

- [x] The context key becomes `machine/workspace/group`. Switching across workspaces is the same operation as
  switching within one.
- [x] Keep each recently used group's views attached: detach on switch, don't dispose. The last N groups stay warm,
  and older ones are rebuilt from their saved snapshot.
- [x] Switching never waits on the network. Tabs whose session isn't loaded yet show their last content (snapshot)
  until the stream catches up.
- [x] Quick switch: a palette entry listing workspaces and groups, plus a key back to the last one.
- [x] A budget, measured with the input-latency tools (`docs/benchmarks/input-latency`): click or key to first frame
  of the new group ≤ 2 frames for a warm group, ≤ 100 ms for a cold one.
- [x] Tests: a per-context tab round trip across two workspaces (dirty buffers, carets, scroll kept).
- [x] A capture measuring the switch.

What landed: `ContextKey` (`src/workspace/ContextKey.hx`) builds and parses `machine/workspace/group` and migrates
the old `workspace:<id>` and `group:<id>` keys on restore. The host keeps `warmLimit` (4) inactive contexts attached;
older ones with only plain document tabs are rebuilt from their snapshot, while contexts with a terminal, agent or
diff stay attached. Remote-session tabs keep their last content because nothing in a switch waits on the network.
Quick switch is "Switch Workspace or Group..." (`context:switch`, Ctrl+Shift+A); "Goto Previous Workspace"
(`context:previous`, Ctrl+Shift+D) goes back to the last workspace or group. Ctrl+Tab and Ctrl+Shift+Tab still switch
tabs. Measured in process by `tests/context-switching` (the host times each
`switchContext`): warm about 35 us, cold (rebuilt from the snapshot) about 0.5 ms for a two-document group on
HashLink. 
Measured end to end (2026-11-01, `m19_switch_latency`, real `SendInput`, Windows, one workspace with six groups; the
driver stamps each input, the app stamps the context change and every rendered frame on the QueryPerformanceCounter
clock, `SwitchTrace` and `switch_latency.py`; summary in `docs/benchmarks/input-latency/switch-latency-2026-11-01.txt`).
Input to the first rendered frame that shows the new group, median / p90 / max:

| Switch | n | ms | frames |
|---|---|---|---|
| warm, Ctrl+Shift+D | 4 | 17.5 / 19.6 / 19.6 | 1 |
| warm, quick switch (Enter) | 4 | 16.6 / 19.1 / 19.1 | 1 |
| cold (rebuilt from its snapshot), quick switch | 6 | 20.0 / 28.6 / 28.6 | 1 |

Both limits are met (2 frames; 100 ms). The switch itself is 0.5 ms warm and 1.2 ms cold; input to the context change
is about 1 ms; the remaining 15 to 18 ms is the wait for the next frame. The end point is the end of the render, not
the display's present, which is not measured. A click on a group row was not measured: it does not switch (see
NEXT-PHASE). A switch to another workspace attaches the window to its service and is not covered.

Acceptance: switching between groups in different workspaces is instant and swaps the tabs; switching back restores
them exactly.

## Phase 8: many windows and instances in parallel

- [ ] Each window registers with suit (it already does) with its focused workspace and group, so the tree can show
  "open in another window".
- [ ] "Open in New Window" on a workspace or group starts another editor instance focused there.
- [ ] **Tabs belong to the window.** Two windows on the same group each keep their own tabs, and both see the same
  sessions live. Input to a session from one window shows in the other.
- [x] **Restore: the last write wins, per group.** (Storage and restore are built and tested headless
  (`tests/context-snapshots`); no real-input scenario restarts the editor yet.)
  - A window saves a group's tab snapshot when it switches away from that group, when it closes, and periodically,
    so a crash loses little.
  - Snapshots are stored one file per `machine/workspace/group`, written atomically. Two windows therefore never
    overwrite each other's other groups, and the most recent writer of a group wins for that group.
  - On restart exosuit opens one window, the last one closed: its focus, and its tabs for that group. Every other
    group restores from its most recent snapshot, whichever window wrote it. Other windows are not reopened
    automatically; Open in New Window brings back any workspace or group.
  - This replaces the single `session.conf` tab section for contexts. The window-level chrome (window size and the
    last focused context) stays in one small file written by the window that closes last.
  - File layout, under the editor's state folder (`PRAGTICAL_PORTABLE` or the platform state root, the same one as
    `session.conf`):
    - `contexts/<prefix>-<sha256 of key>.json`, one per context key. The name is stable and safe on every file system
      (the readable prefix keeps letters, digits and `-`; the hash keeps two keys apart, also on case-insensitive
      disks). The key itself is inside the file.
    - The file is `{"version":1,"key":..., "written":<ms>, "layout":[<the layout lines the host restores from>]}`,
      written atomically (`sys.io.AtomicFile`). A damaged or unknown file is skipped and left alone.
    - `session.conf` keeps the window chrome, the focused context's key and its layout, and the recent list. It no
      longer carries other contexts' tabs.
  - When a window writes: right after it switches context (the one it left), every 30 seconds while anything
    changed, and on close. It writes only the contexts whose content changed since it last read or wrote them, and
    deletes only files of contexts it knew and then closed, and only if the file still holds what it last read or wrote (another window's rewrite survives). So it never touches a group another window changed, and
    a window that merely restored a group never becomes its latest writer. A crash loses at most the last period.
  - After the catalog names the machine, a window re-keys its contexts and so rewrites all of them: it becomes the latest writer of each.
  - On start the focused context comes from `session.conf` (the window that closed last); every other context comes
    from its own file. Old `session.conf` files migrate on the first start: their context lines are used when the
    folder has no file for that key (or no files at all, for keys in the older `workspace:`/`group:` scheme), and
    the first save writes them out as files. The old lines stay in `session.conf` until it is next saved, so an older
    build still reads them; nothing is deleted.
  - Not built: reopening the focused context from its file when `session.conf` is missing.
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
