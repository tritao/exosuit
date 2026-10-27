# Exosuit agent (agentkit provider)

The fourth Workbench provider is built in: choose **New agent session → Exosuit**.
Unlike Codex, Claude and Pi it has no CLI. `haxeon-agentkit` runs inside the
workspace daemon and calls the Anthropic Messages API over NativeKit HTTP, so it
works wherever the daemon does, including remote workspaces.

## Setup

Set a key where the **daemon** runs (not necessarily where the window is):

| Variable | Meaning |
| --- | --- |
| `EXOSUIT_AGENT_API_KEY` or `ANTHROPIC_API_KEY` | API key. Without one, sessions exist but prompts fail with `missing_credentials`. |
| `EXOSUIT_AGENT_API_URL` | Alternative endpoint (a gateway or test server). Plain `http://` is accepted only here. |
| `EXOSUIT_AGENT_MODEL` | Default model; otherwise `claude-sonnet-5-5`. |

Agent sessions always open as integrated conversations, whatever
`agentSessionMode` says.

## Tools

All paths are relative to the session's group directory, symlinks are resolved
before the containment check, and results are bounded.

| Tool | Access | Notes |
| --- | --- | --- |
| `read_file` | read | Text files under 2 MiB, numbered lines, `offset` / `limit`. |
| `list_directory` | read | Up to 500 entries. |
| `search_files` | read | Literal text; skips `.git`, `build`, `out`, `node_modules`; 100 matches, 3000 files. |
| `write_file` | mutating | Atomic. The parent directory must exist. |
| `edit_file` | mutating | One exact, unique replacement. |

There is no shell tool: the agent cannot run commands.

## Permissions

`supervised` (default) asks before mutating tools; `acceptEdits` and `fullAccess`
run them unattended. Both only govern these five tools. Approve / Decline use the
same request cards as the other providers; a declined call is reported to the
model as an error.

## State

The Workbench record and a bounded activity snapshot live in the daemon's SQLite
store like other providers. The model conversation is written to
`<state dir>/agentkit/agentkit-<hash>.json` when a run ends, and restored when
the daemon restarts. A run in progress cannot survive a restart: that session
reappears as *interrupted*, and its unfinished turn is not in the history.
Histories over 4 MiB are refused rather than truncated.

## Not yet supported

Effort levels, queued or steering messages, session discovery and native
renaming. Streaming is text-only; tool arguments are shown when the call starts.

## Verification

```sh
python3 scripts/test-agentkit-agents.py
```

Runs the core unit tests, the NativeKit transport, and the provider through the
real RPC path against a local mock server: read tool, approval, decline,
sandbox escape, stop, permission modes, restart with history, and missing key.
No paid inference.
