# M14 — Workbench: workspaces, terminals and agent supervision

Depends on M11, M12 and M13. The reference is the Pragtical Workbench submodule
(`../pragtical/data/plugins/workbench/`, especially its `README.md` and
`docs/workbench-plan.md`) and `src/workbench-agent/`. Stay wire-compatible
with Workbench protocol 2.1: a 4-byte big-endian length, a MessagePack map, a
16 MiB maximum, and hello/command/batch/result/snapshot/subscribe/event/error/
close. Keep a separate storage root per editor. Deliver it as an optional,
removable subsystem. The editor must work when Workbench is disabled or the
agent is missing.

## M14.1 — Client and UI against the existing agent

- [ ] Protocol 2 client: an async `execute` that returns a cancellable
  request, a 10 s default timeout, a snapshot plus `subscribe` with
  `after_event_sequence`, reconnect and replay, and endpoint resolution and
  namespacing.
- [ ] Add a `tree_model` projection of snapshots and events into
  collections, tasks and resources, with expanded state.
- [ ] Register a Workbench sidebar mode (M9.3). Commands: open, toggle,
  refresh, create-collection, create-task, create-terminal. Terminal resources
  open as M12 sessions backed by `runtime.input/resize/replay`.

Acceptance: against Pragtical's built `workbench-agent`, exosuit lists, creates
and drives a shell runtime. The runtime survives an editor restart and
reconnects with correct replay. This slice delivers a working Workbench before
the Haxe agent exists.

## M14.2 — Service and storage

- [ ] Port the domain service: validation limits (from `service/validation.lua`),
  commands with `operation_id` idempotency via command digests,
  `expected_revision` compare-and-swap, typed events with per-workspace
  sequences, and `execute_batch`.
- [ ] Storage on M11.3 with schema versions 3–7 migrations equivalent to
  `service/migration/`. MessagePack blobs. Refuse unknown schema versions.

Acceptance: port the service and persistence tests (revisions, idempotency,
lifecycle transitions, transactions, rollback, event trimming).

## M14.3 — Headless agent daemon

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
- [ ] Discovery descriptors with handshake validation. The client auto-spawns
  the agent detached when none is live.

Acceptance: port the agent, agent_reconnect, agent_terminal, agent_stress and
agent_fault scenarios. A PTY survives client reconnect, checkpoints restore,
stalled clients get evicted, offsets stay contiguous, and abrupt exit is
covered. Pragtical's client must interoperate with `exosuit-agent`.

## M14.4 — Providers, policy and supervision

Claude Code and Codex are required agent providers. Claude uses the CLI-in-a-PTY
pattern from Pragtical's `provider/agent_cli.lua`. Codex uses its structured
app-server protocol and shared local daemon. Keep provider transport separate
from terminal sessions: a Codex conversation is a thread with turns and items,
not a terminal byte stream. Before implementing, check installed CLI help and
generate the Codex protocol schema for that exact version.

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
