# Overnight implementation handoff

This file is a prompt for launching an implementation run. Writing this plan
does not start an agent or install an automation. The follow-on roadmap
(M8–M15) is many nights of work, so each run resumes from the ledger.

## Goal

Port the Pragtical fork's features onto the Haxeon editor running on the
NativeKit UIKit host. The end state is an editor that develops this repository
with full Haxeon language support. It has an integrated terminal, local
control from `exosuit-ctl`, and Workbench agent supervision, plus a browser
build. Each slice must be verified and committed. A run that leaves the gates
red has not met the goal, however many boxes are checked.

## Launch prompt

> Implement the follow-on roadmap (M8–M15) in `docs/roadmap/README.md`. First
> read `docs/roadmap/EXECUTION.md`, `docs/roadmap/COMPILER-TYPING.md` and
> `docs/roadmap/STATUS.md`, plus the instructions of every repository you will
> touch.
>
> Start at the first ready unfinished task in the stated ready-work order and
> keep going through successive tasks. Deliver working, verified slices; do
> not stop at another plan or at a milestone boundary. M8 comes first and is
> mandatory: nothing later may be claimed while `./scripts/test.sh` or
> `python scripts/build.py` is red.
>
> `../pragtical` is a read-only reference, including its uncommitted diff.
> Port behavior and tests from it; never modify it. Necessary Haxeon
> compiler/runtime/stdlib, NativeKit and UIKit changes are in scope. Make them
> general capabilities with their own tests and gates. When valid code hits a
> typing defect, reduce it, add regressions and fix the general rule. Never
> evade it with weakened types, casts, special cases, disabled diagnostics or
> `--self-hosted` toggles.
>
> Commit each verified slice following EXECUTION.md: the current branch in
> exosuit, and an `exosuit-followon` branch in sibling repositories. Stage
> only owned hunks and preserve all pre-existing dirty work. Do not push,
> publish or mutate PRs. Serialize builds that share output directories.
> Update STATUS after each slice with the commands run, their outcomes,
> commit IDs, compiler fixes and an exact resume instruction. If blocked,
> record the evidence and continue with independent ready work (M11 and M13
> do not depend on M9, M10 or M15). Keep unavailable GUI, Windows and
> external-CLI checks pending rather than claiming they passed.
>
> At the end, report the completed task IDs, the commits in each repository,
> verification results, unresolved failures and the next ready task.

## Suggested first-run target

Complete M8. Start with M8.1 (native string convention) because it unblocks
every headless test. M8.2's compiler fixes may consume most of a night; leave
reducers, regressions and root-cause notes so the next run continues without
guesswork. If M8 finishes, go into M15 (web target), reusing materia's
`app/web` pipeline. After that comes M9.1 (styled spans). If M8.2 is blocked
on the compiler, work on M11.1 (PTY) in NativeKit in parallel.

## Morning review

Read STATUS first, then review the commits in exosuit, haxeon, nativekit and
uikit. Run the outstanding graphical checks. Resume with the same launch
prompt; the ledger chooses the next task. Do not rerun broad checks that
already pass unless new changes or unresolved concerns call for it.
