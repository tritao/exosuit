# Claude provider

Exosuit runs Claude Code directly from Haxe. `ClaudeTransport` implements the
CLI's bidirectional JSONL protocol; there is no Python/TypeScript runtime bridge
or PTY. The workspace daemon owns one process per Claude session. Detaching an
editor leaves the process, active turn and pending approvals in the daemon.

## Using it

In a Workbench group's context menu, choose **New Claude session**. The existing
conversation tab renders streaming text, tool calls/results, approvals and user
questions. Approve once or decline a tool request. Answer questions in the prompt
as `0=Blue` (one numbered question per line); the adapter maps each number back
to the CLI's question text and preserves the original tool input. All questions
must be answered, without duplicate numbers. Long requests remain visible but
cannot be approved or answered from a truncated view; they can be declined or
the turn interrupted.

The model chooser uses the catalog returned by `initialize`. Model changes send
`set_model`. Permission choices send `set_permission_mode`: `default`,
`acceptEdits`, and `plan`. These are Claude permission modes, **not OS sandbox
profiles**. Existing CLI settings/rules can permit a tool without requesting
Exosuit approval. Exosuit does not enable bypass mode or change global settings.
Effort overrides are currently unsupported and rejected rather than ignored.

The executable is resolved on the workspace host from `EXOSUIT_CLAUDE_BIN` or
`claude` on PATH. Authentication uses the installed CLI's configuration. The
optional `EXOSUIT_CLAUDE_SCRIPT` launch prefix exists for test executables, like
the Codex fixture configuration; normal operation launches the CLI directly.

The fixed launch arguments are:

```sh
claude -p --input-format stream-json --output-format stream-json \
  --verbose --include-partial-messages --permission-prompt-tool stdio \
  --permission-mode <saved-mode> --session-id <reserved-uuid>
```

Recovery replaces `--session-id` with `--resume <saved-uuid>`. A saved model adds
`--model`. Provider identity, session UUID (`AgentRecord.thread`), canonical cwd,
model, permission mode, turn state and a bounded activity snapshot live in the
existing SQLite agent payload. Older records without a provider remain Codex.
The two providers share authorization, catalog limits and workspace RPC routing.
The generic provider registry and provider-specific discovery remain future work.

## Failure and replay

The daemon persists a prompt's working state **before** queuing its delivery.
A transport failure or daemon restart marks an unfinished turn uncertain. There
is no automatic prompt resend or automatic Claude process relaunch. Use
**Resume session** explicitly; this starts `--resume` without sending a prompt.
Then inspect the retained activity and, if necessary, CLI history before deciding
what to ask next. Initialization does not replay the full Claude transcript or
reconstruct an interrupted tool request. A reserved session that never received
its first prompt may not yet exist in Claude's history; Exosuit never silently
creates a replacement when resume fails. An active session in another CLI client
is not taken over or terminated by Exosuit.

Live activity retains 128 normalized items, paged eight at a time. Text/details
are clipped at 4096/2048 characters. Eviction invalidates old cursors. Up to six
recent items (384/128 characters of text/details, at most 6 KiB encoded) are saved
as a restart snapshot, not a full transcript. Older CLI history is not imported.
Partial text and final messages share message IDs so final delivery replaces
streamed content. Nested agent events are not flattened into the parent chat.

The transport bounds each frame at 256 KiB, input/output queues at 1 MiB,
outstanding control requests at 32, pending tool approvals at 16, control waits
at 60 seconds, and work per poll. Writes track UTF-8 byte offsets and handle
partial writes/backpressure. Malformed or oversized input disconnects the
session, clears pending approvals and leaves prompt delivery uncertain. Unknown
control request kinds receive an explicit protocol error. Interrupt completion
waits for the turn result; its control acknowledgement alone does not permit a
new prompt while the old result can still arrive.

## Validation

Run deterministic native adapter/failure tests with:

```sh
python3 scripts/test-claude-agents.py
```

The Python fixture is a test-only fake CLI, not part of the adapter or deployed
launch path. Tests cover routing/auth, create idempotence, text deduplication,
models/permissions, approvals and truncation, question validation, interrupt,
editor detachment, persisted uncertain turns, explicit resume without resending,
malformed/oversized frames, control timeouts, queue bounds and replay eviction.
The normal headless suite includes this test. Codex regressions remain covered
by `scripts/test-workspace-agents.py`.

Opt-in real CLI acceptance (requires authentication and uses inference):

```sh
python3 scripts/test-claude-agents.py --real
```

Verified 2026-10-26 with Claude Code **2.1.310**: native Haxe initialization,
streamed prompt, Write approval, AskUserQuestion answer, Bash sleep interruption,
explicit session resume remembering the answer, and model/permission controls.
The fixture runs in a temporary directory. It adds per-process ask rules to
make approval callbacks deterministic and does not alter global CLI settings.
No desktop click-through qualification has been performed for Claude yet.

Protocol references:

- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Headless operation](https://code.claude.com/docs/en/headless)
- [Official SDK control protocol implementation](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py)
- [Official SDK subprocess launch](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/transport/subprocess_cli.py)

The adapter follows these envelopes directly; SDK libraries are not runtime
dependencies. Compatibility is established through initialization and operation
responses, not a hard-coded version allowlist. Re-run real acceptance after CLI
protocol changes.
