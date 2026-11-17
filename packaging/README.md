# Exosuit

Run `./exosuit [project-directory] [file ...]` from any working directory. The archive
contains the UIKit editor, matched HashLink VM and runtime, native libraries,
language server, standard library, workspace service, reference defaults
and license notices.

Linux x86-64 requires the host libraries used by NativeKit: OpenGL, Fontconfig,
FreeType, GTK 3, WebKitGTK 4.1, OpenSSL 3 and Python 3 (Codex proxy). UIKit discovers system fonts through
Fontconfig. No source checkout is required to launch the editor or bundled server.

Configuration and state paths are documented in `docs/configuration.md`.
Set `PRAGTICAL_PORTABLE` to keep both under one chosen directory. The launcher
sets `HAXEON_LSP` to the bundled server unless explicitly overridden.

Opening a workspace asks exohost for its service, which exohost starts when none runs: one process per running workspace
(`tools/hl tools/exosuit-agent.hl --workspace ID --folder F...`). Busy agent turns keep it up; otherwise it stops ten
minutes after its last client leaves (`EXOSUIT_SERVICE_IDLE_SECONDS` changes that), retaining its SQLite catalog.
Terminals keep running in their terminal hosts and the next service takes them back. Its state, with its
`service.log`, lives below `$XDG_STATE_HOME/exosuit/workspaces/<id>`. exohost stops a service with `exohost kill <pid>`.

Native Claude Code session naming uses a pinned Claude Agent SDK metadata adapter. Build preparation installs only that package with optional executables and peer dependencies omitted; the release includes the SDK and its upstream README/legal notice under `tools/claude-naming`. Node.js 18.14 or newer is required on the workspace host for this optional feature. The daemon does not download dependencies, launch Claude, or send model requests to read or rename a session. Without the adapter/runtime, the UI offers an explicitly local Workbench label instead.
