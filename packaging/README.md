# Exosuit

Run `./exosuit [file-or-directory]` from any working directory. The archive
contains the UIKit editor, matched HashLink VM and runtime, native libraries,
language server, standard library, reference defaults and license notices.

Linux x86-64 requires the host libraries used by NativeKit: OpenGL, Fontconfig,
FreeType, GTK 3, WebKitGTK 4.1 and OpenSSL 3. UIKit discovers system fonts through
Fontconfig. No source checkout is required to launch the editor or bundled server.

Configuration and state paths are documented in `docs/configuration.md`.
Set `PRAGTICAL_PORTABLE` to keep both under one chosen directory. The launcher
sets `HAXEON_LSP` to the bundled server unless explicitly overridden.
