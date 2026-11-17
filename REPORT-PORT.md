# Exosuit on latest haxeon: overnight port report (2026-11-17/18)

**Status: done.**

- The port builds and runs on latest haxeon.
- Every GUI scenario gives the same check results as the baseline.
- It allocates less per frame in every allocation run, and up to 72 % less overall.
- It renders 35–64 % fewer frames where the baseline rebuilt on every pointer move.
- Input latency is equal within noise.
- Nothing is pushed.

## What was done

Exosuit moved from haxeon `fa128931e` to upstream haxeon `origin/main` `ff7e29aac`, which is 991 upstream commits
newer. The pin is `5d2c7ab19`: upstream plus 21 of our commits. The goal was that the app behave as the baseline does
while using upstream's reactive, low-allocation UI paths.

| | |
|---|---|
| Port worktree | `C:\Users\corbi\projects\exosuit-port`, branch `haxeon-port` (on main `6ee0435b`) |
| Topic stack | branch `haxeon-port-topics`, same tree as `haxeon-port`, rebuilt at the end (see Commits) |
| Baseline | `C:\Users\corbi\projects\exosuit-baseline`: main `6ee0435b` on old haxeon `fa128931e`, built clean |
| Docs | `.port/docs/` (git-excluded): A = upstream inventory, B = UI architecture, C = plan, E = capture commands and perf diagnosis |

Main moved from `2bf957d9` to `6ee0435b` (suit was renamed to exohost) while the night's work ran. The port was rebased
onto it before any port commit, and the baseline was rebuilt at `6ee0435b`.

## Commits per repo

### haxeon: branch `exosuit-upstream` = `origin/main` (`ff7e29aac`) + 21 commits, tip `5d2c7ab19`

Our 51 commits on `exosuit-m19` were sorted into three groups. Each commit's reason is in
`.port/docs/A-our-commits.md`.

- **Kept: 21 topic commits.**
  - UI host: window placement, activation and front, safe-area, touch, Back hook.
  - Detached starts inside a job that forbids breakaway.
  - Android: chdir on API 34+, the UIKit frame-in-flight retry, NativeKit TLS and UIKit build options, font fallbacks,
    imeAction.
  - ProfileNativeTrace.ticks.
  - Windows process-alive check.
  - LiveHost: module and entry; `run --watch` events; `build --compiler-only --live`; resumed-session lambda-capture
    patches.
  - TreeView.focusItem, and the retention check settling focus.
  - Glyph atlas retirement drops retained geometry.
  - Windows native publish moves a held library aside.
  - SearchPicker can start with a query selected.
  - RpcClient.retryNow.
- **Already upstream: 9 commits.** The nativekit bumps, the parser fixes, HaxeonBuild path parts, the stdlib Path
  helpers, and the CLI/worker source fixes.
- **Superseded by upstream's design: 20 commits.** Among them the tooltip pointer input, the packed-type hash, the
  self-hosting check, Process.run on Windows, the FFI audit and the wasm scripts. The merge commit is also dropped.

Submodules: hashlink stays at upstream's pin `06874e96`, and none of our hashlink commits is still needed. Our nativekit
work is already in upstream's pin `dff231d8`, and libffi is unchanged.

Branch `tooltip-scope-fix` = `exosuit-upstream` + `7f5ad7510`. It fixes a UI bug the port found: a render scope that
reruns alone breaks a positioned tooltip ("Layout node IDs must be unique"), and `commandShortcutFilter` was not carried
to a scope's new root. It has a regression test, and the F3 repro passes. It is **not yet in the port's pin** (see Open
issues).

### exosuit: two branches, both on main `6ee0435b`, with identical trees

