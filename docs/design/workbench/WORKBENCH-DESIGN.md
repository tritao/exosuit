# Workbench: one tree, every workspace live, no waits

Status: built (entropy pass, 2026-11-15 and 16). The owner decided every question raised ([QUESTIONS.md](QUESTIONS.md),
rounds 1 and 2). This is the design; how the parts fit together now is in [ARCHITECTURE.md](../../ARCHITECTURE.md).
§4 checks it against the [suitctl design](../suitctl/TDD-exosuit-ctl.md).

## Decisions (owner, rounds 1 and 2)

| Q | Decision | Consequence in this design |
|---|---|---|
| Q1 | (a) A click opens the workspace; the chevron only expands. In the owner's words: "click should be milliseconds", and "right clicking on something, even if it's not open at the time, should let me interact with it" | Every row (workspace, group, session, terminal; open, running or idle) gets its full action menu. A click draws from the catalog snapshot at once and connects behind it (§1, §2.4) |
| Q2 | (a) A session made from another workspace's row opens as a tab in that workspace, and the window goes there | One rule: tabs belong to the focused workspace. A create on row X = open X + create in X |
| Q3 | (a) Expanding an idle workspace shows its on-disk catalog snapshot and starts nothing | The service writes a catalog snapshot (§2.4); a start happens on create, on opening an item, or on open |
| Q4 | (a) One process per workspace, the launcher, manager and daemon chain collapsed to one process, plus a warm spare | §2.3 |
| Q5 | (a) A workspace stops after 10 minutes with no window showing or using it and no active session | Links, not passive watches, keep services up (§2.4) |
| Q6 | (a) Remove suit-off and folder-only modes | suit is always on; opening a folder opens the workspace that holds it; Q10 covers a folder no workspace holds |
| Q7 | (a) New Agent Session creates at once with the default provider; a submenu offers the other providers and Change Folder… | The default provider is set by Q8 |
| Q8 | (a) A "Default agent provider" setting, initially Claude ("claude for now") | `defaultAgentProvider` next to `agentSessionMode` in `src/config/Settings.hx`, default `claude`. New Agent Session's first entry uses it; the submenu lists the others |
| Q9 | (a) The warm spare exists only while at least one editor window is open | suit starts the spare while an editor window is linked and ends it when the last one goes. A start that finds no spare ready is a cold start (§2.3) |
| Q10 | (a) A folder that no workspace holds becomes a new workspace named after the folder, with the folder attached, and opens | No folder-only windows. It matches the suitctl design's `project.change` ("creating one if none does") |
| Q11 | (b) A session that fails to start keeps its tab and the typed text, shows the cause and a Retry, and never sends the text by itself | On a normal start, queued input is delivered when the session goes live. Only after a failure is the text held as an unsent draft for the user to send again (§1) |

Owner's requirements, as given:

1. Add a workspace, then open a session in it at once.
2. Selecting a workspace is Open.
3. Every workspace row can create sessions, terminals and groups.
4. No waits on a local machine. An idle workspace's start counts as a wait too: it should take milliseconds on cube.
5. Resource-light; lowest entropy.

---

## 1. Behaviour

1. **A click on a workspace row opens it, in milliseconds** (Q1). The window's context becomes that workspace's root.
   In the same frame the tabs swap (per-context layouts), the tree shows the workspace's rows from its link if it has
   one, else from its catalog snapshot (§2.4), and Files, Search and Changes re-point to it. The connection is made
   behind that, and it starts the service if it is idle. Nothing in the click waits on IO. The chevron alone expands
   or collapses. There is no Open item, and there is no "attached" state for the user to manage.
2. **Every row, open or not, running or idle, has its full action menu** (Q1):
   - **Workspace rows:** New Agent Session ▸ (the default provider at the top; the other providers and Change Folder…
     in a submenu, Q7), New Terminal, New Group, Rename, Attach/Detach Folder, Open in New Window, Remove,
     New Workspace.
   - **Group rows:** their group actions.
   - **Session and terminal rows:** their item actions (rename, move, close, remove).

   Nothing is read-only because of which window you are in, or because the service is idle. The row actions live in
   one place, `WorkbenchActions`.
3. **An action on a row of workspace X opens X and acts there** (Q2). A create opens its tab in X at once, and the tab
   accepts input; input is queued until the session is live. An idle X starts.
