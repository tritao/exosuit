# M10 — Haxeon language services in the UIKit shell

Depends on M8, and on M9.1/M9.2 for decorations and anchored popups. The M6.3
client, transport and controller already exist. The gap is configuration,
lifecycle and UI. The reference behavior is Pragtical's
`data/plugins/haxeon.lua` and `docs/haxeon.md`.

## M10.1 — Configuration and lifecycle

- [x] Add `plugins.haxeon`-equivalent configuration: `enabled`, `command`
  (argument list), `verbose`. Keep the resolution order: config, then
  `$HAXEON_LSP`, then the bundled server, then
  `$HAXEON_ROOT/scripts/haxeon-lsp`. `HAXEON_ROOT` defaults to `../haxeon`.
- [x] Start one server lazily per workspace folder when its first `.hx` document
  opens. Route documents/settings by owning root, including nested roots.
  Keep sessions across tab switches and last-document closure; stop on folder
  removal or explicit Stop. Reconfigure only the affected folder.
  Restart on crash with backoff, and surface failures in status and problems.

Acceptance: opening a `.hx` file starts exactly one server. Killing it
externally leads to a visible restart. A wrong command produces a clear,
recoverable error. Multiple and nested folders route documents independently;
last-document closure retains sessions and folder-local configuration changes
leave other folders' sessions running.

## M10.2 — Feature UI

- [x] Completion list UI with filtering, accept and dismiss. Hover and
  signature help popups (M9.2 anchoring).
- [x] Gate document symbols, find references and rename on negotiated
  capabilities. Show references in a navigable list. Apply rename through the
  existing revision-checked transactional workspace edits.
- [x] Bridge these commands into the palette with shortcuts. Completion uses
  Ctrl+Space, hover Ctrl+Alt+Space, signature help Ctrl+Shift+Space, definition
  Ctrl+Alt+G, symbols Ctrl+Shift+G, references Ctrl+Shift+H and rename Ctrl+Alt+H.
  Unsupported commands leave keyboard input unconsumed.

Acceptance: the fake-server tests are extended to symbols, references and
rename, including a stale-revision rename that is rejected. The real Haxeon
smoke (M8.3) is extended so that on this repository it diagnoses, fixes,
completes, goes to definition and renames a local symbol.

Exit: the edit/build/diagnose/fix cycle works on this repository inside the
graphical editor.

Linux automation accepted: `scripts/test-real-language-ui.sh` drives the real
server through graphical diagnosis, prefix completion, definition navigation,
rename, transactional undo/redo and saving a disposable fixture. The fixture
then builds and exits with 42. A second run exercises repository source through
unsaved overlays and verifies that the file on disk remains unchanged. This
gate is included in `scripts/ci.sh`. Fake-server and popup regressions cover
capabilities, stale edits, filtering, long-list navigation and normalized
composition handoff. Physical OS IME and other-platform qualification remain
outside this Linux automation claim.
