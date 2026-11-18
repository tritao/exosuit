# One-command gaps

Everything that should work from a clean clone with one command, but only worked because of state outside the repo
(mostly the deleted `exosuit-wt` folder) or because someone knew a manual step. Each entry: what broke, what it relied
on, what the repo needs. Found 2026-11-17, after `exosuit-wt` and parts of `haxeon/.tools` were deleted.

## Build

1. **A partly deleted toolchain is not repaired, and the error doesn't say why.** With `haxeon/.tools/ccache` gone,
   every native package fails with `CreateProcess failed: The system cannot find the file specified.` The CMake caches
   under `haxeon/out/native-cache` bake in `CMAKE_C_COMPILER_LAUNCHER=.../.tools/ccache/ccache.exe`, the fingerprint
   still matches, so nothing reconfigures.
   Needs: the native build checks that the launcher and compiler it cached still exist (part of the fingerprint),
   and a build entry point runs the bootstrap when a pinned tool is missing instead of failing.
2. **`scripts/run.py` stops at "Pinned Haxe compiler is not bootstrapped"** (`scripts/haxeon_cli.py`) when
   `haxeon/.tools/haxe` is missing. It names a bootstrap but doesn't run it, and doesn't say which command.
   Needs: `run.py` bootstraps (or calls the same step as `scripts/build-windows.ps1`) when tools are missing.
3. **Two Windows entry points.** `scripts/build-windows.ps1` (VS environment + bootstrap + build) and `scripts/run.py`
   (build + run, plain shell) overlap; `-SkipBootstrap` was used by habit from the worktree wrapper and skipped the
   repair. Needs: one command per platform that builds what's missing and runs: `run.py` should be that command
   everywhere, with the Windows specifics (VS environment, bootstrap) inside it.

4a. **The bootstrap relinks HashLink in place while it runs.** `scripts/build-windows.ps1` (with bootstrap) failed with
   `LNK1104: cannot open file ...\.tools\hashlink\libhl.dll`: the daemon, services and terminal hosts run from that DLL.
   It rebuilt HashLink although the working one was intact (other tools in `.tools` were missing). Needs: the
   bootstrap skips a tool that's present and current, and builds a replacement beside a locked one, switching on
   next start.

## Daemon rename (suit → exohost, 6ee0435b)

4. **No state migration.** exohost's home is `%LOCALAPPDATA%\exosuit\exohost`; the workspace list stayed in
   `%LOCALAPPDATA%\exosuit\suit\machine.json`. A new editor shows "Looking for this machine's workspaces…" forever.
   Needs: exohost adopts the old home's `machine.json` (and registry) on first start, once.
5. **The old daemon keeps running and owns the workspace services and terminal hosts.** Nothing stops it or hands its
   services over. Needs: exohost asks a running suit to quit with `--keep-terminals` on first start.
6. **No error when the daemon can't be reached or started.** The Workbench just keeps looking. Needs: a visible reason
   (no launcher built, start failed, version mismatch) with a Retry.
7. **exohost isn't built by the editor's launch path when missing** (`exohost/build/host/main.hl` absent after the
   rename). Needs: `run.py` builds exohost like it builds the agent.

## Live mode

