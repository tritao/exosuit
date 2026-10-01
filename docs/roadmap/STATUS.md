# Execution ledger

Last updated: 2026-10-01.

## Current checkpoint

- **M8.1 and M8.2 accepted headlessly in both compiler modes.** Exosuit
  `95a3b08` restores source plugins and makes their full test mandatory.
  Graphical builds and all headless projects exit 0 in reference and refreshed
  self-hosted modes. Haxeon `82d92ba0` passes 375/375 and every integration/Wasm
  stage; bootstrap converges and rebuilds identically.
- **M8 accepted on Linux:** restored composed CI exits 0 after b76554b, and
  the changed graphical entry point builds in self-hosted mode as well.
- **M15 accepted on Linux/Chrome:** both guest targets build with matching
  C imports and pass actual Unicode edit/save/readback/URL/reload smoke. The
  browser stage is wired into composed CI through `EXOSUIT_CI_WEB=1`; absent
  toolchains remain explicitly pending.
- Active task: **M9.1**, styled text and decorations on UIKit.
- Exact resume: add general styled/decorated text ranges to retained UIKit text
  layout, with affected-row invalidation, and wire existing syntax, diagnostics,
  search/bracket/current-line and normalized multi-selection models into the
  editor. Preserve M8 and both browser gates; measure the M7.1 typing budget.
- All further graphical tests must use disposable PRAGTICAL_PORTABLE state.
  IME, physical mixed-DPI transitions, Windows and macOS remain unclaimed.
- HEADs at planning: exosuit `ae2f260` (`haxeon-uikit-port`). Materia `main` is at
  `816372dd`, fast-forwarded 2026-10-01 for the Haxeon wasm and web fixes; it
  contains uikit and editorkit. Haxeon is at `fba71015` (on pin, fast-forwarded).
  NativeKit is at `2bb4c957` (`materia-numeric-locale`, off-pin, local). Pragtical
  is at `50644c91` (`next`, read-only reference, dirty smooth-scroll work).
- The baseline failures below were observed before the Haxeon and materia
  fast-forward. Re-run both gates at the start of M8.
- The UIKit port (`89d2694`, ADR 0002) invalidates M0–M7 runtime evidence for the
  graphical product. Those records stay as history; M8 re-establishes the gates.
- Baseline failures at `ae2f260`:
  - `./scripts/test.sh`: the headless core compiles, then HashLink aborts with
    `Invalid signature for function pragtical_hx@last_error : P_OBi_ required but
    P_B found in hdll`. Every `String` extern has the same mismatch (M8.1).
  - `./scripts/build.sh`: `commandview/CommandView.hx:297:16: E1005: Field
    "entries" requires an object` in the reference compiler (M8.2).
- Previous checkpoint (M0–M7 complete headlessly on the SDL host): editor `354f0e8`, Haxeon `83a2749`.

## Milestones

| Milestone | State | Evidence / remaining gate |
| --- | --- | --- |
| M0 | Complete on Linux | M0.1/M0.2 complete; `test-sdl-workflow.sh` covers the complete M0.3 route through a real SDL window |
| M1 | Complete headlessly | Stable pathless identity, atomic persistence, Save As, unified close/quit, external conflicts and bounded recovery pass; graphical prompt smoke remains in the M0.3 manual route |
| M2 | Complete headlessly | Everyday editing, clipboard/navigation, coding transformations and normalized multiple selections pass; graphical keyboard/mouse smoke remains in M0.3 |
| M3 | Complete headlessly | Reusable command input, pane/tab/sidebar navigation, logical-point DPI routing, status, bounded feedback, error inspection and centralized UI roles pass; interactive M0.3 smoke remains |
| M4 | Complete headlessly | Responsive index/search, safe replacement, recoverable file operations and defensive sessions pass; graphical smoke remains in M0.3 |
| M5 | Complete headlessly | Live layered configuration, owned APIs, debounced background compilation, transactional reload and editor lifecycle controls pass |
| M6 | Complete headlessly | Bounded JSON-RPC, lifecycle/synchronization, language commands, diagnostics, restart and real Haxeon edit/diagnose/fix/build smoke pass |
| M7 | Complete for the claimed Linux automation scope | M7.1–M7.3 pass; desktop IME, physical mixed-DPI, Windows and macOS remain explicit unclaimed follow-ons |
| M8 | Accepted on Linux | Both compiler modes, mandatory source plugins, real LSP/window workflow and unpacked release; composed CI exits 0 |
| M9 | Active: M9.1 | General styled text/decorations and editor rendering |
| M10 | Not started | Depends on M8, M9.1–M9.2 |
| M11 | Not started | Depends on M8; independent of M9/M10 |
| M12 | Not started | Depends on M9, M11.1, M11.4 |
| M13 | Not started | Depends on M11.2 |
| M14 | Not started | Depends on M11–M13 |
| M15 | Accepted on Linux/Chrome | Both guest targets, typed capabilities, Unicode editing/save/URL/reload, matching C imports and opt-in browser CI |

## Implementation records

### M9.1 — diagnostic/search presentation and paint revisions (verified slice)

- EditorPane maps plugin-owned decorations and current search matches from
  UTF-16 columns to codepoint ranges for visible chunks. PluginDecorationKind
  preserves existing background defaults and adds wavy underlines. Language
  diagnostics request severity-colored underlines, including one segment for
  each nonempty line of a multiline range; the fingerprint includes severity.
- Cached language diagnostics transform through BufferChange before the next
  server publication, follow undo, and remove deleted nonempty ranges. Existing
  version checks still reject stale server publications. Headless tests cover
  Unicode mapping, offscreen filtering, removal, stale search revisions,
  diagnostic movement and stopped-service clearing. Focused tests pass:
  `/tmp/exosuit-m9-decorations-focused.log`, diagnostics-live and controller logs.
- Added a real-window decoration fixture and pixel check using Xvfb/Pillow,
  wired into composed CI. Initial fresh-window check passed. Strengthening it
  to warm retained text before changing/clearing marks exposed 32 stale red
  underline pixels after clearing (`/tmp/exosuit-m9-decoration-retained-pixels.log`).
  A temporary fixture parse failure was a missing closing brace and was fixed.
- Root cause: retained text painting was keyed solely by measurement/geometry.
  Materia `23397690` adds paint-only invalidation and TextField presentation
  revisions/provider-change detection. EditorPane retains stable provider
  callbacks and advances its revision for text, palette, registry and search
  changes. Display lists remain cached when presentation is unchanged.
- Strengthened real-window pixel checks now pass
  (`/tmp/exosuit-m9-decoration-repaint-pixels.log`): underline and search
  background render, move after a Unicode line insertion, and clear after
  several warm frames. UIKit full framework gate passes
  (`/tmp/uikit-m9-presentation-revision-framework.log`), verifying repaint and
  clearing independently of measurement version/height and unchanged-list reuse.
- Exosuit `6c04c14` commits the editor wiring, model repair, retained pixel
  fixture and composed-CI stage. Complete gates exit 0:
  `/tmp/exosuit-m9-decorations-tests-final.log`, build-verified and
  self-build-verified logs, real-lsp, workflow, release and web logs.
  Both wasm32 and wasm-gc browser smoke routes pass. The strengthened pixel
  fixture also passes self-hosted (`/tmp/exosuit-m9-decoration-self-pixels.log`).
  Release lock pins materia 23397690; Haxeon/NativeKit revisions are unchanged.
- No M9 acceptance box is checked; bracket/current-line, shared multi-selections,
  affected-row invalidation and typing-budget measurements remain pending.

### M9.1 — editor syntax and incremental initializer adapters (verified slice)

- EditorPane now requests visible syntax foreground ranges and uses the core
  editor palette for text, gutter and background. SyntaxPresentation maps the
  existing highlighter's UTF-16 tokens to absolute codepoint ranges, clips to
  requested chunks and omits normal tokens. Focused tests cover accents/emoji,
  clipping and multiline state repair after edits. The tokenizer now keeps
  operator-token boundaries outside surrogate pairs (astral characters outside
  strings previously split into invalid codepoint boundaries).
- Full headless gate exits 0 (`/tmp/exosuit-m9-syntax-tests.log`). Final reference
  and self-hosted graphical builds both exit 0 (the corresponding
  `/tmp/exosuit-m9-syntax-*-build-final.log` files).
- Desktop workflow rebuild failed before launching: cached compilation pruned
  `$function-adapter-env:nativekit.ui.style.StyleProperty.__init:0`, causing IR
  verification failure in `__init$part5`. Original failure log:
  `/tmp/exosuit-m9-syntax-desktop.log`. No desktop/release/browser success is
  claimed for this slice yet.
- Reduced to separate Values/Main modules: a static generic comparator passes
  cold, then a consumer-only edit fails with missing Values.__init adapter.
  Root cause: generated-function retention recognizes ordinary function origins
  but not initializer pseudo-bodies. Haxeon `a3b26edb` resolves initializer
  retention and invalidation through the owning class constructor, using
  existing ownership rules. Focused execution passes consumer edits, initializer
  replacement/restoration and existing invalid callable rejection cases.
  Compiler gate exits 0, 383/383 plus all integration/Wasm stages:
  `/tmp/haxeon-m9-static-adapter-gate.log`. Bootstrap converges after one
  self-host stage and rebuilds identically (the corresponding bootstrap logs).
- The repaired repeated desktop build passed, then plugin-driven editing
  exposed stale shared text during syntax painting. Widget replay globally
  disabled buffer-to-document mirroring while notifying subscribers; a nested
  plugin edit therefore updated buffer lines but not the shared TextDocument.
  A failing headless reducer confirms it (`/tmp/exosuit-m9-nested-edit-before.log`).
  Exosuit `18597b1` replaces mutable global suppression with an operation-local
  mirror argument, preserving nested edits. Focused document test exits 0
  (`/tmp/exosuit-m9-nested-edit-final.log`); full headless gate exits 0
  (`/tmp/exosuit-m9-syntax-tests-final.log`). Initial focused run used a relative
  fixture argument and failed file lookup; rerun uses the required absolute path.
- Desktop edit/save/plugin-reload and unpacked release gates pass after the
  repair (`/tmp/exosuit-m9-syntax-desktop-final.log` and release log). Both
  browser targets pass (`/tmp/exosuit-m9-syntax-web.log`). Captured pixels show
  actual syntax colors but exposed a light text-field background and fit-height
  tabs. Added explicit editor background and grow-height editor tabs; final
  palette gates all exit 0:
  `/tmp/exosuit-m9-syntax-palette.log`, `-self.log`, `-release.log`, `-web.log`.
  Both wasm32 and wasm-gc smoke routes pass. Inspected final desktop output
  frame: readable colored tokens, configured dark background, full-height pane.
  Release lock now pins Haxeon a3b26edb and materia 267bfa07.
- No M9 acceptance boxes are checked. Strict affected-row invalidation and
  p95 typing measurements remain pending. Cached highlighter state can require
  scanning preceding unvalidated lines; native retained chunks contain up to
  64 paragraphs. Next: wire diagnostics/search/bracket/current-line decorations
  and shared normalized selections/carets into the editor, with edit repair and
  clearing regressions, then affected-row invalidation and typing measurements.

### M9.1 — geometry decorations and missing-glyph carets (in progress)

- Added geometry-based background, whole-line background, straight and wavy
  underline capabilities. Background nodes precede selections; wavy paths clip
  to the horizontal viewport and decoration providers query visible chunks.
- Initial E1007 was an application flow error: an impure callback could replace
  the mutable nullable provider between loop iterations. Existing LoopFlowMain
  requires invalidating such field facts. Each paint layer now retains one
  provider for its entire pass; a regression replaces the field during the pass
  and verifies all three chunks still use that retained provider. No typing rule
  or application cast changed. Also corrected an absent overlay-style helper.
- Unicode geometry initially failed at an unsupported emoji: caret offset 3
  returned x=0, while neighboring carets were x=17.824 and x=25.872. The fixture
  loaded only IBM Plex Sans. Adding bundled NotoEmoji with FontFamily.Emoji
  makes the focused decoration test and complete framework gate pass:
  `/tmp/uikit-decorations-emoji-family.log` (0). Loading emoji as Default was
  insufficient because the shaping library requests the Emoji family.
