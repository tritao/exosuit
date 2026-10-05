# NativeKit and UIKit integration

The graphical application runs on the NativeKit `DesktopUiHost` with UIKit
widgets. This is the standard desktop platform for Haxeon applications.

## Architecture

- **NativeKit** (platform layer) provides file dialogs, clipboard, shell
  operations, and platform event dispatch via `DesktopUiHostContext`.
- **UIKit** (component framework) provides layout, widgets, text editors
  (`TextDocument`, `TextArea`), docking workspaces, menus, and popups.
- **DesktopUiHost** (host) owns the window, GPU context, and main loop;
  it instantiates and manages the application instance.
- **EditorKit** (editor widget API) provides the `TextDocument` model and
  `EditTransaction` interface used to track and apply edits.

## Build manifests

The project uses two separate build manifests:

- **`haxeon.json`** (headless core) — entry `app.Main`, depends on NativeKit
  and UIKit as Haxe packages (no native compilation). Used by headless tests
  and as the base for the graphical layer.
- **`graphical/haxeon.json`** (graphical application) — entry
  `app.GraphicalMain`, depends on the headless core and includes
  `uikit-native` (which builds UIKit's native GPU toolkit via CMake).

Keeping these separate ensures headless tests do not require building UIKit's
GPU stack, reducing build cost and complexity.

## Document mirroring: TextBuffer and TextDocument

The editor's document model is split between two layers:

- **TextBuffer** (editor's native model) — maintains undo/redo history,
  document state, and notifies subscribers (plugins, language services) of
  all edits through its own API.
- **TextDocument** (UIKit's text widget model) — the text value shown and
  edited in `TextArea`, backed by EditorKit.

When a user types in the text widget, the `TextArea` emits an `EditTransaction`.
`ui.EditorPane` captures this and calls `TextBuffer.applyEditTransaction()`,
which replays the transaction as a normal `replace()` call into the buffer's
undo stack (with mirroring suppressed for that one call to avoid feedback loops,
since the widget already mutated the shared document).

This design ensures:
- Plugins and LSP subscribers see all edits, whether they come from the text
  widget, buffer API, or search/replace operations.
- TextArea's own Ctrl+Z (via TextDocument) and TextBuffer's Ctrl+Z stay in
  sync, editing the same underlying document.
- The old command-driven text interface and the new widget-driven interface
  coexist without duplication.

## Application integration

Create an application class implementing `haxeon.ui.host.DesktopUiApplication`:

```hx
class ExosuitApp implements DesktopUiApplication {
  final context:DesktopUiHostContext;

  public function new(context:DesktopUiHostContext) {
    this.context = context;
    context.onCloseRequested = function(close:Void->Void) {
      // Handle close request, then call close()
    };
  }

  public function view():View { ... }
  public function submit(frame:LayoutFrame):RenderNode { ... }
  public function context():UiContext { ... }
  public function dispose():Void { ... }
  public function diagnosticState():Dynamic { ... }
}
```

Open it with `DesktopUiHost.open()`:

```hx
var options = new DesktopUiHostOptions();
options.title = "Exosuit";
options.width = 1320;
options.height = 900;

return DesktopUiHost.open(options, function(context:DesktopUiHostContext) {
  return new ExosuitApp(context);
});
```

The host calls:
- `app.view()` to build the current UI tree (called on every frame)
- `app.submit(frame)` to layout and prepare render commands
- `app.dispose()` on shutdown or reload

## File dialogs and clipboard

`NativeDesktopServices` wraps NativeKit's FFI for file/folder dialogs, clipboard
operations, and shell invocation:

```hx
// File dialogs via NativeKit
var file = await services.chooseFile({ title: "Open File", ... });

// Clipboard
services.setClipboardText(text);
var text = services.getClipboardText();

// Shell
services.openFileManager("/path");
services.openUrl("https://...");
```

See `src/NativeDesktopServices.hx` for the full API.

## Text rendering and gutter

The document editor is built from:

- **`ui.EditorPane`** — a scrollable container holding both the gutter and text area
- **`ui.EditorGutter`** — a custom View that renders line numbers beside the text
- **`TextArea.withDocument()`** — UIKit's text widget, backed by a shared
  `TextDocument`

Both the gutter and TextArea are children of a single `ScrollView`, so they
scroll in sync by construction. The gutter re-renders line numbers on every
frame; the TextArea handles text rendering, selection, and input.

Current limitations:
- **Line wrapping** is not implemented; long lines scroll horizontally.
- **Syntax highlighting** requires manual span insertion into the `TextDocument`.
- **Multi-cursor editing** is not exposed by the current UIKit TextArea API.

## Headless (non-graphical) builds

The headless core (`haxeon.json`, entry `app.Main`) builds without UIKit:

```json
{
  "version": 1,
  "package": { "name": "pragtical_hx" },
  "entry": "app.Main",
  "sourceRoots": ["src"],
  "dependencies": {
    "nativekit": { "path": "../nativekit" },
    "haxeon-ui": { "path": "haxeon/packages/ui" },
    "haxeon-editor": { "path": "haxeon/packages/editor" }
  },
  "ffi": {
    "interfaces": ["bindings/pragtical_hx.hxi"],
    "projections": ["bindings/pragtical_hx.hxmap"]
  },
  "native": {
    "cmake": { "source": "native", "target": "pragtical_hx", "library": "pragtical_hx" }
  },
  "target": "host"
}
```

See [the native binding contract](native-bindings.md) for generation and callback ownership.

This build targets the headless platform (no window, no GPU). The main entry
point runs Haxe code directly without a host loop. All headless test projects
depend on this core manifest as `"pragtical_hx"`.

## Known gaps and working around them

### Dynamic plugins
Plugin discovery and manifest-based plugins are implemented, but **dynamic
plugin compilation** (compiling user `.hx` files at runtime and loading them)
is stubbed. This requires embedding Haxeon's compiler and runtime libraries
as package dependencies, which is not yet wired in `haxeon.json`.

### LSP and language services
The UI shell structurally provides a "Problems" panel and a "Build Output"
panel, but they show placeholder messages. Wiring them to the language client
and build system is out of scope for this port.

### Command palette
A small set of new commands is registered directly to UIKit's command registry
(New, Open, Open Folder, Save, Close Tab, Toggle Palette). Exosuit's existing
~45 commands (doc:*, root:*, project:*) are not ported, because they were
written against concepts (pane layouts, editor splits, LayoutNode) that don't
semantically map onto the new DockWorkspace/Tab architecture.

Text editing itself (typing, cut/copy/paste, in-widget undo) goes through
TextArea's native EditHistory, not through exosuit's command system.

### Completion and context menus
Right-click context menus and code completion popups are not implemented.

### Text styling and multi-cursor
The current UIKit TextArea/TextDocument API exposes only flat text with a
single selection. Styled spans and multi-cursor editing are not supported
by the widget API itself.
