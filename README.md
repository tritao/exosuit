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

Haxeon is pinned as a submodule at `haxeon`, including its UI,
platform, GPU, and NativeKit dependencies. Initialize the submodules and
bootstrap the compiler before building:

```sh
git submodule update --init --recursive
./haxeon/scripts/bootstrap-tools.sh
(cd haxeon && ./scripts/build-native.sh)
```

EditorKit and SceneKit still come from sibling Materia directories:
`../editorkit` and `../scenekit`. The `editorkit` symlink connects
Haxeon's UI package to that same EditorKit checkout. Keep Exosuit in the
Materia workspace for these dependencies and the browser build helpers.
Manifests use Haxeon workspace entries to resolve SceneKit’s transitive
platform and GPU dependencies from this same Haxeon checkout.
`HAXEON_ROOT` and `HAXEON_BIN` can override the compiler used by scripts;
package manifests remain pinned to the submodule sources.

```sh
./scripts/build.sh
./scripts/run.sh [file or directory]
```

The graphical workbench follows the system light/dark preference on launch.
Use `./scripts/run.sh --theme=dark` or `--theme=light` to override it.
When no folder is open, the Explorer collapses to an Open Folder rail.

The graphical application builds from `graphical/haxeon.json` (entry
`app.GraphicalMain`). Headless tests build from `haxeon.json` (entry
`app.Main`); see `scripts/test.sh` for the test suite.

Haxeon and its nested dependencies are pinned by Git submodule commits.
Use `git submodule update --init --recursive` after pulling dependency updates.

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
hot reloads pass headless and real-window automation. Syntax colors, plugin
backgrounds, diagnostic wavy underlines and search highlights render through
retained UIKit text layouts. Bracket matches and full-width current-line
backgrounds follow the shared primary caret. Multiple selections/carets render,
and multi-caret insertion, cut/paste and deletion use buffer transactions.
Keyboard navigation moves all carets through UIKit's shaped layout.

- M9.1's accepted Linux typing runs measured 37.79 ms p95 for small Unicode,
  39.47 ms for a 1 MiB single line and 30.96 ms for 10 MiB multiline text.
  Unchanged shaped rows retain their identity; see the execution ledger for scope.
- Primary caret/selection changes now flow between the widget and model, including
  command-driven placement. Language popups follow the visible caret and dismiss
  when scrolling clips it or the active document changes.
- Files and Search share a sidebar with persisted mode, visibility and separate
  widths. Search provides virtualized results, navigation and transactional
  replacement previews, and refreshes after open-document edits.
- Documents and terminals share editor tab bars across DockWorkspace splits.
  Pane focus, tab movement and pane closure are available through commands;
  sessions preserve pane membership, selections, scroll and terminal profiles.
- Wrapped text shares its shaped geometry with the gutter and selection. Editor,
  tab and file-tree command menus support right-click, Shift+F10 and the Menu key.
- Editor wheel scrolling uses configurable time-based smooth motion. Physical
  IME and non-Linux acceptance remain pending.

Both compiler modes, release packaging and real-window automation pass the
claimed Linux scope in [M8](docs/roadmap/08-uikit-baseline.md). See the
[execution ledger](docs/roadmap/STATUS.md) for current verification evidence.

See [docs/architecture/0002-nativekit-uikit-host.md](docs/architecture/0002-nativekit-uikit-host.md)
for migration notes and implementation details.

## Implementation roadmap

See the [implementation roadmap](docs/roadmap/README.md) for ordered milestones,
acceptance checks and the core compiler typing policy. The
[overnight handoff](docs/roadmap/OVERNIGHT.md) provides a launch prompt, and the
[execution ledger](docs/roadmap/STATUS.md) tracks resumable progress.
