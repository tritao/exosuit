# M8 — Green baseline on the NativeKit UIKit host

Depends on M7 and the UIKit port (`89d2694`, ADR 0002). The port replaced the
SDL host and the realtime-haxe scripts, but its gates were not re-established.
Nothing after M8 may claim completion while these gates are red.

Observed on 2026-10-01 at `ae2f260`:

- `./scripts/test.sh` compiles the headless core, then HashLink aborts with
  `Invalid signature for function pragtical_hx@last_error : P_OBi_ required but
  P_B found in hdll`. Current Haxeon types `@:hlNative` `String` as a HashLink
  string object (`_STRING`). `native/hashlink/pragtical_hx.c` still declares
  `_BYTES` (`vbyte*`) for every string parameter and return, including the
  `plugin_api_*` closures. `last_error` also returns raw UTF-8 where UTF-16 is
  expected.
- `./scripts/build.sh` fails in the reference compiler with
  `commandview/CommandView.hx:297:16: E1005: Field "entries" requires an object`.
- Existing workarounds hide typing defects: `test.sh` defaults to
  `--self-hosted` (cites `ConfigurationController.hx:1886`, "Field "current"
  requires an object"). `build.sh` avoids `--self-hosted` because of the
  `SelectOption` generic-resolution bug. The `build/.haxeon/actions` mkdir race
  in `test.sh` is a Haxeon executor defect.
- `scripts/ci.sh` no longer runs the release packaging or the real Haxeon LSP
  smoke. The SDL automation scripts (`test-sdl-*.sh`) were deleted, and nothing
  replaces them.

## M8.1 — Native string convention

- [x] Move `pragtical_hx` to the NativeKit binding convention: a C header
  plus generated `.hxi`/`.hxmap`, with UTF-8 `utf8` strings
  (`haxeon/docs/C_HEADER_FFI.md`). This is required, not preferred. The wasm
  guest (M15) can only import C-ABI HXI functions, and `@:hlNative` has no
  browser equivalent. Use Haxeon's native callback support for the plugin API
  closures (`19fc2fd9`, "native callbacks through exported entry functions").
  If a closure still cannot be expressed, reduce it and fix Haxeon; do not
  keep `@:hlNative`.
- [x] Convert every string-carrying function in `src/platform/Native.hx` and
  the native side together. Fix UTF-8/UTF-16 handling, and remove or
  regenerate the stale `include/pragtical_hx/native_ffi.h`.
- [x] Delete externs that the UIKit host made dead (window, font and draw), or
  record why they stay. Keep `platform/abi.json` and its `--check` gate
  consistent, and bump the ABI version if compatibility changes.

Acceptance: `./scripts/test.sh` passes every headless test project. A
non-ASCII error message, clipboard string, process output and plugin API
string all round-trip unchanged.

## M8.2 — Compiler defects behind the build split

- [x] Reduce `CommandView.hx:297` E1005, `ConfigurationController.hx:1886` and
  the self-hosted `SelectOption` failure to minimal cases. Add regressions in
  Haxeon and fix the general typing rule (COMPILER-TYPING). Do not rewrite
  application code to evade them.

  Evidence: CommandView has a reduced effect regression. The historical
  ConfigurationController/SelectOption failures do not reproduce after the
  source update and converged bootstrap; both actual UIKit builds pass. See
  STATUS for classification rather than claiming invented reducers.
- [x] Make reference and self-hosted builds agree. Then remove the divergent
  `HAXEON_SELF_HOSTED` defaults from `test.sh` and `build.sh`, or document a
  remaining unrelated reason.
- [x] Fix the action-directory creation race in Haxeon's executor and drop the
  `mkdir -p` sidestep.

Acceptance: `./scripts/build.sh` and `./scripts/test.sh` pass with both compiler
modes. Haxeon's own `./scripts/test.sh` passes.

## M8.3 — Restore release and integration gates

- [x] Port `scripts/test-haxeon-lsp.sh` and the release packaging
  (`release.lock`, `scripts/test-release.sh`) to the manifest layout. Pin
  Haxeon, NativeKit, UIKit and EditorKit revisions instead of the Pragtical
  renderer.
- [x] Replace the deleted SDL automation with a real-window, scripted UIKit
  route: open project, edit, save, palette, problems, build output, reload.
  Inspect UIKit/NativeKit for existing automation or test-input hooks before
  adding one. If no display is available, record the check as pending; do not
  fake it.
- [x] `scripts/ci.sh` composes the compiler, headless, graphical-build,
  LSP-smoke and release gates again.

Acceptance: `./scripts/ci.sh` exits 0 on Linux. The graphical route passes
under a real or virtual display, or is recorded as pending with the reason.

## M8.4 — Truthful documentation

- [x] Update README "Known limitations" and ADR 0002 to match the code. The
  problems panel, build output and LSP commands are wired. Decorations, caret
  anchoring, the search panel, pane operations and context menus are not.

Exit: green gates, no hidden workarounds, and an accurate gap list feeding M9/M10.
