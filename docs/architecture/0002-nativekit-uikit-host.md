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
- Native ABI: `native/headless/platform.c`, `native/hashlink/pragtical_hx.c`
- Provides: Editor model, document/session, workspace, commands, plugins
- Used by: Headless tests, 12 test projects, library consumers

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

Application code (`ExosuitApp`, in `src/ui/ExosuitApp.hx`) owns only the view
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
- **Syntax highlighting** requires manual span insertion (not implemented)
- **Line wrapping** is not supported
- **Multi-cursor editing** is not exposed by the API
- **Context menus** (right-click) are not implemented

### Native ABI and platform decoupling

The native layer remains unchanged from 0001:
- `native/headless/platform.c` — minimal platform ABI (file system, processes)
- `native/hashlink/pragtical_hx.c` — FFI bindings (clipboard, shell, etc.)
- No window management, main loop, or SDL directly referenced from Haxe

Rendering and window management are now owned by `DesktopUiHost` + UIKit,
not by custom native code. The old SDL rendering paths (`native/host/main.c`,
`native/pragtical/renderer_backend.c`) are deleted.

### Command palette and UI shell

The graphical UI provides:
- **AppShell** — top-level layout (title bar, menubar, status bar)
- **DockWorkspace** — docking panels (Explorer, Editor tabs, Problems, Build Output)
- **TextArea + EditorGutter** — text editor in tabs
- **Command palette** — a small set of new commands (New, Open, Save, etc.)

**Not ported (documented scope cut):**
- Language services (LSP client, problem panel) — structurally present, shows placeholder
- Build tasks output — structurally present, shows placeholder
- ~45 existing commands (doc:*, root:*, project:*) — require LayoutNode/pane concepts
  that don't map to DockWorkspace/Tab architecture
- Dynamic plugins — discovery exists, but compilation is stubbed
- Completion, context menus, multi-cursor editing — not supported by current UIKit API

The new UI is a working graphical shell that replicates the core editing
experience; it is not a 1:1 port of the old renderer-driven architecture.

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

## Known Haxeon tool issues and workarounds

Two pre-existing, external Haxeon bugs were discovered and worked around:

1. **Generic resolution bug in --self-hosted mode**: Haxeon's precompiled
   bootstrap (compiler.hl) has a confirmed bug when resolving generics through
   `nativekit.ui.widgets.text.TextField` → `ComboBox`'s `Array<SelectOption<T>>`
   ("Type \"SelectOption\" does not accept type arguments"). The graphical build
   uses the normal reference-Haxe bootstrap instead (now reliable after a WIP
   compiler change landed). Headless tests use --self-hosted (default) to avoid
   a separate reference-compiler bug in ConfigurationController.hx:1886.

2. **Directory-creation race in Haxeon's executor**: Haxeon's parallel action
   executor can race two worker threads creating `build/.haxeon/actions` on the
   first build, causing a hang. Pre-creating the directory in build.sh/run.sh/test.sh
   sidesteps this entirely. This is an external, read-only tool issue.

## Trade-offs and limitations

- **Not a 1:1 port**: The new graphical UI prioritizes a working shell over
  preserving every legacy feature. Commands, plugins, and language services are
  present but not wired to the old architecture.
- **No automatic command migration**: Existing commands were rewritten to assume
  UIKit widget semantics; automatic translation would have been incorrect.
- **UIKit API limitations**: Syntax highlighting, multi-cursor, and context menus
  are constrained by what the current TextArea/TextDocument expose.
- **Build cost trade-off**: Using separate manifests adds some maintenance burden
  but preserves test suite speed and clarity of intent (core vs. graphical).

## Future work

- Wire language services and build output to the Problems and Build Output panels
- Implement context menus and code completion popups
- Port remaining commands once DockWorkspace/Tab semantics are fully understood
- Support syntax highlighting via TextDocument span insertion
- Embed Haxeon's compiler/runtime to enable dynamic plugin compilation
