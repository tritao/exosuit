# M18 — Workspaces, contexts and layout modes

Depends on M9 (sidebar modes), M14 (Workbench groups) and M17 (linked worktrees).
Read [EXECUTION.md](EXECUTION.md) and [COMPILER-TYPING.md](COMPILER-TYPING.md)
first. Record progress and evidence in [STATUS.md](STATUS.md).

Goal: one shell that works as a VS Code-like editor and as an agent-first
workbench, without two UIs. The agent-first view is the default when a
Workbench service is connected.

## Vocabulary (use these words in code, UI and docs)

- **Workspace**: a saved set of folders (VS Code semantics). Today this is
  `Workspace.projects` in `src/workspace/Workspace.hx`, with no saved identity.
  Do not call the daemon or the group container a "workspace" in new UI text.
- **Group**: a Workbench unit of agent work (M14). It has a directory, which
  may be a git worktree, plus agents and terminals.
- **Context**: what the window is focused on. Either the workspace's roots
  or one group. It is not the same as tree selection, which stays per client.
- **Mode**: a layout preset and default-sidebar choice (Agents or Editor).
  A mode changes layout and defaults only, never behavior.

## Rules

- Context scoping is orthogonal to mode. Both modes can focus either kind of
  context.
- Selecting a group in the tree never changes the context. Only an explicit
  "Focus Group" action (or double-click) does. This preserves the M14 rule.
- Every new region and command must declare its capability (M15.1) so the
  web build stays green. Without a Workbench service, the app behaves as
  Editor mode on the workspace roots.
- Keep each stage shippable alone. Do not start a stage until the previous
  one has evidence in STATUS.

## M18.1 — Saved workspace

- [ ] Add a saved workspace record: id, name, ordered roots. Persist it in
  the existing session/config storage. Keep roots as paths, not copies.
- [ ] Add commands: Open Workspace, Add Folder to Workspace, Remove Folder,
  Save Workspace As, and a recents list (last 10).
- [ ] Add a welcome screen when no workspace is open, listing recents.
- [ ] Use the workspace name in the title bar (`workspaceTitle` in
  `graphical/src/ui/ExosuitApp.hx`).

Acceptance: round-trip with 1 and 3 roots; a missing root is shown as
unavailable and does not abort startup; two windows opening the same
workspace do not corrupt the record.

## M18.2 — ActiveContext

- [ ] Add `ActiveContext` (new file under `graphical/src/ui/` or `src/`): kind
  (`Workspace` | `Group`), id, label, `roots:Array<String>`, `cwd:String`. One
  instance per window, with a change event.
- [ ] Route these through it instead of `application.workspace.projects[0]` or
  `activeProject`: Files tree (`explorerRoot` in `ExosuitApp.hx`), Search,
  Source Control, Problems (`ProblemsPanel` root list), Build output, and the
  cwd for new terminals/agents (`newTerminalTab`, `newGroupedTerminal`).
- [ ] The Files header shows the scope and a dropdown: Context, Workspace,
  (later) All.
- [ ] Default context is `Workspace`. No visible behavior change in this stage.

Acceptance: with context = Workspace, existing tests and screenshots are
unchanged. A test context with a single root different from the workspace
makes all of the surfaces above follow it.

## M18.3 — Layout controls and right panel

- [ ] Add four icon buttons at the right of the title bar toolbar (see the
  toolbar builder in `ExosuitApp.hx` and `WindowTitleBar`): toggle left
  sidebar, toggle bottom panel, toggle right panel, layout menu.
- [ ] Register a new dock panel `context-panel` (right side) in `makeDock()`.
  It hosts Files and Changes scoped to the active context. Make it a real dock
  region, not an overlay, so it resizes and persists.
- [ ] Left toggle reuses `toggleSidebar`; bottom toggle reuses `toggleTerminal`
  and also covers Problems/Build. Remove the standalone "Terminal" toolbar
  button.
- [ ] Add commands and keybindings for all four, and show shortcuts in the
  tooltips (use `TabTooltip`/`TooltipOverlayHost`, which are in progress).
- [ ] Phone width (`ExosuitApp.hx`, the phone layout code): hide the buttons,
  and keep the existing single-pane behavior.

