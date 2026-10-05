# M14 — Workbench: workspaces, terminals and agent supervision

Depends on M11, M12 and M13. Build an Exosuit-owned workspace service and
protocol. Pragtical's Workbench sources and tests are read-only behavioral
references, not a runtime dependency or wire-compatibility requirement. Deliver
Workbench as an optional, removable subsystem: the editor must work when it is
disabled or the agent is missing.

## Protocol and client boundary

Follow the compact [workspace protocol contract](WORKSPACE-PROTOCOL.md) for
ownership, permissions, mutations, subscriptions, terminals and agents.

The [Haxeon RPC plan](HAXEON-RPC.md) supplies typed calls, bounded dispatch
and connection lifecycle, including reconnect from the first delivery. Exosuit
owns operation deduplication, durable replay and resource reconciliation.

Use Haxeon's `haxeon.wire` typed codecs for shared protocol records. Define
`@:wire` records with permanent `@:id` field identities in a shared package
used by the headless agent and desktop/browser clients. Use MessagePack as
the primary encoding; `JsonWire` is an optional diagnostic encoding of the
same schema, not a second application protocol.

Keep encoding, transport and service semantics separate:

- Local byte streams use the versioned HMPK envelope from `MessagePackFrame`.
  Add bounded incremental assembly for split/coalesced reads. Check declared
  length before allocating. Binary WebSocket messages carry one MessagePack
  value without another length frame. Both invoke the same typed handlers.
- The application hello negotiates protocol major/minor and capabilities;
  HMPK's framing version is not the workspace protocol version. Unknown fields
  can be skipped, but unknown enum constructors are rejected by current codecs:
  capability-gate new variants and report unsupported methods explicitly.
- Define request ids, structured errors, cancellation, deadlines, operation-id
  deduplication, expected revisions and sequenced snapshot/subscription replay.
  Use Int64 for long-lived revisions, event sequences and terminal offsets.
  Validate required identifiers and domain constraints after decoding: missing
  scalar fields otherwise receive codec defaults.
- Apply protocol-specific byte/container/depth limits, bounded queues and work
  budgets. Haxeon wire supplies serialization; the planned Haxeon RPC layer supplies
  calls/reconnect/backpressure, while service adapters enforce authentication.
- The current frame pack/unpack helpers allocate and copy payloads. Initially
  use the verified helpers; add reusable generic slice/stream APIs in Haxeon
  if measurements justify them, with explicit buffer lifetimes. Do not claim
  zero-copy serialization or network transport.

Remote web/Android clients connect through an authenticated HTTPS/WebSocket
boundary to this same service. Project file browsing/watching, persistent
terminals and agent resources are service modules. The
[filesystem API plan](WORKSPACE-FILES.md) specifies root-scoped reads, revisions,
watch recovery and search. Device UI state stays local.
Codex's own protocol remains behind its provider adapter. Standalone browser
mode remains available without a server; connected capabilities are negotiated
with the service. Remote deployment and mobile acceptance are tracked in
[M16](16-remote-workspaces.md), using the existing web build first and including
away-from-home relay access from initial delivery.

## Named groups and working directories

Preserve Sakura-style named, nested groups as a first-class Workbench feature.
Use one group concept (the UI name for collections), not parallel group and
collection hierarchies. A group has a stable id, name, optional parent,
optional working-directory reference and sibling order. Duplicate display
names are allowed; identity is the id. Persist groups in the workspace service
and project them into the same tree on desktop and connected web/mobile.

- Groups contain child groups, agent sessions and terminals. Support create,
  rename, reorder and move; reject cycles. A flat Agents list may be a filtered
  view of this tree, not a separate storage model.
- Show directory hints and aggregated attention/activity badges. Keep tree
  expansion/selection per client. Selecting a group does not automatically
  replace the editor project or change another client's view. Offer an explicit
  Open folder action for its directory.
- New terminals/agents use an explicit session directory override, otherwise
  the nearest ancestor group's directory, otherwise the workspace default.
  Resolve and validate it on the machine, then persist the chosen session cwd.
  Remote clients select authorized directory references, not arbitrary host
  paths; assigning a group directory never grants access by itself.
