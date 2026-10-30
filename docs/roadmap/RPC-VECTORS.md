# RPC v1 compatibility vectors

All hex below is canonical MessagePack output. RPC envelopes are single-entry
maps: permanent variant id -> positional argument array. Records use permanent
numeric field ids, in ascending order when encoded. Integers use their smallest
MessagePack representation; payloads are binary, not embedded MessagePack values.
Independent manually constructed vectors are checked by `RpcCompatibilityTests`
on native, Wasm32 and Wasm GC. Both encode and decode/re-encode must agree.

| Value | Canonical hex |
| --- | --- |
| hello | `8101940101a6746573742f3191ae776f726b73706163652e72656164` |
| welcome | `8102940101a76167656e742f3191ae776f726b73706163652e72656164` |
| refused | `8103918301ae756e6b6e6f776e5f6d6574686f6402ae756e6b6e6f776e5f6d6574686f6403c2` |
| request | `8104940164cd03e8c4048101a177` |
| response | `81059201c400` |
| failed | `810692018301ae756e6b6e6f776e5f6d6574686f6402ae756e6b6e6f776e5f6d6574686f6403c2` |
| cancel | `81079101` |
| notification | `810892ccc8c400` |
| query w | `8101a177` |
| identity w, /w, i (method 104 response) | `8301a17702a22f7703a169` |
| snapshot e, cursor 0, group g/Work/null/1, nullable parent/order | `8301a165020003918601a16702a4576f726b03c0040105c006c0` |
| rename w/e/op/g/1/New, nullable tree fields | `8a01a17702a16503a26f7004a167050106a34e657707c008c009c00ac0` |
| framed query | `484d504b0100000000048101a177` |

Hello uses protocol/codec 1, application `test/1`, capability `workspace.read`;
Welcome uses application `agent/1`. Error code/message are `unknown_method`,
ambiguity false. Request has id 1, method 100, timeout 1000 and the query payload.
Response and notification have empty binary payloads; notification method is 200.

## Evolution rules

Never reuse method, variant or record field ids. Unknown record fields are skipped
recursively; map order on input is not significant. Non-null structured object/enum fields
without defaults are required. Missing nullable fields default to null. Existing
primitive/collection wire defaults are zero/false, empty strings/bytes and empty
arrays/maps. These defaults are deliberately frozen here. Application
validation must reject defaults that violate its domain: request id/method/timeouts
must be positive, workspace/epoch ids must be nonempty and bounded, and rename
revision must be positive. An omitted snapshot group array defaults to empty. Presence of a scalar alone
is not an authorization or feature signal. Added fields must be nullable or have a
compatible default; do not add required fields to an existing capability schema.

Enum variants have fixed positional arity. Unknown variants and changed arity
are rejected; new variants require a negotiated capability/version before use.
Known variants with unsupported protocol/codec numbers receive an explicit
handshake refusal (`unsupported_protocol`/`unsupported_codec`). HMPK framing
version and flags are checked independently before payload decode. Invalid types,
missing required structured objects, null non-null values and trailing bytes
fail decode.
An absent/defaulted workspace id is rejected by service validation as `invalid_request`.

After handshake, unknown method, invalid request body, absent workspace and denied
grant produce `unknown_method`, `invalid_request`, `unknown_workspace` and
`unauthorized` method errors. These validation failures have ambiguity false,
retire only that request, leave workspace state unchanged and permit later calls.
Disconnected mutations still retain their separate documented ambiguity semantics.
JSON is a diagnostic representation and does not redefine these MessagePack bytes.

These are frozen vectors for the first catalog schema, not a promise that new
terminal/file/provider schemas already exist. Future schemas add their own vectors.


## Terminal records

The native and both portable Wasm fixtures freeze these independently specified
MessagePack vectors (workspace `w`, instance `i`, terminal `t`):

- Target: `8301a17702a16903a174`.
- Output request at Int64 offset 4294967298:
  `8401a17702a16903a17404d30000000100000002`.
- Input sequence 1 with binary bytes 00 01:
  `8501a17702a16903a174040105c4020001`.

Terminal methods use IDs 110–114; field IDs are permanent in
`WorkspaceTerminalProtocol.hx`. These vectors extend the catalog compatibility
fixtures without changing existing method or field identities.


Terminal catalog vectors (methods 115–117 use permanent identities):

