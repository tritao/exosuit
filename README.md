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

## Known limitations and open gaps

- **Dynamic plugins** are stubbed; the plugin discovery infrastructure exists,
  but compiling and hot-loading plugins requires Haxeon's compiler/runtime
  packages as a manifest dependency (not yet available).
- **Language services and diagnostics** (LSP client, problem panel) are
  structurally present but show a placeholder message; the new UI does not
  wire them to the backend.
- **Build output panel** is structurally present but shows a placeholder message.
- **Multi-cursor editing** and **styled/syntax-colored text spans** are not
  exposed by the current UIKit TextDocument/TextArea API.
- **Context menu popups** (right-click) are not implemented.
- **Command palette** replicates only a small set of new commands (New, Open,
  Open Folder, Save, Close Tab, Toggle Palette); exosuit's own ~45 commands
  (doc:*, root:*, project:*) are not ported, as they were written against
  concepts (pane layouts, editor splits) that don't semantically map onto the
  new DockWorkspace/Tab architecture.

See [docs/architecture/0002-nativekit-uikit-host.md](docs/architecture/0002-nativekit-uikit-host.md)
for migration notes and implementation details.

## Implementation roadmap

See the [implementation roadmap](docs/roadmap/README.md) for ordered milestones,
acceptance checks and the core compiler typing policy. The
[overnight handoff](docs/roadmap/OVERNIGHT.md) provides a launch prompt, and the
[execution ledger](docs/roadmap/STATUS.md) tracks resumable progress.
