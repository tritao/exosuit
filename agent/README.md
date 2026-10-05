# Headless workspace catalog

The daemon hosts a durable named-group catalog over a same-user local socket and
an authenticated **loopback-only** WebSocket. SQLite persists groups, revisions,
cursor, operation outcomes and trimmed replay events atomically; restart preserves
the catalog epoch and mutation idempotency. It has no UIKit or GPU dependency.
Terminal/provider supervision, editor auto-spawn/reuse and remote deployment
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
must be verified by a client handshake before reuse; editor integration is still
pending. To stop, send SIGTERM to the descriptor's `managerPid`. Normal stop
removes owned discovery and stops the child process group while retaining the
database and credential. Replaced/missing storage stops the daemon rather than
silently opening a fresh catalog. Linux startup is tested; Windows management is
not delivered by this POSIX launcher.

For direct fixtures, build with
`../haxeon/scripts/haxeon build --project agent/haxeon.json`.
Run arguments are:

```text
PRIVATE_SOCKET LOOPBACK_WS_PORT TOKEN_FILE SEED_EPOCH [DATABASE [WORKSPACE_ROOT]]
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

Run `bash scripts/test-workspace-persistence.sh` for storage and managed lifecycle
acceptance, and `bash scripts/test-workspace-transport.sh` for real transports.
`bash scripts/test-workspace-rpc-browser.sh` builds and runs Chrome fixtures on
both Wasm GC and Wasm32 (using the sibling Emsdk installation). A browser commits
a rename, suspends/reconnects, then observes its durable state after daemon restart.
Temporary credentials and child processes are cleaned up. The browser page is a
test client; the Exosuit web application's connection UX remains pending.
