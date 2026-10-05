# Execution ledger

Last updated: 2026-10-05.

## M14.4 — first Codex provider and conversation tabs, 2026-10-05

Daemon-owned Codex adapter uses the installed 0.160.0 CLI / 0.160.1 shared app-server proxy.
Version/initialize checks precede requests. Typed optional agent read/control
capabilities expose catalog/create/action/discovery (120–123); Codex JSONL stays
inside the host adapter. The CLI proxy forwards raw Unix-socket bytes; a bounded
WebSocket/JSONL bridge performs upgrade, masking, fragmentation/control handling
and output draining. Two real shared-daemon clients initialize and query metadata;
one continues querying after its sibling disconnects. Direct JSONL to the raw
proxy was rejected during implementation. New sessions inherit the selected group directory;
explicit discovery is directory-filtered and attachment verifies cwd before
resuming. New-thread sandbox/approval requests are workspace-write/on-request;
existing thread policy and global Codex configuration are preserved.

SQLite v4 migrates existing data and adds bounded agent rows. Reservations precede
thread creation; uncertain creates retain identity. Prompts are never replayed on
ambiguous failure. Reconnect reads metadata, resumes, reconciles the latest active
turn and reads eight recent persisted items. Resolved requests and stale service
instances are fenced. Oversized requests cannot be approved from truncated
summaries; unsupported request kinds remain visible. Catalog pages, activity,
requests, transport queues and per-poll work are bounded.

Workbench groups project terminals and agents together. Conversations use normal
editor-group tabs, including saved resource scope and ordinary close behavior.
Closing a view/editor never interrupts a turn or owns the Codex shared server.
Terminal and agent client contracts remain separate behind a Workbench composition.
The shared host-services package owns the existing platform/process FFI/build once;
both executables consume it without duplicate bindings or daemon UI dependencies.

Deterministic native acceptance covers lazy startup/version checks, streamed items,
approvals/input, read-only fencing, duplicate approval rejection, oversized frames,
large UTF-8 prompts, ambiguous-loss reconciliation, recent history, interruption,
external cwd refusal and SQLite thread identity. The full core suite passes,
including native, Wasm32 and Wasm-GC wire vectors. Self-hosted provider tests pass.
Relocated desktop checks cover conversation creation, prompts, approvals/input,
saved tabs and view closure, plus existing terminal restoration and group cwd.
Real authenticated inference and two-client shared Codex active-turn survival remain pending; no claim is based on
CLI/schema inspection alone. Full history browsing, richer requests/renderers,
agent metadata controls, supervision CLI/wait and Claude remain open.


## M14.1/M14.3 — named directory groups and Workbench tree, 2026-10-05

Haxeon `3e8014be` fixes incremental shared-helper ownership. Required wire/JSON
helpers can remain stored under a source module that becomes unreachable after an
edit; IR assembly previously dropped that module despite calls from retained codecs.
The compiler now closes the generated-helper dependency graph over cached modules,
includes required helper owners in artifact assembly and still prunes unrelated
functions. The reduced MessagePack/JsonWire edit, caller removal/restoration and
changed-schema rejection cases pass, as does the original current/baseline/current
graphical transition in one worker. The full compiler gate passes and refreshed
bootstrap stages converge. No application type weakening or cache-reset workaround.

Workspace groups now carry nullable parent IDs and sibling order. The optional
`workspace.groups.tree` capability gates method 105 for create/full update; method
102 remains rename-only and preserves hierarchy/directory metadata. Existing
revision CAS, operation-id reconciliation, events and SQLite transactions are reused.
Schema v3 accepts existing v1/v2 data and prevents older agents from opening the
expanded mutation journal and independently pinned authorization root. Creation uses expected revision zero. Duplicate names
are allowed; missing parents, cycles, invalid directories and stale writes fail.
The bounded first service still retains at most 32 groups/256 operation outcomes;
the broader domain retention/batch work remains open.

The Workbench sidebar projects groups and terminal resources into UIKit's virtual
TreeView. New group and Edit group support name, parent, directory and sibling
order. New terminal targets the selected group. Open folder explicitly changes the
editor project; group selection alone does not. Tree expansion/selection belong to
the client. The terminal browser remains the metadata/Stop/Remove view.

The owning machine resolves launch directories: explicit override, nearest ancestor
directory, then workspace root. Canonical existing directories must remain within
that root, including symlink resolution; missing/outside paths fail visibly.
Current service authorization is one project root, not arbitrary host filesystem
access or a multi-project registry. Moving groups/resources affects organization
and future launches; existing terminals retain their actual cwd. Schema v3 pins the authorized root in
workspace metadata independently of every
group directory. Legacy managed roots are verified/backfilled once during migration;
a failed root migration rolls back, and later group edits cannot redirect ownership.

Terminal records/catalogs identify their owning workspace separately from actual
cwd. Remote view keys, backend attachment and saved typed resource references use
workspace scope, so subdirectory sessions restore against the original daemon.
Older saved references still load. Group drafts pin their service instance/revision
so folder switching cannot apply an old edit to a different workspace.

Six records per catalog page leave room for 32 groups with parents and worst-case
Unicode directories under the 262144-byte message cap. Native/Wasm vectors exercise
that upper bound. Terminal metadata alone has a 16 KiB blob budget; group/journal
blobs retain 8 KiB. Unicode metadata roundtrip and paged aggregation are tested.

Validation: full core suite; native group/terminal persistence, idempotency,
permissions, cycles, stale revisions, two-client events, directory inheritance,
explicit overrides, unchanged running cwd and restart recovery; native/Wasm32/
Wasm-GC wire fixtures; real desktop group creation and subdirectory terminal restore.
Reference and refreshed self-hosted terminal/group fixtures pass, including root
identity independence and rollback of a rejected legacy-root migration. Relocated
runtime qualification passes from a renamed path containing spaces with source
compiler/tree access disabled: real group creation, subdirectory launch, restored
resource scope, catalog discovery without saved tabs and existing-shell reattachment.
NativeKit bindings were extracted during qualification; affected Exosuit, UIKit and
SceneKit consumers now use Haxeon platform/GPU packages (Materia `213d24ef9`).
Unrelated pending web manifest edits and repository pins were preserved.
Codex/provider sessions, multi-project roots, group deletion/drag-and-drop, persistent
tree presentation across launches and durable terminal checkpoints remain open.


## M14.3 — discoverable terminal catalog, 2026-10-05

Terminals now have agent-owned durable metadata in the existing SQLite database:
resource ID, name, group, canonical working directory, originating service instance,
state/exit code and Int64 revision. Schema v1 migrates transactionally to v2 without
resetting group data. Creation commits a starting record before spawning, then a
running record before acknowledgement. Storage failure fences metadata access and
closes any unpublished PTY. Startup marks old running/starting records lost; it never
claims a process survived the daemon. Terminal bytes/checkpoints remain volatile.

The optional `workspace.terminals.catalog` capability supplies list, rename/move
and forget (method IDs 115–117). Eight records per page keep messages bounded,
including long names/directories; clients aggregate at most 256 records. Pages are
an eventually consistent listing, not an atomic catalog snapshot. Rename/move uses
Int64 revision CAS. Forget also checks resource instance/revision, refuses running
resources, releases retained runtime slots and is safe to repeat after removal.
Read-only peers can list but cannot change records. Group membership refers to the
existing named groups; new/nested group creation and tasks remain pending.

The desktop command “Workspace Terminals…” opens a virtualized browser with Open,
name/group editing, Stop and Remove. Listing is independent of saved/open tabs;
Open attaches or focuses a single view. View IDs are scoped to working directory
and resource identity. Saved layouts persist explicit remote ownership and a typed,
escaped resource reference, with compatibility for older terminal rows. This also
allows resource IDs that do not match the application's generated ID prefix.

Haxeon `99893ce3` fixed an inference defect: later optional-constructor uses contextually erased
a nullable concrete initializer to one interface, rejecting another interface
implemented by that class. BodyTyper now lets concrete conditional/switch branches
supply their own type; context still types empty/null-only literals. The reduced
positive runtime case and missing-interface rejection pass with the full compiler
suite (489 runtime cases plus integration/Wasm checks). No casts/type weakening.

Validation: native persistence/detach/permissions/CAS/forget/restart tests; injected
metadata failure before and after PTY spawn; multi-page native-client aggregation;
real desktop discovery/reopen of an unsaved resource; and native/Wasm schema vectors.
The full application core suite passes. Reference and refreshed self-hosted terminal
fixtures pass, as do real saved-tab restoration and a relocated runtime bundle
with spaces in its path and source/compiler access disabled. Bootstrap stages
converged. A broader UI run passed session, editor and zoom phases but stalled at
the language references filter (stage 5); a repeat hit a glyph-atlas upload failure
instead. The committed graphical baseline passed the isolated language phase.
Switching baseline/current source in the same compiler worker then exposed an
incremental wire-helper IR verification failure; the current isolated language
phase passes with a fresh worker. That incremental transition needs a compiler
reducer/fix separately. Neither broad UI run is claimed as a full-suite pass.
Release pins and unrelated edits remain unchanged.

## M14.3 — daemon-owned terminals, 2026-10-05

The Linux folder workspace now opens terminal views through the verified typed RPC
connection. The daemon owns PTYs; saved stable IDs attach the same shell after editor
shutdown. Restored views never silently spawn a replacement. Active PTYs retain the
service without clients; explicit terminal termination permits normal idle shutdown.
Hiding the panel retains its tabs. Folderless terminals still use the local backend.

Methods 110–114 enforce read/control grants, instance identity, idempotent open,
per-connection input sequence and explicit ambiguous-input fencing. Output uses
64-bit offsets, 64 KiB reads and at most 16 MiB retained per terminal. Sixteen records
are permitted per daemon lifetime. Borrowed native output is copied once into owned
chunks; encoding/network copies remain. Server VT responses are centralized, and
remote parser checkpoint event logs are disabled to avoid duplicate history.

Two ownership defects were fixed: source startup passed the lifetime lock into a
persistent compiler worker, preventing immediate restart; it now builds without the
lock and launches the VM directly. NativeKit PTY children now close host descriptors
before exec. The local session also drains the final bounded output reads before
reporting exit, preventing truncation of a large final burst.

Durable terminal history/checkpoints, runtime listing/deletion, named task/group
integration, daemon-crash reconciliation and AI providers remain pending. Release
pins are unchanged. Validation passes: the full headless suite; reference and self-hosted terminal
contracts (all control grants, stale instance, lost-open retry, duplicate input,
replay gap and explicit termination); two-process reattachment across the idle
interval; actual Xvfb desktop continued execution/reopen; native PTY descriptor
isolation; and native/both portable Wasm binary/Int64 vectors. The relocated bundle
also restores the same shell with source/compiler paths disabled. NativeKit fix:
`6cf89618`. No compiler typing changes were required by this slice.

## M14 — idle service lifetime and runtime bundle, 2026-10-05

Catalog-only workspace daemons now stop after 60 seconds without authenticated,
fully negotiated clients. Every client or owned-session interval resets the grace;
startup gets the same grace. Raw sockets and unauthenticated/preflight peers do not
retain a daemon. The shared typed lifetime policy accepts an active-session count
for the future runtime manager; no daemon-owned terminals/providers exist yet, so
AgentMain currently supplies zero. Closing the UI only closes its client; a sibling
or browser keeps the service alive. Explicit `--always-available`, or
`EXOSUIT_AGENT_ALWAYS_AVAILABLE=1`, disables idle shutdown for new daemons. Existing
service policy is not changed by reconnecting clients. An explicit service-stop UI
and live policy changes are not delivered by this slice.

Idle stop closes clients/listeners, SQLite and NativeKit, then reports completion;
the manager removes its owned descriptor, retires the process group, reaps inherited
lock holders and exits 0. Catalog/credentials remain for restart. Short real-manager
acceptance covers an unnegotiated socket, two authenticated clients with one closing,
a fresh grace after last disconnect, retained catalog, restart and detached opt-in
availability. Policy tests cover the exact default deadline and future session
retention; local and authenticated WebSocket tests check negotiated client counts.

Release staging now copies the Python manager, matched agent bytecode/runner and
SQLite library alongside the desktop VM/runtime. The installed editor selects its
own manager; the manager executes its adjacent bundled runner instead of compiling
sources. `stage-runtime.sh` centralizes the runtime copies and staged RPATH changes
used by production packaging and developer relocation acceptance. A moved bundle
(with spaces in installation/project paths) starts and reuses its service with
source/compiler paths disabled, then stops after the default one-minute idle grace
and retains its catalog. Runtime and managed-startup prerequisites are documented.

Reference and self-hosted lifecycle acceptance both pass. Real native local and
authenticated WebSocket client-count coverage passes; the relocated desktop
acceptance covers actual default idle shutdown and shared reuse. The full Exosuit
headless suite passes, including both portable Wasm compatibility gates.

Release revision/dirty-input guards are preserved. The release archive command
refuses the stale Haxeon pin (expected `6d8593d5`, current `5baacfb2`); no pins were
changed and no release archive was published. Relocated current-build acceptance
uses the same staging routine without bypassing those publication guards. M14.3
runtime/provider ownership, checkpoints and resource reconciliation remain open.

## M14 — Linux desktop service attachment, 2026-10-05

The repository desktop now discovers or starts a detached daemon for the active
canonical project directory. Private discovery is validated by a read-only helper
and decoded through typed JsonWire. Negotiation requires read/events/identity;
permanent method 104 verifies workspace, canonical root and manager instance before
snapshot/replay subscription. Wrong roots fail closed; changed instances rediscover.
Concurrent windows share ownership; switching folders retires stale callbacks and
reuses the correct daemon. Closing a client leaves its daemon alive. Status/error
changes use the existing background poll and only request frames when needed.
Release bundles still need launcher/daemon installation; terminal/provider resources
and their lifetime reconciliation remain the next domain work.

Real native acceptance covers concurrent startup, shared reuse, folder switching,
client-independent lifetime, a socket proxy serving the wrong workspace, invalid
private hints and stale-descriptor restart. Reference and self-hosted clients pass.
The actual desktop under Xvfb connects and reuses the same daemon across two windows
with bounded frame counts. Chrome Wasm GC and Wasm32 retain authenticated mutation,
reconnect and durable restart coverage; native and portable identity vectors agree.

Haxeon standard-library `Math.random()` was missing. Commit `5baacfb2` adds the
portable effectful API using the existing integer RNG, preserving explicit purity
on existing Math methods. A failing reducer preceded range, variation and arity
regressions. The full Haxeon gate passes (488 compiler tests plus backend/integration
checks). No application type weakening or fixed-jitter workaround was used.

An immediate manager restart in the full gate exposed a descendant shutdown race:
the database lock could release before the inherited lifetime lock. Linux managers
now adopt and reap owned launcher descendants after retiring the process group,
before reporting shutdown. The existing immediate-restart/lifetime-lock acceptance
passes with that lifecycle fix. The full Exosuit headless suite passes after
the fix, including native and both portable Wasm compatibility gates.

## M14 — durable catalog and managed startup, 2026-10-05

Delivered a typed `WorkspacePersistence` boundary and agent-owned SQLite schema
version 1 using generic `sqlitekit`. Each rename commits its group/revision,
cursor, operation request/outcome and event atomically before replying or publishing;
event trimming is in the same transaction. WAL/FULL durability and per-row typed
MessagePack blobs avoid full-catalog serialization on each rename. Startup restores
the stored epoch, bounded snapshot, all 256 retained outcomes and last 32 events.
Idempotent retries and operation lookup survive process restart; saturation refuses
new operations without discarding old outcomes. Corruption, unknown/unversioned
schemas and stale cursor/revision writes are refused. An ambiguous storage failure
fences subsequent RPC access until reopening.

`scripts/run-agent.py` adds qualified Linux managed startup with canonical-root
identity, private credential/state files, an inherited lifetime lock, exit 3
`workspace_in_use`, generation-tagged discovery after readiness and optional
detached startup. The descriptor publishes a credential path, never the secret.
Normal stop removes owned discovery and retires the process group; abrupt manager
kill cannot unlock its still-live daemon. Device/inode storage replacement stops
the daemon. A full-suite run exposed launcher/child shutdown ordering: cleanup now
waits for the independently owned database lock to release before reporting stop,
so an immediate restart cannot race a surviving child.

Two Haxeon defects were fixed in `7f3f28ce`. Imported named calls now retain their
source receiver path, so a field named after an introduced package root cannot
shadow the imported type. The reference-Haxe reducer passes; regressions preserve
actual source-value shadowing and incremental reanalysis. Running child stdout/
stderr is flushed while forwarding; a blocking-child integration test requires
its readiness message before allowing exit. No application rename/type weakening
was used to bypass either defect.

Validation: full Exosuit `scripts/test.sh`; real SQLite restart, idempotence,
outcome lookup, replay trimming, late-transaction rollback, stale writer/CAS,
retention saturation, corrupt blob and schema refusal; real manager discovery,
duplicate startup, immediate restart, abrupt kill, detached readiness, root
identity and storage replacement. Chrome Wasm GC and Wasm32 clients commit a rename,
reconnect, restart a separate daemon and recover the same durable epoch/revision.
The full Haxeon gate passes: 487 tests, differential/integration checks, both Wasm
backends/parity and Wasmtime. The self-hosted compiler was rebuilt from current
source; the persistence and managed-startup acceptance also passes through it.
Owned format/syntax/diff checks pass. Unrelated web/
editor changes remain untouched; no push, PR or submodule pin changes.

This accepts the first durable catalog/startup slice, not all M14.2/M14.3 domain
or runtime work. Next: typed local descriptor validation and seamless editor
attachment/auto-spawn, then actual terminal/provider lifetime reconciliation.
Nested groups, domain batches, terminal histories/checkpoints, runtime supervision
and volatile terminal mode on storage loss remain open. See
[WORKSPACE-RPC.md](WORKSPACE-RPC.md) and [agent/README.md](../../agent/README.md).

## Haxeon RPC.2 — lifecycle isolation and frozen vectors, 2026-10-05

Real socket admission now verifies reduced capabilities after service policy
replacement, denies attempted writes, and retains that reduction when server write
support returns. Forty completed reconnects exceed the hub's 32-stream and service's
16-client limits without retaining dead slots. Completed-attempt cancellation leaves
the adopted socket open. A real non-draining peer is overloaded with bounded 64 KiB
messages; its queues retire while a sibling's pending and subsequent queries succeed.
`WorkspaceRpcServer` now accepts an optional copied capability policy while retaining
its established framing, message and work limits.

`RpcCompatibilityTests` and [RPC-VECTORS.md](RPC-VECTORS.md) freeze all eight envelope
variants plus query, snapshot, rename and framed query. Independently constructed
MessagePack bytes are checked for encoding and decode/re-encoding on native,
Wasm32 and Wasm GC. Evolution coverage includes nested unknown fields, map order,
missing nullable/primitive/collection fields, required structured objects, null and
wrong-type fields, trailing bytes, unsupported constructors/arity, framing flags,
protocol/codec refusals and explicit method errors with a usable connection afterward.

Compatibility tests exposed an application validation gap, not a compiler defect:
missing primitive strings intentionally decode to empty strings in Haxeon's wire
profile. Query now rejects an invalid workspace id. Rename rejects missing/invalid
workspace and epoch ids as non-ambiguous `invalid_request` before stale-epoch handling;
operation lookup requires a valid epoch too. Missing rename revision still fails
existing domain validation. Granted malformed requests retire without changing
cursor/revision. Complete requests with obsolete epochs retain their prior semantics.
No Dynamic/cast bypass or compiler/runtime change was introduced.

Validation: native RPC compatibility and real lifecycle consumers pass;
`test-workspace-rpc-wasm.sh` passes the same compatibility/service fixtures on both
Wasm targets; `test-workspace-rpc-browser.sh` passes both real Chrome clients through
authentication, suspend/reconnect and agent process restart. `scripts/test.sh` and
owned-file format/syntax/diff checks pass. Unrelated UI/confirmation edits remain
untouched. Repository bases: Exosuit `f59fca9`, Haxeon `46b32640`, NativeKit `01bbc511`;
only Exosuit changes in this slice, with no pushes or submodule pin changes.

RPC.2 transport lifecycle and compatibility items are accepted. Its terminal/agent
resource reconciliation item stays open for M14.3; a catalog connection test is not
PTY/provider lifetime evidence. The plan now separates that prerequisite explicitly.
Next: durable workspace catalog/storage ownership and managed daemon lifecycle,
then real terminal/provider attachment and reconciliation. Method generation and
streaming remain optional until a consumer demonstrates the need.

## Haxeon RPC.2 — real transports and headless bootstrap, 2026-10-05

Delivered `src/workspace/transport/`, a headless `agent/haxeon.json`, real native
socket/WebSocket consumers and a Chrome fixture using the same typed Haxeon client
on Wasm32 and Wasm GC. Shared NativeKit event observation owns/adopts opaque
handles; cancellation removes attempts before late events. Framing and per-poll
work are bounded. Same-user local admission and loopback credential preflight
precede RPC negotiation and capability-gated service dispatch. Credential and
public epoch are independent; each process restart receives a fresh epoch.

NativeKit `01bbc511` annotates the mutable receive buffer and derives its capacity
from the managed buffer. Before this fix, GC Wasm copied an unannotated pointer's
bytes into native scratch memory without copying native writes back; framing then
saw unchanged bytes and disconnected. Existing Haxeon mutable-counted-buffer
support handles the correction; no compiler change or alternate browser protocol
was needed. The first browser run also rejected a listener-only address-reuse flag
on outbound WebSockets; the adapter now sets that flag only for listeners.

Validation: `bash scripts/test.sh` passes, including the newly registered real
transport consumer and portable Wasm service tests. Native cancellation churn,
same-user socket and authenticated WebSocket reconnection, event-cursor restoration,
ambiguous committed rename/outcome lookup without mutation replay, and terminal
credential refusal pass. `bash scripts/test-workspace-rpc-browser.sh` passes all
four Chrome scenarios on both Wasm targets: initialization, authenticated snapshot,
suspend/reconnect preserving epoch, then daemon process restart restoring a fresh
snapshot. NativeKit `tools/test-haxe-bindings.sh` passes ABI32/ABI64 drift checks,
core lifecycle and GPU rendering smoke. Fresh native CMake/CTest passes 28 tests
with one environment-dependent joystick/uinput test skipped (29 registered). The old NativeKit build
cache referred to its former checkout path; tests used a fresh /tmp build instead.
Owned Haxe format, shell syntax, Python syntax and diff checks pass.

Receive feeding avoids temporary slices and transfers assembled payload ownership.
Framing, native send queues and GC/native memory bridging still copy; no network
zero-copy claim. Bootstrap caller owns private directory/credential configuration.
The editor/web product is not yet connected to this daemon. Persistent storage,
workspace lock/discovery, runtime/provider supervision, Android/relay qualification,
resource reconciliation and compatibility vectors remain. RPC.2's first adapter
item is accepted; RPC.2 overall and M14.3 remain open. Exact next action: finish
RPC.2 lifecycle/capability/slow-consumer and evolution-vector acceptance before
building durable workspace/runtime ownership on these verified transports.

Repository ownership: Exosuit stays on `haxeon-uikit-port`; NativeKit's existing
`exosuit-followon` branch was fast-forwarded to its current main HEAD before the
owned binding commit. Haxeon remains `46b32640`, unchanged. Existing UI/confirmation
work, NativeKit dialog changes and unrelated untracked files were preserved;
only owned binding hunks were staged. No pushes or parent submodule pin changes.
Exosuit commit: this ledger is included in the real-transport/bootstrap slice.

## Haxeon RPC.1 — first workspace consumer, 2026-10-05

`src/workspace/service/` now consumes Haxeon RPC with a headless named-group
metadata catalog, typed query, explicit watch/resume, group-change notifications,
expected-revision rename and operation-outcome lookup. Permanent method/field ids
and capability checks live with the service schema. Renames preserve cwd; this
slice does not complete nested groups, project files, terminal/agent operations,
durable persistence or a daemon. Details and usage: [WORKSPACE-RPC.md](WORKSPACE-RPC.md).

The client replica explicitly restores after handshake using a generation guard.
It resumes retained events; a new epoch or expired/future cursor establishes live
watch delivery before snapshot fetching and reconciles bounded concurrent events.
A live sequence gap makes the view unready and explicit recovery fetches fresh
state. Old-generation and superseded recovery callbacks cannot replace the view.
A disconnected replica keeps its last snapshot/cursor but reports unready.

Rename commits the metadata, sequence and operation outcome together in one
non-interleaved service event-loop action before replying/publishing. Identical
operation retries return the original outcome without a second revision/event;
different semantic payloads with the same id fail. Lost replies are reconciled by
outcome lookup. All committed outcomes remain until the epoch ends; retention
saturation rejects new mutations rather than evicting uncertain outcomes. Unknown
outcomes, including after restart, remain ambiguous. Restart requires a new epoch
and rejects old-epoch mutations. This is in-memory atomicity, not durable storage
or an exactly-once delivery guarantee; the daemon store must persist metadata and
outcomes atomically and define retention before durable deployment.

Two valid-code compiler defects were fixed without weakening workspace types:

- Haxeon **1116631b**: field inference accepted only literal array elements. Arrays of statically typed
  constants failed before ordinary expression typing could resolve them. Field
  initializer resolution now recurses through arrays using existing static-field
  and call-result resolution, structural signature comparison and cycle detection.
  A portable nested-array fixture passes, while mixed-element/cyclic arrays still
  fail. Existing compiler signature utilities keep the fix self-hostable.
- Haxeon **46b32640**: incremental pruning retained generic lambdas but dropped nested function adapters
  and their capture environments. `NestedAdapterRetentionMain` reproduces the
  missing IR object on the old compiler and passes after the fix. Retention now
  follows generated-function ownership transitively, excluding children superseded
  by retyping. The reducer also checks that removing the caller prunes descendants.

Native and both Wasm consumer tests cover snapshot races, live events, retained
resume, expired history/snapshot recovery, epoch changes, stale callbacks,
permissions/revocation, ambiguous lost replies, same/different operation-id reuse,
revision conflicts, bounded outcome retention and slow-observer overflow while
another client commits normally. The Wasm consumer is registered alongside the
native suite in `scripts/test.sh`. The final Haxeon `./scripts/test.sh` passes formatting, native build,
**487 compiler/runtime cases**, all integrations, Wasm backend/parity and
Wasmtime. Exosuit native RPC consumer, both Wasm workspace consumers, graphical
build, owned-file format checks and shell syntax checks pass. RPC.1 is accepted
for this transport-independent/in-memory first delivery; M14 and durable daemon
work are not complete. Evidence: `/tmp/haxeon-workspace-rpc-verified.log`,
`/tmp/exosuit-workspace-rpc-final.log`,
`/tmp/exosuit-workspace-rpc-wasm-final.log` and
`/tmp/exosuit-workspace-rpc-graphical.log`. Reduced old-compiler failures:
`/tmp/haxeon-static-array-baseline.log` and
`/tmp/haxeon-nested-adapter-baseline.log`; the static-array example also passes
reference Haxe (`/tmp/haxeon-static-array-reference.log`).

Next: RPC.2 local socket and browser WebSocket adapters, authentication before
privileged dispatch and actual restart/suspend/churn recovery. Build the headless
agent entrypoint around the same service; add durable storage before claiming
persisted group metadata or mutation reconciliation across process restarts.

## Haxeon RPC.1 — handshake and reconnect, 2026-10-05

Haxeon **51eaaa6a** adds immutable peer options, bounded client/server
handshake and a reconnecting client over an asynchronous connector contract.
Protocol and codec versions are independent from the application version.
Capability negotiation intersects offers, checks requirements and rejects
unoffered capabilities. Reconnect can reduce the accepted capability ceiling;
regaining permissions requires an explicit new client/policy decision. Adapter
transport authentication precedes the handshake; service authorization runs
before any privileged connection is published.

Every attempt has a fresh generation. Stale transport completions are closed,
old response contexts cannot respond and accepted calls fail with ambiguity on
disconnect. No request is replayed. Explicit close cancels attempts and disables
retry; connect/handshake deadlines, exponential capped backoff and injected jitter
are deterministic. Authentication and compatibility refusals terminate retries.
The host owns its scheduler, polls on readiness and uses `nextWakeAt()` to arm
its timer. The ready hook exposes the fresh generation for explicit application
resource attachment or subscription restoration; application cursors and gap
recovery are still pending.

Native consumer tests cover synchronous and delayed connection completion,
timeouts, cancellation, duplicate/stale callbacks, refusal delivery, independent
codec/version checks, capability loss/widening, backoff/jitter and an accepted
mutation interrupted before reply. A portable lifecycle fixture also freezes a
Hello MessagePack vector and exercises typed calls and reconnect.

The first full gate exposed a Wasm GC compiler defect: a native static function
used as a callback (`Bytes.ofString`) had no emitted closure target, although its
direct calls worked. A standalone `native-static-codec` reducer covers this valid
code. Haxeon **b7a7672f** makes Wasm GC emit wrappers for address-taken runtime natives, preserving
their declared names and lowering their ABI symbols; the RPC API needs no shim.
The final normal Haxeon `./scripts/test.sh` passes formatting, native build,
**485 compiler/runtime cases**, integrations, both Wasm parity targets and
Wasmtime. The registered Exosuit RPC consumer also passes. Evidence:
`/tmp/haxeon-rpc-lifecycle-full-final.log` and `/tmp/exosuit-rpc-lifecycle.log`.
The failing initial Wasm gate is preserved in `/tmp/haxeon-rpc-lifecycle-full.log`.

Next: consume the runtime with an Exosuit read-only workspace query, sequenced
subscription with cursor/gap recovery and an operation-id mutation whose lost
reply is reconciled without duplicate execution. RPC.1 is not yet complete;
real local/WebSocket adapters and daemon deployment remain later slices.

## Haxeon RPC.1 — typed asynchronous dispatch, 2026-10-05

Haxeon **cb337303** adds typed `RpcMethod<Request, Response>` descriptors,
`RpcConnection` client/server dispatch and retained asynchronous response contexts.
The registry stores byte-oriented closures while the public APIs keep static
request/response typing. Clock injection supplies monotonic millisecond deadlines.
Completion is at most once; cancellation is cooperative, and expired/disconnected
contexts cannot send late responses. The runtime never replays calls. A zero call
id means definitely not dispatched; accepted requests retain uncertainty on
timeout, cancellation or disconnect. Method errors distinguish unknown methods,
overload, invalid payloads and private handler failures.

Limits cover pending callers, active handlers, encoded messages, queued bytes and
message counts, plus work in each poll direction. Handler-generated replies and
notifications share the outgoing poll budget. One bounded incoming message can be
held until the next byte budget. Queue overflow closes the connection rather than
silently losing replies. Failure callback exceptions remain visible after all
disconnect waiters are retired. Each connection is a lifetime boundary; handshake,
reconnect, capability negotiation and application restoration are not yet wired.
Usage and ownership are documented in Haxeon's `docs/RPC.md`; this does not claim
zero-copy encoding or transport.

Three valid-code compiler defects were reduced and fixed, without weakening RPC
types or introducing Dynamic dispatch:

- **4e55fcca**: result-annotated lambdas such as `function(value):Void` are represented
  by parser-generated local bindings. Generic callback inference did not recognize
  that wrapper and lost the expected parameter type. Shared lambda recognition and
  contextual parameter resolution preserve explicit result annotations, optional
  parameters and inferred generic results. Positive/negative, fresh and incremental
  checks pass; the reduced positive case agrees with reference Haxe.
- **6be72179**: lexical capture planning ignored method receivers and function
  callees. A mutable local captured only through calls acquired storage too late,
  losing reassignments made before that capture. The reduced RPC case returned 3
  before the fix and 42 after it. Capture analysis now treats those bindings as
  reads and plans their cells at declaration. Native and Wasm parity cover a
  standalone receiver/callee reassignment fixture; immutable receivers stay direct.
- **74b014cd**: persisted incremental builds pruned nested wire helpers by a single
  recorded origin even when unchanged codecs still called them. The standalone
  integration fixture fails before the fix with an unknown nested decoder call.
  Existing transitive equality-helper retention now also covers MessagePack/JSON
  helpers; both encodings execute correctly after editing the unrelated caller.

Haxeon **a7f80cdd** separately repairs formatting in three unchanged HEAD files
that blocked the required gate. The final normal `./scripts/test.sh` passes:
formatting, native build, differential checks, **483 compiler/runtime cases**,
all integrations, Wasm backend/parity and Wasmtime. Exosuit graphical build and
the registered RPC consumer run also pass. Consumer scenarios include deferred
responses, at-most-once completion, deadline/cancellation races, late queued replies,
accepted reply loss, disconnect before/after dispatch, independent caller/handler
limits, slow consumers, malformed payloads, typed events and incoming/outgoing poll
budgets. Baseline/final logs are under `/tmp/exosuit-rpc-*`,
`/tmp/exosuit-wire-incremental-*` and `/tmp/haxeon-rpc-full-final.log`.

Next: implement a fresh version/capability handshake and explicit client lifecycle,
bounded reconnect backoff/jitter, cancellable attempts and generation fencing; then
Exosuit query/events plus operation-id mutation reconciliation. RPC codec fixtures
across native/Wasm and the complete RPC.1 acceptance matrix remain pending.

## Haxeon RPC.1 — envelope and framing foundation, 2026-10-05

Haxeon **b1bf3d0c** adds permanent-id typed MessagePack/JsonWire envelopes,
structured errors, required-value validation and independent protocol/codec
versions. The bounded message transport specifies ownership transfer; its
in-memory implementation injects accepted message loss without copying payloads.
The incremental HMPK reader bounds payload allocation, queued bytes, queued
messages and input consumed per feed. Callers retain unconsumed input under
backpressure; taking a completed payload transfers it without another copy.
Malformed headers poison the reader until a fresh connection. Frame length
validation now rejects unsigned overflow before allocation, and pack/unpack
arithmetic avoids overflowing the addressable frame length.

Exosuit's `tests/haxeon-rpc` is registered in `scripts/test.sh`. Its native
consumer run passes typed and diagnostic round trips, malformed/oversized
envelopes, every frame split point, coalesced and empty frames, message/byte
backpressure, feed budgets, oversized headers, sticky framing failures, bounded
transport queues, injected loss and peer closure. Owned-file formatting and
diff checks pass. The repository-wide Haxeon format check fails on three
unchanged HEAD files: HlAssemblerStateCodec.hx, DebugMetadataMain.hx and
HotReloadMain.hx. No compiler implementation changes were needed for this slice.

RPC.1 remains active: next implement typed descriptors and asynchronous
dispatch with bounded pending calls, deadlines and cooperative cancellation,
then generation-fenced handshake/reconnect and Exosuit query/event/mutation
reconciliation. Native/Wasm codec agreement and full runtime acceptance remain
pending. This foundation does not claim zero-copy serialization or networking.

## M12.2 — native selection and clipboard copy, 2026-10-05

Vendored libtsm **1902b63** fixes a reproduced heap-buffer overflow in selection
copy: the old four-bytes-per-cell allocation underestimated cells with combining
marks. An unchanged-fork ASan reproducer overflows with a 19-byte single-cell
selection; the same reproducer passes after the fix. Selection copy now measures
UTF-8 and checks arithmetic before writing. New `tsm_screen_selection_copy_into`
uses caller storage, leaves undersized buffers unchanged, and emits neither a
terminator nor the final separator. The original allocating API delegates to it.
Selection endpoints on wide continuation cells snap to the complete glyph.
The selection test's broken dlist macro was fixed. Baseline-reproduced stale VTE
expectations were corrected: copied text omits its final separator, and Kitty
subtracting bit 2 (not bit 1) from 7 produces the asserted 5.

TerminalKit exposes native screen selections and copies directly into binding
storage, without an intermediate native string allocation. TerminalPane captures
left-button drags, uses native highlighting, and copies with Ctrl+Shift+C.
Shift-drag selects while an application owns mouse reporting. A click without a
drag clears selection; copy repeats are consumed without sending Control-C.
Ordinary Control-C still reaches the program. Text/key input and paste return
from scrollback to the live viewport. Selection follows native line identities
when output pushes selected text into history. Checkpoints do not persist this
client-local selection.

Highlighting exposed another defect: inverse default foreground/background
both packed as the same unset value, so swapping them had no effect. The bridge
now emits the existing opposite-default color marker, and TerminalColors decodes
it against the current palette. Explicit ANSI/RGB inversion remains unchanged.

Verified portable ABI audit; native contract/PTY bridge; Haxe session binding;
graphical build; real X11/PTY mouse, paste and selection/copy test. The latter
asserts clipboard text for a first-line and reversed multiline Japanese selection
with application mouse reporting enabled, and differing highlight/background
pixels. Native tests cover reverse, wide-continuation, multiline, scrollback,
clearing and insufficient-buffer behavior. All six functional libtsm static
suites pass under ASan/UBSan. Its intentional leaking Valgrind fixture also
passes separately with leak detection disabled for that fixture only. Shared
Meson test linkage of internal symbols remains a pre-existing build limitation;
no public internal-symbol exports were added. Other platforms remain unqualified.
Next: scrollback search, followed by remaining terminal rendering roles,
process controls and full-screen/performance acceptance.

## M12.2 — native move/wheel modifiers, 2026-10-05

UIKit/materia commit **f05fce913** preserves the window's ordered modifier state
for NativeKit move/wheel events, whose payloads omit modifiers. Key and pointer
button snapshots update the adapter state; modifier-key actions normalize
pre-action (GTK) and post-action snapshots. Held left/right modifier keys are
tracked independently so releasing one Shift does not release the other.
Foreign-window input cannot update state. Focus loss and detach clear it.
No NativeKit ABI change or per-event allocation was required.

Verified the complete UIKit framework smoke, including press/release,
left/right Shift, foreign source, focus-loss and detach regressions. Extended
`scripts/test-terminal-ui.sh` checks real X11 Shift-wheel produces no application
wheel report, while Control-wheel and Control-hover carry their expected SGR
bits through the PTY. Existing button/drag/release/coordinate and clipboard
assertions also passed. Preserved unrelated materia edits, staging only the
adapter and the owned framework-test hunk. Other-platform runtime remains
unqualified. Next terminal selection/copy through the native screen model.

## M12.2 — mouse reporting and tracking ownership, 2026-10-05

Vendored libtsm commit **40a8945** separates active tracking (9/1000/1002/1003)
from encoding (1006/1016). Encoding alone cannot enable reporting; disabling
tracking leaves encoding configured, and disabling encoding falls back to legacy
reports without disabling tracking. Normal tracking rejects drag/motion, button
tracking accepts drags, and all-motion tracking preserves hover modifiers.
Alternate-scroll arrow emulation applies only when tracking is disabled.
The bridge now reads the explicit tracking state instead of inferring it from
encoding. Checkpoint replay reconstructs these states through the existing
recorded output stream; no checkpoint format change was needed.

TerminalPane maps UIKit buttons/modifiers and local padded geometry to bounded
terminal cells. Pointer capture keeps drag/release paired outside the pane.
Wheel input first offers the event to the emulator (including alternate scroll),
then falls back to local scrollback if unhandled. Shift bypasses pointer reports.
TerminalTabView activates during capture but offers its context menu only after
terminal handlers, respecting consumed events. Its previous capture-phase menu
intercepted application right-clicks and subsequent input.

Verified: libtsm mouse suite including the new tracking/encoding regression;
native terminal contract and PTY bridge; Haxe session tests; graphical build;
real X11 raw-PTY test asserting SGR left/middle/right, release, drag, hover,
wheel, Control-click and coordinate bounds, plus clipboard command execution.
The complete libtsm Meson build still fails on a selection-test dlist macro and
internal symbol linkage in VTE/symbol tests. Both failures reproduced from an
unchanged HEAD archive; they are not attributed to this change. Test dependency
packages were extracted under /tmp rather than installed system-wide.

M12 remains open. Next: preserve native pointer move/wheel modifiers in UIKit,
then selection/copy/search and the remaining rendering/process/performance gates.
The pane's Shift-wheel branch exists, but native wheel modifier delivery is not
qualified until that adapter fix lands. Pixel-precision 1016 remains unqualified.

## M12.2 — clipboard and bracketed paste, 2026-10-05

Terminal panes now accept Ctrl+Shift+V through UIKit's asynchronous clipboard
service. A focus generation prevents a pending read from reaching a pane after
focus leaves and returns; closed panes and exited sessions reject delivery.
Key repeats consume the paste shortcut instead of sending Control-V to the PTY.
TerminalKit emits length-delimited input using the emulator's current DEC 2004
mode. Its callback path borrows the caller's bytes without concatenating the
paste wrappers. The queued path reserves the whole message before emission;
over-limit/allocation failures cannot leave an unmatched opening wrapper.
The existing one-MiB pending-reply bound applies to queued paste.

Verified: portable ABI audit for Linux/Windows/macOS triples; native contract
and PTY bridge tests; Haxe terminal-session tests for plain and Unicode
bracketed paste; graphical build; real X11 clipboard shortcut executing a
command through the PTY and writing an asserted fixture marker. Updated the
terminal smoke's stale Open Folder coordinate assertion to check button
presence. Cross-platform runtime and physical IME qualification remain open.
M12 is incomplete: mouse reporting, selection/copy/search, rendering roles,
process controls and full-screen/performance acceptance are still required.
Next implement mouse reporting through the existing emulator/session path.

## M10 — real-server graphical acceptance on Linux, 2026-10-05

Added `scripts/test-real-language-ui.sh` and its hosted graphical test project
to CI. The real server diagnoses invalid source, completes a typed prefix,
navigates to the definition and renames through routed palette text/key events.
Undo/redo verifies the rename transaction. A disposable fixture saves, builds
and executes with exit 42. Repository `ApplicationPaths.hx` undergoes the same
diagnose/fix/completion/navigation/rename cycle through unsaved overlays; undo
restores the buffer and the test verifies unchanged disk content.

This exposed two application defects. Interactive requests shared the five-second
lifecycle deadline; a traced repository completion arrived after 8.8 seconds.
They now use a separate 30-second deadline, with a six-second fake-server
regression. Initialization retains its five-second deadline. Programmatic cursor
changes were no-ops in UIKit, leaving the line-25 completion anchor offscreen.
Views now request reveal explicitly, and EditorPane uses resolved caret/viewport
geometry and its existing scroll controller. Native layout feedback applies the
offset. Ordinary scrolling still preserves the viewport and dismisses a clipped
popup. No compiler or server changes were needed.

The language-service test, clipped/scroll/live-completion/IME popup phases and
both real-server graphical runs passed. M10 is accepted for Linux automation;
physical OS IME and other-platform qualification remain unclaimed. Next is
the outstanding M11/M12 foundation and terminal acceptance work.

## M10.2 — native composition handoff and real-server regression, 2026-10-05

Language popups are now nonmodal. Overlay capture requests focus after layout,
when its node is registered; the former immediate request could fail silently.
Dismissal restores editor focus. A native TextEdit event dismisses the language
popup, focuses the existing editor and forwards the original payload through
UIKit's normal composition transaction handler. A failed focus request stops
forwarding to avoid recursively redispatching into the overlay.
The routed Xvfb regression composes Japanese text and commits a replacement,
checking that completion closes and committed text is neither lost nor duplicated.
IME, live completion, long-list, hover, menu Escape and palette cancellation
phases passed. `scripts/test-haxeon-lsp.sh` passed fixture diagnostics/fix,
navigation/rename, save/build/execution and repository unsaved-overlay checks.
These prove normalized native-event handling and real-server headless behavior;
actual OS IME qualification and a real-server graphical workflow remain open.

## M10.2 — reveal keyboard-selected completion rows, 2026-10-05

The UIKit completion popup now retains its scroll controller, uses explicit
24-pixel rows with 4-pixel gaps and bounds its viewport to 236 pixels (or the
available window height). Up/Down reveal the selected row, including wrapping
from first to last. Opening a new popup resets the offset. Xvfb tests navigate
40 suggestions using routed key events and inspect the selected row against
the actual clipping viewport. Long-list, wrap, live typing, large information
and hover phases passed. IME and real-server graphical qualification remain
open; the milestone is not yet accepted.

## M10.2 — live completion interaction, 2026-10-05

Added shared `ActiveCompletion` ownership of the replacement range, provider
items and document revision. Both hosts narrow the original results as committed
text edits the document; Backspace re-expands from the original results. Accept
replaces the updated prefix. Unrelated edits, cursor changes, document switches
and retired providers invalidate acceptance. Unmatched prefixes dismiss without
losing typed text. Popup closure releases its callbacks and item references.
Headless command tests cover live edits, acceptance, stale edits, Unicode
Backspace and no matches. Language-controller tests passed. A focused Xvfb
smoke uses routed UIKit text/Backspace/Enter events; hover, completion and
signature popup regression phases also passed. This does not yet qualify IME,
long-list selected-row scrolling or the real-server graphical acceptance.

## M10.2 — completion prefix filtering, 2026-10-05

Completion requests now narrow suggestions to the word before the caret,
case-insensitively, using LSP `filterText` with a label fallback. Filtering
preserves provider order and item identity, including insertion text. Empty
prefixes retain all results; unmatched prefixes do not open a popup. Results
from a retired server are rejected before presentation as well as acceptance.
The command test covers ordering, alternate filter text, empty/no matches and
Unicode prefixes. Fake-server decoding and language-controller tests passed;
`scripts/build.sh` passed against the current graphical checkout.
Live narrowing while typing and real-server graphical acceptance remain open;
this is prefix filtering at request time, not a completed M10.2 acceptance.

## M10.2 — remaining language shortcuts, 2026-10-05

Added hover (Ctrl+Alt+Space), signature help (Ctrl+Shift+Space) and definition
(Ctrl+Alt+G) defaults to the common keymap. The existing UIKit bridge maps
these keys/modifiers into its command registry. The command test verifies
dispatch and that unavailable language services do not consume these keys.
`../haxeon/scripts/haxeon run --project tests/command-test/haxeon.json` passed.
Completion filtering and the real-server graphical acceptance remain open;
this check proves headless dispatch, not graphical interaction.

## Workbench UX — named groups with working directories, 2026-10-05

User requires Sakura-style named groups associated with working directories.
Recorded one nested group model in M14 and the common protocol contract, using
stable ids, order, directory inheritance and explicit session overrides. Existing
sessions retain cwd on group moves/directory changes. Groups persist/share across
clients, while selection/expansion is local. Directory association never grants
filesystem access or silently switches the editor project. Sakura import must
preserve this structure. Documentation checked; implementation remains pending.

## Codex reference correction, 2026-10-05

User explicitly excludes Sakura's Codex integration: it predates the shared
app-server. Recorded the exclusion in M14. Generic Sakura workspace/terminal
ownership, replay/backpressure and failure tests remain useful references;
Codex helpers/hooks/provider lifecycle do not. Current official protocol,
installed version-matched schema and shared-daemon tests define our Codex
integration. Documentation diff checked; no source implementation changed.

## Shared workspace protocol contract, 2026-10-05

Recorded one compact WORKSPACE-PROTOCOL.md rather than expanding into separate
terminal/agent specifications, per user's request to avoid overengineering.
Defines ownership, permission checks, mutation outcome reconciliation, cursor
recovery, terminal controller leases and uncertain input, agent approval races,
capabilities and bounded queues. Implement with real M14 consumers; no additional
framework or prerequisite implementation is claimed. Diff checked. Resume
existing delivery order with M10.2 completion filtering/language shortcuts.

## Workspace filesystem API — read/watch/search plan, 2026-10-05

Added WORKSPACE-FILES.md and linked M14/M16. Defines root-relative typed
addressing, per-operation grants, race-resistant path containment, paginated
listings, opaque revision/epoch tokens, bounded owner-scoped read handles,
watch cursor recovery and cancellable file/content search. Initial view shows
saved files, not desktop unsaved drafts. Streaming reads must prove coherent
content or fail explicitly; read handles alone are not immutable snapshots.

F1–F5 acceptance includes symlink swaps/revocation, concurrent and preserved-mtime
writes, multibyte chunks, watcher overflow/restart/replay gaps, search budgets
and Unicode coordinates, plus native/browser integration. File writes remain
outside initial scope. Reuses existing filesystem/index/search/watch engines;
no implementation or runtime acceptance is claimed. Documentation diff checked.

## M16 relay selection — Cloudflare Workers free tier, 2026-10-05

User selects Cloudflare Workers for the relay plan. M16 now specifies a thin
Worker/router plus a SQLite-backed Durable Object per opaque machine identity,
both endpoints connecting inbound to the object, hibernation/attachment
recovery, bounded encrypted forwarding and minimal metadata. Start on Free;
no paid upgrade is authorized. Record actual quota/duration/Worker usage and
explicit limit failures; do not promise free operation for arbitrary workloads.

Checked official hibernation/pricing/Wrangler documentation. No Wrangler
executable or relay project was found locally. Local implementation needs no
Cloudflare account input. Live deployment later needs account selection/local
Wrangler authentication and final approval under EXECUTION.md; workers.dev
is the default so a custom domain is optional. No credentials requested or
read, no account changes, no remote deployment. Documentation diff checked.

## M16 scope — existing web build first, 2026-10-05

User requires remote access from the existing web build immediately, including
away-from-home connectivity. Added M16 with browser pairing, outbound relay,
authenticated/end-to-end encrypted workspace transport, file browsing, both
agent providers and terminal attachment/control. Android uses the responsive
web client first. Standalone M15 remains accepted separately; connected
capabilities come from the service, not browser-native PTY/process support.

Real cross-network relay/browser acceptance and Android suspend/network-switch
qualification are explicit gates. Crypto protocol/library selection and browser
key/client-delivery trust need verification before implementation. No relay
was deployed, remote access enabled or device paired by this documentation
change. Diff checked; implementation remains pending.

## Haxeon RPC delivery plan — reconnect included, 2026-10-05

Recorded the agreed RPC scope in HAXEON-RPC.md and linked it from M14 and the
roadmap index. RPC.1 includes typed calls, deferred handlers, deadlines,
cancellation, bounded dispatch, connection generations, handshake and reconnect
with backoff/jitter. Explicit resumable subscription hooks use application-owned
cursors. Exosuit demonstrates durable replay/snapshot fallback and operation-id
reconciliation after lost mutation replies. No automatic mutation resend or
exactly-once delivery claim. Explicit close disables reconnect.

Later slices add real transport qualification, generation over proven method
descriptors, and bounded streaming/buffer ownership. General RPC mechanics go
in Haxeon; authentication policy, workspace persistence and provider semantics
remain outside the core. Implementation is pending. Documentation diff checked;
no runtime tests or shared builds were needed for this plan-only change.

## M14 protocol ownership — Haxeon wire, 2026-10-05

User removes Pragtical agent dependency; it is reference input only. Updated
M14.1 to target an initial Exosuit service and removed Workbench 2.1 wire,
Pragtical-client and database schema compatibility requirements. M13's separate
local editor-control compatibility remains unchanged.

Inspected Haxeon's MESSAGEPACK.md, JSON_WIRE.md, MessagePackFrame and reader.
Use shared @:wire records/stable @:id fields, typed MessagePack codecs and
optional same-schema JsonWire diagnostics. Local streams use HMPK framing with
bounded incremental assembly; WebSocket uses message boundaries. Define
application version/capability negotiation separately from frame version,
explicit RPC/replay semantics, Int64 counters, domain validation and bounded
queues. Unknown enum variants require negotiated capabilities. Current frame
helpers copy payloads; no zero-copy claim. Generic buffer-slice improvements
belong in Haxeon if measured and required.

Recorded connected web/Android service boundary without claiming remote support
implemented or expanding standalone M15 acceptance. This is a documentation
scope/design change; protocol and service implementation remain pending.

## M14 scope — Codex shared app-server provider, 2026-10-05

User overrides the original Claude-only scope: Codex is required alongside
Claude Code in M14.4; only opencode remains deferred. README and M14 now agree.
Read the official app-server protocol documentation and verified installed
`codex-cli 0.160.0` help for daemon management, stdio proxy, shared agent
browsing and remote attachment. Generated its stable JSON schema under
`/tmp/exosuit-codex-protocol-0160`; confirmed thread/turn methods, status
notifications and approval request types. No daemon was started, stopped or
restarted; no existing Codex thread was modified and no inference was run.

Design: the Workbench agent owns a provider connection and local projection;
Codex owns its daemon and thread history. Use structured protocol events for
status, approvals and conversation UI, with thread identity persisted for
recovery. Resource stop interrupts its turn, never the shared daemon. Define
provider-specific read cursors and reconciliation after ambiguous prompt
submission. Verify multi-client approval ownership and subscriber lifetime
before claiming active work survives client disconnect.

This is a researched plan change, not implemented M14 functionality. Provider
acceptance includes fake protocol tests and opt-in real daemon/reconnect tests.
M10.2 and the existing terminal/control-plane prerequisites remain pending.

## Clay clipping and persistent-state capacity, 2026-10-05

- GDB captured the reported shutdown before cleanup, preserving a core in
  `/tmp/exosuit-clay-debug/clay-error.core`. The failing call was adding a
  scroll-container record in ConfigureOpenElementPtr: the persistent table had
  length/capacity 100/100. Clay's generic bounds message obscured exhaustion;
  this was not an OS signal crash, so ordinary core-dump enablement alone did
  not capture it.
- Clay now provides per-context clipping-only mode. UIKit opts out of native
  scroll tracking because ScrollController owns offsets/input/lifetime.
  Clipping, explicit child offsets, scissor commands and resolved geometry
  remain active; clipped labels no longer consume persistent scroll records.
  Native tracking remains enabled by default for standalone Clay users.
- Scroll retirement is a separate pass before target selection. Swapback
  replacements are all examined and no selected target is invalidated by
  subsequent removal. Scroll and transition tables scale with declared element
  capacity, allowing previous/current overlap. Long-lived exiting transitions
  still count toward the supported capacity; exhaustion is a typed resource
  error, never a mutable default-record write or generic bounds error.
- Capacity diagnostics name the table, capacity and element via a supplementary
  query, preserving Clay's existing error-callback ABI and UIKit's public ABI.
  Failed capacity frames return no commands; the next layout resets diagnostics.
  Transition completion also examines swapback replacements. A pre-existing
  C++ reference in paragraph layout was changed to a borrowed pointer to restore
  C compatibility, with a permanent C11 compile target.
- Regressions pass: 3,000 clipped nodes with full ID replacement; standalone
  tracking beyond 100 records and native wheel scrolling; complete stale-cache
  retirement; transition churn beyond 200 records; forced exhaustion of both
  tables without default-record mutation; recovery on the next frame. Native
  layout/invariants/render/Clay gates (7 tests), C/C++ compilation, ASan/UBSan,
  existing framework/input/4,000-node regressions, and the captured app build
  running 180 frames with the final native library all pass.
- Isolated app snapshot desktop build and wasm32/wasm-gc browser acceptance pass.
  The working-tree browser click test hit newly added breadcrumbs at its old
  editor coordinates; the final working-tree desktop rebuild was blocked by
  concurrent Preferences.hx:94 (`sys.FileSystem.stat` not recognized). Those
  unrelated changes are preserved. A verified app artifact and matching native
  libraries remain under `/tmp/exosuit-clay-fixed/verified-main.hl` and
  `verified-native/`; the temporary source checkout was removed.
- Commits: Clay `0897847` and ABI-compatible follow-up `af7fa05`; UIKit/materia
  `f377215dc` and `aef4b8c35`, including the Clay dependency pin. Existing Haxeon
  and NativeKit pins and unrelated UIKit/app edits remain untouched. No document
  buffers are copied and no editor-specific clipping cache is introduced.
- Next roadmap task remains M10.2 completion filtering/language shortcuts;
  concurrent preferences and breadcrumb integration need their own validation.

## Editor scrollbar at the outer pane edge, 2026-10-04

- ScrollView accepts an optional enclosing overlay host. The editor supplies its
  outer pane, placing its single scrollbar after the fixed minimap at the far
  right edge. Content keeps its original viewport and scroll controller; no
  document copies or separate visibility controller are introduced.
- The relocated control forwards wheel and keyboard input to the same controller.
  Pane activation captures input on the enclosing pane. Existing hover, delayed
  fade, captured drag and visibility settings continue to apply.
- UIKit framework regressions pass, including an external host with a fixed
  sibling, far-right geometry, wheel, keyboard, drag outside, fade and unmount.
  Real app checks with the minimap pass for visibility, smooth scrolling,
  minimap navigation, narrow/disabled layouts and repeated resizing. The full
  native workspace suite and desktop build also pass in an isolated snapshot
  containing only the placement slice, avoiding concurrent icon/tab edits.
- Commits: UIKit `650d116ec`; editor placement `eb0bfec`. Concurrent minimap
  integration is separately committed as `4da728a`; remaining icon/tab changes
  and dependency pins are preserved.
- Next roadmap task: completion filtering and remaining language shortcuts in
  M10.2.

## Shared automatic scrollbar visibility, 2026-10-04

- UIKit ScrollView owns a persistent visibility controller and retires its
  scheduler registration on unmount or controller replacement. Bars are
  transparent while idle; only the existing narrow overlay edge target remains.
  Hover and scroll reveal immediately; dragging and keyboard focus keep them
  visible. Leaving waits 500 ms, then fades for 200 ms. Re-entry cancels the
  fade. Pointer focus during a drag does not keep the bar visible forever.
- Reveal/fade changes persistent widget state so retained paint caches see
  alpha changes; viewport and content geometry do not shift. No text copies,
  per-panel timers, native ABI additions, or separate visibility rules in the
  editor and Explorer. Reduced motion retains the delay and skips interpolation.
- `workbench.scrollbarVisibility=auto|always|hidden` is validated, copied and
  reloaded live into UIKit's shared environment. ScrollView can override the
  policy locally; its existing showScrollbar=false opt-out remains supported.
  Hidden removes the control/hit target, preserving wheel/keyboard scrolling.
  This applies to existing vertical ScrollView bars; horizontal bars and
  terminal scrollback controls are separate existing scope.
- Toolkit regressions pass: deterministic timing, hover interruption, drag
  hold, reduced motion, policies, actual hit routing/paint alpha and unmount.
  Smooth-scroll lifetime checks now account for the separate fade animation
  and still require all registrations to retire. Retained-rendering checks
  verify thumb paint revisions change on reveal and fade. UIKit is committed
  as `717261eba`, excluding concurrent resize and icon work.
- App gates pass in an isolated HEAD snapshot with this owned change: full
  headless suite (including setting validation/copy/reset), native workspace
  smoke (real editor hover, delay/fade, wheel reveal and live policies), desktop
  build, and wasm32/wasm-gc browser acceptance. Concurrent icon and resize
  changes and parent dependency pins remain untouched.
- Next: completion filtering and remaining language shortcuts in M10.2.

## Explorer folder single-click, 2026-10-04

- Folder labels now expand/collapse immediately on a single primary click.
  Double-clicking toggles once, including when the tree rebuilds between the
  first and second click. Disclosure arrows retain their single-click behavior.
- UIKit exposes an opt-in `expandOnSingleClick` policy; Exosuit enables it
  without changing other tree consumers' double-click defaults. File preview
  and permanence behavior remains the same.
- Graphical acceptance now checks visibility after the first click, ignores
  the second click across a rebuild, and checks double-click collapse.
- Validation: full native workspace smoke and desktop build pass in an
  isolated HEAD snapshot with this app/test change; the working checkout's
  initial compile hit concurrent in-progress Seti icon sources. The snapshot
  excluded those app sources and preserved their work. UIKit policy is committed
  as `0810b21b9`.
- Next: completion filtering and remaining language shortcuts in M10.2.

## Explorer previews and folder double-click, 2026-10-04

- Fix the graphical tree's selection-only mouse click path: single primary file
  clicks open previews, while activation/Enter and double-click open permanent
  tabs. Folder labels toggle expansion on double-click; disclosure controls
  retain single-click expansion. Context selection does not open a file.
- UIKit exposes a row-click callback independently of selection changes, so
  clicking an already selected file still promotes it. A retained, typed click
  sequence recognizes same-item, primary-button double clicks with time and
  distance bounds across render rebuilds. Tree activation also toggles branches.
- Preview belongs to a document view, one per editor pane, sharing the existing
  document/buffer rather than copying text. Replacing a clean preview disposes
  its view and closes the document only when no other view owns it. Dirty
  documents remain permanent. Buffer edits permanently promote every preview
  view of that document, including after undo; explicit opens, tab double-click,
  moves and reorders also promote. Moving onto an existing tab preserves that
  tab and avoids duplicates. Preview labels show `(preview)`.
- UIKit commit `145d29cbf` owns only the click sequence, tree callback/activation
  and timing regressions. The framework suite passes, including its layout and
  input routing checks. App gates pass: native workspace smoke (actual tree
  and tab pointer events, preview replacement, promotion/undo, pane isolation
  and shared buffers), desktop build, and wasm32/wasm-gc browser acceptance.
  Concurrent scrollbar-resize edits and parent dependency pins were preserved.
- Next: completion filtering and remaining language shortcuts in M10.2.

## M10.2 — symbols, references and rename, 2026-10-04

- Reuse the searchable command-view picker for document symbols and references,
  including hierarchical symbols and navigation to unopened files. Rename uses
  the same text prompt and leaves changed managed buffers unsaved, one undo
  transaction per document. All commands depend on negotiated capabilities and
  owning-folder document eligibility; the existing command bridge supplies
  palette entries and keyboard shortcuts.
- Capture document identities, paths, revisions and protocol versions when
  requesting rename. Validate all target edits before mutation, reject delayed
  results after typing/session changes, and share validation with server-driven
  workspace/applyEdit. Unopened, unversioned targets are loaded as managed
  documents on response; creating/renaming/deleting files is outside text rename.
  Full filesystem transactions and cross-document undo are not claimed.
- Focused fake-server and controller tests pass; real Haxeon fixture completes,
  resolves definition/symbols/references, renames a local declaration and use,
  then builds/runs with exit 42. Native graphical acceptance covers searchable
  symbols, references to a closed file, rename input and transactional undo.
- Real repository acceptance uses unsaved overlays of
  `src/config/ApplicationPaths.hx`: diagnose/fix, completion, definition, symbols,
  references, local rename and undo, with unchanged disk contents. This exposed
  three general Haxeon issues fixed in sibling commit `6f948557`: discover
  `haxeon.json` roots and local dependencies through existing project discovery;
  analyze libraries without requiring executable `main` while retaining body
  checking and executable entry validation; display omitted inferred annotations
  in syntax indexes without a null access. Before/after regressions cover each,
  plus invalid-body recovery and executable rejection after an analysis cache.
  Both compiler language-service and standard LSP suites pass. Existing unrelated
  Haxeon changes and parent dependency pins were preserved.
- Final gates pass: full headless suite, desktop build, native workspace UI
  smoke, real Haxeon fixture plus repository overlays, and browser acceptance
  on wasm32 and wasm-gc. Updated the browser source inventory for the two new
  typed language-result modules.
- Next: finish completion filtering and remaining language-command shortcuts,
  then the graphical real-repository edit/build/diagnose/fix acceptance. This
  slice does not claim complete foreign-binding/package-scope LSP coverage.

## M10.1 — workspace-folder language sessions, 2026-10-04

- User-approved scope replaces the earlier single-client/last-document-stop
  proposal: lazily launch one server per workspace folder, route nested files
  to their longest matching root, retain sessions across tab changes and the
  last document closing, and stop only on folder removal, disablement or
  explicit Stop. Folder-local configuration changes restart only that session,
  including warm sessions with no open documents. Explicit Stop suppresses
  automatic startup until Start or folder removal.
- LanguageController owns root-indexed sessions and independently owned
  diagnostics/failure Problems. It pumps all live and retiring sessions rather
  than just the selected document's client. Settings use each owning folder's
  layers; configuration polling reloads every folder. The graphical shell now
  loads user settings from the existing settings path, and the development
  launcher exports the selected compiler's absolute root for server fallback.
- Retry callbacks use the supplied update clock, schedule one retry per
  failed attempt, retire failed initialization transports, and back off by
  0.25/0.5/1 seconds. Three retries exhaust automatic recovery; thirty healthy
  seconds reset the count. Failure status and Problems clear after recovery,
  and a ready notification replaces the earlier failure notification.
- Headless regression covers two/nested folders, one initial process per root,
  isolated settings, active-folder switches, retained sessions, warm-session
  reconfiguration, folder removal, explicit Stop/Start, external SIGKILL,
  wrong-command recovery, unsupported initialization encoding and disablement.
  The real-window phase verifies automatic startup and visible status/Problems
  with file-based settings recovery. It initially exposed missing process
  initialization in the test harness and missing user-settings loading in the
  shell; both are corrected. Linux checks only; other platforms remain pending.
- Verification: serial process 5550 passed (exit 0): workspace UI, full
  headless, desktop build, real Haxeon LSP and both wasm32/wasm-gc browser
  targets. Logs: /tmp/exosuit-folder-lsp-ui4.log,
  /tmp/exosuit-folder-lsp-{headless,desktop}-final.log and
  /tmp/exosuit-folder-lsp-{real,web}.log. The development launcher also passed
  a real-server window capture (35975, exit 0), with initialize, didOpen and
  empty diagnostics in /tmp/exosuit-folder-launch-smoke-capture.log. Its first
  trial lacked capture mode, so the host did not honor the frame limit; only
  that isolated test app/server were terminated before the bounded rerun.
  bash -n and git diff --check pass. No compiler/native/ABI edits.
- M10.1 accepted. Slice committed with this ledger; git log identifies its SHA.
  Only owned Exosuit paths changed; pre-existing Haxeon/NativeKit dirt and
  materia pins remain unchanged. No publishing or user-app relaunch.
- Next: M10.2 negotiated symbols, references and rename UI,
  including stale-revision rejection and real-server feature acceptance.
  Prior M10.1 last-document-stop instructions below are superseded.

## M10.1 — stopping-client ownership, 2026-10-04

- Added a regression that stops the configured fake server, pumps the controller
  until ProcessManager owns zero processes, restarts it, and shuts down while
  initialization is still pending. The pre-fix run failed with a controller
  timeout (/tmp/exosuit-language-stop-before.log, 14218, exit 1).
- LanguageController retains stopping clients and advances them until their
  asynchronous shutdown finishes. An explicit restart retires any prior stopping
  clients before launching another. Application shutdown explicitly closes the
  transport and releases process/subscriptions without waiting for another frame.
- LanguageServiceClient marks stopping sessions unready and ignores late
  initialization responses, preventing initialization from reopening documents
  or scheduling retries during teardown. Cleanup is idempotent.
- Focused regression, full headless and desktop checks passed in serial process
  57305 (exit 0); /tmp/exosuit-language-stop-after.log and
  /tmp/exosuit-language-stop-{headless,build}.log. Real Haxeon server smoke
  and both wasm32/wasm-gc browser gates passed in process 92824 (exit 0);
  /tmp/exosuit-language-stop-{real,web}.log. git diff --check passes.
- Slice committed with this ledger; git log identifies its SHA. Only Exosuit
  files changed; pre-existing Haxeon/NativeKit work and release pins preserved.
- M10.1 remains unfinished. Next is automatic project-scoped startup, stopping
  on last .hx close/project change, configuration reapplication, crash backoff
  and visible failure/status acceptance. Preserve explicit Stop in automatic
  mode; restrict server synchronization to its project root. Retry timing must
  use the supplied update clock and retire failed initialization sessions.
  No automatic startup is claimed yet.

## M10.1 — language configuration foundation, 2026-10-04

- Added typed plugins.haxeon.enabled (true), command (JSON string argv array,
  empty means automatic resolution) and verbose (false). Invalid JSON,
  non-string arguments and empty executable values reject the settings layer;
  last-good values survive. Command arrays preserve spaces, commas and empty
  arguments and are copied at ownership boundaries.
- LanguageServerCommand resolves config, HAXEON_LSP, the bundled server, then
  HAXEON_ROOT/scripts/haxeon-lsp (default root ../haxeon). No shell parsing is
  involved. The root fallback is resolved before spawning in the project cwd.
  Controller starts use effective settings, including project overrides.
  Disabled startup launches no process. Running-service reconfiguration is
  part of the remaining lifecycle work.
- Added optional transport trace callbacks using the already encoded payload;
  verbose clients log send/receive messages to the launch console, bounded to
  2,048 characters per message. Default logging is off. Settings command view
  includes these fields and the M9.4 motion fields. Packaging/docs list defaults.
- Core tests cover invalid reload rollback, command-copy independence, all four
  resolution priorities, exact argv, disabled launch and verbose protocol
  output from a configured fake server. Full headless and desktop checks passed
  (13653, exit 0); /tmp/exosuit-language-config-{headless,build}.log.
- Existing real-server edit/diagnose/fix/save/build/run smoke passed;
  /tmp/exosuit-language-config-real-lsp.log. Both wasm32 and wasm-gc browser
  behavior passed in serial process 59437 (exit 0);
  /tmp/exosuit-language-config-web.log. git diff --check passes.
  web/haxeon.json source inventory is regenerated for LanguageServerCommand.
- Configuration foundation committed with this ledger (git log identifies SHA).
  No compiler/NativeKit changes or pin updates were made in this slice.
- M10.1 remains unfinished. Next exact action: repair shutdown ownership
  (LanguageController currently drops a client before its asynchronous shutdown
  response is pumped), then add automatic startup for project .hx documents,
  last-document/project-change stop, restart backoff, visible status/problems,
  wrong-command recovery and external-kill/single-server acceptance tests.
  M10.2 symbols/references/rename and real-repository UI cycle remain later work.

## M9.4 — time-based editor scrolling, 2026-10-04

- Read the uncommitted Pragtical view/config/settings diff and deterministic
  tests from /home/joao/dev/pragtical without modifying that checkout.
- UIKit ScrollController approaches a target with 0.01^(dt/duration), default
  0.12 seconds, and snaps within 0.5 logical pixels. Same-direction wheel
  events accumulate the target; reversals discard the old pending direction.
  Motion stores only offsets and targets; content and text layouts are retained.
- Smooth motion is opt-in for general UIKit scroll views and enabled for editor
  panes. jumpTo, scrollbar dragging and session restoration remain immediate.
  Exosuit exposes editor.scroll_animation_type (smooth/none) and
  editor.scroll_animation_duration (0..0.3 seconds; zero is immediate).
  Existing, split, reopened and restored panes receive effective settings.
- Mount-owned ScrollBinding releases callbacks and scheduler registrations on
  replacement/unmount. A regression reproduced old viewport cleanup detaching
  the same controller after it moved to a new viewport. Bindings now check
  ownership before detaching, and retire a previous scheduler when rebinding.
  Before-fix /tmp/uikit-smooth-transfer-before.log (85687, exit 1) reports
  "old scroll mount detached replacement binding". After-fix framework passed
  /tmp/uikit-smooth-transfer-after.log in serial gate 35747.
- Deterministic framework tests cover >40% first-frame motion, >=99% at the
  rounded-up duration, equal elapsed time at 30/120 fps, immediate reversal,
  jump cancellation, zero duration, disabling motion, replacement, transfer
  and unmount cleanup. Configuration tests reject malformed/nonfinite/out-of-
  range values and preserve last-good settings; removing overrides restores
  defaults. The new window test initially omitted activeView's null check;
  corrected invalid test code, with no compiler changes.
- Initial UIKit framework passed /tmp/uikit-smooth-scroll2.log (30213).
  Serial gate 87534 passed workspace UI, ./scripts/test.sh, ./scripts/build.sh
  and the full decoration/pixel suite; logs
  /tmp/exosuit-smooth-scroll-{ui,headless,build,decoration}.log. Real editor wheel
  input advances over frames, settings apply live, and restored offsets jump.
  Reviewed /tmp/exosuit-smooth-scroll-ui/editor-scroll/frame.png.
- Final transfer fix: framework, all workspace UI phases and desktop build
  passed in gate 35747 (exit 0); /tmp/uikit-smooth-transfer-after.log,
  /tmp/exosuit-smooth-scroll-final.log and
  /tmp/exosuit-smooth-scroll-build-final.log. Both wasm32 and wasm-gc
  browser behavior passed in the same process;
  /tmp/exosuit-smooth-scroll-web.log. git diff --check passes.
- UIKit committed as Materia 5934be0a3; release pin follows that commit.
  Haxeon/NativeKit pins and pre-existing checkout changes were preserved. App
  slice is committed with this ledger (git log identifies its SHA).
- M9.4 accepted for Linux automation. Next exact action: implement M10.1
  configuration and automatic project-scoped language-server lifecycle.
  Physical IME, non-Linux and terminal-tab keyboard transfer remain pending.
  Full roadmap goal remains active.

## M9.3 — registered sidebar and graphical search, 2026-10-04

- UIKit owns generic SidebarModel/SidebarHost: registered, ordered modes with
  lazy providers, controlled tabs, mode visibility and independent widths.
  Persistence validates atomically and preserves unknown modes for later
  registration. DockWorkspace can set the panel width through nested splits.
- Exosuit registers Files first and Search second. Commands, Ctrl+Shift+F,
  pointer tabs and the closed-sidebar rail select modes. Separate-process
  restart restores active mode, visibility and dragged widths.
- Search borrows the service result array and virtualizes visible rows. Results
  navigate through validated document positions; edits refresh searches and
  invalidate previews. Replacement previews show changed excerpts and apply
  through the existing transactional service. Generation and snapshot identity
  guards reject stale navigation and Apply callbacks.
- Added open-document refresh and stale-preview core regressions. The initial
  test called a nonexistent RootView.activeView method; corrected the test to
  use activeLeaf.tabs.activeView. No compiler workaround was introduced.
- Full serial gate passed (13036, exit 0): UIKit framework, workspace UI,
  ./scripts/test.sh, ./scripts/build.sh, decoration/pixel UI, and browser
  behavior on both wasm32 and wasm-gc. Logs:
  /tmp/uikit-sidebar-framework-verified.log,
  /tmp/exosuit-sidebar-{ui,headless,desktop}-verified.log,
  /tmp/exosuit-sidebar-decoration.log and /tmp/exosuit-sidebar-web.log.
  Replacement preview screenshot reviewed in
  /tmp/exosuit-sidebar-ui-verified/sidebar-preview/frame.png.
- Final focused workspace UI passed (78520, exit 0), including Files wheel,
  virtual search wheel, navigation after edits, preview/application and stale
  Apply rejection; /tmp/exosuit-sidebar-complete.log. The Files test initially
  searched a widget key that is not a RenderNode style key; it now targets the
  tree accessibility role. Production wheel routing required no UIKit change.
  Final desktop build passed (15526, exit 0),
  /tmp/exosuit-sidebar-desktop-final.log. git diff --check passes.
- UIKit committed as Materia eb8afb84e; release pin follows it. Haxeon and
  NativeKit checkouts and pins were preserved. web/haxeon.json's generated
  source list now includes WorkspaceSearchPanel (generated by web/build.sh).
- Read-only Pragtical reference is /home/joao/dev/pragtical. No live user app
  was closed. README removes obsolete rendering/search/key-mapping gaps;
  historical M9.1 latency evidence was not remeasured in this slice.
- M9.3 is accepted for Linux automation. Next is M9.4's frame-rate-independent
  smooth editor scrolling and configuration. Physical IME, non-Linux and
  terminal-tab keyboard transfer remain unclaimed; the full goal is active.

## M9.2 — restart and keyboard acceptance, 2026-10-04

- Reviewed pre-existing TerminalPane diff: it removes a duplicate resolved-layout
  callback that resized the grid immediately. Adopted this reviewed correction in the app slice; the
  remaining callback records geometry and schedules resize before row painters
  are built. Real PTY transfer regression verifies wider panel columns, return
  to the original editor grid, and unchanged session creation count.
- Added standalone workspace-ui-smoke host and scripts/test-workspace-ui.sh.
  Writer and reader run in separate processes using isolated portable storage:
  actual shutdown/startup preserves split panes, shared recovered dirty text,
  independent caret/scroll positions, active terminal and one recreated shell.
  Terminal processes restart from profiles; they do not survive process exit.
- Added real keyboard-only palette split/close and default directional focus/tab
  movement checks. Initial failure: focused TextField consumed Ctrl+Alt arrows
  as text navigation before application shortcuts. UIKit regression reproduces
  caret movement and verifies all eight arrow/Shift chords reach commands
  without altering selection. TextField leaves these chords for command routing.
- Before-fix framework regression failed with "application arrow chord changed
  text selection" (/tmp/uikit-pane-shortcut-before.log). Complete framework
  after fix passed (/tmp/uikit-pane-shortcut-after.log).
- Second palette operation initially retained the prior query; the test now
  selects existing query text with Ctrl+A before entering the next command.
- Legacy version-3 flat T records reopen surviving files and skip missing ones.
  Unsupported/corrupt session files are quarantined; missing session and invalid
  dock JSON leave a workspace that can create and edit documents.
- Initial complete workspace gate passed:
  WORKSPACE_UI_ARTIFACTS=/tmp/exosuit-workspace-acceptance-fixed2
  ./scripts/test-workspace-ui.sh, log /tmp/exosuit-workspace-acceptance-fixed2.log.
  Restart screenshot reviewed. Final exact dock snapshot assertion also passes:
  WORKSPACE_UI_ARTIFACTS=/tmp/exosuit-workspace-acceptance-final2
  ./scripts/test-workspace-ui.sh (44340, exit 0), log
  /tmp/exosuit-workspace-acceptance-final2.log. The new expected-snapshot file
  initially needed its isolated state directory created before shutdown; fixed
  fixture setup, without production changes.
- Broader serial verification (18425, exit 0): ./scripts/test.sh,
  ./scripts/build.sh, DECORATION_UI_ARTIFACTS=/tmp/exosuit-workspace-decoration
  ./scripts/test-decoration-ui.sh, EXOSUIT_CI_WEB=1
  EXOSUIT_WEB_BROWSER=/tmp/exosuit-chrome-testing/chrome-linux64/chrome
  ./scripts/test-web.sh. Logs /tmp/exosuit-workspace-{headless,desktop,decoration,web}.log.
  Both wasm32 and wasm-gc pass real browser behavior. git diff --check passes.
- UIKit committed as Materia 5f279c4a6 (only TextField and FrameworkSmoke).
  Exosuit release pin updated to that revision; pre-existing parent CadKit
  commits remain intact. No compiler/NativeKit edits or pin changes made.
  App acceptance slice committed with this ledger; git log identifies its SHA.
- Added workspace acceptance to composed CI; corrected outdated single-pane
  host documentation and README. No live user app was closed or relaunched.
- M9.2 checklist complete for the claimed Linux automated document-pane scope.
  M9 and the full roadmap remain unfinished. Resume at M9.3: registerable sidebar
  modes with Files first, then graphical workspace search. Physical IME,
  non-Linux platforms, and keyboard transfer of terminal tabs remain unclaimed.

## IME range affinity correction, 2026-10-02

- Fixed TextLayout.selectionRangeRects to derive logical insertion offsets
  through offsetFromPosition, while retaining original visual positions and
  affinity for the endpoint carets. Intermediate rectangles use canonical
  logical boundaries. No text copy or empty-geometry recovery was added.
- TextEditorLayout normalizes logical range ordering before chunk/viewport
  clipping and retains visual positions in the cache key. At a chunk boundary,
  a visual endpoint from the preceding chunk uses this chunk's canonical edge.
- Added UIKit regressions for forward/reverse affinity endpoints, geometry
  preservation, repeated cached editor queries and the preceding-chunk edge.
  App UI regression ime-selection-affinity reproduces the original GTK drag
  and requires nonempty geometry entirely inside the logical selection.
- Reduced GTK reproducer now passes (21074, exit 0), log
  `/tmp/exosuit-ime-affinity-fixed-run.log`. First full app UI/pixel run passed
  (44806), log `/tmp/exosuit-ime-affinity-ui.log`, before final boundary handling.
- Broader framework initially hit a Skribidi property lookup assertion.
  Repeating with original committed UIKit files also aborted (57760, exit 134),
  log `/tmp/uikit-ime-affinity-baseline.log`. Initial whole-empty-document guard
  did not address it and was removed. Actual defect: hit-testing an empty final
  line in a nonempty newline-terminated layout reads text properties at count.
- Vendor regression reproduced that assertion (before exit 134) and full
  Skribidi unit suite passed after fix (50371), logs
  `/tmp/skribidi-ime-final-line-before.log` and
  `/tmp/skribidi-ime-final-line-after.log`. Vendor commit e1c33fe bounds-checks
  control-EOL character pruning without changing document-end insertion carets.
  Native text-engine regression passed (77303), log
  `/tmp/uikit-ime-final-line-native.log`, fresh/replaced empty and trailing-newline
  documents at left/center/right coordinates.
- Complete UIKit framework gate passed (13552, exit 0), log
  `/tmp/uikit-ime-affinity-complete-framework.log`, including new affinity/cache/
  chunk-edge regressions and all existing 4,000-node/input-routing cases.
  Boundary regression initially assumed selection excluded its preceding newline;
  corrected expectation after observing model grapheme alignment (255..259)
  versus the three visible letter rectangles (256..259).
- Final full app UI/pixel gate passed (44376, exit 0), log
  `/tmp/exosuit-ime-affinity-ui-final.log`, artifacts
  `/tmp/exosuit-ime-affinity-ui-final`. Desktop build passed (94479, exit 0),
  log `/tmp/exosuit-ime-affinity-desktop.log`. Both browser targets passed
  (15245, exit 0, Chrome Testing 154), log `/tmp/exosuit-ime-affinity-web.log`.
- Materia commit 168c0f7a2 owns the two geometry implementations, framework/native
  regressions and Skribidi pin e1c33fe. Exosuit pins that Materia revision and
  includes the GTK pointer regression in its regular UI suite. No fallback or
  diagnostic logging reintroduced into TextInputBridge. No compiler changes
  made; pre-existing Haxeon/NativeKit gitlink dirt preserved.
- Next: manual graphical acceptance/relaunch when requested; continue remaining
  M9.2 restart and legacy/corrupt session checks. This fixes the reproduced
  geometry rejection; no broader physical IME acceptance claimed.
  Physical desktop IME and non-Linux acceptance remain unclaimed.

## IME geometry fallback reverted and rejection reproduced, 2026-10-02

- User requested reverting the pre-existing uncommitted TextInputBridge retry.
  Restored only that file to its index version; UIKit has no pending file change.
  Original strict NativeKit geometry validation remains enabled.
- Full existing UI/pixel gate passed without fallback (10478, exit 0), log
  `/tmp/exosuit-ime-repro-ui.log`, artifacts `/tmp/exosuit-ime-repro-ui`.
  This gate alone did not reproduce the original geometry defect.
- Separate 91-frame GTK pointer/composition stress fixture reproduced error -2
  before composition cases ran (21366 and diagnostic rerun 45601, exit 1).
  Diagnostic log `/tmp/exosuit-ime-geometry-stress-run2.log` shows frame 54:
  logical selection 181..345, visual endpoints 345..180 with affinities 1..2;
  generated range rect 180..181 lies outside the logical selection.
- Reduced to one pointer drag on frame 4, then to a standalone 67-line app
  with five repeated mixed Unicode lines; reproducer build passed (64338),
  run failed as expected (66704, exit 1). Logs
  `/tmp/exosuit-ime-geometry-minimal-build.log` and
  `/tmp/exosuit-ime-geometry-minimal-run.log`. Source and manifest preserved
  at `/tmp/exosuit-ime-geometry-stress/src/app/DecorationSmokeMain.hx` and
  `/tmp/exosuit-ime-geometry-stress/haxeon.json`. No production code changed.
- Exact repeat: isolated PRAGTICAL_PORTABLE, xvfb-run haxeon run --project
  /tmp/exosuit-ime-geometry-stress/haxeon.json --
  /tmp/exosuit-ime-geometry-stress/project/Main.hx <capture directory>.
  Window 900x600; drag in the text field from local (198,105) to (89,48).
- Root-cause evidence: TextEditorState.placeCaretAt retains the shaping-engine
  visual offset plus affinity separately from the logical offset returned by
  offsetFromPosition. TextField builds IME range rectangles with those visual
  endpoints; TextLayout.selectionRangeRects tags rectangles using raw offsets.
  With an affinity-bearing endpoint, tags can precede the logical selection.
  NativeKit correctly rejects range tags outside the state selection.
- Next: add a retained regression for this endpoint/affinity mismatch and fix
  logical range tagging while preserving shaped visual geometry. Keep native
  validation and avoid empty-geometry retry. Actual desktop IME input is still
  unclaimed; failure reproduced with ordinary pointer selection before IME use.

## Shared terminal and document editor tabs, 2026-10-02

- Implemented typed UiEditorTab variants for document views and owned terminal
  sessions. UiEditorPane.items owns ordered tabs; document-only projections
  continue to serve document controllers without exposing terminal content.
- Move Terminal to Editor and Move Terminal to Panel transfer the same
  UiTerminalTab/TerminalPanel owner, preserving PTY, emulator and scrollback.
  Commands are available in the palette; panel context menus offer transfer
  to editor and editor terminal tab menus offer transfer back and close.
  Multiple terminals can live in either location. Tab switching, movement,
  reordering and closing operate on typed tabs; document actions have no
  active document while a terminal is selected.
- X/Y session records persist editor/panel terminal profiles and placement.
  Same-process restoration reuses live owners by ID/profile. Restart launches
  new shells from profiles; running processes do not survive app shutdown.
- Fixed a renderer defect exposed by transferring terminals: the backdrop
  painter resized emulator rows and invalidated later painters in that frame.
  Resolved dimensions now schedule resize before constructing the next frame.
- Focused real PTY regression passed, log
  `/tmp/exosuit-terminal-transfer-run.log`: repeated transfers, typed tab
  switching, same-process session restoration, two session owners, isolated
  terminal close. Factory counts prove transfer does not spawn replacement PTYs.
- Full UI/pixel gate passed (11102, exit 0), all 53 phases, log
  `/tmp/exosuit-terminal-tabs-full2.log`, artifacts
  `/tmp/exosuit-terminal-tabs-full2`. Initial fixture failures: the generic
  decoration fixture assumed a document remained selected; legacy migration
  fixture captured before creating its terminal. Both fixtures corrected.
  Resize crash was an application bug fixed above, no compiler workaround.
- Headless gate passed (26728, exit 0), log
  `/tmp/exosuit-terminal-tabs-headless.log`; desktop build passed (62248,
  exit 0), log `/tmp/exosuit-terminal-tabs-desktop-build.log`.
- Browser wasm32 build passed but initial focus test clicked the old y=130
  after the document row moved up with header removal. Screenshot confirmed
  normal rendering and clean application state. Updated click to y=95, added
  failure diagnostics/early screenshots; focused browser gate passed (19553).
  Both-target composed gate passed (4441, exit 0), log
  `/tmp/exosuit-terminal-tabs-web-final.log` (Chrome Testing 154). Browser
  manifest regenerated; older Chrome 136 baseline remains pending.
- Final review corrected the panel context handler to UIKit right button=1.
  Extended focused PTY regression passed (43107, exit 0), log
  `/tmp/exosuit-terminal-menu-run.log`, with real pointer opening and selecting
  Move Terminal to Editor and no extra session creation. Screenshot visually
  reviewed at `/tmp/exosuit-terminal-transfer/capture-menu2/frame.png`: Main.hx
  and Terminal 2 share one content-owned tab row. This final pointer-only
  correction was checked with the focused gate; prior full UI/headless/web
  gates above passed before it. Desktop final rebuild passed (21909, exit 0),
  log `/tmp/exosuit-terminal-tabs-desktop-final.log`. Verified pane/terminal
  slice committed locally; no publication. User live app left running.
  M9.2 remains open for actual process restart, keyboard-only acceptance and
  corrupt/legacy/missing session cases; do not mark the milestone complete.

## Editor/tool grouping policy in progress, 2026-10-02

- User's live screenshot still had Editor | Terminal above document tabs:
  singleton header suppression does not fix a mixed dock group. Added general
  DockPanelGrouping metadata (named group, shared tabs or standalone pane).
  Exosuit editor panes are standalone members of editors; tools share tools;
  Explorer belongs to sidebar. UIKit contains no editor-specific IDs or rules.
- Model enforces policy for Center/TabBefore/TabAfter; side splits remain valid.
  Drag preview filters unsupported drops. open selects a compatible group or
  a side split. Terminal explicitly targets Build, then Problems, then a bottom
  split beside the active editor, avoiding the old first-panel fallback.
- Layout installation and restore migrate incompatible tab groups into split
  groups, preserving IDs, within-group ordering/selection and active panel.
  Already valid layout snapshots roundtrip unchanged. No content is copied or
  panel provider retired by grouping normalization.
- UIKit framework passed (51472, exit 0), log
  `/tmp/exosuit-group-policy-framework.log`; covers prohibited tab merges,
  allowed side splits, compatible open fallback, legacy group migration and
  idempotent persistence. Initial fixture compile needed a missing class qualifier.
- Full UI gate runs under handle 29820, log `/tmp/exosuit-group-policy-ui.log`,
  artifacts `/tmp/exosuit-group-policy-ui`. New real PTY fixtures cover reopening
  with Build closed, with all tool panels closed, legacy Editor/Terminal layout
  migration and pointer drag rejection. Poll before UI/build source edits.
  Full UI gate passed (29820, exit 0), including all previous UI/pixel cases.
  Migrated terminal screenshot visually reviewed. Added a terminal factory
  counter; focused migration/drag rerun passed (97113, exit 0), confirming only
  one terminal session is created through migration/reopening. Log
  `/tmp/exosuit-group-policy-terminal-once.log`.
- UIKit grouping policy committed in Materia as `314dabd14`; release.lock updated.
  Exosuit integration remains with pending pane slice. Graphical rebuild passed
  (42808, exit 0), log `/tmp/exosuit-group-policy-desktop-build.log`. Restart the
  live app to load it; preserve user edits when restarting.

## Single editor tab row in progress, 2026-10-02

- Added UIKit DockPanelHeaderMode (Dock/Content) as descriptor metadata.
  Singleton content-owned panels render their own header without a redundant
  dock tab row. Multi-panel groups retain their dock tabs for panel selection.
  Pane cache keys include header mode; model IDs/layout persistence are unchanged.
- All Exosuit editor registrations (initial, split and restored panes) use
  Content mode. Tool panels retain normal dock chrome. Added real UI assertions
  for one document tab row in single/split editor panes.
- UIKit framework passed (41527, exit 0), log
  `/tmp/exosuit-content-header-framework.log`; covers singleton suppression,
  mixed-group tabs, return to singleton, plus existing docking interactions.
- Full UI gate runs under handle 19731, log `/tmp/exosuit-content-header-ui.log`,
  artifacts `/tmp/exosuit-content-header-ui`; poll before source edits/shared
  builds. Full UI gate passed (19731, exit 0), including singleton/split header
  assertions, dock/session roundtrip, pane lifecycle/movement/focus, menus,
  popups and all pixel regressions. Singleton screenshot visually reviewed.
  Pixel checks now derive editor bounds from captured layout rather than assume
  the removed header's old vertical offset. UIKit change committed in Materia
  as `7db5e52bd`; release.lock updated. Exosuit registrations/regressions remain
  with the pending pane slice. Running user app needs a restart; preserve edits.

## Gutter alignment regression in progress, 2026-10-02

- User screenshot exposed independently measured gutter rows: 13 px labels
  estimated document height from a single number while TextArea used themed,
  wrapped text. Replaced fixed row spacing with borrowed editor shaping geometry.
- UIKit TextEditorLayout exposes paragraphCaret and paragraphIndexAtY; TextField
  publishes borrowed text geometry through onLayoutResolved. No document text is
  copied. Exosuit gutter shapes only visible number labels and aligns their
  baselines with actual logical paragraph starts, including wrapped/blank rows.
  Intrinsic gutter height follows the measured text height through layout feedback.
- Focused build/render passed; screenshot visually verified wrapped paragraphs,
  blank rows and subsequent numbered lines after scroll and a newline insertion.
  Added pixel regression against actual paragraph caret baselines.
- Full UI gate runs under handle 31286, log
  `/tmp/exosuit-gutter-alignment-full.log`, artifacts
  `/tmp/exosuit-gutter-alignment-full`. All runtime phases passed; final checker
  initially rejected thin antialiased digits (red channel 168 versus threshold
  200). Corrected the classifier to red >120, green/blue <50; rerunning the full
  pixel checker on the captured artifacts passed all invariants. No product
  inputs changed between runtime run and pixel recheck.
- UIKit framework gate runs under handle 48936, log
  `/tmp/exosuit-gutter-uikit-framework.log`; passed (exit 0), including paragraph
  geometry against fresh shaping after edits. UIKit API/regression committed in
  Materia as `11ed9b914`; release.lock updated. Exosuit gutter integration and
  rendered regressions remain with the pending pane slice. Existing app stays open
  with its old loaded code to preserve unsaved edits.

## Selection viewport clipping regression, 2026-10-02

- User screenshot showed selection leaking into the lower tool panel. A real
  long-document UI fixture reproduces it: text clips but the floating custom
  selection layer paints below the editor viewport.
- UIKit native render compiler now intersects the custom node's resolved
  inherited clip with the command clip stack, including raster-subtree and
  composite paths. Floating layers cannot rely solely on surrounding scissor
  commands. Added a native regression with inherited clip and no scissor stack.
- Native test rebuilt and passed:
  `/tmp/materia-uikit-layout-test/nativekit_ui_layout_render_compiler_test`.
  Focused rendered fixture has 59,153 selection pixels and zero outside the
  resolved viewport. Added that pixel invariant to the full UI suite.
- First full UI run (8074) failed because the fixture wrote bounds before its
  isolated state directory existed. Fixed fixture directory creation.
- Full UI gate runs under handle 97563, log
  `/tmp/exosuit-selection-clip-full-fixed.log`, artifacts
  `/tmp/exosuit-selection-clip-full-fixed`. Poll before UI/native source edits or
  shared builds. Full UI gate passed (97563, exit 0), including the new pixel
  assertion and every prior pane/menu/decoration/multi-caret/popup case.
- Five native compositor/layout tests passed after building their executables.
  Extended the native regression to raster-subtree clipping, verified in
  cache-local coordinates; final render compiler test passed. UIKit fix
  committed in Materia as `1189e5635`; release.lock updated. Exosuit fixture
  remains part of the pending pane slice.
- The user's live app retains its old loaded library; do not close it or discard
  unsaved documents to reload the fix.

## M9.2 — visible DockWorkspace splits in progress, 2026-10-02

- Latest session roundtrip exposed a real ordering defect: WorkspaceSession
  showed the sidebar after restoring the dock, replacing saved editor panel
  activation with Explorer activation. Initialize the sidebar before restoring
  layout so saved selection/focus wins. The strict fixture already verified
  shared dirty recovery, independent carets/scroll and active editor membership.
  Full UI rerun: handle 98867, log `/tmp/exosuit-dock-session-fixed.log`, artifacts
  `/tmp/exosuit-dock-session-fixed`; poll before edits to UI/build inputs.
  The complete UI gate passed (handle 98867, exit 0), including strict session
  roundtrip with exact dock snapshot/session metadata equality and all previous
  pane lifecycle, movement, menu, decoration, multi-caret and popup cases.
- Haxeon String ordering fix committed as `6d8593d5`. Full
  `../haxeon/scripts/test.sh` passed (handle 81286, exit 0), log
  `/tmp/haxeon-string-ordering-full-gate.log`, including typing rejection tests,
  registered runtime regression and Wasm gates. Greater-than preserves source
  operand evaluation order through the existing string comparator intrinsic.
- UIKit explicit scroll ownership committed in Materia as `cc2ae8dcc`; framework
  and full UI passed under handle 15686. Updated release.lock for both verified
  dependency commits. Pre-existing sibling/submodule dirt remains untouched.

- Ownership foundation committed as Exosuit `d49d640`; UI, graphical,
  headless and both fresh browser targets pass. Started this slice clean.
- Added UiEditorPane tab/active-view membership and made host tab/index access
  refer to the active pane. Additional editor panels register in the existing
  shell dock, share Documents and clone only selection snapshots on split.
- Split commands now call WorkbenchHost; UIKit CommandBridge includes them.
  Editor panel content is registered lazily, tabs render per-pane selection,
  and editor focus/pointer events activate their pane before commands run.
  Dock pane descriptors are non-closable so chrome cannot bypass confirmations.
- First compile caught unsupported default-value syntax in an interface method;
  changed the declaration to an optional parameter. The next compile required
  an explicit UiEvent type on a local callback with no function context; added
  it. Visible split graphical build passed (handle 29114, exit 0), log
  `/tmp/exosuit-visible-splits-build.log`.
- Added resolved pane rectangles and text-control focus targets. Directional
  focus selects neighboring editor panes; tab movement preserves a view or
  retires a duplicate when the destination already shows its Document.
  Newly revealed panes request validated focus after layout. Compilation runs
  passed under handle 49001 (exit 0), log
  `/tmp/exosuit-pane-navigation-build.log`. Runtime behavior is not verified.
- Added right/down split UI fixtures checking two resolved text controls,
  orientation, shared Document/buffer, independent selection and directional
  core focus. UI gate runs under handle 23268, log
  `/tmp/exosuit-visible-split-ui.log`, artifacts `/tmp/exosuit-visible-split-ui`.
  Both split fixtures pass; retained right-split image visually reviewed.
  The full UI gate then failed at the file-tree menu: captures/state folders
  accumulated inside the project and clipped Main.hx out of the tree viewport.
  Moved the input project into its own directory, separate from artifacts/state.
- Implemented pane/tab loss calculations across views, dirty guards and pane
  retirement via DockWorkspaceModel.unregister. Shared documents remain open;
  unique documents close through the document manager after lifecycle approval.
  Menus now validate exact view identity across shared-document panes. Explorer
  reopening targets the surviving active editor pane.
- Updated full UI gate runs under handle 75831, log
  `/tmp/exosuit-pane-safe-close-ui.log`, artifacts `/tmp/exosuit-pane-safe-close-ui`.
  This full UI gate passes (handle 75831, exit 0), including prior menus,
  decorations, multi-carets and caret popups.
- Rebind retained EditorPane focus/geometry/context callbacks when a view moves
  between panes; old callbacks must not activate its former pane. Added real UI
  cases for shared dirty-pane close without a prompt, unique dirty close with
  Escape cancellation/discard, unique view movement and duplicate retirement,
  followed by focus on the destination's rendered editor.
- Expanded UI gate runs under handle 38424, log
  `/tmp/exosuit-pane-lifecycle-ui.log`, artifacts `/tmp/exosuit-pane-lifecycle-ui`.
  This gate passes (handle 38424, exit 0), including all lifecycle/movement
  cases and the prior UI suite. This slice remains uncommitted.
- Per-view ScrollController ownership now follows tabs across pane moves;
  UiDocumentView reads/restores offsets and passes the controller to EditorPane.
  UIKit ScrollView honors an explicitly supplied controller instead of replacing
  it with a previous widget instance's stored controller. Implicit controllers
  retain existing state behavior. Framework tests replace a supplied controller
  at the same widget key and assert the correct object and offset survive.
- First scroll compile caught a stale, unused State parameter in the scrollbar
  helper; removed it. Updated popup fixture to use the view-owned controller
  rather than inspect implicit widget state. UIKit/framework followed by full
  UI runs under handle 15686, logs `/tmp/uikit-owned-scroll-controller.log` and
  `/tmp/exosuit-owned-scroll-ui.log`. Poll before source edits/shared builds.
  Materia now has two owned dirty UIKit files (ScrollView and FrameworkSmoke),
  in addition to preserved TextInputBridge/submodule dirt.
  UIKit/framework and full UI pass (handle 15686, exit 0).
- Added host session records for pane membership (P), per-pane views (V), last
  active editor pane (Q) and versioned dock snapshot (D/dock/1). WorkspaceSession
  validates field/identity/coordinate bounds without depending on UIKit; the
  dock snapshot codec validates its own payload during host restore. Existing
  T/A records remain as a flat document fallback for older readers, and old
  single-pane sessions still restore through T records. Only metadata is added.
- Restore retires every old view/pane, registers saved pane identities, resolves
  shared Documents through the existing session resolver cache, restores each
  caret/scroll offset, then applies the dock snapshot. Invalid/missing layout
  payloads reopen resolved panes rather than lose document views.
- First session compile rejected relational comparisons of String characters
  (E1011). Pane IDs require ASCII ordinal ranges, so validation now uses numeric
  charCodeAt ranges. Follow COMPILER-TYPING to reduce and compare the String
  operator semantics with the local Haxe reference before classifying a compiler
  defect; do not silently dismiss valid typing defects.
- Session graphical build passes (handle 69878, exit 0), log
  `/tmp/exosuit-dock-session-build.log`.
- COMPILER-TYPING audit confirms String relational operators are valid Haxe:
  local `.tools/haxe/haxe --interp` returns true for a character range reducer.
  Haxeon compareTyped currently permits String equality but sends ordering to
  numeric-only validation. Fix the general rule using existing
  `__string_compare_full`, preserving original left/right evaluation order even
  for reversed greater-than operators; keep mixed/non-numeric invalid cases.
  Native, Wasm32 and Wasm-GC already implement the comparator intrinsic.
- Added registered runtime regression `tests/programs/string-ordering.hx` with
  dynamically produced strings, equality boundaries, prefix/Unicode ordering and
  side-effect order. Its pre-fix compile runs under handle 8935, log
  `/tmp/exosuit-string-ordering-before.log`; poll before compiler source edits.
  Haxeon pre-existing hashlink/.claude/hlprofile dirt remains untouched.
  Restart/corrupt/missing-file/legacy session tests and final composed gates
  remain pending. Audit fallback dock geometry/defaultRoot after unregister,
  active-pane visibility in dock tab groups, and empty-pane keyboard focus.
- Next: fix compile failures, add a real UI split fixture proving two resolved
  editors with independent selections on shared text, then directional focus,
  tab move, lifecycle pane close and session/dock/scroll persistence. Current
  restore/dispose/loss calculations still need the multi-pane audit. The
  split-pane checklist remains open. Also audit menu guards against exact view
  identity: switching panes that show the same Document must retire old targets.
  Audit tab-switch commands, pane visibility and diagnostics across all views.

## M9.2 — split-pane ownership foundation verified, 2026-10-02

- Exosuit was clean at `c3fe35e` before this slice. Menus are committed as
  `5f1c320`; NativeKit `5067eba0` and Materia `5cebf86d6` gates passed.
- Removed the host's document-global selection map. Each UiDocumentView owns
  its selection and a buffer subscription, following the existing DocumentView
  passive change transformation. Shared text stays in the Document buffer.
  Active edit cursor placement remains owned by TextBuffer's transaction.
- Closing a tab, restoring sessions and shutting down release the subscriptions;
  disposal is idempotent. A real UI fixture exercises independent views on one
  document, active/passive cursor behavior across multiline insert and undo,
  and retirement of the disposed view's callback.
- Selection ownership UI gate passed under handle 96154 (exit 0), log
  `/tmp/exosuit-pane-selection-model-ui.log`. Added stable UiDocumentView IDs
  and switched retained EditorPane/caret lookup and retirement to view IDs.
  The identity fixture also asserts two views sharing a document differ in ID.
- Identity-only UI and graphical build passed. Review caught an over-broad
  replacement in the tab-selection callback: tab keys encode document IDs,
  not view IDs. Stopped the unfinished headless chain (handle 11475, exit 143)
  before source edits; restored `documentView.document.id == id`.
- Extended the fixture to reopen a document after creating/discarding extra
  views, then activate that tab with real pointer events. It requires active
  view ID and document ID to differ, so equal counters cannot conceal the bug.
- Reopened-view pointer regression passes, followed by the complete UI suite
  and final graphical build. Headless suite and Wasm32 browser smoke pass;
  final Wasm-GC browser check also passes (handle 1276, exit 0). Logs
  `/tmp/exosuit-pane-ownership-final-{ui,build,headless,web}.log`, UI artifacts
  `/tmp/exosuit-pane-ownership-final-ui`. All handles are terminal.
  Split-pane checklist remains open: this verifies ownership, not visible splits.
- Next: add pane tab membership and scope widget identity per pane, render editor
  DockWorkspace splits, route split commands through WorkbenchHost, and implement
  directional focus/movement and close confirmation. WorkspaceSession currently
  validates only legacy S/T/A lines; DockWorkspace persistence needs an explicit,
  validated format extension and migration of existing single-pane sessions.
- Pane audit: UiDocumentView.scrollX/scrollY return zero and restoreScroll is a
  no-op. Wire retained ScrollController offsets to each view/session. Directional
  focus must use actual resolved editor-pane rectangles; pane close must retain
  FileController confirmation and exclude documents still shown in other panes.
  Dock chrome must not bypass lifecycle confirmation. Keep shared buffers and
  independent view state; do not duplicate document text for splits/persistence.
- Use the existing shell DockWorkspaceModel for additional editor panels, rather
  than nesting a second workspace. The renderer already computes pane widths
  from the outer split tree; one dock snapshot also preserves sidebar/tool
  geometry consistently. Keep the last active editor pane while a tool/sidebar
  has focus. Register dynamic editor panel content lazily from pane membership.

## M9.2 — editor/tab/tree command menus verified, 2026-10-02

- Implemented CommandMenu/CommandMenuEntry with current registry predicates,
  omission of unregistered commands and target validation immediately before
  activation. Editor retains selection; tabs activate their document; tree
  targets its selected file/project. Stale document/path/project targets retire.
  Editor, tab and tree support Shift+F10 and Menu; pointer opens on the right button.
- Exosuit editor Tabs now uses existing Controlled selection mode so context
  activation of an inactive tab changes the displayed page as well as the core
  active document. Actions include edit/clipboard/find, tab save/close and tree
  create/rename/delete, routed through existing confirmation and controller
  flows. Only command metadata is copied, not document text.
- Generic UIKit Menu fits viewport width/height, scrolls oversized content and
  clamps/flips its measured popup. Menu navigation handles arrows before the
  scroll container, starts on a command and reveals keyboard destinations in
  transformed coordinates. All-disabled menus retain an Escape target.
  BuildContext/UiContext provide validated focus-after-layout requests for
  newly revealed widgets. Queue is cleared on consumption/disposal.
- Real UI coverage adds 14 menu scenarios, including a retained visual capture,
  editor/tab/tree pointer and keyboard delivery, document switch, stale action,
  changed predicate, viewport edge, Escape/outside and dirty-close confirmation.
  Bounds assertions locate the measured popup panel, not its fullscreen root.
- Initial fixture/source compilation failures (missing import/fields, nullable
  resolved geometry reused across pointer callbacks) were corrected using
  declared fields and checked geometry snapshots; no casts or typing changes.
  The oversized-menu regression exposed layout/screen coordinate confusion;
  fixed conversion and assert every navigation step, final visibility and action.
- Final desktop UI (14 menu scenarios plus existing decoration/popup checks),
  graphical build and headless suite passed. Updated UIKit framework and all
  four NativeKit browser integration programs also pass, including ContextMenu
  key normalization and canvas handoff without stealing external control focus.
- The stronger composed browser regression exposed two DOM focus issues:
  deactivating the hidden IME left focus on BODY; returning from the menu to
  the IME then reported canvas blur as native window focus loss. Select All
  ran and visibly selected the document, but that spurious event cleared the
  restored toolkit focus. NativeKit now hands inactive IME focus to canvas and
  observes non-capturing window focus/blur rather than canvas DOM focus/blur.
- Fresh composed Wasm32/Wasm-GC verification of this latest focus change is
  passed under handle 74371 (exit 0), log
  `/tmp/exosuit-command-menu-window-focus-web.log`, including Select All,
  ContextMenu-key Escape, resumed typing, save and fresh-session reload.
- Window focus listeners now have one shared lifetime and broadcast actual
  window focus to live surfaces; removing a surface does not remove the other
  surfaces' listener. NativeKit regression checks internal canvas/IME handoffs
  produce no inactive window state and actual window blur/focus changes state.
  The first regression compile caught a duplicate fixture-local name; renamed
  it. Synthetic blur also queues released keys/window events, exhausting a
  later request test's bounded poll loop; the fixture now consumes its events.
- Final serial NativeKit browser gate, graphical build and both fresh browser
  targets pass (handle 8293, exit 0). Logs
  `/tmp/nativekit-menu-window-focus-tests.log`,
  `/tmp/exosuit-menu-window-focus-build.log` and
  `/tmp/exosuit-menu-window-focus-final-web.log`. The headless gate passed
  `/tmp/exosuit-command-menu-headless.log`; final UIKit and real UI logs are
  `/tmp/uikit-context-menu-browser-focus-framework.log` and
  `/tmp/exosuit-command-menu-browser-focus-ui.log`. The retained menu capture
  was visually reviewed. All handles are terminal.
- NativeKit `5067eba0` commits browser keys/focus and regressions. Materia
  `5cebf86d6` commits the seven owned UIKit files; TextInputBridge and existing
  submodule dirt remain untouched. release.lock pins both owned commits.
  Context-menu checklist is complete. Chrome 136 reload compatibility remains
  unresolved; passing Chrome 154 checks do not prove that older-browser case.
- Exosuit `5f1c320` commits the integrated menus, UI/browser regressions and
  release inputs. README and architecture known gaps now reflect delivered
  menu/caret/styled-text behavior.
- Next: M9.2 DockWorkspace split panes, directional focus, tab movement and pane
  close, with session restoration. Existing split commands require legacy
  RootView and must be moved to the WorkbenchHost boundary. Each pane needs its
  own UiDocumentView/selection and widget identity while sharing the Document
  buffer; persistence must restore dock geometry, pane membership and active
  view. Keep lifecycle confirmations and shared-document close semantics.

## M9.2 — tab context-menu foundation verified, 2026-10-02

- Caret popup slice committed as Exosuit `4b594bf`; browser harness diagnostics
  are `7dc2d29`, UIKit geometry is Materia `c781ddac6`. Exosuit was clean before
  starting this next slice.
- Generic Tabs now offers onTabContextMenu, also through TabsOptions. Enabled
  headers report right-pointer presses and Shift+F10 without changing page
  selection; consumers decide which tab becomes the command target. Disabled
  headers remain inert and pointer drag keeps its primary-button behavior.
- Framework coverage exercises pointer target identity, unchanged selected
  page/change count, Shift+F10 versus unmodified F10, and disabled headers.
  `/tmp/uikit-tab-context-menu-framework-final.log` passes, exit 0. First
  compile caught an ordinary duplicate local fixture name; renamed scoped
  test locals, with no compiler workaround or compiler change.
- Graphical build and both fresh browser target smokes pass, exit 0:
  `/tmp/exosuit-tab-context-{build,web}.log`. Browser smoke uses isolated
  Chrome for Testing 154; Chrome 136 compatibility remains unresolved. All
  handles are terminal. Materia commit `acc270e7a` contains only Tabs,
  TabsOptions and its framework regression; release.lock pins that commit.
- Resume by implementing editor/tab/tree command-menu surfaces. Commands must be enabled
  from current CommandRegistry predicates and validated again on activation;
  menus must retire if their target document/path is no longer current.
  M9.2 context-menu checkbox remains open until all three surfaces work.

## M9.2 — caret-anchored language popups verified, 2026-10-02

- UIKit exposes a dedicated nullable visible caret rectangle callback and
  measures popup placement against live logical-screen anchors. Popups flip
  above the caret or clamp to viewport bounds using bounded layout feedback.
  Materia commit `c781ddac6` contains only the two owned widget files;
  pre-existing TextInputBridge and submodule dirt remain untouched.
- Exosuit follows the active document's resolved caret for hover, completion
  and signature help, supports scrolling oversized content, and dismisses on
  document switch or when scrolling clips the caret. No text materialization
  or document copy is introduced for anchoring. M9.2's first checklist item is
  complete; menus and pane operations are still open.
- Real graphical fixtures pass all eight popup scenarios (hover, completion,
  signature, edge placement, document switch, large content, scrolling and
  clipped dismissal), plus prior decoration/multiline pixel regressions:
  `/tmp/exosuit-caret-visibility-ui.log`, exit 0.
- Final source `./scripts/build.sh` and `./scripts/test.sh` pass, logs
  `/tmp/exosuit-caret-popup-final-{build,headless}.log`. Fresh composed
  `EXOSUIT_CI_WEB=1 EXOSUIT_WEB_BROWSER=/tmp/exosuit-chrome-testing/chrome-linux64/chrome
  ./scripts/test-web.sh` passes both Wasm32 and Wasm-GC with Chrome for Testing
  154.0.8037.92 (`/tmp/exosuit-caret-popup-current-chrome-web.log`, exit 0).
  UIKit `tools/test-haxeon-framework.sh` also passes
  (`/tmp/uikit-caret-popup-framework.log`, exit 0). All handles are terminal.
- Browser diagnostics/protocol wait budget committed as Exosuit `7dc2d29`.
  Installed Chrome 136's cancellation failure remains unresolved; current
  browser qualification does not prove older-browser compatibility. Physical
  IME/mixed-DPI/Windows/macOS checks and release composition with pre-existing
  dirt remain pending. No full milestone or full roadmap completion claimed.
- Resume with M9.2 editor/tab/file-tree context menus through CommandRegistry.
  TreeView already has onItemContextMenu; inspect Tabs' missing tab hook and
  reuse UIKit Menu keyboard handling with bounded placement. Preserve the
  Chrome 136 evidence and investigate it separately from popup geometry.

## Browser reload — interaction and browser-version isolation, 2026-10-02

- Diagnostic variants use existing built Wasm-GC assets, not final-source
  validation. Startup-only, focus-only, selection-only and Unicode insertion
  each pass 12 fresh sessions. Adding the ordinary `!` keyboard event fails
  in session 1 (`/tmp/exosuit-character-reload-1.log`), canceling both fonts.
  Text insertion/character/newline without save fails in session 4; removing
  documentation URL interception fails in session 1. Ordinary `location.reload()`
  also fails in session 12. None of these narrow passes supersedes the failures.
- A standalone textarea with the same input/key sequence and large simulated
  guest/resource fetches passes 100 edit/reload cycles
  (`/tmp/exosuit-minimal-reload-character.log`, exit 0). Earlier plain-page
  40-cycle run completed its observations but exited 1 during profile cleanup;
  corrected subsequent 100-cycle runs exit 0. Key-event tracing confirms editor
  Ctrl+A, Enter and Ctrl+S keydowns prevent browser defaults.
- Complete Chrome NetLog retained at `/tmp/exosuit-complete-netlog-3.json`:
  new-document canceled script requests do not reach its network request log.
  Renderer/browser ownership remains an investigation direction, not a proven
  root cause.
- Isolated official Chrome for Testing 154.0.8037.92 passes 12 full interaction
  and reload sessions (session 1 `/tmp/exosuit-new-chrome-longtimeout.log`,
  sessions 2–12 `/tmp/exosuit-new-chrome-N.log`). Installed Chrome
  136.0.7103.92 retains its reproduced cancellation issue; it has not been
  fixed or suppressed, and no installed browser was replaced.
- First Chrome 154 run hit the connector's five-second socket observation
  timeout during startup. Diagnostic protocol waits bounded at 30 seconds
  pass. Smoke now sets protocol timeout to min(30 seconds, requested overall
  budget), retaining active-document error assertions and all interaction
  checks. Optional lifecycle tracing remains diagnostic only.
- Fresh GraphicalMain build, headless suite, then both browser targets with
  Chrome 154 are running serially under process handle 75947; logs
  `/tmp/exosuit-caret-popup-final-{build,headless}.log` and
  `/tmp/exosuit-caret-popup-current-chrome-web.log`. Poll this handle before
  starting shared builds. Older-browser compatibility stays unresolved.

## Browser reload — script cancellation also reproduced, 2026-10-02

- Optional `web/tools/smoke.py --trace-lifecycle` records bounded fetch and
  document lifecycle timing in newly created documents without changing pass
  criteria. Python compilation passes. Existing built assets were used only
  for diagnosis, not current-source validation.
- `/tmp/exosuit-reload-lifecycle-1.log` passes; sessions 2 and 5 fail with
  `ReferenceError: HaxeonWasmHost is not defined` in the new reload document.
  Sessions 3–4 pass. Both serial diagnostic batches stopped at their first
  failure; all process handles are terminal.
- Session 2 attributes canceled requests for `haxeon-host.js`, `exosuit.js`
  and `exosuit_web.js` to the new loader. Its lifecycle trace reaches load
  and pageshow, then completes the host Wasm fetch; it contains no pagehide
  or beforeunload. This broadens the failure beyond NativeKit font loading;
  do not implement font retry or suppress startup errors as a fix.
- Resume by investigating reload request cancellation across scripts and
  resources, using retained `/tmp/exosuit-reload-lifecycle-{2,5}` artifacts.
  Determine the source of cancellation before changing application resource
  lifetime. Popup source remains uncommitted; fresh final-source desktop and
  both browser gates remain required.

## Browser reload — active-document font cancellation reproduced, 2026-10-02

- Diagnostic sessions 1–2 pass; session 3 fails
  (`/tmp/exosuit-reload-attribution-3.log`, exit 1). Attribution identifies
  canceled `assets/IBMPlexSans-Regular.ttf` and `assets/NotoEmoji-Regular.ttf`
  fetches in loader `A712096E96A0F0CE69C1D2696548F983`, the newly committed
  reload document. Initiator is `nk_web_fetch_resource` through
  BrowserUiHost.loadFonts/initialize/start and WebMain.main.
- That document reports failed after one frame, with "The editor stopped with
  an error". Server/browser logs are retained in
  `/tmp/exosuit-reload-attribution-3`. This is an active-document resource
  failure, not evidence that the existing pagehide retirement is insufficient.
- Resume by tracing NativeKit browser resource cancellation and BrowserUiHost
  startup/frame lifetime. Preserve real active-document errors; do not swallow
  canceled requests or turn passing retries into completion evidence.

## Browser reload — request attribution investigation, 2026-10-02

- Smoke diagnostics now correlate canceled requests with URL, document URL,
  loader/frame identity and initiator, retaining at most 256 pending entries
  and dropping completed requests. This changes failure evidence only.
- A diagnostic run of the already-built Wasm-GC site passes
  (`/tmp/exosuit-reload-request-attribution.log`); it does not explain or
  supersede the earlier canceled-fetch failure, or validate the newer clipped
  caret code. Fresh sessions are running serially, stopping at the first
  failure (up to 12), with logs `/tmp/exosuit-reload-attribution-N.log` and
  server/browser artifacts `/tmp/exosuit-reload-attribution-N`.
- Resume by polling that diagnostic process. On reproduction inspect the
  attributed request and loader before changing lifecycle code. Final source
  rebuilds and composed browser gates remain required.

## M9.2 — clipped caret implementation in verification, 2026-10-02

- TextField's dedicated caret callback now accepts nullable geometry and
  checks resolved visibility plus intersection with the editor's clip bounds.
  EditorPane retains null for a clipped caret; ExosuitApp dismisses a visible
  language popup when its current anchor becomes unavailable.
- Fixtures now choose visible caret positions for normal/edge cases and cover
  both a 24-pixel outer-controller scroll with unchanged selection and a larger
  scroll that removes the caret from view. The full capture suite passes
  (`/tmp/exosuit-caret-visibility-ui.log`, exit 0), retaining
  `/tmp/exosuit-caret-visibility-ui` artifacts. Resume by verifying
  GraphicalMain/browser behavior and diagnosing the reload failure.
- Browser reload still needs diagnosis. The launcher already retires callbacks
  on pagehide, and the harness waits for a committed/loaded new main-frame
  context. The failure reports a canceled guest fetch in the new state.
  Gather request URL/loader attribution before altering lifecycle behavior;
  preserve failure of genuine active-document startup errors.

## M9.2 — visual review and clipped caret follow-up, 2026-10-02

- Headless suite and actual GraphicalMain build pass
  (`/tmp/exosuit-caret-popup-headless.log`,
  `/tmp/exosuit-caret-popup-build-final.log`). Both browser targets build, but
  the Wasm-GC smoke gate fails on a canceled guest fetch during reload
  (`/tmp/exosuit-caret-popup-web.log`, chain exit 1). Investigate the reload
  lifecycle/context evidence; do not discard the failure as a passing retry.
- Visual inspection of
  `/tmp/exosuit-caret-popup-scroll-ui/popup-scroll/frame.png` exposes a missing
  lifecycle case: its caret lies outside the outer editor clip, yet the popup
  remains visible over another panel. Existing bounds assertions do not cover
  anchor visibility. Do not commit/complete this slice from those tests alone.
- Next: publish nullable caret geometry when outside ResolvedLayoutItem's
  clipBounds, retire language popups whose current anchor is unavailable, and
  test both a visible retained-controller scroll and scrolling the caret out
  of view. Make the edge fixture reveal its caret before opening a popup.
  Re-run focused captures and relevant build/browser gates after that change.
- The read-only Pragtical reference is `/home/joao/dev/pragtical`, branch
  `next`, rather than the missing default sibling. Its context-menu plugin
  dispatches registered commands and provides keyboard activation/navigation;
  preserve its uncommitted sidebar/scroll work for the later roadmap items.

## M9.2 — caret popup functional gate passes, 2026-10-02

- Final unchanged-script run passes all popup phases, including hover,
  completion and signature following caret movement, measured edge placement,
  an 80-line scroll-constrained result, document-switch retirement and the
  real outer editor ScrollController moving the popup while selection stays
  unchanged (`/tmp/exosuit-caret-popup-scroll-ui.log`, exit 0).
  Previous decoration, multicaret and multiline syntax pixel checks pass too.
- Integration gates are running sequentially: headless
  `/tmp/exosuit-caret-popup-headless.log`, actual GraphicalMain build
  `/tmp/exosuit-caret-popup-build-final.log`, then both browser targets
  `/tmp/exosuit-caret-popup-web.log`. Do not claim the latter gates until
  their final outputs and chain exit are checked.
- Owned changes remain uncommitted in UIKit Popup/TextField and Exosuit's
  EditorPane, ExosuitApp, UiWorkbenchHost and decoration test fixture/script.
  Preserve pre-existing TextInputBridge and sibling gitlink dirt. Resume by
  polling this gate chain, reviewing the diff and committing the verified
  UIKit slice, its release pin and Exosuit integration. Then proceed to M9.2
  editor/tab/file-tree context menus through CommandRegistry.

## M9.2 — final capture rerun, 2026-10-02

- The large-result phase passes, but its first suite run exits 2 because the
  executing shell script was edited while Bash was reading it. That run does
  not validate the scroll phase. The finalized script passes `bash -n` and is
  rerunning unchanged in `/tmp/exosuit-caret-popup-final-ui.log`, retaining
  `/tmp/exosuit-caret-popup-final-ui` artifacts.
- Inspection shows EditorPane scrolls its gutter and TextArea through an
  outer ScrollView; the new scroll fixture currently targets TextEditorState's
  internal scroll. If it fails for lack of internal overflow, fix the fixture
  to exercise the real outer controller and retain the unchanged selection.
  The rerun exits 1 with "popup fixture could not scroll retained editor".
  The fixture is corrected to use the real outer ScrollController, keeping
  selection unchanged. A new unchanged-script run is live in
  `/tmp/exosuit-caret-popup-scroll-ui.log` with artifacts under
  `/tmp/exosuit-caret-popup-scroll-ui`. Resume by checking this process/log.
  Do not edit a running script or shared build inputs during the rerun.

## M9.2 — popup capture results and content bounds, 2026-10-02

- Initial real-editor popup captures pass hover/completion/signature caret
  movement, viewport-edge placement and document-switch retirement
  (`/tmp/exosuit-caret-popup-ui.log`, exit 0). All earlier decoration and
  multiline syntax pixel checks also pass.
- Language content now uses a viewport-bounded ScrollView; panel width is
  limited to available viewport width. Overlay builders receive BuildContext
  directly so limits follow the current viewport instead of cached dimensions.
- Additional fixture phases cover an 80-line hover result and a retained
  editor scroll without changing its selection. Verification is running in
  `/tmp/exosuit-caret-popup-large-ui.log`; artifacts are retained under
  `/tmp/exosuit-caret-popup-large-ui`. Edits remain uncommitted. Resume by
  checking this handle/log, verifying the newly added scroll phase ran on the
  final compiled fixture, then completing functional/headless/browser gates.

## M9.2 — measured anchor placement in progress, 2026-10-02

- Generic Popup has an optional live logical-screen anchor provider. After
  its panel resolves, placement uses its actual width/height, flips above
  when below would overflow, clamps against its parent bounds and requests
  native layout feedback only when the position changes.
- Language popups use this provider and retire when the active document
  changes; dismissal clears retained anchor state. These changes remain
  uncommitted and require rendered lifecycle/placement tests, including
  oversized content and scroll behavior.
- Initial compilation rejected calling a nullable mutable provider field
  inside the deferred handler. The handler now reads and checks its provider
  locally when invoked, so changes between build and resolve are handled.
  This is a corrected nullable lifecycle check, not a compiler change.
  GraphicalMain rebuild passes
  (`/tmp/exosuit-anchored-popup-build-final.log`, exit 0).
- Real-editor phases now assert resolved hover/completion/signature bounds
  track caret movement, edge anchors stay within the viewport and popups
  retire on document switch. The complete capture suite is running in
  `/tmp/exosuit-caret-popup-ui.log`, retaining artifacts under
  `/tmp/exosuit-caret-popup-ui`. Resume by checking that process/log and
  fixing failures; scroll and oversized-content cases still need coverage.

## M9.2 — caret geometry plumbing in progress, 2026-10-02

- UIKit TextField now has an optional typed `onCaretRect` callback publishing
  logical screen-space bounds when its text geometry resolves. EditorPane
  retains that rectangle separately from diagnostic reporting.
- These edits are uncommitted; GraphicalMain compilation is running in
  `/tmp/exosuit-caret-geometry-build.log`. Resume by checking compilation,
  wiring active-pane geometry to UiWorkbenchHost and Popup placement, then
  testing movement, scrolling, tab switches and edge placement. The host's
  fixed coordinates have now been replaced: the host queries the active pane,
  popups use its caret bottom, and geometry changes request a refresh only
  while a popup is visible. GraphicalMain compilation passes
  (`/tmp/exosuit-caret-popup-build.log`, exit 0). Edge placement, active-document
  retirement and rendered behavioral tests remain; M9.2 is not complete.

## M9.1 acceptance audit complete; M9.2 active, 2026-10-02

- Styled foreground, background, underline/wavy underline and whole-line
  backgrounds are implemented through UIKit's typed ranges/decorations.
  Native row-publication tests prove unchanged ASCII and general-Unicode rows
  preserve their publication identity; isolated color changes preserve other
  row objects and measured geometry (`/tmp/exosuit-row-color-invalidation.log`).
- Real-editor pixels verify multiline syntax repair and undo, diagnostic
  movement/clearing, search, brackets/current line, multiple selections and
  caret rendering. Transactional multi-caret typing, paste, undo and wrapped
  navigation pass (`/tmp/exosuit-multiline-syntax-ui.log`, Exosuit `22001d1`).
- The rebuilt/runtime-verified typing captures pass the M7.1 p95 budget on
  small Unicode, 1 MiB long line and 10 MiB fixtures (37.79, 39.47 and 30.96 ms).
  Native correctness/lifetime, browser and headless gates pass as recorded
  above. M9.1's checklist is complete; full M9 and M8–M15 remain incomplete.
- Active task: M9.2 caret-anchored hover, completion and signature popups.
  Replace fixed host coordinates with current logical screen-space caret
  geometry. Add a dedicated typed widget callback rather than depending on
  diagnostic reporting; popup anchors must refresh after scrolling, selection
  changes, layout, and active-document switches. Verify actual rendered popup
  placement and edge clamping before marking the item complete.

## M9.1 — multiline syntax acceptance fixture in progress, 2026-10-02

- The real decoration fixture now warms a multiline comment, closes its
  opening boundary, and renders undo in a separate phase. Pixel assertions
  require the following row's keyword color to appear after the boundary edit
  and return to the original comment-colored rendering after undo.
- Verification passes (`/tmp/exosuit-multiline-syntax-ui.log`, exit 0), with
  artifacts retained in `/tmp/exosuit-multiline-syntax-ui`. Actual multiline
  keyword pixels repair after the edit and undo, alongside all previous
  decoration checks. Resume with the M9.1 requirement audit, then M9.2.

## M9.1 — row color invalidation audit, 2026-10-02

- Final decoration smoke passes (`/tmp/exosuit-shared-rows-decoration-final.log`,
  exit 0), including actual pixels for diagnostic movement/clearing, search,
  brackets/current line, additional selections, multi-caret typing/undo and
  wrapped navigation.
- Materia `8feeec885` adds an explicit general-Unicode foreground regression:
  changing only the middle row's colors preserves the first/last published
  objects, does not rebuild measured layout, leaves vertex geometry unchanged,
  and restores the original middle publication when colors are removed.
  The native TextEngine gate passes (`/tmp/exosuit-row-color-invalidation.log`).
- M9.1 remains open pending a direct multiline syntax repair acceptance check.
  Resume by adding a real-editor multiline syntax edit fixture and verifying
  its repaired colors, then audit the first M9.1 checklist item against all
  evidence before moving to M9.2 caret-anchored popups.

## M9.1 — shared rows and measured edit costs, 2026-10-02

- Skribidi `572e8c8`, pinned by Materia `30b65a472`, retains immutable
  prefix/suffix row blocks for equal-advance edits and rebuilds only affected
  rows. Bulk compatibility caches are separate; indexed reads stay allocation
  free. Source mutation, ellipsis, destruction, child generations and explicit
  bulk-cache/reset lifetime checks pass. Shape measurement uses a sequential
  piece cursor and stops word lookahead after the first full-row overflow.
- Native differential probe, vendor units and ASan/leaks pass (the
  `/tmp/exosuit-shape-cursor-{probe,unit,asan}.log` artifacts). Native 1 MiB
  mixed edits measure 12.05 ms mean CPU; stable edits rebuild at most four rows.
  Final UIKit native checks pass 3/3
  (`/tmp/exosuit-shared-rows-uikit-final.log`). Both browser gates pass
  (`/tmp/exosuit-shared-rows-web.log`). Full headless tests pass
  (`/tmp/exosuit-bounded-buffer-offset-tests.log`). Graphical build passes as
  part of each benchmark, with actual loaded UIKit hashes recorded.
- Fresh typing captures pass across 30 input frames each: small Unicode
  37.79 ms p95 (`/tmp/exosuit-shared-rows-small`), 1 MiB varied-key long line
  39.47 ms p95 (`/tmp/exosuit-bounded-buffer-offset-1mb`), and 10 MiB
  30.96 ms p95 (`/tmp/exosuit-shared-rows-10mb`). These are single captures;
  they do not establish universal latency or complete the milestone.
- Resume M9.1 by checking final decoration behavior and the remaining
  changed-row invalidation requirements. Changed wrapping still owns full row
  arrays; general styled Unicode uses the correct fallback. Do not mark M9
  complete from the guarded ASCII or these typing fixtures alone.

## M9.1 — typing verification correction, 2026-10-02

- The earlier delivered-input typing captures do not validate the recent native
  revisions: the benchmark launched an existing GraphicalMain build without
  rebuilding it. Its loaded UIKit library was built at 04:28:37, before the
  indexed reflow, affected-row and indexed-query commits. Historical results
  below are retained as observations, but their revision-specific typing gate
  claims are withdrawn. Decoration smoke builds a separate test application.
- Exosuit `5812357` makes the benchmark rebuild GraphicalMain before capture,
  records repository
  revisions and source/binary hashes, and checks the actual UIKit mapping in
  `/proc/<pid>/maps` against that build before delivering input.
- A fresh 1 MiB varied-key capture fails the 50 ms budget: 85.46 ms p95,
  76.14 ms input-dispatch p95, 9.89 ms frame p95. Artifacts:
  `/tmp/exosuit-shared-rows-1mb-fresh`. Loaded UIKit SHA-256:
  `f2d27d62a3ca4f024f934e1281ae56226d5b34bcaa797eaf60939cb4026f05d0`.
- A diagnostic trace confirms incremental ASCII shaping succeeds for the real
  fixture (approximately 9,710 rows); full-layout fallback is not the cause.
  Temporary phase instrumentation measured native edits at roughly 42–53 ms,
  text assembly at 0.07–0.26 ms and row publication at 0.16–0.19 ms
  (`/tmp/exosuit-shared-rows-phases`). The diagnostic capture still fails at
  81.88 ms p95; instrumentation was removed after measurement. M9.1 remains
  incomplete. Resume by profiling the native changed-wrap line builder and
  remaining editor dispatch; row publication is not the dominant native cost.
- Native line-builder instrumentation confirms the real insert/delete fixture
  rebuilds all 9,710 rows with no prefix/suffix reuse. Wrap measurement costs
  roughly 32–46 ms, culling 6.4 ms and alignment 0.16 ms, measuring about
  2.1 million clusters per edit. Artifacts:
  `/tmp/exosuit-shared-rows-native-phases`. The diagnostic capture fails at
  68.39 ms p95; this shorter capture is not a matched speedup claim.
  Instrumentation was removed. Next: reduce changed-wrap measurement and
  support exact suffix reuse when edits shift row boundaries/counts, preserving
  fresh-layout equivalence and the general Unicode fallback.
- The guarded WORD_CHAR reflow now ends lookahead at the first full-row
  overflow instead of measuring two row widths. Beyond that point the word
  must split, so further measurement cannot change the decision. The full
  differential probe passes, including 240 accepted edits and 100-generation
  variable-width checks with 692 moved wraps; native 1 MiB mixed edits measure
  18.79 ms mean CPU (`/tmp/exosuit-one-row-lookahead.log`). Vendor units and
  ASan/leak checks pass (`/tmp/exosuit-one-row-units.log`,
  `/tmp/exosuit-one-row-asan.log`). Actual rebuilt-app typing is still pending
  in `/tmp/exosuit-one-row-lookahead-1mb`; no budget pass is claimed.
- A sequential measurement cursor reads cluster, advance, text and flags
  from one immutable shape piece instead of independently looking up each
  value. It checks both boundaries when lookahead restarts and retains the
  general non-indexed path. No shape buffers are flattened or copied.
  Full differential checks, vendor units and ASan/leaks pass
  (`/tmp/exosuit-shape-cursor-probe.log`, `/tmp/exosuit-shape-cursor-unit.log`,
  `/tmp/exosuit-shape-cursor-asan.log`). Native 1 MiB mixed edits measure
  12.05 ms mean CPU. The fresh 90-second varied-key app capture fails at
  60.29 ms p95 (`/tmp/exosuit-shape-cursor-1mb`); the 50 ms gate remains red.
  both browser targets build and pass typing, save/readback, URL and reload
  (`/tmp/exosuit-shared-rows-web.log`, exit 0).
- Temporary Haxe editor-phase instrumentation measures document mutation at
  approximately 0.1–0.7 ms and retained-layout update at 18–41 ms in the
  short varied-key diagnostic (`/tmp/exosuit-editor-edit-phases`). It does not
  explain the complete dispatch time. The diagnostic fails at 70.78 ms p95;
  it is not comparable to the 90-second gate. Instrumentation was removed.
  Resume by profiling the remaining input callbacks/selection path and the
  layout update's text slicing/native call separately; document segment
  mutation is not the dominant measured cost.
- Post-edit publication instrumentation identifies the buffer replay callback
  at roughly 10–14 ms; selection and refresh each cost below 0.1 ms
  (`/tmp/exosuit-publish-edit-phases`). Temporary tracing was removed.
  `TextBuffer.positionFromCodepointOffset` now walks only through the requested
  codepoint instead of counting the whole destination line first. Surrogate
  pairs and completed preceding lines retain the previous semantics.
  Document tests pass, including new insertion replay/undo/redo checks at
  every boundary of a multiline string containing emoji and an empty line.
  The full headless suite passes
  (`/tmp/exosuit-bounded-buffer-offset-tests.log`, exit 0). The fresh 90-second
  varied-key 1 MiB typing capture passes: 39.47 ms p95, 51.24 ms maximum
  (`/tmp/exosuit-bounded-buffer-offset-1mb`, exit 0). This single capture does
  not complete M9 or replace the remaining fixture and general-text checks.
  The buffer conversion and regression checks are committed as Exosuit
  `d52a490`; shared-row/native reflow work remains uncommitted.
- Uncommitted shared-row storage passes vendor units, native differential
  checks, ASan/leaks and UIKit native tests. Equal-advance edits retain prefix
  and suffix blocks and rebuild four private rows for both 4 KiB and 1 MiB
  probes. Changed-wrap edits still rebuild full row arrays. These checks do
  not establish the app typing budget or complete M9.

## M9.1 — indexed native geometry queries, 2026-10-02

- Skribidi `441e2bc`, pinned by Materia `dc660f975`, migrates native
  hit/content tests, content bounds, caret iteration/style, word/line
  navigation, selections, rendering and indexed glyph positions now read rows
  and runs through the indexed value boundary. Bulk glyph compatibility caches
  use it too. Row lookup by text offset uses binary search with the previous
  last-start-at-or-before semantics; empty/before-first defaults remain zero.
  Builder, retained-source reuse and snapshot eligibility still own/read flat
  arrays. Shared row storage is not installed yet.
- Full native probe passes (`/tmp/exosuit-indexed-row-queries-probe.log`),
  including 240 accepted/one rejected and both 100-generation sequences with
  692 moved wraps. Vendor units pass (`/tmp/exosuit-indexed-row-queries-unit.log`);
  an added regression compares lookup with the prior linear semantics at every
  offset from before the text through beyond its end on the variable-width
  changed-wrap snapshot. Overflow/empty and general script tests remain green.
- ASan/leak native-only passes (`/tmp/exosuit-indexed-row-queries-asan.log`),
  UIKit native tests pass 3/3 (`/tmp/exosuit-indexed-row-queries-uikit.log`),
  actual decoration/multi-caret navigation/typing/undo passes
  (`/tmp/exosuit-indexed-row-queries-decoration.log`). The 1 MiB varied-key
  delivered-input gate passes across 30 frames: 48.04 ms p95, 50.14 ms max
  (`/tmp/exosuit-indexed-row-queries-1mb`). This is not a matched speedup claim.
- The 10 MiB repeat-key gate also passes across 30 frames: 42.01 ms p95,
  42.68 ms max (`/tmp/exosuit-indexed-row-queries-10mb`). Both browser targets
  build with matching imports and pass typing, save/readback, URL and reload
  (`/tmp/exosuit-indexed-row-queries-web-final.log`).
- Exosuit `a2afe46` retires browser startup completions/rejections and queued
  frames on `pagehide`. The registered controlled-promise regression fails
  against the old launcher when a departing host rejection publishes failure
  (`/tmp/exosuit-browser-lifecycle-before.log`) and passes after, also checking
  active host/guest failures and late guest completion/frame retirement
  (`/tmp/exosuit-browser-lifecycle-after.log`). A temporary built site that
  deliberately fails its new document still exits 1 with the exact error
  (`/tmp/exosuit-browser-lifecycle-negative.log`).
- The preceding loader-only harness change was insufficient: the initial query
  browser gate fails on canceled host fetch during Wasm-GC reload
  (`/tmp/exosuit-indexed-row-queries-web.log`). Explicit execution-context
  tracking alone also leaves an intermittent wasm32 canceled-font failure
  (`/tmp/exosuit-row-context-32-3.log`). The harness now selects the current
  main-frame context by unique ID, tracks committed/loaded documents, and
  retries only protocol context retirement while waiting for navigation.
  Application failures remain fatal. After departure guards, three fresh
  runs per target pass (`/tmp/exosuit-row-lifecycle-{32,gc}-{1,2,3}.log`), followed
  by the complete registered gate above. Preserve these failed logs; the initial
  harness-only diagnosis did not resolve the full lifecycle problem.
- Next install retained row
  blocks with lifetime/COW tests and indexed source-prefix/suffix reads; remove
  stable-row array copies, prefix/suffix aggregation scans and full alignment.
  UIKit result/revision publication remains a separate O(rows) cost. M9.1 and
  the full goal stay open. Pre-existing Materia gitlinks/TextInputBridge and
  Haxeon HashLink/untracked diagnostics remain preserved. Composed release and
  physical IME/mixed-DPI/Windows/macOS checks remain pending.

## M9.1 — indexed row access boundary, 2026-10-02

- Skribidi `7c00226`, pinned by Materia `05db38b2a`, adds value-returning
  `skb_layout_get_line_at` and
  `skb_layout_get_layout_run_at`. UIKit intrinsic metrics, initial and edited
  layout publication, and fallback row-equivalence checks no longer borrow
  complete native row/run arrays. Vendor editor navigation and rich-layout
  hit testing also use indexed rows. Bulk getters remain compatible.
- The full native differential probe passes
  (`/tmp/exosuit-indexed-row-api-probe.log`), including 240 accepted/one rejected
  ASCII sweep and both 100-generation lifetime/geometry sequences with 692
  moved wraps. Those repeated-generation row/culling/hit comparisons now use
  indexed row reads; RTL-run checks use indexed run reads.
- Final vendor unit suite passes (`/tmp/exosuit-indexed-row-api-unit-final.log`),
  ASan/leak native-only checks pass (`/tmp/exosuit-indexed-row-api-asan.log`),
  UIKit native tests pass 3/3 (`/tmp/exosuit-indexed-row-api-uikit-final.log`),
  and actual decoration/multi-caret navigation/typing/undo passes
  (`/tmp/exosuit-indexed-row-api-decoration.log`). Both browser targets build
  with matching imports and pass real typing, save/readback, URL and reload
  (`/tmp/exosuit-indexed-row-api-web-final.log`).
- Exosuit `0cd5b71` fixes reload observation: track main-frame loader IDs and
  lifecycle load events before checking fresh-document application state.
  The initial browser gate failed during reload with canceled font requests
  (`/tmp/exosuit-indexed-row-api-web.log`), following the preceding slice's
  canceled-script failure. The old harness could observe outgoing-document
  callbacks while navigation was replacing the execution context. New-document
  failures remain fatal: a temporary copy of the built site deliberately
  fails on its first reloaded frame and the gate exits 1 with that exact error
  (`/tmp/exosuit-indexed-row-api-reload-negative.log`). The wasm32 recheck and
  complete two-target gate pass after the harness correction; product startup
  code is unchanged.
- This is an access-boundary migration, not shared row storage or a speedup.
  Next migrate internal read-only line/run geometry consumers behind indexed
  access, then retain immutable row blocks for verified prefix/suffix ranges.
  Builders keep mutable owned rows; public bulk compatibility reads must not
  be requested by caret/render/hit/selection queries. UIKit result/revision
  vectors and row publication still require bounded work. M9.1 remains open.

## M9.1 — affected-row reflow, 2026-10-02

- Skribidi `702daa6`, pinned by Materia `6a6a640c0`, implements guarded ASCII
  reflow starting at the first affected row and reuses a recovered
  suffix only when its source boundary and row number match. Cached snapshot
  eligibility avoids scanning the source again at the first edit. Unchanged
  font metrics are reused; row-count changes conservatively reflow the tail.
  Row/run arrays are still copied and final alignment/publication visit rows.
- Reduced regression fails before on missing prefix/suffix reuse
  (`/tmp/exosuit-bounded-row-before.log`) and passes after: 60 prefix rows,
  10 rebuilt rows, 954 suffix rows, 100 measured wrapping clusters. It also
  compares all glyphs for a row-count-changing insertion and invalidates cached
  eligibility after an uppercase source rebuild. Full vendor unit suite passes
  (`/tmp/exosuit-bounded-row-certificate-unit.log`). Counters exclude copying,
  alignment and publication and do not imply bounded total edit work.
- Full native differential/lifetime probe passes: 30/30 shared edits at both
  4,096 and 1 MiB, 240 accepted/one rejected sweep, both 100-generation sequences
  and 692 moved internal wrap boundaries. Native 1 MiB mean CPU is 24.73 ms,
  versus the preceding slice's 27.41 ms
  (`/tmp/exosuit-bounded-row-certificate-probe.log`). An intermediate version
  repeated unchanged-row font work and regressed to 33.93 ms before correction
  (`/tmp/exosuit-bounded-row-probe.log`).
- ASan/leak native-only gate passes (`/tmp/exosuit-bounded-row-asan.log`),
  UIKit native tests pass 3/3 (`/tmp/exosuit-bounded-row-uikit.log`), real editor
  decoration/navigation/typing/undo passes
  (`/tmp/exosuit-bounded-row-decoration.log`), and full headless suite passes
  (`/tmp/exosuit-bounded-row-headless.log`).
- Delivered-input gates pass across 30 frames: 1 MiB varied-key 48.56 ms p95,
  50.48 ms maximum (`/tmp/exosuit-bounded-row-1mb`); 10 MiB repeat-key 43.06 ms
  p95, 46.63 ms maximum (`/tmp/exosuit-bounded-row-10mb`). Both are slower than
  the preceding captures (44.59/30.85 ms p95); isolated native CPU improvement
  does not establish end-to-end improvement. The gate applies to p95, not max.
- Both browser targets build with matching imports. Wasm32 passes all typing,
  save/readback, URL and reload checks. The first Wasm-GC reload failed with
  `HaxeonWasmHost is not defined` and canceled script requests
  (`/tmp/exosuit-bounded-row-web.log`); two fresh runs of the same built target
  pass without changes (`/tmp/exosuit-bounded-row-web-gc-recheck.log`,
  `/tmp/exosuit-bounded-row-web-gc-repeat.log`). The intermittent reload issue
  is unresolved; these passes do not erase the original composed gate failure.
- Next: shared row metadata and bounded publication, then bounded
  pending tail reflow. M9.1/full goal remain open; pre-existing dirty inputs
  and unavailable platform gates remain preserved.

## M9.1 — indexed changed-wrap reflow, 2026-10-02

- Skribidi `b9a4ad9` adapts the existing line builder to read clusters,
  properties and advances from immutable indexed shape blocks. Row geometry
  owns positions, so reflow does not mutate retained glyphs. Non-truncating
  supported ASCII edits retain pieces when wrap boundaries change; truncation
  and other shape-mutating paths retain materialization. Unicode fallback is
  unchanged. Materia `cd9e2fee1` pins the verified vendor revision.
- The repeated 4,096-/1 MiB native edit regression failed before the fix on
  lost shared storage (`/tmp/exosuit-indexed-reflow-before.log`). Both fixtures
  now retain shared shapes for all 30 edits. Two 100-generation sequences
  compare geometry/render/caret/hit/selection behavior and empty bulk caches
  against fresh layouts. The variable-width sequence moves 692 internal wrap
  boundaries; sources are destroyed, mutated with ellipsis, and rebuilt while
  children retain original blocks. Full sweep: 240 accepted, one rejected.
  Gate exits 0: `/tmp/exosuit-indexed-reflow-final-probe.log`.
- Standalone Skribidi unit coverage verifies moved wrapping, source destruction,
  absent arrays/cache, uppercase rejection and materialized overflow fallback.
  Full vendor unit suite exits 0 (`/tmp/exosuit-indexed-reflow-final-unit.log`).
  Native-only ASan/leak detection exits 0, including both 100-generation
  sequences (`/tmp/exosuit-indexed-reflow-final-asan.log`). UIKit text engine,
  frame resources and renderer pass 3/3 (`/tmp/exosuit-indexed-reflow-uikit.log`).
- Graphical build and real decoration pixels/typing/undo pass
  (`/tmp/exosuit-indexed-reflow-decoration.log`). Full editor headless suite
  exits 0 (`/tmp/exosuit-indexed-reflow-headless.log`). Both browser targets
  rebuild and pass Unicode typing, save/readback, URL and fresh-session reload
  with no unavailable imports (`/tmp/exosuit-indexed-reflow-web.log`).
- Actual delivered-input gates pass across 30 frames each: small varied-key
  28.04 ms p95 (`/tmp/exosuit-indexed-reflow-small`); 1 MiB single-line varied-key
  44.59 ms p95, 49.70 ms maximum (`/tmp/exosuit-indexed-reflow-1mb`, 90 s capture,
  1,200 ms key delay); 10 MiB repeat-key 30.85 ms p95, 32.09 ms maximum
  (`/tmp/exosuit-indexed-reflow-10mb`, 45 s capture, 400 ms key delay).
  Samples do not establish a universal latency bound or a matched speedup.
- The sequential native 1 MiB paragraph probe averages 27.41 ms CPU versus
  the earlier shared/materialized slice's 16.53 ms; this is a CPU regression,
  despite removing copied shape arrays (`/tmp/exosuit-indexed-reflow-generations.log`).
  Reflow and property/width/eligibility checks still scan the paragraph; indexed
  reads add lookup work. Row arrays and prepared glyph publication remain O(n).
- Exact resume: bound unchanged-row verification and publication, and reflow
  from the first affected row until an unchanged suffix boundary is recovered.
  Retain this differential/lifetime and real-frame evidence as required gates.
  M9.1 and the full M8–M15 goal remain open. Pre-existing Materia gitlinks and
  TextInputBridge diagnostics remain preserved; composed release still rejects
  the dirty UIKit input. Physical IME/mixed-DPI/Windows/macOS remain pending.

## Browser host streams and terminal boundary — 2026-10-02

- Haxeon `47c35ea0` supplies typed Wasm `Sys.stdout()`/`Sys.stderr()`
  streams through the shared C-ABI host interface. Each stream buffers
  independently; `flush()` publishes partial lines. Browser hosts may supply
  `printError` separately from `print`. Documentation: `ca658504`.
- The reduced existing `wasm-host-services.hx` fixture failed before the fix
  on `Sys.sysStderr` (`/tmp/exosuit-wasm-stream-before.log`). It now executes
  Unicode stdout/stderr writes and flushes on both targets. The registered
  Wasm runner also executes the shipped browser adapter with imported memory
  and checks exact output/routing with no unavailable imports. The complete
  compiler gate exits 0: 384/384 plus every native, integration and Wasm stage
  (`/tmp/exosuit-wasm-stream-compiler-gate.log`).
- Shared `ExosuitApp` now accepts a typed `TerminalPanel` factory. Desktop
  GraphicalMain supplies the real TerminalPane, which owns PTY/emulator creation
  and failure cleanup. Browser compilation includes the lifecycle/view contract
  and excludes the desktop implementation. No platform-only emulator imports
  remain in the shared shell; capability-based commands/panels are preserved.
- Both browser targets build and pass real Unicode typing, dirty tracking,
  save/readback, URL and fresh-session reload checks, with no unavailable
  imports (`/tmp/exosuit-terminal-boundary-web-final.log`). The desktop terminal
  dock, row canvases, actual PTY input and resize pass
  (`/tmp/exosuit-terminal-boundary-ui.log`, artifacts
  `/tmp/exosuit-terminal-boundary-ui`). Full editor headless suite exits 0
  (`/tmp/exosuit-terminal-boundary-headless.log`). Real decoration pixels,
  movement, clearing, multi-caret typing and undo also pass
  (`/tmp/exosuit-terminal-boundary-decoration.log`).
- Preserve pre-existing Materia gitlinks/TextInputBridge diagnostics and Haxeon
  HashLink gitlink/untracked files. Composed release remains unavailable with
  that dirty UIKit input; these passing individual gates do not claim composed
  release acceptance. IME/mixed-DPI/Windows/macOS remain pending.
- Resume M9.1: implement indexed changed-wrap reflow
  and bounded row verification/publication. The prior shared-shape differential
  fixture remains the mandatory lifetime/geometry/render reference.

## Counted-input repair checkpoint — 2026-10-02

The later browser host/terminal record above supersedes pending checks here.

- NativeKit counted function inputs used field-oriented borrowed annotations.
  Accessibility range/removal inputs and transport bytes now use `NK_IN_ARRAY`;
  desktop and browser HXI regeneration/audits pass. UIKit accessibility calls
  now let the generated wrapper derive the removal-byte count.
- A reduced accepted `ptr<const<void>> @in_array` case first crashed projection
  (`Void has no value ABI`). The emitter now projects it as managed bytes.
  Signed count rejection remains covered on portable 32/64-bit ABI targets.
- Actual execution then exposed an independent IR assumption: byte-buffer
  counts were restricted to I32 despite accepted unsigned 64-bit HXI counts.
  IR and Wasm GC validation now share an I32/I64 count rule; non-integer
  metadata remains rejected. The native checksum regression exercises populated
  and empty buffers with inferred u64 counts.
- Focused parser and native-call integration pass, including the real checksum
  and existing ABI rejection cases (`/tmp/exosuit-void-array-parser-final.log`,
  `/tmp/exosuit-void-array-runtime-after.log`). The compiler gate's 384 cases
  pass; the complete compiler gate exits 0, including native FFI and Wasm
  execution (`/tmp/exosuit-void-array-compiler-gate.log`). Haxeon repair commit:
  `6a309543`. NativeKit smoke exits 0, including counted structure and byte
  input calls (`/tmp/exosuit-counted-input-nativekit-final.log`); NativeKit
  commit `9cc4bd3a`. UIKit accessibility call repair is Materia `44fa1a4ea`.
- Browser rebuild initially exposed direct desktop terminal imports in shared
  ExosuitApp. Uncommitted work injects a host-owned `TerminalPanel` factory;
  desktop creation retains PTY/emulator failure cleanup and browser graph
  excludes only the desktop implementation. Graphical build exits 0
  (`/tmp/exosuit-terminal-boundary-graphical.log`). Interaction checks pending.
- Browser now reaches lowering and fails on unsupported `Sys.sysStderr`
  (`build/web-ci-wasm32/guest-compile.log`,
  `/tmp/exosuit-terminal-boundary-web.log`). The call is from the pre-existing
  dirty UIKit TextInputBridge diagnostic. Preserve that edit; supply general
  Wasm stderr support in Haxeon with reduced execution coverage, then rerun
  both browser targets and graphical interaction checks. No test handles live.
- Terminal boundary remains uncommitted. Release pins reflect the three verified
  sibling commits; composed release still rejects pre-existing Materia dirt.
  M9.1 indexed changed-wrap reflow remains the next layout task.

## Current checkpoint

- **M8.1 and M8.2 accepted headlessly in both compiler modes.** Exosuit
  `95a3b08` restores source plugins and makes their full test mandatory.
  Graphical builds and all headless projects exit 0 in reference and refreshed
  self-hosted modes. Haxeon `82d92ba0` passes 375/375 and every integration/Wasm
  stage; bootstrap converges and rebuilds identically.
- **M8 accepted on Linux:** restored composed CI exits 0 after b76554b, and
  the changed graphical entry point builds in self-hosted mode as well.
- **M15 accepted on Linux/Chrome:** both guest targets build with matching
  C imports and pass actual Unicode edit/save/readback/URL/reload smoke. The
  browser stage is wired into composed CI through `EXOSUIT_CI_WEB=1`; absent
  toolchains remain explicitly pending.
- Active task: **M9.1**, strict changed-row invalidation on UIKit. The M12.2
  terminal now has styled cells, cursor, scrollback controls, broader key input,
  and a unified light/dark workbench theme (`a3f0a4a`, `f14d847`).
- Independent M11.1 POSIX PTY, M11.2 Linux transport, M11.3 SQLiteKit, and
  an initial M11.4 TerminalKit slice are verified. M12.1's headless session
  model and direct local PTY adapter now pass in both compiler modes
  while the 1 MiB graphical timing gate waits for an idle host. Their Windows
  implementations remain open. The Pragtical PTY and emulator references are
  present in the available read-only checkout.
- Exact resume: finish **M9.1**, continuing indexed row geometry and strict
  changed-row invalidation. Stable-row ASCII edits now retain immutable shape
  blocks through indexed pieces. Rendering, carets, hit tests, selection and
  navigation read that same native snapshot. Editor queries do not materialize
  bulk text/property/glyph/cluster arrays; explicit legacy bulk getters populate
  separate compatibility caches. Mutations detach shared buffers before writes.
  The native differential fixture uses shared storage for all 30 edits;
  changed-wrap edits now retain shared shapes through reflow. Per-paragraph property,
  width and glyph verification and row-index copying remain O(n); native edit
  CPU time has not substantially improved. Browser annotation, counted-buffer
  compiler, standard-stream and desktop terminal dependency repairs are verified
  above. Next bound row verification, reflow and publication.
- Unchanged ASCII/color-equivalent rows retain publication revisions after
  source rebasing. Full Unicode fallback maps unchanged prefix/suffix source
  ranges and compares exact row-local geometry. Persistent frame text identity
  and canonical row translation retain verified moved-row rasters. Ordinary and
  newline edits share a source-mapped chunk window; unaffected chunk boundaries
  stay stable, with local growth to 128 paragraphs before splitting. Splits still
  move rows between native layouts. Fractional-origin reuse, actual application
  newline raster attribution and the strict decoration audit remain open.
- Current standard typing gates pass: **44.59 ms p95** (1 MiB varied-key) and
  **30.85 ms p95** (10 MiB repeat-key), each across 30 actual input frames.
  Prior failures remain recorded. These samples do not establish a universal
  latency bound. Preserve graphical pixels, M8 and both browser gates; missed
  p95 budgets still produce nonzero benchmark exits.
- Current follow-on HEADs: Exosuit `e7a9b76` before this ledger commit;
  Haxeon `ca658504`, NativeKit `9cc4bd3a`; Materia `cd9e2fee1` carries row-scoped glyph commands, shallow row raster
  caching, rebased source metadata, a parent repaint cost regression, and the
  Skribidi bulk-copy and guarded variable-width row-geometry reuse slices. The
  existing dirty Haxeon/NativeKit gitlinks and UIKit TextInputBridge edit in
  Materia were left untouched.
- All further graphical tests must use disposable PRAGTICAL_PORTABLE state.
  IME, physical mixed-DPI transitions, Windows and macOS remain unclaimed.
- HEADs at planning: exosuit `ae2f260` (`haxeon-uikit-port`). Materia `main` is at
  `816372dd`, fast-forwarded 2026-10-01 for the Haxeon wasm and web fixes; it
  contains uikit and editorkit. Haxeon is at `fba71015` (on pin, fast-forwarded).
  NativeKit is at `2bb4c957` (`materia-numeric-locale`, off-pin, local). Pragtical
  is at `50644c91` (`next`, read-only reference, dirty smooth-scroll work).
- The baseline failures below were observed before the Haxeon and materia
  fast-forward. Re-run both gates at the start of M8.
- The UIKit port (`89d2694`, ADR 0002) invalidates M0–M7 runtime evidence for the
  graphical product. Those records stay as history; M8 re-establishes the gates.
- Baseline failures at `ae2f260`:
  - `./scripts/test.sh`: the headless core compiles, then HashLink aborts with
    `Invalid signature for function pragtical_hx@last_error : P_OBi_ required but
    P_B found in hdll`. Every `String` extern has the same mismatch (M8.1).
  - `./scripts/build.sh`: `commandview/CommandView.hx:297:16: E1005: Field
    "entries" requires an object` in the reference compiler (M8.2).
- Previous checkpoint (M0–M7 complete headlessly on the SDL host): editor `354f0e8`, Haxeon `83a2749`.

## Milestones

| Milestone | State | Evidence / remaining gate |
| --- | --- | --- |
| M0 | Complete on Linux | M0.1/M0.2 complete; `test-sdl-workflow.sh` covers the complete M0.3 route through a real SDL window |
| M1 | Complete headlessly | Stable pathless identity, atomic persistence, Save As, unified close/quit, external conflicts and bounded recovery pass; graphical prompt smoke remains in the M0.3 manual route |
| M2 | Complete headlessly | Everyday editing, clipboard/navigation, coding transformations and normalized multiple selections pass; graphical keyboard/mouse smoke remains in M0.3 |
| M3 | Complete headlessly | Reusable command input, pane/tab/sidebar navigation, logical-point DPI routing, status, bounded feedback, error inspection and centralized UI roles pass; interactive M0.3 smoke remains |
| M4 | Complete headlessly | Responsive index/search, safe replacement, recoverable file operations and defensive sessions pass; graphical smoke remains in M0.3 |
| M5 | Complete headlessly | Live layered configuration, owned APIs, debounced background compilation, transactional reload and editor lifecycle controls pass |
| M6 | Complete headlessly | Bounded JSON-RPC, lifecycle/synchronization, language commands, diagnostics, restart and real Haxeon edit/diagnose/fix/build smoke pass |
| M7 | Complete for the claimed Linux automation scope | M7.1–M7.3 pass; desktop IME, physical mixed-DPI, Windows and macOS remain explicit unclaimed follow-ons |
| M8 | Accepted on Linux | Both compiler modes, mandatory source plugins, real LSP/window workflow and unpacked release; composed CI exits 0 |
| M9 | Active: M9.1 | General styled text/decorations and editor rendering |
| M10 | Accepted on Linux automation | Real-server graphical fixture and repository overlays, completion/navigation/rename, transactional undo and fixture build/execution pass; physical IME and other platforms remain unclaimed |
| M11 | Active: M11.1 POSIX, M11.2 Linux, M11.3 SQLiteKit, M11.4 TerminalKit slice | Depends on M8; independent of M9/M10; Windows PTY/named pipes and M11.4 session integration remain pending |
| M12 | M12.1 accepted; M12.2 Linux view active | Local PTY/session and plugin profiles pass; docked styled grid, cursor, scrollback keys, row raster reuse, input and resize smoke pass; selection and redraw benchmark remain |
| M13 | Not started | Depends on M11.2 |
| M14 | Not started | Depends on M11–M13 |
| M15 | Accepted on Linux/Chrome | Both guest targets, typed capabilities, Unicode editing/save/URL/reload, matching C imports and opt-in browser CI |

## Implementation records

### M9.1 — shared immutable shape storage on stable-row edits

- Skribidi `b552598` retains decoded text, properties, glyphs and clusters in
  reference-counted shape blocks. Indexed generations retain block ranges,
  coalesce adjacent ranges into the same block and rebase glyph/cluster indexes
  during reads. No complete ancestor layout is retained by a piece. The native
  geometry boundary serves rendering, carets, hit tests, selections and navigation
  from the current row index and shared shapes. Materia `40fae154a` pins the fork.
- Validated unchanged-advance or stable-wrap ASCII edits leave the complete
  text/property/glyph/cluster arrays absent. Renderer and culling walks use row
  cursors; advance-only geometry avoids calculating unused glyph origins.
  Explicit bulk compatibility calls populate separate caches, preserving the
  existing array API. Changed-wrap edits still materialize for full line reflow,
  and unsupported Unicode still uses the complete-layout path.
- Mutable rebuilds release shared storage before writing and reuse unique
  buffers. The internal ellipsis operation also preserves shared buffers through
  copy-on-write, including its reallocations. The constructor's public lifetime
  contract now permits shared buffers while guaranteeing source independence.
- The production differential regression performs **100 dispersed edits**, with
  replacements, insertions and deletions. It compares indexed text/properties,
  clusters, glyph positions, both caret affinities, hit tests, selections,
  rendered glyphs, row metrics and culling bounds with fresh layouts. It checks
  actual prefix-block identity and absent bulk caches after geometry queries;
  sources are destroyed after edits, and the original is mutated by ellipsis
  and rebuilt while descendants survive. Legacy bulk calls also remain valid.
- Native-only AddressSanitizer/leak detection passes, including the shared
  ellipsis regression: `/tmp/exosuit-shared-shape-ellipsis-asan.log`. Native
  text-engine, ABI, frame resources and renderer checks pass. Graphical build
  and real decoration pixels pass, including typing/undo and wrapped navigation:
  `/tmp/exosuit-shared-shape-final-render.log`,
  `/tmp/exosuit-shared-shape-final-decoration.log`.
- The full differential probe passes 240 accepted/one rejected sweep cases,
  immutable lifetime checks and repeated 4,096-/1 MiB-codepoint edits. Of 30
  edits in each repeated fixture, **20 share shape storage**, while 10 require
  materialization. The 1 MiB native edit averages **16.53 ms CPU**, comparable
  to the prior materialized probe's 15.85 ms; this is not a speedup claim.
  Artifact: `/tmp/exosuit-shared-shape-final-probe.log`.
- Standard gates pass across 30 input frames each: 1 MiB varied-key
  **47.22 ms p95**, 57.87 ms maximum, `/tmp/exosuit-shared-shape-1mb`;
  10 MiB repeat-key **47.55 ms p95**, 52.11 ms maximum,
  `/tmp/exosuit-shared-shape-10mb`. Earlier failures remain recorded.
- `scripts/test-skribidi-layout.sh` now builds and runs the full differential
  probe from a fresh default build directory. It passes and is required by
  composed CI after the graphical build. Shell syntax checks pass. Artifact:
  `/tmp/exosuit-shared-shape-required-test.log`.
- The composed gate passes compiler, headless, graphical, real LSP, workflow
  and decoration stages, then exits nonzero at release input validation. The
  only dirty path within Materia's release-checked UIKit/EditorKit scope is the
  pre-existing `uikit/haxe/nativekit/ui/core/TextInputBridge.hx`; it remains
  untouched. Artifact: `/tmp/exosuit-shared-shape-ci.log`. This run does not
  reaccept the complete composed/release gate.
- The independent browser gate fails before guest/host compilation at NativeKit
  interface generation. Direct wasm32 audit exposes `E3001` at
  `nativekit_accessibility.h:494`: parameter `ranges` uses the field-oriented
  `NK_BORROWED_ARRAY(range_count)` annotation, while function input arrays have
  the distinct `NK_IN_ARRAY(count)` contract. The current header fails on both
  wasm32 targets before UIKit/Skribidi are reached. No compiler or NativeKit
  source workaround was added. Artifacts:
  `/tmp/exosuit-shared-shape-web.log`,
  `/tmp/exosuit-shared-shape-nativekit-audit.log`.
- Next: correct and verify the NativeKit input-array annotation to restore the
  browser gate, then remove materialization from changed-wrap reflow and bound
  row work.
  Full row verification/index copying, prepared-vector rebasing, Unicode
  incremental shaping and strict invalidation remain unfinished. M9.1 and the
  complete follow-on goal remain open.

### M9.1 — common indexed reads for native geometry and rendering

- Skribidi `a8987d8` adds value-returning indexed reads for codepoints,
  text properties, glyphs and clusters. Its renderer, grapheme/word navigation,
  caret iterator, caret placement, hit tests and selection bounds now use the
  same internal read boundary. The current boundary still reads flat arrays;
  this is preparation for shared storage, not zero-copy activation.
- Materia `19d7bc46d` carries the UIKit text engine's indexed API for
  row equivalence, word/paragraph
  navigation and diagnostics. It no longer borrows bulk text, property, glyph
  or cluster arrays. Lines and runs remain in the current native generation.
  ADR 0003 records Skribidi as the composite geometry owner, preserving its
  existing Unicode geometry semantics instead of duplicating them in UIKit.
- The differential probe compares indexed edited cluster/glyph/property/text
  reads with a fresh layout's bulk arrays, including retained generations,
  source mutation and destruction. Native text-engine, ABI, frame resources,
  renderer, full differential and native-only ASan/leak checks pass. Graphical
  build and real decoration pixels pass. Artifacts:
  `/tmp/exosuit-indexed-reads-probe-final.log`,
  `/tmp/exosuit-indexed-reads-asan.log`,
  `/tmp/exosuit-indexed-reads-render-final.log`,
  `/tmp/exosuit-indexed-reads-decoration.log`.
- The first standard 1 MiB varied-key run fails at **74.25 ms p95**,
  3,403.97 ms maximum, artifact `/tmp/exosuit-indexed-reads-1mb`.
  Its longest frame records 2,854.20 ms frame duration and 549.54 ms dispatch;
  individual frame phase measurements account for only a small fraction of
  that duration. This leaves attribution unresolved. The 10 MiB repeat-key
  gate passes at **32.18 ms p95**, 179.35 ms maximum, artifact
  `/tmp/exosuit-indexed-reads-10mb`. Both capture 30 actual input frames.
- A matched prior-source control (`6e22891` native, `19f2f9222` UIKit) passes
  at **40.73 ms p95**, 45.87 ms maximum, artifact
  `/tmp/exosuit-indexed-reads-control-1mb`. All four candidate source files and
  the built app were restored before the candidate repeat. The initial failure
  remains recorded; the control alone does not establish its cause.
- The restored candidate repeat passes at **48.25 ms p95**, 62.71 ms
  maximum, across 30 input frames, artifact
  `/tmp/exosuit-indexed-reads-candidate-1mb`. One control/candidate pair does
  not establish a latency bound or explain the initial failure. No instrumentation
  was left in production. The release pin advances to Materia `19d7bc46d`.
- Next: immutable shared shape blocks with indexed piece ranges. Legacy
  mutations must detach before writes, and the renderer and all geometry must
  remain on the same generation. Full-array materialization and strict M9.1
  invalidation remain unfinished; preserve the complete follow-on plan.

### M9.1 — immutable native ownership prerequisite

- Skribidi `6e22891` adds `skb_layout_create_ascii_edit`, returning a new
  owned generation while preserving the source on success and rejection.
  The legacy mutating API delegates to that constructor. This still copies
  complete shaped arrays; shared shape storage is not activated.
- Materia `19f2f9222` adopts native generations through
  `shared_ptr<const skb_layout_t>`. Every geometry and rendering call reads
  the current read-only owner. The native deleter retains its font collection,
  so native destruction precedes font retirement. Ordinary edits publish a new
  owner instead of mutating the previous native layout.
- The differential probe retains ten generations across beginning, middle and
  end edits and compares text, cluster metadata, glyph positions and carets
  with fresh layouts. Rejection preserves the latest generation. Rebuilding
  the original and mutating its first descendant preserves later descendants;
  the latest generation remains queryable after source destruction. Native-only
  AddressSanitizer with leak detection passes, including the source mutation
  regression: `/tmp/exosuit-immutable-source-mutation-asan.log`.
- Native text-engine, ABI, frame-resource and renderer checks pass, including
  moved-row cache hits and restored framebuffer pixels. The graphical build,
  decoration pixel suite and full edit-window differential probe pass. Logs:
  `/tmp/exosuit-immutable-layout-final-build.log`,
  `/tmp/exosuit-immutable-layout-decoration.log`,
  `/tmp/exosuit-immutable-probe-final.log`.
- Standard typing gates each capture 30 input frames and exit zero: 1 MiB
  varied-key **46.07 ms p95**, 46.37 ms maximum, artifact
  `/tmp/exosuit-immutable-layout-1mb`; 10 MiB repeat-key **34.86 ms p95**,
  38.91 ms maximum, artifact `/tmp/exosuit-immutable-layout-10mb`.
- Next: extract validated local shape pieces and implement the common indexed
  snapshot/geometry boundary. No renderer-only composition is enabled. Native
  arrays and rebased prepared glyph vectors remain materialized. M9.1 and the
  full follow-on plan remain open.

### M9.1 — measured ASCII splice cost and redundant writes removed

- Temporary real-window timers covered 60 insertion/deletion edits of the
  1 MiB varied-key fixture. Guard median/p95: **2.48/8.45 ms**; local shape
  **0.045/0.130 ms**; array splice/index repair **6.62/20.01 ms**; geometry
  **3.29/12.55 ms**. Full native edit median/p95: **13.09/40.53 ms**;
  UTF-8 string copy and result metadata medians were 0.10/0.16 ms. This
  instrumented 45-second probe missed the frame budget at 62.06 ms p95; it is
  attribution evidence, not a standard acceptance run. Raw artifacts:
  `/tmp/exosuit-edit-phases`, `/tmp/exosuit-edit-phase-summary.json`.
- Skribidi `cc3b8e2` repairs indexes only in copied spans whose source and
  destination differ. Successful geometry reuse no longer zeroes every glyph
  origin before restoring it; equal-length reuse restores only its contextual
  window. Failed geometry guards still reset shaping-local origins before full
  reflow. Materialized arrays remain O(n), and zero-copy composite snapshots
  remain unfinished. All temporary timing probes were removed.
- Materia `65e70e840` pins that fork change. Native text-engine, ABI,
  frame-resource and renderer checks pass; graphical build and decoration
  pixel suite pass. The differential probe compares cluster offsets/counts,
  glyph cluster indexes, geometry, culling and sampled carets against fresh
  layouts. Repeated 4,096- and 1 MiB-codepoint edits pass, as do 240 accepted
  variable-advance sweep cases and the rejection fixture. Probe logs:
  `/tmp/exosuit-ascii-index-probe-final-results.log`.
- Final standard typing gates pass across 30 actual input frames each:
  1 MiB varied-key **47.24 ms p95**, 47.80 ms maximum, artifact
  `/tmp/exosuit-ascii-index-1mb`; 10 MiB repeat-key **33.59 ms p95**,
  40.10 ms maximum, artifact `/tmp/exosuit-ascii-index-10mb`. Prior failures
  remain recorded; these samples do not establish a universal latency bound.
- ADR 0003 now describes current source rebasing, moved-row raster identity
  and stable chunk windows. General Unicode shaping, fractional-origin reuse,
  actual newline raster attribution and strict decoration invalidation remain
  open. Preserve the full M9–M15 goal.

### M9.1 — matched chunk control and enforced timing budget

- Built the previous `TextEditorLayout.hx` from Materia `f084a2837` with all
  other current inputs unchanged, restored the source, and ran the standard
  1 MiB varied-key workload. The control fails at **59.27 ms p95**, 70.40 ms
  maximum, artifact `/tmp/exosuit-chunk-control-1mb`. Rebuilt the current
  `33d36d62a` implementation and ran the same workload: **40.61 ms p95**,
  41.88 ms maximum, artifact `/tmp/exosuit-chunk-candidate-1mb`. Both have
  30 actual input frames. Sources and the built app were restored to current
  before completion; unrelated parent changes remain untouched.
- These runs show that the chunk change is not necessary for the timing
  failure. One pair does not establish equal performance or explain every
  earlier outlier. The slower control frame includes 62.81 ms of edit dispatch
  and 5.24 ms of native rendering. Scheduler samples are preserved in
  `/tmp/exosuit-chunk-scheduler.jsonl`; their windows are too coarse for exact
  phase attribution, so they do not prove host load caused the failures.
- The benchmark formerly printed `withinBudget: false` but still exited zero.
  It now saves/prints its result and exits nonzero on a missed p95 budget.
  Replaying the final result parser against copied real control/candidate
  captures verifies exit 1/0 respectively and retained result artifacts;
  `bash -n` and diff checks pass. No new renderer or chunk source change was
  needed for this control.
- M9.1 stays active. Next attribute long-line dispatch/copying cost and
  native-render variability, preserving the stable chunk design. Then resume
  fractional-origin, actual newline raster and decoration-invalidation audits.
  The full M9–M15 goal is unchanged.

### M9.1 — stable bounded chunk windows for all local edits

- Ordinary and newline edits now share one incremental source-range window.
  Chunks outside the actual edit keep their text/layout and mapped boundaries;
  the path no longer reslices neighboring chunks or reconstructs fixed global
  64-paragraph groups on the next ordinary keystroke. An affected chunk can
  grow locally to 128 paragraphs; overflow splits only that window, targeting
  64-paragraph pieces. Edits spanning chunks repair their combined window.
- The framework fixture compares every caret and measurement against fresh
  layouts across seven transactions: initial newline, boundary insertion,
  deletion across chunks, later insertion, ordinary Unicode typing, insertion
  of 140 extra paragraphs (local overflow), and whole-document clearing.
  Paint-provider ranges prove initial newline and subsequent ordinary typing
  preserve unrelated boundaries; every emitted chunk stays within 128
  paragraphs. The complete framework and graphical decoration suites pass.
- Initial standard 1 MiB varied-key run misses the 50 ms budget:
  **50.86 ms p95**, 58.45 ms maximum, 30 input frames, artifact
  `/tmp/exosuit-stable-chunks-1mb`. Dispatch p95 is 41.17 ms and frame p95
  10.75 ms; this failure is not dismissed as host load. Further timing
  verification remains required. A second unchanged-code run also fails at
  **76.46 ms p95**, 103.47 ms maximum, artifact
  `/tmp/exosuit-stable-chunks-1mb-rerun`. Its native-render p95 is 32.70 ms,
  dispatch p95 39.96 ms, and measured GC p95 0.0012 ms. Next run a matched
  previous-implementation control rather than attributing this to host load or
  claiming performance acceptance. Standard 10 MiB repeat-key typing passes
  across 30 frames at **39.56 ms p95**, with a **289.66 ms maximum** outlier,
  artifact `/tmp/exosuit-stable-chunks-10mb`.
- Materia commit `33d36d62a`. Remaining M9.1 work includes fractional-origin
  cancellation, actual app newline raster attribution and the decoration
  invalidation matrix. Overflow splitting still moves some unchanged rows to
  different native layouts, so cross-layout identity is not claimed. Rebased
  CPU glyph snapshots still copy vectors. Preserve the full M9–M15 roadmap.

### M9.1 — Haxe newline chunks use native edit invalidation

- `setTextAfterParagraphEdit` now receives old/new edit boundaries and computes
  unchanged source-mapped prefixes/suffixes for each reused chunk. Changed
  chunks use `TextLayout.edit` instead of full `update`, enabling native row
  identity preservation. New chunks still allocate their own layout; styles
  and width remain those of the existing edit session. The replacement is
  sliced directly from the indexed document without another text-diff scan.
- Framework regression starts with 220 mixed-Unicode lines, inserts at the
  beginning and around paragraph 63, deletes across the 64-paragraph boundary,
  and inserts near paragraph 190. After each operation it compares every
  codepoint caret and measured size against an independently rebuilt layout.
  The full Haxe UIKit framework passes, as do the graphical build and complete
  decoration pixel suite (including diagnostic movement after newline edits).
- Standard 1 MiB varied-key typing gate passes across 30 input frames:
  **44.86 ms p95**, 44.87 ms maximum, artifact
  `/tmp/exosuit-newline-chunks-1mb`. This is a typing regression gate, not a
  measurement of newline chunk reuse. Standard 10 MiB repeat-key typing
  also passes across 30 frames: **32.24 ms p95**, 32.90 ms maximum, artifact
  `/tmp/exosuit-newline-chunks-10mb`.
- Materia commit `f084a2837`. M9.1 stays active: existing neighborhood
  rebalancing can change both ends of a reused chunk, leaving unchanged middle
  rows outside this one-replacement preservation guard. Next inspect stable
  bounded chunk boundaries that repair/split only the affected chunks, and
  verify actual raster reuse through a newline transaction. Do not claim all
  unchanged rows survive repartitioning. Fractional-origin equality
  and rebased CPU glyph-vector copying also remain open.

### M9.1 — persistent source identity for moved row rasters

- Frame text bindings carry optional persistent source identity separately
  from temporary prepared-resource slots. Runtime cache hashes use that
  identity with complete content generation. Owned bindings retain the same
  identity without copying glyph payloads; default bindings preserve their
  prior resource identity. Aliased bindings require nonzero content generation
  and a text-layout source ID. Rebinding and reset restore the default contract.
- Row raster commands combine vertical translation into one local transform.
  Whole-pixel movement therefore leaves local raster geometry unchanged while
  parent composition uses the new row position. Fractional pixel phase remains
  part of geometry and cannot be silently reused.
- Newline insertion/deletion renderer regression passes: **5 hits / 2 misses**
  after insertion, **6 hits / 2 misses** after deletion. It verifies moved-row
  pixels translate by 24 points and deletion restores the exact prior complete
  framebuffer. Existing changed-row and Unicode edits still produce two misses.
  Native text-engine, ABI, frame-resource and renderer smoke pass; graphical
  build and full decoration pixel suite pass.
- Standard 1 MiB varied-key typing gate passes across 30 frames:
  **45.56 ms p95**, 63.28 ms maximum, artifact
  `/tmp/exosuit-stable-bind-1mb`. The standard 10 MiB repeat-key gate also
  passes across 30 frames: **36.03 ms p95**, 37.76 ms maximum, artifact
  `/tmp/exosuit-stable-bind-10mb`.
- Materia commit `b8411cd4e`. M9.1 remains active: native fractional-origin
  equality, cross-chunk paragraph movement and the broader decoration matrix
  still require audit. The Haxe newline path (`setTextAfterParagraphEdit`)
  currently calls `record.layout.update` when repartitioning changes chunk
  text, bypassing native `edit` identity reuse; inspect and fix this next.
  Rebased glyph snapshots still copy CPU vectors; stable
  frame binding does not claim that remaining zero-copy work is complete.

### M9.1 — source-mapped native row reuse after newline edits

- Full Unicode edit fallback maps unchanged prefix/suffix source ranges to
  their prior rows, independently of row index. Exact comparisons use row-local
  bounds, baselines, run geometry, glyphs, fonts and cluster ranges. Single-row
  keys omit row index; immutable publication metadata rebases layout ID, row
  index and source ranges. Old snapshots remain unchanged.
- Native mixed combining/emoji/bidi regression covers newline insertion and
  deletion, moved foreground ranges, publication identity, vertex equality,
  source rebasing and snapshot validity with explicit 24-point row spacing.
  Fractional-origin cancellation can still reject exact equivalence; this
  intentionally rebuilds rather than assuming approximate paint equality.
- Text-engine, ABI, frame-resource and existing renderer smoke pass. Graphical
  build and decoration pixel suite pass. A temporary renderer movement test
  failed: runtime hashing includes ephemeral prepared-resource IDs, so stable
  native publication does not yet guarantee moved-row raster reuse. That test
  and an insufficient transform-only experiment were removed; next implement
  explicit stable source identity in frame bindings and restore that regression.
- Standard 1 MiB varied-key typing gate passes across 30 input frames:
  **49.72 ms p95**, 59.75 ms maximum, artifact
  `/tmp/exosuit-moved-rows-1mb`. The narrow margin remains visible; this gate
  measures typing, not the unimplemented moved-row raster reuse. The standard
  10 MiB repeat-key gate also passes across 30 input frames: **30.40 ms p95**,
  31.49 ms maximum, artifact `/tmp/exosuit-moved-rows-10mb`.
- Materia commit `fe3f5e7c0`. M9.1 remains active; this is native publication
  reuse, not completion of renderer invalidation or zero-copy snapshots.

### M9.1 — unchanged Unicode row publications after full shaping

- The full-layout edit fallback compares matching rows' codepoints, layout
  runs, fonts, glyph IDs, glyph positions, and relative cluster source ranges
  against the prior generation. Equivalent rows retain their globally unique
  row revision. Single-row publication keys use that revision independently
  of the layout ID; a cache hit republishes immutable metadata for the new
  layout and source offset while retaining paint identity.
- Geometry queries continue to read the freshly shaped native layout. Native
  tests cover combining marks, emoji, bidi text, relative foreground colors,
  shifted source offsets, changed-row invalidation, and retained old snapshot
  lifetime. The renderer smoke confirms a Unicode edit produces exactly two
  misses (changed row and parent pass) while unchanged rows hit. Native
  text-engine, ABI, frame-resource, session-render, graphical build, and
  decoration pixel checks pass. Newline edits that shift row indexes remain
  conservative; general Unicode shaping is still a full-layout operation.
- Final standard typing gates pass across 30 input frames each: 1 MiB
  varied-key **43.39 ms p95**, artifact `/tmp/exosuit-unicode-rows-1mb`;
  10 MiB repeat-key **30.70 ms p95**, artifact
  `/tmp/exosuit-unicode-rows-10mb`. Both remain below 50 ms. The 10 MiB maximum
  was 41.07 ms in this final run.

### M9.1 — collection attribution and 10 MiB rerun

- Capture timelines now include `frameGcSeconds`; the typing benchmark
  reports `frameGcP95Ms` without excluding collections from total latency.
  Timing calls run only while capture is enabled.
- The 10 MiB rerun passed across 30 input frames at **36.40 ms p95**;
  artifact `/tmp/exosuit-frame-gc-10mb`. Frame-boundary collection p95 and
  maximum were about **0.0012 ms**. A 302 ms worst input sample therefore
  does not support the prior GC hypothesis. The earlier failing run remains
  recorded; no collection-policy change was made. The graphical app built,
  and the real-window run verified the new benchmark field.

### M9.1 — shifted colored rows and standard typing gates

- Single-row publication keys now describe clipped foreground ranges relative
  to their row. Unchanged color coverage keeps the publication key when the
  row's source offset moves; publication rebases immutable source metadata.
  Fixed absolute ranges still rebuild when their relative coverage changes.
  Native tests cover both cases, preserved vertex colors and old-snapshot
  invalidation. Native text-engine and graphical decoration pixel tests pass.
- The standard 90-second 1 MiB varied-key fixture delivered 30 input frames
  at **47.27 ms p95**, within the 50 ms budget; artifact
  `/tmp/exosuit-stable-break-final-1mb`. The 45-second 10 MiB fixture delivered
  30 frames at **91.40 ms p95** and missed the budget; artifact
  `/tmp/exosuit-stable-break-final-10mb`. Its worst frame was 3.17 seconds,
  while submit and rendering accounted for only about 157 ms. The frame host
  calls its garbage-collection scheduler outside those stages. Attribute that
  unaccounted interval before accepting the 10 MiB gate or changing layout.

### M9.1 — stable wrap boundaries for variable-width ASCII edits

- A short real-window 1 MiB varied-key probe confirmed that all 60
  insertion/deletion edits used guarded ASCII shaping, but the earlier
  uniform-width row-geometry path covered only 4. Exosuit's active editor
  font has variable advances in this fixture.
- Skribidi now verifies each existing row boundary against the new glyph
  advances. If every row still fits and the next glyph would overflow, it
  reuses row positions and recomputes only changed row widths and glyph
  bounds. A moved boundary uses the complete line builder. The uniform-only
  insertion path was removed. A second short real-window probe reached this
  new path in 52 of 60 edits; temporary traces were removed afterward.
- A temporary in-process phase timer on another 60-edit real-window run
  measured the retained row path at 4.78 ms median, 7.98 ms p95 (56 edits),
  against 20.99 ms median, 23.64 ms p95 for four full-line fallbacks in that
  same run. Host load was around 17, so this is evidence about the native line
  phase only, not an end-to-end latency acceptance result. The timer was
  removed.
- Native text-engine differential tests compare line ranges, bounds, caret
  geometry, and visible rows with fresh layouts. The graphical decoration
  pixel suite passes. The short probes ran at host load around 14–18, and
  their latency p95 values are not an acceptance comparison. The full 1 MiB
  and 10 MiB typing gates remain pending on an idle host. This path still
  copies shaped arrays; composite snapshots remain the zero-copy direction.

### M9.1 — guarded wrapped-row geometry reuse

- Skribidi reuses wrapped row geometry after a guarded equal-length ASCII
  edit when advances and break properties in the local window match. It
  recalculates the changed row's glyph bounds. For a uniform-width ASCII word,
  a one-codepoint insertion or deletion can also retain full-row geometry if
  the final row absorbs the length change; bounds are recalculated from the
  edit onward. All other edits retain full line reflow.
- Native differential tests compare the reuse path with fresh layouts for
  wrapped row ranges, bounds, carets, and visible rows using a monospaced
  font. The native text-engine test and graphical decoration pixel suite pass.
  A temporary trace verified that the insertion/deletion test reached the
  reuse branch; the trace was removed.
- The 1 MiB varied-key timing run made before the insertion/deletion branch
  measured 170.83 ms p95 with host load near 20 and native render p95 36.23
  ms. It is not a valid latency comparison. Final 1 MiB and 10 MiB timing
  gates still require an idle host. The retained generation still copies full
  shaped arrays, and general variable-width edits still reflow all lines.

### M9.1 — 1 MiB edit-dispatch profile and native copy slice

- Opt-in timing probes on actual 1 MiB keyboard edits put document replacement
  below 0.3 ms and paragraph slicing around 2–3 ms. The retained native
  layout edit took roughly 27 ms median, 43 ms p95 in the short probe. Within
  that edit, the guarded ASCII window cost about 1.7 ms, the whole-layout
  metadata copy about 5 ms, and line layout about 12 ms on representative
  samples. The probes were removed after measurement.
- Skribidi now copies the unchanged prefix, local window, and unchanged suffix
  as contiguous arrays, then adjusts the positional cluster/glyph metadata.
  This removes source selection and four scalar data copies from every
  codepoint of the 1 MiB paragraph. Native text-engine equivalence and the
  graphical decoration pixel suite pass.
- The first post-change 1 MiB varied-key run delivered all 30 frames but
  measured 175.24 ms p95 during unrelated concurrent Wasm and compiler builds
  (host load above 20; native render p95 rose to 39.65 ms from 5.48 ms).
  The 10 MiB run also delivered all 30 frames at 65.05 ms p95 with host load
  above 40 and native render p95 30.27 ms. Neither overloaded run can
  establish a latency improvement or regression. Repeat both timing gates on
  an idle host. Line layout is the largest measured native phase and remains
  the main incremental-layout work.

### M9.1 — parent repaint cost and typing-stage attribution (measured)

- Materia `9de8be1ab` records GPU draw calls in the wrapped-row regression.
  Its first render takes 19 draws, a cache-hit render 3, and an edit to one
  row 12. The edit still recomposites the unchanged row rasters into the
  containing pass, but their glyph paint remains cached.
- The 1 MiB varied-key trace from the preceding slice has p95 native render
  **5.48 ms**, total frame **8.04 ms**, and text-input dispatch
  **41.23 ms**. The long single-line fixture bypasses the row raster path,
  so partial parent repaint cannot improve its narrow 50 ms gate. The 10 MiB
  trace has p95 native render **8.37 ms** and total frame **30.82 ms**.
  `benchmark-uikit-typing.sh` now reports those stage p95 values alongside
  end-to-end latency; a new 30-event small-file run validates its output at
  **20.69 ms** end-to-end p95 and **1.33 ms** dispatch p95 (artifact
  `/tmp/exosuit-m9-parent-profile-small`).
- Partial parent repaint would require retaining or copying the old target,
  tracking damage across every background and decoration command, and
  preserving in-flight frames under the 64 MiB cache cap. That extra GPU
  transfer and bookkeeping are not justified by the current cost. Investigate
  the 1 MiB text-input edit-dispatch work before changing the pass model.

### M9.1 — shifted source metadata for unchanged ASCII rows (verified slice)

- Materia `da5afbe63` keeps a row's glyph revision after a guarded ASCII edit
  when its bytes and placement match, even if its codepoint range moves.
  Publication copies the small immutable row snapshot and rebases its source
  ranges; frames holding the old snapshot keep valid metadata. The row's
  source start is part of currency validation. Rows with absolute color ranges
  rebuild so their tint follows current source positions.
- Native tests cover insertion and deletion that move a wrapped suffix row by
  three codepoints, old-snapshot invalidation, rebased source ranges, and
  absolute color-range correctness. Text-engine, ABI, frame-resource and
  session-render smoke pass. The graphical decoration pixel smoke passes.
- The 1 MiB varied-key typing fixture passed over 30 actual input frames at
  **49.61 ms p95** against the 50 ms budget; artifact
  `/tmp/exosuit-m9-source-rebase-1mb`. The 10 MiB repeat-key fixture passed
  at **46.49 ms p95** over 30 frames, with a 210.25 ms worst-frame outlier;
  artifact `/tmp/exosuit-m9-source-rebase-10mb`. The 1 MiB margin is narrow
  under host variation. M9.1 remains active for colored rows, Unicode fallback
  and parent-pass recomposition. The full Exosuit headless suite exits 0.

### M9.1 — cached row paint on the layout-session editor (verified slice)

- Materia `090ba9d31` gives eligible visible rows their own shallow cached
  raster pass, then composites each at its original place in the parent pass.
  The original clip remains on the composite, preserving selection and
  decoration order. Multi-row layouts and short single-row paragraphs use
  immutable row glyph snapshots; very long single rows, rotated text, ranges
  above 96 rows and exhausted transient IDs retain the direct draw path.
  The raster cache supports 128 entries within its existing 64 MiB byte cap.
- The native layout-session regression reports nine initial cache misses,
  nine hits on repeat, then seven hits and two misses after one wrapped-row
  edit (the changed row and containing pass). Its 160-frame pressure case
  verifies bounded eviction. ABI, text-engine, frame-resource, public-renderer
  and session-render native tests pass. Real graphical decoration pixels pass.
- The 30-event typing fixtures pass: small 4.2 KiB p95 **19.87 ms**; 10 MiB
  p95 **27.98 ms**; 1 MiB varied-key repeat p95 **46.73 ms**, under the 50 ms
  gate. Artifacts: `/tmp/exosuit-m9-row-cache-small`,
  `/tmp/exosuit-m9-row-cache-10mb`, and
  `/tmp/exosuit-m9-session-row-cache-repeat` (plus `.log`). The preceding
  1 MiB run was **57.24 ms p95** under host variation and missed the gate;
  report both runs. The full Exosuit headless suite exits 0.
- M9.1 stays open: unchanged row rasters are reused, but their parent pass
  still recomposites them. Unicode/native fallback and source-shift cases
  remain more conservative than strict changed-row invalidation.

### M9.1 — row-scoped visible text commands (verified slice)

- Materia `83904c4b7` splits a multi-row visible text command into independently
  keyed draw commands. Each command binds an immutable per-row glyph snapshot;
  unchanged rows retain that snapshot across edits instead of rebuilding an
  aggregate viewport. The row commands retain the original clip and transform,
  place glyphs using measured row bounds, and refresh a row privately if atlas
  preparation invalidates it before sealing. One-row and resource-limit cases
  continue through the bounded aggregate path.
- Native UIKit ABI, text-engine, frame-resource and public renderer smoke tests
  pass. The real graphical decoration smoke passes, including wrapped-paragraph
  navigation, selection and diagnostic pixels. The 1 MiB varied-key fixture
  delivered 30/30 frames: p50 **39.30 ms**, p95 **43.13 ms**, max **45.61 ms**,
  below the 50 ms p95 budget. Artifacts: `/tmp/exosuit-m9-row-commands` and
  `.log`.
- M9.1 remains open here because render-pass caching is pass-wide. The next
  slice above adds bounded row raster caching on the editor's actual
  layout-session path while preserving clipping and decoration order.

### M12.2 — docked terminal view (initial Linux slice)

- The graphical package now depends on `terminalsession` and opens a local
  shell in an on-demand Terminal dock panel. `TerminalPane` owns dedicated
  terminal font resources and one retained canvas per emulator row. It updates
  row text layouts only when the emulator reports changed rows, and uses
  per-row raster keys so unchanged rows keep their paint cache. The backdrop
  measures the resolved pane and resizes both emulator and PTY to whole cells.
- Clicking the pane focuses it; text input, Enter, Backspace, and Tab go to
  the PTY. Closing the panel or app closes the session and UI resources.
  `--open-terminal` starts the pane for desktop smoke runs. Follow-on commits
  `a3f0a4a` and `f14d847` added per-cell terminal colors, cursor drawing,
  scrollback controls, broader keyboard input and matching light/dark shell,
  panel and terminal palettes. The no-folder Explorer collapses to a narrow rail.
- `scripts/test-terminal-ui.sh` uses disposable application state, real X11
  input, and a resized window. It verifies the dock, row canvases, 80×6
  session geometry, and shell input. The captured shell output reports
  `stty size` as `6 80`. Graphical builds pass in reference and self-hosted
  compiler modes. Selection and redraw benchmark remain M12.2 work. The follow-on graphical
  terminal smoke and headless tests passed; physical desktop review remains.

### M9.1 — identical-range suffix snapshot reuse (verified slice)

- Materia `736b3241a`. UIKit's guarded ASCII edit path now compares old and new row text after an
  offset-shifting edit. It retains a row revision only when its source range,
  bytes and bounds agree, allowing immutable glyph snapshots to survive a
  repeated-run insertion or deletion without exposing stale source offsets.
  Rows whose text changes still receive a fresh revision.
- The native text-engine regression first failed against the old invalidation
  rule and then passed with the new rule. The real 1 MiB varied-key benchmark
  delivered 30/30 frames: p50 43.84 ms, p95 52.70 ms, max 52.85 ms (artifacts
  `/tmp/exosuit-m9-row-after`). The same fixture before this change measured
  p50 39.89 ms, p95 53.26 ms, max 67.51 ms. Both p95 values exceed the 50 ms
  gate, so performance acceptance is still open. This does not complete strict
  changed-row display-list invalidation.
- The native `nativekit_ui_text_engine` test and real graphical decoration
  smoke both exit 0. The next slice below removes the redundant full-range
  publication; row-level paint invalidation is the remaining M9.1 step.

### M9.1 — direct viewport glyph ownership (verified slice)

- Materia `f0688c6fb` removes a second, full-range glyph publication from the
  native frame seal. The render frame now owns the already prepared visible
  buffer. A later rebuild uses copy-on-write when a sealed frame still owns the
  earlier buffer; atlas invalidation within a frame also rebuilds privately.
  This retains prepared rows and avoids copying the composed glyph geometry
  for the second publication.
- Native `nativekit_ui_abi`, `nativekit_ui_text_engine`,
  `nativekit_ui_frame_resources`, and `nativekit_ui_public_renderer_smoke` tests
  exit 0. The real graphical decoration smoke passes. The 1 MiB varied-key
  fixture delivered 30/30 frames at p50 **39.69 ms**, p95 **46.29 ms**, max
  **46.56 ms**, under the 50 ms p95 gate; artifacts:
  `/tmp/exosuit-m9-owned-viewport` and `.log`.
- Strict changed-row paint invalidation remains open. A changed visible row
  still rebuilds the aggregate viewport and changes its render-pass key.
  Next, represent visible rows as independently keyed draw commands, retaining
  correct clipping, styling, geometry and sealed-frame ownership.

### M12.1 — headless terminal session (initial Linux slice)

- `native-packages/terminal/session` defines byte-offset output and lifecycle
  events, a backend interface, terminal profile, and a `TerminalSession` that
  owns the emulator. It trims duplicate/overlapping output, buffers bounded
  gaps, requests replay, handles status before trailing output, and restores
  checkpoints. A borrowed output event is fed through `terminalkit_feed_range`
  without allocating a prefix copy; only queued out-of-order data is copied.
- `LocalPtyBackend` launches the profile program directly through NativeKit,
  drains into a reused 64 KiB buffer, bounds queued input at 1 MiB, and
  forwards resize, exit, and termination. `TerminalProfile` snapshots the
  parent environment, removes `NO_COLOR`, forces `TERM=xterm-256color`, then
  applies valid overrides. Haxeon `bf7e7150` adds generic `Sys.environment()`
  for this; `release.lock` pins it.
- Deterministic replay/overlap/checkpoint and real shell PTY round-trip tests
  pass in reference and self-hosted modes. The session package gate is in
  `scripts/test.sh`. `TerminalProfileRegistry` accepts plugin-owned profiles
  through the context's lifetime hook without depending on Exosuit's core
  package. The plugin integration test launches a registered profile and
  verifies cleanup on disable, reload, and shutdown. The graphical view,
  remote transport backend, and Windows ConPTY execution remain open.

### M11.4 — TerminalKit emulator (initial Linux slice)

- `native-packages/terminal` is a reusable Haxeon package with a native C
  library, generated HXI/HXMAP, thin Haxe `Emulator` wrapper, and native plus
  Haxe smoke tests. The Pragtical libtsm backend is vendored with MIT
  attribution. libtsm itself is a Git submodule pinned to
  `tritao/libtsm` commit `a676fa19`, published on
  `terminalkit-scrollback-draw`; the commit adds Pragtical's scrollback
  viewport API with a focused upstream test. The existing dirty Pragtical
  subproject checkout was not modified.
- The native API feeds PTY bytes, reports dimensions/cursor/modes/title,
  navigates scrollback, encodes keyboard/mouse/focus replies through a borrowed
  callback, and writes/restores replayable checkpoints. Active-screen
  snapshots expose borrowed typed cells and a UTF-8 arena. Changed-row flags
  hash rendered content because libtsm row IDs identify lines but do not
  change on every write. Haxe copies a row only when `rowText()` is called.
- The native contract ports emulator fixtures for screen text, style, cursor,
  scrollback, focus, mouse, keyboard, synchronized output, and checkpoint
  restore into a differently sized emulator. That restore test exposed stale
  attributes outside the constructor width; the vendored backend now clears
  the resized grid before replay. A long combining sequence confirms the
  pinned libtsm limit of ten code points per cell. Four-target HXI audit,
  native contract, and Haxeon smoke pass in reference and self-hosted modes.
  The fork's Meson library builds; its own unit suite could not run because
  the host lacks `check`.
- The package gate is included in `scripts/test.sh`.
- Follow-up TerminalKit work exposes styled cells through one packed copy per
  requested Haxe row, a bounded Haxe reply queue, Haxe keyboard/mouse/focus and
  checkpoint methods, and explicit alternate-screen state. Native PTY callers
  still use a borrowed direct reply callback and borrowed snapshot storage.
  The native contract and Haxe smoke cover these APIs in reference and
  self-hosted compiler modes. A POSIX `forkpty` smoke feeds a real stream into
  the emulator and sends input back; it passed 20 consecutive runs. This is
  an emulator/OS-PTY boundary test, not yet a NativeKit `nk_pty` session.
  M11.4 remains open for wider Pragtical conformance and Windows/macOS native
  execution; M12 will connect NativeKit PTY to the session model and view.

### M11.3 — SQLiteKit embedded storage (accepted Linux slice)

- `native-packages/sqlite` is a reusable package named SQLiteKit, with a
  shared native library, Haxeon manifest, generated HXI/HXMAP, and thin Haxe
  `Database`/`Statement` wrappers. Its C ABI uses opaque handles and supports
  prepare/bind/step/column, immediate transactions, busy timeout, change count,
  and last-insert ID. The Haxe wrapper covers rollback, typed values and safe
  blob copies. The native column-blob view borrows SQLite memory directly
  until step/reset/finalize, avoiding an intermediate native byte queue.
- The package vendors official SQLite 3.53.4 amalgamation, with version,
  download URL and verified SHA3-256 in `VENDOR.md`. The lock sidecar is
  `<database>.sqlitekit-lock`; POSIX `flock` and Windows `LockFileEx` refuse
  another SQLiteKit opener without waiting. The sidecar persists so its inode cannot be
  replaced while a process holds it. Paths must use one stable spelling.
- Native contract passes rollback, same-process and forked-process lock
  refusal, blob round trip, compare-and-swap revision update, close refusal
  with live statements, and reopen. `tests/run.sh` passes the four-target HXI
  audit, C contract, and headless Haxeon rollback/blob smoke, including an
  empty blob. Exosuit's `scripts/test.sh` now runs that package gate. The
  complete Exosuit headless suite passes in reference and refreshed
  self-hosted compiler modes; the final package gate was rerun in both modes
  after the empty-blob fix. Windows/macOS C execution remains pending; the HXI
  audit covers their ABI shapes only.
- Haxeon `7e432f80` imports opt-in incomplete `hxi:opaque` C typedefs and
  borrowed pointer outputs/results; `f2f277f5` documents the annotations.
  The importer fixture passes, and Haxeon's full suite passes 384/384 driver
  cases plus integrations/Wasm. `release.lock` pins that Haxeon HEAD; its
  pre-existing dirty `vendor/hashlink` pointer remains unstaged.
- M9.1's graphical timing gate and Windows ConPTY/named-pipe work remain open.

### M11.1 — POSIX PTY runtime (accepted native slice)

- NativeKit `4511511b` and `b5f5ab4d` add generation-checked `nk_pty_*` handles on Linux and
  macOS. Spawn accepts absolute program, argv, cwd, environment and cell size;
  the master descriptor is nonblocking. Read and write use caller buffers
  directly, with a 64 KiB per-call bound and no intermediate byte queue.
  `NK_EVENT_PTY_READABLE` and `NK_EVENT_PTY_EXITED` carry no output copy; a
  monitor wakes the UI loop, while callers drain bytes with `nk_pty_read`.
- Native contract passes shell echo, cwd, custom environment, `stty size`
  after spawn and resize, bounded read under a 1 MiB producer, natural exit,
  kill, and close. A fork race on immediate close is covered by process-group
  termination with a child-PID fallback; 20 consecutive native contract runs
  pass. The Haxe ABI importer passes Linux, Windows and both macOS
  targets; `pty_contract` and `transport_contract` pass in
  `/tmp/materia-nativekit-m11-build`. NativeKit source and generated HXI are
  committed, and `release.lock` pins the commit.
- M11.1 remains open for Windows ConPTY runtime and a platform execution
  test. The current Windows stub reports `NK_ERROR_UNSUPPORTED`. The
  Pragtical runtime reference was located after this slice and can inform
  the remaining ConPTY implementation.

### M11.2 — POSIX local transport hardening (accepted Linux slice)

- NativeKit commits `2574e961`, `51537156`, and `dd905416`; the accompanying Exosuit
  commit pins the NativeKit HEAD in `release.lock`. The existing Materia
  `nativekit` gitlink was already off-pin and remains unstaged.
- Local listeners now require a user-owned, non-symlink private parent
  directory; create socket paths with mode 0600; preserve regular files and
  live sockets; and remove only stale sockets owned by the current user.
  Client and accepted sockets check peer uid using `SO_PEERCRED` on Linux
  (`getpeereid` on macOS). Windows capability reporting no longer advertises
  unsupported local transport.
- The NativeKit `transport_contract` passes unprivileged and under `pkexec`.
  The privileged run drops a child to uid/gid 65534, permits it to connect to
  the test socket, and verifies no accepted-peer event reaches the queue.
  Private-parent refusal, symlink refusal, regular-file preservation, stale
  recovery, live-socket preservation and socket mode are covered. The contract
  also delivers a local stream one byte at a time and rejects a payload above
  16 MiB; both unprivileged and privileged runs pass after this addition. Build:
  `/tmp/materia-nativekit-m11-build`; logs under `/tmp/nativekit-m11-*`.
- M11.2 remains open on Windows for named pipes with a current-user-only DACL
  and a Windows CI build. Protocol framing belongs to M13 and is not supplied
  by NativeKit's raw byte stream. M11.1's POSIX PTY slice is recorded above.

### M9.1 — equal-length suffix culling reuse (verified native and UI slice)

- Skribidi `d744d4780`, Materia pin `5b9a4c60d`; the accompanying Exosuit
  commit updates `release.lock` and the native differential probe.
- Guarded equal-length ASCII edits carry forward culling and common-glyph
  bounds for rows strictly after the edit when source range, baseline, and box
  geometry match. The 240-case native sweep now compares those bounds against
  fresh layouts for replacements as well as insertions and deletions. The full
  probe, UIKit native text-engine test, and real decoration pixel suite pass.
- The host remained heavily loaded (load average around 20–23, with unrelated
  compiler jobs), so no real typing-budget measurement is claimed. Resume by
  running the 1 MiB varied-key graphical fixture when the host is idle. If
  p95 remains marginal, reduce full-row native layout work; retained culling
  alone does not eliminate it.

### M9.1 — guarded ASCII prefix culling reuse (verified native and UI slice)

- Skribidi commit `bc8ae4ead`; Materia pin `f5d8ac04d`; the accompanying
  Exosuit commit updates `release.lock` and the fresh-layout probe.
- The guarded ASCII edit carries culling and common-glyph bounds for strict
  prefix rows only when their source range, baseline, and box geometry match.
  Changed or shifted rows still compute bounds from glyphs. The full probe
  passes 240 accepted native ASCII edits and compares every row's culling
  bounds with a freshly shaped layout, including the 1 MiB insertion/deletion
  fixture. UIKit's native text-engine test, graphical build, and real
  decoration pixel suite pass.
- A temporary 300-edit native-only run measured **21.49–23.39 ms mean CPU**
  across three runs, versus **23.74 ms** in one preceding run without this
  change. This suggests a small gain but is not a controlled wall-clock result.
  The real 50 ms p95 gate remains pending: unrelated compiler jobs raised
  host load above 40 during graphical verification. Next, rerun the 1 MiB
  varied-key fixture on an idle host, then continue reducing full-row layout
  work if the gate remains marginal.

### M9.1 — insertion/deletion prefix-row reuse (verified slice)

- Materia commit `b9f109586`; the accompanying Exosuit commit pins it in
  `release.lock`.
- UIKit preserves prepared glyph snapshots for visual rows strictly before a
  guarded ASCII insertion or deletion when their range and bounds match. The
  native text-engine regression proves prefix identity survives both edits
  while a later wrapped row is invalidated. The real decoration-window suite
  passes.
- A trial suffix rebase was rejected: in a continuously wrapped word, an
  inserted codepoint can leave later pixels looking the same while the row's
  source range no longer maps to one old row. Reusing the old snapshot would
  publish stale codepoint metadata. Suffix rows still reprepare, and M9.1's
  strict changed-row gate remains open for a source-aware remap and retained
  display-list raster invalidation.
- The isolated native text-engine test passes after rebuilding against the
  reverted Skribidi experiment. Two valid 30-frame, 1 MiB varied-key runs
  measured **51.93 ms** and **50.31 ms p95**, above the 50 ms target
  (`/tmp/exosuit-m9-prefix-row-typing` and `-repeat`). A further graphical
  run was discarded because another `run.sh` rebuilt the shared output while
  the benchmark app started. Re-run in an idle build window before treating
  timing as a regression or claiming the budget gate.
- Renderer trace: `prepare_visible_text` still composes visible row snapshots
  into one viewport glyph resource, and its resource binding includes the
  layout generation, which changes on every edit. That remains a changed-row
  invalidation gap, but the saved 30-frame timelines put input dispatch at
  roughly **35 ms median / 45 ms p95** and frame rendering at only **2–4 ms**.
  Optimizing the viewport binding alone cannot provide a robust typing margin.
- A temporary probe outside the repository (`/tmp/exosuit-edit-window-profile`)
  ran 300 guarded 1 MiB native edits without full-layout oracles between edits:
  **23.74 ms mean CPU**. A `perf` sample placed the largest edit costs in
  `skb__layout_lines`, per-line culling bounds, and the edit's full-layout
  materialization; the one-glyph eligibility scan was smaller. Artifacts:
  `/tmp/exosuit-m9-native-edit-300.perf.data` and `.log`. EditorKit's
  `TextDocument` already splits offset maps into ~2 KiB segments, so a
  document-wide offset-map rebuild is not the likely dispatch bottleneck.
  Next, reduce native row layout/culling work for supported guarded edits
  while preserving full geometry and differential tests. Do not reuse shifted
  suffix glyph rows until their source ranges are remapped and verified.

### M9.1 — retained visual-row glyph invalidation (verified slice)

- Materia commit `558499f54`; the accompanying Exosuit commit records this
  result and pins the revision in `release.lock`.
- For an equal-length guarded ASCII edit, UIKit now retains a visual row's
  prepared glyph snapshot only when its codepoint range, bounds, font atlas,
  and foreground publication key remain valid. The edited row gets a new
  revision; native tests prove rows before and after reuse their immutable
  snapshots for equal-length edits.
- The scene compiler uses the retained snapshot directly, removing its second
  glyph preparation pass. The editor's multi-row viewport composes visible
  row snapshots and retains them across edits. Single-row viewports keep direct
  preparation, which avoids copying a very long row.
- C ABI, text-engine, and scene-compiler tests pass. The real graphical
  decoration suite passes. The first 1 MiB run with unconditional row
  composition regressed to **54.26 ms p95**. After the single-row bypass, a
  fresh 30-frame varied-key run measured p50 **40.57 ms**, p95 **49.03 ms**,
  max **53.62 ms**, under the **50 ms** p95 budget. Artifacts:
  `/tmp/exosuit-m9-row-single-typing` and `.log`.
- M9.1 remains active: insertions/deletions still invalidate shifted suffix
  rows conservatively, and the display-list renderer redraws the visible
  viewport even when its unchanged row snapshots are reused. Next, measure
  changed-row publication for offset-shifting edits and update the row index
  and source ranges before claiming strict changed-row invalidation.

### M9.1 — guarded ASCII layout reuse and visible-line backgrounds (verified slice)

- Commits: Skribidi `7b10d4821`; Materia `baff45a53`. The Exosuit commit
  containing this record also pins the Materia revision in `release.lock`.
- Skribidi's guarded edit operation reshapes a 16-codepoint window for short
  lowercase ASCII edits in simple LTR one-glyph-per-codepoint layouts. It
  checks both seams, reuses old prefix/suffix shaping, and materializes one
  native layout generation for rendering and geometry. Unsupported cases
  retain complete-layout fallback. UIKit records fast-path and fallback counts.
- UIKit exposes retained visible-line rectangles to whole-line background
  decorations, removing per-grapheme caret work from that paint path. Its
  edit-range UTF-8 lookup now uses constant extra memory.
- The real 1 MiB varied-key benchmark delivered 30 input frames: p50
  **37.66 ms**, p95 **41.67 ms**, max **43.44 ms**, under the **50 ms** budget.
  Artifacts: `/tmp/exosuit-m9-byte-range-typing` and `.log`. The preceding
  traced run saw 60 guarded edits and no fallback; without the byte-range
  change, its p95 was 63.41 ms. These runs are separate and should not be
  combined as one sample.
- Native ABI/text-engine tests and the UIKit Haxe framework smoke pass.
  The full differential probe passed 240 randomized accepted cases plus
  repeated 4,096-codepoint and 1 MiB edits against fresh native layouts.
  The real graphical decoration smoke passes. Strict changed-row
  invalidation remains open, so M9.1 is still active.
- Resume with changed-row invalidation: trace retained dirty-row publication
  during an edit that affects one wrapped row, then make rendering and paint
  publish only the affected visible rows while retaining correct full-query
  geometry. Keep unsupported Unicode on the complete-layout path.

### M9.1 — multi-caret keyboard navigation (verified slice)

- Materia `ef68e734c` adds a typed UIKit navigation intent for controlled
  fields with additional selections. Exosuit applies each key movement to the
  full selection set using the retained shaped layout's grapheme, word,
  paragraph, visual-line and line-boundary geometry. Shift extends every
  selection; overlapping results are normalized by `BufferSelection`.
  Repeated vertical movement retains each caret's requested x column and
  resets it after an edit or pointer selection. Single-selection fields keep
  the existing UIKit path.
- The real decoration-window test now drives two carets across `é🙂` grapheme
  boundaries, extends both selections, moves both to line end and then down a
  visual line. Reference and self-hosted builds/pixel checks pass. The UIKit
  Haxe framework smoke passes. Logs: `/tmp/exosuit-m9-multinav-build.log`,
  `/tmp/exosuit-m9-multinav-test.log`,
  `/tmp/exosuit-m9-multinav-self-build.log`,
  `/tmp/exosuit-m9-multinav-self-test.log`, and
  `/tmp/uikit-m9-multinav-framework.log`. A final unchanged-source
  reference window rerun and unpacked release check pass at
  `/tmp/exosuit-m9-multinav-final-test.log` and
  `/tmp/exosuit-m9-multinav-release-test.log`.
- A second real-window fixture puts two carets inside one 400-character
  paragraph and verifies that Down advances both to the next wrapped visual
  row without changing logical lines or losing a caret. The complete reference
  and self-hosted decoration suites pass
  (`/tmp/exosuit-m9-multiwrapped-test.log` and
  `/tmp/exosuit-m9-multiwrapped-self-test.log`).
- M9.1 remains active: strict changed-row invalidation and the 1 MiB typing
  budget are still open. An isolated cluster-input row-reflow prototype now
  exercises viewport-first delivery; edit-range shaping is the next gate.

### M9.1 — long-paragraph update reduction (diagnosis; budget still failing)

- Materia `32e3748df` exposes `nkui_text_layout_edit` with a half-open codepoint range
  and UTF-8 replacement. `TextEditorLayout.setTextAfterEdit` forwards the known
  edit for a stable chunk; repartitioning still uses full update. The native
  implementation currently splices text and rebuilds one Skribidi layout, so
  all rendering and geometry still share one generation. The C ABI and native
  text-engine tests pass; `check-hxi.sh` and the Haxe framework smoke pass.
  A native Unicode replacement/insertion/deletion regression compares its
  caret geometry with fresh layouts. The graphical app builds, and the real
  1 MiB varied-key fixture delivered 30 input frames: p50 **248.34 ms**, p95
  **268.12 ms**. Artifacts are in `/tmp/exosuit-m9-edit-range-typing` and
  `/tmp/exosuit-m9-edit-range-typing.log`. This validates the edit boundary,
  not incremental layout or the 50 ms gate.

- An opt-in temporary Skribidi phase probe on the real 1 MiB typing fixture
  measured 62 builds: median UTF-8 decode/text-property setup **41.5 ms**,
  itemization **16.4 ms**, shaping and cluster construction **122.3 ms**, and
  line layout **12.0 ms**. The probe was removed after measurement; no diagnostic
  code or native behavior change is retained. Artifacts:
  `/tmp/exosuit-m9-phase-long` and `/tmp/exosuit-m9-phase-long.log`.
- A conservative HarfBuzz unsafe-to-concat boundary experiment on a 4,096-`a`
  single run found no interior safe boundary. It was reverted because it would
  still reshape the entire measured line. Reusing glyphs alone also cannot
  meet 50 ms while full decoding and itemization take roughly 58 ms combined.
- `scripts/benchmark-uikit-typing.sh` now accepts
  `TYPING_UI_KEY_PATTERN=varied`, typing different letters at the same caret
  between deletions; the default repeated-key fixture remains comparable to
  earlier runs. On the clean native build, 30 varied delivered inputs/frames
  measured p50 **253.33 ms**, p95 **292.04 ms**, max **295.28 ms**. Artifacts:
  `/tmp/exosuit-m9-typing-long-varied` and `.log`. This still fails 50 ms.
- The uncommitted decoded-text reuse experiment was reverted. A separate
  `experiments/incremental_wrap.py` prototype now accepts shaped clusters,
  locates the edited row by binary search, backs up one row at boundaries, and
  yields changed rows before scanning the suffix. Its differential tests pass
  for 200 randomized edits, variable widths, ligature/emoji/Arabic clusters,
  and a 1 MiB deep edit. It models character wrapping only; it does not prove
  Skribidi shaping equivalence or reuse cached suffix rows.
- A disposable Skribidi probe compared local-window shaping with the matching
  full-layout clusters for 4,096-character repeated-`a` and varied Latin
  samples, with an edit at the midpoint. Both 4- and 64-character radii had
  zero mismatched local cluster IDs/advances. This checks only the sampled
  window; it cannot prove that glyphs outside the window remain reusable, nor
  does it cover Unicode, bidi, carets, or line breaking. The probe lives at
  `/tmp/exosuit-shape-seam.c` and was not wired into production.
- A repeatable C probe in `experiments/skribidi_edit_window/` now constructs a
  cached-prefix / newly shaped window / cached-suffix candidate and compares
  cluster ranges, glyph IDs, advances, and vertical offsets to fresh Skribidi
  layouts. It also compares per-codepoint text properties and glyph
  IDs/ranges/directions/positions in one-line visual render order.
  It tests substitution, insertion, deletion, Latin ligatures, Arabic joining,
  mixed Hebrew/Latin, emoji ZWJ, 36 extra edit positions, and 96 deterministic
  mixed-script edits. Edges align to old cluster boundaries; unchanged
  four-codepoint glyph/property guards reject contextual seam changes. Matching Hebrew/Latin
  cluster signatures still produced a different visual order, so any RTL run
  in the old paragraph or new window conservatively rejects short reuse.
  Arabic still mismatches at a 130-codepoint window and falls back.
  Glyph-equivalent Latin/emoji windows also changed text properties at seams.
  Leading/trailing caret comparisons found emoji geometry differences despite
  matching glyphs, so emoji now falls back. The local window adds a break at
  its artificial final codepoint; retaining that unchanged codepoint's cached
  property allows a 4,096-character `a` edit to pass fresh glyph, caret and
  character-wrap comparisons at radii 4, 16, and 64. The gates accepted 25
  short windows and rejected 398; all accepted windows matched the sampled
  fresh-layout glyphs, properties, one-line visual positions and caret x.
  The full-window oracle
  passes in all cases. The probe build and executable exit 0; output is in
  `/tmp/exosuit-edit-window-results.txt`.
- Cluster and text-property candidates now use indexed references to old and
  local layouts instead of copying and sorting every cached cluster. The 1 MiB
  smoke fixture constructs three cluster and four property pieces; 100,000
  paired random lookups take about **3 ms CPU** on this host.
- The mutable fixture applies 30 varied letter replacements to a 4,096- and a
  1 MiB-codepoint line. After **every edit**, indexed clusters and properties
  match fresh Skribidi layouts; the final 1 MiB character-wrap breaks also
  match. The 1 MiB isolated nine-codepoint shape plus piece splice measured
  p50/p95 **0.026/0.032 ms CPU** in the final verification run. This excludes
  the full oracle, row geometry,
  rendering, UIKit event dispatch, and publication, so it is not a typing-frame
  result. Artifacts: `/tmp/exosuit-edit-window-results.txt` and
  `/tmp/exosuit-edit-window-build.log`.
- Another 30-edit fixture alternates insertion and deletion at one caret.
  Both the 4,096-codepoint and 1 MiB versions match fresh clusters and text
  properties after every edit, including suffix offset shifts; the final
  1 MiB character-wrap breaks match. Isolated 1 MiB text copy, shape and
  splice measured p50/p95 **0.096/0.120 ms CPU**. A visible-row reflow
  started one row before a 1 MiB replacement, visited 288 clusters for 12
  rows, and matched fresh Skribidi breaks among 43,691 total rows.
- `docs/architecture/0003-incremental-text-layout.md` records the required
  composite snapshot boundary: `TextEngine` currently owns one `skb_layout_t`
  and routes rendering, hit tests, carets and line queries through it. The
  indexed pieces need a common generation and row index before UIKit can use
  them without breaking those APIs. The Haxe `setTextAfterEdit` path already
  carries old/new document offsets; stable changed records now call
  `TextLayout.edit` with chunk-relative ranges. The native call still uses
  complete layout and awaits the composite snapshot implementation.
- This probe is not a correctness proof or production implementation. It
  still scans cached layouts for oracle checks and glyph-position reconstruction,
  checks only one unbroken-word wrap fixture,
  and has no general bound for Arabic joining, emoji carets, or bidi changes.
  The mutable cluster splice handles only one-codepoint clusters; visible
  reflow covers one unbroken ASCII word. Exact next: add a composite layout/render boundary
  over pieces, reflow row metrics lazily from the edit, and compare general word
  wrapping and caret geometry with fresh Skribidi layouts. Then integrate the
  safe Latin path into UIKit and remeasure varied 1 MiB input. A full-paragraph
  fallback remains mandatory. HarfBuzz's unsafe-to-concat flag alone cannot
  bound the edit window for the measured font. M9.1 and 50 ms remain unmet.

### M9.1 — visible glyph publication and long-line edit profile (verified slice)

- Skribidi `6c53759` adds half-open visual-line range iteration and glyph
  preparation. The full-layout APIs delegate to the range APIs. A 1 MiB wrapped
  word regression checks a middle line visits only its glyphs, empty and invalid
  bounds, and callback termination. Its full native test suite passes.
- Materia `2c8600fc1` carries the visible range through TextEngine, both public
  rendering paths and immutable snapshot publication. Conservative line bounds
  permit binary viewport lookup; native atlas refresh keeps the selected range
  and tint. Bounded render targets use their own height; translated targets use
  the full preparation path. A GPU regression renders a 100,000-character
  wrapped paragraph at the top and after scrolling 5,000 pixels. The complete
  native CTest suite passed 61/61, with the environment-dependent joystick test
  skipped; focused renderer checks passed after the target-bounds adjustment.
  Logs: `/tmp/skribidi-m9-line-range-test.log`,
  `/tmp/uikit-m9-visible-range-all.log`,
  `/tmp/uikit-m9-visible-target-tests.log`, and
  `/tmp/uikit-m9-visible-scroll-test.log`.
- Ordinary edits now update the retained native paragraph layout, matching the
  already retained newline-edit path. This avoids creating a new text engine and
  atlas on every keystroke. The framework smoke and graphical build pass.
- The final reference and self-hosted graphical builds and real decoration
  pixels pass. Both browser guest targets pass Unicode edit, save/readback,
  URL and fresh reload; the unpacked release and real Haxeon LSP pass.
  Logs use `/tmp/exosuit-m9-visible-` with `final-build`, `self-build`,
  `ref-decoration`, `self-decoration`, `web32-test`, `webgc-test`, and
  `release` suffixes plus `.log`.
- The real UIKit project/open/edit/save/palette/problems/build/plugin workflow
  passes after an initial artifact-free exit during the loaded native run; the
  unchanged-source retry retained artifacts at
  `/tmp/exosuit-m9-visible-workflow-artifacts` and passed
  (`/tmp/exosuit-m9-visible-workflow-retry.log`). The first exit had no captured
  app diagnostic, so its cause is not established.
- A final 61-test native CTest run passed every text/UI check but saw the
  unrelated GPU contract smoke fail. The same binary passed directly and on
  a subsequent isolated CTest run without source changes
  (`/tmp/uikit-m9-gpu-contract-uncontented.log`). This is recorded as an
  intermittent test failure, not a text change regression or a clean 61/61
  final run. The earlier full native run passed 61/61; one joystick test was
  skipped in both runs.
- The 1 MiB single-line fixture now has 30 delivered input events in 30 frames:
  p50 288.47 ms, p95 **313.69 ms**, max 321.93 ms. This improves the prior
  808.62 ms p95 but still **fails** the 50 ms budget. Mean native render fell
  from about 401 ms to 2.2 ms; mean edit dispatch remains **236.5 ms** and
  frame time 51.3 ms. Retained resource reuse improves p95 only modestly
  (viewport-only p95 324.93 ms). Logs/artifacts:
  `/tmp/exosuit-m9-typing-long-visible` and
  `/tmp/exosuit-m9-typing-long-retained` (plus `.log`).
- Final small fixture: 30/30 frames/events, p95 **18.14 ms** (passes).
  The 10 MiB multiline fixture produced 30 frames/events, p95 **62.59 ms**
  on the first run (fails), then 29 frames/events, p95 **44.30 ms** on an
  unchanged-build repeat (passes). Both runs had one approximately 255 ms
  outlier; the first also had a 40 ms tree/style frame. The status is
  variable under this workstation load, so a stable 10 MiB acceptance is
  not claimed. Artifacts: `/tmp/exosuit-m9-visible-small-final`,
  `/tmp/exosuit-m9-visible-10mb-final`, and
  `/tmp/exosuit-m9-visible-10mb-repeat` (plus `.log`).
- The 100 Hz HashLink profile (`/tmp/exosuit-m9-long-edit-profile.log`) repeatedly
  identifies `nkui_text_layout_create_styled` inside the edit path. The editor
  still has to reshape and wrap the whole million-character paragraph after
  every character edit. The next implementation must reuse unaffected shaping
  and row geometry across edits while preserving Unicode, bidi and contextual
  shaping semantics; a cache of this fixed benchmark input would not satisfy
  the general typing budget. Strict changed-row invalidation and multi-caret
  movement remain pending. M9.1 acceptance is not claimed.
- A follow-up experiment reused Skribidi's retained buffer capacities on each
  text update. Native text/render smoke checks passed, but two unchanged-build
  1 MiB runs gave p50/p95 **250.41/605.90 ms** and **310.09/535.04 ms**;
  several edit-dispatch samples exceeded 400 ms. The experiment was reverted,
  so the committed p95 remains 313.69 ms. Artifacts:
  `/tmp/exosuit-m9-typing-long-reuse` and
  `/tmp/exosuit-m9-typing-long-reuse-repeat` (plus `.log`). This rules out
  allocation reuse alone as the long-paragraph fix.

### M9.1 — large-file startup and measured typing (verified fixes, budget still partial)

- Haxeon `460e10d7` fixes generic factory/disposer callback inference for implicit
  static and instance methods. Non-lambda arguments and known callback contexts
  bind type parameters progressively; reversed callbacks are revisited rather
  than defaulting their receivers to Dynamic. Class/expected-result substitutions
  remain intact. The reduced resource factory now compiles without annotations.
  Accepted execution and rejected missing-method/wrong-type regressions pass;
  all 384 compiler tests, integration/Wasm gates, bootstrap convergence and
  identical self-hosted rebuild pass. Logs: `/tmp/haxeon-m9-callback-gate-verified.log`,
  `/tmp/haxeon-m9-callback-bootstrap.log` and `-bootstrap-self.log`.
- Skribidi `889e644` caches remaining word lookahead across character-wrapped
  rows, eliminating quadratic rescanning. Tab-dependent widths are not cached;
  short tails retain original width accumulation. The new 1 MiB wrapped-word
  regression times out at 20 seconds before the fix and passes in 1.149 CPU
  seconds afterward; the complete native Skribidi suite passes.
- Materia `065eb34cf`: UIKit defers glyph preparation until rendering, culls offscreen transformed
  glyph quads before bounded GPU upload, and starts TextEditorState with an
  unconstrained provisional width. A 100,000-character native rendering regression
  verifies upload succeeds; the framework regression checks initial measurement
  followed by real-width wrapping. EditorKit skips Unicode property scans for
  ASCII pairs while preserving CRLF and Unicode adjacency; exhaustive representable
  ASCII-pair and incremental/Unicode regressions pass.
- Exosuit's gutter retains one layout and shapes only viewport labels, instead
  of allocating a view/layout for every logical line. This avoids both resource
  exhaustion and repeated traversal of tens of thousands of offscreen labels.
  No Clay change was needed. Existing wrapped-row/gutter alignment is not claimed
  as fixed by this performance work.
- Capture metadata now records delivered text-input count, oldest delivery time
  and edit-dispatch duration before the adapter mutates the document. Coalesced
  caret requests retain the input attribution. The benchmark waits for the actual
  first rendered frame and measures delivered input through completed frame,
  including edit dispatch, excluding OS delivery and physical display scanout.
  Earlier request-reason filtering missed coalesced inputs and excluded dispatch;
  those historical measurements are not directly comparable.
- Final Linux i5-13600K measurements, 30 input events in 30 measured frames each:
  small (4,200 bytes) p50 **17.47 ms**, p95 **20.03 ms**, max **22.82 ms**;
  original 10 MiB multiline fixture p50 **26.31 ms**, p95 **36.86 ms**,
  max **46.92 ms**; 1 MiB single line p50 **705.83 ms**, p95 **808.62 ms**,
  max **824.02 ms**. The small and multiline cases pass the 50 ms budget;
  the single line fails. Artifact directories are `/tmp/exosuit-m9-typing-small-traced`,
  `/tmp/exosuit-m9-typing-10mb-viewport`, `/tmp/exosuit-m9-typing-long-line-traced`;
  logs use the same names plus `.log`. Multiline inputs were paced at 400 ms
  and single-line inputs at 1,200 ms to collect distinct frames; small uses 120 ms.
- Final benchmark-default verification also passes: 10 MiB, 30 frames/events,
  p50 26.35 ms, p95 **35.74 ms**, max 40.61 ms, 45-second capture/400 ms pacing,
  with both settings recorded in `/tmp/exosuit-m9-typing-10mb-defaults/result.json`.
- Single-line mean edit dispatch is 254 ms, custom paint 32 ms and native render
  401 ms. Whole-paragraph shaping/prepared-glyph generation and traversal remain
  the measured next targets. In particular, TextEngine line publication passes
  a codepoint range to its callback but still prepares/iterates the whole native
  layout before filtering. Bound that work to visible lines, then remeasure the
  remaining edit dispatch. Both large fixtures now open and accept input;
  **M9.1 remains active**, including strict changed-row invalidation and multi-caret
  movement. Do not mark overall acceptance complete.
- `scripts/profile-uikit-startup.py` retains startup samples, native profiler output
  and sampled HashLink peak RSS with disposable portable state. The unconstrained
  startup/ASCII run of the original multiline fixture used about 2,090,884 KiB
  peak RSS and completed three frames in 10.22 seconds, before the final viewport
  gutter optimization; this is not a final startup-memory acceptance claim.

- Verification for this slice: native CTest has 61/61 passing checks across the
  full run and four framework reruns, plus the added large-upload regression;
  EditorKit DocCheck passes. Reference and self-hosted decoration pixels and
  graphical builds and complete headless suites pass in both compiler modes
  (`/tmp/exosuit-m9-large-headless.log` and `-headless-self.log`).
  Real UIKit workflow, actual Haxeon LSP and unpacked
  release pass. Both browser targets pass edit/save/readback/URL/fresh reload.
  Logs use `/tmp/exosuit-m9-large-` with `decoration`, `decoration-self`,
  `self-build`, `workflow`, `lsp`, `release`, `web32-retry`, `webgc-test` suffixes
  and `.log`; native evidence is `/tmp/uikit-m9-large-native-tests.log`,
  `/tmp/uikit-m9-large-framework-verified.log`, `/tmp/uikit-m9-large-render.log`.
- The first browser reload attempt timed out after successful edit/save; an
  unchanged-build retry passed. Failure output now retains the final fresh-page
  probe, console and network failures. Cause remains unresolved; do not claim a
  browser product fix. Four initial framework wrappers failed during an invalid
  incidental compiler-formatting intermediate; formatting was restored and all
  four pass with the final committed compiler. No test was removed or suppressed.

### M9.1 — restored UIKit keyboard benchmark (initial measurements)

Historical measurements before the startup fixes recorded above.

- `scripts/benchmark-uikit-typing.sh` drives actual X11 character insertion and
  backspace through the production editor with disposable portable state. It
  retains capture/event timelines and reports committed TextInput-request to
  completed-frame time, excluding OS delivery and physical display scanout.
  Backspace restores the fixture between measured insertions. The script
  supports the fixed small, 10 MiB and 1 MiB single-line fixtures and records
  CPU/platform metadata. Exit 0 means valid measurements, not budget acceptance;
  `withinBudget` explicitly reports the p95 < 50 ms result.
- Small fixture: 4,200 bytes, 30 committed text-input frames on the i5-13600K,
  p50 13.79 ms, p95 21.56 ms, maximum 21.93 ms. Artifacts:
  `/tmp/exosuit-m9-typing-small-fixed`; log has the same path plus `.log`.
  These observations are from a workstation also running other compiler work.
- The 10 MiB run exits 137 after its HashLink process is killed, before frame
  captures/measurements exist (`/tmp/exosuit-m9-typing-10mb.log`, artifacts at
  the same path without `.log`). No OOM cause was established from available
  kernel/service logs; do not classify this as a passed latency measurement.
- The 1 MiB single-line run reaches the 180-second external timeout (124),
  with about 100% of one CPU core and roughly 398 MiB RSS observed while stuck.
  Only startup/window events were recorded; no input-frame measurements exist.
  Artifacts/log: `/tmp/exosuit-m9-typing-long-line` and `.log`.
- Large-fixture startup/typing remains an unresolved product limitation.
  Next: profile document/highlighter creation, native shaping and the first UI
  submission separately on reduced long-line sizes; collect peak memory for
  the 10 MiB failure. Fix measured bottlenecks and affected-row invalidation,
  then rerun the fixed fixtures. Do not check M9.1's overall acceptance yet.

### M9.1 — multiple selections/carets and delegated editing (verified slice)

- Materia `d04b8e0d6` adds optional additional-selection, selected-text and typed
  edit-intent providers to TextField/TextArea. Owners may consume insertion,
  paste and backward/forward deletion before the widget mutates its document.
  The widget imports the result without replaying an already-applied edit.
  Unhandled operations retain ordinary widget behavior; secondary collapsed
  carets participate in blink scheduling. Full framework and focused delegation
  tests pass `/tmp/uikit-m9-multiselection-final.log`.
- EditorPane renders normalized additional ranges and carets and delegates
  multi-selection edits to TextBuffer's existing transactional model. Clipboard
  text follows document order; matching clipboard lines distribute per range.
  Cut with collapsed carets preserves the clipboard/document. Native movement
  currently falls back to one primary caret; full multi-caret movement and
  physical IME coverage remain pending.
- Real-window reference and self-hosted fixtures pass Unicode replacement,
  backward/forward deletion, cut, transactional undo with restored selection
  sets, asynchronous clipboard distribution and visible selections/carets on
  two rows. Logs: `/tmp/exosuit-m9-multi-final-ui.log`, self-ui.log. Pixel checks
  account for anti-aliased one-pixel carets and adjacent selection rectangles.
- Complete headless suite, graphical build, UIKit workflow, actual Haxeon LSP
  and unpacked release pass `/tmp/exosuit-m9-multi-` tests, build, workflow,
  real-lsp and release logs. Browser targets pass web-reload-final.log.
- Browser reload probes initially reported font/host fetch failures (web.log,
  web-font-probe.log and web-final.log). These occur after typing/save, in the
  reload phase. The smoke test now waits for a changed performance.timeOrigin
  before inspecting fresh-document state and explicitly requires new running
  frames. Network failures and optional HTTP/browser logs are retained. Both
  targets pass this stronger check; no compiler fix or conclusive diagnosis of
  the original fetch failures is claimed. Temporary host diagnostics were removed.
- Release lock pins materia d04b8e0d6. The syntax/decorations and multiple
  selection rendering checklist items are checked; M9.1 remains unfinished
  because strict affected-row invalidation and large-fixture typing budgets
  are not accepted. Next: use real keyboard measurements to localize the
  large-document/long-line bottlenecks, then finish row invalidation and
  multi-caret movement.

### M9.1 — bracket/current-line highlights and glyph layering (verified slice)

- CaretPresentation caches syntax-aware bracket matches by document revision,
  primary caret, selection state and palette. EditorPane paints current-line
  backgrounds before bracket/plugin/search backgrounds, using measured layout
  ranges. Empty lines receive full-width backgrounds; strings/comments do not
  produce bracket matches. Movement and edits invalidate the presentation.
- WholeLineBackground is available in PluginDecorationRegistry; empty ranges
  are permitted for that kind, with reversed/negative ranges rejected.
- The expanded pixel test exposed an existing UIKit stacking error: floating
  backgrounds painted above normal-flow glyphs. Search covered keyword glyphs;
  whole-line backgrounds covered all text and underlines. Materia `2c1193f6`
  separates intrinsic measurement from absolute glyph painting, preserving
  background/selection/glyph/caret ordering. Full UIKit framework passes
  `/tmp/uikit-m9-text-layer-order.log`.
- Headless suite passes `/tmp/exosuit-m9-caret-marks-tests.log`; final focused
  empty/reversed whole-line and caret tests pass
  `/tmp/exosuit-m9-caret-marks-focused.log`. Strengthened real pixel checks pass
  in reference and self-hosted modes (`ui-fixed.log`, `self-ui.log` under
  `/tmp/exosuit-m9-caret-marks-`), requiring visible keyword glyphs above search,
  underlines, bracket clearing and current-line movement onto empty paragraphs.
- Graphical build, both browser targets, real UIKit workflow, real language
  service and unpacked release pass their `/tmp/exosuit-m9-caret-marks-` logs:
  build, web, workflow, real-lsp and release. Release lock pins materia 2c1193f6.
- Next: controlled additional selection/caret painting and owner-delegated
  multi-caret mutations; then affected-row invalidation and typing p95.
  No M9 milestone acceptance box is checked.

### M9.1 — controlled primary caret and selection (verified slice)

- Materia `83e797af` adds UIKit `TextSelection`, preserving anchor/focus direction
  and native affinities. TextField/TextArea optionally import selection from a
  provider and report widget changes after edit callbacks synchronize the owner.
  Unchanged selections do not re-place the caret or reset preferred navigation.
- EditorPane connects this API to its shared BufferSelection. EditorCoordinates
  converts buffer UTF-16 positions to layout codepoints and back, preserving
  emoji, combining marks, line boundaries and the final empty paragraph.
  Model-driven placement and native navigation now share the primary caret.
  Additional selections and multi-caret typing remain pending.
- Full UIKit framework passes `/tmp/uikit-m9-controlled-selection-focused.log`,
  including backward Unicode replacement, callback ordering, keyboard reporting
  and persistence across rebuilds. Complete headless suite passes
  `/tmp/exosuit-m9-controlled-selection-tests.log`; graphical build passes
  `/tmp/exosuit-m9-controlled-selection-build.log`.
- The real EditorPane fixture passes in reference and self-hosted modes:
  `/tmp/exosuit-m9-controlled-selection-ui.log` and self-ui.log. It warms the
  retained widget, imports a backward model selection, extends across emoji,
  replaces text and checks the shared UTF-16 caret. Existing diagnostic/search
  pixel movement and clearing remain green in both modes.
- Both browser targets pass `/tmp/exosuit-m9-controlled-selection-web.log`,
  including actual Unicode edit/save/readback/URL/fresh-reload routes.
- Release lock advances to materia 83e797af; compiler/native pins are unchanged.
  No M9 acceptance box is checked. Next: cache caret-dependent bracket/current-line
  ranges, render them through the measured layout, then add multi-selection
  ownership/rendering and affected-row/typing-budget evidence.

### M9.1 — diagnostic/search presentation and paint revisions (verified slice)

- EditorPane maps plugin-owned decorations and current search matches from
  UTF-16 columns to codepoint ranges for visible chunks. PluginDecorationKind
  preserves existing background defaults and adds wavy underlines. Language
  diagnostics request severity-colored underlines, including one segment for
  each nonempty line of a multiline range; the fingerprint includes severity.
- Cached language diagnostics transform through BufferChange before the next
  server publication, follow undo, and remove deleted nonempty ranges. Existing
  version checks still reject stale server publications. Headless tests cover
  Unicode mapping, offscreen filtering, removal, stale search revisions,
  diagnostic movement and stopped-service clearing. Focused tests pass:
  `/tmp/exosuit-m9-decorations-focused.log`, diagnostics-live and controller logs.
- Added a real-window decoration fixture and pixel check using Xvfb/Pillow,
  wired into composed CI. Initial fresh-window check passed. Strengthening it
  to warm retained text before changing/clearing marks exposed 32 stale red
  underline pixels after clearing (`/tmp/exosuit-m9-decoration-retained-pixels.log`).
  A temporary fixture parse failure was a missing closing brace and was fixed.
- Root cause: retained text painting was keyed solely by measurement/geometry.
  Materia `23397690` adds paint-only invalidation and TextField presentation
  revisions/provider-change detection. EditorPane retains stable provider
  callbacks and advances its revision for text, palette, registry and search
  changes. Display lists remain cached when presentation is unchanged.
- Strengthened real-window pixel checks now pass
  (`/tmp/exosuit-m9-decoration-repaint-pixels.log`): underline and search
  background render, move after a Unicode line insertion, and clear after
  several warm frames. UIKit full framework gate passes
  (`/tmp/uikit-m9-presentation-revision-framework.log`), verifying repaint and
  clearing independently of measurement version/height and unchanged-list reuse.
- Exosuit `6c04c14` commits the editor wiring, model repair, retained pixel
  fixture and composed-CI stage. Complete gates exit 0:
  `/tmp/exosuit-m9-decorations-tests-final.log`, build-verified and
  self-build-verified logs, real-lsp, workflow, release and web logs.
  Both wasm32 and wasm-gc browser smoke routes pass. The strengthened pixel
  fixture also passes self-hosted (`/tmp/exosuit-m9-decoration-self-pixels.log`).
  Release lock pins materia 23397690; Haxeon/NativeKit revisions are unchanged.
- No M9 acceptance box is checked; bracket/current-line, shared multi-selections,
  affected-row invalidation and typing-budget measurements remain pending.

### M9.1 — editor syntax and incremental initializer adapters (verified slice)

- EditorPane now requests visible syntax foreground ranges and uses the core
  editor palette for text, gutter and background. SyntaxPresentation maps the
  existing highlighter's UTF-16 tokens to absolute codepoint ranges, clips to
  requested chunks and omits normal tokens. Focused tests cover accents/emoji,
  clipping and multiline state repair after edits. The tokenizer now keeps
  operator-token boundaries outside surrogate pairs (astral characters outside
  strings previously split into invalid codepoint boundaries).
- Full headless gate exits 0 (`/tmp/exosuit-m9-syntax-tests.log`). Final reference
  and self-hosted graphical builds both exit 0 (the corresponding
  `/tmp/exosuit-m9-syntax-*-build-final.log` files).
- Desktop workflow rebuild failed before launching: cached compilation pruned
  `$function-adapter-env:nativekit.ui.style.StyleProperty.__init:0`, causing IR
  verification failure in `__init$part5`. Original failure log:
  `/tmp/exosuit-m9-syntax-desktop.log`. No desktop/release/browser success is
  claimed for this slice yet.
- Reduced to separate Values/Main modules: a static generic comparator passes
  cold, then a consumer-only edit fails with missing Values.__init adapter.
  Root cause: generated-function retention recognizes ordinary function origins
  but not initializer pseudo-bodies. Haxeon `a3b26edb` resolves initializer
  retention and invalidation through the owning class constructor, using
  existing ownership rules. Focused execution passes consumer edits, initializer
  replacement/restoration and existing invalid callable rejection cases.
  Compiler gate exits 0, 383/383 plus all integration/Wasm stages:
  `/tmp/haxeon-m9-static-adapter-gate.log`. Bootstrap converges after one
  self-host stage and rebuilds identically (the corresponding bootstrap logs).
- The repaired repeated desktop build passed, then plugin-driven editing
  exposed stale shared text during syntax painting. Widget replay globally
  disabled buffer-to-document mirroring while notifying subscribers; a nested
  plugin edit therefore updated buffer lines but not the shared TextDocument.
  A failing headless reducer confirms it (`/tmp/exosuit-m9-nested-edit-before.log`).
  Exosuit `18597b1` replaces mutable global suppression with an operation-local
  mirror argument, preserving nested edits. Focused document test exits 0
  (`/tmp/exosuit-m9-nested-edit-final.log`); full headless gate exits 0
  (`/tmp/exosuit-m9-syntax-tests-final.log`). Initial focused run used a relative
  fixture argument and failed file lookup; rerun uses the required absolute path.
- Desktop edit/save/plugin-reload and unpacked release gates pass after the
  repair (`/tmp/exosuit-m9-syntax-desktop-final.log` and release log). Both
  browser targets pass (`/tmp/exosuit-m9-syntax-web.log`). Captured pixels show
  actual syntax colors but exposed a light text-field background and fit-height
  tabs. Added explicit editor background and grow-height editor tabs; final
  palette gates all exit 0:
  `/tmp/exosuit-m9-syntax-palette.log`, `-self.log`, `-release.log`, `-web.log`.
  Both wasm32 and wasm-gc smoke routes pass. Inspected final desktop output
  frame: readable colored tokens, configured dark background, full-height pane.
  Release lock now pins Haxeon a3b26edb and materia 267bfa07.
- No M9 acceptance boxes are checked. Strict affected-row invalidation and
  p95 typing measurements remain pending. Cached highlighter state can require
  scanning preceding unvalidated lines; native retained chunks contain up to
  64 paragraphs. Next: wire diagnostics/search/bracket/current-line decorations
  and shared normalized selections/carets into the editor, with edit repair and
  clearing regressions, then affected-row invalidation and typing measurements.

### M9.1 — geometry decorations and missing-glyph carets (in progress)

- Added geometry-based background, whole-line background, straight and wavy
  underline capabilities. Background nodes precede selections; wavy paths clip
  to the horizontal viewport and decoration providers query visible chunks.
- Initial E1007 was an application flow error: an impure callback could replace
  the mutable nullable provider between loop iterations. Existing LoopFlowMain
  requires invalidating such field facts. Each paint layer now retains one
  provider for its entire pass; a regression replaces the field during the pass
  and verifies all three chunks still use that retained provider. No typing rule
  or application cast changed. Also corrected an absent overlay-style helper.
- Unicode geometry initially failed at an unsupported emoji: caret offset 3
  returned x=0, while neighboring carets were x=17.824 and x=25.872. The fixture
  loaded only IBM Plex Sans. Adding bundled NotoEmoji with FontFamily.Emoji
  makes the focused decoration test and complete framework gate pass:
  `/tmp/uikit-decorations-emoji-family.log` (0). Loading emoji as Default was
  insufficient because the shaping library requests the Emoji family.
- Missing-glyph caret behavior is a real independent native issue, now covered
  by a failing UIKit text-engine regression. Skribidi found style metadata but
  no caret position and skipped its nearest-run fallback. Its clean baseline
  is `7c31390` on nativekit-atlas-api; created exosuit-followon before the fix.
  Running the existing run-boundary fallback alone still failed when one run
  spanned the missing character. The fix retains the nearest canonical insertion
  position from the existing caret iterator, while preserving known style data.
  Skribidi `76a337e` includes its own unsupported-emoji regression; the complete
  `skribidi_test` suite exits 0 (`/tmp/skribidi-caret-tests.log`). Materia
  `254d2dbc` pins it and adds the UIKit regression. Four native checks pass:
  text_engine, compositor, frame_resources and layout_render_compiler.
  No baseline vendor edits existed.
- Materia `267bfa07` commits the decoration API and focused Unicode geometry,
  all four paint kinds, edit movement and provider snapshot coverage. Full
  framework gate exits 0 (`/tmp/uikit-decorations-caret-final.log`).
- Editor syntax wiring is in progress. The headless focused editor-view test
  passes (`/tmp/exosuit-m9-syntax-focused.log`), including UTF-16/codepoint
  conversion, visible clipping and multiline state invalidation after edits.
  The syntax slice and final native/browser gates are recorded above.

### M9.1 — TextArea presentation (in progress)

- Next design: a typed foreground provider receives each visible retained chunk's
  absolute codepoint range. This bounds syntax work to visible chunks and keeps
  provider results local; unchanged colors reuse native resource revisions.
  Backgrounds and underlines will reuse existing measured range rectangles.
- Materia `cfe3e241` adds the visible foreground provider to TextField/TextArea
  and retained editor layouts. Values clip to local codepoint ranges, unchanged
  colors avoid native updates, reshaped chunks reapply styles. Single-line fields
  retain styled content when a provider is set and keep placeholder behavior.
- Framework gate exits 0: `/tmp/uikit-text-area-colors-framework-final.log`.
  Coverage uses a 150-line accent/emoji fixture, verifies only the visible chunk
  requests colors, clipping and recoloring preserve measurement, overlap rejects
  and clearing works. Existing 4,000-node/input regressions pass.
- Both graphical compiler-mode builds exit 0:
  `/tmp/exosuit-m9-text-area-colors-build.log` and
  `/tmp/exosuit-m9-text-area-colors-self-build.log`. No compiler change.
- Exact next action: add background/underline/whole-line geometry decorations,
  then wire syntax/diagnostics into EditorPane and rerun both browser targets.
  Native retained layouts still group up to 64 paragraphs; strict changed-row
  invalidation and M7.1 measurements remain acceptance work, not a claimed pass.


### M9.1 — public foreground ranges and raster invalidation (foundation delivered)

- General C ABI `nkui_text_layout_set_color_ranges` copies sorted, disjoint
  codepoint ranges and rejects invalid colors, bounds, handles and overlap
  transactionally. Empty ranges clear; text/layout updates clear; base-color
  changes preserve overrides. ABI version 8 and both portable HXI regenerated.
- Typed `TextColorRange`/`TextLayout.setColorRanges` uses the existing native
  struct-array boundary. Mutable scaled glyphs and owned immutable snapshots
  both receive foreground ranges. Identical colors do not invalidate resources.
- A new actual pixel recolor test initially failed (red=0, stale green=36).
  Root cause: mutable retained text had no color revision in raster resource
  fingerprints. A text content revision now participates in both renderer
  bindings and advances on text/layout or color changes. The regression verifies
  green override plus blue base, cached repaint, live red recolor and range
  clearing on text replacement. No compiler workaround was needed.
- Native focused gate passes 6/6, including ABI, text engine, compositor,
  frame resources, layout render compiler and real Xvfb pixel rendering.
  `../uikit/tools/test-haxeon.sh` exits 0: actual typed array marshaling,
  rendered Canvas transaction, invalid overlap, unchanged measurement and
  Settings suite (`/tmp/uikit-color-ranges-haxeon.log`).
- Materia `f4313d4b` commits this public API slice. Exosuit root tests and both
  graphical compiler-mode builds exit 0, serially:
  `/tmp/exosuit-m9-color-ranges-tests.log`,
  `/tmp/exosuit-m9-color-ranges-build.log`,
  `/tmp/exosuit-m9-color-ranges-self-build.log`.
- Final `EXOSUIT_CI_WEB=1 ./scripts/test-web.sh` exits 0 for both guest targets
  with 107/104 matching imports and real Unicode edit/save/URL/fresh reload:
  `/tmp/exosuit-m9-color-ranges-web-final.log`. The first attempt failed once
  at reload with a guest frame error; its assertion omitted console details.
  Added console capture to failure assertions. Same linear artifact then passed
  the diagnostic run plus five fresh browser repetitions. That first transient's
  root cause remains unclassified; it is not silently treated as a passing run.
- Updated release pin to materia `f4313d4b`; new unpacked-release acceptance
  remains pending until the editor presentation slice. Exact next action:
  add visible retained foreground ranges and geometry-based decorations to
  UIKit TextArea, then wire the editor's syntax/diagnostics and selections.

### M9.1 — retained foreground ranges (in progress)

- Starting from accepted M15 commit `5a46f5c`, with materia `a9486f67`,
  Haxeon `02f924ed` and NativeKit `d12dd484`. Existing submodule-pointer dirt
  and Haxeon vendor/profile files remain outside this slice.
- Design: retain logical codepoint cluster ranges alongside prepared glyph quads.
  Sorted, disjoint foreground ranges recolor cached geometry using the cluster's
  first codepoint (a shaped ligature remains one color). Published snapshots
  include colors in their cache identity and remain immutable. Color changes
  must neither rebuild measured layouts nor rasterize glyphs. Line snapshots
  ignore ranges outside their logical line, preserving unaffected-row reuse.
- Materia `59cb6eaf` delivers the internal foreground-range foundation. Native
  tests cover geometry, clearing, immutable snapshots, unchanged-row cache reuse,
  rejected overlapping/reversed/negative ranges and codepoint metadata for
  accent, supplementary and RTL text.
- `cmake --build ../nativekit/build-ui --target
  nativekit_ui_text_engine_test nativekit_ui_frame_resources_test
  nativekit_ui_layout_render_compiler_test nativekit_ui_compositor_test -j 4`
  exits 0 (targets built serially in the same tree). Corresponding focused
  `ctest --test-dir ../nativekit/build-ui` selection passes 4/4; diff check passes.
  An initial test compile caught a duplicate local name; corrected before gates.
- Exact next action: expose foreground ranges through the C ABI and typed
  UIKit TextLayout/TextArea APIs, including mutable and owned renderer paths.
  Background/underline/whole-line, editor wiring and acceptance remain pending.


### M15.1–M15.3 — browser editor and composed acceptance (accepted)

- The shared UIKit editor now runs through BrowserUiHost with bundled fonts,
  seeded session MemoryFS and native window.open URL handling. Typed host
  services isolate file dialogs and source-plugin compilation. Injected plugin
  loaders initialize through their actual service instance; missing browser
  processes/LSP/build/plugins/terminal/control capabilities omit those commands.
- `web/build.sh` reuses materia `tools/web`, derives the source graph from its
  manifest, generates portable ABI HXI and a checked memory contract, builds the
  guest and Emscripten host, audits import signatures and assembles the site.
  Compile failures propagate; artifact trees are separate per target. All runtime
  export lists include ccall/addFunction/removeFunction consistently.
- `web/test.sh` drives real Chrome keyboard and pointer input, accent/emoji and
  ordinary characters, Enter, Ctrl-S/save/readback, dirty transitions, URL opening
  and fresh-session reload. It rejects console, exception and page/network errors.
  Bounded model/focus waits report actual failure state. Disposable browser process
  groups retire before profile cleanup. Edited/fresh screenshots are optional.
- `EXOSUIT_CI_WEB=1 ./scripts/test-web.sh` exits 0 on both targets:
  `/tmp/exosuit-web-final-ci.log`. Wasm32 has 107 imports and GC has 104;
  all host-bound signatures match and unavailable imports are empty. This stage
  joins `scripts/ci.sh`. Unselected or missing-Emscripten/Chrome branches print
  PENDING and were independently checked. GUI qualification is Chrome/SwiftShader
  on Linux; other browsers and platforms are unclaimed.
- Final desktop gates exit 0 at the release pins:
  `/tmp/exosuit-web-final-reference-tests.log`,
  `/tmp/exosuit-web-final-reference-build.log`,
  `/tmp/exosuit-web-final-self-tests.log`,
  `/tmp/exosuit-web-final-self-build.log`,
  `/tmp/exosuit-web-final-release.log`. Mandatory source plugins and unpacked real
  LSP remain passing. Real UIKit project/edit/save/palette/Problems/BuildOutput and
  live source-plugin reload passed in `/tmp/exosuit-web-accepted-desktop-window.log`.
  Edited browser screenshot `/tmp/exosuit-web-final-gc-edited.png` was inspected;
  it displays the saved accent/emoji text and a clean fresh line.
- Haxeon `02f924ed` copies borrowed C UTF-8 results into managed linear strings,
  preserves null on both targets and declares GC linear memory for result-only
  string imports. The registered ABI fixture verifies Unicode operations and
  survival after native storage is overwritten. It failed before the fix and
  passes both targets afterward. This resolves the actual linear browser
  `NativeKitError.messageFor` error-path crash without hiding platform errors.
- Compiler gate `/tmp/haxeon-gate-utf8-results-final.log` exits 0 with 383/383 and
  all integration/Wasm stages. Bootstrap converges in one stage and self-bootstrap
  is identical (both 0): `/tmp/haxeon-bootstrap-utf8-results-final.log` and
  `/tmp/haxeon-bootstrap-self-utf8-results-final.log`. The initial missing-helper
  lookup was an owned implementation error; the required nullable guard corrected
  it before committing. No typing workaround or diagnostics suppression added.
- Release pins: Haxeon `02f924ed`, materia `a9486f67`, NativeKit `d12dd484`,
  deliberately preserved HashLink vendor `40a4782`. Shared materia web tooling is
  `a656e9b7`; UIKit surface routing is `a9486f67`; NativeKit runtime callback exports
  are `708ac89e`, focused-input keys `97938edb`, pointer capture `d12dd484`.
  Haxeon prerequisite fixes are `14a02e0e` (terminated assignments), `35bd627d`
  (optional interfaces), `6a86c528` (callable ABI/initializer ownership),
  `642863b4` (UTF-16 string coordinates) and `02f924ed` (borrowed UTF-8 results).
- Pre-existing vendor gitlink/profile dump and parent submodule dirt are preserved.
  No pushes or publication. M15 checkboxes are accepted; continue directly with
  M9.1 rather than stopping at this milestone.


### M15.2 — UTF-16 string coordinates and browser pointer capture (verified slices)

- Haxeon `642863b4` keeps UTF-8 storage and ABI transfer while making length,
  charCodeAt, charAt and substring use UTF-16 coordinates on both Wasm targets.
  Selected surrogate halves survive through WTF-8. Internal byte slicing for
  split/case conversion remains byte based. EReg/Regex match positions now use
  UTF-16 and scalar iteration handles surrogate pairs consistently.
- The formerly skipped `string-utf16-length` fixture passes on both targets and
  is required. Registered `string-utf16-slices` covers Bytes roundtrip, BMP and
  astral text, individual surrogate halves, negative/outside charAt, clamping
  and empty slices. Reference Haxe/HashLink returns 42. Regex coverage includes
  whole-emoji matching, UTF-16 match ranges and terminating zero-width replacement.
- Full gate exits 0 with 383/383 and all integration/Wasm stages:
  `/tmp/haxeon-gate-utf16-slices-final.log`. Bootstrap converges in one stage and
  self-bootstrap is identical (both 0): `/tmp/haxeon-bootstrap-utf16.log` and
  `/tmp/haxeon-bootstrap-self-utf16.log`.
- NativeKit `d12dd484` uses DOM pointer capture for ordinary interaction rather
  than deferred relative pointer lock. A missing active pointer returns the
  declared unsupported result without changing mode. Its browser integration
  gate passes all four pages: `/tmp/nativekit-web-capture-gate.log` (0).
- Actual GC browser Unicode editing/save/URL/reload passes with no errors:
  `/tmp/exosuit-web-gc-pointer-capture-window.log` (0). Screenshot inspected:
  `/tmp/exosuit-web-gc-pointer-capture.png` shows the editor, project and Problems.
  Linear smoke passed standalone in `/tmp/exosuit-web-linear-selection-probe.log`,
  but composed CI remains red; no M15 acceptance is claimed.
- Composed failure is now reduced to a native UTF-8 result being treated as a
  managed string in linear Wasm. `/tmp/exosuit-web-ci-utf16-final.log` fails
  after pointer input in `__string_length` via `NativeKitError.messageFor`.
  New registered Wasm backend regression `tests/ffi/wasm-utf8-result.hx` fails
  before correction (exit 1 instead of 42), then passes both targets with owned
  uncommitted interop fixes. It verifies UTF-16 use, null preservation and native
  storage mutation after a result was returned. The GC-only reduction also
  revealed a missing memory declaration for result-only C string imports.
- Pending exact action: finish full gate/bootstrap for the borrowed UTF-8 result
  correction, run the actual opt-in browser CI stage on both targets and commit
  the verified compiler and browser slices. Current sessions: compiler gate in
  `/tmp/haxeon-gate-utf8-results.log`, browser CI in
  `/tmp/exosuit-web-ci-managed-utf8.log`. Browser smoke uses bounded state waits;
  do not mask page errors or count an earlier standalone pass as composed CI.
- Desktop requalification at `642863b4` passed reference and actual self-hosted
  tests/builds, real UIKit window/plugin reload and unpacked release:
  `/tmp/exosuit-web-accepted-{reference,self}-{tests,build}.log`,
  `/tmp/exosuit-web-accepted-desktop-window.log`,
  `/tmp/exosuit-web-accepted-release.log` (all 0). Later interop changes still
  require final pins and relevant requalification.

### M15.2 — generic callable ABI and initializer ownership (verified compiler slice)

- Haxeon `6a86c528` adapts callable argument/result signatures at generic
  semantic/physical boundaries, including nested callables. Nullable callbacks
  evaluate once and preserve null. Generated adapters in initializer pseudo-bodies
  now reuse the declaring class's module ownership rule.
- Independent registered `generic-callable-abi` execution covers nominal,
  integer, float and higher-order storage, assignment, null fallback, evaluation
  count and static initialization. Registered compiler coverage checks execution,
  incremental body edits/restoration and cold/incremental incompatible callbacks.
  Static initialization failed before the ownership change with
  `No source module owns typed function "$function-adapter:Functions.__init:0"`;
  focused execution passes afterward.
- `../haxeon/scripts/test.sh` exits 0, including formatting, runtime/compiler,
  integrations and Wasm parity/Wasmtime stages:
  `/tmp/haxeon-gate-generic-callable.log`. Bootstrap converges in one stage and
  self-bootstrap is identical (both exit 0):
  `/tmp/haxeon-bootstrap-generic-callable.log` and
  `/tmp/haxeon-bootstrap-self-generic-callable.log`.
- Actual Wasm GC editor builds with 104 matching imports:
  `/tmp/exosuit-web-gc-initializer-fixed-build.log` (0). ASCII browser typing,
  ordinary character input, Enter, dirty tracking, Ctrl-S/save/readback, native
  URL opening and fresh-session reload pass:
  `/tmp/exosuit-web-gc-callback-ascii-final.log` (0). Disposable Chrome process
  groups prevent child processes racing profile cleanup.
- Toolkit fixes already verified and committed separately: materia `a9486f67`
  routes transactional text by surface; NativeKit `97938edb` forwards focused
  hidden-input shortcuts while retaining DOM text/composition delivery. NativeKit's
  four browser integration pages passed in
  `/tmp/nativekit-web-key-routing-gate.log` (0).
- Full Unicode smoke remains red (`/tmp/exosuit-web-gc-unicode-probe.log`);
  source/test changes under `web/` remain uncommitted until acceptance passes.
  M15 is not accepted. Existing vendor gitlink/profile dump and parent submodule
  dirt remain preserved. No publication performed.


### M15.1/M15.2 — typed host services and optional interfaces (verified slice)

- The editor shell now accepts shared UiHostContext and an optional typed
  HostFileDialogs service; GraphicalMain supplies NativeDesktopServices explicitly.
  Hosts without dialogs use the existing path command view. Source compilation
  sits behind SourcePluginLoader/NativeSourcePluginLoader; browser graph excludes
  the embedded compiler and desktop loader, while existing plugin APIs remain.
- Haxeon `35bd627d` preserves optional interface parameters in canonicalization
  and uses shared TypeRepresentation to publish their nullable physical signature.
  Reduced Service.value(required:Int, ?suffix:String) previously rejected an
  omitted suffix. Registered cold/incremental positive and rejection coverage
  plus inherited/numeric optional runtime cases pass. Full gate: 380/380,
  every integration and 247 Wasm parity fixtures (12 existing skips); both
  bootstrap commands exit 0 and self-bootstrap is identical.
  Logs /tmp/haxeon-gate-interface-optional.log and
  /tmp/haxeon-bootstrap[-self]-interface-optional.log.
- NativeKit `708ac89e` makes its transitive Emscripten runtime exports configurable.
  Its hard-coded ccall export list previously replaced the consumer's callback
  exports. Matched host ABI checker and actual Chrome rendering now pass with
  ccall/addFunction/removeFunction. NativeKit's original off-pin commit/branch
  remains preserved; changes are on exosuit-followon.
- Both complete editor test/build modes exit 0 on the final service boundary:
  /tmp/exosuit-browser-final-boundary-{reference,self}-{tests,build}.log.
  Real UIKit/plugin reload and standalone release also exit 0:
  /tmp/exosuit-browser-boundary-desktop-window.log and
  /tmp/exosuit-browser-boundary-release.log.
- Browser startup/rendering passes with no unavailable imports, but input smoke
  remains red. NativeKit TextEdit events arrive with a surface handle; UIKit's
  NativeInputAdapter wrongly filters them against the window handle. Fix the
  general routing rule in materia/uikit with distinct-handle regression, then
  rerun browser typing/save/readback/reload on both guest targets. Browser files
  remain experimental and are not accepted yet.


### M15.2 — terminating assignment lowering (verified compiler slice)

- Haxeon `14a02e0e` fixes CFG lowering after a throw-valued assignment.
  Abstract constructor `this = throw "expected"` reduced the guest failure.
  Local/captured/field/static/array/map assignments and variable initialization
  now preserve the throw without emitting an unreachable store. Operand
  evaluation stops when an earlier operand terminates.
- Registered terminated-assignment executes all eight forms and verifies
  unchanged destinations; local reference Haxe/HL exits 42 on the same behavior.
  Full gate exits 0: 378/378, every integration, 246 Wasm parity fixtures with
  12 existing skips, Wasmtime. Bootstrap converges and --self rebuilds identically.
  Logs: /tmp/haxeon-gate-terminated-assignment.log,
  /tmp/haxeon-bootstrap-terminated-assignment.log,
  /tmp/haxeon-bootstrap-self-terminated-assignment.log.
- Guest CFG now succeeds, exposing embedded compiler runtime imports unsupported
  on Wasm. Browser graph work isolates desktop source-plugin implementations.
  Shared UiHostContext and optional typed file-dialog service are in progress.
  The new service also reduced an existing interface optional-argument metadata
  loss to an independent fixture; its fix and qualification are pending.


### M15.2 — shared browser pipeline tools (verified slice)

- Materia `a656e9b7` factors manifest guest arguments, portable Wasm HXI
  generation and host import signature checking into `tools/web`. The reference
  app keeps compatibility entry points and owns its toolkit generator list.
- Before/after generated HXI files and manifest arguments compare identically
  (`/tmp/materia-web-tools-before.log`, `/tmp/materia-web-tools-after.log`).
  Shared and compatibility import checkers give identical results for matching
  and deliberately mismatched Wasm ABI fixtures (exit 0 and 1 respectively).
  Shell syntax, Node syntax and Python compilation checks pass.
- Materia is on `exosuit-followon`; its pre-existing Haxeon/NativeKit gitlink
  changes and untracked exosuit remain untouched. Release pin now includes
  the shared tools. Browser entry/build experiments remain uncommitted.
- First actual 988-source browser guest exposed a general CFG lowering crash:
  generated unsupported UTF-8 callback constructor assigns a throw expression
  to abstract `this`. Reduced independently to `this = throw "expected"`.
  Fix and runtime regressions are underway in Haxeon; browser acceptance remains
  pending. Resume with that compiler gate, then qualify the guest and native host.


### M15.1 — typed host capability policy (verified slice)

- M8 composed CI restoration committed as exosuit 84c2dac. This slice adds an
  immutable typed HostCapability/HostCapabilities query (clipboard, filesystem,
  processes, threads, IPC, terminal, language services, URL, source plugins).
  Desktop advertises delivered services; IPC/terminal remain false until their
  milestones. Browser policy enables session filesystem/URL with optional
  clipboard and omits process/thread/source-plugin services.
- Application passes policy to controllers. Unavailable build/LSP/source-plugin
  commands are absent; clipboard commands and bindings are omitted. Process
  start is guarded before native allocation; deliberate direct controller calls
  return false with visible feedback. Restricted plugin managers do not install
  the host callback. UIKit omits Build Output when processes are unavailable.
- Host-capabilities test proves editing/undo, immutable constructor ownership,
  service prerequisites, absent commands, clear feedback and no owned child or
  plugin resources. Registered in test.sh with disposable portable state.
- Both ./scripts/test.sh and ./scripts/build.sh pass in reference and explicit
  self-hosted modes after these changes; graphical builds compile 987 sources.
  Logs /tmp/exosuit-test-capabilities-reference.log,
  /tmp/exosuit-build-capabilities-reference.log,
  /tmp/exosuit-test-capabilities-self.log,
  /tmp/exosuit-build-capabilities-self.log. Focused original test exits 0:
  /tmp/exosuit-capabilities-focused-fixed.log.
- Actual LSP, UIKit edit/task/plugin-reload route and unpacked release all exit 0:
  /tmp/exosuit-capabilities-real-lsp.log, /tmp/exosuit-capabilities-window.log,
  /tmp/exosuit-capabilities-release.log. Package pins the compiler correction
  below. Diff and shell syntax checks pass; no sibling dirt was staged.
- Browser guest/native host do not exist yet; no browser execution is claimed.
  Continue M15.2 using the shared pipeline, qualifying M15.1's import boundary.

### M15.1 compiler issue — array enum lookup context and representation

- Haxeon 39c27f9a fixes Array.indexOf/contains argument typing: supply the known
  element type just as push/remove do. The unmodified capability query passed
  local reference Haxe, while the independent reducer failed E1005 before the
  correction (/tmp/haxeon-array-lookup-before.log). Runtime probing then exposed
  separately allocated nullary constructors being missed by reference lookup.
- Shared IR lowering scans nullary enum variants by constructor index, retaining
  reference lookup for payload constructors and null. It preserves first-match
  order and nullable arrays, and uses the same CFG on native/Wasm backends.
  Reference Haxe/HL confirms distinct Value(7) instances do not match, but a
  retained instance does. No permissive assignability or application rewrite.
- Registered ArrayLookupContextMain covers contextual bare constructors,
  conflicting imports, unrelated enum rejection, cold/incremental builds and
  restoration. Registered array-enum-lookup covers duplicate nullary instances,
  payload identity, nulls, empty arrays and actual execution.
- Full compiler gate exits 0: 377/377 and all native/C++/integration stages;
  245 Wasm parity fixtures (12 pre-existing skips), Wasmtime. Bootstrap converges
  after one stage and --self rebuilds identically; refreshed artifacts committed.
  Logs /tmp/haxeon-gate-array-enum-lookup.log,
  /tmp/haxeon-bootstrap-array-enum-lookup.log,
  /tmp/haxeon-bootstrap-self-array-enum-lookup.log. Original editor capability
  test and both complete editor mode gates pass after the fix.


### M8.3 — restored composed CI (accepted)

- Real native-input slice committed as exosuit b76554b. scripts/ci.sh now runs
  the compiler gate, all headless projects, graphical build, real LSP smoke,
  real UIKit workflow and unpacked release serially. Package creation explicitly
  rejects unsupported host architectures. Workflow also asserts the task exit
  status is shown, so a partial output drain cannot satisfy the check.
- ./scripts/ci.sh exits 0; log /tmp/exosuit-ci-restored.log. Compiler/runtime
  tests and all native/C++/Wasm/Wasmtime integration stages exit 0, followed by
  every editor project and the actual LSP/window/unpacked-artifact routes.
  Expected failure fixtures in the compiler's test-framework checks are their
  own passing negative tests, not unresolved failures.
- HAXEON_SELF_HOSTED=1 ./scripts/build.sh exits 0 after the graphical CLI and
  diagnostics changes; 984 sources. Log /tmp/exosuit-m8-final-self-build.log.
  Earlier full headless self-hosted acceptance at 95a3b08 still applies: no
  headless application source changed in these window/release slices.
- Shell syntax and diff checks pass. Haxeon retains only initial vendor/hashlink
  pointer modification and hlprofile.dump; NativeKit and materia dirty/off-pin
  states are preserved. No publishing. M8.1–M8.4 accepted for the stated Linux
  automated scope. Physical IME/DPI and non-Linux remain pending.
- Continue M15.1 next; the goal still covers every follow-on milestone.


### M8.3 — native input and source-plugin reload (verified slice)

- Release slice committed as exosuit 011ea4d. The real-window workflow now uses
  Xvfb/xdotool against built bytecode and matched native libraries. It opens a
  project and file, edits/saves through TextArea, uses the command palette and
  task picker, observes task diagnostics in Problems, and inspects Build Output
  after a second host launch. Plugin reload recompiles a callback whose changed
  body inserts a marker; the saved marker proves execution of the new guest body.
- Graphical CLI accepts multiple paths (project then file), timed captures and
  native event recording using existing host capabilities. Recording mode emits
  and flushes readiness; captures include application errors and loaded plugins.
- UIKIT_WORKFLOW_ARTIFACTS=/tmp/exosuit-uikit-workflow-queries
  ./scripts/test-uikit-workflow.sh exits 0. Log uses the same path with .log.
  Both captures contain Main.hx, the loaded plugin and no application errors;
  event traces have actual native text input and no host failures. Saved text
  contains return 42 and the reloaded callback marker. Visually inspected the
  real Build Output screenshot. Shell syntax and diff checks pass.
- Early disposable probe failures: Sys.println is outside the source-plugin
  API; document subscriptions require an active document. Corrected fixtures
  use the supported editor API and open a document before activation. The CLI
  runner buffers forwarded child output, so the native-input driver launches
  the built artifact directly. Palette search persists between opens; the test
  selects/replaces the search query just as a user would. No typing evasion.
- Project build tasks and release/getting-started documentation now describe
  actual UIKit commands and dependencies; SDL measurements are historical.
- Pending: composed CI and self-hosted build after CLI changes. IME, physical
  DPI transitions and non-Linux checks remain unclaimed. Next ready task after
  accepted M8 is M15.1 capability boundaries.


### M8.3 — standalone UIKit release (verified slice)

- Replaced SDL/Pragtical packaging with manifest output, ordinary C libraries,
  Haxeon runtime and matching VM built from vendor/hashlink. release.lock pins
  Haxeon 82d92ba0, NativeKit 2bb4c957, materia 816372dd (UIKit/EditorKit), and
  HashLink 40a4782b. Preserved initial sibling dirty paths and off-pin state.
- Standalone launchers resolve libraries and the bundled LSP relative to the
  installation, preserving the caller's working directory/file arguments.
  Staged ELF runpaths use $ORIGIN; original build artifacts are untouched.
  UIKit uses system Fontconfig fonts; removed obsolete bundled-font defaults.
  Native dependency notices and standard library accompany the archive.
- ./scripts/test-release.sh exits 0, log /tmp/exosuit-release-uikit.log:
  unpacked archive renders/captures outside the source tree using disposable
  portable state; ELF search paths contain no source directories; bundled LSP
  diagnoses/fixes/saves the edited source, then CLI build/run returns 42.
  Shell syntax and git diff --check pass. An initial attempt exposed the native
  build wrapper's cwd requirement; package invocation now enters Haxeon first.
- Pending: scripted native input route and composed CI; M8 remains in progress.


### M8.3 — manifest-based real language service (verified slice)

- Exosuit `485303f` replaces removed realtime-haxe/haxeon-compile invocations
  with a real smoke-test package and CLI build/run. The client starts the actual
  Haxeon server, edits valid code into an invalid return, observes a diagnostic,
  fixes and clears it, saves through Document.save, then independently builds
  the saved package and executes it to return 42. Initial disk code returns 1,
  so success proves the changed document was saved.
- `./scripts/test-haxeon-lsp.sh` and
  `HAXEON_SELF_HOSTED=1 ./scripts/test-haxeon-lsp.sh` exit 0. Logs:
  `/tmp/exosuit-real-lsp-manifest.log`,
  `/tmp/exosuit-real-lsp-manifest-self.log`. Shell syntax and diff checks pass.
  External-server override is retained for unpacked release qualification.
- Inspected existing DesktopUiHost options: native capture, frame limits,
  event recording and app diagnostic snapshots are already available; no
  framework hook was added. `xvfb-run -a ./scripts/run.sh --capture-dir=...`
  with three frames and a disposable Main.hx exits 0, produces a real window
  capture/tree/events/app state, and visually shows the file and live shell.
  Log `/tmp/exosuit-uikit-window-smoke.log`, artifacts
  `/tmp/exosuit-m8-window-capture`. This first capture inherited existing
  session tabs; all further GUI checks must set PRAGTICAL_PORTABLE to a
  disposable state directory. No existing document was edited.
- Basic window rendering is verified; scripted edit/save/palette/problems/
  build/reload acceptance remains pending. Next: isolate portable state and
  drive real native inputs with xdotool, then restore pinned packaging/CI.

### M8.1/M8.2 — reflection copies and mandatory source plugins (accepted)

- Haxeon `82d92ba0` fixes the reduced Reflect.copy representation failure.
  Native reflection clones typed object layouts without constructors, preserves
  declared null field types and shallow references, and retires interface-cache
  slots. Existing HashLink dynamic/virtual copying is reused. Wasm generates
  per-layout shallow copying through ObjectReflection; dynamic objects retain
  their explicit field-copy path. No assignability weakening, editor special
  cases or test skips were introduced.
- Before-fix typed-record reducer exited 1 with the same dynobj cast failure.
  A stock HashLink copy was insufficient for object-backed records, and copying
  to dynobj still lost nominal layout; the final adapter preserves the layout.
  The local reference Haxe record test exits 42. New native/Wasm regressions
  cover nullable fields, copy independence, shallow arrays, null input,
  inherited class fields, constructor counts and interface dispatch. The
  embedding test now recompiles a method body on a worker with publication
  tracking, exercising the semantic body-reuse path.
- The first full reflection gate failed both Wasm backends on the new test
  (`/tmp/haxeon-gate-reflect-copy.log`, exit 1). The general Wasm helper fixes
  both: focused parity exits 0 with 244 fixtures/12 pre-existing skips; final
  full gate exits 0, 375/375 plus every integration/native/C++/Wasm/Wasmtime
  stage (`/tmp/haxeon-gate-reflect-copy-complete.log`). Both bootstrap commands
  exit 0, converge after one stage and rebuild identically; logs
  `/tmp/haxeon-bootstrap-reflect-copy-complete.log` and
  `/tmp/haxeon-bootstrap-self-reflect-copy-complete.log`. Stdlib formatting
  checked explicitly. Temporary compiler stack logging and reducer files are
  removed. Pre-existing dirty Haxeon paths remain untouched.
- Exosuit `95a3b08` restores threaded source compilation, publication,
  compatible patching, structural reload/state transfer, rollback and unload
  handling. It registers compiler intrinsics and PluginHost HXI. SDK host
  callbacks return checked success/error responses; Unicode errors can be
  caught inside plugin code. Initialization reinstalls managed callbacks after
  shutdown, and retired tokens are rejected. Unexpected compiler failures keep
  exception stacks in plugin diagnostics.
- Acceptance extends the disposable fixture with Unicode host-error catching
  and checks shutdown/reinstall/retired-token handling. The full existing
  compatible/structural reload, source failure, activation rollback, state
  version and unload-race test is mandatory again; suppression is removed.
- Serialized `./scripts/build.sh`, `HAXEON_SELF_HOSTED=1 ./scripts/build.sh`,
  `./scripts/test.sh`, `HAXEON_SELF_HOSTED=1 ./scripts/test.sh` all exit 0.
  Graphical builds compile 984 sources; every headless project, including
  dynamic plugins, passes. Logs:
  `/tmp/exosuit-build-plugin-restored-reference.log`,
  `/tmp/exosuit-build-plugin-restored-self.log`,
  `/tmp/exosuit-test-plugin-restored-reference.log`,
  `/tmp/exosuit-test-plugin-restored-self.log`.
- CommandView's defect has dedicated effect regressions. The historical
  ConfigurationController/SelectOption claims no longer reproduce in the
  updated source/compiler; bootstrap refresh and actual two-mode UIKit builds
  establish resolution without invented reducers. README/ADR reflect current
  implementation; plugin docs use the actual API version 2. Interactive GUI,
  release and real-server integration are still pending in M8.3.

### M8.1 — reusable compiler/runtime package (verified slice)

- Haxeon `70d697ed` exposes the existing public compiler/runtime APIs through
  `embed/haxeon.json` (`haxeon-compiler`), documents ownership/configuration,
  and registers `test-compiler-embedding.sh` in the standard gate. Consumers
  keep compiler/runtime namespaces and configure intrinsics/host HXI explicitly.
  No compiler sources are copied into the editor.
- Registered integration builds a real package consumer, compiles a guest
  program, executes its stable exported function returning 42, and disposes
  the module. Direct runner exits 0; the full compiler gate exits 0 with
  373/373 and every integration/Wasm stage, including embedding. Logs:
  `/tmp/haxeon-embedding-integration-direct.log`,
  `/tmp/haxeon-gate-embedding-package.log`. Prior focused package runs also
  passed reference and self-hosted modes after `c0e1f251`.
- The separate draft incremental probe with a single field-only class passes
  (exit 0, `/tmp/haxeon-embedding-incremental-before.log`), so it does not yet
  reduce the plugin's failure. A stronger variant enables publication tracking,
  acknowledges its first revision, and adds another module with a default
  argument; running session 36638, log
  `/tmp/haxeon-embedding-incremental-publication.log`.
- Source-plugin restoration remains uncommitted and acceptance red at the
  original AST record cast failure. Next: reduce that failure using the stronger
  probe; do not claim a fix from the simpler incremental case passing.

### M8.1 — dynamic restoration checkpoint (uncommitted, acceptance red)

- Restored source-plugin project compiles 973 sources and executes initial
  activation, host calls, Unicode host-error catching and command dispatch.
  Direct run with absolute fixture arguments exits 1 at the background
  compatible-update assertion: an AST class record cannot cast from dynobj to
  the expected anonymous shape. Log:
  `/tmp/exosuit-dynamic-plugin-restoration-absolute.log`. The first direct run
  used relative fixture paths and exited 1 opening source; those paths were
  corrected, with no code workaround.
- Owned pending exosuit files: `haxeon.json`, `DynamicPlugin.hx`,
  `DynamicHostRouter.hx`, `DynamicEditorApiSource.hx`,
  `DynamicPluginTestMain.hx`. None is committed without acceptance. Callback
  response protocol and restart regressions are included, but the restart
  assertion has not yet been reached. Suppression in test.sh remains visible.
- Haxeon embedding manifest/documentation and registered integration test are
  pending verification in session 80655, log
  `/tmp/haxeon-gate-embedding-package.log`. The initial generated-program probe
  passes. A separate unregistered draft
  `tests/integration/test-compiler-embedding-incremental.sh` adds an AST class
  and recompiles changed class initialization to reduce the new runtime cast
  failure; session 4484, log `/tmp/haxeon-embedding-incremental-before.log`.
- Next: inspect that reducer's uncaught runtime stack, reduce the anonymous
  representation conversion, add general compiler/runtime regressions and fix
  the responsible layer before making dynamic-plugin acceptance mandatory.

### M8.1/M8.2 — cast context and checked opaque conversions (verified slice)

- Haxeon `c0e1f251` separates operand inference from the destination of an
  untyped cast; explicit type ascriptions still guide their operands. This
  fixes the exact E1003 reducer for Runtime.callBytes: a generic callback
  calling a native method was incorrectly constrained by the cast destination.
  Local reference Haxe accepts the reduced existing explicit ABI cast.
- IR lowering now treats opaque native handles and managed Bytes as reference
  cast types, using existing checked dynamic casts. It does not relax implicit
  assignability. `CastContextMain` executes a Bytes -> matching opaque handle
  -> Bytes round trip and rejects a wrong native tag at runtime. Removing the
  explicit cast remains rejected incrementally and cold; restoration runs.
  The initial reducer also exposed unsupported backend representation casting;
  both responsible layers are fixed and tested.
- Full `./scripts/test.sh` exited 0: 373/373 and every native/C++/Wasm stage
  (`/tmp/haxeon-gate-cast-context.log`). Bootstrap and self-bootstrap exited 0,
  converged after one stage and rebuilt identically (logs
  `/tmp/haxeon-bootstrap-cast-context.log`,
  `/tmp/haxeon-bootstrap-self-cast-context.log`). Owned updated bootstrap is
  committed; pre-existing dirty Haxeon paths are unchanged.
- The uncommitted package probe now passes in reference and self-hosted modes:
  `/tmp/haxeon-compiler-embedding-cast-fixed-entry.log` and
  `/tmp/haxeon-compiler-embedding-cast-self.log`, both exit 0, compile the
  public compiler/runtime package and execute generated code returning 42.
  The earlier probe expected `Probe.main` incorrectly; module-level functions
  export `main`, consistent with existing runtime tests. Corrected that fixture
  rather than changing exports. Register/document/verify the embedding package
  before committing it.
- Pending exosuit restoration restores the original threaded dynamic-plugin
  implementation, configures compiler intrinsics and the portable PluginHost
  HXI, uses checked function-ID lookups, and reinstalls retained callbacks after
  shutdown. SDK calls use explicit ok/error responses to propagate host errors
  within plugin code. Added disposable-fixture Unicode error-catching and
  callback restart checks. Direct acceptance is running; no success or milestone
  completion is claimed yet. Test suppression remains until acceptance passes.

### M8.1/M8.2 — consistent raw byte intrinsic types (verified compiler slice)

- Haxeon `3f870cf7` makes `Bytes.getData()` and the primitive String byte
  accessor return the same raw `THlBytes` ABI type that declared `hl.Bytes`
  parameters resolve to. The former nominal abstract wrapper caused E1009
  in ordinary identity calls and embedded `Runtime.inspectPatch`.
- Registered `RawBytePointerMain` fails before the fix, then passes actual
  native UTF-16 length calls, annotated raw pointer assignments and identity
  calls. Passing managed Bytes directly remains rejected in incremental and
  cold compiles; restoration executes correctly. Local reference Haxe
  accepts the reduced getData/identity/annotated-pointer program (exit 0).
- Focused expanded regression exited 0; full `./scripts/test.sh` exited 0
  with 372/372 driver cases and every integration/Wasm stage. Both bootstrap
  commands exited 0, converged after one stage and self-rebuilt identically.
  Bootstrap artifacts did not change. Logs:
  `/tmp/haxeon-raw-byte-pointer-before.log`,
  `/tmp/haxeon-raw-byte-pointer-expanded.log`,
  `/tmp/haxeon-gate-raw-byte-pointer.log`,
  `/tmp/haxeon-bootstrap-raw-byte-pointer.log`,
  `/tmp/haxeon-bootstrap-self-raw-byte-pointer.log`.
- Owned, uncommitted Haxeon embedding work: `embed/haxeon.json`, package probe
  `tests/integration/test-compiler-embedding.sh`, and an unregistered draft
  `tests/compiler/CastContextMain.hx`. The real package probe compiles the
  public compiler and Runtime, generates a 42-returning program and invokes
  it. Before the fix it failed at Runtime.hx:108 with E1009; afterward it
  reaches Runtime.hx:139 with E1003 in the existing `callBytes` boundary.
  Logs: `/tmp/haxeon-compiler-embedding-reference.log` and
  `/tmp/haxeon-compiler-embedding-raw-pointer.log` (both exit 1).
- The draft cast reducer reaches a distinct backend diagnostic:
  `Unsupported cast from Abstract(realtime_bytes) to ManagedBytes`. Reference
  Haxe accepts the existing explicit ABI cast through a generic callback;
  the reducer does not yet reproduce the precise E1003 from Runtime, and no
  cast/inference fix is claimed. Do not introduce application casts or
  weaken assignability. Next: reduce both the Runtime callBytes typing and
  managed-byte representation boundary, fix general capabilities with tests,
  then finish the embedding package and restore the dynamic plugin test.

### M8.2 — consistent wrappers without action-directory workaround (verified slice)

- Exosuit `18e1ad5` aligns build, run and test with the standard CLI
  reference-compiler default. `HAXEON_SELF_HOSTED=1` remains an explicitly
  verified mode. Removed the stale pre-created action directories; upstream
  Haxeon `c59502ff` owns the general concurrent directory-creation fix.
- Serialized graphical builds using each compiler and new output paths exited
  0 (`/tmp/exosuit-fresh-reference-actions.log`,
  `/tmp/exosuit-fresh-self-actions.log`). Both headless modes then exited 0
  (`/tmp/exosuit-test-wrapper-reference.log`,
  `/tmp/exosuit-test-wrapper-self.log`), still explicitly skipping source-plugin
  acceptance. No test suppression was added or expanded.
- Additional graphical manifests in temporary directories used absolute
  references to the unchanged real packages and empty build/action caches.
  Both reference and self-hosted builds exited 0, including native builds;
  logs `/tmp/exosuit-empty-actions-reference.log` and
  `/tmp/exosuit-empty-actions-self.log`. No directory pre-creation was used.
- `bash -n scripts/build.sh scripts/run.sh scripts/test.sh` and
  `git diff --check` exited 0. Interactive run, GUI and other platforms remain
  pending. Next: expose Haxeon's compiler/runtime package, restore source
  plugins with callback-error propagation/lifecycle coverage, then make the
  dynamic-plugin test mandatory.

### M8.2 — comprehension collection shadowing (verified slice)

- Haxeon `24ad2048` passes comprehension binding names through loop effect
  analysis, preventing a shadowed outer map/array from lending its primitive
  read-only classification to a user object. The reducer previously accepted
  a field read on a later iteration after a fake `exists` cleared that field;
  it now rejects the code with E1005.
- `PrimitiveMapEffectsMain` covers array and map comprehensions shadowing a
  primitive map, array shadowing, and accepted/executed unshadowed map reads.
  Focused before-fix regression exited 1; corrected expanded checks exited 0.
  Initial focused invocation lacked the runtime library path; the recorded
  regression rerun supplied `LD_LIBRARY_PATH=out:.tools/hashlink`.
- `./scripts/test.sh` exited 0 (371/371 plus all native/C++ and Wasm stages),
  `/tmp/haxeon-gate-comprehension-shadow.log`. Both
  `./scripts/bootstrap-compiler.sh` and `./scripts/bootstrap-compiler.sh --self`
  exited 0: convergence after one stage and identical self-rebuild. Logs:
  `/tmp/haxeon-bootstrap-comprehension-shadow.log` and
  `/tmp/haxeon-bootstrap-self-comprehension-shadow.log`. Updated bootstrap
  artifacts are committed. Pre-existing dirty Haxeon paths remain untouched.
- Exosuit wrapper edits are not yet committed: uniform reference-compiler
  default with explicit self-hosted override, stale action-directory workaround
  removed. Serialized checks are running: fresh graphical outputs in
  `/tmp/exosuit-m8-fresh-reference` and `/tmp/exosuit-m8-fresh-self`, then both
  headless modes. Logs: `/tmp/exosuit-fresh-reference-actions.log`,
  `/tmp/exosuit-fresh-self-actions.log`,
  `/tmp/exosuit-test-wrapper-reference.log`, `/tmp/exosuit-test-wrapper-self.log`.
  Dynamic-plugin suppression remains explicit; M8 acceptance is incomplete.

### M8.2 — text dependency keys and converged bootstrap (verified slice)

- Haxeon `58be9a62` replaces the forbidden NUL dependency separator with a
  shared length-prefixed text key, preserving component boundaries, empty
  components and order. Both reachability-cache producers and consumers use
  it. The HashLink String NUL prohibition remains intact.
- Registered `DependencyKeyMain` fails against the original separator and
  passes with stable, distinct keys for empty lists/components, ambiguous
  concatenations, delimiters and Unicode. Refreshed owned bootstrap artifacts
  are committed with the source; pre-existing `vendor/hashlink` and
  `hlprofile.dump` changes remain untouched.
- Haxeon `./scripts/bootstrap-compiler.sh` exited 0 and converged after one
  self-hosted stage. `./scripts/bootstrap-compiler.sh --self` subsequently
  printed `PASS: checked-in compiler rebuilt itself identically`; its terminal
  status was lost during context handoff, so only that explicit result is
  claimed. Logs: `/tmp/haxeon-bootstrap-dependency-keys.log` and
  `/tmp/haxeon-bootstrap-self-dependency-keys.log`.
- Haxeon `./scripts/test.sh` exited 0: 371/371 compiler-driver cases and every
  integration stage, including native/C++ and both Wasm parity/Wasmtime gates.
  Log: `/tmp/haxeon-gate-dependency-keys.log`. `git diff --check` passed.
- Exosuit `HAXEON_SELF_HOSTED=1 ./scripts/build.sh` and
  `HAXEON_SELF_HOSTED=0 ./scripts/build.sh` exited 0, compiling 618 sources.
  The stale shift-assignment and historical `SelectOption` failures no longer
  reproduce. Logs: `/tmp/exosuit-build-fresh-bootstrap.log` and
  `/tmp/exosuit-build-reference-dependency-keys.log`.
- `HAXEON_SELF_HOSTED=1 ./scripts/test.sh` exited 0; all gating headless
  projects passed. Dynamic source-plugin acceptance was explicitly skipped
  because its implementation is still a stub. Log:
  `/tmp/exosuit-test-fresh-bootstrap.log`. No graphical interaction or
  cross-platform execution is claimed.
- Next: reduce the suspected comprehension collection-shadowing case before
  further compiler changes; remove stale script defaults/workarounds, then
  restore embedded source-plugin compilation and make its test gating.

### M8.1 — native C/HXI migration (verified slice; acceptance incomplete)

- Exosuit `f8939de` replaces every editor `@:hlNative` entry with a C-header
  binding, portable `.hxi`/`.hxmap`, explicit UTF-8 strings, 32-bit booleans and
  managed retained callbacks. ABI is now 18 (the actual run baseline was 17).
  Unused SDL host callbacks and stale generated bridge header are removed.
  Window/font/draw functions remain for headless model, renderer and benchmark
  consumers; rationale and callback lifecycle are in `docs/native-bindings.md`.
- Start state: exosuit `fc5bbee`, clean; materia `816372dd`, dirty submodule
  pointers and untracked exosuit; Haxeon `fba71015`, pre-existing modified
  `vendor/hashlink` pointer and untracked `hlprofile.dump`; NativeKit `2bb4c957`,
  clean off-pin. Reference Pragtical is `/home/joao/dev/pragtical` (the default
  sibling path does not exist), with pre-existing config/sidebar/view/settings
  changes and untracked `scripts/lua/tests/view.lua`. No sibling or reference
  changes were made in this slice.
- `./scripts/test.sh` before migration exited 1 at the recorded `last_error`
  HashLink signature mismatch. After migration it exited 0; all gating
  projects passed. The new `native-string-test` covers Unicode clipboard,
  copied borrowed results, callback arguments/results/errors, replacement,
  shutdown, Unicode native errors and diagnostic truncation at scalar boundaries.
  Existing process tests cover stdin and split UTF-8 output.
- `./scripts/update-native-bindings.sh --check` exited 0: Clang import and
  portable ABI audit passed for Linux x64, Windows x64, macOS x64/arm64.
  This is ABI import evidence, not execution evidence on Windows/macOS.
  `cc -std=c11 -Wall -Wextra -Werror -Iinclude -c
  native/ffi/pragtical_hx.c -o /tmp/exosuit-native.o` and `git diff --check`
  exited 0.
- `./scripts/build.sh` exited 1 with the baseline
  `commandview/CommandView.hx:297:16: E1005: Field "entries" requires an object`.
  GUI/IME/mixed-DPI checks were not performed.
- The test wrapper suppresses `dynamic-plugin-test`: the UIKit port replaced
  source compilation with a throwing stub. Its SDK now declares the migrated
  host symbol through HXI, but needs registration when embedding is restored.
  This gap blocks the full M8.1 acceptance; do not count the wrapper's exit 0 as
  every project passing. No compiler defect was fixed in this slice.

### M8.2 — primitive effect inference (verified compiler slice)

- Haxeon `3606bd7c` on `exosuit-followon` fixes the reference build failure in
  `CommandView.filter` without changing application types or guards. A minimal
  nullable provider loop compiled when it only read entries and failed at the
  same read when `results.push(value)` was added.
- Root cause: loop effect analysis treated built-in array storage operations as
  unknown calls, forgetting all mutable-field facts. It also failed to infer
  primitive string helpers as pure. The syntactic effect walker now recognizes
  declared/inferred array locals and own array fields, reports their storage
  effects, and distinguishes primitive string operations/joins and numeric
  conditional results from calls or object conversions that can run user code.
- Native `StringTools` prefix/suffix comparisons now state their actual `@:pure`
  contract. Their C implementations only read lengths and compare bytes; these
  annotations describe an opaque native boundary, not application workarounds.
- Registered `LoopArrayEffectsMain` covers explicit/implicit own fields,
  annotated/inferred local arrays, rejection of user-defined `push`, sort
  callbacks and direct field replacement. Accepted programs execute on HashLink.
  `PrimitiveStringEffectsMain` covers string helpers and getters, execution,
  incremental rejection after a helper gains a write, cold-build agreement and
  acceptance after restoring the helper.
- Focused regression runners exited 0. Haxeon's `./scripts/test.sh` exited 0
  with formatting enabled: 365/365 test-driver cases, differential tests,
  runtime/HXI/C++ and native-package integrations, wasm backend/parity and
  Wasmtime GC checks passed. Exosuit reference `./scripts/build.sh` exited 0;
  reference headless verification is in progress at this checkpoint.
- Upstream `c59502ff` already made action-directory creation race tolerant via
  `Directories.ensure`; exosuit's pre-creation workaround still needs removal.
- Self-hosted graphical build still exits 1 at `IdSet.hx:565` (`E0002: Expected
  expression`, byte offset at `size <<= 1`). Its checked-in bootstrap was last
  refreshed at `308231b5` (2026-09-28), before later syntax changes. Refresh and
  compare compiler modes before deciding whether another typing fix is needed.
  No self-hosted success or full M8.2 completion is claimed yet.

### M8.2 — null-only local array inference (verified compiler slice)

- Haxeon `5f0b7671` fixes bootstrap's `WasmCAbi.hx:90` E1009 without
  adding annotations to the compiler application. A null-only local array,
  including a comprehension and an alias, now receives the element type
  required by a non-generic constructor argument before its initializer is typed.
  Array assignability and mutation checks remain unchanged.
- Root cause: local constraints did not visit constructors, and null-only
  array initializers ignored later expected context. Existing call constraints
  now also run for expression statements and unannotated initializers.
- Registered `NullArrayContextMain` executes generated HashLink code after
  writing a class instance into nullable array storage; it rejects incompatible
  mutations and checks incremental/cold rejection after a constructor edit.
  The local reference Haxe compiler accepted the independent reducer.
- Focused regression and full Haxeon `./scripts/test.sh` exited 0, including
  formatting, 366/366 driver cases, native/HXI/C++ package integrations,
  differential and both Wasm gates. Log: `/tmp/haxeon-gate-null-array.log`.
  Exosuit `./scripts/build.sh` exited 0 (`/tmp/exosuit-build-null-array.log`).
  Reference headless gate from the preceding slice exited 0, still with the
  explicitly suppressed dynamic-plugin test.
- `./scripts/bootstrap-compiler.sh` exited 1. It passes the old `WasmCAbi`
  failure and stops at `WasmFunctionLower.hx:1049` E1005: a guard checks one
  nullable lookup result, then the body dereferences a second unchecked result.
  The lookup writes a cache; the general type checker correctly requires
  checking the value being consumed. Merge the call branches and check one
  lookup result, then retry bootstrap and two-mode editor gates.
- Pre-existing HashLink pointer and profile dump remain untouched. Bootstrap
  has not converged; M8.1/M8.2 acceptance and GUI checks remain pending.

### M8.2 — checked Wasm source lookups (verified compiler-source slice)

- Haxeon `02608ed7` corrects four nullable-source errors exposed while
  bootstrap checks recent Wasm code. Call lowering now checks and consumes
  one host lookup; dynamic-array helper calls and GC `Std.string` definitions
  report a missing registered function instead of passing a nullable index.
  Fixed-record scratch allocation checks the nullable layout directly.
- These were source errors rather than typing defects. In particular,
  reference Haxe with `@:nullSafety(Strict)` rejects using a stored boolean
  as proof that an unrelated nullable value can be dereferenced. No compiler
  typing rules, annotations or casts were changed for this slice.
- Focused `WasmBackendMain` and full `./scripts/test.sh` exited 0:
  366/366 driver cases, formatting, native integrations, Wasm backend,
  parity and Wasmtime GC execution passed. Log:
  `/tmp/haxeon-gate-wasm-null-checks.log`.
- Bootstrap advances past these failures and exits 1 at
  `WasmGcModuleBuilder.hx:605`, ambiguous bare `I32` in an inferred array.
  Independent reducer: two imported enums both define `Item`; Haxeon rejects
  unannotated `var value = Item`, whereas reference Haxe chooses the later
  import. Existing semantic assembly discards aliases for all collisions.
  Next: register accepted/rejected/runtime/incremental regressions, implement
  import-order precedence, rerun compiler gate and bootstrap convergence.
- No refreshed bootstrap artifact or two-mode success is claimed. All
  pre-existing sibling changes remain preserved; editor worktree is clean.

### M8.2 — enum constructor import precedence (verified compiler slice)

- Haxeon `56fc5b98` resolves colliding constructor names from separate
  explicit imports in source order: the later import supplies the default,
  matching reference Haxe. Explicit expected enum types still take priority;
  collisions within one module import keep their existing ambiguity rule.
- Root cause: semantic assembly discarded constructor aliases for every
  collision, allowing unrelated global enum abstracts to produce misleading
  ambiguity errors in an inferred array of Wasm enum values.
- Registered `EnumImportOrderMain` checks forward/reversed imports, explicit
  expected type priority, incompatible nominal argument rejection, generated
  execution, incremental import edits and cold-build agreement. Reducer failed
  with E1005 before the fix and ran after it; reference Haxe chose the later
  import in the independent fixture.
- Full compiler `./scripts/test.sh` exited 0, with formatting, 367/367 driver
  cases and all native/differential/Wasm stages. Log:
  `/tmp/haxeon-gate-enum-imports.log`. Exosuit `./scripts/build.sh` exited 0
  (`/tmp/exosuit-build-enum-imports.log`).
- Bootstrap exits 1 after passing the old enum failure, now at
  `HlWriterCache.hx:76`: `ObjectMap.get` returns nullable even following
  `exists`. Reference Haxe with strict null safety rejects this pattern too.
  Retrieve and check the snapshot hash once, then retry convergence; no
  compiler assignability or map-presence rules need weakening.
- M8 remains incomplete, including dynamic-plugin integration, refreshed
  self-hosted agreement and release gates. Sibling dirty work is preserved.

### M8.4 — truthful graphical documentation (documentation slice)

- README and ADR 0002 now describe the live Problems and Build Output panels,
  shared-controller command bridge and wired language overlays. They distinguish
  document activation/model selection from visible widget caret movement.
- Remaining gaps explicitly include styled text, decorations, search highlights
  and results panel, caret anchoring, pane operations, context menus and source
  plugins. The ADR describes C/HXI ABI 18 and the retained headless renderer APIs.
- Verified claims against `graphical/src/ui/ExosuitApp.hx`, `CommandBridge.hx`,
  `ProblemsPanel.hx`, `BuildOutputPanel.hx`, `UiWorkbenchHost.hx` and
  `UiDocumentView.hx`; `git diff --check` passes. No extra tests were added for
  this documentation correction. No interactive checks or M8 acceptance are
  claimed. Bootstrap/compiler agreement remains the first active task.

### M8.2 — snapshot cache retention (verified compiler-source slice)

- Haxeon `90776aee` retrieves each cached snapshot hash once, checks it for
  null and retains only present entries. This fixes an unchecked nullable
  `ObjectMap.get` result without changing type relations or map contracts.
  Reference Haxe with strict null safety rejected the former `exists`/`get`
  pattern. Full compiler `./scripts/test.sh` exited 0: formatting, 367/367
  driver cases and all native/differential/Wasm stages. Log:
  `/tmp/haxeon-gate-snapshot-retention.log`.
- Bootstrap advances and exits 1 at `Parser.hx:879`, empty local array `cases`.
  Reducer: the expected result enum has `Case(values:Array<Int>)`, while a
  later imported enum has a no-argument `Case`. Actual expression typing
  selects the expected constructor; inference selects the imported constructor
  first and never constrains `values`. Reference Haxe accepts and executes it.
  Next: register reducer/regressions and align the prepass with typing.
- Exosuit documentation slice `c03089d` completes the M8.4 text correction;
  it does not establish runtime or M8 acceptance. Sibling dirty work remains
  untouched; no refreshed bootstrap artifacts have been committed.

### M8.2 — expected enum argument inference (verified compiler slice)

- Haxeon `5b38eca1` aligns local inference with actual enum expression typing:
  a bare constructor receives the expected enum's argument context before
  falling back to imported constructors. Explicitly qualified references retain
  their normal meaning; type relations are unchanged.
- Root cause: the prepass used imported constructor metadata first, even when
  expression typing selected the expected enum instead. Parser's `Switch`
  constructor collided with the imported token enum's no-argument `Switch`,
  leaving an empty local array without its expected element type.
- Registered `ExpectedEnumContextMain` fails E1003 before the fix, executes
  generated code after it, rejects incompatible pushed elements in incremental
  and cold compiles, and executes again after restoring valid source. Reference
  Haxe accepts and executes the independent reducer.
- Full compiler `./scripts/test.sh` exited 0: formatting, 368/368 driver cases,
  native/differential/Wasm stages. Log: `/tmp/haxeon-gate-expected-enum.log`.
  Exosuit `./scripts/build.sh` exited 0 (`/tmp/exosuit-build-expected-enum.log`).
- Bootstrap passes the parser-array failure and exits 1 at `Parser.hx:2549`:
  missing stdlib `haxe.io.BytesBuffer`, used by Unicode scalar encoding.
  Add reusable byte accumulation over the existing byte-output runtime;
  retain parser types/encoding logic and rerun convergence and both modes.
- No refreshed self-hosted artifact or full M8 acceptance is claimed.

### M8.2 — portable byte builder (verified stdlib slice)

- Haxeon `73d67796` adds `haxe.io.BytesBuffer` over the existing byte-output
  ABI. Supported operations are byte/range append, Int32/Float64 append,
  length and independent byte snapshots. Numeric encoding is little-endian.
  Parser's Unicode scalar encoder is unchanged and now finds its dependency.
- Registered `tests/programs/bytes-buffer.hx` exercises Unicode scalars,
  embedded NUL/255, ranges, byte truncation, snapshots, numeric encoding and
  growth across the initial capacity. Missing class failed E2001 before the
  addition; generated HashLink execution now returns 42.
- The first full gate exited 1 on wasm32 range errors: the underlying native
  byte-output primitive traps on invalid ranges. Reference Haxe's BytesBuffer
  performs its own range validation; the new library now does likewise and
  throws before delegation, preserving the buffer. The test remains gating
  and requires catchable failure on all targets.
- Corrected full `./scripts/test.sh` exited 0: formatting, 369/369 driver cases,
  native/differential integrations, both Wasm parity backends and Wasmtime GC.
  Log: `/tmp/haxeon-gate-bytes-buffer-ranges.log`. Explicit formatter check of
  the stdlib file (outside the script's normal source roots) also exited 0.
- Bootstrap advances beyond the missing class and exits 1 at
  `FieldInference.hx:179`, nullable declaration lookup dereferenced without a
  check. Check retrieved declarations before consuming their fields, then
  rerun bootstrap. No fresh self-hosted artifact or M8 completion is claimed.

### M8.2 — primitive map effects and loop shadowing (verified compiler slice)

- Haxeon `dd36f1c8` recognizes read-only `exists`, `get`, `keys`, `values` and
  `size` on typed String/Int maps as operations that cannot invoke user code.
  Facts cover own fields, arguments, annotated/inferred locals and aliases.
  Loop analysis receives visible primitive-map metadata through Scope and
  TypingSession. User methods and mutations remain effectful.
- Reducer: a checked nullable provider lost its fact after a helper read its
  own `Map.exists`. The helper is now inferred pure. A loop reading a typed
  map parameter exposed missing outer-map metadata; it also executes correctly.
- Rejection coverage caught an unsound loop-name collision: a loop variable
  inherited the outer collection's classification, hiding a fake method's
  mutation between iterations. Loop bindings now remove inherited private-map,
  array and primitive-map metadata. Fake map/array iterations that read before
  mutating are rejected; lexical local shadowing is also covered.
- Registered `PrimitiveMapEffectsMain` executes field/local/alias/argument
  and loop forms; it rejects custom `exists`, direct provider mutation,
  incremental/cold effect edits and accepts restoration. One expanded test
  incorrectly expected arrays from the iterator APIs and was corrected;
  the first gate exited 1 for that fixture error. Later gates passed, and the
  final shadowing gate exited 0: formatting, 370/370 driver cases and all
  native/differential/Wasm stages (`/tmp/haxeon-gate-map-effects-shadowing.log`).
  Exosuit `./scripts/build.sh` exited 0 (`/tmp/exosuit-build-map-effects.log`).
- Source checks also retrieve/validate declarations in `FieldInference`,
  validate store collection after an effectful walker call, and check the
  store-mode precondition in `dottedFieldStore`. No type relations changed.
- Bootstrap passes those failures, then exits 1 at `EqualityGenerator.hx:37`:
  nullable request lookups are dereferenced without checks. Add checked
  required lookups, retry convergence and preserve all pending M8 gates.

### M8.2 — checked equality generation (verified compiler-source slice)

- Haxeon `5cf74eb0` validates required entries before consuming request
  metadata or reachable types. One generic checked lookup preserves types and
  reports an internal missing-key invariant rather than dereferencing null.
- Full compiler `./scripts/test.sh` exited 0: formatting, 370/370 driver cases
  and all native/differential/Wasm stages. Log:
  `/tmp/haxeon-gate-equality-requests.log`.
- Bootstrap passes typing all 443 sources and reaches encoding, then exits 1:
  `HashLink String cannot contain NUL; use Bytes for binary data`. The two
  source literals are dependency-cache separators in `CompilationContext` and
  `FrontendCompilation`. They are text cache keys, not a binary payload.
  Next: share a collision-free length-prefixed text encoder, add regressions
  for empty components and delimiter collisions, then retry convergence.
- M8 acceptance and both compiler modes remain pending; no writer validation
  or language types have been weakened to bypass this failure.

## Completed records

### M7.2–M7.3 — Linux automation and relocatable packaging

- ABI v16 distinguishes committed text from IME preedit state and owns candidate
  placement; Pragtical font groups supply configured fallback faces. Real SDL
  automation covers Unicode clipboard/file names, Ctrl/Shift/Alt chords, resize,
  keyboard-only editing/navigation and the full M0 workflow including split,
  project search and plugin reload. Default essential text roles meet WCAG 4.5:1.
- `release.lock` pins Haxeon, Pragtical renderer and HashLink. Release builds reject
  modified inputs, rebuild the runtime atomically, package all modules, language
  tooling, stdlib, fonts, defaults, docs and notices, and use executable-relative
  lookup rather than the launch cwd or a mutable sibling at runtime.
- `scripts/test-release.sh` passed from a fresh extracted location, including the
  bundled real Haxeon diagnose/fix/build route. `scripts/ci.sh` composes compiler,
  headless, SDL and release gates. Windows/macOS, a real desktop IME candidate
  session and a physical mixed-DPI transition remain explicitly unclaimed.

### M7.1 — performance and endurance

- `2130565` adds the fixed small-file, 10 MiB, 1 MiB-line, document soak,
  plugin-reload and 10,000-file index/search fixtures. Profiling replaced linear
  visual-row lookup, repeated width scans, collapsed-selection offset scans,
  highlight prefix rescans and quadratic project snapshot construction.
- `6a605d7` gives the cooperative scheduler a six-millisecond wall-clock slice in
  addition to its step ceiling and turns the latency, idle CPU, progression and
  cancellation budgets into executable benchmark failures. Both benchmark scripts
  prepare their own headless native runtime.
- On the recorded i5-13600K Linux host, typing p95 was 0.051 ms, 10 MiB scrolling
  p95 was 0.052 ms, idle service CPU was 2.00%, the maximum 32-step indexing turn
  was 6.37 ms, replacement-search turns stayed below 0.98 ms, and peak RSS was
  170,708 KiB. First/last soak windows did not show progressive latency. Exact
  fixtures, limits and results are in `docs/release-qualification.md`.
- `SKIP_FORMAT_CHECK=1 ./scripts/test.sh`, both benchmark scripts and
  `./scripts/build-sdl.sh` exited 0. The format skip remains the documented
  unrelated repository baseline; changed files pass `git diff --check`.

### M6.3 — language service plugin

- `697b19c` adds a bounded UTF-8 `Content-Length` JSON-RPC transport with
  nonblocking atomic writes, response correlation, timeout cancellation,
  bounded stderr and malformed/oversized-frame rejection.
- `d26b462` adds the restartable client with initialize/shutdown, incremental
  UTF-16 document synchronization, versioned diagnostics, hover, completion,
  definitions and revision-checked transactional edits. `ad23720` exposes owned
  editor commands, diagnostic decorations and server-initiated workspace edits;
  `bd3eb44` gates features from negotiated capabilities.
- The deterministic fake server covers out-of-order responses, split Unicode,
  stale diagnostics, unsupported capabilities, server requests and forced
  restart. `77394ff` adds `scripts/test-haxeon-lsp.sh`; it proves the real Haxeon
  server diagnoses an invalid edit, clears the diagnostic after correction, and
  the corrected fixture builds and executes.
- Required Haxeon work is independently committed through `21a996b`: sound call
  invalidation and initializer ownership, native JSON/reflection, Dynamic value
  equality, null-field representation, intrinsic `Std.isOfType`, and a cwd-safe
  LSP launcher. The compiler suite passed 205/205; the editor headless suite,
  real-server smoke and SDL artifact build all exited 0.

### M6.1 — syntax and presentation

- `93eaaf6` expands reference-backed Haxe/Haxeon, C, C++, JSON, Markdown, Lua and
  shell highlighting with multiline lexical states and bounded repair.
- `a34a1d7` adds bounded, syntax-aware bracket matching. `3f3416a` makes wrapped
  and folded visual rows authoritative for painting, scrolling, hit testing,
  selection and vertical movement, with automatic expansion for hidden caret and
  search targets.
- `d232752` adds an owner-scoped completion-provider registry. The built-in
  document-word provider uses the same extension path as plugins, and Ctrl+Space
  opens the shared command UI with revision-checked prefix replacement.
- Focused acceptance covers multiline repair, wrapped movement and selection,
  physical search reveal, completion insertion and provider cleanup. The full
  headless suite and SDL build passed after the implementation.

### M6.2 — background processes and output

- `22c4628` adds generation-checked native process handles with exact argument
  arrays, cwd/environment configuration, separate nonblocking output, exit status,
  cancellation and manager/platform shutdown cleanup. Headless and SDL builds use
  the shared implementation.
- `080b09f` adds deliberately selected project tasks, bounded 10,000-line/1 MiB
  retention, a Build Output view and clickable file/line diagnostics. `2ce8368`
  exposes subprocesses through plugin ownership and proves unload and failed
  activation retire them.
- `0813b05` defines this repository's own headless test/build and SDL build tasks.
  The automated smoke launches the real headless build through the editor task UI;
  atomic artifact publication prevents rebuilding a currently running editor from
  truncating its mapped runtime libraries.
- Acceptance covers spaces in arguments/cwd, environment values, a 200 KB pipe
  flood, UI byte/line limits, nonzero exit, cancellation, stale handles, editor
  shutdown and diagnostic navigation. The full headless suite and SDL build pass.

### M0.1 — trustworthy baseline

- Native platform tests, every Haxeon application test entry, and the SDL graphical artifact build successfully.
- `./scripts/test.sh` exited 0; `./scripts/build-sdl.sh` exited 0.
- The pre-existing top-level `README.md` edit remains outside implementation commits.
- A graphical compile does not prove mouse, IME, DPI or screen usability; the interactive M0.3 route remains pending.

### M0.2 — current search slice

- Commit: `35d73f0 Bind document search results to revisions`.
- Matches carry document identity, buffer state and matched text. Selection and replacement reject stale ranges. Editing, undo and active-document changes refresh or invalidate results.
- Replace-all is one buffer edit and therefore one undo operation. Cancelling find clears transient highlights across views. A named command returns workspace search to the project sidebar.
- Coverage reproduces edit-after-find, undo refresh, document switching, replace-all/undo, cancelled highlighting and multi-project result activation.
- `./scripts/test.sh` exited 0 after the final changes.

### M1 — safe file lifecycle

- `b294ba2` added pathless, uniquely identified untitled documents and Save As,
  with duplicate-open and overwrite collision handling.
- `840781f` made backing paths explicitly optional throughout the document and
  versioned recovery models.
- `38328ca` unified tab close, pane close and native quit behind one
  Save/Discard/Cancel coordinator, including shared-document and failed-save cases.
- `91b0234` bounded recovery retention to the newest 50 snapshots and retires an
  accepted snapshot before regenerating state for documents that remain dirty.
- Existing atomic persistence, external-change reconciliation, BOM/newline
  round-trips, missing/corrupt recovery and injected failure cases complete the M1
  headless acceptance routes.
- `./scripts/test.sh` exited 0 at editor HEAD `91b0234`; interactive prompt behavior
  remains part of the pending M0.3 graphical smoke route.

### M2.1 — positions, transactions and view ownership

- `9d5ddf3` replaced the single buffer callback with structured, independently
  releasable change subscriptions and documented UTF-16 code-unit positions at
  Unicode scalar boundaries.
- `942fdbc` began transforming inactive-pane ranges through shared edits.
- `ec158d3` removed caret and selection state from `TextBuffer`; every editor view
  now owns its selection while documents share text and history. View teardown
  releases subscriptions.
- `98a0109` added explicit multi-replacement transactions, adjacent typing groups,
  movement boundaries, redo invalidation and initiating-view selection restoration.
- Tests cover emoji surrogate boundaries, the declared combining-mark behavior,
  independent split-pane cursors, passive range transformation, grouped typing,
  overlapping-transaction rejection and transaction undo/redo.
- `./scripts/test.sh` and `./scripts/build-sdl.sh` both exited 0 at `98a0109`.

### M2.2 — clipboard and navigation

- `a6b5cf8` added platform ABI v5 clipboard read/write with deterministic headless
  storage, SDL integration, HashLink UTF-8 conversion and Ctrl+C/X/V editing.
  Paste normalizes CRLF/CR to the buffer's logical LF representation and remains
  one undo unit.
- `d61c88a` added selection collapse, word/page/document movement and selection,
  double/triple-click selection, SDL click-count forwarding and bounded drag
  autoscroll driven by an injectable clock. Page keys are covered by ABI v6.
- Tests cover multiline/non-ASCII clipboard round-trips, cut/paste undo, viewport
  page movement, word/document ranges, click selection and timed outside-viewport
  dragging.
- `./scripts/test.sh` and `./scripts/build-sdl.sh` both exited 0 at `d61c88a`.

### M2.3–M2.4 — coding edits and multiple selections

- `f16a506` added single-transaction indent/unindent, autoindent, duplicate/move/
  delete/join line and syntax-driven comment commands. Typed `editor.tabWidth` and
  `editor.insertSpaces` settings select spaces or tabs per project.
- `e9d42aa` introduced normalized selection sets, stable primary selection,
  document-order clipboard distribution, next-occurrence selection, selection-set
  history snapshots and rendering for every caret/range.
- `b5be0c3` extended movement, insertion/deletion, indentation, comments and line
  transformations across multiple selections. `4987556` covers blank, partial and
  trailing-newline indentation semantics.
- Tests cover reversed/overlapping ranges, multiple insertions and deletions,
  distributed copy/paste, next occurrence, undo/redo range restoration, mixed
  indentation, blank/final/trailing lines and one-transaction command behavior.
- `./scripts/test.sh` and `./scripts/build-sdl.sh` both exited 0 at `4987556`.

### M3.1 — reusable command input

- `d10ddf8` gives command input its own reusable text buffer and selection,
  clipboard editing, undo/redo, history traversal and completion without creating
  a document.
- Command results use deterministic exact/prefix/path-aware fuzzy ranking with
  stable tie-breaking and preserve the selected identity across provider updates.
- Named commands provide keyboard-only command execution, file opening and
  go-to-line/column behavior; file completion operates on workspace paths.
- Headless application and command-view tests cover empty, unmatched and Unicode
  queries, completion, cancellation, history and navigation.

### M3.2 — layout and navigation

- `86dd34e` adds directional pane focus, tab movement and reordering, lifecycle-
  coordinated close controls, sidebar toggle/resize, active-tab overflow,
  physical split clamps and draggable editor scrollbars.
- Modal command input owns pointer and wheel routing without moving editor focus,
  preventing an inactive document from being changed through prompt input.
- Headless tests cover focus, tab movement/reordering, narrow layouts, close
  routing, modal input isolation and scrollbar dragging; the SDL artifact builds.
- `8e56b15` makes the platform coordinate contract explicit: window dimensions,
  pointer events, clipping and drawing all use logical points while display-scale
  changes update the backing renderer and propagate through ABI v11. Headless
  tests preserve logical hit-test/layout coordinates at a synthetic 1.75 scale.

### M3.3 — status and feedback

- `c8004f4` adds a reusable status view with path, dirty state, caret, selection,
  indentation, UTF-8/BOM and newline details; bounded notification and error
  histories; an inspectable error command; and reusable typed confirmations.
- File, recovery, configuration and plugin failures feed actionable notifications
  and the retained error log. Escape now cancels the lifecycle transaction behind
  a close confirmation instead of merely hiding its prompt.
- `8e56b15` centralizes shell/editor colors into semantic theme roles, including
  focused, hovered, selected, muted and disabled states.
- `73517b6` covers bounded retention, plugin diagnostics, status transitions,
  Escape cancellation/re-entry and the inspectable log. `./scripts/test.sh` and
  `./scripts/build-sdl.sh` both exited 0 at that editor HEAD.

### M4.1 — scheduling and project index

- `970aee6` introduces a cooperative round-robin scheduler with stable job IDs,
  replacement generations, stale-handle rejection, cancellation and an exact
  per-update step budget. `76a301a` moves project enumeration and bounded polling
  onto those jobs and gives the tree, file picker and search one indexed file set.
- Scans publish the initial tree incrementally and publish later reconciliations
  only from the current generation. Exclusions apply before descent; canonical
  directory identities prevent the benchmark's symlink cycle from recurring.
  Removing a project cancels its scan and retired state rejects later publication.
- `11dcc5c` adds `scripts/benchmark-project-index.sh`. On 2026-09-08, a 10,000-file
  fixture (100 directories × 100 files plus a root symlink cycle) completed in
  100 one-directory updates, with 100 simulated input-service ticks and a maximum
  observed update of 40.499 ms on an Intel Core i5-13600K with 31 GiB RAM.
- The full headless suite and SDL artifact build passed at `76a301a`; the dedicated
  benchmark passed at `11dcc5c` including cancel/reopen stale-result checks.

### M4.2 — search and replacement

- `00340f2` moves workspace search onto debounced, generation-cancelled scheduler
  jobs. Results stream in bounded batches with caps and preview limits; dirty open
  buffers take precedence over disk. Binary, oversized and unreadable files become
  retained partial-result diagnostics rather than aborting the query.
- `c0acd51` adds case, whole-word, path and PCRE2 regular-expression searches,
  including capture-aware replacement, invalid-pattern reporting and scalar-safe
  progression after zero-width matches. Document replacement remains one undoable,
  revision-checked buffer transaction.
- `1460df1` adds an explicit project replacement preview/apply route. Every file is
  revalidated after preview; open documents receive independent undoable edits and
  disk files use atomic M1 publication with per-file applied/conflict/failure
  outcomes. The complete previous contents and expected post-write contents of the
  latest disk batch are retained at `replacement-backup.conf`; restore is explicitly
  best-effort per file and refuses subsequently changed files, not a cross-file undo.
- `20b95b0` proves binary, 5 MiB oversized and permission-denied inputs as distinct
  partial failures. Rapid replacement generations, result caps, dirty precedence,
  filters, regex captures/zero-width/invalid cases, disk conflicts, backup restore
  conflicts and preview/apply equality are covered headlessly.
- The complete headless suite and SDL artifact build passed after the final M4.2
  implementation. Interactive confirmation behavior remains in the M0.3 smoke route.

### M4.3 — file operations and sessions

- `c5543c0` centralizes collision-checked file/folder creation, rename/move and
  recoverable deletion. Directory moves rewrite every nested open-document path;
  dirty documents save only to the new location. Deletion moves entries into the
  application state trash and detaches affected buffers as dirty pathless documents
  so recovery and Save As remain available.
- `7c2c6bf` introduces session v2 and recovery v3. Pane tabs reference clean paths
  or stable recovery identities, allowing multi-root split layouts, active views,
  caret/scroll state and dirty/pathless contents to survive restart without embedding
  recovery text in the session. Missing projects/files/recovery entries and malformed
  layout records are skipped. Session writes settle behind a 750 ms debounce and
  flush explicitly during graphical shutdown.
- Headless coverage exercises file and folder collisions, nested directory moves,
  dirty saves after rename, recoverable deletion, missing project/tab entries,
  malformed sessions, stable untitled recovery, debounced publication and shutdown
  flush. The complete headless suite and SDL artifact build passed at `7c2c6bf`.
- The 10,000-file project benchmark was rerun at the M4 exit gate: 100 updates and
  100 input ticks, with a maximum observed update of 51.621 ms on the previously
  recorded Intel Core i5-13600K / 31 GiB host.

### M5.1 — configuration

- Haxeon `37c062a` adds the standard `Sys.systemName()` platform boundary and a
  runtime regression; the compiler/runtime gate passed all 201 tests.
- `edeaaa0` makes configuration subscriptions independently disposable, converts
  read failures into retained diagnostics, preserves last-good settings across
  invalid bytes and detects restoration of previously accepted bytes.
- Every semantic theme role, font, indentation, keybinding, exclusion and search
  setting participates in defaults < user < active-project layering. Changes apply
  live; project disposal releases its subscription, keymaps replace configured
  bindings, and font replacement destroys the retired native handle.
- Project files remain versioned data and unknown keys reject the complete layer.
  Linux/BSD XDG, macOS, Windows and authoritative portable locations are defined in
  `docs/configuration.md` and selected using the host system name.
- Headless acceptance covers precedence, invalid rollback/recovery, visible project
  diagnostics, project switching, default reset, subscription cleanup, live theme,
  single keybinding installation and stale font-handle rejection. The complete
  headless suite and SDL artifact build passed at `edeaaa0`.

### M5.2 — stable editor API

- `2c1f57e` introduces versioned typed capabilities for transactional document and
  selection edits, configuration snapshots, owned panels, document events and
  cooperative jobs. Plugin contexts release callbacks, jobs, panels, bindings,
  commands and syntax contributions in reverse ownership order.
- Haxeon `c4310fa` supports calls through arbitrary expression values, which keeps
  reverse-order disposer invocation idiomatic. `bf4166f` fixes lexical static-field
  resolution in switch cases rather than requiring editor-side pattern workarounds;
  the compiler/runtime gate passed all 202 functional tests.
- `fe5216f` supplies dynamically compiled plugins with the versioned
  `pragtical.Editor` SDK and opaque, plugin-owned host tokens. The example performs
  undoable document edits, contributes and updates a panel, observes document
  events and retains those capabilities through a compatible body patch.
- Manifests declare independent manifest and API versions; incompatible versions
  produce visible diagnostics. Tests prove unload retires the panel, event callback,
  job, command and syntax registrations while preserving intentional text edits.
  API ownership, conflict order and compatibility are documented in
  `docs/plugin-api.md`.
- The complete headless suite and SDL artifact build passed at `fe5216f`.

### M5.3 — reload reliability

- Haxeon `c4e57eb` adds portable lightweight filesystem metadata and `d3ab07b`
  exposes HashLink thread creation through a typed stdlib boundary; the complete
  compiler/runtime gate passed all 202 functional tests after each final change.
- `21dd513` makes structural reload a context ownership transaction and restores
  the previous runtime, state and registrations if replacement activation fails.
  `5d27a1b` observes metadata on a 250 ms cadence, debounces for 300 ms, audits
  coarse timestamps periodically and deduplicates retained diagnostics.
- `d455d5d` provides command-palette enable, disable, reload and diagnostic views.
  Disabled definitions remain available while every owned command, binding, panel,
  syntax, event and job is disposed before reactivation.
- `434f2b4` serializes dynamic compilation on a worker while publishing only from
  editor updates. `c36783a` also moves source reads and coarse-timestamp audits off
  the event loop and rejects obsolete or unloading in-flight publications.
- `bd752bd` specifies runtime `stateVersion()` compatibility: structural domains
  receive saved state only for equal versions, while compatible body patches retain
  their live runtime and host resources. `docs/plugin-development.md` documents the
  runnable example, local discovery, controls, failure behavior and current SDK gap.
- Acceptance coverage repeatedly performs compatible and structural reloads,
  injects compile, activation and source-removal failures, changes state versions,
  unloads during compilation and asserts no duplicate or stale callbacks. The full
  headless suite and SDL artifact build pass; interactive behavior remains in M0.3.

## Previously delivered roadmap foundations

- `028c7fa`: safe file lifecycle, recovery, project polling and restorable split workspaces.
- `21ba9de`: exception-based atomic write integration and embedded-NUL byte test.
- Haxeon `e573f8f`: byte-oriented, error-reporting atomic publication with POSIX durability and Windows replacement support.
- `e9b47c2`: layered configuration and workspace sessions.
- `e08b0e4`: command-view document/workspace search.

These commits satisfy only the behaviors evidenced by their tests; they do not mark an entire later milestone complete.

## Compiler issue register

- Lambda bodies were previously pretyped outside their flow context. Haxeon `0643a3c` removed that unsound pass and added accepted callback/interface cases.
- Atomic publication required a runtime/stdlib facility rather than weakened editor persistence. Haxeon `e573f8f` owns that platform boundary.
- Haxeon `7598300` preserves nullable narrowing for captured locals in callbacks;
  positive and negative regressions pass with the full compiler suite.
- Haxeon `4bd73cf` compares runtime strings by value in statement switches rather
  than relying on pointer identity; its runtime-created-string regression passes.
- Haxeon `14eeadd` propagates assignment and refinement facts from completing block
  expressions, fixing concise try-expression narrowing without weakening nullable
  field access. Accepted class/interface and rejected continuing-catch cases pass.
- Haxeon `73c7ca3` replaces substring-emulated `EReg` with HashLink's PCRE2 engine,
  including captures, invalid-pattern exceptions and terminating zero-width global
  replacement. Haxeon `1512bc7` captures the receiver for implicit instance-field
  assignment in lambdas instead of emitting an invalid raw `this` local.
- Reinspect repository ownership and run the compiler gate before further compiler edits.

## Blockers and pending manual checks

- M8 gates pass, including real LSP, UIKit workflow and unpacked release.
- The SDL-era graphical route (M0.3) and its automation scripts were removed by the
  UIKit port; M8.3 replaces them. Desktop IME and physical mixed-DPI checks stay pending.
- Windows (ConPTY, named pipes, atomic publication) and macOS are unclaimed.

## Record template

```text
Task ID and state:
Timestamp:
Repository HEADs and pre-existing changes:
Behavior delivered:
Design decisions and rationale:
Files / owned hunks changed:
Commands, exit codes and observed results:
Manual checks performed / still pending:
Compiler issue ID, reduced case, root cause and regression evidence:
Failures classified as introduced / baseline / environment:
Remaining work and exact next action:
```