4. **A new workspace is usable at once.** New Workspace… asks the name, creates the workspace, opens it and starts its
   service (from the warm spare, Q4).
5. **Expanding an idle workspace shows its last-known rows and starts nothing** (Q3).
6. **Nothing says "connecting", "reconnecting", "starting…" or "wait and try again" in normal use** on the local
   machine. Those states appear only for a real failure, shown as an error with its cause. If a session fails to start
   (Q11), its tab stays with the text typed so far, now an unsent draft, and shows the cause with Retry. Nothing is sent
   until the user sends it again.
7. **Empty states.** A workspace with nothing in it shows an empty child row instead of expanding to nothing.
8. **A workspace stops after 10 minutes in which no window shows or uses it and none of its sessions is active**
   (Q5). Reopening it is as fast as opening an idle workspace.

Targets, measured with the editor's connect timeline (`ConnectTimeline`) and the input-latency tools:

| Case | Target |
|---|---|
| Click a running workspace → its rows and tabs drawn | ≤ 2 frames (≤ 33 ms) |
| New Terminal on a running workspace → prompt visible, typing echoes | ≤ 100 ms (dominated by shell start) |
| New Agent Session on a running workspace → composer accepts input | ≤ 100 ms (the CLI's own start is shown as the session's state, not a blocking wait) |
| New Terminal / Session on an **idle** workspace → typing accepted | ≤ 200 ms on cube; owner asked for "milliseconds" |
| New Workspace → typing in its first session | ≤ 200 ms after the name is entered |
| Idle workspace cost | no process, no connection, no poll; memory ≤ one mirror |
| Steady state, nothing changing | zero RPCs per second per window (push only) |

---

## 2. Architecture

### 2.1 One concept: a link per workspace, and a focus

```
WorkspaceLinks (per window)
  link(workspaceId) -> WorkspaceLink   // made on demand, full capabilities, push-driven
  WorkspaceLink: one connection to the workspace's service; its catalog watch (groups, sessions, terminals);
                 the typed clients for agents, terminals, files and source control
ActiveContext: the machine/workspace/group the window shows; Files, Search, Changes and the title follow it
```

- **There is no "attached" workspace.** What remains is the **focus**, the active context (`machine/workspace/group`).
  It decides which workspace's files, search and source control the side panels show, and which tab set is on screen.
  It does not decide which workspaces the window can talk to. Moving the focus is a pointer flip with no IO.
- **When links exist:** the focused workspace, any workspace with terminals open in this window, and any running
  workspace whose row is expanded. A link that matches none of these closes after `WorkspaceLinks.LINGER_MS` (30 s).
  Idle workspaces have no link. Closing a link never stops the service.
- **The tree reads every workspace the same way** (`WorkbenchRows`): from its link's lists once read, else from its
  catalog snapshot. One projection keyed by workspace and item (`WorkbenchRowKey`); orphans go to the root, with a
  cycle guard.
- **Every action takes a workspace id**, as the suitctl design's methods do: no method assumes that a window has
  exactly one workspace. suitctl's `workspaces: [{id, roots[], active}]` is the link map plus the focus.

### 2.2 Push, not poll

- One catalog watch per link (CATALOG with `watch`, then CHANGED). Agent and terminal lists are read again when a
  CHANGED push arrives, never on a timer.
- Mutations are idempotent by operation id with an expected revision.
- suit pushes machine changes on the window's suit link (`exosuit.machine.changed`): the workspace list, services
  up and down, every window's focus. suit knows a service is up because it started it and the service reported; it
  knows it stopped because that connection closed.

### 2.3 Starting in milliseconds

The options weighed:

| Option | What | Start latency | Resource | Risk / cost |
|---|---|---|---|---|
| **O1 Collapse the chain** | One process: suit spawns the service directly. The service takes the lock, listens and reports over its suit link; no file polling | 1 VM start + service init | no change | The chain's arbitration of concurrent starts moves into suit (one start per workspace) |
| **O2 Warm spare** (on top of O1) | suit keeps one pre-started service with no workspace. Opening an idle workspace hands it to the spare (`adopt`): lock, SQLite, listen | adopt only | +1 idle process | Service start split into a process half and a workspace half; crash isolation per workspace is kept |
| O3 One resident host for all workspaces | One process serves every running workspace | ~ms | lowest | One crash or update takes down every workspace |
| O4 Never stop | Services started once stay up | 0 after first | one process per workspace ever started | The opposite of "idle costs nothing" |

