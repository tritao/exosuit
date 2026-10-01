# Getting started

## Prerequisites

Haxeon, NativeKit, and UIKit checkouts are required. Clone or symlink them
beside this repository:

```sh
cd ..
git clone https://github.com/haxeon/haxeon.git
git clone https://github.com/nativekit/nativekit.git
git clone https://github.com/uikit/uikit.git
git clone https://github.com/editorkit/editorkit.git
cd exosuit
```

Or set paths in `graphical/haxeon.json` under `dependencies`.

System libraries (Linux x86-64):
- SDL 3 development headers
- FreeType development headers
- HarfBuzz development headers
- CMake 3.24+
- Haxe compiler (via Haxeon)
- HashLink runtime 1.14+

## Build and run

Build the graphical application:

```sh
./scripts/build.sh
```

Run the application:

```sh
./scripts/run.sh [file or directory]
```

For example:

```sh
./scripts/run.sh .
./scripts/run.sh src/Main.hx
```

To pass additional arguments, append them:

```sh
./scripts/run.sh --smoke-frames=60 --capture-dir=/tmp myfile.txt
```

## Development

For iterative development, rebuild and rerun:

```sh
./scripts/build.sh && ./scripts/run.sh
```

## Headless tests (no UI, no window)

The test suite exercises the headless core (`haxeon.json`, entry `app.Main`)
and a suite of headless test projects under `tests/*/`:

```sh
./scripts/test.sh
```

This runs 11 test projects plus a headless platform ABI check, covering
document persistence, editor operations, language services, plugins, and
workspace operations.

## Build manifest structure

The project uses **two separate build manifests** for practical reasons:

- **`haxeon.json`** — headless core (entry `app.Main`), provides the editor's
  model layer, document/session management, platform ABI, workspace, and
  command infrastructure. No UIKit dependencies; used by headless tests.
- **`graphical/haxeon.json`** — graphical layer (entry `app.GraphicalMain`),
  depends on UIKit and NativeKit for the shell, docking workspace, text editor
  widget, and file dialogs. Linked through `uikit-native`, which builds UIKit's
  native GPU toolkit.

This split avoids requiring every headless test to build and link UIKit's full
GPU stack (harfbuzz, websockets, sokol, skribidi, nanovg). The core manifest
remained focused on model and behavior testing; the graphical layer is entirely
opt-in.

See [0002-nativekit-uikit-host](architecture/0002-nativekit-uikit-host.md) for
architecture details and migration notes.

## Configuration and plugins

See [configuration](configuration.md) for user/project layers and portable mode,
[build tasks](build-tasks.md) for deliberate project processes, and
[plugin development](plugin-development.md) for built-in plugin support.
Relative font paths in settings resolve beside the settings file; built-in font
paths resolve beside the installed executable.

**Note:** Dynamic plugin compilation (loading user-authored .hx plugins at
runtime) is currently stubbed and requires Haxeon's compiler/runtime packages
as manifest dependencies.