- Missing-glyph caret behavior is a real independent native issue, now covered
  by a failing UIKit text-engine regression. Skribidi found style metadata but
  no caret position and skipped its nearest-run fallback. Its clean baseline
  is `7c31390` on nativekit-atlas-api; created exosuit-followon before the fix.
  Running the existing run-boundary fallback alone still failed when one run
  spanned the missing character. The fix retains the nearest canonical insertion
  position from the existing caret iterator, while preserving known style data.
  Skribidi `76a337e` includes its own unsupported-emoji regression; the complete
  `skribidi_test` suite exits 0 (`/tmp/skribidi-caret-tests.log`). Materia
  `254d2dbc` pins it and adds the UIKit regression. Four native checks pass:
  text_engine, compositor, frame_resources and layout_render_compiler.
  No baseline vendor edits existed.
- Materia `267bfa07` commits the decoration API and focused Unicode geometry,
  all four paint kinds, edit movement and provider snapshot coverage. Full
  framework gate exits 0 (`/tmp/uikit-decorations-caret-final.log`).
- Editor syntax wiring is in progress. The headless focused editor-view test
  passes (`/tmp/exosuit-m9-syntax-focused.log`), including UTF-16/codepoint
  conversion, visible clipping and multiline state invalidation after edits.
  The syntax slice and final native/browser gates are recorded above.

### M9.1 — TextArea presentation (in progress)

- Next design: a typed foreground provider receives each visible retained chunk's
  absolute codepoint range. This bounds syntax work to visible chunks and keeps
  provider results local; unchanged colors reuse native resource revisions.
  Backgrounds and underlines will reuse existing measured range rectangles.
- Materia `cfe3e241` adds the visible foreground provider to TextField/TextArea
  and retained editor layouts. Values clip to local codepoint ranges, unchanged
  colors avoid native updates, reshaped chunks reapply styles. Single-line fields
  retain styled content when a provider is set and keep placeholder behavior.
- Framework gate exits 0: `/tmp/uikit-text-area-colors-framework-final.log`.
  Coverage uses a 150-line accent/emoji fixture, verifies only the visible chunk
  requests colors, clipping and recoloring preserve measurement, overlap rejects
  and clearing works. Existing 4,000-node/input regressions pass.
- Both graphical compiler-mode builds exit 0:
  `/tmp/exosuit-m9-text-area-colors-build.log` and
  `/tmp/exosuit-m9-text-area-colors-self-build.log`. No compiler change.
- Exact next action: add background/underline/whole-line geometry decorations,
  then wire syntax/diagnostics into EditorPane and rerun both browser targets.
  Native retained layouts still group up to 64 paragraphs; strict changed-row
  invalidation and M7.1 measurements remain acceptance work, not a claimed pass.


### M9.1 — public foreground ranges and raster invalidation (foundation delivered)

- General C ABI `nkui_text_layout_set_color_ranges` copies sorted, disjoint
  codepoint ranges and rejects invalid colors, bounds, handles and overlap
  transactionally. Empty ranges clear; text/layout updates clear; base-color
  changes preserve overrides. ABI version 8 and both portable HXI regenerated.
- Typed `TextColorRange`/`TextLayout.setColorRanges` uses the existing native
  struct-array boundary. Mutable scaled glyphs and owned immutable snapshots
  both receive foreground ranges. Identical colors do not invalidate resources.
- A new actual pixel recolor test initially failed (red=0, stale green=36).
  Root cause: mutable retained text had no color revision in raster resource
  fingerprints. A text content revision now participates in both renderer
  bindings and advances on text/layout or color changes. The regression verifies
  green override plus blue base, cached repaint, live red recolor and range
  clearing on text replacement. No compiler workaround was needed.
- Native focused gate passes 6/6, including ABI, text engine, compositor,
  frame resources, layout render compiler and real Xvfb pixel rendering.
  `../uikit/tools/test-haxeon.sh` exits 0: actual typed array marshaling,
  rendered Canvas transaction, invalid overlap, unchanged measurement and
  Settings suite (`/tmp/uikit-color-ranges-haxeon.log`).
- Materia `f4313d4b` commits this public API slice. Exosuit root tests and both
  graphical compiler-mode builds exit 0, serially:
  `/tmp/exosuit-m9-color-ranges-tests.log`,
  `/tmp/exosuit-m9-color-ranges-build.log`,
  `/tmp/exosuit-m9-color-ranges-self-build.log`.
- Final `EXOSUIT_CI_WEB=1 ./scripts/test-web.sh` exits 0 for both guest targets
  with 107/104 matching imports and real Unicode edit/save/URL/fresh reload:
  `/tmp/exosuit-m9-color-ranges-web-final.log`. The first attempt failed once
  at reload with a guest frame error; its assertion omitted console details.
  Added console capture to failure assertions. Same linear artifact then passed
  the diagnostic run plus five fresh browser repetitions. That first transient's
  root cause remains unclassified; it is not silently treated as a passing run.
- Updated release pin to materia `f4313d4b`; new unpacked-release acceptance
  remains pending until the editor presentation slice. Exact next action:
  add visible retained foreground ranges and geometry-based decorations to
  UIKit TextArea, then wire the editor's syntax/diagnostics and selections.

### M9.1 — retained foreground ranges (in progress)

- Starting from accepted M15 commit `5a46f5c`, with materia `a9486f67`,
  Haxeon `02f924ed` and NativeKit `d12dd484`. Existing submodule-pointer dirt
  and Haxeon vendor/profile files remain outside this slice.
- Design: retain logical codepoint cluster ranges alongside prepared glyph quads.
  Sorted, disjoint foreground ranges recolor cached geometry using the cluster's
  first codepoint (a shaped ligature remains one color). Published snapshots
  include colors in their cache identity and remain immutable. Color changes
  must neither rebuild measured layouts nor rasterize glyphs. Line snapshots
  ignore ranges outside their logical line, preserving unaffected-row reuse.
- Materia `59cb6eaf` delivers the internal foreground-range foundation. Native
  tests cover geometry, clearing, immutable snapshots, unchanged-row cache reuse,
  rejected overlapping/reversed/negative ranges and codepoint metadata for
  accent, supplementary and RTL text.
- `cmake --build ../nativekit/build-ui --target
  nativekit_ui_text_engine_test nativekit_ui_frame_resources_test
  nativekit_ui_layout_render_compiler_test nativekit_ui_compositor_test -j 4`
  exits 0 (targets built serially in the same tree). Corresponding focused
  `ctest --test-dir ../nativekit/build-ui` selection passes 4/4; diff check passes.
  An initial test compile caught a duplicate local name; corrected before gates.
- Exact next action: expose foreground ranges through the C ABI and typed
  UIKit TextLayout/TextArea APIs, including mutable and owned renderer paths.
  Background/underline/whole-line, editor wiring and acceptance remain pending.


### M15.1–M15.3 — browser editor and composed acceptance (accepted)

- The shared UIKit editor now runs through BrowserUiHost with bundled fonts,
  seeded session MemoryFS and native window.open URL handling. Typed host
  services isolate file dialogs and source-plugin compilation. Injected plugin
  loaders initialize through their actual service instance; missing browser
  processes/LSP/build/plugins/terminal/control capabilities omit those commands.
- `web/build.sh` reuses materia `tools/web`, derives the source graph from its
  manifest, generates portable ABI HXI and a checked memory contract, builds the
  guest and Emscripten host, audits import signatures and assembles the site.
  Compile failures propagate; artifact trees are separate per target. All runtime
  export lists include ccall/addFunction/removeFunction consistently.
- `web/test.sh` drives real Chrome keyboard and pointer input, accent/emoji and
  ordinary characters, Enter, Ctrl-S/save/readback, dirty transitions, URL opening
  and fresh-session reload. It rejects console, exception and page/network errors.
  Bounded model/focus waits report actual failure state. Disposable browser process
  groups retire before profile cleanup. Edited/fresh screenshots are optional.
- `EXOSUIT_CI_WEB=1 ./scripts/test-web.sh` exits 0 on both targets:
  `/tmp/exosuit-web-final-ci.log`. Wasm32 has 107 imports and GC has 104;
  all host-bound signatures match and unavailable imports are empty. This stage
  joins `scripts/ci.sh`. Unselected or missing-Emscripten/Chrome branches print
  PENDING and were independently checked. GUI qualification is Chrome/SwiftShader
  on Linux; other browsers and platforms are unclaimed.
- Final desktop gates exit 0 at the release pins:
  `/tmp/exosuit-web-final-reference-tests.log`,
  `/tmp/exosuit-web-final-reference-build.log`,
  `/tmp/exosuit-web-final-self-tests.log`,
  `/tmp/exosuit-web-final-self-build.log`,
  `/tmp/exosuit-web-final-release.log`. Mandatory source plugins and unpacked real
  LSP remain passing. Real UIKit project/edit/save/palette/Problems/BuildOutput and
  live source-plugin reload passed in `/tmp/exosuit-web-accepted-desktop-window.log`.
  Edited browser screenshot `/tmp/exosuit-web-final-gc-edited.png` was inspected;
  it displays the saved accent/emoji text and a clean fresh line.
- Haxeon `02f924ed` copies borrowed C UTF-8 results into managed linear strings,
  preserves null on both targets and declares GC linear memory for result-only
  string imports. The registered ABI fixture verifies Unicode operations and
  survival after native storage is overwritten. It failed before the fix and
  passes both targets afterward. This resolves the actual linear browser
  `NativeKitError.messageFor` error-path crash without hiding platform errors.
- Compiler gate `/tmp/haxeon-gate-utf8-results-final.log` exits 0 with 383/383 and
  all integration/Wasm stages. Bootstrap converges in one stage and self-bootstrap
  is identical (both 0): `/tmp/haxeon-bootstrap-utf8-results-final.log` and
  `/tmp/haxeon-bootstrap-self-utf8-results-final.log`. The initial missing-helper
  lookup was an owned implementation error; the required nullable guard corrected
  it before committing. No typing workaround or diagnostics suppression added.
- Release pins: Haxeon `02f924ed`, materia `a9486f67`, NativeKit `d12dd484`,
  deliberately preserved HashLink vendor `40a4782`. Shared materia web tooling is
  `a656e9b7`; UIKit surface routing is `a9486f67`; NativeKit runtime callback exports
  are `708ac89e`, focused-input keys `97938edb`, pointer capture `d12dd484`.
  Haxeon prerequisite fixes are `14a02e0e` (terminated assignments), `35bd627d`
  (optional interfaces), `6a86c528` (callable ABI/initializer ownership),
  `642863b4` (UTF-16 string coordinates) and `02f924ed` (borrowed UTF-8 results).
- Pre-existing vendor gitlink/profile dump and parent submodule dirt are preserved.
  No pushes or publication. M15 checkboxes are accepted; continue directly with
  M9.1 rather than stopping at this milestone.


### M15.2 — UTF-16 string coordinates and browser pointer capture (verified slices)

- Haxeon `642863b4` keeps UTF-8 storage and ABI transfer while making length,
  charCodeAt, charAt and substring use UTF-16 coordinates on both Wasm targets.
  Selected surrogate halves survive through WTF-8. Internal byte slicing for
  split/case conversion remains byte based. EReg/Regex match positions now use
  UTF-16 and scalar iteration handles surrogate pairs consistently.
- The formerly skipped `string-utf16-length` fixture passes on both targets and
  is required. Registered `string-utf16-slices` covers Bytes roundtrip, BMP and
  astral text, individual surrogate halves, negative/outside charAt, clamping
  and empty slices. Reference Haxe/HashLink returns 42. Regex coverage includes
  whole-emoji matching, UTF-16 match ranges and terminating zero-width replacement.
- Full gate exits 0 with 383/383 and all integration/Wasm stages:
  `/tmp/haxeon-gate-utf16-slices-final.log`. Bootstrap converges in one stage and
  self-bootstrap is identical (both 0): `/tmp/haxeon-bootstrap-utf16.log` and
  `/tmp/haxeon-bootstrap-self-utf16.log`.
- NativeKit `d12dd484` uses DOM pointer capture for ordinary interaction rather
  than deferred relative pointer lock. A missing active pointer returns the
  declared unsupported result without changing mode. Its browser integration
  gate passes all four pages: `/tmp/nativekit-web-capture-gate.log` (0).
