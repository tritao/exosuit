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

The text model is supplied by `haxeon/packages/editor` (`haxeon.editor`).
The desktop build uses the Haxeon submodule and its nested native dependencies.
The browser build still uses Materia’s SceneKit and browser build helpers.

`HAXEON_ROOT` and `HAXEON_BIN` can override the compiler used by scripts;
package manifests remain pinned to the submodule sources.

```sh
python scripts/build.py
python scripts/run.py [file or directory]
```

On Windows, point `HAXEON_BIN` to the native Haxeon executable:

```powershell
$env:HAXEON_BIN = 'C:\path\to\haxeon.exe'
python scripts/build.py
python scripts/run.py
```

The graphical workbench follows the system light/dark preference on launch.
Use `python scripts/run.py --theme=dark` or `--theme=light` to override it.
When no folder is open, the Explorer collapses to an Open Folder rail.

In the source editor, Tab advances to the next indentation stop at the caret;
with selected text it indents the affected lines. Shift+Tab unindents, and
Backspace in leading whitespace returns to the preceding indentation stop.
Enter preserves indentation and adds a level after a code opening bracket;
between matching brackets it creates an indented middle line. These edits
respect the configured tab width and spaces/tabs setting and support multiple
carets. Ctrl+M toggles Tab between indentation and keyboard focus navigation.

The graphical application builds from `graphical/haxeon.json` (entry
`app.GraphicalMain`). Headless tests build from `haxeon.json` (entry
`app.Main`); see `scripts/test.sh` for the test suite.

The desktop window icon is embedded in the app and packaged runtime. To update it,
edit `graphical/assets/icons/exosuit-mark.svg` or the background in
`scripts/generate-icon.py`, then run:

```sh
python -m pip install cairosvg pillow
python scripts/generate-icon.py
python scripts/build.py
```

The generator refreshes `icon.png`, the SVG and PNG assets, and
`graphical/src/app/ApplicationIcons.hx`. Normal builds use the checked-in embedded
pixels and do not require the image-generation dependencies.

Haxeon and its nested dependencies are pinned by Git submodule commits.
Use `git submodule update --init --recursive` after pulling dependency updates.

See [the NativeKit UIKit host architecture](docs/architecture/0002-nativekit-uikit-host.md).

## Architecture

The graphical editor runs on a separate build manifest (`graphical/haxeon.json`)
to avoid requiring every headless test project to link UIKit's GPU toolkit.
The headless core (`haxeon.json`) provides the editor's model layer, platform
ABI, and command infrastructure; the graphical layer adds the UI shell,
docking workspace, and document rendering.

Text editing is backed by `haxeon.editor.TextDocument`, which the editor's
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
