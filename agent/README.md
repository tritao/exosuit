# Headless workspace catalog

The daemon hosts a durable named-group catalog over a same-user local socket and
an authenticated **loopback-only** WebSocket. SQLite persists groups, revisions,
cursor, operation outcomes and trimmed replay events atomically; restart preserves
the catalog epoch and mutation idempotency. It has no UIKit or GPU dependency.

Start it on Linux with:

```sh
python3 scripts/run-agent.py /path/to/workspace --detach
```

Without `--detach`, the manager runs in the foreground. It creates private state
under `$XDG_STATE_HOME/exosuit/workspaces/ROOT_HASH`, or `--state-dir DIRECTORY`.
The directory must be owned by this user with mode 0700; files are mode 0600.
`--port PORT` chooses the loopback WebSocket port; the default selects a free port
and refuses startup if another listener wins the bind race.

The manager holds an exclusive lifetime lock inherited by the daemon and returns
exit 3 `workspace_in_use` for a duplicate start. It writes `endpoint.json` after
readiness, with the canonical workspace root, manager PID/generation, endpoints
and credential file path. The credential itself is never included. Discovery
is verified by the Linux editor through negotiated capabilities and a typed
identity query before catalog subscription. Opening a folder through
`scripts/run.sh` discovers or starts the detached daemon; switching folders
selects the corresponding service. Closing a window closes only its client;
the daemon stops after a minute without authenticated clients. To stop, send SIGTERM to the descriptor's `managerPid`. Normal stop
removes owned discovery and stops the child process group while retaining the
database and credential. Replaced/missing storage stops the daemon rather than
silently opening a fresh catalog. Linux startup is tested; Windows management is
not delivered by this POSIX launcher.

Remote relay hosting is opt-in. In the desktop Remote Access panel, enter your
HTTPS relay origin and choose **Enable remote access**. The address is saved in
the private workspace state directory. The running daemon enables the relay
without restarting terminals, Codex sessions, or sibling workspace clients.
The panel distinguishes local workspace connection from relay connection and
shows relay failures beside setup. Older daemons need to be restarted after
their active sessions have finished before they can expose this setup flow.

`EXOSUIT_RELAY_ORIGIN` still overrides the saved address when starting the manager.
Configuration creates one stable opaque relay identity
for that workspace service and a private, one-shot bearer bootstrap. The daemon
moves the bearer into NativeKit's OS credential store, keyed by relay origin and
machine identity, enrolls it with the Worker, and keeps the daemon alive while
relay hosting is enabled. Linux builds
need `libsecret-1-dev`; a user-session Secret Service must be available at runtime.
The relay socket is outbound, so no inbound port needs to be exposed. Creating
an invitation requires a connected relay. Incoming devices authenticate through
Noise, and access starts only after code confirmation and desktop approval.
Each request initially selects all permissions; the owner can select Read only,
Edit files, or adjust individual permissions before approving. The choices for
one request do not affect other requests or already paired devices.

For direct fixtures, build with
`haxeon/scripts/haxeon build --project agent/haxeon.json`.
Run arguments are:

```text
PRIVATE_SOCKET LOOPBACK_WS_PORT TOKEN_FILE SEED_EPOCH [DATABASE [WORKSPACE_ROOT [INSTANCE [IDLE_MILLISECONDS]]]]
```

The caller supplies a private owner-only directory, a 0600 credential file
containing exactly 64 lowercase hex digits generated from 256 random bits, and an
independently generated public seed epoch. The seed epoch initializes a new
catalog; an existing database restores its stored epoch. Omitting `DATABASE`
selects ephemeral fixture mode, which requires a fresh epoch on every restart.

NativeKit enforces private-path/same-user checks on the local listener. WebSocket
clients prove possession of the credential before RPC negotiation or dispatch.
Plain loopback WebSocket has no network encryption. Remote access requires the
authenticated secure relay and endpoint/session authorization described in
`docs/roadmap/16-remote-workspaces.md`.

`--discover` validates existing private discovery without starting a daemon;
exit 4 means no discovery. `--wire` emits the typed JsonWire profile for the
native client. The launcher is selected with `EXOSUIT_AGENT_LAUNCHER`, or found
from a repository launch directory. Release bundles install the manager beside a matched `exosuit-agent` runner and
bytecode, so managed startup does not compile sources or require Haxeon.

The default idle grace is 60 seconds, including initial startup. `--idle-seconds N`
changes it for new managed daemons; `--always-available` (or
`EXOSUIT_AGENT_ALWAYS_AVAILABLE=1`) explicitly disables idle shutdown. Unnegotiated
or unauthenticated sockets do not keep it alive. Running daemon-owned terminals also retain the service, even with no attached clients. Existing policies are not changed by client attachment.
Normal idle stop closes clients/listeners, releases SQLite and the native runtime,
then the manager retires discovery and its lifetime lock with exit 0. Explicit
SIGTERM stop uses the same owned-process cleanup. The desktop command palette offers “Terminate Active Terminal”; closing a window only detaches.

Run `python3 scripts/test-agent-idle.py` for real idle shutdown, client retention,
restart and detached availability. `bash scripts/test-runtime-bundle.sh` exercises
already-built assets through the production staging routine after relocation,
without publishing a release or modifying locked revisions.