- First page query, workspace `w`, instance `i`, null after cursor:
  `8301a17702a16903c0`.
- Rename terminal `t` to `N`, group `w`, expected Int64 revision 4294967298:
  `8601a17702a16903a17404a14e05a17706d30000000100000002`.

These run in the same native, Wasm32 and Wasm GC compatibility fixtures.

Ordered terminal replay uses method 138 with a record cursor, separate from the
output byte offset. Records contain a sequence, byte offset, binary data and
columns/rows. Empty data denotes an accepted resize; output records have zero
columns/rows. The initial record establishes geometry. Each response is bounded
to 128 records and 64 KiB of output. Repeated resizes at the same byte offset
remain distinct, and lifecycle state follows the final replay batch.

Snapshot method 119 adds optional field 3 for the next record cursor, captured
atomically with the screen and byte offset. A trimmed journal produces
`replay_gap`; the client restores that snapshot before resuming replay. Clients
apply geometry from replay records, never from current-state metadata or
unacknowledged resize requests. Daemons without method 138 use atomic screen
snapshots rather than replaying historical bytes at current dimensions. Existing
byte-only method 111 and its vectors retain their identities.

Terminal OPEN (110) adds optional field 9, `watch`. A daemon supporting change
notifications returns optional TerminalInfo field 12, `notifications: true`.
Opted-in read-authorized connections receive notification 139 with a TerminalTarget
(workspace, service instance, terminal id) when output, geometry, lifecycle,
control ownership, or terminal metadata changes. Changes coalesce per terminal
per daemon tick; replay remains the authoritative ordered stream. Notifications
received during replay keep the terminal dirty until another replay drains it.
Idle subscribed clients issue no output reads. Reconnect registers a new watch
and resumes replay from the retained cursor. Method 155, UNWATCH, removes a
connection's terminal watch; disconnect also removes it. Panes share one router
per connection and only the final pane unwatches a shared terminal. Older daemons
ignore the new OPEN field and retain the polling/snapshot fallback.

`TerminalReplayTests.hx` and `TerminalServiceTests.hx` cover replay ordering,
geometry-only events, coalescing, reconnect, read-only viewers, malformed batches,
exit ordering, bounded retention, snapshot recovery and legacy daemons.


## Group tree extension

The legacy four-field group/six-field rename vectors still decode. Current codecs
also encode the nullable tree fields; legacy decoders skip those unknown IDs.
Method 105 requires `workspace.groups.tree` and uses create/update rather than
overloading method 102's rename behavior.

| Value | Canonical hex |
| --- | --- |
| create group w/e/op/g/0/N, parent work, cwd null, order 2 | `8a01a17702a16503a26f7004a167050006a14e07a663726561746508a4776f726b09c00a02` |
| open terminal w/i/t, create, 80×24, group g, directory /w | `8801a17702a16903a17404c30550061807a16708a22f77` |

Native, Wasm32 and Wasm GC also encode a conservative maximum-Unicode catalog with
32 groups and six terminal records and assert its size stays within 262144 bytes.


Agent create (method 121), fields workspace/instance/id/group/name/thread:
`8601a17702a16903a16104a16705a5436f64657806c0`.

Agent prompt (method 122), fields workspace/instance/id/action/text/request:
`8601a17702a16903a16104a670726f6d707405a2686906c0`.

Native and portable fixtures also check six-record Unicode agent catalog pages
and maximum bounded activity/request views against the 262144-byte envelope cap.

The maximum agent-view check includes optional structured items (field 5) and
older-item omission (field 6). It also checks legacy views with no items and a
structured round trip on each supported wire target. Item retention is capped at
8192 total characters across fields, in addition to the existing activity and
request bounds.


## Workspace refs and the catalog watch (M19 Phase 0)

Status: **proposed, pending the mobile-app review.** The ids below are reserved and frozen by
`RpcCompatibilityTests.catalogVectors`. No service implements them yet, so nothing changes behaviour.

`WorkspaceRef {1 machine, 2 workspace}` names a workspace by suit's machine id and the workspace's id in that
machine's catalog ([ADR 0006](../architecture/0006-workspaces-without-folders.md)). Folders are attributes of a
workspace, not its name. Every new request carries a ref. Existing requests (methods 100–169) keep their
`workspace:String` field 1 unchanged: today every client sends `"workspace"`, meaning the connection's service.
From M19 Phase 4 that field carries `ref.workspace`, and `"workspace"` stays an alias for the connection's own
service. No existing method or field id changes.