**Decided (Q4 = a): O1, then O2.** O3 and O4 are dropped. As built (`SuitServices`, `AgentMain`):

- suit owns the spare. It is a process kind in suit's inventory, so Quit ends it.
- On an open of idle X, suit hands X to the spare if one is linked and of the current build, else starts X cold. A
  second open while a start is under way waits for that start.
- After a hand-over suit starts the next spare. The spare exists only while an editor window is linked (Q9).
- The service listens and reports before its catalog, terminals and agents are up; connections wait in the pipe.
  Agent providers are built on first use; the terminal host runtime copy is made by the first host spawn.
- Readiness is the report over suit's link, not a file. The window connects to the pipe suit names and checks the
  service's IDENTITY against what suit reported.
- A link's catalog watch resumes from its last token across reconnects; the service answers with a reset only when it
  no longer knows the token.

### 2.4 Idle workspaces cost nothing and still show their contents

**Decided (Q3 = a): the snapshot is shown and nothing is started.** The service keeps `catalog-snapshot.bin` in its
state folder (`CatalogSnapshotFile`): the whole catalog, written once changes settle (checked every second, at most
5 s after the first change of a stream that does not stop) and on exit. The editor reads it (`CatalogSnapshots`,
looked at no more than every 2 s) to draw an idle workspace's rows and to give its row menus their groups. Keeping it
in a file rather than in suit's `machine.json` keeps suit out of the read path. A missing or unreadable file shows the
row as empty, never as an error.

A service starts on a create, on opening one of its items, or on opening the workspace. The rows are already on screen
while it starts.

Service lifetime (Q5 = a, 10 minutes): links keep a service up, and links exist only while a workspace is focused, has
open terminals in a window, or is expanded. The service stops after 600 s with no client and no busy agent turn
(`WorkspaceLifetime`, `EXOSUIT_SERVICE_IDLE_SECONDS`). With the 30 s linger the 10 minutes count from when no window
shows or uses the workspace. Idle chat processes lengthen the wait, at most to 600 s. Running terminals do not keep it:
their hosts outlive it.

### 2.5 What stays

- Per-context tab layouts and warm contexts, the context key `machine/workspace/group`.
- The service's catalog protocol (CATALOG, UNWATCH, CHANGED; paged, grant-filtered), idempotent mutations, terminal
  host adoption across service generations.
- suit as the machine's owner of the workspace list and of service starts.
- The capability model, checked per connection. Remote devices get grant-filtered catalogs.

---

## 3. Devices

The phone and the browser hold the same `WorkspaceLinks` over relay streams (`DeviceMachine.openService`, `OPEN` on
the machine stream); suit forwards each stream to the service's pipe. Their tree comes from suit's machine directory,
filtered to the workspaces the device was granted.

## 4. Consistency with the suitctl design (§6.1)

| suitctl §6.1 says | This design | Agreement |
|---|---|---|
| suit is always on; suit-off mode is gone; tests isolate through `EXOSUIT_SUIT_HOME` | Q6 | Agrees |
| Folder-only mode removed. `project.change {path}` opens the workspace holding the folder, creating one if none does. `project.add {path}` adds the folder to the active workspace | Q10; Attach Folder… on the row | Agrees. `project.add` is the control plane's twin of Attach Folder… |
| One service process per running workspace, plus one warm spare held by suit | O1 + O2 | Agrees |
| Spare only while an editor window is open | Q9 | Agrees |
| Editor windows are the only control-plane instances; services and the spare never link as instances or routing targets | Services and the spare are suit inventory kinds; links are editor → service | Agrees |
| `terminal.create {workspace}` on an idle workspace starts its service and answers after the terminal exists, under the 10 s timeout | The UI opens the tab at once and queues input; the control plane waits for the terminal | No conflict: both use the same start path |
| `exosuit.workspace.open` / `context.switch` answer once the window shows the workspace from its catalog snapshot | A click draws from `catalog-snapshot.bin`; the link says when the service is live | Agrees. "Catalog snapshot" is the word for the file in both, never bare "snapshot" (which is `ui.snapshot`) |
| §6: methods on workspace content take an explicit `workspace` id; `workspaces: [{id, roots[], active}]` | Every action takes a workspace id; the link map plus the focus give that list | Agrees |