Managed services advertise a build identity and a same-user lifecycle capability.
The editor compares that identity with the installed manager's source or bundled
bytecode identity. An outdated idle service updates automatically. With active
terminals or attached Codex conversations, the Remote access panel offers
“Update when idle”, cancellation, and an explicitly confirmed “Restart now”.
Preparation builds the replacement before asking the daemon to stop; build
failure leaves current sessions running. The daemon rechecks activity itself,
closes storage cleanly, and its manager starts a fresh generation. Connected
editors rediscover and reconnect. Older services without lifecycle support need
one explicitly confirmed restart because their activity cannot be checked safely.
Lifecycle control is never offered to relay or loopback WebSocket clients.

Run `python3 scripts/test-service-updates.py` for real idle, busy, forced and
legacy upgrades with two editor clients, plus failed-build and generation guards.
Run `bash scripts/test-workspace-attachment.sh` for discovery, identity, shared
reuse and stale restart acceptance. `python3 scripts/test-workspace-attachment-ui.py`
checks actual desktop attachment and reuse across windows under Xvfb.
Run `bash scripts/test-workspace-persistence.sh` for storage and managed lifecycle
acceptance, and `bash scripts/test-workspace-transport.sh` for real transports.
`bash scripts/test-workspace-rpc-browser.sh` builds and runs Chrome fixtures on
both Wasm GC and Wasm32 (using the sibling Emsdk installation). A browser commits
a rename, suspends/reconnects, then observes its durable state after daemon restart.
Temporary credentials and child processes are cleaned up. The browser page is a
test client; the Exosuit web application's connection UX remains pending.


### Daemon-owned desktop terminals

With a folder open on Linux, terminals use the verified workspace RPC connection.
Their opaque IDs are saved in the editor session. Restoring a view attaches to the
same shell, environment and PID; it never silently starts a replacement shell.
Folderless terminals retain the existing local backend. Hiding the terminal panel
keeps its tabs, and closing the editor detaches its views. Running terminals keep
the daemon alive; the idle grace resumes after all terminals exit and clients leave.

The first runtime slice permits 16 terminal records per daemon instance, including
exited records. Each retains at most 16 MiB of output in owned 64 KiB chunks, with
64-bit byte cursors. Replay reads and input batches are bounded to 64 KiB. Restoring
beyond retained history reports a replay gap; daemon restart reports a lost session.
No durable terminal history, checkpoint rotation, provider sessions are delivered yet. Terminals are rooted at the canonical project
folder, use the default user shell and accept dimensions up to 512 columns × 256 rows.

Only the daemon responds to VT queries. Client emulators replay output without
responding to queries, but still send explicit keyboard/paste/mouse input. Both
remote parsers disable the generic emulator's optional checkpoint event log to
avoid retaining another unbounded copy of output. Retained PTY bytes require one
ownership copy; RPC encoding and transport are not claimed to be zero copy.

Development startup builds without passing the workspace lock into the compiler,
then launches HashLink directly with the lock. Persistent compiler workers cannot
retain it. NativeKit isolates PTY children from host descriptors. Installed bundles
run their already-built agent and include its terminal libraries.

Run `python3 scripts/test-workspace-terminals.py` for permission checks, open retry,
input sequencing, bounded replay, same-shell reattachment and idle ownership.
Run `xvfb-run -a python3 scripts/test-workspace-terminal-ui.py` for real desktop
close/reopen, continued execution while detached and restored shell identity.

A restored grid replays raw bytes at its current size; exact historical resize
reconstruction awaits state checkpoints. Closing an individual tab also detaches.
Use Workspace Terminals to reopen or stop a detached session.


### Terminal catalog

“Workspace Terminals…” lists service resources even with no saved/open view. Open
reattaches the same runtime, name/group editing changes durable metadata, Stop kills
its PTY and Remove forgets an exited, failed or lost record. Running sessions cannot
be forgotten. Removal releases replay/emulator retention and runtime slots.

The existing database migrates from schema 1/2 to 3 and stores at most 256 terminal
records; discovery returns six per page. Names/group membership and last known
state survive service restart, but old active records become lost and cannot open
or silently respawn. Output remains volatile. Sixteen runtime/replay records can be
held at once; removing finished records makes room for new terminals.

The catalog uses current workspace groups. Tasks and
provider resources are later work. Run `xvfb-run -a python3
scripts/test-workspace-terminal-catalog-ui.py` to discover a shell created by a
separate process, reopen it without a saved tab and restore that view on a third
launch. An optional installation directory exercises the relocated bundle.


### Workbench directory groups

The Workbench sidebar supports nested named groups, duplicate names, editing,
parent moves and sibling order. New terminal uses the selected group. Its launch
directory comes from an explicit override, the nearest ancestor directory, or the
workspace root. The daemon canonicalizes existing directories and refuses targets
outside that root, including symlink escapes. Moving a running session/group never
changes its cwd. Group selection is local UI state; Open folder is an explicit
editor action.

This slice uses one authorized project root. The authorized root is pinned in workspace metadata, independently of editable
group directories; groups may inherit or select subdirectories. Multi-project roots,
group deletion, drag-and-drop and saved tree expansion/selection are later work.
Group changes reuse durable revisions, operation IDs and the event journal; schema
3 migrates older catalogs and refuses unknown schemas. Bounds remain 32 groups and
256 retained operations. Names/group metadata and terminal owner scope persist;
output replay stays volatile.

Run `xvfb-run -a python3 scripts/test-workbench-groups-ui.py` for real controls,
nested directory creation and subdirectory terminal restoration. It accepts a
staged runtime directory as its optional argument for relocation acceptance with
source compilation disabled. Terminal fixtures also cover two-client updates,
permissions, cycle/stale-edit rejection and Unicode storage/message bounds.

Codex conversations use a separate structured provider adapter, not terminal
bytes. See [CODEX.md](CODEX.md) for version support, controls, bounds and recovery.
