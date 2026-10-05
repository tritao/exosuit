# Haxeon typed RPC foundation

Status: RPC.1 accepted for the transport-independent runtime and first in-memory
workspace consumer. Native, Wasm32 and Wasm GC tests pass, including handshake,
reconnect, subscription recovery and lost-mutation reconciliation. RPC.2 now has
real local sockets and authenticated loopback WebSockets, including Chrome
Wasm32/Wasm GC reconnect and daemon-restart tests. Resource reconciliation,
compatibility vectors and durable daemon storage remain. See
[WORKSPACE-RPC.md](WORKSPACE-RPC.md) for the consumer's exact guarantees and limits.
Required by the Exosuit workspace service in [M14](14-workbench.md). This plan
authorizes a small general-purpose Haxeon library developed alongside real
workspace methods, with the existing serialization layer.

## Ownership

| Haxeon RPC | Exosuit workspace service |
| --- | --- |
| Typed method descriptors and wire codecs | File, terminal and agent operations |
| Request correlation, errors, deadlines and cancellation | Permissions, domain validation and persistence |
| Transport-independent bounded dispatch | Authentication and deployment |
| Connection lifecycle, reconnect and handshake | Resource attachment and state reconciliation |
| Explicit resumable subscription hooks | Durable cursors, snapshots and replay history |
| Generic streaming flow control | Terminal offsets, checkpoints and operation deduplication |

Use `haxeon.wire`: MessagePack is the primary encoding; JsonWire provides an
optional diagnostic encoding of the same schema. Permanent method ids and
record field ids are never reused. Keep socket/WebSocket, UI and provider APIs
outside the RPC core. Codex's app-server protocol stays inside its adapter.

## RPC.1 — Runtime and reconnect, first delivery

- [x] Define typed request/response, notification, cancellation and structured
  error envelopes, protocol/capability negotiation and connection-scoped ids.
  Distinguish application version from framing/codec version. Capability-gate
  new enum variants; validate required values after decoding.
- [x] Implement typed method descriptors, client calls and handler dispatch.
  Handlers receive cancellation/deadline context and may respond asynchronously.
  Use existing asynchronous abstractions where suitable; do not block the loop.
- [x] Define a message transport interface and an in-memory fault-injecting
  transport. Local streams use bounded incremental HMPK assembly; binary
  WebSocket messages supply their own boundaries. Bound allocation before
  assembling payloads, pending calls, queued bytes and work per poll.
- [x] Include connection lifecycle and reconnect in the first slice: explicit
  connecting/handshaking/connected/disconnected/closed states, bounded backoff
  with jitter, cancellable attempts and a fresh handshake on each connection.
  Inject clock/scheduler/randomness for deterministic tests. Explicit close
  disables reconnect; incompatible protocol or authentication refusal is
  surfaced rather than retried indefinitely.
- [x] Fence responses, callbacks and subscriptions by connection generation.
  Disconnect completes pending calls with an explicit failure; if a request
  may have reached the server, preserve that ambiguity. Never silently replay
  pending requests or widen capabilities/policy during reconnect.
- [x] Provide explicit subscription restoration hooks. A resumable subscription
  supplies an application-owned cursor and resume request after handshake.
  Surface replay gaps to the application, which chooses a fresh snapshot.
  Do not automatically repeat arbitrary resource-creating subscription calls.
- [x] Use the initial runtime immediately with Exosuit hello, a read-only
  workspace query and one sequenced subscription. Add a mutation with an
  Exosuit operation id to demonstrate safe reconciliation after a lost reply.

Failure contract: timeout ends the caller's wait, not necessarily server work.
Cancellation is cooperative and does not promise rollback. Late completion
must not resurrect an expired call. A disconnected mutation can already have
executed; retries require application-level idempotency/reconciliation. No
exactly-once claim is made for network delivery.

Acceptance: deterministic tests cover round trips, unknown methods, malformed
and oversized messages, split/coalesced frames, deferred handlers, deadline
and cancellation races, disconnect before/after dispatch, lost responses,
old-generation callbacks, reconnect backoff and explicit close. Demonstrate
resume without missing application events, replay-gap snapshot recovery,
and no duplicated workspace mutation. Flooded peers stay within queue and
poll budgets. Codec fixtures agree across native and Wasm targets.

## RPC.2 — Transport integration and compatibility

- [x] Implement local socket and browser-compatible WebSocket adapters using
  the same typed runtime. Keep authentication/session establishment at the
  adapter/service boundary and verify it before privileged dispatch.
- [ ] Exercise service restart, mobile-style suspend/resume, connection churn,
  slow consumers and capability changes. Reconcile Exosuit terminal and agent
  resources without stopping unrelated sessions.
- [ ] Freeze documented protocol vectors and evolution rules. Test added and
  missing fields, unsupported variants/versions and explicit method errors.

Acceptance: real local and browser connections recover through the same
client API. Interrupted requests retain their documented failure semantics;
no remote deployment or Android qualification is implied by adapter tests.

## RPC.3 — Method generation

- [ ] Define each method once with permanent id, request and response type;
  generate client calls and server dispatch from the verified descriptor API.
  Prefer library/tooling generation first; add compiler syntax only when it
  removes demonstrated duplication without coupling the compiler to Exosuit.
- [ ] Reject duplicate method ids and unsupported schema shapes. Preserve
  wire vectors and static request/response typing. No Dynamic/reflection dispatch.

Acceptance: generated and explicit APIs interoperate and produce identical
messages; invalid declarations fail with actionable diagnostics.

## RPC.4 — Streaming and buffer ownership

- [ ] Add explicit stream open/data/credit/close semantics with cancellation,
  bounded queues and fair scheduling. Keep bulk terminal/file traffic from
  starving control and approval messages. Durable replay remains application-owned.
- [ ] Measure copies/allocations; use immutable slices or owned buffers where
  appropriate. Retained asynchronous buffers require explicit ownership;
  borrowed receive memory cannot outlive its lease. Put reusable framing and
  byte-view improvements in Haxeon, not Exosuit wrappers.

Acceptance: slow-consumer and cancellation tests bound memory and prove buffer
lifetimes; native/Wasm tests cover retained and reused buffers. Do not claim
zero-copy serialization or networking: current MessagePackFrame pack/unpack
allocates and copies, and decoding typed values can allocate.

## Delivery rules

Implement and commit verified slices in Haxeon under the execution contract,
with Exosuit consumer tests and ledger entries. No Pragtical agent dependency.
RPC.1 includes reconnect; application persistence/replay is implemented alongside
it rather than deferred behind a transport-only demonstration. Stages RPC.3
and RPC.4 do not block initial workspace delivery unless measured consumer
requirements make them necessary.
