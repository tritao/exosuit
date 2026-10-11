# Release qualification

This document records evidence for the release-quality claims. Measurements are
local development gates, not promises for other hardware or operating systems.

The performance and SDL platform measurements below are historical evidence.
They do not qualify the replacement UIKit host. Current UIKit evidence is the
real-window project/open/edit/save/palette/problems/build-output/plugin-reload
route in `scripts/test-uikit-workflow.sh` and the unpacked release/LSP gate in
`scripts/test-release.sh`. IME, physical mixed-DPI, Windows and macOS remain pending.

## Performance and endurance

Recorded 2026-09-08 on Linux 6.8.0-59-generic x86_64, an Intel Core i5-13600K
(14 cores, 20 logical CPUs, up to 5.1 GHz) with 31 GiB RAM. The repository was at
`6a605d7` after the performance fixes in `2130565`; Haxeon was at `21a996b`.

Run the fixed fixtures from the repository root:

```sh
./scripts/benchmark-release.sh
./scripts/benchmark-project-index.sh
```

The release benchmark constructs a small Haxe source, exactly 10 MiB of text, a
single 1 MiB line, 200 typing-to-present samples, 500 idle update samples, 200
scroll-to-present samples, 50 open/edit/atomic-save/close cycles and 20 live
plugin recompilation/reload cycles. It measures a complete first-document frame,
uses a one-second sleeping service-idle interval for CPU time, and records process
peak RSS with `/usr/bin/time`. The project benchmark creates 100 directories with
100 files each, cancels and replaces both indexing and search generations, and
runs the same 32-step scheduler request used by the application.

Observed result:

```text
startup 0.618 ms; first usable document 0.077 ms
typing-to-frame p95 0.051 ms; service idle p95 0.0012 ms; idle CPU 2.00%
10 MiB open 618.9 ms; 1 MiB line open 21.85 ms; scroll-to-frame p95 0.052 ms
50 document lifecycle cycles 571.2 ms; first/last ten p95 11.32/12.38 ms
20 plugin reloads p95 31.55 ms; first/last five median 6.44/5.55 ms
peak RSS 170,708 KiB
10,000-file index: 6 turns, maximum turn 6.37 ms
cancelled/replacement 10,000-file search: maximum turn 0.98 ms
```

The executable gates require scheduling turns below 8 ms, typing and large-file
scroll p95 below 50 ms, service-idle CPU below 5%, and no greater than a bounded
twofold-plus-2-ms median increase in the final document/plugin soak windows.
Rendering and service-idle timings are reported separately.

Profiling found and removed repeated whole-document work: visual-row lookup is
now logarithmic, maximum line width is cached by visual-map revision, collapsed
status selections do not calculate absolute offsets, highlight validation starts
at its known-valid frontier, and project snapshots use linear assembly. The shared
job scheduler enforces a six-millisecond wall-clock slice in addition to its step
limit.

There is no configured hard editor document-size limit; 10 MiB documents and a
1 MiB line are qualified here, while larger inputs remain unclaimed and memory
scales with buffer and visual-row count. Workspace search deliberately skips
individual files larger than 4 MiB and caps retained results at the caller's
configured maximum. These limits are surfaced as search diagnostics.

The full headless suite and SDL artifact compile passed after these changes. Peak
RSS is a whole-run high-water mark; the chronological first/last soak comparisons
show no progressive latency in the exercised cycles.

## M17 connected Source Control browser

Verified 2026-10-10 with the isolated wasm32 site, WSL2 Ubuntu 24.04, Chrome 154
on Windows, and Wrangler 4.147.0. The browser-pairing runner was invoked in
`--scm` mode against the built site. It completed the Noise pairing and desktop
approval, attached the remote workspace, opened a changed file from the real Git
fixture, and opened its Source Control diff. The paired device had
`workspace.scm.read` and did not have `workspace.scm.write` or
`workspace.scm.remote`; the panel exposed no commit or row-mutation controls.
The same diff opened full-width at 320 × 740. Remote file preview, Unicode
content search, filename search, reconnect, and persisted device grants also
passed in the same run.

The test host binds the production `WorkspaceScmService` and
`WorkspaceRpcServer` behind the real local Wrangler relay and Noise pairing.
`tests/workspace-scm` separately exercises the production agent-side service and
its permission boundary. This is automated browser evidence, not a manual
qualification of every Explorer and status-bar interaction.