- **`haxeon-port`** is the working history: about 80 commits, one per item and fix, written as the night went.
- **`haxeon-port-topics`** is the same final tree as 10 topic commits, plus an 11th that adds this report. Push this
  one:
  1. Pin haxeon to `exosuit-upstream` (`5d2c7ab19`).
  2. Scripts and build tooling find the HashLink VM through Haxeon's output path table (`scripts/haxeon_paths.py`).
     `build-windows.ps1` builds the `windows-msvc` preset. Android, web, devtools bundles and build-report scripts
     follow.
  3. Non-UI sources on the new compiler and stdlib:
     - `ChildProcess.spawn`;
     - `BuildOutput` renamed to `BuildLog`;
     - typed native enums and flags;
     - `createDirectory` throws on failure;
     - null-checked `pop`/`shift`/`parseInt`;
     - the dynamic-plugin compiler API;
     - exohost's language-server and VM paths.
  4. The app on the reactive UI: everything under "What moved to the new UI model" except the three scopes, plus the
     `EditorPane` retained-geometry fix.
  5. Tests on the new API, and the `port-probes` suite.
  6. The compiler-bugs doc: the bugs the port found.
  7. The capture harness: the `port_*` scenarios, `port_frames.py`, the scenario repairs, and `measure.ps1`'s cleanup
     of leftovers.
  8. **F1:** the terminal rows in a tracked scope.
  9. **F2:** the chat session panel in a tracked scope.
  10. **F3:** the editor pane in a tracked scope.

  F1, F2 and F3 are each one commit and can be reverted alone. The commits before the last are not built on their own,
  because the API change spans sources, app and tests.

## What moved to the new UI model

- **Root invalidation.** The per-frame root key string is gone. In its place is a constant key, a stable `view` closure,
  a `frameTick` signal, and `RootChangeDetector`, which compares the old key's components as scalars without allocating.
  A frame in which nothing changed allocates nothing in `submit`.
- **Tree models.**
  - The SCM and Workbench tree models are `Observable`, so `TreeView` keeps its index between frames.
  - The directory and workspace file trees, which have worker threads, use one UI-thread `Signal` read by every
    accessor.
  - `refreshBranches` and `revision()` polling are gone.
- **Commands.** The polling of `commands.refresh()` and `revision` is removed. Command enablement follows tracked
  state, and a successful command invocation, deferred focus and tree expansion each request a frame explicitly.
- **Widgets.** About 154 Button writes after construction, and the Text and Icon inputs, now go through constructors.
  Buttons are render scopes, so hover and press patch locally.
- **Typed input.** `UiModifier`, `StyleState` and `AccessibilityState` are flags; event phases are `UiEventPhase`.
- **Writes during a build.** Panels that wrote state during a build were changed to write it before the build or in a
  handler: problems, settings, explorer, context files and workbench sync.
- **Tracked scopes.**
  - **Terminal (F1):** output, cursor, selection, scroll and typing rebuild only the terminal's rows.
  - **Chat panel (F2):** typing, toggles and transcript scrolling rebuild only the chat panel.
  - **Editor pane (F3, partial):** scroll, reveal, search marks and the definition underline rebuild only the pane.
    Caret moves and typing still rebuild the whole view until the tooltip fix is pinned.
- **Smaller changes.**
  - The minimap repaints in place on scroll and fade, with no root rebuilds.
  - The settings path preview is a local `State`.
  - The FPS title is a tracked value.
  - The old menu and tooltip styles are restored over upstream's new theme.
- **Non-UI.**
  - `Process.spawn` became `ChildProcess.spawn`.
  - `build.BuildOutput` was renamed to `BuildLog`, because it collided with haxeon's module of that name.
  - Every script finds the HashLink VM through `scripts/haxeon_paths.py`, since upstream's new VM layout has no
    `.tools/hashlink`.
  - The dynamic-plugin compiler API and the Android sources are ported.

## Tests

### Build gate

- The haxeon toolchain builds: `cmake --preset windows-msvc`, Release.
- `scripts/build-windows.ps1 -SkipBootstrap` exits 0.
- All six compile gates are clean: root, agent, agent/terminal-host, exohost, graphical, devtools. So is the Android
  compile.