- Actual GC browser Unicode editing/save/URL/reload passes with no errors:
  `/tmp/exosuit-web-gc-pointer-capture-window.log` (0). Screenshot inspected:
  `/tmp/exosuit-web-gc-pointer-capture.png` shows the editor, project and Problems.
  Linear smoke passed standalone in `/tmp/exosuit-web-linear-selection-probe.log`,
  but composed CI remains red; no M15 acceptance is claimed.
- Composed failure is now reduced to a native UTF-8 result being treated as a
  managed string in linear Wasm. `/tmp/exosuit-web-ci-utf16-final.log` fails
  after pointer input in `__string_length` via `NativeKitError.messageFor`.
  New registered Wasm backend regression `tests/ffi/wasm-utf8-result.hx` fails
  before correction (exit 1 instead of 42), then passes both targets with owned
  uncommitted interop fixes. It verifies UTF-16 use, null preservation and native
  storage mutation after a result was returned. The GC-only reduction also
  revealed a missing memory declaration for result-only C string imports.
- Pending exact action: finish full gate/bootstrap for the borrowed UTF-8 result
  correction, run the actual opt-in browser CI stage on both targets and commit
  the verified compiler and browser slices. Current sessions: compiler gate in
  `/tmp/haxeon-gate-utf8-results.log`, browser CI in
  `/tmp/exosuit-web-ci-managed-utf8.log`. Browser smoke uses bounded state waits;
  do not mask page errors or count an earlier standalone pass as composed CI.
- Desktop requalification at `642863b4` passed reference and actual self-hosted
  tests/builds, real UIKit window/plugin reload and unpacked release:
  `/tmp/exosuit-web-accepted-{reference,self}-{tests,build}.log`,
  `/tmp/exosuit-web-accepted-desktop-window.log`,
  `/tmp/exosuit-web-accepted-release.log` (all 0). Later interop changes still
  require final pins and relevant requalification.

### M15.2 — generic callable ABI and initializer ownership (verified compiler slice)

- Haxeon `6a86c528` adapts callable argument/result signatures at generic
  semantic/physical boundaries, including nested callables. Nullable callbacks
  evaluate once and preserve null. Generated adapters in initializer pseudo-bodies
  now reuse the declaring class's module ownership rule.
- Independent registered `generic-callable-abi` execution covers nominal,
  integer, float and higher-order storage, assignment, null fallback, evaluation
  count and static initialization. Registered compiler coverage checks execution,
  incremental body edits/restoration and cold/incremental incompatible callbacks.
  Static initialization failed before the ownership change with
  `No source module owns typed function "$function-adapter:Functions.__init:0"`;
  focused execution passes afterward.
- `../haxeon/scripts/test.sh` exits 0, including formatting, runtime/compiler,
  integrations and Wasm parity/Wasmtime stages:
  `/tmp/haxeon-gate-generic-callable.log`. Bootstrap converges in one stage and
  self-bootstrap is identical (both exit 0):
  `/tmp/haxeon-bootstrap-generic-callable.log` and
  `/tmp/haxeon-bootstrap-self-generic-callable.log`.
- Actual Wasm GC editor builds with 104 matching imports:
  `/tmp/exosuit-web-gc-initializer-fixed-build.log` (0). ASCII browser typing,
  ordinary character input, Enter, dirty tracking, Ctrl-S/save/readback, native
  URL opening and fresh-session reload pass:
  `/tmp/exosuit-web-gc-callback-ascii-final.log` (0). Disposable Chrome process
  groups prevent child processes racing profile cleanup.
- Toolkit fixes already verified and committed separately: materia `a9486f67`
  routes transactional text by surface; NativeKit `97938edb` forwards focused
  hidden-input shortcuts while retaining DOM text/composition delivery. NativeKit's
  four browser integration pages passed in
  `/tmp/nativekit-web-key-routing-gate.log` (0).
- Full Unicode smoke remains red (`/tmp/exosuit-web-gc-unicode-probe.log`);
  source/test changes under `web/` remain uncommitted until acceptance passes.
  M15 is not accepted. Existing vendor gitlink/profile dump and parent submodule
  dirt remain preserved. No publication performed.


### M15.1/M15.2 — typed host services and optional interfaces (verified slice)

- The editor shell now accepts shared UiHostContext and an optional typed
  HostFileDialogs service; GraphicalMain supplies NativeDesktopServices explicitly.
  Hosts without dialogs use the existing path command view. Source compilation
  sits behind SourcePluginLoader/NativeSourcePluginLoader; browser graph excludes
  the embedded compiler and desktop loader, while existing plugin APIs remain.
- Haxeon `35bd627d` preserves optional interface parameters in canonicalization
  and uses shared TypeRepresentation to publish their nullable physical signature.
  Reduced Service.value(required:Int, ?suffix:String) previously rejected an
  omitted suffix. Registered cold/incremental positive and rejection coverage
  plus inherited/numeric optional runtime cases pass. Full gate: 380/380,
  every integration and 247 Wasm parity fixtures (12 existing skips); both
  bootstrap commands exit 0 and self-bootstrap is identical.
  Logs /tmp/haxeon-gate-interface-optional.log and
  /tmp/haxeon-bootstrap[-self]-interface-optional.log.
- NativeKit `708ac89e` makes its transitive Emscripten runtime exports configurable.
  Its hard-coded ccall export list previously replaced the consumer's callback
  exports. Matched host ABI checker and actual Chrome rendering now pass with
  ccall/addFunction/removeFunction. NativeKit's original off-pin commit/branch
  remains preserved; changes are on exosuit-followon.
- Both complete editor test/build modes exit 0 on the final service boundary:
  /tmp/exosuit-browser-final-boundary-{reference,self}-{tests,build}.log.
  Real UIKit/plugin reload and standalone release also exit 0:
  /tmp/exosuit-browser-boundary-desktop-window.log and
  /tmp/exosuit-browser-boundary-release.log.
- Browser startup/rendering passes with no unavailable imports, but input smoke
  remains red. NativeKit TextEdit events arrive with a surface handle; UIKit's
  NativeInputAdapter wrongly filters them against the window handle. Fix the
  general routing rule in materia/uikit with distinct-handle regression, then
  rerun browser typing/save/readback/reload on both guest targets. Browser files
  remain experimental and are not accepted yet.


### M15.2 — terminating assignment lowering (verified compiler slice)

- Haxeon `14a02e0e` fixes CFG lowering after a throw-valued assignment.
  Abstract constructor `this = throw "expected"` reduced the guest failure.
  Local/captured/field/static/array/map assignments and variable initialization
  now preserve the throw without emitting an unreachable store. Operand
  evaluation stops when an earlier operand terminates.
- Registered terminated-assignment executes all eight forms and verifies
  unchanged destinations; local reference Haxe/HL exits 42 on the same behavior.
  Full gate exits 0: 378/378, every integration, 246 Wasm parity fixtures with
  12 existing skips, Wasmtime. Bootstrap converges and --self rebuilds identically.
  Logs: /tmp/haxeon-gate-terminated-assignment.log,
  /tmp/haxeon-bootstrap-terminated-assignment.log,
  /tmp/haxeon-bootstrap-self-terminated-assignment.log.
- Guest CFG now succeeds, exposing embedded compiler runtime imports unsupported
  on Wasm. Browser graph work isolates desktop source-plugin implementations.
  Shared UiHostContext and optional typed file-dialog service are in progress.
  The new service also reduced an existing interface optional-argument metadata
  loss to an independent fixture; its fix and qualification are pending.


### M15.2 — shared browser pipeline tools (verified slice)

- Materia `a656e9b7` factors manifest guest arguments, portable Wasm HXI
  generation and host import signature checking into `tools/web`. The reference
  app keeps compatibility entry points and owns its toolkit generator list.
- Before/after generated HXI files and manifest arguments compare identically
  (`/tmp/materia-web-tools-before.log`, `/tmp/materia-web-tools-after.log`).
  Shared and compatibility import checkers give identical results for matching
  and deliberately mismatched Wasm ABI fixtures (exit 0 and 1 respectively).
  Shell syntax, Node syntax and Python compilation checks pass.
- Materia is on `exosuit-followon`; its pre-existing Haxeon/NativeKit gitlink
  changes and untracked exosuit remain untouched. Release pin now includes
  the shared tools. Browser entry/build experiments remain uncommitted.
- First actual 988-source browser guest exposed a general CFG lowering crash:
  generated unsupported UTF-8 callback constructor assigns a throw expression
  to abstract `this`. Reduced independently to `this = throw "expected"`.
  Fix and runtime regressions are underway in Haxeon; browser acceptance remains
  pending. Resume with that compiler gate, then qualify the guest and native host.


### M15.1 — typed host capability policy (verified slice)

- M8 composed CI restoration committed as exosuit 84c2dac. This slice adds an
  immutable typed HostCapability/HostCapabilities query (clipboard, filesystem,
  processes, threads, IPC, terminal, language services, URL, source plugins).
  Desktop advertises delivered services; IPC/terminal remain false until their
  milestones. Browser policy enables session filesystem/URL with optional
  clipboard and omits process/thread/source-plugin services.
- Application passes policy to controllers. Unavailable build/LSP/source-plugin
  commands are absent; clipboard commands and bindings are omitted. Process
  start is guarded before native allocation; deliberate direct controller calls
  return false with visible feedback. Restricted plugin managers do not install
  the host callback. UIKit omits Build Output when processes are unavailable.
- Host-capabilities test proves editing/undo, immutable constructor ownership,
  service prerequisites, absent commands, clear feedback and no owned child or
  plugin resources. Registered in test.sh with disposable portable state.
- Both ./scripts/test.sh and ./scripts/build.sh pass in reference and explicit
  self-hosted modes after these changes; graphical builds compile 987 sources.
  Logs /tmp/exosuit-test-capabilities-reference.log,
  /tmp/exosuit-build-capabilities-reference.log,
  /tmp/exosuit-test-capabilities-self.log,
  /tmp/exosuit-build-capabilities-self.log. Focused original test exits 0:
  /tmp/exosuit-capabilities-focused-fixed.log.
- Actual LSP, UIKit edit/task/plugin-reload route and unpacked release all exit 0:
  /tmp/exosuit-capabilities-real-lsp.log, /tmp/exosuit-capabilities-window.log,
  /tmp/exosuit-capabilities-release.log. Package pins the compiler correction
  below. Diff and shell syntax checks pass; no sibling dirt was staged.
- Browser guest/native host do not exist yet; no browser execution is claimed.
  Continue M15.2 using the shared pipeline, qualifying M15.1's import boundary.

### M15.1 compiler issue — array enum lookup context and representation

- Haxeon 39c27f9a fixes Array.indexOf/contains argument typing: supply the known
  element type just as push/remove do. The unmodified capability query passed
  local reference Haxe, while the independent reducer failed E1005 before the
  correction (/tmp/haxeon-array-lookup-before.log). Runtime probing then exposed
  separately allocated nullary constructors being missed by reference lookup.
- Shared IR lowering scans nullary enum variants by constructor index, retaining
  reference lookup for payload constructors and null. It preserves first-match
  order and nullable arrays, and uses the same CFG on native/Wasm backends.
  Reference Haxe/HL confirms distinct Value(7) instances do not match, but a
  retained instance does. No permissive assignability or application rewrite.
- Registered ArrayLookupContextMain covers contextual bare constructors,
  conflicting imports, unrelated enum rejection, cold/incremental builds and
  restoration. Registered array-enum-lookup covers duplicate nullary instances,
  payload identity, nulls, empty arrays and actual execution.
- Full compiler gate exits 0: 377/377 and all native/C++/integration stages;
  245 Wasm parity fixtures (12 pre-existing skips), Wasmtime. Bootstrap converges
  after one stage and --self rebuilds identically; refreshed artifacts committed.
  Logs /tmp/haxeon-gate-array-enum-lookup.log,
  /tmp/haxeon-bootstrap-array-enum-lookup.log,
  /tmp/haxeon-bootstrap-self-array-enum-lookup.log. Original editor capability
  test and both complete editor mode gates pass after the fix.


### M8.3 — restored composed CI (accepted)

- Real native-input slice committed as exosuit b76554b. scripts/ci.sh now runs
  the compiler gate, all headless projects, graphical build, real LSP smoke,
  real UIKit workflow and unpacked release serially. Package creation explicitly
  rejects unsupported host architectures. Workflow also asserts the task exit
  status is shown, so a partial output drain cannot satisfy the check.
