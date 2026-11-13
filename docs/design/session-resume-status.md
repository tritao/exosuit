# Agent sessions across restarts: what happens and what was changed

Status: 2026-11-12, branch `session-resume`. Companion of `terminal-host-status.md` (terminals); this file is about the
sessions the agent service runs itself (the chat panel: Claude Code, Codex, Pi, AgentKit).

## Evidence

From a copy of the user's state (`%LOCALAPPDATA%\Exosuit-20261112-preswitch`, read only) and the code.

- The six current workspaces hold **1 chat session record** (Codex, `idle`) and **9 terminal records, 6 of them
  provider terminals** (`agentProvider` `claude` ×5, `codex` ×1; 5 `lost`, 1 `exited`). What the user calls sessions
  are mostly Claude Code running in a terminal, not chat sessions.
- A provider terminal's record holds no conversation id (`TerminalRecord`: id, name, group, cwd, instance, state, exit
  code, provider). "Restart" on a lost one starts plain `claude` again (`TerminalProfile.agent`,
  `native-packages/terminal/session/haxe/terminalsession/TerminalProfile.hx:28`; `WorkspaceTerminalManager.profile`,
  `agent/src/workspace/runtime/WorkspaceTerminalManager.hx:155`): a new conversation. Nothing resumes the old one.
- A service stops itself 60 s after its last client left unless a session is working or waiting for an answer
  (`agent/src/app/AgentMain.hx:314`, `WorkspaceLifetime.shouldStop`): an idle chat session does not keep it up. So
  closing the editor, or switching to another workspace, ends every idle Claude or Pi chat process a minute later.
  14 of 24 service starts in the logs have no stop line (killed or stopped by suit), 3 stopped idle, 2 for an update.

## A chat session, case by case, before this branch

| Case | What the user got | Why |
|---|---|---|
| Editor closed and reopened within a minute, or a session is working | Row there, same process, full view | The process belongs to the service (`ClaudeProvider.hx:36`); the catalog lists every record (`WorkspaceAgentService.hx:85`) |
| Editor closed for more than a minute with idle sessions; workspace switched away for more than a minute | Claude, Pi: row "Disconnected", the last 6 items cut to 384 characters each, prompt disabled, a "Resume session" button. Codex: reconnects by itself, full history | Idle stop (`AgentMain.hx:314`) ends the service; `dispose` ends each process (`ClaudeProvider.hx:391`); only `ClaudeConversation.snapshot` (6 items, 384 characters) is saved (`ClaudeConversation.hx:88`); the panel enables the prompt only when connected (`CodexSessionPanel.hx:319`, `:364`). Codex resumes threads at start (`CodexProvider.hx:488`, `thread/resume` `:723`) |
| Rebuild (service restarts for the update, or is stopped first) | Same as above; a session that was working shows "uncertain" and refuses prompts until resumed | Records load as `disconnected` or `uncertain` (`ClaudeProvider.hx:75`) |
| "Quit Exosuit and suit", start again | Same as above | The service is killed; the record is whatever was saved last |
| "Resume session" on a Claude session that was used | Works: `claude --resume <id>` in the session's folder, same conversation; the view stays the 6-item stub plus what comes after | `ClaudeProvider.launch` (`:137`), id and cwd from the record |
| "Resume session" on a Claude session nothing was ever sent to | Fails every time ("Claude CLI exited with status 1"); the row can only be deleted | `--resume` needs a conversation Claude recorded; one is written with the first message |
| A saved record that fails validation (no folder, bad id, or saved under another workspace root) | The service does not start: no rows at all in that workspace | `throw "Invalid persisted Claude session"` in the provider's constructor (`ClaudeProvider.hx:73`), not caught in `AgentMain` |
| Provider terminal (Claude Code in a terminal) lost | Row "lost" with saved screen; restart begins a new conversation | See Evidence; terminals now survive a service stop in hosts, but not a Windows restart or "End all terminals" |

## What this branch changes (Claude chat sessions)

- **The whole conversation comes back.** A stopped session's conversation is read from Claude Code's own record
  (`<CLAUDE_CONFIG_DIR or ~/.claude>/projects/<folder>/<session id>.jsonl`, read only, the last 8 MB of a larger file, none of a file above 64 MB)
  the first time it is read or resumed (`ClaudeTranscript`, `ClaudeProvider.importTranscript`). A session keeps 512
  items instead of 128.
- **One action continues it.** A message typed into a stopped session resumes the same conversation
  (`--resume <id>`) and is delivered once the process is ready (`promptResumes` in the view; the panel keeps the prompt
  enabled and says so). The button still works. Not when a delivery is uncertain: that still needs the button.
- **Resume cannot fail for good.** With no record of the conversation, the session is begun under its id
  (`--session-id`); if Claude refuses, `--resume` is tried once.
- **Rows do not disappear.** An invalid saved record becomes a row that says why it cannot be resumed; a record saved
  under another root is kept usable. The service starts.

## Provider terminals (Claude Code or Codex in a terminal)

