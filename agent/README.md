# Headless workspace catalog

The daemon hosts a durable named-group catalog over a same-user local socket and
an authenticated **loopback-only** WebSocket. SQLite persists groups, revisions,
cursor, operation outcomes and trimmed replay events atomically; restart preserves
the catalog epoch and mutation idempotency. It has no UIKit or GPU dependency.
Terminal/provider supervision and remote deployment
remain M14 work.

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

For direct fixtures, build with
`../haxeon/scripts/haxeon build --project agent/haxeon.json`.
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
planned authenticated secure relay and endpoint/session authorization.

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
No durable terminal history, checkpoint rotation, runtime listing/deletion or
provider sessions are delivered yet. Terminals are rooted at the canonical project
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
Until runtime listing is delivered, terminate before discarding the last saved
view when the shell should stop.
