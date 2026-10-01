# M10 — Haxeon language services in the UIKit shell

Depends on M8, and on M9.1/M9.2 for decorations and anchored popups. The M6.3
client, transport and controller already exist. The gap is configuration,
lifecycle and UI. The reference behavior is Pragtical's
`data/plugins/haxeon.lua` and `docs/haxeon.md`.

## M10.1 — Configuration and lifecycle

- [ ] Add `plugins.haxeon`-equivalent configuration: `enabled`, `command`
  (argument list), `verbose`. Keep the resolution order: config, then
  `$HAXEON_LSP`, then the bundled server, then
  `$HAXEON_ROOT/scripts/haxeon-lsp`. `HAXEON_ROOT` defaults to `../haxeon`.
- [ ] Start the server automatically when a `.hx` document opens in a
  project, and stop it when the last one closes or the project changes.
  Restart on crash with backoff, and surface failures in status and problems.

Acceptance: opening a `.hx` file starts exactly one server. Killing it
externally leads to a visible restart. A wrong command produces a clear,
recoverable error.

## M10.2 — Feature UI

- [ ] Completion list UI with filtering, accept and dismiss. Hover and
  signature help popups (M9.2 anchoring).
- [ ] Gate document symbols, find references and rename on negotiated
  capabilities. Show references in a navigable list. Apply rename through the
  existing revision-checked transactional workspace edits.
- [ ] Bridge these commands into the palette with shortcuts.

Acceptance: the fake-server tests are extended to symbols, references and
rename, including a stale-revision rename that is rejected. The real Haxeon
smoke (M8.3) is extended so that on this repository it diagnoses, fixes,
completes, goes to definition and renames a local symbol.

Exit: the edit/build/diagnose/fix cycle works on this repository inside the
graphical editor.
