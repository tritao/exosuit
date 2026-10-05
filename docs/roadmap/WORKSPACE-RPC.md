# First workspace RPC consumer

The transport-independent implementation lives in `src/workspace/service/`.
It is a headless catalog of named group metadata with optional cwd association;
renaming preserves cwd. It does not yet implement the full nested group model,
project/file access, terminal/agent operations or persistence. A running bootstrap
daemon now hosts this catalog; full daemon supervision/discovery remains pending.
The native and Wasm tests consume the same service, client replica and wire types.

## Methods and permissions

All requests identify the workspace. Bind a service only to an authenticated,
handshaken connection and pass its negotiated capabilities. The service checks
these grants at dispatch. The returned revocation function closes the connection
and removes its observer; directory associations never grant filesystem access.

| Permanent id | Method | Grant | Result |
| --- | --- | --- | --- |
| 100 | Query | `workspace.read` | Epoch, cursor and group snapshot |
| 101 | Watch/resume | `workspace.read`, `workspace.events` | Cursor, retained events or snapshot-reset flag |
| 102 | Rename group | `workspace.groups.write` | Recorded operation outcome and updated group |
| 103 | Lookup operation | `workspace.read` | Known outcome or explicit unknown |
| 200 | Group changed notification | Established watch | Epoch, sequence and updated group |

Field ids are declared beside the records in `WorkspaceProtocol.hx`; ids are
never reused. The schema uses MessagePack through concrete typed method codecs.
Protocol/codec compatibility is handled by the Haxeon handshake. This initial
capability advertises the complete fixed schema; future event variants need a
new negotiated capability or protocol version before emission.

## Recovery

`WorkspaceReplica.restore(connection, isCurrent)` is explicitly called after a
fresh handshake, normally from `RpcClient`'s ready hook with its generation guard.
The replica keeps its epoch/cursor and resumes retained events. Old connection
callbacks and superseded recovery responses cannot replace its state.

A new epoch or expired/future cursor establishes live delivery first and then
queries a snapshot. Events received during that query are bounded and buffered;
only events after the snapshot cursor are applied. Live sequence gaps make the
view unready. The host explicitly calls `recover()` for a fresh watch/snapshot;
buffer overflow closes the connection so ordinary reconnect can recover. A
lost final event is detected by the next sequence or by explicit reconnect/resume;
there is no periodic catch-up timer in this first slice.

The service retains at most the configured event history (default 32 events),
32 groups, with default limits of 16 bound clients and 256 committed operation
outcomes. RPC and adapter
message/queue limits apply independently. Choose message limits large enough for
the permitted snapshot and replay payloads. Group ids/names and cwd strings have
size limits. One watch per connection is replaced by an explicit resume request;
a watch never creates a terminal or agent resource. Stalled observers cannot
block other connections and close on RPC output queue overflow.

## Mutation uncertainty and retention

Rename requires the service epoch, a caller-owned operation id and expected group
revision. The service commits the group, sequence and outcome together in one
non-interleaved event-loop action before replying or publishing. Repeating the
same operation returns the original outcome without a second event/revision;
a different payload with that id is an `operation_conflict`. New operations with
stale revisions fail before mutation.

After a lost reply, query the operation outcome. Unknown means execution remains
uncertain, especially across a service restart; it never means safe to repeat
blindly. The service keeps all committed outcomes for its epoch and rejects new
mutations with `operation_limit` when retention is full, rather than evicting
outcomes silently. Storage is currently in memory. Restart must use a new opaque
epoch, invalidating old mutation requests and replay cursors. The daemon's durable
store must atomically persist state and outcomes and define retention before this
becomes a durable workspace mutation API. No process-restart or exactly-once
network delivery guarantee is claimed.

Run `haxeon run --project tests/haxeon-rpc/haxeon.json` for the native consumer and
`bash scripts/test-workspace-rpc-wasm.sh` for the same workspace scenarios on both
Wasm targets. Both checks are registered in `scripts/test.sh`.

## Real transport boundary (RPC.2 first slice)

`src/workspace/transport/` adapts NativeKit local sockets and native/browser
WebSockets to the same Haxeon `MessageTransport`/`RpcClient` API. NativeKit exposes
ordered bytes even for WebSockets, so every payload uses HMPK framing. A shared
NativeKit event subscription transfers accepted/connected owned handles; it never
runs a competing event pump. Canceled attempts are removed before closing the
handle, completed attempts no longer own their transferred transport, and stale
handle generations cannot publish a new connection.

Local listener admission uses NativeKit's private-path/same-user checks. Browser
and native WebSocket admission first exchanges a caller-generated 256-bit session
credential and an acknowledgement in framed payloads. The service creates its RPC
handshake only after authentication, then binds only negotiated capabilities.
Invalid credentials are a terminal refusal; disconnect/timeouts remain retryable.
WebSockets bind only to loopback here. This is not encrypted remote authentication,
relay authorization or browser-origin policy for a shipped remote endpoint.

Limits: 32 hub streams, four listeners, 16 server peers, 256 KiB messages,
1 MiB native send/receive queues, 16 KiB reusable receive storage, 32 KiB consumed
per transport receive call, and 32 RPC messages/256 KiB per peer poll. Authentication
expires after five seconds. A rejected peer cannot consume a privileged RPC slot.
Browser send admission accounts for `WebSocket.bufferedAmount`; buffering internal
to the browser remains outside application control.

Receive feeding uses the reusable buffer directly, retaining unread offsets and
transferring completed payload ownership without an extra framing copy. Framing
still allocates the assembled payload; outgoing framing and native send queues
copy. GC Wasm additionally bridges mutable receive storage between GC and native
linear memory. NativeKit's receive buffer annotation makes capacity implicit and
ensures writes are copied back; an unannotated pointer was insufficient on GC Wasm.
No end-to-end zero-copy claim is made.

The native test verifies socket/WebSocket query, cursor recovery, ambiguous lost
mutation reply and outcome lookup without replaying the mutation, plus canceled
connection churn and terminal credential refusal. The Chrome fixture uses the
same Haxeon client on Wasm32 and Wasm GC against a separate headless agent process:
initial snapshot, suspension/reconnect in the same epoch, then process restart
with a fresh epoch and snapshot restoration. See [agent/README.md](../../agent/README.md)
for commands and bootstrap limits. Android, wide-area relay access, durable
outcomes, runtime resource reconciliation and frozen evolution vectors remain.
