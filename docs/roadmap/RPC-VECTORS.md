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
