# Handoff: terminal Backspace fix

## Goal

In the editor's terminals, plain Backspace deleted a whole word, as if Ctrl+Backspace had been pressed.

## Done

The fix is complete, reviewed and pushed. Nothing is in flight.

- **Cause.** The libtsm emulator never had backspace-sends-delete turned on. Once a program turns on kitty keyboard mode
  (Claude Code does), keys are encoded by libtsm, and plain Backspace wrote BS (0x08). 0x08 is the byte Ctrl+Backspace
  sends, and ConPTY and readline treat it as a word delete.
- **Fix:** `native-packages/terminal/vendor/pragtical/terminal_emulator_libtsm.c` calls
  `tsm_vte_set_backspace_sends_delete(vte, true)`. Report-all-keys mode still sends `CSI 127;1 u`.
- **Test:** `tests/terminal-keys` checks plain Backspace in three keyboard modes: legacy, kitty disambiguate, and kitty
  report-all-keys. It passes with the fix and fails without it (disambiguate mode sends BS).
- **Commits:** pushed to origin/main as cfe41dbb on 2026-11-16, and contained in the current `main`. The earlier
  `daily` copies, ef2a0a99 and 728110ec, are superseded by that clean slate.
- **Branches and worktrees:** none left. The temporary branch `backspace-del` in the `exosuit-wt/entropy-s0` worktree
  was deleted.
- **Uncommitted files:** none from this session.

## Next steps

None needed. The fix is native code, so a running editor picks it up only after the terminal library is rebuilt, which
happens when the editor is restarted.

## State outside the repo

None.
