# Exosuit

Exosuit is an editor and agent workbench written in Haxeon. Its parts are the desktop editor (`graphical/`), suit,
the per-user daemon that owns the machine's workspaces and is the control plane (`suit/`), one workspace service
process per running workspace with terminal hosts that outlive it (`agent/`), and remote clients on the phone
(`android/`) and in the browser (`web/`) that reach a machine through a relay (`relay/worker/`). How they fit together:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build and run

Haxeon is pinned as a submodule at `haxeon`, including its UI,
platform, GPU, and NativeKit dependencies. Initialize the submodules and
bootstrap the compiler before building:

```sh
git submodule update --init --recursive
./haxeon/scripts/bootstrap-tools.sh
(cd haxeon && ./scripts/build-native.sh)
```

`HAXEON_ROOT` and `HAXEON_BIN` can override the compiler used by scripts;
package manifests remain pinned to the submodule sources.

```sh
python scripts/build.py
python scripts/run.py [file or directory]
```

Development runs through `scripts/run.py` (or `scripts/run.sh`) enable core dumps
up to the shell's hard limit. Native text-layout creation failures print their
failure stage, resource slot, and layout parameters, then abort before exception
cleanup so the native state is preserved in a dump. Set
`EXOSUIT_DEV_CORE_DUMPS=0` to retain normal error-return behavior. Packaged launches
do not enable this diagnostic mode. On Linux with systemd-coredump, inspect a
failure with `coredumpctl info <pid>` and `coredumpctl debug <pid>`.

On Windows, build everything with the Visual Studio 2026 toolchain from any
PowerShell prompt (no developer shell needed):

```powershell
scripts/build-windows.ps1 -Clean     # wipe build outputs, bootstrap Haxeon, build the app
scripts/build-windows.ps1 -SkipBootstrap   # rebuild only the app
```

It loads the newest Visual Studio 2026 x64 environment and uses that install's
bundled CMake, because a system CMake older than 4.2 builds the app's native
packages with Visual Studio 2022 instead. Pass `-Clean` after switching
toolchains; CMake will not reuse a build directory made by another generator.

To use a native Haxeon executable instead, point `HAXEON_BIN` to it:

```powershell
$env:HAXEON_BIN = 'C:\path\to\haxeon.exe'
python scripts/build.py
python scripts/run.py
```

Tests: `./scripts/test.sh` (Linux) or `scripts/test-windows.ps1`. They run against an isolated suit home and state,
never the user's (see "Tests and isolation" in the architecture page). On Windows, launch programs and tests through
`docs/benchmarks/perf-harness/run-guarded.ps1` (`CLAUDE.md`).

The graphical application builds from `graphical/haxeon.json` (entry `app.GraphicalMain`). Headless tests build from
`haxeon.json` (entry `app.Main`). More in [docs/getting-started.md](docs/getting-started.md).

## Editing

The editor uses the real Haxeon language server. Completion popups use theme colors,
show symbol kinds and provider details/documentation, and support arrow navigation,
Tab/Enter acceptance, Escape dismissal, and mouse selection. Filtering preserves
provider order and insertion text. Go to Definition supports F12 and Ctrl+Alt+G,
Ctrl+click, and the editor context menu. Go to Type Definition is available in the
command palette and editor context menu. Both navigation commands can use current
syntax facts when dependency analysis fails. Recovery follows declared types and
imports and refuses ambiguous names. Blocked requests report the compiler error and source location.
Multiple results open a searchable picker;
Alt+Left and Alt+Right return through definition navigation history. Missing results
and server failures appear as notifications. An early F12 waits for server startup
and document synchronization while the file and cursor remain unchanged. After
200 ms, the status bar shows initialization, synchronization, or definition lookup
progress; editing, moving the cursor, or changing tabs cancels the request. Navigation
outranks background semantic coloring and interrupts diagnostics, which resume afterward.
With verbose Haxeon logging enabled, navigation logs include readiness and total time,
and server timing notifications separate queue wait, analysis, and execution time.

The graphical workbench follows the system light/dark preference on launch.
Use `python scripts/run.py --theme=dark` or `--theme=light` to override it.
When no folder is open, the Explorer collapses to an Open Folder rail.

In the source editor, Tab advances to the next indentation stop at the caret;
with selected text it indents the affected lines. Shift+Tab unindents, and
Backspace in leading whitespace returns to the preceding indentation stop.
Enter preserves indentation and adds a level after a code opening bracket;
between matching brackets it creates an indented middle line. These edits
respect the configured tab width and spaces/tabs setting and support multiple
carets. Existing tab characters render at the same configured stops, with matching
caret, selection, and mouse geometry; their width scales with the editor font.
Ctrl+M toggles Tab between indentation and keyboard focus navigation.

Indentation resolves each setting from a document override, explicit project/user
settings, `.editorconfig`, detected file style, then defaults. Detection samples
meaningful lines on opening and stays stable while typing; ambiguous files keep
their defaults. Explicit settings take precedence even when they equal a default.
The status-bar indentation control shows the effective style and its source and
opens a document-only override picker; Automatic restores normal resolution.

