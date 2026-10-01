# Execution contract

## Scope and repository ownership

Implementation covers this editor and necessary changes in the sibling
workspace repositories:

- Haxeon compiler, runtime and stdlib in `HAXEON_ROOT` (default `../haxeon`).
- NativeKit (`../nativekit`) for core native capabilities (PTY, local transport).
- UIKit (`../uikit`) for widgets and hosts.
- EditorKit (`../editorkit`) for the text model.

Read the applicable repository instructions before editing any of them.
Inspect `git status --short` in each at the start and preserve existing work.
At the M8 planning baseline, `haxeon` had 2 modified paths and `uikit` and
`editorkit` had 4 each; do not assume authorship of them.

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
./scripts/build.sh     # graphical/haxeon.json (UIKit host)
./scripts/ci.sh        # composed gate (M8.3 restores LSP and release stages)
./scripts/run.sh /absolute/path/to/a/disposable/project
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
