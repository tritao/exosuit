# Codex provider

Exosuit's workspace daemon connects through the installed Codex shared
app-server. It launches only on explicit creation, discovery or reconnect.
The proxy forwards raw socket bytes; `run-codex-proxy.py` performs the local
WebSocket upgrade and bounded text-frame/JSONL translation. It handles fragmented
text, ping/pong, UTF-8, masking and graceful output drain without owning the daemon.
Closing an editor/conversation view releases its client; provider shutdown closes
only its proxy. It never stops/restarts the shared server or deletes Codex history.

This first adapter supports **codex-cli 0.160.0** with server **0.160.0/0.160.1**. The initialized server must be 0.160.0 or 0.160.1. All 31
used generated schemas are identical for these two server versions; hashes are
recorded in [codex-protocol-lock.json](codex-protocol-lock.json). A different version fails visibly; update the
adapter against that version's generated schema rather than guessing field names.

Protocol reference: <https://learn.chatgpt.com/docs/app-server>.
The installed schema was generated with:
`codex app-server generate-json-schema --out /tmp/exosuit-codex-schema-0160`.

## Operations

- Create a conversation in the selected group's inherited canonical directory.
  New threads request `workspace-write` sandbox and `on-request` approvals.
- Find existing threads in the selected directory and explicitly attach them.
  Read metadata before resume, validate cwd, and preserve existing thread policy.
- Send a text prompt, watch streamed messages/tool activity, interrupt the active
  turn, or reconnect and read the latest turn plus eight recent history items.
- Command/file approvals support approve once or decline. Truncated requests
  cannot be approved here. User input uses question IDs (`id=value` per line).
  Unsupported request kinds remain visible for another compatible Codex client.

The Workbench displays agents alongside terminals. Conversations are ordinary
editor-group tabs with saved workspace/resource references. Each view has its
own draft; records, requests and turn ownership live in the daemon. Switching
projects cannot submit a draft to another workspace.

## Bounds and recovery

SQLite schema v4 adds at most 32 agent records; existing v1–v3 databases migrate.
Resource metadata is committed before thread creation. An uncertain create keeps
its reservation; Exosuit never silently creates a replacement thread. Thread IDs
survive workspace-daemon restarts; the next attachment reconciles persisted
Codex state rather than claiming the old active turn continued.

Catalog pages contain at most six records. Views retain 16384 characters of
activity, sixteen requests with 2048-character summaries, and bounded errors.
The structured conversation retains at most 32 items and 8192 characters across
all item fields. Individual message text is capped at 4096 characters and tool
details at 2048; truncation and omitted older items are explicit.
Provider messages are capped at 256 KiB, queues at 1 MiB, pending calls at 32,
and each poll limits I/O and message dispatch. Writes respect the native process
pipe's atomic limit.

Only a confirmed `provider_starting` refusal may retry creation, with the same
resource ID and workspace instance. Prompts and approval replies are never
automatically replayed after loss. Reconnect reads the current active turn and
bounded persisted history first. Resolved or disconnected request IDs refuse
another answer.

Messages, reasoning summaries, commands/output and file changes have typed
presentation items keyed by turn and item ID. Completion replaces streamed text;
duplicate completion and late started/delta events cannot duplicate a finished
message. History ordering uses the server page and preserves live items arriving
during the query. The desktop groups messages by speaker, folds tool details,
keeps raw diagnostics behind a toggle, and keeps the prompt outside the scrolling
conversation. Pending requests appear first, with command/directory/reason and
question/options presented as readable text. Transport IDs stay in the adapter;
other decision fields remain visible, and the complete raw request size still
fences approval reviewability. Unknown item kinds retain bounded diagnostic details.

This is a first Codex slice: full paged history browsing, Markdown/diff rendering,
the remaining request kinds, agent rename/move/remove, supervision CLI/wait and
Claude are still planned. Two real shared-daemon clients initialize and query
metadata through the WebSocket bridge; one continues querying after the other
disconnects. Opt-in real inference also passed: the same turn completed after
both attached fixture clients disconnected, and reconnect/resume read its
assistant response from persisted history. The first attempt refused attachment
and cleanup interrupted only its test turn; the next fresh attempt passed. The
initial refusal is unclassified. Desktop acceptance still uses the fake provider.

## Tests

`python3 scripts/test-workspace-agents.py` runs the native fixture.
`HAXEON_SELF_HOSTED=1 python3 scripts/test-workspace-agents.py` checks self-hosted
compilation. `xvfb-run -a python3 scripts/test-codex-workbench-ui.py` drives desktop
creation, prompting, approvals, input, tab restoration and view closing with fake
Codex. Passing an installed runtime directory tests relocation.

`python3 scripts/test-codex-shared-metadata.py` checks two clients against an
already-running real shared daemon. It does not start the daemon, create threads
or send inference prompts.

`python3 scripts/test-codex-shared-lifecycle.py --run` opts in to one real model
turn in an isolated read-only directory. It checks two-client attachment, active
turn survival after both clients disconnect, same-turn recovery and persisted
history. It sends no approval replies, never replays the prompt and never
stops/restarts the shared daemon. Failure cleanup interrupts only its test turn.
The persistent test thread is printed and retained for inspection.

The structured desktop fixture includes a long wrapped message. Native layout
regressions also check that external paragraph line coordinates agree with
rendered primitives, including explicit newlines and empty lines.