- Moving a running session or changing a group directory affects organization
  and future launches only, never silently changes cwd or restarts work. Restart
  retains the session's persisted cwd unless explicitly changed. Missing or
  inaccessible directories fail visibly instead of falling back elsewhere.
- New terminal/New agent actions target the selected group, with provider choice
  for agents. Preserve nesting, names, order and directory associations during
  Sakura import; map directories into authorized roots explicitly.

Acceptance: nested directory inheritance, explicit overrides, duplicate names,
cycle rejection, move/rename without runtime disruption, invalid directories,
service restart and two-client synchronization. Desktop and phone display the
same hierarchy; selecting/expanding it remains independent.

## M14.1 — Shared protocol, client and initial service

- [ ] Deliver Haxeon RPC.1 with an Exosuit consumer, including reconnect,
  explicit subscription recovery and lost-reply mutation reconciliation.
- [ ] Define and test the shared schemas, hello/capability negotiation,
  requests/responses/events, errors and bounded local transport assembly.
- [ ] Build an async client with cancellable requests, a 10 s default timeout,
  snapshot plus subscribe with an event cursor, reconnect/replay and endpoint
  resolution. A minimal Exosuit headless service supplies this slice; it does
  not connect to Pragtical's agent.
- [ ] Add the named-group tree above, projecting snapshots/events into nested
  groups and session resources, with client-owned expanded state.
- [ ] Register the Workbench sidebar mode (M9.3): open, toggle, refresh,
  create-group, rename/move-group, create-task and create-terminal. Terminal resources open
  as M12 sessions backed by service input/resize/replay operations.

Acceptance: deterministic protocol fixtures verify schema evolution, missing
and invalid fields, split/coalesced frames, limits, cancellation and replay.
An Exosuit client lists, creates and drives a shell runtime against the initial
Exosuit service. The runtime survives an editor restart and reconnects with
correct replay. No Pragtical binary is required.

## M14.2 — Service and storage

- [ ] Port the domain service: validation limits (from `service/validation.lua`),
  commands with `operation_id` idempotency via command digests,
  `expected_revision` compare-and-swap, typed events with per-workspace
  sequences, and `execute_batch`.
- [ ] Storage on M11.3 with Exosuit-owned schema versions and migrations.
  Pragtical migrations are reference cases; existing Pragtical database
  compatibility is not required. Typed MessagePack blobs. Refuse unknown
  schema versions.

First catalog slice delivered: schema v1 persists groups, cursor, operation
requests/outcomes and trimmed events atomically through generic SQLite. Restart
preserves the epoch and idempotency; failed storage fences the service. Unknown
schemas/corrupt bounded records are refused. Full domain/lifecycle/batch storage
and later migrations remain open.

Acceptance: port the service and persistence tests (revisions, idempotency,
lifecycle transitions, transactions, rollback, event trimming).

## M14.3 — Headless agent daemon

Delivered terminal metadata slice: SQLite records preserve names/group membership
and reconcile old active sessions as lost. Capability-gated discovery pages,
revision-checked metadata editing/removal and the desktop “Workspace Terminals…”
browser allow detached sessions to be found and reattached independently of tabs.
The browser uses existing named groups; new/nested group creation and task/provider
catalog integration remain pending. Output history is still volatile.

Delivered first terminal slice: the Linux desktop attaches folder-scoped terminals
through typed RPC to daemon-owned PTYs. Saved IDs restore the same shell across
window shutdown; ongoing shell execution retains the daemon. Explicit termination,
read/control grants, bounded byte replay, input ambiguity fencing and VT response
ownership are implemented. Source startup separates compilation from the lock-owning
runtime, and PTY child descriptors are isolated in NativeKit. Real client-process
and desktop reopen fixtures cover ownership. This does not complete M14.3: durable
history/state checkpoints, full task/provider resource catalog and durable runtime recovery, named-group
integration and provider supervision remain pending.


