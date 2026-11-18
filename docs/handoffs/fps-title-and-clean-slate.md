# Handoff: title-bar FPS and dev-env clean slate (session b08b5a50)

## Goal
1. Live-patch a real-time FPS counter into the running editor's title bar.
2. Push the daily work, then reduce the machine to one clean exosuit checkout on the latest main.

## Done
- FPS counter: `graphical/src/ui/FrameRateMeter.hx` (new), plus hooks in `ui/ExosuitApp.hx` (`pollBackground` samples,
  toolbar title appends "· N fps") and `app/GraphicalMain.hx` (`captureReady` counts frames). Verified by screenshots
  over time (idle ~1 fps, active 131–145 fps) and live in the user's editor.
- Pushed to origin/main: `c24cff62` (New Chat With…) and `2bf957d9` (title-bar FPS).
- Clean slate (2026-11-17): `C:\Users\corbi\projects\exosuit` is the only exosuit checkout, on `main`, one worktree, one
  branch, no stash. Submodules detached at their pins. Deleted ~352 GB: `projects/exosuit-wt` (incl. wt-run.ps1,
  switch-daily*.ps1, Android SDK/APKs), `daily-wt`, `haxeon-wt`, `haxeon-merge-wt`, `.claude/worktrees`, the `daily`
  branch, 199 exosuit and 109 haxeon local branches.
- Since then another session committed `6ee0435b` (suit → exohost) on main; not mine.

## In flight
Nothing. No uncommitted work of mine, no branches, no worktrees, no background processes.
Untracked in the checkout and NOT mine: `docs/one-command-gaps.md`, `suit/`.

## Next steps (only if the user asks)
- Purge deleted commits: `git reflog expire --expire=now --all && git gc --prune=now` in exosuit and haxeon
  (until then they are recoverable for 30–90 days).
- Delete the empty, locked folder `.claude/worktrees/agent-a11e4b4a7974a4a85` once its holding process exits.
- Remote feature branches on GitHub were left alone; deleting them is the user's call.
- New isolated work needs a fresh env-isolation wrapper, since wt-run.ps1 is gone.

## State outside the repo
- Kept on purpose: `projects/pragtical`, `%LOCALAPPDATA%\Exosuit`, the `Exosuit-before-entropy-20261116-1517` backup,
  `exosuit/.local/android` (AVD, git-ignored).
- Scratch scripts/screenshots (disposable): `C:\Users\corbi\AppData\Local\Temp\claude\9921e6a8f2f5815e\b08b5a50-a5ca-422c-ae9b-e8133be222b6\scratchpad`
- Memory: `clean-slate-1117.md`, `push-1116b.md`.