- ./scripts/ci.sh exits 0; log /tmp/exosuit-ci-restored.log. Compiler/runtime
  tests and all native/C++/Wasm/Wasmtime integration stages exit 0, followed by
  every editor project and the actual LSP/window/unpacked-artifact routes.
  Expected failure fixtures in the compiler's test-framework checks are their
  own passing negative tests, not unresolved failures.
- HAXEON_SELF_HOSTED=1 ./scripts/build.sh exits 0 after the graphical CLI and
  diagnostics changes; 984 sources. Log /tmp/exosuit-m8-final-self-build.log.
  Earlier full headless self-hosted acceptance at 95a3b08 still applies: no
  headless application source changed in these window/release slices.
- Shell syntax and diff checks pass. Haxeon retains only initial vendor/hashlink
  pointer modification and hlprofile.dump; NativeKit and materia dirty/off-pin
  states are preserved. No publishing. M8.1–M8.4 accepted for the stated Linux
  automated scope. Physical IME/DPI and non-Linux remain pending.
- Continue M15.1 next; the goal still covers every follow-on milestone.


### M8.3 — native input and source-plugin reload (verified slice)

- Release slice committed as exosuit 011ea4d. The real-window workflow now uses
  Xvfb/xdotool against built bytecode and matched native libraries. It opens a
  project and file, edits/saves through TextArea, uses the command palette and
  task picker, observes task diagnostics in Problems, and inspects Build Output
  after a second host launch. Plugin reload recompiles a callback whose changed
  body inserts a marker; the saved marker proves execution of the new guest body.
- Graphical CLI accepts multiple paths (project then file), timed captures and
  native event recording using existing host capabilities. Recording mode emits
  and flushes readiness; captures include application errors and loaded plugins.
- UIKIT_WORKFLOW_ARTIFACTS=/tmp/exosuit-uikit-workflow-queries
  ./scripts/test-uikit-workflow.sh exits 0. Log uses the same path with .log.
  Both captures contain Main.hx, the loaded plugin and no application errors;
  event traces have actual native text input and no host failures. Saved text
  contains return 42 and the reloaded callback marker. Visually inspected the
  real Build Output screenshot. Shell syntax and diff checks pass.
- Early disposable probe failures: Sys.println is outside the source-plugin
  API; document subscriptions require an active document. Corrected fixtures
  use the supported editor API and open a document before activation. The CLI
  runner buffers forwarded child output, so the native-input driver launches
  the built artifact directly. Palette search persists between opens; the test
  selects/replaces the search query just as a user would. No typing evasion.
- Project build tasks and release/getting-started documentation now describe
  actual UIKit commands and dependencies; SDL measurements are historical.
- Pending: composed CI and self-hosted build after CLI changes. IME, physical
  DPI transitions and non-Linux checks remain unclaimed. Next ready task after
  accepted M8 is M15.1 capability boundaries.


### M8.3 — standalone UIKit release (verified slice)

- Replaced SDL/Pragtical packaging with manifest output, ordinary C libraries,
  Haxeon runtime and matching VM built from vendor/hashlink. release.lock pins
  Haxeon 82d92ba0, NativeKit 2bb4c957, materia 816372dd (UIKit/EditorKit), and
  HashLink 40a4782b. Preserved initial sibling dirty paths and off-pin state.
- Standalone launchers resolve libraries and the bundled LSP relative to the
  installation, preserving the caller's working directory/file arguments.
  Staged ELF runpaths use $ORIGIN; original build artifacts are untouched.
  UIKit uses system Fontconfig fonts; removed obsolete bundled-font defaults.
  Native dependency notices and standard library accompany the archive.
- ./scripts/test-release.sh exits 0, log /tmp/exosuit-release-uikit.log:
  unpacked archive renders/captures outside the source tree using disposable
  portable state; ELF search paths contain no source directories; bundled LSP
  diagnoses/fixes/saves the edited source, then CLI build/run returns 42.
  Shell syntax and git diff --check pass. An initial attempt exposed the native
  build wrapper's cwd requirement; package invocation now enters Haxeon first.
- Pending: scripted native input route and composed CI; M8 remains in progress.


### M8.3 — manifest-based real language service (verified slice)

- Exosuit `485303f` replaces removed realtime-haxe/haxeon-compile invocations
  with a real smoke-test package and CLI build/run. The client starts the actual
  Haxeon server, edits valid code into an invalid return, observes a diagnostic,
  fixes and clears it, saves through Document.save, then independently builds
  the saved package and executes it to return 42. Initial disk code returns 1,
  so success proves the changed document was saved.
- `./scripts/test-haxeon-lsp.sh` and
  `HAXEON_SELF_HOSTED=1 ./scripts/test-haxeon-lsp.sh` exit 0. Logs:
  `/tmp/exosuit-real-lsp-manifest.log`,
  `/tmp/exosuit-real-lsp-manifest-self.log`. Shell syntax and diff checks pass.
  External-server override is retained for unpacked release qualification.
- Inspected existing DesktopUiHost options: native capture, frame limits,
  event recording and app diagnostic snapshots are already available; no
  framework hook was added. `xvfb-run -a ./scripts/run.sh --capture-dir=...`
  with three frames and a disposable Main.hx exits 0, produces a real window
  capture/tree/events/app state, and visually shows the file and live shell.
  Log `/tmp/exosuit-uikit-window-smoke.log`, artifacts
  `/tmp/exosuit-m8-window-capture`. This first capture inherited existing
  session tabs; all further GUI checks must set PRAGTICAL_PORTABLE to a
  disposable state directory. No existing document was edited.
- Basic window rendering is verified; scripted edit/save/palette/problems/
  build/reload acceptance remains pending. Next: isolate portable state and
  drive real native inputs with xdotool, then restore pinned packaging/CI.

### M8.1/M8.2 — reflection copies and mandatory source plugins (accepted)

- Haxeon `82d92ba0` fixes the reduced Reflect.copy representation failure.
  Native reflection clones typed object layouts without constructors, preserves
  declared null field types and shallow references, and retires interface-cache
  slots. Existing HashLink dynamic/virtual copying is reused. Wasm generates
  per-layout shallow copying through ObjectReflection; dynamic objects retain
  their explicit field-copy path. No assignability weakening, editor special
  cases or test skips were introduced.
- Before-fix typed-record reducer exited 1 with the same dynobj cast failure.
  A stock HashLink copy was insufficient for object-backed records, and copying
  to dynobj still lost nominal layout; the final adapter preserves the layout.
  The local reference Haxe record test exits 42. New native/Wasm regressions
  cover nullable fields, copy independence, shallow arrays, null input,
  inherited class fields, constructor counts and interface dispatch. The
  embedding test now recompiles a method body on a worker with publication
  tracking, exercising the semantic body-reuse path.
- The first full reflection gate failed both Wasm backends on the new test
  (`/tmp/haxeon-gate-reflect-copy.log`, exit 1). The general Wasm helper fixes
  both: focused parity exits 0 with 244 fixtures/12 pre-existing skips; final
  full gate exits 0, 375/375 plus every integration/native/C++/Wasm/Wasmtime
  stage (`/tmp/haxeon-gate-reflect-copy-complete.log`). Both bootstrap commands
  exit 0, converge after one stage and rebuild identically; logs
  `/tmp/haxeon-bootstrap-reflect-copy-complete.log` and
  `/tmp/haxeon-bootstrap-self-reflect-copy-complete.log`. Stdlib formatting
  checked explicitly. Temporary compiler stack logging and reducer files are
  removed. Pre-existing dirty Haxeon paths remain untouched.
- Exosuit `95a3b08` restores threaded source compilation, publication,
  compatible patching, structural reload/state transfer, rollback and unload
  handling. It registers compiler intrinsics and PluginHost HXI. SDK host
  callbacks return checked success/error responses; Unicode errors can be
  caught inside plugin code. Initialization reinstalls managed callbacks after
  shutdown, and retired tokens are rejected. Unexpected compiler failures keep
  exception stacks in plugin diagnostics.
- Acceptance extends the disposable fixture with Unicode host-error catching
  and checks shutdown/reinstall/retired-token handling. The full existing
  compatible/structural reload, source failure, activation rollback, state
  version and unload-race test is mandatory again; suppression is removed.
- Serialized `./scripts/build.sh`, `HAXEON_SELF_HOSTED=1 ./scripts/build.sh`,
  `./scripts/test.sh`, `HAXEON_SELF_HOSTED=1 ./scripts/test.sh` all exit 0.
  Graphical builds compile 984 sources; every headless project, including
  dynamic plugins, passes. Logs:
  `/tmp/exosuit-build-plugin-restored-reference.log`,
  `/tmp/exosuit-build-plugin-restored-self.log`,
  `/tmp/exosuit-test-plugin-restored-reference.log`,
  `/tmp/exosuit-test-plugin-restored-self.log`.
- CommandView's defect has dedicated effect regressions. The historical
  ConfigurationController/SelectOption claims no longer reproduce in the
  updated source/compiler; bootstrap refresh and actual two-mode UIKit builds
  establish resolution without invented reducers. README/ADR reflect current
  implementation; plugin docs use the actual API version 2. Interactive GUI,
  release and real-server integration are still pending in M8.3.

### M8.1 — reusable compiler/runtime package (verified slice)

- Haxeon `70d697ed` exposes the existing public compiler/runtime APIs through
  `embed/haxeon.json` (`haxeon-compiler`), documents ownership/configuration,
  and registers `test-compiler-embedding.sh` in the standard gate. Consumers
  keep compiler/runtime namespaces and configure intrinsics/host HXI explicitly.
  No compiler sources are copied into the editor.
- Registered integration builds a real package consumer, compiles a guest
  program, executes its stable exported function returning 42, and disposes
  the module. Direct runner exits 0; the full compiler gate exits 0 with
  373/373 and every integration/Wasm stage, including embedding. Logs:
  `/tmp/haxeon-embedding-integration-direct.log`,
  `/tmp/haxeon-gate-embedding-package.log`. Prior focused package runs also
  passed reference and self-hosted modes after `c0e1f251`.
- The separate draft incremental probe with a single field-only class passes
  (exit 0, `/tmp/haxeon-embedding-incremental-before.log`), so it does not yet
  reduce the plugin's failure. A stronger variant enables publication tracking,
  acknowledges its first revision, and adds another module with a default
  argument; running session 36638, log
  `/tmp/haxeon-embedding-incremental-publication.log`.
- Source-plugin restoration remains uncommitted and acceptance red at the
  original AST record cast failure. Next: reduce that failure using the stronger
  probe; do not claim a fix from the simpler incremental case passing.

### M8.1 — dynamic restoration checkpoint (uncommitted, acceptance red)

- Restored source-plugin project compiles 973 sources and executes initial
  activation, host calls, Unicode host-error catching and command dispatch.
  Direct run with absolute fixture arguments exits 1 at the background
  compatible-update assertion: an AST class record cannot cast from dynobj to
  the expected anonymous shape. Log:
  `/tmp/exosuit-dynamic-plugin-restoration-absolute.log`. The first direct run
  used relative fixture paths and exited 1 opening source; those paths were
  corrected, with no code workaround.
- Owned pending exosuit files: `haxeon.json`, `DynamicPlugin.hx`,
  `DynamicHostRouter.hx`, `DynamicEditorApiSource.hx`,
  `DynamicPluginTestMain.hx`. None is committed without acceptance. Callback
  response protocol and restart regressions are included, but the restart
  assertion has not yet been reached. Suppression in test.sh remains visible.
- Haxeon embedding manifest/documentation and registered integration test are
  pending verification in session 80655, log
  `/tmp/haxeon-gate-embedding-package.log`. The initial generated-program probe
  passes. A separate unregistered draft
  `tests/integration/test-compiler-embedding-incremental.sh` adds an AST class
  and recompiles changed class initialization to reduce the new runtime cast
  failure; session 4484, log `/tmp/haxeon-embedding-incremental-before.log`.
- Next: inspect that reducer's uncaught runtime stack, reduce the anonymous
  representation conversion, add general compiler/runtime regressions and fix
  the responsible layer before making dynamic-plugin acceptance mandatory.

### M8.1/M8.2 — cast context and checked opaque conversions (verified slice)

- Haxeon `c0e1f251` separates operand inference from the destination of an
  untyped cast; explicit type ascriptions still guide their operands. This
  fixes the exact E1003 reducer for Runtime.callBytes: a generic callback
  calling a native method was incorrectly constrained by the cast destination.
  Local reference Haxe accepts the reduced existing explicit ABI cast.