Linux agent builds require libcurl development files for the relay ticket HTTP
client. `agent/native/CMakeLists.txt` now fails during configuration with the
package name when those files are missing instead of producing a relay that
cannot connect.

## M17 local Git Explorer and performance

Verified 2026-10-10. The requested benchmark checkout is Exosuite. The initial
Windows run used the Exosuite worktree with 94 SCM resources; a repeat used the
current worktree with 95. Linux used a clean ext4-backed snapshot at `b185a73`
with zero changes. Each run also used a synthetic 50,000-file repository
containing 49,999 untracked files, without status truncation. Unchanged
refreshes emitted zero notifications in every run.

The shared `scripts/test-scm-ui.py` runner passed on Windows through the native
Haxeon CLI. Its eight UI phases verify staged, changed, untracked and conflicted
groups; refresh after an external commit; a full-width phone diff; conflict
resolution; read-only remote controls; file stage/unstage/discard with actual
Git state checks; commit message entry and commit-button behavior; and Explorer
folder badges with `main ↑1 ↓1`. A real submodule fixture also verifies its
nested repository row and confirms that staging a child file changes only the
child index. The runner uses the native window on Windows
and wraps the same fixtures with Xvfb on Linux; `scripts/test-scm-ui.sh` remains a shell
entry point for existing callers. The UI assertions pass on Windows, but its
PNG capture step invokes ImageMagick's X11-only `import` command, which is not
available there, so Windows screenshot capture is not claimed. The focused
Windows `tests/scm-git` run also passed; the latest 10,000-line, 50-edit run
completed in 10 ms total with a 0.387 ms maximum diff slice, below both the
4 ms slice and 100 ms convergence limits.
Separate Windows phases pass gutter marker rendering, click and owner removal,
unified diff refresh, and synchronized side-by-side scrolling. The
`tests/status-bar` fixture also verifies Explorer badge/name tint, priority
roll-up, owner removal, status item ordering/action, and the resource tint on an
editor tab title. The `tests/remote-access-panel` and
`tests/workspace-transport --noise-only` runs pass the permission editor and
pairing grant persistence checks.

| Host and fixture | Resources | Status / unchanged total (ms) | Max frame: status / unchanged (ms) | Max service / scheduler update (ms) |
| --- | ---: | ---: | ---: | ---: |
| Windows 11, Exosuite worktree | 94 | 1472.7 / 1652.4 | 15.523 / 8.439 | 0.815 / 14.708 |
| Windows 11, 50,000-file fixture | 49,999 | 1130.1 / 1130.6 | 12.634 / 10.312 | 1.240 / 11.529 |
| Windows 11, Exosuite worktree (repeat) | 95 | 1200.8 / 1202.4 | 12.134 / 8.300 | 0.816 / 11.616 |
| Windows 11, 50,000-file fixture (repeat) | 49,999 | 517.2 / 429.0 | 14.590 / 11.137 | 2.364 / 13.631 |
| WSL2 Ubuntu 24.04, clean Exosuite snapshot | 0 | 91.995 / 84.808 | 0.437 / 0.522 | 0.038 / 0.427 |
| WSL2 Ubuntu 24.04, 50,000-file fixture | 49,999 | 156.202 / 164.276 | 6.597 / 6.486 | 0.053 / 6.588 |

| Host and fixture | Wire bytes | Conversion median (ms) | MessagePack encode / decode median (ms) | Model rebuild median (ms) | Batch spawn / cold blob / warm median (warm max), ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Windows 11, Exosuite worktree | 9,874 | 0.0057 | 0.102 / 0.108 | 0.163 | 12.54 / 78.0 / 46.12 (47.61) |
| Windows 11, 50,000-file fixture | 3,450,077 | 3.699 | 45.891 / 55.936 | 67.037 | 8.887 / 61.93 / 46.40 (47.56) |
| Windows 11, Exosuite worktree (repeat) | 9,949 | 0.0093 | 0.185 / 0.158 | 0.199 | 10.939 / 57.627 / 13.604 (18.387) |
| Windows 11, 50,000-file fixture (repeat) | 3,450,084 | 3.793 | 45.102 / 57.404 | 55.788 | 7.551 / 53.689 / 14.224 (16.572) |
| WSL2 Ubuntu 24.04, clean Exosuite snapshot | 101 | 0 | 0.00095 / 0.00405 | 0 | 0.271 / 63.38 / 7.199 (8.479) |
| WSL2 Ubuntu 24.04, 50,000-file fixture | 3,450,059 | 6.491 | 37.413 / 51.707 | 38.156 | 0.564 / 3.895 / 2.363 (2.553) |