The catalog watch is negotiated as `workspace.catalog` (`WorkspaceCatalogProtocol.hx`):

| Id | Kind | Shape |
| --- | --- | --- |
| 170 | method `CATALOG` | `CatalogQuery {1 ref, 2 resume:Null<String>, 3 watch:Bool}` → `WorkspaceCatalog` |
| 171 | method `UNWATCH` | `WorkspaceRef` → `WorkspaceRef` |
| 172 | notification `CHANGED` | `CatalogChange {1 ref, 2 token}` |

`WorkspaceCatalog` fields: 1 ref, 2 instance, 3 token, 4 reset, 5 more, 6 name, 7 folders (possibly empty),
8 scratch (nullable), 9 status, 10 attention, 11 groups (`WorkspaceGroup`), 12 sessions, 13 terminals,
14 removedGroups, 15 removedSessions, 16 removedTerminals, 17 watching.
`CatalogSession`: 1 id, 2 name, 3 group, 4 directory, 5 provider (null is Codex), 6 state, 7 attention.
`CatalogTerminal`: 1 id, 2 name, 3 group, 4 directory, 5 state, 6 exitCode, 7 available, 8 revision (Int64),
9 agentProvider, 10 attention.

Rules:

- A catalog holds no content: no activity, output or file data. Clients read those with the existing methods.
- No `resume`, or a token the service does not know (another instance, or trimmed), gives `reset: true`: the
  reply replaces everything the client holds. A known token gives what changed after it: records to upsert and
  ids to remove. `token` resumes after the page it came with. Tokens are opaque and at most 128 characters.
- Pages reach devices through the relay, whose messages are at most `RelaySocketLink.MAX_MESSAGE_BYTES` (about
  64 KiB). So an encoded page is at most `PAGE_BYTES` (48 KiB), and holds at most `PAGE_LIMIT` (24) folders,
  groups, sessions, terminals and removals together. The service adds items while `fits(page)`. The workspace's
  own fields and one worst-case item of every kind fit one page, so every page makes progress.
- `more: true` means call again with the new token at once. `reset` is set only on the first page of a reset;
  the pages that follow it through `more` belong to the same reset.
- `folders` is sent only in a reset, split across its pages when it does not fit one (sixteen folders at the
  4096-byte path bound do not), and the client joins the pages' folders. Any change to the workspace's name,
  folders or scratch folder makes the next read a reset. Outside a reset `folders` is empty and means nothing.
- `watch: true` registers the connection for `CHANGED`. These are the same connection-scoped notifications as
  terminal open's `watch` (139): coalesced per service tick, only a hint, and removed by `UNWATCH` or
  disconnect. A client that receives a token equal to its own skips the read.
- `directory` is the working directory resolved when the session or terminal was created. It goes in as agent
  create field 11 or terminal open field 8, and the service keeps it as `AgentRecord.cwd` or
  `TerminalRecord.cwd`.
- A session's `attention` counts its pending requests, plus one when its state is `needs-attention`. The page's
  `attention` counts the whole workspace.
- A ref with an empty or over-long id, or an empty or over-long `resume`, is `invalid_request` (`validQuery`). A ref the service does not serve is
  `unknown_workspace`. Until clients learn workspace ids (the editor from suit, devices in Phase 9), a service
  treats workspace id `"workspace"` on its own machine as itself and replies with its real ref.

| Value | Canonical hex |
| --- | --- |
| ref m/w (also `UNWATCH`) | `8201a16d02a177` |
| catalog query m/w, no resume, watch | `83018201a16d02a17702c003c3` |
| change m/w, token t | `82018201a16d02a17702a174` |
| agent create w/i/a/g/Codex, directory /d | `8b01a17702a16903a16104a16705a5436f64657806c007c008c009c00ac00ba22f64` |
| catalog m/w, instance i, token t, reset, name N, no folders, scratch /s, running, attention 1, one session a/A/g, /d, codex, idle, watching | `de0011018201a16d02a17702a16903a17404c305c206a14e079008a22f7309a772756e6e696e670a010b900c918701a16102a14103a16704a22f6405a5636f64657806a469646c6507000d900e900f90109011c3` |

