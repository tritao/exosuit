# First workspace RPC consumer

The transport-independent implementation lives in `src/workspace/service/`.
It is a headless catalog of named group metadata with optional cwd association;
renaming preserves cwd. It does not yet implement the full nested group model,
project/file access, terminal/agent operations, persistence or a running daemon.
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
