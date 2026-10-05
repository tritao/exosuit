# Headless workspace bootstrap

This first daemon hosts the typed in-memory group catalog over a same-user local
socket and an authenticated **loopback-only** WebSocket. It has no UIKit or GPU
dependency. It does not yet supervise terminals/providers, persist workspace
state, acquire the workspace storage lock, discover existing agents or auto-spawn
from the editor. Every restart uses a fresh epoch; prior mutation outcomes become
unknown. Do not treat it as the completed M14 daemon or a remote deployment.

Build with `../haxeon/scripts/haxeon build --project agent/haxeon.json`.
The run arguments are `PRIVATE_SOCKET LOOPBACK_WS_PORT TOKEN_FILE FRESH_EPOCH`.
The caller must create a private owner-only directory (0700), keep the credential
file owner-only (0600), and supply a cryptographically generated 256-bit credential
as exactly 64 lowercase hex digits. Generate the epoch independently on every
startup; it is public protocol metadata and must never contain the credential.
Credentials are read from a file rather than command arguments and are not logged.
The bootstrap assumes this caller-controlled configuration; it is not yet the
managed credential/discovery lifecycle needed by the shipped application.

NativeKit enforces private-path/same-user checks on the local listener. WebSocket
clients prove possession of the credential before RPC negotiation or dispatch.
Plain loopback WebSocket has no network encryption. Remote access still requires
the planned authenticated secure relay and endpoint/session authorization.

Run the real transport tests with `bash scripts/test-workspace-transport.sh`.
For each `wasm-gc` and `wasm32`, run
`bash scripts/build-workspace-rpc-browser.sh TARGET` followed by
`python3 scripts/test-workspace-rpc-browser.py`. The browser fixture needs the
sibling Emsdk installation and Chrome/Chromium. It starts a separate daemon,
authenticates, suspends/reconnects, restarts the daemon with a fresh epoch, and
verifies snapshot restoration. Temporary credentials and child processes are
cleaned up. The browser page is a test client, not the Exosuit web application.
