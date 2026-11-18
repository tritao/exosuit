# Handoff: New Chat With…

## Goal

The owner asked for a "New Chat With…" option on the Workbench row menu, plus command palette entries. It starts a
session in the first-class chat GUI (`CodexSessionPanel`), not a terminal, for any supported harness (Claude, Codex,
Pi). It was delivered as a live patch to the running editor.

## Done

- Commit `9cebe97a` on the old `daily` branch, now carried into `main` (`2bf957d9`, "New Chat With…, FPS title").
  - `WorkbenchPanel.createItems`: a "New Chat With…" item whose submenu lists every provider (`chatItems`, `makeChat`).
  - `WorkbenchActions.createChat` calls `AgentTabs.createProviderChat`. It goes through `actions`, not a new panel
    field, so an editor that was already running picks it up from a live patch.
  - `AgentTabs.createProviderAgentIn(..., chat)` and `canCreateSession(terminal)`: chat ignores
    `agentSessionMode == "terminal"`.
  - Palette: `agent:new-chat-<provider>`, labelled "New Chat with Claude/Codex/Pi". `installCommands` registers these,
    and `paletteEntries` registers them again so a live patch adds them.
- The owner confirmed it works in the running editor.
- No automated tests were added or run.

## In flight

Nothing. This session has no uncommitted files. `docs/one-command-gaps.md` and `suit/` are untracked and are not from
this session.

## Next steps (optional)

- Palette commands start the chat in the workspace root. They could use the active group instead.
- The menu item is enabled whenever `actions` is set. When the agent service cannot create a session, the click reports
  an error instead of greying out the item.
- A test in `tests/session-chat-ui` or a Workbench UI test should cover the menu item and the chat-view path in
  terminal mode.

## State outside the repo

None of my own. A note for whoever runs live mode: on 11-16, after a native `.c` edit, the live watcher hung on
`taskkill /T /F` (pid 57808) of the editor tree, and patches stalled until the module reloaded.
