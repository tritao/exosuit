# Pragtical Haxeon

An editor implementation with its application core written in Haxeon,
built on the NativeKit UIKit desktop host and Haxeon manifest builds.

The NativeKit `DesktopUiHost` owns the window, GPU context, input devices,
and main event loop. Application code (`ExosuitApp`) implements the
reloadable `DesktopUiApplication` interface and manages editor state,
documents, view trees, and command dispatch. UIKit provides layout,
text widgets, docking workspace, and platform dialogs; NativeKit provides
clipboard, file dialogs, and native services.

## Build and test

Install Haxeon and place this repository alongside checkouts of `nativekit`,
`uikit`, `editorkit` and `haxeon` (the materia workspace layout), or set their
paths in graphical/haxeon.json:

```sh
cd exosuit
./scripts/build.sh
./scripts/run.sh [file or directory]
```

The graphical application builds from `graphical/haxeon.json` (entry
`app.GraphicalMain`). Headless tests build from `haxeon.json` (entry
`app.Main`); see `scripts/test.sh` for the test suite.

For CI or reproducible builds, pin dependency versions in haxeon.json.

See [the NativeKit UIKit host architecture](docs/architecture/0002-nativekit-uikit-host.md).

## Architecture

The graphical editor runs on a separate build manifest (`graphical/haxeon.json`)
to avoid requiring every headless test project to link UIKit's GPU toolkit.
The headless core (`haxeon.json`) provides the editor's model layer, platform
ABI, and command infrastructure; the graphical layer adds the UI shell,
docking workspace, and document rendering.

Text editing is backed by `nativekit.editorkit.TextDocument`, which the editor's
`TextBuffer` mirrors to enable plugin/LSP subscriber access to all edits
regardless of whether they originate from the text widget, buffer API, or
search/replace operations.

## Browser build

`./web/build.sh` builds the editor with a session filesystem in the browser.
`./web/test.sh` checks real keyboard editing and saving through headless Chrome.
Both Wasm targets are supported; see [web/README.md](web/README.md) for setup,
capabilities and the opt-in CI stage.

## Known limitations and open gaps

The UIKit shell uses the shared application controllers. The Problems panel
reads live diagnostics, Build Output streams task output with clickable
locations, and the palette exposes bridged document, project, build and
language commands. Hover, completion and signature-help overlays are wired.
Source plugins use the embedded compiler/runtime; compatible and structural
hot reloads are covered by mandatory headless acceptance. Interactive acceptance
on the UIKit host remains pending.

- Styled syntax spans, diagnostic/plugin decorations and search highlights
  are not rendered in the document widget.
- Navigation updates the model selection but cannot yet move or reveal the
  widget's caret. Language popups are not anchored to that caret.
- Workspace search results are retained by the host but have no graphical panel.
- The shell has one editor region. Split, pane focus and moving tabs between
  panes are unavailable; tab reordering and sidebar visibility are wired.
- Multiple selections, line wrapping and right-click context menus remain gaps.
- Some legacy shortcut keys lack a UIKit key mapping; their bridged commands
  are still available from the palette.

Compiler-mode agreement, release packaging and real-window automation are
still being restored in [M8](docs/roadmap/08-uikit-baseline.md). See the
[execution ledger](docs/roadmap/STATUS.md) for current verification evidence.

See [docs/architecture/0002-nativekit-uikit-host.md](docs/architecture/0002-nativekit-uikit-host.md)
for migration notes and implementation details.

## Implementation roadmap

See the [implementation roadmap](docs/roadmap/README.md) for ordered milestones,
acceptance checks and the core compiler typing policy. The
[overnight handoff](docs/roadmap/OVERNIGHT.md) provides a launch prompt, and the
[execution ledger](docs/roadmap/STATUS.md) tracks resumable progress.
