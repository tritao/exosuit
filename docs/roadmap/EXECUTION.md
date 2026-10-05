# Execution contract

## Scope and repository ownership

Implementation covers this editor and necessary changes in the sibling
workspace. That is three git repositories:

- **materia** (`..`), a monorepo. Its directories include UIKit (`uikit/`,
  widgets and hosts), EditorKit (`editorkit/`, text model) and the reference
  editor's web pipeline (`app/web/`). This exosuit checkout sits inside it
  untracked.
- **Haxeon** (`HAXEON_ROOT`, default `../haxeon`), a materia submodule: the
  compiler, runtime and stdlib.
- **NativeKit** (`../nativekit`), a materia submodule: core native
  capabilities (PTY, local transport).

Read the applicable repository instructions before editing any of them.
Inspect `git status --short` in each at the start and preserve existing work.
State at the M8 baseline:

- materia `main` was at `816372dd` and pins Haxeon `fba71015` and NativeKit
  `0d66103f`.
- The Haxeon checkout matches its pin. It has a modified `vendor/hashlink`
  pointer and an untracked `hlprofile.dump`.
- The NativeKit checkout is off-pin at `2bb4c957`
  (`materia-numeric-locale`), a deliberate local state.

Do not assume authorship of the dirty paths, and do not move submodule
checkouts or pins except as part of an owned, recorded change.

Treat `PRAGTICAL_ROOT` (default `../pragtical`, branch `next`) as read-only
reference input, including its uncommitted work. Read its sources and tests to
port behavior. You may build it and run its binaries for interoperability
tests, using a separate build directory. Do not modify it.

No publishing, pushes, PR mutations or destructive cleanup are part of this
plan. Commit each verified slice on the current branch of the repository it
belongs to. In a sibling repository, first create a branch named
`exosuit-followon`, and never commit to `main`. Stage only owned hunks. Use
the commit attribution the session requires, and record every repository's
commit IDs in STATUS.

## Work loop

1. Read STATUS and select the first uncompleted task whose prerequisites pass.
2. Inspect its actual implementation and tests; adapt proposed class names to
   existing abstractions. Record meaningful design choices before broad edits.
3. Implement one coherent behavior through model, command and UI as applicable.
4. When compilation exposes a language issue, follow COMPILER-TYPING immediately.
5. Run focused behavioral checks, then the applicable integration gate.
6. Review the diff for regressions, unrelated edits and temporary workarounds.
7. Update STATUS with evidence, remaining limitations and the next exact action.
8. Continue to the next ready task. Do not stop merely because a milestone ended.

If blocked, record the exact failed command, diagnosis and required dependency;
continue independent ready work. Do not simulate unavailable capabilities or
claim completion because the UI displays a placeholder. Stop dependent work
when a real product decision or unavailable authority is required.

## Engineering rules

- Keep document changes transactional and notify all consumers with revisions.
- Use typed editor APIs. Native resources remain opaque generation-checked handles.
- Add ABI functions consistently to the C header, bridge, Haxe externs and backend;
  define failure semantics and update version checks when compatibility changes.
- Bound work per event-loop turn; cancel obsolete jobs and retire callbacks.
- Use deterministic headless services for clocks, file failures and asynchronous
  completion where practical. Test externally observable behavior, not getters.
- Keep application errors visible and recoverable. Do not swallow failures to
  make smoke tests pass.
- Do not undertake speculative rewrites of the buffer, compiler or renderer.
  Use measurements and reduced failures to justify architectural changes.

## Verification commands

Run from the editor root:

```sh
./scripts/test.sh      # headless core + tests/*/haxeon.json projects
python scripts/build.py # graphical/haxeon.json (UIKit host)
./scripts/test-skribidi-layout.sh # native layout differential + immutable/shared lifetimes
./scripts/ci.sh        # composed gate (M8.3 restores LSP and release stages)
./scripts/test-decoration-ui.sh # real retained decoration pixels (Xvfb + Python Pillow)
./scripts/test-workspace-ui.sh # separate-process restart, keyboard panes and session recovery
./scripts/benchmark-uikit-typing.sh # delivered input through completed frame; small|10mb|long-line
./scripts/profile-uikit-startup.py --fixture long-line --artifacts /tmp/exosuit-startup-new
python scripts/run.py /absolute/path/to/a/disposable/project
```

The test script runs the platform ABI check and the headless test projects
under `tests/`. Each new subsystem adds its own `tests/<name>/haxeon.json`
project, wired into `test.sh`. NativeKit changes add their own tests and run that
repository's test gate. Exosuit `native-packages/` carry their own tests.
Serialize builds and tests that share `build`
directories or the `uikit-native` CMake build; do not race them.

Run `./scripts/test.sh` from the compiler root after a core compiler change.
Its current stages include formatting, runtime bridge build, differential tests
and the test driver. Inspect current scripts before selecting focused cases.
Do not skip format checks or remove cases to obtain a green result.

Capture exit codes and concise results. Classify pre-existing failures with
baseline evidence. A graphical compile is not evidence of working mouse input,
IME, font shaping or a usable screen. If no display is available, mark those
checks pending and continue work that can be validated headlessly.

## Definition of done for a task

Acceptance scenarios pass; user-facing behavior is wired up; regressions have
focused coverage where warranted; relevant integration checks pass; compiler
fixes satisfy their own gate; no unexplained failures or workaround debt are
hidden. Record unperformed platform/manual checks explicitly. Later milestones
may proceed around independent pending checks, but milestone completion cannot
be claimed until its required checks pass.

Typing measurements include edit dispatch and retain input attribution through
coalesced caret frames. `TYPING_UI_CAPTURE_SECONDS` and `TYPING_UI_KEY_DELAY_MS`
override fixture defaults (small: 15 s/120 ms, multiline: 45 s/400 ms,
single line: 90 s/1,200 ms). Results record both settings.
Benchmark exit 0 means valid samples within the p95 budget. A missed budget
exits nonzero after preserving the result artifact, including `withinBudget`.
Set `TYPING_UI_PROFILE_PORT` to expose HashLink diagnostics during a benchmark
for an independently started `hlprof-live` sampler.
