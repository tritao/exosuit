# ADR 0002: Adopt NativeKit UIKit host and haxeon.json manifest builds

Status: accepted

Supersedes: [0001-platform-boundary.md](0001-platform-boundary.md)

## Decision

Pragtical Haxeon migrates from a custom SDL host to the standard NativeKit
`DesktopUiHost` and adopts haxeon.json manifest-driven builds. The host owns
window, GPU, input, and application loop lifecycle; editor code implements
the reloadable `DesktopUiApplication` interface. The native layer decouples
from rendering and adopts UIKit's generic platform abstraction.

Build configuration moves from shell scripts targeting a sibling realtime-haxe
repository to haxeon.json manifests built with `haxeon build --project
graphical/haxeon.json` and run with `haxeon run --project ... -- args`.

## Implementation

### Manifest split: headless core + graphical layer

To avoid requiring every headless test project to build UIKit's GPU stack
(harfbuzz, websockets, sokol, skribidi, nanovg), the project uses **two
separate build manifests**:

**`haxeon.json`** (headless core):
- Entry point: `app.Main`
- Dependencies: NativeKit, UIKit, EditorKit (as Haxe packages, no native build)
- Native ABI: `native/headless/platform.c`, `native/ffi/pragtical_hx.c`
- Provides: Editor model, document/session, workspace, commands, plugins
- Used by: Headless test projects and library consumers

**`graphical/haxeon.json`** (graphical application):
- Entry point: `app.GraphicalMain`
- Dependencies: headless core (`pragtical_hx`), UIKit, EditorKit, native UIKit
  toolkit (`exosuit-ui-native`)
- Provides: Complete editor shell with docking workspace, tabs, text editing
- Built via: `scripts/build.sh` and `scripts/run.sh`

This split was a deliberate deviation from the literal instruction to switch
the root manifest's own entry: doing that would have required every test
project to link UIKit's GPU toolkit, a measured, severe regression to the
test suite's build time per-project. The root manifest remained focused on
model and behavior testing; the graphical layer is entirely opt-in.

### Architecture

```
┌───────────────────────────────────────────────────────────┐
│ DesktopUiHost (nativekit.ui.host)                         │
│ • Window, GPU, input, main loop lifecycle                │
│ • Runs app.GraphicalMain                                 │
└────────────────────┬────────────────────────────────────┬─┘
                     │                                    │
        ┌────────────┴────────────┐        ┌──────────────┴──────┐
        │                         │        │                     │
    ┌───▼──────────────┐   ┌─────▼──────┐ │ ┌──────────────────┐│
    │ UIKit Components │   │ NativeKit  │ │ │ ExosuitApp       ││
    │ • Layout system  │   │ • Dialogs  │ │ │ (DesktopUiApplication)
    │ • Text widgets   │   │ • Clipboard│ │ │ • Model state    ││
    │ • Docking        │   │ • Shell    │ │ │ • View tree      ││
    └──────────────────┘   └────────────┘ │ │ • Commands       ││
                                          │ └──────────────────┘│
                                          │                     │
    ┌─────────────────────────────────────┴─────────────────────┐
    │ Headless Core (pragtical_hx)                              │
    │ • TextBuffer, Document, DocumentManager                   │
    │ • Workspace, Project workspace, build tasks              │
    │ • Language services, plugins, session recovery            │
    │ • Platform ABI (file system, processes, OS handles)      │
    └───────────────────────────────────────────────────────────┘
```

Application code (`ExosuitApp`, in `graphical/src/ui/ExosuitApp.hx`) owns only the view
tree, model bindings, and command dispatch. It does not own window, rendering,
or layout—those are handled by `DesktopUiHost` and UIKit. The host calls:
- `app.view()` to build the current UI tree
- `app.submit(frame)` to layout and render
- `app.dispose()` on shutdown or reload

### Document model: TextBuffer + TextDocument mirroring

The editor's document is split between two layers:

