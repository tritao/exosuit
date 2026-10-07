# Workspace filesystem protocol

Status: Linux F1 and the first F2 read-handle slice are implemented, with a
basic Linux desktop F3 change-invalidation path; F1–F3 acceptance is incomplete
and F4–F5 remain planned. Required by
[M16.2](16-remote-workspaces.md). The
Exosuit service uses shared typed RPC schemas; filesystem semantics are not
part of Haxeon's generic RPC package. Local adapters and RPC adapters will
share operations, while editor buffer edits remain in-process.

The current slice adds an optional NativeKit filesystem module with pinned
root handles and race-resistant Linux path resolution, Haxeon wrappers, and
an agent service with `roots`, `stat` and paginated `list`. The service accepts
up to 16 configured authorized roots; AgentMain currently configures one. Each
connection must hold `workspace.files.read`; cursors are connection-owned,
capped and idle-expiring. A directory listing retains a bounded immutable copy
of the entries it observed, so retries cannot mix pages. Its revision
fingerprints that returned metadata set; it is not a file-content revision or
a point-in-time filesystem transaction. Concurrent changes during enumeration
may require a fresh listing. Later changes invalidate the desktop Explorer's
root listing through the basic Linux watch path described below.

F2 adds root-scoped regular-file handles and typed `readOpen`, `readChunk` and
`readClose` RPCs. A handle pins the opened identity; each chunk checks the
identity, size, mtime and ctime-derived revision before and after reading.
Chunks are capped at 256 KiB, with eight handles per connection and a 30-second
idle expiry. A detected change retires the handle and returns
`revision_changed`. This streams bytes without copying an entire file into a
server snapshot. It is a revision-checked live read, not an atomic filesystem
snapshot; timestamp precision and concurrent external writes remain platform
limits. Revocation and connection cleanup close owned handles.
The shared `WorkspaceFileClient` maps these typed calls over any RPC
connection; local attachment exposes it only when the file-read grant exists.
The Linux desktop explorer now uses this client for root discovery and paged
directory browsing. Single-click opens a preview tab, double-click keeps it,
and saved files display in a selectable, read-only text surface. The first UI
slice caps each preview at 16 MiB, concurrent reads at two, and retained remote
preview content at 32 MiB across 24 tabs. It rejects invalid UTF-8 and
NUL-containing binary data instead of silently decoding it. If a listed file
changes before open, the client retries once against the current revision;
chunks must still match that revision. Desktop previews now use the shared
syntax registry and apply token colors to visible text ranges. A Refresh action
re-stats and rereads the saved file, replacing only the same still-open tab and
retaining the last snapshot with an error if refresh fails. Live change
notifications now invalidate remote listings and mark open snapshots as
changed on disk; the user still triggers Refresh. The Explorer resets remote
listings after a connection replacement, retries expired page cursors from a
fresh listing, and bounds its retained cache to 256 directories and 32,768
entries. The authenticated web build now exposes the same remote Explorer and
preview path when `workspace.files.read` is granted; standalone browser files
remain local. Connected-browser preview and live change invalidation now pass
against AgentMain for both wasm32 and wasm-gc, including a second notification
after relay reconnect; the existing preview stays intact and is marked stale
until the user refreshes. This does not complete F1–F5 filesystem acceptance.
Remote editing remains out of scope.

The current Linux desktop watcher subscribes per root, coalesces native events
over 100 ms and publishes only a root epoch/cursor, never host paths or file
contents. The Explorer drops cached pages for that root and shows a changed-on-
disk notice on its open snapshots. A reconnect with a mismatched epoch/cursor
requests a full root resync; the service does not retain/replay event history.
This is invalidation, not automatic file reload. Watcher overflow invalidates
all roots. Connected-browser delivery now has a basic acceptance that changes a
file on AgentMain before and after relay reconnect, observes the stale-preview
marker and confirms the Explorer revision advances after its watch is restored.
Non-Linux backends, event replay, narrower subtree/path events and full F3
race/overflow/reconnect qualification remain open.

The secure NativeKit backend currently requires Linux `openat2`; it fails closed
when unavailable, and other platforms return `unsupported`. Multiple roots are
supported by the service and contract tests, but AgentMain currently publishes
one configured root per workspace. Non-Linux secure backends and remaining F1
acceptance cases are still open. The Linux desktop and connected web client use
valid UTF-8 syntax-colored read-only previews; Linux desktop has root-level
change invalidation. Search, full F1–F5 browser qualification and full F3
acceptance remain open.

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
name order with a stable tie-breaker). Cursors bind scope/filter/order and root
identity to a retained listing result. Bound retained listing state; expiry,
revocation or root closure invalidates its cursors explicitly. Pages from one
cursor stay on that immutable result even if the directory changes; a fresh
listing observes later changes. The metadata fingerprint identifies the
returned entry set, not an atomic filesystem view. Client expansion state is
independent of service listing state. Include link and inaccessible entry
metadata without reading targets eagerly.

## File reads and revisions

Serve saved filesystem bytes; desktop unsaved drafts are a separate future
capability. Byte offsets are not character offsets. Return raw Bytes; client
text decoding preserves partial multibyte sequences across chunks. Report
encoding/binary hints without silently converting file content. Invalid text
remains inspectable as bytes or an explicit unsupported text display.

A read handle pins identity, not an automatically immutable file snapshot.
Detect concurrent modification and return revision_changed; the client discards
partial assembly/reopens rather than combining incompatible chunks. The Linux
slice pins identity at open and checks identity, size, mtime and ctime-derived
revision around each chunk. This detects ordinary in-place writes, including
same-size writes that preserve mtime, while acknowledging filesystem timestamp
precision. It does not claim a point-in-time snapshot. Other platforms must
provide equally clear consistency semantics or report the limitation instead
of claiming a snapshot.

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

- [ ] F1: schemas, multiple root grants, path resolver and paginated roots/stat/list.
  Tests cover multiple roots, exact UTF-8 ordering/case, invalid paths,
  traversal, external symlinks, symlink swaps, root replacement, loops, special
  files, revocation, stable cursor retries and expiry. Unsupported native names
  have explicit outcomes.
- [ ] F2: bounded coherent reads, handles, revisions and byte-to-text display.
  Tests cover multibyte chunk boundaries, empty/binary/large files, replacement,
  in-place writes, same-size preserved-mtime writes, truncation, cancellation,
  disconnect and cross-client handle refusal. No mixed-revision display. The
  Linux desktop preview currently reads up to 16 MiB, validates UTF-8, rejects
  binary content, uses the shared syntax registry for syntax coloring and has
  explicit refresh; automatic reload after a change remains open.
- [ ] F3: watch subscriptions and reconnect. A basic Linux desktop path now
  coalesces NativeKit events into root epoch/cursor notifications, invalidates
  listings and marks open snapshots stale; connected-browser acceptance also
  verifies AgentMain changes reach the browser before and after relay reconnect.
  Neither path auto-reloads file text.
  Full tests cover initial fetch races, duplicates/coalescing, missing rename
  pairs, overflow, retention gaps, polling
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