Initial and unchanged refresh frame assertions are strictly below 16.67 ms on
both hosts. The initial Windows Exosuite worktree's 15.523 ms maximum was close
to that budget. The repeat run measured 12.134 ms on the current worktree and
14.590 ms on the 50,000-file fixture. The clean Linux snapshot is a different
baseline from the dirty Windows worktree, so those repository rows are not a
direct comparison. Linux used the
system libffi 3.4.6 shared library because the WSL image lacked the pinned
toolchain's autoreconf dependency; SCM performance results are from the same
Exosuite source snapshot.

The Linux Xvfb runner was attempted, but this WSL image lacks GTK3 development
files. NativeKit therefore built its no-window stub and the UI process reported
that no platform window backend was available. This is an environment
limitation; the Windows native UI runner passed, while Linux UI automation is
not claimed as a pass.

## Platform matrix

Only Linux x86-64 is claimed. Windows and macOS remain unclaimed until native
build and execution evidence exists.

| Route | Linux evidence | Result |
| --- | --- | --- |
| Committed text and composition model | ABI v16 maps SDL text-editing separately from text-input; mixed Japanese/emoji preedit tests prove no document mutation before commit and verify the UTF-16 selection and candidate rectangle | Automated pass; real desktop IME session still pending |
| Combining text, emoji and mixed scripts | `test-sdl-smoke.sh` renders Latin combining text, Greek, Cyrillic, Japanese and emoji through the bundled primary/fallback font group | Pass under Xvfb |
| Non-ASCII path and clipboard | `test-sdl-input.sh` opens `日本語-😀.txt`, pastes `Olá 日本語 😀 Z` through the X clipboard, selects/copies `Z`, saves and byte-compares the file | Pass under Xvfb |
| Modifiers and keyboard navigation | The same real SDL route delivers Ctrl, Shift and Alt chords; `test-sdl-workflow.sh` performs the M0 workflow without a mouse | Pass under Xvfb |
| Resize and logical scale | The real window is resized to 1120×720; typed event coverage routes a 1.75 display-scale transition without changing logical hit-test coordinates | Pass; physical mixed-DPI monitor transition pending |
| Window lifecycle | Frame- and time-bounded graphical launches both execute normal callback teardown | Pass under Xvfb |
| External replacement | Document tests cover clean reload plus dirty-buffer conflict, and replacement tests reject changed files before apply/restore | Pass headlessly |
| User directories | Configuration tests cover portable, XDG config and XDG state roots; packaged smoke uses isolated portable state | Pass on Linux |
| Keyboard focus and essential workflow | Real-window automation opens a project/file, edits, selects, undo/redoes, saves, splits, switches tabs, finds/replaces, searches the project and reloads a plugin | Pass under Xvfb |
| Default text contrast | Executable WCAG relative-luminance checks require editor text, muted text and accent-selection text to meet 4.5:1 | Pass headlessly |

The Linux automation cannot prove candidate-window behavior for a particular
desktop input-method daemon or a physical transition between differently scaled
monitors. Those two manual observations remain open. There is no screen-reader
accessibility bridge yet, theme overrides are not automatically contrast-checked,
and no reduced-motion or forced-colors integration is claimed.

The SDL callback host originally consumed 99% CPU under Xvfb because it rendered
without a wait when no compositor synchronized presentation. A bounded 16 ms
cadence now keeps background jobs progressing near 60 Hz and measured 5% CPU
(0.24 s user, 0.03 s system over five wall-clock seconds) in the same environment.

## Packaging and reproducibility

`release.lock` records exact Haxeon, NativeKit, materia (UIKit/EditorKit) and
HashLink vendor revisions. `scripts/package-release.sh` rejects mismatched or
dirty dependency inputs, builds the matched VM/runtime and language server,
and builds the graphical manifest. It creates a Linux x86-64 archive in `dist/`.
The archive includes bytecode, standalone launchers, ordinary C libraries,
HashLink and Haxeon runtime, language server, stdlib, reference defaults,
documentation, revision manifest and native dependency license notices.
UIKit discovers system fonts through Fontconfig.

`scripts/test-release.sh` extracts outside the source tree, checks ELF runtime
search paths, launches/captures the real window with isolated portable state,
and tests edit/diagnose/fix/save/build against the bundled server.
