# Workspace filesystem protocol

Status: planned, not implemented. Required by [M16.2](16-remote-workspaces.md).
Use shared typed Exosuit schemas over Haxeon RPC; filesystem semantics are not
part of Haxeon's generic RPC package. Reuse the existing workspace index,
search, filesystem and watcher implementations behind this service interface.
Local adapters and RPC adapters implement the same operations. Local editor
buffer edits remain in-process, without a request per keystroke.

## Addressing and access

`FileRef` contains `workspaceId`, `rootId` and `relativePath`. Root ids are
service-issued opaque identities; clients get names and display metadata, not
permission to supply arbitrary host absolute paths. Empty relativePath denotes
the root. Paths use slash-separated segments; reject absolute/drive/UNC paths,
NUL, dot/dot-dot and platform-invalid segments rather than silently rewriting
ambiguous input. RPC paths are values, never URL-decoded a second time.

Preserve filename case and Unicode spelling; do not globally normalize case or
Unicode. The platform adapter determines alias/case behavior. Disambiguate
identical root names by id. Native filename bytes that cannot be represented
losslessly as protocol strings must be marked unsupported or use a separately
negotiated opaque addressing capability; never silently substitute characters.

Resolve against an authorized root and verify containment at the actual open,
not only at string normalization. Follow symlinks only when the resolved target
stays within that root; an external target requires its own explicitly granted
root. Detect loops and bound resolution depth. Reuse/extend NativeKit generic
handle-relative access where needed to avoid symlink-swap and root-replacement
races. A realpath check followed by an unrestricted open is insufficient.

Check device/user/workspace grants on every operation and subscription delivery.
Revocation cancels outstanding work and closes affected read/watch resources.
Expose regular files/directories/symlinks only; refuse devices, FIFOs and sockets
for content reads. Permissions never follow from possession of a root or handle
id. Errors must not disclose unauthorized paths or file contents.

## Methods and typed values

Names below are semantic API names; assign permanent numeric method/field ids
in the shared schema registry during implementation and retain protocol vectors.
Use Int64 for byte sizes/offsets and event sequences. Revisions are opaque tokens
scoped to service/root epoch, never timestamps or bare mtime/size tuples.

| Method | Input | Result |
| --- | --- | --- |
| `files.roots` | Workspace id | Authorized root descriptors and capabilities |
| `files.stat` | FileRef | Kind, size, timestamps, revision and access metadata |
| `files.list` | Directory FileRef, page limit, optional cursor | Entries, directory revision, next cursor |
| `files.readOpen` | FileRef, optional expected revision | Connection-owned read handle, observed revision, size |
| `files.readChunk` | Read handle, byte offset, bounded length | Bytes, revision and EOF |
| `files.readClose` | Read handle | Released handle acknowledgement |
| `files.subscribe` | Root/subtree scopes, optional resume cursor | Subscription id, epoch and acknowledged cursor |
| `files.unsubscribe` | Subscription id | Closed subscription acknowledgement |
| `files.searchStart` | Root scopes, file/content query and options | Connection-owned search id and generation |
| `files.searchPage` | Search id, optional cursor, result limit | Bounded results, next cursor, completeness and skipped summary |
| `files.searchCancel` | Search id | Cooperative cancellation acknowledgement |

All handles are opaque, bounded, owner-scoped, idle-expiring and invalidated on
connection loss. Reconnect opens new read/search handles; it does not implicitly
repeat their old calls. Typed errors include not_found, permission_denied,
unsupported_name/type/query, invalid_path/range, revision_changed,
cursor_expired, resync_required, cancelled and resource_limit. Unknown handles
must not reveal another client's resources.

## Directory listing

Use stable platform-independent ordering (directories first, then exact UTF-8
name order with a stable tie-breaker). Cursors bind scope/filter/order, root
identity and directory revision. Bound retained listing state; directory change
or expired state invalidates the cursor explicitly. Do not silently mix pages
from different directory versions. Re-list after invalidation; client expansion
state is independent of service listing state. Include link and inaccessible
entry metadata without reading targets eagerly.

## File reads and revisions

Serve saved filesystem bytes; desktop unsaved drafts are a separate future
capability. Byte offsets are not character offsets. Return raw Bytes; client
text decoding preserves partial multibyte sequences across chunks. Report
encoding/binary hints without silently converting file content. Invalid text
remains inspectable as bytes or an explicit unsupported text display.