8. **A full module reload after many live patches threw `TreeView selection key is not visible`** (haxeon
   `TreeView.hx:178/215/237`) from the Workbench; the window died but the live host kept running with no window, so the
   launching terminal never returned. Needs: the Workbench catches it (the selection isn't visible yet → defer), and
   the live host exits (or reopens the window) when the app's window is gone.
9. **A deadlock** (window stops taking input, Ctrl+C doesn't end it, close turns it white) — no record anywhere: the
   live logs only cover the watcher. Needs: the app's own log file with thread state on a hang (watchdog).

## Tooling that lived only in `exosuit-wt` (now gone)

10. **`wt-run.ps1`** — ran commands in a worktree with an isolated environment (cleared inherited `HAXEON_*`,
    `EXOSUIT_*`, fixed `PATH`), timeouts, and exit 99 when a command wrote into the owner's checkout.
    Needs: a repo script (`scripts/in-worktree.ps1` or part of `run.py`) or worktree-proof scripts that don't read
    inherited env.
11. **`android-run.ps1`** (session scratchpad) — set `ANDROID_HOME`/`ANDROID_SDK_ROOT`, `JAVA_HOME` and `PATH` for
    `android/scripts/machine-acceptance.ps1`. Needs: the acceptance script finds the SDK and JDK itself (or a checked-in
    env script), so `machine-acceptance.ps1 -Avd exosuit-s8` works from a plain shell.
12. **`switch-daily-*.ps1`** — moved the owner's checkout to a commit: polite quit of the editor and daemon, check for
    leftover processes, reset, verify the haxeon pin, update vendored submodules, move live state aside, build.
    Needs: a repo command (`scripts/switch.ps1 <commit>` or `run.py --update`) — the daemon rename shows why: it must
    also stop the old daemon and migrate state.
13. **`land-*.py`** — rebuilds a branch into topic commits from its final tree (temporary index, `update-index -z`).
    Optional, but if landings keep using it, it belongs in `scripts/`.
14. **Worker rules (`REVIEW-FIXES-COMMON.md`) and result folders (`exosuit-wt/state/...`)** — test output landed outside
    the repo. Needs: one ignored repo folder for run output (e.g. `out/runs/`), and the rules in `docs/`.

## Wishes

16. **An agent terminal whose program ends unexpectedly restarts itself once, resuming its conversation**
    (`claude --resume <id>`, `codex resume <id>`; `AgentTerminalResume` already plans it). Today it shows *exited*
    until someone presses Restart. A deliberate `/exit` (exit code 0) stays exited.

## Git state

17. **Submodule URLs pointed into a deleted worktree.** `.git/config` (and haxeon's) had every submodule URL set to
    `exosuit-wt\daily4h\small-fixes\...`, so a new worktree couldn't clone `noise-c` or haxeon's vendored modules.
    Fixed with `git submodule sync --recursive` (back to `.gitmodules`). Needs: never point submodule URLs at local
    folders; a fetch from a sibling checkout goes through a named remote or a one-off `git fetch <path>`, not the URL.
18. **`daily` pins a haxeon commit that exists only locally** (`5d2c7ab19`, the port's `exosuit-upstream`). A clone
    from the remote fails `submodule update` ("not our ref"). Needs: push the haxeon branch before a pin that uses it
    is committed anywhere others (or a fresh worktree) will check out — or a check that refuses such a commit.

19. **A submodule clone that failed part-way leaves an empty module that looks fine.** After the stale-URL failure,
    `libtsm` and `oniguruma` in a new worktree had every file staged as deleted; `git submodule status` showed the
    right commit, and the build failed later with "native CMake input does not exist: .../libtsm/src". Needs: the build
    checks each vendored module is clean at its pin and says which one to restore.

20. **`exohost quit --keep-terminals` left a haxeon compiler worker running** (`haxeon\out\cmake\windows-msvc\
    hashlink-runtime\hl.exe`, a compile cache from the live watcher). It holds the HashLink runtime the next build
    rebuilds, and haxeon's CLI has no command to stop it. Needs: exohost lists and ends compiler workers in the quit
    (they're Exosuit-spawned), or `haxeon_cli.py compiler stop`.
21. **Switching the checkout to a new commit is a 7-step recipe passed between sessions** (record hosts, polite quit,
    stop the daemon, reset, submodules, move live history aside, full build, start). Same need as #12: one repo
    command, e.g. `python scripts/run.py --update <rev>`.

## Tests

15. **`scripts/test-windows.ps1 -Only` doesn't know every suite** (e.g. machine-remote runs only as
    `scripts/test-machine-remote.py`). Needs: every suite in the one suite list.