- The haxeon live test subset passes 8/8, plus the new resumed-capture test.
- `haxeon scripts/check-self-hosting.hx` on the pin passes its gates: the compiler builds itself to a fixed point
  (stage 1 = stage 2), and the self-hosted compiler builds all 9 entry points with no known gaps. Its later "programs"
  step fails on Windows at upstream main as well; that is an upstream bug, recorded.
- After the last fix the app was rebuilt from the clean tree in 73 s. G01 on those final binaries passes 7/7, and 7/7
  with the retention check.

### Targeted suites (test-windows.ps1)

- **50/50 pass.** The list is in C-port-plan.md section 9 (core, commands, terminal keys, quick picker, status bar,
  tabs, workbench tree, drag and layout, problems, editor and document, session chat, SCM, workspace catalog and
  attachment, live build feed, plugins, RPC and others) plus port-probes. Port-probes is a headless suite that pins down
  the eight reactive-runtime rules the port relies on.
- **Headless live check.** An edit was patched into a running program within 0.5 s, and `live-status.py` reported ok.
- **exohost row.** It times out only because this session runs inside an Exosuit terminal. Exohost hides processes below
  a terminal host by design. Rerun it from a plain shell.

### Phase E: GUI captures, port vs baseline (same harness, one at a time)

The final pass ran on a quiet machine, 08:55–09:16, with port at `6d9d622f`. The run folders are
`docs/benchmarks/perf-harness/runs/{port,base}-<id>`. Side-by-side comparisons are in `runs/compare-<id>.txt`, and
`.port/parity.py` compares the checks of each pair.

**Functional parity: identical in every scenario.** Each check passes or fails the same way on both sides. The only
exception is G07, where the port does better.

