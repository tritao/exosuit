# M15 — Web target

Depends on M8.1 and M8.2. M9 and M10 are not required. M12–M14 native features are
disabled in standalone browser mode. [M16](16-remote-workspaces.md) extends
this same web build with connected workspace capabilities, including
away-from-home access; its acceptance is separate from the M15 baseline.

Reuse the pipeline from materia's reference editor rather than inventing one:

- `../app/web/` (`build.sh`, `test.sh`, `README.md`, `materia.js`,
  `host.cpp`, `CMakeLists.txt`, `tools/`) and `../app/src/MainWeb.hx`.
- Haxeon `stdlib/haxeon/wasm/haxeon-host.js` (Haxeon `e9d31520` "describe the
  Wasm host ABI", `65592ea0` "wasm-gc: load the editor in Chrome") and
  `docs/WASM_BACKEND.md`.
- NativeKit `docs/wasm-host-memory.md` and `tools/setup-web.sh`.

The output is two modules sharing one linear memory:

- A Haxeon **guest** (`wasm32` by default, `wasm-gc` opt-in), compiled from an
  exposed browser entry point.
- An Emscripten **host** linking NativeKit and UIKit, which exports every C
  function the guest imports.

`haxeon build` cannot target wasm32 yet. Like `app/web/build.sh`, derive the
guest compiler arguments from the manifest. Pragtical's `docs/web.md` and
`scripts/test-web.py` define the feature-level behavior to match.

## M15.1 — Native boundary and capability guards

- [x] Everything the guest imports must be C-ABI HXI bindings. If any
  `@:hlNative` (`pragtical_hx`) code remains after M8.1, migrate it, or keep it
  behind a host-only interface that the browser build replaces. The browser
  host provides no processes, PTY, local IPC, SQLite or threads.
- [x] Add a typed capability query (clipboard, filesystem, processes,
  threads, local IPC, terminal, language services, url). Hide or disable
  commands, panels and sidebar modes whose capability is missing; never let
  them throw at use time. The reference app shows the pattern:
  `window.materia.unavailable` lists the kits that only have stubs.

Acceptance: a headless test with a capability-restricted host shows no command
that would fail. Process, LSP, build tasks, terminal, Workbench and threaded
search are absent or degrade with a clear message.

## M15.2 — Browser build

- [x] Add a `web/` directory to exosuit. It needs:
  - an `app.WebMain` entry point with `@:expose` `configure`, `main` and
    `frame`, hosted by `BrowserUiHost`;
  - `build.sh` that generates wasm32 HXI interfaces for the kits, compiles the
    guest against a memory contract, links the Emscripten host with generated
    exports, runs `check-imports.js` and assembles `build/web/site`;
  - `index.html` and a loader based on `haxeon-host.js`.

  Factor shared tooling (`guest-arguments.py`, `check-imports.js`,
  `generate-wasm-hxi.sh`) out of `app/web/tools` into a shared location rather
  than copying it, if materia accepts that change. Otherwise vendor it with a
  note.
- [x] Use an in-memory filesystem seeded with a sample project. Open URLs with
  `window.open`. Bundle fonts as `BrowserUiFontAsset`s.
- [x] Build both `wasm32` and `wasm-gc` guests; `wasm32` is the default.

## M15.3 — Browser smoke

- [x] Add `web/test.sh`, modeled on `app/web/test.sh`: headless Chrome on
  SwiftShader. Extend it with Pragtical's checks: type text, save, verify the
  file in the in-memory filesystem, reload, and fail on any console or page
  error.

Acceptance: the smoke test passes for both guest targets. It joins
`scripts/ci.sh` as an opt-in stage, which records "pending" when Emscripten or
Chrome is unavailable.
