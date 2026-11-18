# Handoff: add-workspace-from-folder

## Goal
Owner asked (2026-11-16, from a screenshot) for an "Add Workspace from Folder" option next to New Workspace… in the
Workbench, patched into the running editor, no tests.

## Done
- Commit `df47955f` "Workbench: Add Workspace from Folder… under New Workspace…".
  - New machine row `n:folder-workspace` (`WorkbenchRowKey.FOLDER_WORKSPACE`) under New Workspace…; also in the machine
    row menu and every workspace row menu.
  - `WorkbenchActions.createFromFolder()`: folder picker → opens the workspace whose only folder is that folder, else
    `suit.create(null, [folder])` (named after the folder) and opens it.
  - `tests/workbench-tree` root/visible expectations updated for the extra row (not run).
- Was live-patched into the running editor on 11-16 (patch revision 2, state ok).
- It is now an ancestor of `main` / `origin/main` (carried by the 11-17 clean slate). The worktree
  `exosuit-wt/add-workspace-from-folder` and branch `daily` no longer exist; nothing to clean up.

## In flight
Nothing. No uncommitted files from this session.

## Next steps
- Owner to try it in the GUI (not verified on screen).
- Run `tests/workbench-tree` when convenient.
- After the suit → exohost rename (6ee0435b), confirm the code still compiles; it calls `MachineClient.create` /
  `workspaceHolding` and `workspace.PathKey.same`, no suit-named types of its own.

## State outside the repo
None.
