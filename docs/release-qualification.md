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