| id | scenario | port | base |
|---|---|---|---|
| G01 | caret, typing, scroll, search, Settings tab open/close | 7/7 | 7/7 |
| G02 | idle, hover, idle again | 5/5 | 5/5 |
| G03 | Files tree: keyboard and pointer expand/collapse, outside create and delete | 11/11 | 11/11 |
| G04 | side bar header actions on hover and focus, tooltip, context menu | 8/8 | 8/8 |
| G06 | palette open/close and typing, Ctrl+S clears the unsaved mark | 7/8 | 7/8 (same check fails on both: scenario gap) |
| G07 | FPS title | 6/9 | 4/9 (the baseline's title never shows the reading in captures) |
| G08 | chat: typing, fake reply, slash suggestions, transcript scroll | 11/11 | 11/11 |
| G09 | terminal typing, output, scrollback, selection | 6/7 | 6/7 (same check fails on both: scenario gap) |
| G09r | real keystroke → echo on screen | 135.5 ms median | 131.5 ms median |
| G10 | editor tabs sweep | 26/26 | 26/26 |
| G11 | workspace/group switching, real input | 22/22 | 22/22 |
| G11b | workspaces | 10/10 | 10/10 |
| G12 | live edit applied without a restart | 7/7 | 7/7 |
| G13a/b/c | Workbench tree, menus, session drag | 11/11, 14/14, 11/11 | same |
| G14 | right panel tabs, Changes after an outside edit, bottom panel, Workbench keys | 10/10 | 10/10 |
| G16a/b | new workspace; two windows with tabs | 25/25, 10/10 | same |
| G17 | terminals survive their window | 14/14 | 14/14 |

**Allocations (census from the 20th frame to exit): lower on the port in every scenario.**

| id | bytes per rendered frame, port / base | objects per frame, port / base | total bytes, port / base |
|---|---|---|---|
| G02 idle+hover | 599 KB / 677 KB (−11 %) | 9 139 / 10 751 (−15 %) | 186 MB / 656 MB (−72 %) |
| G01 editor | 410 KB / 454 KB (−10 %) | 9 125 / 10 473 (−13 %) | 241 MB / 244 MB |
| G08 chat | 748 KB / 791 KB (−5 %) | 11 745 / 12 819 (−8 %) | 106 MB / 184 MB (−42 %) |
| G09 terminal | 972 KB / 1 019 KB (−5 %) | 15 805 / 17 747 (−11 %) | 304 MB / 318 MB |

**Frames rendered for the same scenario: far fewer where the baseline rebuilt on every pointer move.**

| | G02 hover | G04 affordances | G14 panels | G08 chat | G07 FPS | G01 editor | G09 terminal |
|---|---|---|---|---|---|---|---|
| port | 348 | 134 | 113 | 162 | 235 | 604 | 353 |
| base | 969 | 278 | 251 | 270 | 319 | 567 | 334 |

**Frame cost.** Measured with a per-frame instrumented build, port side only: a typing frame takes 2–3 ms to build and
4–5 ms to reach the screen. Scroll and search frames take 0.4–1.3 ms. Opening and closing the Settings tab takes
10–15 ms, because the root is built 3 times in that frame (a lead not yet followed).

**Input → first frame: mixed.**

- **Biased by baseline animation.** The baseline runs a 240 Hz hover animation, and tooltips and scrollbars fade, so
  some frame always lands within 4 ms of any input. Its input-to-frame figure therefore partly measures an animation
  frame, not a response. This affects G02 hover (port 43.5 ms vs base 18.6), G04 header and tooltip, and the frame
  interval p90 of G14.
- **The other gaps are noise, not delay.** A single run showed the port slower in several stages: G08 chat slash
  suggestions 82.7 vs 34.4 ms and reply 96.4 vs 55.9; G01 scroll 77.4 vs 65.2; G14 SCM 78.2 vs 66.0; G07 busy 66.6 vs
  43.9. Pooled over all runs, and counting only frames at least 20 ms after the input (an input cannot reach the
  window sooner), they are within noise:

  | Stage | Port | Base |
  |---|---|---|
  | slash | 70.3 | 78.0 |
  | reply, 10 presses per side | 54.5 | 51.7 |
  | chat scroll | 72.7 | 67.5 |
  | SCM | 86.6 | 82.6 |
  | editor scroll | 69.3 | 66.0 |
  | typing p90 | 72.1 | 70.1 |
  | busy | 70.0 | 68.2 |

- **Where the time goes on the port** (instrumented run `runs/port-g08-lat1`). Getting the input to the window takes
  8–73 ms, depending on the input. Delivery takes about 17 ms, then the frame starts 0.5 ms later and is drawn 6–9 ms
  after that. There is no added scheduling delay.
- **A 17 ms wait for scripted input, same on both sides.** A scripted input waits one 1/60 s loop turn, because
  `EditorControl.pollControl` polls `SyntheticInput` before it reads the link. It is left unchanged.
- **The final build matches.** `runs/port-g01-final` and `-final-verify` on the final binaries pass 7/7 and 7/7 with
  the retention check, and render no more idle frames than the baseline after scrolling or search.
- **The terminal with real input is equal:** 135.5 vs 131.5 ms median.
- **G07, after scrolling:** the scrollbar fade-out shows as 11 frames/s for about a second on the port. The baseline
  has the same burst, but its stage boundary puts it inside "busy".

**Retention check (G18, `HAXEON_UI_VERIFY_RETENTION=5`): passes everywhere after one fix.**

- **What it found.** At first every run with a document open stopped at start with "UIKit incremental tree differs
  from full encode ... style=0 text=1". In that message 0 means "differs", so the style differed and the text was
  equal.
- **The cause was real, in exosuit.** `EditorPane.applySourceGeometry` changes the text area's size and trailing
  scroll space in place after layout. It never announced the change (`willEditRetained`), so native layout kept the
  old geometry: scroll-past-end space, content size and hit area were out of date.
- **Why the port exposed it.** The baseline's per-frame root rebuilds hid this. On the port the pane is a tracked
  scope, so it rebuilds rarely and the stale geometry would have stayed.
- **The fix** is `b98ce09a`. After it every verify run passes the retention check:
  - G02, G01, G03 and G04 pass all their checks.
  - G06 and G09 fail only their known scenario gaps.
  - G08 and G14 were clean already.

**Run-condition note.** Idle numbers are only valid on a quiet machine. Exohost's `ScmDirectoryWatch` covers the repo's
git directory, and haxeon draws a frame for every file-change event. Any git activity during a capture adds frames, on
both sides alike.

## Push commands (nothing was pushed)

Push bottom-up: haxeon first, then exosuit.

```
# 1. haxeon: the upstreamable series (21 commits on tritao/haxeon main ff7e29aac)
git -C C:\Users\corbi\projects\exosuit-port\haxeon push origin exosuit-upstream
#    optional, the tooltip-in-scope fix on top (not pinned by the port yet):
git -C C:\Users\corbi\projects\exosuit-port\haxeon push origin tooltip-scope-fix

# 2. exosuit: the port as a branch (topic stack); merge to main once you have tried it
git -C C:\Users\corbi\projects\exosuit-port push origin haxeon-port-topics:haxeon-port
#    when landing on main (fast-forward; main is 6ee0435b, the stack's base):
git -C C:\Users\corbi\projects\exosuit push origin haxeon-port-topics:main
```

**Push the haxeon branches before you remove the `exosuit-port` worktree.** `exosuit-upstream` and
`tooltip-scope-fix` exist only in that worktree's own haxeon repository
(`C:\Users\corbi\projects\exosuit\.git\worktrees\exosuit-port\modules\haxeon`), and removing the worktree deletes them.

The baseline worktree `C:\Users\corbi\projects\exosuit-baseline` (detached at `6ee0435b`, built) is left in place for
side-by-side checks. Remove it with `git -C C:\Users\corbi\projects\exosuit worktree remove --force
C:\Users\corbi\projects\exosuit-baseline` when you are done comparing.

`exosuit-upstream` is new on tritao/haxeon. Upstream `origin/main` has moved past `ff7e29aac` since the night began
(it was at `2071f2aa5` at 03:30). Rebase the series before you open an upstream PR, then move the exosuit pin with it.

To try the port: `C:\Users\corbi\projects\exosuit-port` is built (`graphical\build\host\main.hl`). In a fresh pwsh,
dot-source `.port\env.ps1`, then run `python scripts\run.py`; it starts in isolated state
(`PRAGTICAL_PORTABLE=temp`).

## Open issues

- **Tooltip fix not pinned.** `tooltip-scope-fix` (`7f5ad7510`) is not in the port's pin yet. Pinning it unblocks the
  rest of F3: caret moves and typing would rebuild only the editor pane and status bar.
- **F4 (observing dock panels) was not done.** No candidate panel could be proven refresh-correct tonight. The reasons
  are in `.port/docs/C-handoffs.md`.
- **Leftover files in the user's checkout.** During integration, a port agent wrote two native-cache folders into your
  checkout, under `C:\Users\corbi\projects\exosuit\haxeon\out\native-cache\host\`: `exosuit-ui-native-5c873c8ea8` and
  `pluginhost-ef9e216aec`, plus their `.lock` and `.lock.holder` files. Deleting them was blocked by the permission
  rules, so please remove them.
- **Untracked `suit/` in your checkout.** Your checkout shows an untracked `suit/` folder, left over from the
  suit→exohost rename that another session landed on main. It is not from this work and was left alone.
- **Upstream has a Windows bug in check-self-hosting.** The step that compiles the program cases with the self-hosted
  compile server cannot start on Windows, because the compile server's secure token is unavailable when haxeon itself
  builds it. The compiler-bugs doc has the entry. The fixed point and all 9 entry points pass.
- **CLAUDE.md PATH rule is out of date.** It names `haxeon\.tools\hashlink`, which no longer exists. The new wording is
  in `.port/docs/C-claude-md-change.md`; it is yours to apply.
- **Scenario gaps.** G06 (palette toggles the side bar) and G09 (the last of 400 terminal lines) fail the same way on
  both sides, so they are scenario faults, not port regressions. The profiler scenario (`measure.ps1` without `-Drive`)
  fails at its metrics/export step on both sides.
- **FPS title.** The port shows the reading reliably. In the captures the baseline's title never showed it, because the
  old title bar rebuilds only when its inputs change. The difference is in the port's favour.