Terminals usually survive a service stop now (terminal hosts, `terminal-host-status.md`). For the rest (Windows
restart, a host ended by suit's full quit or "End all terminals", a crash, the user quitting Claude) a restart now
continues the conversation instead of beginning a new one (`AgentTerminalResume`, `WorkspaceTerminalManager.agentLaunch`):

- **Claude:** the record keeps a conversation id (`TerminalRecord.agentSession`). The first start passes
  `--session-id <id>`; a restart passes `--resume <id>` once Claude has a record of it (`ClaudeTranscript.locate`), else
  `--session-id <id>` again (nothing was said yet).
- **Codex** cannot be given an id. The record keeps when the terminal began (`agentStarted`); a restart looks in
  `<CODEX_HOME or ~/.codex>/sessions/YYYY/MM/DD/rollout-*.jsonl` for the earliest conversation of the terminal UI
  (`originator` `codex-tui`) in the terminal's folder begun after that and not kept by another terminal, records its id
  and passes `resume <id>`.
- **Terminals saved before this** (the user's 5 lost Claude terminals) have nothing to go by: a restart opens the
  provider's own list of the folder's conversations (`claude --resume`, `codex resume`) so the user picks the old one.
  With several conversations in one folder only the user can tell which was the terminal's.
- **Pi** terminals: unchanged (a new conversation; Pi's session layout was not available here to check).
- The tree says "resumable" for a lost or exited Claude/Codex terminal and its pane's button says Resume. Provider
  files are only read. Paths of 260 characters or more are read in their `\\?\` form (`LongPath`; haxeon bug list).

## Pi and Codex chat sessions

- An invalid saved Pi or Codex record no longer throws in the provider's constructor (which stopped the service): it is
  a row in state "Session unavailable" with the reason.
- A message typed into a stopped Pi session starts Pi again with `--session <file>` and is sent once Pi is ready (text
  only, not after an uncertain delivery). Pi still shows the service's short preview of the conversation, not the
  whole of it: reading Pi's own session file is not done.

## Idle stop

A service with no client used to stop after 60 s unless a session was working, ending idle chat processes. Idle chat
processes (`updateActivityCount`: Claude and Pi sessions with a process, attached Codex threads) now lengthen that to ten
times the idle limit, at most ten minutes (`WorkspaceLifetime.shouldStop`). Chosen over keeping the service up for good
because each such process costs memory and every session resumes on a message anyway; ten minutes covers a rebuild, an
editor restart and a quick workspace switch, where keeping the process means no restart delay at all.

## After, by case

| Case | What the user gets now |
|---|---|
| Editor closed and reopened (rebuild, restart) within ten minutes | Every chat session: same process, nothing to do. Terminals: same program (hosts) |
| Workspace switched away and back within ten minutes | Same as above |
| Editor closed or workspace switched for longer; quit Exosuit and start again | Claude chat: row "Resumable", whole conversation, a message resumes the same conversation. Pi: row "Resumable", short preview, a message resumes the same session. Codex: reconnects by itself. Terminals: still running in their hosts (unless suit's full quit ended them) |
| Claude/Codex terminal whose program ended (Windows restart, full quit, crash, user quit) | Row "resumable"; Resume in the pane continues the same conversation (new terminals); older terminals open the provider's list of the folder's conversations |
| Session that was working when the service ended | "uncertain", whole conversation (Claude), button to resume; prompts refused until then, as before |
| Claude session nothing was sent to | Resumes (begun under the same id) |
| Invalid record (Claude, Codex, Pi) | A row with the reason; the other rows are there |

## Not done

- **Keeping chat processes alive across a service stop** past the ten minutes. A terminal host owns a PTY; a chat
  process is a child with three pipes speaking JSON lines. Reusing the host means a second host kind that owns the
  pipes and relays frames, plus buffering of provider output while no service is attached and answering permission
  requests that arrive meanwhile. Estimate: 2 to 3 days with tests.
- Pi: the whole conversation after a restart (Pi's session file is not read); Pi terminals do not resume.
- A Claude terminal where the user ran `/clear` began a new conversation inside Claude; Resume returns to the one before.
- A long reply restored from Claude's record is served whole only while it is among the 128 newest cached texts of the
  service; older ones show their first 4096 characters.
- Images of prompts older than the service's 6-item preview are not attached again after a restart.

## Decisions the user may want to reverse

1. A message typed into a stopped Claude or Pi session starts its process without asking.
2. The service reads Claude Code's files under `~/.claude/projects` and Codex's under `~/.codex/sessions` (read only).
   They are the providers' formats, not documented interfaces; if they change, chat sessions show the short preview and
   terminals fall back to the provider's list or a new conversation.
3. An invalid saved record is shown, not refused. The check on the saved workspace root is gone for all providers.
4. 512 items per Claude session in memory instead of 128.
5. Idle chat processes keep a service with no client for up to ten minutes (was one).
6. A Codex terminal is matched to the earliest Codex conversation begun in its folder after it started; two Codex
   terminals started in one folder at the same moment could be matched the other way round.
7. Old provider terminals restart into the provider's picker, not a new conversation.
