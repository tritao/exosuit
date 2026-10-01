# Browser editor

The browser hosts the same UIKit editor and controllers as the desktop. Its
filesystem lives in the Haxeon guest's memory for the current page session;
reloading starts a fresh seeded `/workspace/Main.hx`. Changes do not reach the
checkout or persist across page reloads. Save writes to this session filesystem.
Native process, LSP, source-plugin compilation, terminal and local control
commands are unavailable. Open File and Open Folder use the path command view.

`./web/build.sh` builds a Wasm32 guest and Emscripten host, checks their C import
signatures and assembles `build/web/site`. It uses materia's shared `tools/web` manifest
walker and HXI generators, the reference editor's host/loader design and Haxeon's
`haxeon-host.js`. Both modules share a checked linear-memory partition. Fonts
are bundled through BrowserUiFontAsset.

Set `EXOSUIT_WEB_TARGET=wasm-gc` to select the GC guest. Set
`EXOSUIT_WEB_BUILD_DIR` to keep each target's artifacts separately. The toolchain
comes from `../haxeon` and `../nativekit/.tools/emsdk`, with `HAXEON_DIR` and
`EMSDK_DIR` overrides. Guest compile errors terminate the build; stale output
cannot qualify a failed compile.

`./web/test.sh` uses installed Chrome and SwiftShader with a disposable profile.
It checks rendering, real keyboard editing, dirty tracking, save/readback, URL
opening and a fresh page reload. Any console or page error fails the check.
`EXOSUIT_WEB_SITE_DIR` selects a previously built site; `EXOSUIT_WEB_BROWSER`
selects Chrome. `--screenshot PATH` preserves the fresh session and a `-edited` capture of the
Unicode document before reload.

The loader's `window.exosuit` report includes lifecycle, frame count, unavailable
imports and a snapshot function. The snapshot crosses the host boundary as
UTF-8 JSON; it does not inspect backend-specific Haxe object layouts.

Browser qualification is tracked in `docs/roadmap/STATUS.md`; do not infer a
passing smoke check from a successful artifact build.

`EXOSUIT_CI_WEB=1 ./scripts/ci.sh` adds both guest builds and browser smokes to
composed CI. `EXOSUIT_CI_WEB=1 ./scripts/test-web.sh` runs that browser stage
alone. Its artifact trees are isolated by target. The stage reports `PENDING`
when not selected or when Emscripten or Chrome is unavailable.