First bootstrap delivered in `agent/haxeon.json`: a headless NativeKit loop hosts
a durable group catalog over same-user local sockets and authenticated loopback
WebSockets. Real Chrome Wasm32/Wasm GC clients recover a saved rename across
connection and agent process restarts. `scripts/run-agent.py` adds qualified Linux
startup, an inherited exclusive lock (exit 3), private generation-tagged discovery,
detached readiness and device/inode storage-replacement fencing. Linux repository
desktop discovery, typed identity validation and detached auto-spawn/reuse are
delivered, including release staging of the matched daemon/manager. An idle
catalog-only service stops after one minute without authenticated clients; explicit
always-available mode disables that timeout. Durable runtime recovery and provider supervision remain open. Catalog connection limits are the stricter existing RPC.2
bounds documented below, not the future runtime-manager budget.
See [WORKSPACE-RPC.md](WORKSPACE-RPC.md) for limits and test evidence.

- [ ] Add an `exosuit-agent` headless manifest. It takes an exclusive
  workspace lock (exit 3 `workspace_in_use`). Its single-threaded server loop
  accepts, processes clients, polls runtimes and providers, and flushes. Per
  client: 64 messages per turn, 1024 messages or 8 MiB outbound, and 1024
  pending events; evict on overload. Detect replaced storage by device and
  inode.
- [ ] Runtime manager over M11.1 and M11.4. History: append-only output files
  with byte-offset bounds and 16 MiB rotation. Emulator checkpoints every
  256 KiB (max 4 MiB), written atomically. Crash reconciliation. Volatile mode
  on storage loss.
- [x] Discovery descriptors with handshake validation. The client auto-spawns
  the agent detached when none is live. Linux repository and relocated runtime
  bundle accepted; default idle stop and explicit availability are covered.

Acceptance: port the agent, agent_reconnect, agent_terminal, agent_stress and
agent_fault scenarios. A PTY survives client reconnect, checkpoints restore,
stalled clients get evicted, offsets stay contiguous, and abrupt exit is
covered. The shared Exosuit client must interoperate with `exosuit-agent`.

## M14.4 — Providers, policy and supervision

Claude Code and Codex are required agent providers. Claude uses the CLI-in-a-PTY
pattern from Pragtical's `provider/agent_cli.lua`. Codex uses its structured
app-server protocol and shared local daemon. Keep provider transport separate
from terminal sessions: a Codex conversation is a thread with turns and items,
not a terminal byte stream. Before implementing, check installed CLI help and
generate the Codex protocol schema for that exact version.

Sakura is useful reference input for workspace ownership, terminal replay,
bounded queues and failure tests. Its Codex integration predates the shared
app-server and is explicitly excluded as a provider reference. Base the Codex
adapter on current official protocol documentation, installed CLI/schema and
shared-daemon acceptance tests; do not port Sakura's Codex helpers or hooks.

Research baseline, 2026-10-05: installed `codex-cli 0.160.0` exposes
`app-server daemon`, `app-server proxy`, `agents`, `--remote` and `--no-daemon`.
Its generated stable schema includes thread start/list/read/resume, turn
start/interrupt, status notifications and server-initiated approval requests.
The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
covers the protocol; daemon/proxy commands are verified from local CLI help.
Their multi-client lifecycle and reconnect behavior still need acceptance tests.

- [ ] Provider registry with the lifecycle contract (available, create,
  attach, recover, start, stop, restart, send_input, action, refresh_status,
  capabilities, shutdown). Ship `shell`, `claude` and `codex`.
- [ ] `claude` provider: run the interactive `claude` CLI in a PTY so the
  user can watch and take over in the terminal view. `TERM=xterm-256color`,
  scrollback 10000, and cwd is the task's project directory.
  - Create generates a UUID, passes it with `--session-id`, and stores it as
    `external_session_id`. Recover and restart use `--resume <id>`, so the
    conversation survives agent or editor restarts.
  - Map `--model`, `--add-dir`, `--allowedTools` and an initial prompt from
    the resource config.
  - Status comes from Claude Code hooks, not screen-scraping. Pass a
    per-runtime `--settings` file whose hooks (session start, prompt submit,
    stop, notification or permission request) run
    `exosuit-ctl workbench agent event <runtime> <kind>`. This reports
    working, idle, needs-permission and completed states to the agent, and
    `agent.wait` relies on it. If the hook command fails or is missing, fall
    back to process state only and surface a degraded-status warning.
