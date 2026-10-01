# M15 — Web target

Depends on M9 and M10. M12–M14 are not required, because those features are
disabled on the web. References: Pragtical `docs/web.md`,
`scripts/test-web.py`; UIKit `host/BrowserUiHost.hx`, `tools/build-web.sh`,
`tools/showcase-wasm.sh`; Haxeon `wasm32`/`wasm-gc` targets. Haxeon reports
that `run` is not wired for wasm, so drive the browser with its own script.

## M15.1 — Capability guards

- [ ] Add a typed capability query (clipboard, filesystem, processes,
  threads, local IPC, terminal, language services, url). Disable or hide
  commands, panels and sidebar modes whose capability is missing. Never let
  them throw at use time.

Acceptance: a headless test with a capability-restricted host shows no command
that would fail. Process, LSP, terminal, Workbench and threaded search are
absent or degrade with a clear message.

## M15.2 — Browser build

- [ ] Compile the shell as a `wasm32` guest against UIKit's wasm bindings and
  host it with `BrowserUiHost`. Use an in-memory filesystem with a seeded
  sample project. Open URLs with `window.open`.
- [ ] Add `scripts/build-web.sh` and `scripts/serve-web.sh` that output to
  `dist/web`, and pin the Emscripten version.

## M15.3 — Browser smoke

- [ ] Add a Playwright Chromium smoke test. It waits for a painted canvas,
  types, saves, verifies the in-memory file, reloads, and fails on any console
  or page error.

Acceptance: the smoke test passes locally and joins `scripts/ci.sh` behind an
opt-in flag when Chromium is unavailable.
