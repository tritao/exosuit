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

- [ ] Provider registry with the lifecycle contract (available, create,
  attach, recover, start, stop, restart, send_input, action, refresh_status,
  capabilities, shutdown). Built-in providers are `shell`, `codex` (CLI in a
  PTY with model, sandbox, approval and profile mapping) and `opencode`
  (HTTP+SSE, optionally a managed `opencode serve`, reattach by
  `external_session_id`).
- [ ] Policy: approval, sandbox and per-permission deny/prompt/allow, merged
  with runtime overrides and mapped per provider.
- [ ] Supervision commands: `agent.list/status/create/prompt/read/stop/restart/
  delete/wait`. `read` uses a durable `read_offset`, and `wait` is held by the
  daemon. Expose them as `exosuit-ctl workbench ...` (M13.3) and in the UI.

Acceptance: fake-provider tests cover the lifecycle, recovery and policy
mapping, and the HTTP/SSE parser handles chunked bodies, SSE and deadlines.
Real Codex and opencode runs are opt-in and recorded as pending when the CLIs
are unavailable.

## M14.5 — Sakura import

- [ ] Add a GKeyFile parser and a Sakura session import (groups become
  collections, tasks stay tasks, terminals become resources). It supports dry
  run and a skipped-field report, rejects ambiguous references and cycles,
  makes a `.bak` backup that is never overwritten, applies everything in one
  batch, and asks the user to type `import` to confirm.

Acceptance: the Pragtical fixture `tests/fixtures/sakura-session-v8.conf`
imports identically.