The indentation adapter reads `indent_style`, `indent_size`, and `tab_width` from
ancestor `.editorconfig` files, including section globs, `root`, and `unset`.
Widths from 1 to 16 are supported; indentation size and hard-tab display width
may differ. Other EditorConfig properties are not applied. See the
[EditorConfig specification](https://spec.editorconfig.org/) for those rules.

Haxe Enter uses shared structural context for brackets, switch cases, continued
expressions, and unbraced control bodies. Comments and strings do not contribute
brackets, and incomplete code uses conservative fallback behavior. Reindent
Selection and Reindent Document are available in Commands for Haxe files; each
changes leading indentation as one undoable operation, preserving selections
and multiline literal/comment contents. Opening a file never rewrites whitespace.

The command palette exposes **Format Document** and **Format Selection** when the
Haxe language server advertises those capabilities. Formatting uses the resolved
document indentation settings and is undoable. Replies are discarded if the
document, selection, active view, or server session changes while waiting. The
bundled Haxeon server supports explicit formatting, but does not advertise
on-type formatting; Enter therefore uses the local indentation policy. Reindent
remains a separate, whitespace-only operation.

## DevTools

Run Exosuit with a separate Haxeon DevTools window and an available HLDI profiler endpoint:

```sh
python scripts/devtools.py --launch-exosuit
```

For an existing development session, use **Developer: Open DevTools** in the command palette.
`python scripts/run.py --open-devtools` opens the inspector at startup. These paths provide UI
frame metrics without function instrumentation. Function sampling additionally requires a runtime
launched with `hl --diagnostics PORT`; pass `--profiler-port=PORT` to `scripts/devtools.py`, or set
`EXOSUIT_DEVTOOLS_PROFILER_PORT` before opening DevTools from Exosuit. HLDI supports one profiler
client at a time, so use either DevTools or the `--profile` recorder for that endpoint.

DevTools shows CPU frame history, phase durations, heap/GC counters, a live render tree, computed
properties with style provenance, and a selection overlay in the application. **Follow hovered
widget** follows the target's hovered element. **Track widget invalidations and paint** enables
bounded per-frame widget events; selecting an event selects its widget in the current application.
Properties always describe the current tree, even when an older frame is selected. The frame chart
measures UI submission and rendering CPU time; background polling, host preparation, GPU execution
and end-of-frame GC are outside that total. Use HLDI/Perfetto for the broader trace. Paint durations
measure custom Haxe painters; native rendering and layout durations remain frame-level totals.

The viewer polls at most four times per second and retains 240 frames and up to 1000 tree nodes.
Payload limits may reduce the visible tree further. Truncation and frame-history gaps are reported.
Closing or disconnecting the viewer clears highlighting and detailed probes. The local endpoint is
created only on demand, in a private directory on Unix or a same-user named pipe on Windows.

**Start sampling** uses 250 Hz sampling. **Record HLPC** records through the existing HLDI client;
**Stop capture** ends the sampling session before closing the capture. **Export Perfetto trace**
writes a `.pftrace` beside that file for full trace analysis. Choose the output with
`--capture-path=/absolute/path/session.hlpc`. An existing capture can be viewed as a report with
`python scripts/devtools.py --profile-capture=/path/session.hlpc`.

**Save inspection** writes `<capture-path>.ui.json`, containing the retained frame metrics, compact
tree, selected widget properties and selected frame's widget events. Open it with
`python scripts/devtools.py --inspection-capture=/path/session.hlpc.ui.json`.
This is a saved inspection snapshot; it does not reconstruct every widget's properties at every frame.

The native UI libraries must be built as for the editor. The launcher adds the standard
`haxeon/out/packages/ui/native` library directories and preserves an existing library search path.
The viewer uses NativeKit's bounded local transport. HLDI decoding runs in a bootstrap-Haxe helper
process, reusing `ProfilerService`; its output worker coalesces live snapshots so a slow viewer does
not block the decoder. Runtime profiler buffer pressure is still visible through its stall counters.

## Local stable build

Save the current host build outside the disposable build directories, then launch
it without rebuilding from the checkout:

```sh
python scripts/stable.py save
python scripts/stable.py launch
python scripts/stable.py rollback
python scripts/stable.py status
```

Snapshots are stored under the Git-ignored `.local/stable/<platform>/` directory.
Stable opens with a separate title, settings and workspace-agent state. Run `save`
after building the app and agent; each snapshot includes its own language-server
launcher. The tool retains the current and previous snapshots and removes older
ones only after their app, language server and workspace agent have stopped.
On Windows, taskbar pins use the promoted launcher and icon under the stable
directory, so reopening restores the stable environment and follows the current
snapshot after saves or rollbacks.

## Icon

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

## Browser build

`./web/build.sh` builds the editor for the browser and `./web/test.sh` checks it through headless Chrome; see
[web/README.md](web/README.md).

## Documents

| Document | What |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | suit, the editor, workspace services, terminal hosts, devices, the control plane, tests |
| [docs/ROADMAP.md](docs/ROADMAP.md) | open work |
| [docs/architecture/](docs/architecture/) | decision records |
| [docs/design/](docs/design/) | the Workbench and suitctl designs, terminal hosts, agent sessions, the sessions UI |
| [docs/RPC-VECTORS.md](docs/RPC-VECTORS.md) | the workspace protocol's frozen wire vectors |
| [suit/README.md](suit/README.md), [agent/README.md](agent/README.md) | suit and the workspace service |
| [docs/mobile/](docs/mobile/) | the phone app, its local end-to-end rig, the relay |
| [docs/getting-started.md](docs/getting-started.md), [docs/configuration.md](docs/configuration.md), [docs/recovery.md](docs/recovery.md), [docs/build-tasks.md](docs/build-tasks.md), [docs/plugin-development.md](docs/plugin-development.md), [docs/plugin-api.md](docs/plugin-api.md) | using and extending the editor |
| [docs/nativekit.md](docs/nativekit.md), [docs/native-bindings.md](docs/native-bindings.md) | the native layer |
| [docs/haxeon-compiler-bugs.md](docs/haxeon-compiler-bugs.md), [docs/compiler-typing.md](docs/compiler-typing.md) | compiler bugs met here, and the typing policy |