Acceptance: each toggle round-trips and persists across restart; resizing the
right panel is remembered; screenshot tests at desktop and phone widths.

## M18.4 — Per-context layout and tabs

- [ ] Key the session snapshot by context id. `UiWorkbenchHost.sessionLines()`
  currently writes one `D dock` line, one sidebar line and the tab lines. Add
  a context id header, and store one snapshot per context.
- [ ] On context switch: save the current context's snapshot, then restore the
  target's, or build a default if none exists. Dirty buffers stay open and are
  never lost: documents belong to the app, and only tab visibility is per
  context.
- [ ] Panel visibility (left, bottom, right) is part of the per-context snapshot.

Acceptance: open tabs in A, switch to B, open different tabs, switch back and
A is restored exactly, including dirty state, carets and scroll. A corrupt or
missing snapshot falls back to defaults.

## M18.5 — Modes

- [ ] Define a `LayoutMode` as data: id, label, sidebar order, default selected
  sidebar destination, and default visibility for left/bottom/right regions.
  Presets:
  - **Agents**: Workbench first, then Files/Search/SCM; right panel open;
    bottom closed.
  - **Editor**: Files first, then Search/SCM/Workbench; right closed; bottom
    on demand.
- [ ] Store the current mode per window. Default to Agents when a Workbench
  service is connected and groups exist, otherwise Editor. Add a setting to
  override.
- [ ] Switching mode applies the preset only to regions the user has not
  manually changed in that context. Track a per-region "user changed" flag.
- [ ] Add the two modes to the layout-menu button and as commands. Do not add
  a title bar button for modes.

Acceptance: switching modes twice returns to the same layout; a manually
resized region is unchanged by a mode switch; both modes keep Workbench and
Files reachable.

## M18.6 — Group focus and agent-first home

- [ ] Add a group rail (left, Agents mode) showing the group tree with
  attention badges, reusing `WorkbenchPanel` and `WorkbenchTreeModel`.
- [ ] Add "Focus Group" (context = the group, roots = its directory). Add a
  quick-switch palette entry listing groups and workspaces.
- [ ] Add a landing view with one card per group: name, directory, agent state,
  attention count. Show it when no tabs are open in the context.
- [ ] The Files view does not follow the active agent tab. Show a subtle hint
  when the active file is outside the context.

Acceptance: focusing a group scopes Files/Search/SCM/Problems/terminal to its
directory and swaps in its tab set; two clients focusing different groups do
not affect each other; attention badges update from service events.

## M18.7 — Worktree groups

- [ ] Decide the authorization rule first (see open decision 1), and update
  the "single authorized project root" statement in
  [14-workbench.md](14-workbench.md) and
  [WORKSPACE-PROTOCOL.md](WORKSPACE-PROTOCOL.md) to match.
- [ ] "New Task": create a git worktree on a new branch, create a group
  pointing at it, and start an agent there, in one action. Report each failing
  step visibly and do not leave half-created state.
- [ ] "Finish Task": show the diff via M17, offer merge or PR, then remove the
  worktree after confirmation. Never remove a worktree with uncommitted
  changes without an explicit second confirmation.
- [ ] Show the branch name and worktree marker on the group row.

Acceptance: create, work in, finish and delete a task on a real repository;
failure at each step leaves a consistent state; the main checkout's indexer
does not list worktree contents twice.

## Open decisions (defaults in bold)

1. Where worktrees live and how they are authorized: **authorize multiple
   roots** (matches `Workspace.projects`), versus keeping them under
   `<root>/.exosuit/worktrees/` with the indexer ignoring that folder.
2. Does Files follow the active agent tab: **no, explicit context change only**.
3. Right panel as dock region versus overlay: **dock region**.
4. Default mode when connected with no groups yet: **Editor**.

## Risks

- `ExosuitApp.hx` is large and registers sidebars ad hoc. Land M18.2 before
  adding more features to it, and keep new code in separate files.
- Per-context snapshots (M18.4) touch session restore, which is
  safety-critical. Reuse the M4.3 defensive-restore behavior and its tests.
- Do not add more modes until the first two clearly fail someone.