- [ ] `codex` provider: connect to the shared local app-server daemon through
  `codex app-server proxy` (or a verified configured local socket). Start it
  through `codex app-server daemon start` when absent. Validate CLI/server
  compatibility and initialize each connection before issuing requests.
  - Store the Codex thread id as `external_session_id`; create with
    `thread/start`, recover with `thread/read` and `thread/resume`, and send
    prompts with `turn/start`. Track turn ids separately. Do not automatically
    resend a prompt after an ambiguous connection failure; reconcile first.
  - Project structured thread/turn/item notifications into Workbench status
    and a conversation/activity view. Preserve tool output and file-change
    details. `read` and `wait` use provider events and persisted history rather
    than scraping a terminal. Bound queues, history reads and work per turn.
  - Route command/file approvals and user-input requests to the UI and
    supervision API using their request ids. Handle resolved requests,
    disconnects and competing-client replies without answering twice. Map
    sandbox and approval policy through the version-matched protocol; never
    widen policy silently or change the user's global Codex configuration.
  - Stop means interrupt this resource's active turn. Closing the editor or
    deleting a Workbench resource must not stop/restart the shared daemon,
    interrupt unrelated threads, or delete Codex history implicitly. Recovery
    after an actual daemon restart resumes persisted history; it must not
    claim an interrupted in-flight turn continued.
  - Offer explicit discovery/attachment of existing Codex threads, filtered
    by project. Do not import unrelated sessions automatically. Optional CLI
    takeover uses the same verified daemon/thread; it is not the status source.
    Test subscription lifetime and active-turn survival before claiming that
    work continues without an editor connection.
- [ ] Policy mapping for `claude`. Approval `prompt` maps to
  `--permission-mode manual`. `auto` maps to `acceptEdits`, or to `auto` when
  the policy also allows process execution. Sandbox `read-only` maps to
  `plan`. `bypassPermissions` only applies with sandbox `full` and every
  permission `allow`, and the UI requires explicit confirmation for it.
  Merge per-runtime overrides as Pragtical's `policy.lua` does.
- [ ] Supervision commands: `agent.list/status/create/prompt/read/stop/restart/
  delete/wait`. `prompt` starts the runtime if needed, otherwise it sends the
  prompt through the provider transport (PTY input for Claude; a turn request
  for Codex). `read` uses a durable provider cursor (byte offset for terminals,
  thread/turn/item position for Codex), and `wait` is held by the daemon until
  provider events report a terminal state. Expose them as
  `exosuit-ctl workbench ...` (M13.3) and in the UI, including a
  "New Claude Code agent" and "New Codex agent" commands.
- [ ] Follow-on providers, out of scope for M14 unless separately scheduled:
  `opencode` (HTTP+SSE).

Acceptance: a fake `claude` executable on `PATH` records its argv and emits
scripted output plus hook invocations. The tests built on it cover create,
resume after an agent restart, policy-to-flag mapping, hook-driven status, a
`wait` timeout, and a missing hook. A real Claude Code run is opt-in: create,
prompt, wait, read, restart with resume. Record it as pending when `claude`
is unavailable or not authenticated.

Codex acceptance: a fake app-server transport covers handshake, create,
prompt, streamed items, approval and user-input requests, turn interruption,
reconnect/history reconciliation, duplicate events and bounded queues. Cover
unsupported versions/methods, resolved approval races and disconnects during
an active turn. Assert that closing/restarting the editor never stops the
shared daemon or another client's thread. A real Codex run is opt-in: create,
prompt, wait, read, reconnect and resume, plus two-client attachment and
active-turn survival across editor disconnect. Record unavailable or
unauthenticated Codex as pending. Schema generation and CLI help alone do not
accept the provider.

## M14.5 — Sakura import

- [ ] Add a GKeyFile parser and a Sakura session import (groups become
  collections, tasks stay tasks, terminals become resources). It supports dry
  run and a skipped-field report, rejects ambiguous references and cycles,
  makes a `.bak` backup that is never overwritten, applies everything in one
  batch, and asks the user to type `import` to confirm.

Acceptance: the Pragtical fixture `tests/fixtures/sakura-session-v8.conf`
imports identically.