- IR lowering now treats opaque native handles and managed Bytes as reference
  cast types, using existing checked dynamic casts. It does not relax implicit
  assignability. `CastContextMain` executes a Bytes -> matching opaque handle
  -> Bytes round trip and rejects a wrong native tag at runtime. Removing the
  explicit cast remains rejected incrementally and cold; restoration runs.
  The initial reducer also exposed unsupported backend representation casting;
  both responsible layers are fixed and tested.
- Full `./scripts/test.sh` exited 0: 373/373 and every native/C++/Wasm stage
  (`/tmp/haxeon-gate-cast-context.log`). Bootstrap and self-bootstrap exited 0,
  converged after one stage and rebuilt identically (logs
  `/tmp/haxeon-bootstrap-cast-context.log`,
  `/tmp/haxeon-bootstrap-self-cast-context.log`). Owned updated bootstrap is
  committed; pre-existing dirty Haxeon paths are unchanged.
- The uncommitted package probe now passes in reference and self-hosted modes:
  `/tmp/haxeon-compiler-embedding-cast-fixed-entry.log` and
  `/tmp/haxeon-compiler-embedding-cast-self.log`, both exit 0, compile the
  public compiler/runtime package and execute generated code returning 42.
  The earlier probe expected `Probe.main` incorrectly; module-level functions
  export `main`, consistent with existing runtime tests. Corrected that fixture
  rather than changing exports. Register/document/verify the embedding package
  before committing it.
- Pending exosuit restoration restores the original threaded dynamic-plugin
  implementation, configures compiler intrinsics and the portable PluginHost
  HXI, uses checked function-ID lookups, and reinstalls retained callbacks after
  shutdown. SDK calls use explicit ok/error responses to propagate host errors
  within plugin code. Added disposable-fixture Unicode error-catching and
  callback restart checks. Direct acceptance is running; no success or milestone
  completion is claimed yet. Test suppression remains until acceptance passes.

### M8.1/M8.2 — consistent raw byte intrinsic types (verified compiler slice)

- Haxeon `3f870cf7` makes `Bytes.getData()` and the primitive String byte
  accessor return the same raw `THlBytes` ABI type that declared `hl.Bytes`
  parameters resolve to. The former nominal abstract wrapper caused E1009
  in ordinary identity calls and embedded `Runtime.inspectPatch`.
- Registered `RawBytePointerMain` fails before the fix, then passes actual
  native UTF-16 length calls, annotated raw pointer assignments and identity
  calls. Passing managed Bytes directly remains rejected in incremental and
  cold compiles; restoration executes correctly. Local reference Haxe
  accepts the reduced getData/identity/annotated-pointer program (exit 0).
- Focused expanded regression exited 0; full `./scripts/test.sh` exited 0
  with 372/372 driver cases and every integration/Wasm stage. Both bootstrap
  commands exited 0, converged after one stage and self-rebuilt identically.
  Bootstrap artifacts did not change. Logs:
  `/tmp/haxeon-raw-byte-pointer-before.log`,
  `/tmp/haxeon-raw-byte-pointer-expanded.log`,
  `/tmp/haxeon-gate-raw-byte-pointer.log`,
  `/tmp/haxeon-bootstrap-raw-byte-pointer.log`,
  `/tmp/haxeon-bootstrap-self-raw-byte-pointer.log`.
- Owned, uncommitted Haxeon embedding work: `embed/haxeon.json`, package probe
  `tests/integration/test-compiler-embedding.sh`, and an unregistered draft
  `tests/compiler/CastContextMain.hx`. The real package probe compiles the
  public compiler and Runtime, generates a 42-returning program and invokes
  it. Before the fix it failed at Runtime.hx:108 with E1009; afterward it
  reaches Runtime.hx:139 with E1003 in the existing `callBytes` boundary.
  Logs: `/tmp/haxeon-compiler-embedding-reference.log` and
  `/tmp/haxeon-compiler-embedding-raw-pointer.log` (both exit 1).
- The draft cast reducer reaches a distinct backend diagnostic:
  `Unsupported cast from Abstract(realtime_bytes) to ManagedBytes`. Reference
  Haxe accepts the existing explicit ABI cast through a generic callback;
  the reducer does not yet reproduce the precise E1003 from Runtime, and no
  cast/inference fix is claimed. Do not introduce application casts or
  weaken assignability. Next: reduce both the Runtime callBytes typing and
  managed-byte representation boundary, fix general capabilities with tests,
  then finish the embedding package and restore the dynamic plugin test.

### M8.2 — consistent wrappers without action-directory workaround (verified slice)

- Exosuit `18e1ad5` aligns build, run and test with the standard CLI
  reference-compiler default. `HAXEON_SELF_HOSTED=1` remains an explicitly
  verified mode. Removed the stale pre-created action directories; upstream
  Haxeon `c59502ff` owns the general concurrent directory-creation fix.
- Serialized graphical builds using each compiler and new output paths exited
  0 (`/tmp/exosuit-fresh-reference-actions.log`,
  `/tmp/exosuit-fresh-self-actions.log`). Both headless modes then exited 0
  (`/tmp/exosuit-test-wrapper-reference.log`,
  `/tmp/exosuit-test-wrapper-self.log`), still explicitly skipping source-plugin
  acceptance. No test suppression was added or expanded.
- Additional graphical manifests in temporary directories used absolute
  references to the unchanged real packages and empty build/action caches.
  Both reference and self-hosted builds exited 0, including native builds;
  logs `/tmp/exosuit-empty-actions-reference.log` and
  `/tmp/exosuit-empty-actions-self.log`. No directory pre-creation was used.
- `bash -n scripts/build.sh scripts/run.sh scripts/test.sh` and
  `git diff --check` exited 0. Interactive run, GUI and other platforms remain
  pending. Next: expose Haxeon's compiler/runtime package, restore source
  plugins with callback-error propagation/lifecycle coverage, then make the
  dynamic-plugin test mandatory.

### M8.2 — comprehension collection shadowing (verified slice)

- Haxeon `24ad2048` passes comprehension binding names through loop effect
  analysis, preventing a shadowed outer map/array from lending its primitive
  read-only classification to a user object. The reducer previously accepted
  a field read on a later iteration after a fake `exists` cleared that field;
  it now rejects the code with E1005.
- `PrimitiveMapEffectsMain` covers array and map comprehensions shadowing a
  primitive map, array shadowing, and accepted/executed unshadowed map reads.
  Focused before-fix regression exited 1; corrected expanded checks exited 0.
  Initial focused invocation lacked the runtime library path; the recorded
  regression rerun supplied `LD_LIBRARY_PATH=out:.tools/hashlink`.
- `./scripts/test.sh` exited 0 (371/371 plus all native/C++ and Wasm stages),
  `/tmp/haxeon-gate-comprehension-shadow.log`. Both
  `./scripts/bootstrap-compiler.sh` and `./scripts/bootstrap-compiler.sh --self`
  exited 0: convergence after one stage and identical self-rebuild. Logs:
  `/tmp/haxeon-bootstrap-comprehension-shadow.log` and
  `/tmp/haxeon-bootstrap-self-comprehension-shadow.log`. Updated bootstrap
  artifacts are committed. Pre-existing dirty Haxeon paths remain untouched.
- Exosuit wrapper edits are not yet committed: uniform reference-compiler
  default with explicit self-hosted override, stale action-directory workaround
  removed. Serialized checks are running: fresh graphical outputs in
  `/tmp/exosuit-m8-fresh-reference` and `/tmp/exosuit-m8-fresh-self`, then both
  headless modes. Logs: `/tmp/exosuit-fresh-reference-actions.log`,
  `/tmp/exosuit-fresh-self-actions.log`,
  `/tmp/exosuit-test-wrapper-reference.log`, `/tmp/exosuit-test-wrapper-self.log`.
  Dynamic-plugin suppression remains explicit; M8 acceptance is incomplete.

### M8.2 — text dependency keys and converged bootstrap (verified slice)

- Haxeon `58be9a62` replaces the forbidden NUL dependency separator with a
  shared length-prefixed text key, preserving component boundaries, empty
  components and order. Both reachability-cache producers and consumers use
  it. The HashLink String NUL prohibition remains intact.
- Registered `DependencyKeyMain` fails against the original separator and
  passes with stable, distinct keys for empty lists/components, ambiguous
  concatenations, delimiters and Unicode. Refreshed owned bootstrap artifacts
  are committed with the source; pre-existing `vendor/hashlink` and
  `hlprofile.dump` changes remain untouched.
- Haxeon `./scripts/bootstrap-compiler.sh` exited 0 and converged after one
  self-hosted stage. `./scripts/bootstrap-compiler.sh --self` subsequently
  printed `PASS: checked-in compiler rebuilt itself identically`; its terminal
  status was lost during context handoff, so only that explicit result is
  claimed. Logs: `/tmp/haxeon-bootstrap-dependency-keys.log` and
  `/tmp/haxeon-bootstrap-self-dependency-keys.log`.
- Haxeon `./scripts/test.sh` exited 0: 371/371 compiler-driver cases and every
  integration stage, including native/C++ and both Wasm parity/Wasmtime gates.
  Log: `/tmp/haxeon-gate-dependency-keys.log`. `git diff --check` passed.
- Exosuit `HAXEON_SELF_HOSTED=1 ./scripts/build.sh` and
  `HAXEON_SELF_HOSTED=0 ./scripts/build.sh` exited 0, compiling 618 sources.
  The stale shift-assignment and historical `SelectOption` failures no longer
  reproduce. Logs: `/tmp/exosuit-build-fresh-bootstrap.log` and
  `/tmp/exosuit-build-reference-dependency-keys.log`.
- `HAXEON_SELF_HOSTED=1 ./scripts/test.sh` exited 0; all gating headless
  projects passed. Dynamic source-plugin acceptance was explicitly skipped
  because its implementation is still a stub. Log:
  `/tmp/exosuit-test-fresh-bootstrap.log`. No graphical interaction or
  cross-platform execution is claimed.
- Next: reduce the suspected comprehension collection-shadowing case before
  further compiler changes; remove stale script defaults/workarounds, then
  restore embedded source-plugin compilation and make its test gating.

### M8.1 — native C/HXI migration (verified slice; acceptance incomplete)

- Exosuit `f8939de` replaces every editor `@:hlNative` entry with a C-header
  binding, portable `.hxi`/`.hxmap`, explicit UTF-8 strings, 32-bit booleans and
  managed retained callbacks. ABI is now 18 (the actual run baseline was 17).
  Unused SDL host callbacks and stale generated bridge header are removed.
  Window/font/draw functions remain for headless model, renderer and benchmark
  consumers; rationale and callback lifecycle are in `docs/native-bindings.md`.
- Start state: exosuit `fc5bbee`, clean; materia `816372dd`, dirty submodule
  pointers and untracked exosuit; Haxeon `fba71015`, pre-existing modified
  `vendor/hashlink` pointer and untracked `hlprofile.dump`; NativeKit `2bb4c957`,
  clean off-pin. Reference Pragtical is `/home/joao/dev/pragtical` (the default
  sibling path does not exist), with pre-existing config/sidebar/view/settings
  changes and untracked `scripts/lua/tests/view.lua`. No sibling or reference
  changes were made in this slice.
- `./scripts/test.sh` before migration exited 1 at the recorded `last_error`
  HashLink signature mismatch. After migration it exited 0; all gating
  projects passed. The new `native-string-test` covers Unicode clipboard,
  copied borrowed results, callback arguments/results/errors, replacement,
  shutdown, Unicode native errors and diagnostic truncation at scalar boundaries.
  Existing process tests cover stdin and split UTF-8 output.
- `./scripts/update-native-bindings.sh --check` exited 0: Clang import and
  portable ABI audit passed for Linux x64, Windows x64, macOS x64/arm64.
  This is ABI import evidence, not execution evidence on Windows/macOS.
  `cc -std=c11 -Wall -Wextra -Werror -Iinclude -c
  native/ffi/pragtical_hx.c -o /tmp/exosuit-native.o` and `git diff --check`
  exited 0.
- `./scripts/build.sh` exited 1 with the baseline
  `commandview/CommandView.hx:297:16: E1005: Field "entries" requires an object`.
  GUI/IME/mixed-DPI checks were not performed.
