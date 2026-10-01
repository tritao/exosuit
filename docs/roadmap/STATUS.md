# Execution ledger

Last updated: 2026-10-01.

## Current checkpoint

- Active tasks: **M8.1** acceptance gap (dynamic plugin integration) and **M8.2**
  (compiler/build agreement). Native C/HXI migration committed as `f8939de`.
- Current evidence: `./scripts/test.sh` exits 0 with Unicode native regression
  coverage, but its pre-existing dynamic-plugin failure suppression remains;
  this is not a pass of every project and M8.1 is not yet complete.
  `./scripts/build.sh` still exits 1 at `CommandView.hx:297` E1005.
- Exact resume: reduce nullable provider-field access in `CommandView.filter`
  using both compiler modes, register accepted/rejected compiler regressions,
  and fix the general rule. Restore source-plugin embedding and remove the
  suppression before claiming the M8.1 acceptance gate.
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
| M8 | In progress | C/HXI migration `f8939de` removes native string abort; headless gating tests pass; dynamic plugin project suppressed; graphical build still hits E1005; integration/release gates pending |
| M9 | Not started | Depends on M8 |
| M10 | Not started | Depends on M8, M9.1–M9.2 |
| M11 | Not started | Depends on M8; independent of M9/M10 |
| M12 | Not started | Depends on M9, M11.1, M11.4 |
| M13 | Not started | Depends on M11.2 |
| M14 | Not started | Depends on M11–M13 |
| M15 | Not started | Depends on M8.1, M8.2; scheduled right after M8. Reference: materia `app/web` at `816372dd`, Haxeon `fba71015` |

## Implementation records

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

- M8 gates are red (see Current checkpoint); every follow-on milestone waits on M8.
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
