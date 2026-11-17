# Agent sessions across restarts

How a Claude, Codex or Pi session continues its conversation after its program, its service or the machine was
restarted. Terminals and their hosts are in [terminal-host-status.md](terminal-host-status.md).

An agent session is either a provider terminal (the CLI in a terminal; the default, `agentSessionMode` "terminal") or
a chat session (the service runs the CLI and the chat panel draws it).

## Provider terminals

Terminals live in hosts that outlive the service, so most restarts never end the program. When it did end (Windows
restart, exohost's full quit, a crash, the user quitting the CLI), the terminal's row stays, labelled "resumable".

- **Each provider reports its conversation.** The terminal's program is started with a reporter of its own extension
  point, writing to `sessions.log` in the terminal's folder of the service's state (`AgentTerminalIdentity`):
  Claude's SessionStart hook (`--settings <file>`), a Codex notify program (`-c notify=[...]`, run after each turn
  with the thread id) and a Pi extension (`--extension <file>`, `session_start`). A report follows the conversation
  through `/clear`, `/new`, `/resume` and `/fork`. The user's own provider settings are not changed; for Codex the
  notify setting replaces a `notify` of the user's configuration inside that terminal.
- **Claude and Pi are given an id** at the first start (`--session-id`), so a terminal has one at once. Codex cannot be;
  it reports its thread after its first turn.
- **A restart resumes** the last reported id, else the recorded one (`AgentTerminalResume.plan`): `claude --resume <id>`
  (or `--session-id <id>` while Claude has no record of it, as when nothing was said yet), `codex resume <id>`,
  `pi --session-id <id>`. With no id (a Codex terminal whose first turn never ended) it begins a new
  conversation. Nothing is guessed from the providers' files by folder and time.
- **Opening a resumable terminal continues it**: the first time a view sees the terminal ended, it restarts
  it in the same tab, as Resume does. It sends no text. A program that ends while its view is open stays ended until
  Resume. Plain shells keep their last screen and start again only on Restart.

## Chat sessions

- The service builds a provider when it is first needed (`WorkspaceAgentService`): a session of its kind is created,
  listed or acted on, or its models are asked for. A workspace whose agents are all terminals builds none.
- **Claude:** the whole conversation comes back from Claude's own record (`<CLAUDE_CONFIG_DIR or ~/.claude>/projects/
  <folder>/<id>.jsonl`, the last 8 MB, read only; `ClaudeTranscript`). A message typed into a stopped session resumes it
  (`--resume <id>`, or `--session-id <id>` if nothing was said) and is delivered once Claude is ready.
- **Pi:** the whole conversation comes back from Pi's session file (`PiTranscript`); a message resumes with
  `--session <file>`.
- **Codex:** Codex's app-server is started when a saved Codex session is first read (its tab opens), not at service
  start; then every saved session is reconnected (`thread/resume`) with its history.
- A session that was working when the service ended is "uncertain" and refuses prompts until resumed. An invalid saved
  record is a row with the reason; the other rows are there.
- Idle chat processes keep a service with no client up to ten times the idle limit, at most ten minutes
  (`WorkspaceLifetime.shouldStop`).

## Not done

- Keeping chat processes alive across a service stop past those ten minutes (they are pipes, not a PTY a host owns).
- A long reply restored from Claude's record is served whole only while it is among the 128 newest cached texts of the
  service; older ones show their first 4096 characters.
- Images of prompts older than the service's 6-item preview are not attached again after a restart.

## Decisions the owner may want to reverse

1. A message typed into a stopped Claude or Pi chat session starts its process without asking; opening an ended
   provider terminal starts its program without asking.
2. The service reads Claude Code's files under `~/.claude/projects` and Pi's session files (read only), for chat
   history and to choose between `--resume` and `--session-id`. If they change, chat sessions show the short preview.
3. A Codex terminal that ended before its first turn finished begins a new conversation on Resume.