- The test wrapper suppresses `dynamic-plugin-test`: the UIKit port replaced
  source compilation with a throwing stub. Its SDK now declares the migrated
  host symbol through HXI, but needs registration when embedding is restored.
  This gap blocks the full M8.1 acceptance; do not count the wrapper's exit 0 as
  every project passing. No compiler defect was fixed in this slice.

### M8.2 — primitive effect inference (verified compiler slice)

- Haxeon `3606bd7c` on `exosuit-followon` fixes the reference build failure in
  `CommandView.filter` without changing application types or guards. A minimal
  nullable provider loop compiled when it only read entries and failed at the
  same read when `results.push(value)` was added.
- Root cause: loop effect analysis treated built-in array storage operations as
  unknown calls, forgetting all mutable-field facts. It also failed to infer
  primitive string helpers as pure. The syntactic effect walker now recognizes
  declared/inferred array locals and own array fields, reports their storage
  effects, and distinguishes primitive string operations/joins and numeric
  conditional results from calls or object conversions that can run user code.
- Native `StringTools` prefix/suffix comparisons now state their actual `@:pure`
  contract. Their C implementations only read lengths and compare bytes; these
  annotations describe an opaque native boundary, not application workarounds.
- Registered `LoopArrayEffectsMain` covers explicit/implicit own fields,
  annotated/inferred local arrays, rejection of user-defined `push`, sort
  callbacks and direct field replacement. Accepted programs execute on HashLink.
  `PrimitiveStringEffectsMain` covers string helpers and getters, execution,
  incremental rejection after a helper gains a write, cold-build agreement and
  acceptance after restoring the helper.
- Focused regression runners exited 0. Haxeon's `./scripts/test.sh` exited 0
  with formatting enabled: 365/365 test-driver cases, differential tests,
  runtime/HXI/C++ and native-package integrations, wasm backend/parity and
  Wasmtime GC checks passed. Exosuit reference `./scripts/build.sh` exited 0;
  reference headless verification is in progress at this checkpoint.
- Upstream `c59502ff` already made action-directory creation race tolerant via
  `Directories.ensure`; exosuit's pre-creation workaround still needs removal.
- Self-hosted graphical build still exits 1 at `IdSet.hx:565` (`E0002: Expected
  expression`, byte offset at `size <<= 1`). Its checked-in bootstrap was last
  refreshed at `308231b5` (2026-09-28), before later syntax changes. Refresh and
  compare compiler modes before deciding whether another typing fix is needed.
  No self-hosted success or full M8.2 completion is claimed yet.

### M8.2 — null-only local array inference (verified compiler slice)

- Haxeon `5f0b7671` fixes bootstrap's `WasmCAbi.hx:90` E1009 without
  adding annotations to the compiler application. A null-only local array,
  including a comprehension and an alias, now receives the element type
  required by a non-generic constructor argument before its initializer is typed.
  Array assignability and mutation checks remain unchanged.
- Root cause: local constraints did not visit constructors, and null-only
  array initializers ignored later expected context. Existing call constraints
  now also run for expression statements and unannotated initializers.
- Registered `NullArrayContextMain` executes generated HashLink code after
  writing a class instance into nullable array storage; it rejects incompatible
  mutations and checks incremental/cold rejection after a constructor edit.
  The local reference Haxe compiler accepted the independent reducer.
- Focused regression and full Haxeon `./scripts/test.sh` exited 0, including
  formatting, 366/366 driver cases, native/HXI/C++ package integrations,
  differential and both Wasm gates. Log: `/tmp/haxeon-gate-null-array.log`.
  Exosuit `./scripts/build.sh` exited 0 (`/tmp/exosuit-build-null-array.log`).
  Reference headless gate from the preceding slice exited 0, still with the
  explicitly suppressed dynamic-plugin test.
- `./scripts/bootstrap-compiler.sh` exited 1. It passes the old `WasmCAbi`
  failure and stops at `WasmFunctionLower.hx:1049` E1005: a guard checks one
  nullable lookup result, then the body dereferences a second unchecked result.
  The lookup writes a cache; the general type checker correctly requires
  checking the value being consumed. Merge the call branches and check one
  lookup result, then retry bootstrap and two-mode editor gates.
- Pre-existing HashLink pointer and profile dump remain untouched. Bootstrap
  has not converged; M8.1/M8.2 acceptance and GUI checks remain pending.

### M8.2 — checked Wasm source lookups (verified compiler-source slice)

- Haxeon `02608ed7` corrects four nullable-source errors exposed while
  bootstrap checks recent Wasm code. Call lowering now checks and consumes
  one host lookup; dynamic-array helper calls and GC `Std.string` definitions
  report a missing registered function instead of passing a nullable index.
  Fixed-record scratch allocation checks the nullable layout directly.
- These were source errors rather than typing defects. In particular,
  reference Haxe with `@:nullSafety(Strict)` rejects using a stored boolean
  as proof that an unrelated nullable value can be dereferenced. No compiler
  typing rules, annotations or casts were changed for this slice.
- Focused `WasmBackendMain` and full `./scripts/test.sh` exited 0:
  366/366 driver cases, formatting, native integrations, Wasm backend,
  parity and Wasmtime GC execution passed. Log:
  `/tmp/haxeon-gate-wasm-null-checks.log`.
- Bootstrap advances past these failures and exits 1 at
  `WasmGcModuleBuilder.hx:605`, ambiguous bare `I32` in an inferred array.
  Independent reducer: two imported enums both define `Item`; Haxeon rejects
  unannotated `var value = Item`, whereas reference Haxe chooses the later
  import. Existing semantic assembly discards aliases for all collisions.
  Next: register accepted/rejected/runtime/incremental regressions, implement
  import-order precedence, rerun compiler gate and bootstrap convergence.
- No refreshed bootstrap artifact or two-mode success is claimed. All
  pre-existing sibling changes remain preserved; editor worktree is clean.

### M8.2 — enum constructor import precedence (verified compiler slice)

- Haxeon `56fc5b98` resolves colliding constructor names from separate
  explicit imports in source order: the later import supplies the default,
  matching reference Haxe. Explicit expected enum types still take priority;
  collisions within one module import keep their existing ambiguity rule.
- Root cause: semantic assembly discarded constructor aliases for every
  collision, allowing unrelated global enum abstracts to produce misleading
  ambiguity errors in an inferred array of Wasm enum values.
- Registered `EnumImportOrderMain` checks forward/reversed imports, explicit
  expected type priority, incompatible nominal argument rejection, generated
  execution, incremental import edits and cold-build agreement. Reducer failed
  with E1005 before the fix and ran after it; reference Haxe chose the later
  import in the independent fixture.
- Full compiler `./scripts/test.sh` exited 0, with formatting, 367/367 driver
  cases and all native/differential/Wasm stages. Log:
  `/tmp/haxeon-gate-enum-imports.log`. Exosuit `./scripts/build.sh` exited 0
  (`/tmp/exosuit-build-enum-imports.log`).
- Bootstrap exits 1 after passing the old enum failure, now at
  `HlWriterCache.hx:76`: `ObjectMap.get` returns nullable even following
  `exists`. Reference Haxe with strict null safety rejects this pattern too.
  Retrieve and check the snapshot hash once, then retry convergence; no
  compiler assignability or map-presence rules need weakening.
- M8 remains incomplete, including dynamic-plugin integration, refreshed
  self-hosted agreement and release gates. Sibling dirty work is preserved.

### M8.4 — truthful graphical documentation (documentation slice)

- README and ADR 0002 now describe the live Problems and Build Output panels,
  shared-controller command bridge and wired language overlays. They distinguish
  document activation/model selection from visible widget caret movement.
- Remaining gaps explicitly include styled text, decorations, search highlights
  and results panel, caret anchoring, pane operations, context menus and source
  plugins. The ADR describes C/HXI ABI 18 and the retained headless renderer APIs.
- Verified claims against `graphical/src/ui/ExosuitApp.hx`, `CommandBridge.hx`,
  `ProblemsPanel.hx`, `BuildOutputPanel.hx`, `UiWorkbenchHost.hx` and
  `UiDocumentView.hx`; `git diff --check` passes. No extra tests were added for
  this documentation correction. No interactive checks or M8 acceptance are
  claimed. Bootstrap/compiler agreement remains the first active task.

### M8.2 — snapshot cache retention (verified compiler-source slice)

- Haxeon `90776aee` retrieves each cached snapshot hash once, checks it for
  null and retains only present entries. This fixes an unchecked nullable
  `ObjectMap.get` result without changing type relations or map contracts.
  Reference Haxe with strict null safety rejected the former `exists`/`get`
  pattern. Full compiler `./scripts/test.sh` exited 0: formatting, 367/367
  driver cases and all native/differential/Wasm stages. Log:
  `/tmp/haxeon-gate-snapshot-retention.log`.
- Bootstrap advances and exits 1 at `Parser.hx:879`, empty local array `cases`.
  Reducer: the expected result enum has `Case(values:Array<Int>)`, while a
  later imported enum has a no-argument `Case`. Actual expression typing
  selects the expected constructor; inference selects the imported constructor
  first and never constrains `values`. Reference Haxe accepts and executes it.
  Next: register reducer/regressions and align the prepass with typing.
- Exosuit documentation slice `c03089d` completes the M8.4 text correction;
  it does not establish runtime or M8 acceptance. Sibling dirty work remains
  untouched; no refreshed bootstrap artifacts have been committed.

### M8.2 — expected enum argument inference (verified compiler slice)

- Haxeon `5b38eca1` aligns local inference with actual enum expression typing:
  a bare constructor receives the expected enum's argument context before
  falling back to imported constructors. Explicitly qualified references retain
  their normal meaning; type relations are unchanged.
- Root cause: the prepass used imported constructor metadata first, even when
  expression typing selected the expected enum instead. Parser's `Switch`
  constructor collided with the imported token enum's no-argument `Switch`,
  leaving an empty local array without its expected element type.
- Registered `ExpectedEnumContextMain` fails E1003 before the fix, executes
  generated code after it, rejects incompatible pushed elements in incremental
  and cold compiles, and executes again after restoring valid source. Reference
  Haxe accepts and executes the independent reducer.
- Full compiler `./scripts/test.sh` exited 0: formatting, 368/368 driver cases,
  native/differential/Wasm stages. Log: `/tmp/haxeon-gate-expected-enum.log`.
  Exosuit `./scripts/build.sh` exited 0 (`/tmp/exosuit-build-expected-enum.log`).
- Bootstrap passes the parser-array failure and exits 1 at `Parser.hx:2549`:
  missing stdlib `haxe.io.BytesBuffer`, used by Unicode scalar encoding.
  Add reusable byte accumulation over the existing byte-output runtime;
  retain parser types/encoding logic and rerun convergence and both modes.
- No refreshed self-hosted artifact or full M8 acceptance is claimed.

### M8.2 — portable byte builder (verified stdlib slice)

- Haxeon `73d67796` adds `haxe.io.BytesBuffer` over the existing byte-output
  ABI. Supported operations are byte/range append, Int32/Float64 append,
  length and independent byte snapshots. Numeric encoding is little-endian.
  Parser's Unicode scalar encoder is unchanged and now finds its dependency.
- Registered `tests/programs/bytes-buffer.hx` exercises Unicode scalars,
  embedded NUL/255, ranges, byte truncation, snapshots, numeric encoding and
  growth across the initial capacity. Missing class failed E2001 before the
  addition; generated HashLink execution now returns 42.
- The first full gate exited 1 on wasm32 range errors: the underlying native
  byte-output primitive traps on invalid ranges. Reference Haxe's BytesBuffer
  performs its own range validation; the new library now does likewise and
  throws before delegation, preserving the buffer. The test remains gating
  and requires catchable failure on all targets.
