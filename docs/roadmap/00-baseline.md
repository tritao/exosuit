# M0 — Establish a trustworthy baseline

Prerequisites: execution contract and compiler policy read. No task below has
been executed merely by creating this plan.

## M0.1 — Record the starting state

- [x] Inspect applicable instructions, branch/HEAD, status and existing diffs in
  editor and compiler; record renderer revision and toolchain availability.
- [x] Run existing editor tests and graphical build sequentially. Record each
  failure as pre-existing, environmental or introduced only with evidence.
- [x] Inspect command-view/search changes and update the README feature summary
  once verified; do not discard or recommit another author's work wholesale.

Acceptance: STATUS contains reproducible commands/results and a concrete list
of unfinished behaviors. Relevant files: `scripts/`, `src/app/*TestMain.hx`.

## M0.2 — Finish the current search slice

- [x] Exercise file picker, command picker, document find, next/previous, case
  and whole-word toggles, replacement and workspace result activation.
- [x] Bind searches to document identity and revision; refresh or invalidate
  results after edits, undo/redo, document switches and closure.
- [x] Make replacement one intentional undo transaction; validate ranges before
  replacing, and handle empty queries and no-match navigation consistently.
- [x] Check command-view cancel/accept restores focus and clears transient
  highlights appropriately. Ensure search results can return to project view.

Acceptance: tests reproduce edit-after-find, switch-document-after-find,
replace-all/undo, cancelled prompt and opening a result in another project.
Files: `src/core/Application.hx`, `src/commandview/`, `src/search/`,
`src/view/SearchSidebar.hx`, `src/app/WorkspaceTestMain.hx`.

## M0.3 — Capture the behavioral smoke route

- [x] Document and perform: open project, open file, edit, select, undo/redo,
  save, split, switch tabs, find/replace, search project and reload example plugin.
- [x] Record current known unsafe quit/save behavior without testing on valuable
  files. Use disposable fixtures for all failure scenarios.

Exit: headless baseline and graphical build known; current changes assessed;
manual results or display limitation recorded; no unsupported claims of parity.