- **TextBuffer** (exosuit's native model, `src/editor/TextBuffer.hx`) — maintains
  undo/redo history, document state, and notifies subscribers (plugins, LSP
  clients) of edits.
- **TextDocument** (UIKit's text widget model, `nativekit.editorkit.TextDocument`)
  — the text value shown and edited in `TextArea`.

When a user types in the text widget:
1. `TextArea` mutates the shared `TextDocument`
2. `TextArea` emits an `EditTransaction`
3. `ui.EditorPane` captures the transaction
4. `TextBuffer.applyEditTransaction()` replays it as a normal `replace()` call
   into the buffer's undo stack (with mirroring suppressed for that one call to
   avoid feedback loops)

This design ensures:
- Plugins and LSP subscribers see all edits, whether from widget, buffer API, or
  search/replace
- TextArea's Ctrl+Z and TextBuffer's Ctrl+Z stay in sync
- The old command-driven interface and new widget-driven interface coexist

### Text rendering: EditorGutter + TextArea

The document editor is built from:

- **`ui.EditorPane`** — a scrollable container holding gutter + text area
- **`ui.EditorGutter`** — a custom View rendering line numbers
- **`TextArea.withDocument()`** — UIKit's text widget

Both gutter and TextArea are children of a single `ScrollView`, so they scroll
in sync by construction.

Limitations in current UIKit TextArea:
- **Syntax highlighting** is not wired to the document widget
- **Line wrapping** is not supported
- **Multi-cursor editing** is not exposed by the editor widget
- **Context menus** (right-click) are not implemented

### Native ABI and platform decoupling

The editor bridge uses ordinary C symbols declared in
`include/pragtical_hx/native.h`, with generated `.hxi`/`.hxmap` bindings,
explicit UTF-8 strings, 32-bit booleans and retained callback ownership.
The ABI is version 18. See [native-bindings.md](../native-bindings.md).

`native/headless/platform.c` implements deterministic platform services for
model tests, including window/font/draw APIs still consumed by the headless
renderer and benchmarks. `native/ffi/pragtical_hx.c` exposes those services
through the portable C ABI. The graphical host owns its actual window, input,
clipboard and GPU rendering. The previous custom SDL host and renderer are
removed.

### Command palette and UI shell

The graphical UI provides an `AppShell`, `DockWorkspace`, document tabs,
`TextArea`/gutter editing, and a command palette. `ExosuitApp` pumps the shared
`core.Application` controllers each frame. `CommandBridge` exposes their
commands with live enabled states and supported shortcuts.

Problems reads the shared diagnostic registry; Build Output reads the running
task's output and exposes diagnostic activation. Hover, completion and
signature-help overlays are wired to the language controller. Activation opens
the relevant document, but model selection does not yet move or reveal the
widget's caret. These connections are compile-verified; real-window acceptance
remains pending in M8.3.

Remaining graphical gaps:
- Syntax spans, diagnostic/plugin decorations and search highlighting are not rendered.
- Language overlays have no caret anchor.
- Workspace search stores results but has no visible results panel.
- One editor region means split, pane focus and moving tabs between panes are unavailable.
- Editor, tab and file-tree command menus use UIKit popups and CommandRegistry.
  Right-click, Shift+F10 and the Menu key open them; targets and predicates are
  checked again before activation. Wrapping remains a gap.

Tab reordering and sidebar visibility are wired. Layout-only legacy commands
are excluded by `CommandBridge`; other commands are bridged, with some shortcut
keys unavailable in the current UIKit key mapping.

## Migration from 0001

**Previous (0001):**
- Custom SDL loop in native/host/main.c
- Pragtical renderer integrated into Haxe via custom GLContext
- Ad-hoc shell script builds targeting ../realtime-haxe
- core.Application coupled to Renderer

**New (0002):**
- DesktopUiHost provides the event loop and window lifecycle
- UIKit renders via a generic Canvas abstraction
- NativeKit FFI provides platform services without exposing SDL
- haxeon.json manifest drives reproducible builds
- app.GraphicalMain implements DesktopUiApplication
- core.Application unchanged (for headless tests); ui.ExosuitApp is the new
  graphical entry

## Ownership and lifecycle

- **Host** owns window, GPU, input devices, and main loop
- **UIKit/NativeKit** own the widget tree, layout, rendering, and event dispatch
- **ExosuitApp** owns model state, documents, session, and command dispatch
- **Reload** replaces the application instance; host loop and widgets continue
- **Headless tests** use core.Application directly, skip DesktopUiHost entirely

Callbacks from native code flow through `DesktopUiHostContext`, never directly
into application code. Events are pulled on the host's main thread at a defined
safe point.

## Compiler and acceptance state

Both reference and self-hosted graphical builds pass. Haxeon's compiler now
bootstraps to identical output. Build, run and test use the CLI's reference
compiler default with a verified self-hosted override. The upstream action
directory fix (`c59502ff`) is used directly; the pre-creation workaround is gone.

Source plugins embed the public compiler/runtime package, compile on a worker,
and publish at editor updates. Their SDK registers a portable host HXI and
propagates host callback errors through checked responses. Shutdown retires
callbacks and tokens; initialization reinstalls callbacks after restart.

Every headless project, including mandatory source-plugin acceptance, passes in
both compiler modes. Release packaging, the real LSP smoke gate and UIKit window
automation still need restoration. The [execution ledger](../roadmap/STATUS.md)
records commands and remaining checks; graphical builds do not establish
interactive behavior.

## Trade-offs and follow-on work

Separate manifests keep model tests independent of UIKit's native GPU build.
The shared controllers preserve editor behavior while host adapters expose
it through widgets. M9/M10 complete styled text, visible selection/navigation,
pane operations, search surfaces and language UI behavior. Compiler/runtime
embedding restores source plugins in M8; M8.3 restores release and integration
gates. See the [roadmap](../roadmap/README.md) for dependencies and acceptance.
