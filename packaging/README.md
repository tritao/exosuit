# Exosuit

Run `./exosuit [project-directory] [file ...]` from any working directory. The archive
contains the UIKit editor, matched HashLink VM and runtime, native libraries,
language server, standard library, workspace daemon and manager, reference defaults
and license notices.

Linux x86-64 requires the host libraries used by NativeKit: OpenGL, Fontconfig,
FreeType, GTK 3, WebKitGTK 4.1, OpenSSL 3 and Python 3 (workspace manager). UIKit discovers system fonts through
Fontconfig. No source checkout is required to launch the editor or bundled server.

Configuration and state paths are documented in `docs/configuration.md`.
Set `PRAGTICAL_PORTABLE` to keep both under one chosen directory. The launcher
sets `HAXEON_LSP` to the bundled server unless explicitly overridden.

Opening a folder starts or reuses its bundled workspace daemon. Authenticated
local or browser clients keep it alive; after the last disconnect it stops after
one minute, retaining its SQLite catalog. Current terminals and providers are
not yet daemon-owned. The future runtime manager must also keep the service alive
while owned sessions run.

For explicit availability without clients, start
`python3 tools/run-agent.py /path/to/workspace --detach --always-available`, or set
`EXOSUIT_AGENT_ALWAYS_AVAILABLE=1` before starting the editor. This applies to new
daemons; it does not change an already-running daemon's policy. It keeps the
loopback service available, but away-from-home connectivity still needs the
planned secure relay. Discovery and state live below `$XDG_STATE_HOME/exosuit`.
Send SIGTERM to the descriptor's manager PID to explicitly stop the service.