A read handle pins identity, not an automatically immutable file snapshot.
Detect concurrent modification and return revision_changed; the client discards
partial assembly/reopens rather than combining incompatible chunks. Establish
identity at open and verify around reads; mtime/size alone is not a sufficient
revision check. Define and test a bounded snapshot/content-verification strategy
for stable file views. If a platform cannot prove a coherent read under concurrent
external writes, return a consistency limitation/error instead of claiming a
snapshot. Files too large for snapshot budgets need negotiated weaker live-read
semantics or a clear size refusal. Choose the concrete strategy before accepting
files.read; do not hide this behind an opaque revision token.

Bound chunk length (initial maximum 256 KiB), active handles, cached snapshots
and aggregate bytes per client. Close/cancel releases resources. No bulk whole
project transfer or eager re-read on every event. Revisions change on content or
identity changes, and are invalidated after service/root epoch changes. Local
service mutations may use monotonic counters; external changes require explicit
reconciliation and content verification appropriate to promised consistency.

## Watching and reconnect

Events contain subscription id, service/root epoch, sequence, FileRef, kind and
available revision. Kinds include created, changed, removed, renamed and
invalidate. Rename pairing is best-effort: platforms may report remove/create.
The sequence describes service publication order, not every OS write.

Subscriptions establish the cursor before initial listing/reads. Clients stage
incoming events while fetching initial state and revalidate affected entries;
this avoids a list-then-subscribe race. Resume from an acknowledged cursor only
within the matching epoch and retained event window. A gap/overflow, watcher
failure or service/root replacement sends invalidate/resync_required; rebuild
affected listings and reopen files. Never claim native watchers are lossless.

Use bounded event retention, coalescing and a bounded polling/reconciliation
fallback where native watching is absent. Poll fallback and native watcher
capabilities are visible. Exosuit owns cursor persistence and snapshot recovery;
Haxeon RPC reconnect merely restores explicitly resumable subscriptions.

## Search

Share the existing workspace search engine. File search and content search
have distinct typed queries; root/glob/ignore options stay within grants.
Default to existing project ignore rules and expose explicit overrides. Do not
accept arbitrary user regex syntax unless the engine can bound its work or
interrupt it safely; advertise supported query capabilities.

Page results and bound file sizes, concurrency, bytes scanned, result count,
execution budget and retained search state. Cancellation retires pending work.
Each content match carries FileRef, file revision and typed location with an
explicit coordinate convention (zero-based line plus UTF-8 byte column/range).
The client maps this to its text model; do not conflate UTF-16, bytes and graphemes.
Search is best-effort across files, not an atomic workspace snapshot. Return
truncation, incomplete coverage and permission/read failures as bounded summaries.
Revalidate match revision when opening; changed results require refresh.

## Acceptance and implementation slices

- [ ] F1: schemas, root grants, path resolver and paginated roots/stat/list.
  Tests cover multiple roots, Unicode/case, invalid paths, traversal, external
  symlinks, symlink swaps, root replacement, loops, special files, revocation
  and cursor invalidation. Unsupported native names have explicit outcomes.
- [ ] F2: bounded coherent reads, handles, revisions and byte-to-text display.
  Tests cover multibyte chunk boundaries, empty/binary/large files, replacement,
  in-place writes, same-size preserved-mtime writes, truncation, cancellation,
  disconnect and cross-client handle refusal. No mixed-revision display.
- [ ] F3: watch subscriptions and reconnect. Tests cover initial fetch races,
  duplicates/coalescing, missing rename pairs, overflow, retention gaps, polling
  fallback, server restart and Wi-Fi/mobile-style reconnect. UI drops stale data
  and resyncs visibly when required.
- [ ] F4: bounded file/content search. Tests cover ignored directories, scoped
  access, cancellation, result/scan limits, stale locations and Unicode offsets.
  Flooded read/search/watch traffic leaves terminal/approval control responsive.
- [ ] F5: desktop/local and connected-browser acceptance using the same service
  operations. Both Wasm targets preserve standalone gates; relay carries opaque
  encrypted payloads without filesystem-specific logic or storage.

Writes, rename/delete/create, upload and remote editing are outside this initial
read/watch/search API. A later slice specifies expected revisions, transactional
saves, operation-id reconciliation and conflict UX. This plan does not grant
remote clients unrestricted OS access or imply files are readable while the
machine/service is offline.