- Corrected full `./scripts/test.sh` exited 0: formatting, 369/369 driver cases,
  native/differential integrations, both Wasm parity backends and Wasmtime GC.
  Log: `/tmp/haxeon-gate-bytes-buffer-ranges.log`. Explicit formatter check of
  the stdlib file (outside the script's normal source roots) also exited 0.
- Bootstrap advances beyond the missing class and exits 1 at
  `FieldInference.hx:179`, nullable declaration lookup dereferenced without a
  check. Check retrieved declarations before consuming their fields, then
  rerun bootstrap. No fresh self-hosted artifact or M8 completion is claimed.

### M8.2 — primitive map effects and loop shadowing (verified compiler slice)

- Haxeon `dd36f1c8` recognizes read-only `exists`, `get`, `keys`, `values` and
  `size` on typed String/Int maps as operations that cannot invoke user code.
  Facts cover own fields, arguments, annotated/inferred locals and aliases.
  Loop analysis receives visible primitive-map metadata through Scope and
  TypingSession. User methods and mutations remain effectful.
- Reducer: a checked nullable provider lost its fact after a helper read its
  own `Map.exists`. The helper is now inferred pure. A loop reading a typed
  map parameter exposed missing outer-map metadata; it also executes correctly.
- Rejection coverage caught an unsound loop-name collision: a loop variable
  inherited the outer collection's classification, hiding a fake method's
  mutation between iterations. Loop bindings now remove inherited private-map,
  array and primitive-map metadata. Fake map/array iterations that read before
  mutating are rejected; lexical local shadowing is also covered.
- Registered `PrimitiveMapEffectsMain` executes field/local/alias/argument
  and loop forms; it rejects custom `exists`, direct provider mutation,
  incremental/cold effect edits and accepts restoration. One expanded test
  incorrectly expected arrays from the iterator APIs and was corrected;
  the first gate exited 1 for that fixture error. Later gates passed, and the
  final shadowing gate exited 0: formatting, 370/370 driver cases and all
  native/differential/Wasm stages (`/tmp/haxeon-gate-map-effects-shadowing.log`).
  Exosuit `./scripts/build.sh` exited 0 (`/tmp/exosuit-build-map-effects.log`).
- Source checks also retrieve/validate declarations in `FieldInference`,
  validate store collection after an effectful walker call, and check the
  store-mode precondition in `dottedFieldStore`. No type relations changed.
- Bootstrap passes those failures, then exits 1 at `EqualityGenerator.hx:37`:
  nullable request lookups are dereferenced without checks. Add checked
  required lookups, retry convergence and preserve all pending M8 gates.

### M8.2 — checked equality generation (verified compiler-source slice)

- Haxeon `5cf74eb0` validates required entries before consuming request
  metadata or reachable types. One generic checked lookup preserves types and
  reports an internal missing-key invariant rather than dereferencing null.
- Full compiler `./scripts/test.sh` exited 0: formatting, 370/370 driver cases
  and all native/differential/Wasm stages. Log:
  `/tmp/haxeon-gate-equality-requests.log`.
- Bootstrap passes typing all 443 sources and reaches encoding, then exits 1:
  `HashLink String cannot contain NUL; use Bytes for binary data`. The two
  source literals are dependency-cache separators in `CompilationContext` and
  `FrontendCompilation`. They are text cache keys, not a binary payload.
  Next: share a collision-free length-prefixed text encoder, add regressions
  for empty components and delimiter collisions, then retry convergence.
- M8 acceptance and both compiler modes remain pending; no writer validation
  or language types have been weakened to bypass this failure.

## Completed records

### M7.2–M7.3 — Linux automation and relocatable packaging

- ABI v16 distinguishes committed text from IME preedit state and owns candidate
  placement; Pragtical font groups supply configured fallback faces. Real SDL
  automation covers Unicode clipboard/file names, Ctrl/Shift/Alt chords, resize,
  keyboard-only editing/navigation and the full M0 workflow including split,
  project search and plugin reload. Default essential text roles meet WCAG 4.5:1.
- `release.lock` pins Haxeon, Pragtical renderer and HashLink. Release builds reject
  modified inputs, rebuild the runtime atomically, package all modules, language
  tooling, stdlib, fonts, defaults, docs and notices, and use executable-relative
  lookup rather than the launch cwd or a mutable sibling at runtime.
- `scripts/test-release.sh` passed from a fresh extracted location, including the
  bundled real Haxeon diagnose/fix/build route. `scripts/ci.sh` composes compiler,
  headless, SDL and release gates. Windows/macOS, a real desktop IME candidate
  session and a physical mixed-DPI transition remain explicitly unclaimed.

### M7.1 — performance and endurance

- `2130565` adds the fixed small-file, 10 MiB, 1 MiB-line, document soak,
  plugin-reload and 10,000-file index/search fixtures. Profiling replaced linear
  visual-row lookup, repeated width scans, collapsed-selection offset scans,
  highlight prefix rescans and quadratic project snapshot construction.
- `6a605d7` gives the cooperative scheduler a six-millisecond wall-clock slice in
  addition to its step ceiling and turns the latency, idle CPU, progression and
  cancellation budgets into executable benchmark failures. Both benchmark scripts
  prepare their own headless native runtime.
- On the recorded i5-13600K Linux host, typing p95 was 0.051 ms, 10 MiB scrolling
  p95 was 0.052 ms, idle service CPU was 2.00%, the maximum 32-step indexing turn
  was 6.37 ms, replacement-search turns stayed below 0.98 ms, and peak RSS was
  170,708 KiB. First/last soak windows did not show progressive latency. Exact
  fixtures, limits and results are in `docs/release-qualification.md`.
- `SKIP_FORMAT_CHECK=1 ./scripts/test.sh`, both benchmark scripts and
  `./scripts/build-sdl.sh` exited 0. The format skip remains the documented
  unrelated repository baseline; changed files pass `git diff --check`.

### M6.3 — language service plugin

- `697b19c` adds a bounded UTF-8 `Content-Length` JSON-RPC transport with
  nonblocking atomic writes, response correlation, timeout cancellation,
  bounded stderr and malformed/oversized-frame rejection.
- `d26b462` adds the restartable client with initialize/shutdown, incremental
  UTF-16 document synchronization, versioned diagnostics, hover, completion,
  definitions and revision-checked transactional edits. `ad23720` exposes owned
  editor commands, diagnostic decorations and server-initiated workspace edits;
  `bd3eb44` gates features from negotiated capabilities.
- The deterministic fake server covers out-of-order responses, split Unicode,
  stale diagnostics, unsupported capabilities, server requests and forced
  restart. `77394ff` adds `scripts/test-haxeon-lsp.sh`; it proves the real Haxeon
  server diagnoses an invalid edit, clears the diagnostic after correction, and
  the corrected fixture builds and executes.
- Required Haxeon work is independently committed through `21a996b`: sound call
  invalidation and initializer ownership, native JSON/reflection, Dynamic value
  equality, null-field representation, intrinsic `Std.isOfType`, and a cwd-safe
  LSP launcher. The compiler suite passed 205/205; the editor headless suite,
  real-server smoke and SDL artifact build all exited 0.

### M6.1 — syntax and presentation

- `93eaaf6` expands reference-backed Haxe/Haxeon, C, C++, JSON, Markdown, Lua and
  shell highlighting with multiline lexical states and bounded repair.
- `a34a1d7` adds bounded, syntax-aware bracket matching. `3f3416a` makes wrapped
  and folded visual rows authoritative for painting, scrolling, hit testing,
  selection and vertical movement, with automatic expansion for hidden caret and
  search targets.
- `d232752` adds an owner-scoped completion-provider registry. The built-in
  document-word provider uses the same extension path as plugins, and Ctrl+Space
  opens the shared command UI with revision-checked prefix replacement.
- Focused acceptance covers multiline repair, wrapped movement and selection,
  physical search reveal, completion insertion and provider cleanup. The full
  headless suite and SDL build passed after the implementation.

### M6.2 — background processes and output

- `22c4628` adds generation-checked native process handles with exact argument
  arrays, cwd/environment configuration, separate nonblocking output, exit status,
  cancellation and manager/platform shutdown cleanup. Headless and SDL builds use
  the shared implementation.
- `080b09f` adds deliberately selected project tasks, bounded 10,000-line/1 MiB
  retention, a Build Output view and clickable file/line diagnostics. `2ce8368`
  exposes subprocesses through plugin ownership and proves unload and failed
  activation retire them.
- `0813b05` defines this repository's own headless test/build and SDL build tasks.
  The automated smoke launches the real headless build through the editor task UI;
  atomic artifact publication prevents rebuilding a currently running editor from
  truncating its mapped runtime libraries.
- Acceptance covers spaces in arguments/cwd, environment values, a 200 KB pipe
  flood, UI byte/line limits, nonzero exit, cancellation, stale handles, editor
  shutdown and diagnostic navigation. The full headless suite and SDL build pass.

### M0.1 — trustworthy baseline

- Native platform tests, every Haxeon application test entry, and the SDL graphical artifact build successfully.
- `./scripts/test.sh` exited 0; `./scripts/build-sdl.sh` exited 0.
- The pre-existing top-level `README.md` edit remains outside implementation commits.
- A graphical compile does not prove mouse, IME, DPI or screen usability; the interactive M0.3 route remains pending.

### M0.2 — current search slice

- Commit: `35d73f0 Bind document search results to revisions`.
- Matches carry document identity, buffer state and matched text. Selection and replacement reject stale ranges. Editing, undo and active-document changes refresh or invalidate results.
- Replace-all is one buffer edit and therefore one undo operation. Cancelling find clears transient highlights across views. A named command returns workspace search to the project sidebar.
- Coverage reproduces edit-after-find, undo refresh, document switching, replace-all/undo, cancelled highlighting and multi-project result activation.
- `./scripts/test.sh` exited 0 after the final changes.

### M1 — safe file lifecycle

- `b294ba2` added pathless, uniquely identified untitled documents and Save As,
  with duplicate-open and overwrite collision handling.
- `840781f` made backing paths explicitly optional throughout the document and
  versioned recovery models.
- `38328ca` unified tab close, pane close and native quit behind one
  Save/Discard/Cancel coordinator, including shared-document and failed-save cases.
- `91b0234` bounded recovery retention to the newest 50 snapshots and retires an
  accepted snapshot before regenerating state for documents that remain dirty.
- Existing atomic persistence, external-change reconciliation, BOM/newline
  round-trips, missing/corrupt recovery and injected failure cases complete the M1
  headless acceptance routes.
- `./scripts/test.sh` exited 0 at editor HEAD `91b0234`; interactive prompt behavior
  remains part of the pending M0.3 graphical smoke route.

### M2.1 — positions, transactions and view ownership

- `9d5ddf3` replaced the single buffer callback with structured, independently
  releasable change subscriptions and documented UTF-16 code-unit positions at
  Unicode scalar boundaries.
- `942fdbc` began transforming inactive-pane ranges through shared edits.
- `ec158d3` removed caret and selection state from `TextBuffer`; every editor view
  now owns its selection while documents share text and history. View teardown
  releases subscriptions.
- `98a0109` added explicit multi-replacement transactions, adjacent typing groups,
  movement boundaries, redo invalidation and initiating-view selection restoration.
- Tests cover emoji surrogate boundaries, the declared combining-mark behavior,
  independent split-pane cursors, passive range transformation, grouped typing,
  overlapping-transaction rejection and transaction undo/redo.
- `./scripts/test.sh` and `./scripts/build-sdl.sh` both exited 0 at `98a0109`.

### M2.2 — clipboard and navigation

- `a6b5cf8` added platform ABI v5 clipboard read/write with deterministic headless
  storage, SDL integration, HashLink UTF-8 conversion and Ctrl+C/X/V editing.
  Paste normalizes CRLF/CR to the buffer's logical LF representation and remains
  one undo unit.
- `d61c88a` added selection collapse, word/page/document movement and selection,
  double/triple-click selection, SDL click-count forwarding and bounded drag
  autoscroll driven by an injectable clock. Page keys are covered by ABI v6.
- Tests cover multiline/non-ASCII clipboard round-trips, cut/paste undo, viewport
  page movement, word/document ranges, click selection and timed outside-viewport
  dragging.
- `./scripts/test.sh` and `./scripts/build-sdl.sh` both exited 0 at `d61c88a`.

### M2.3–M2.4 — coding edits and multiple selections

- `f16a506` added single-transaction indent/unindent, autoindent, duplicate/move/
  delete/join line and syntax-driven comment commands. Typed `editor.tabWidth` and
  `editor.insertSpaces` settings select spaces or tabs per project.
- `e9d42aa` introduced normalized selection sets, stable primary selection,
  document-order clipboard distribution, next-occurrence selection, selection-set
  history snapshots and rendering for every caret/range.
- `b5be0c3` extended movement, insertion/deletion, indentation, comments and line
  transformations across multiple selections. `4987556` covers blank, partial and
  trailing-newline indentation semantics.
- Tests cover reversed/overlapping ranges, multiple insertions and deletions,
  distributed copy/paste, next occurrence, undo/redo range restoration, mixed
  indentation, blank/final/trailing lines and one-transaction command behavior.
- `./scripts/test.sh` and `./scripts/build-sdl.sh` both exited 0 at `4987556`.

### M3.1 — reusable command input

- `d10ddf8` gives command input its own reusable text buffer and selection,
  clipboard editing, undo/redo, history traversal and completion without creating
  a document.
- Command results use deterministic exact/prefix/path-aware fuzzy ranking with
  stable tie-breaking and preserve the selected identity across provider updates.
- Named commands provide keyboard-only command execution, file opening and
  go-to-line/column behavior; file completion operates on workspace paths.
- Headless application and command-view tests cover empty, unmatched and Unicode
  queries, completion, cancellation, history and navigation.

### M3.2 — layout and navigation

- `86dd34e` adds directional pane focus, tab movement and reordering, lifecycle-
  coordinated close controls, sidebar toggle/resize, active-tab overflow,
  physical split clamps and draggable editor scrollbars.
- Modal command input owns pointer and wheel routing without moving editor focus,
  preventing an inactive document from being changed through prompt input.
- Headless tests cover focus, tab movement/reordering, narrow layouts, close
  routing, modal input isolation and scrollbar dragging; the SDL artifact builds.
- `8e56b15` makes the platform coordinate contract explicit: window dimensions,
  pointer events, clipping and drawing all use logical points while display-scale
  changes update the backing renderer and propagate through ABI v11. Headless
  tests preserve logical hit-test/layout coordinates at a synthetic 1.75 scale.

### M3.3 — status and feedback

- `c8004f4` adds a reusable status view with path, dirty state, caret, selection,
  indentation, UTF-8/BOM and newline details; bounded notification and error
  histories; an inspectable error command; and reusable typed confirmations.
- File, recovery, configuration and plugin failures feed actionable notifications
  and the retained error log. Escape now cancels the lifecycle transaction behind
  a close confirmation instead of merely hiding its prompt.
- `8e56b15` centralizes shell/editor colors into semantic theme roles, including
  focused, hovered, selected, muted and disabled states.
- `73517b6` covers bounded retention, plugin diagnostics, status transitions,
  Escape cancellation/re-entry and the inspectable log. `./scripts/test.sh` and
  `./scripts/build-sdl.sh` both exited 0 at that editor HEAD.

### M4.1 — scheduling and project index

- `970aee6` introduces a cooperative round-robin scheduler with stable job IDs,
  replacement generations, stale-handle rejection, cancellation and an exact
  per-update step budget. `76a301a` moves project enumeration and bounded polling
  onto those jobs and gives the tree, file picker and search one indexed file set.
- Scans publish the initial tree incrementally and publish later reconciliations
  only from the current generation. Exclusions apply before descent; canonical
  directory identities prevent the benchmark's symlink cycle from recurring.
  Removing a project cancels its scan and retired state rejects later publication.
- `11dcc5c` adds `scripts/benchmark-project-index.sh`. On 2026-09-08, a 10,000-file
  fixture (100 directories × 100 files plus a root symlink cycle) completed in
  100 one-directory updates, with 100 simulated input-service ticks and a maximum
  observed update of 40.499 ms on an Intel Core i5-13600K with 31 GiB RAM.
- The full headless suite and SDL artifact build passed at `76a301a`; the dedicated
  benchmark passed at `11dcc5c` including cancel/reopen stale-result checks.

### M4.2 — search and replacement

- `00340f2` moves workspace search onto debounced, generation-cancelled scheduler
  jobs. Results stream in bounded batches with caps and preview limits; dirty open
  buffers take precedence over disk. Binary, oversized and unreadable files become
  retained partial-result diagnostics rather than aborting the query.
- `c0acd51` adds case, whole-word, path and PCRE2 regular-expression searches,
  including capture-aware replacement, invalid-pattern reporting and scalar-safe
  progression after zero-width matches. Document replacement remains one undoable,
  revision-checked buffer transaction.
- `1460df1` adds an explicit project replacement preview/apply route. Every file is
  revalidated after preview; open documents receive independent undoable edits and
  disk files use atomic M1 publication with per-file applied/conflict/failure
  outcomes. The complete previous contents and expected post-write contents of the
  latest disk batch are retained at `replacement-backup.conf`; restore is explicitly
  best-effort per file and refuses subsequently changed files, not a cross-file undo.
- `20b95b0` proves binary, 5 MiB oversized and permission-denied inputs as distinct
  partial failures. Rapid replacement generations, result caps, dirty precedence,
  filters, regex captures/zero-width/invalid cases, disk conflicts, backup restore
  conflicts and preview/apply equality are covered headlessly.
- The complete headless suite and SDL artifact build passed after the final M4.2
  implementation. Interactive confirmation behavior remains in the M0.3 smoke route.

### M4.3 — file operations and sessions

- `c5543c0` centralizes collision-checked file/folder creation, rename/move and
  recoverable deletion. Directory moves rewrite every nested open-document path;
  dirty documents save only to the new location. Deletion moves entries into the
  application state trash and detaches affected buffers as dirty pathless documents
  so recovery and Save As remain available.
- `7c2c6bf` introduces session v2 and recovery v3. Pane tabs reference clean paths
  or stable recovery identities, allowing multi-root split layouts, active views,
  caret/scroll state and dirty/pathless contents to survive restart without embedding
  recovery text in the session. Missing projects/files/recovery entries and malformed
  layout records are skipped. Session writes settle behind a 750 ms debounce and
  flush explicitly during graphical shutdown.
- Headless coverage exercises file and folder collisions, nested directory moves,
  dirty saves after rename, recoverable deletion, missing project/tab entries,
  malformed sessions, stable untitled recovery, debounced publication and shutdown
  flush. The complete headless suite and SDL artifact build passed at `7c2c6bf`.
- The 10,000-file project benchmark was rerun at the M4 exit gate: 100 updates and
  100 input ticks, with a maximum observed update of 51.621 ms on the previously
  recorded Intel Core i5-13600K / 31 GiB host.

### M5.1 — configuration

- Haxeon `37c062a` adds the standard `Sys.systemName()` platform boundary and a
  runtime regression; the compiler/runtime gate passed all 201 tests.
- `edeaaa0` makes configuration subscriptions independently disposable, converts
  read failures into retained diagnostics, preserves last-good settings across
  invalid bytes and detects restoration of previously accepted bytes.
- Every semantic theme role, font, indentation, keybinding, exclusion and search
  setting participates in defaults < user < active-project layering. Changes apply
  live; project disposal releases its subscription, keymaps replace configured
  bindings, and font replacement destroys the retired native handle.
- Project files remain versioned data and unknown keys reject the complete layer.
  Linux/BSD XDG, macOS, Windows and authoritative portable locations are defined in
  `docs/configuration.md` and selected using the host system name.
- Headless acceptance covers precedence, invalid rollback/recovery, visible project
  diagnostics, project switching, default reset, subscription cleanup, live theme,
  single keybinding installation and stale font-handle rejection. The complete
  headless suite and SDL artifact build passed at `edeaaa0`.

### M5.2 — stable editor API

- `2c1f57e` introduces versioned typed capabilities for transactional document and
  selection edits, configuration snapshots, owned panels, document events and
  cooperative jobs. Plugin contexts release callbacks, jobs, panels, bindings,
  commands and syntax contributions in reverse ownership order.
- Haxeon `c4310fa` supports calls through arbitrary expression values, which keeps
  reverse-order disposer invocation idiomatic. `bf4166f` fixes lexical static-field
  resolution in switch cases rather than requiring editor-side pattern workarounds;
  the compiler/runtime gate passed all 202 functional tests.
- `fe5216f` supplies dynamically compiled plugins with the versioned
  `pragtical.Editor` SDK and opaque, plugin-owned host tokens. The example performs
  undoable document edits, contributes and updates a panel, observes document
  events and retains those capabilities through a compatible body patch.
- Manifests declare independent manifest and API versions; incompatible versions
  produce visible diagnostics. Tests prove unload retires the panel, event callback,
  job, command and syntax registrations while preserving intentional text edits.
  API ownership, conflict order and compatibility are documented in
  `docs/plugin-api.md`.
- The complete headless suite and SDL artifact build passed at `fe5216f`.

### M5.3 — reload reliability

- Haxeon `c4e57eb` adds portable lightweight filesystem metadata and `d3ab07b`
  exposes HashLink thread creation through a typed stdlib boundary; the complete
  compiler/runtime gate passed all 202 functional tests after each final change.
- `21dd513` makes structural reload a context ownership transaction and restores
  the previous runtime, state and registrations if replacement activation fails.
  `5d27a1b` observes metadata on a 250 ms cadence, debounces for 300 ms, audits
  coarse timestamps periodically and deduplicates retained diagnostics.
- `d455d5d` provides command-palette enable, disable, reload and diagnostic views.
  Disabled definitions remain available while every owned command, binding, panel,
  syntax, event and job is disposed before reactivation.
- `434f2b4` serializes dynamic compilation on a worker while publishing only from
  editor updates. `c36783a` also moves source reads and coarse-timestamp audits off
  the event loop and rejects obsolete or unloading in-flight publications.
- `bd752bd` specifies runtime `stateVersion()` compatibility: structural domains
  receive saved state only for equal versions, while compatible body patches retain
  their live runtime and host resources. `docs/plugin-development.md` documents the
  runnable example, local discovery, controls, failure behavior and current SDK gap.
- Acceptance coverage repeatedly performs compatible and structural reloads,
  injects compile, activation and source-removal failures, changes state versions,
  unloads during compilation and asserts no duplicate or stale callbacks. The full
  headless suite and SDL artifact build pass; interactive behavior remains in M0.3.

## Previously delivered roadmap foundations

- `028c7fa`: safe file lifecycle, recovery, project polling and restorable split workspaces.
- `21ba9de`: exception-based atomic write integration and embedded-NUL byte test.
- Haxeon `e573f8f`: byte-oriented, error-reporting atomic publication with POSIX durability and Windows replacement support.
- `e9b47c2`: layered configuration and workspace sessions.
- `e08b0e4`: command-view document/workspace search.

These commits satisfy only the behaviors evidenced by their tests; they do not mark an entire later milestone complete.

## Compiler issue register

- Lambda bodies were previously pretyped outside their flow context. Haxeon `0643a3c` removed that unsound pass and added accepted callback/interface cases.
- Atomic publication required a runtime/stdlib facility rather than weakened editor persistence. Haxeon `e573f8f` owns that platform boundary.
- Haxeon `7598300` preserves nullable narrowing for captured locals in callbacks;
  positive and negative regressions pass with the full compiler suite.
- Haxeon `4bd73cf` compares runtime strings by value in statement switches rather
  than relying on pointer identity; its runtime-created-string regression passes.
- Haxeon `14eeadd` propagates assignment and refinement facts from completing block
  expressions, fixing concise try-expression narrowing without weakening nullable
  field access. Accepted class/interface and rejected continuing-catch cases pass.
- Haxeon `73c7ca3` replaces substring-emulated `EReg` with HashLink's PCRE2 engine,
  including captures, invalid-pattern exceptions and terminating zero-width global
  replacement. Haxeon `1512bc7` captures the receiver for implicit instance-field
  assignment in lambdas instead of emitting an invalid raw `this` local.
- Reinspect repository ownership and run the compiler gate before further compiler edits.

## Blockers and pending manual checks

- M8 gates pass, including real LSP, UIKit workflow and unpacked release.
- The SDL-era graphical route (M0.3) and its automation scripts were removed by the
  UIKit port; M8.3 replaces them. Desktop IME and physical mixed-DPI checks stay pending.
- Windows (ConPTY, named pipes, atomic publication) and macOS are unclaimed.

## Record template

```text
Task ID and state:
Timestamp:
Repository HEADs and pre-existing changes:
Behavior delivered:
Design decisions and rationale:
Files / owned hunks changed:
Commands, exit codes and observed results:
Manual checks performed / still pending:
Compiler issue ID, reduced case, root cause and regression evidence:
Failures classified as introduced / baseline / environment:
Remaining work and exact next action:
```