The fixtures also fill a page with worst-case records of every kind (ids and names at their bounds in
three-byte characters, folders at 4096 bytes) and check that it fits `PAGE_BYTES` and, in its response envelope,
the relay's message bound.

### suit's `machine` reply, version 2

suit's control endpoint answers JSON, not MessagePack. `machine`, and every op that returns `machine`, replies:

```json
{"ok": true, "machine": {"version": 2, "id": "machine-…", "name": "cube", "workspaces": [
  {"id": "workspace-…", "name": "Notes", "folders": [], "scratch": "C:\\Users\\me\\Exosuit\\Notes",
   "revision": 3, "service": null},
  {"id": "workspace-…", "name": "exosuit", "folders": ["C:\\Users\\me\\projects\\exosuit"], "scratch": null,
   "revision": 1, "service": {"endpoint": "\\\\.\\pipe\\exosuit-…", "pid": 4242, "running": true}}]}}
```

- `folders` may be empty. `scratch` is null until suit has made the scratch folder.
- `revision` counts changes to that workspace (rename, folders, scratch). A version 1 file, or a reply without
  it, reads as 0.
- `service` is the workspace's service, or null when suit does not know one. Phase 0 always reports null. suit
  fills it in once services are keyed by workspace (Phase 4). `MachineCatalog.decodeService` reads it.
- `version` is the reply's own version (`MachineCatalog.REPLY_VERSION`), not machine.json's.
- Clients ignore fields they do not know. `SuitUnitTests.machineReply` freezes this shape.

### Phase 0 and the mobile app

The paused `mobile-app` branch has two clients. Both pair with one workspace service through the relay.

The Kotlin client (`android/app/.../remote/WorkspaceRpcClient.kt`) It handshakes as `exosuit-editor/1`, offering `workspace.read`, `workspace.identity`
and `workspace.agents.read`/`control`. It sends `"workspace"` as field 1 of every request, reads the root and
instance from identity (104), and polls groups (100) and the agent list (120) every second while in the
foreground. It reads and drives sessions with 121–123 and 127/128. It drops every notification envelope
(`if (kind == 8) continue` in `call`), and reads only inside a call.

The Haxe client (`android/haxe-remote/src/`) runs the shared Workbench. `RemoteWorkbench.hx` polls QUERY (100)
every 1000 ms and lists terminals with the terminal catalog (115). `SavedRemoteWorkspace.hx` takes the identity
root (104) as the workspace's one folder: it scopes files (`fileScope`), source control (`"workspace:" + root`)
and, through `RpcWorkspaceWorkbenchClient`, the agent delivery state by that root.

Phase 0 changes none of that. To adopt it, the mobile branch would:

1. Offer `workspace.catalog`. When it is negotiated, replace the one-second polls (100 and 120 in Kotlin, 100
   and 115 in Haxe) with `CATALOG` (`watch: true`), and read again with the last token on `CHANGED`. Keep the
   polls for services without it. The Kotlin client first needs a receive loop that delivers notifications
   between calls instead of dropping them; the Haxe client already has one (`RpcConnection`, as terminal watch
   uses).
2. Send `WorkspaceRef {machine: the paired machine id, workspace: "workspace"}` until it knows the workspace's
   id, then the `ref` from the reply.
3. Build `RemoteWorkspaceSnapshot` from the catalog. Use the workspace's `name` and `folders` instead of a label
   derived from the identity root (a workspace may have no folders), use `CatalogSession.directory` instead of
   `AgentRecord.cwd`, and show `attention`.
4. In the Haxe client, key saved state by the ref instead of the root: delivery state and the source control
   identity by `ref`, file and source control scope by each of `folders`, and a workspace with no folders shows
   the empty state with its `scratch` folder as where new sessions start. The identity root stays the folder of
   the service the connection reaches until Phase 4.
5. Leave session views, prompts, snapshots and discovery (121–128) as they are.

Open questions for the mobile review:

- Should `CATALOG` also be how a device learns the workspaces on a machine (one connection per machine through
  suit, Phase 9), or stay one connection per workspace service as now?
- Do sessions need a last-activity time for sorting, and terminals a source of attention (bell, exit)?
- Are three removal lists better than one list of `{kind, id}`?
- Should identity (104) return the ref too? That would change its frozen vector, so for now it does not.
