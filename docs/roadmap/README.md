# Implementation roadmap

Planning baseline: 2026-09-08. This is an execution plan, not a claim that the
current tests pass. The source inspection includes uncommitted changes.

## Destination

Deliver a lightweight, responsive, configurable desktop coding editor with
Pragtical-like editing, project navigation, search, extensibility and polish.
Keep the Haxeon application core and the platform boundary in
[ADR 0001](../architecture/0001-platform-boundary.md). Reuse the sibling
NativeKit/UIKit host in [ADR 0002](../architecture/0002-nativekit-uikit-host.md).
Lua plugin binary/source compatibility is not assumed.

## Execution order

| Stage | Plan | Depends on | Result |
| --- | --- | --- | --- |
| M0 | [Baseline](00-baseline.md) | None | Verified starting point |
| M1 | [File safety](01-file-safety.md) | M0 | Safe real-file editing |
| M2 | [Editing](02-editing.md) | M1 | Complete everyday editing |
| M3 | [Editor shell](03-editor-shell.md) | M2 | Discoverable, usable interface |
| M4 | [Projects and search](04-projects-search.md) | M3 | Responsive project workflows |
| M5 | [Configuration and plugins](05-configuration-plugins.md) | M4 | Useful, reloadable extensions |
| M6 | [Coding tools](06-coding-tools.md) | M5 | Develop this project in this editor |
| M7 | [Release quality](07-release-quality.md) | M6 | Reproducible standalone release |

Read [the execution contract](EXECUTION.md) and
[the compiler policy](COMPILER-TYPING.md) before implementing any stage.
Record progress in [STATUS.md](STATUS.md). Use [OVERNIGHT.md](OVERNIGHT.md)
as the launch handoff. Task IDs are stable; check a task only after its
acceptance criteria have evidence. Each numbered task is a bounded delivery
unit, not a promise that a whole milestone fits in one night.

## Observed foundation

- Platform ABI, native/headless backend and Pragtical-backed rendering.
- Text buffer, undo/redo, save, selection, scrolling and measured caret placement.
- Document manager, tabs, pane layout, focus, named commands and keybindings.
- Project roots, directory tree, file command view, syntax registry/highlighter.
- In-progress document/workspace search and replacement.
- Plugin registration, dynamic compilation, patching and module reload.
- Native tests and Haxeon application test entry points.

Important gaps observed: quit bypasses dirty-document resolution; saving writes
directly to the destination; workspace search reads files synchronously;
plugin refresh rereads source files every update; cursor/anchor live in the buffer.
Validate these observations again before changing their implementation.

## Follow-on: UIKit host and Pragtical fork features

Planning baseline: 2026-10-01 at `ae2f260` (branch `haxeon-uikit-port`). ADR
0002 moved the editor onto the NativeKit UIKit host and haxeon.json manifests,
so the M0–M7 evidence no longer describes the running product. The sibling
Pragtical fork (`../pragtical`, branch `next`, `50644c91`) adds Workbench
agents, an integrated terminal, a local control plane, Haxeon LSP, sidebar
modes and a web build. These stages port that work. They are behavioral ports
onto Haxeon, NativeKit and UIKit; Lua code is not reused.

| Stage | Plan | Depends on | Result |
| --- | --- | --- | --- |
| M8 | [UIKit baseline](08-uikit-baseline.md) | M7, port | Green gates on the new toolchain |
| M9 | [Shell parity](09-shell-parity.md) | M8 | Styled text, panes, sidebar modes, smooth scroll |
| M10 | [Haxeon language](10-haxeon-language.md) | M8, M9.1–M9.2 | Language features usable in the UI |
| M11 | [Native foundations](11-native-foundations.md) | M8 | PTY, hardened local IPC, SQLite, emulator |
| M12 | [Terminal](12-terminal.md) | M9, M11.1, M11.4 | Integrated terminal |
| M13 | [Control plane](13-control-plane.md) | M11.2 | `exosuit-ctl` and launch forwarding |
| M14 | [Workbench](14-workbench.md) | M11–M13 | Workspaces, terminals, Claude Code and Codex agent supervision |
| M15 | [Web target](15-web.md) | M8.1, M8.2 | Browser build with capability guards |
| M16 | [Remote workspaces](16-remote-workspaces.md) | M14, M15, Haxeon RPC | Existing web/Android access through a Cloudflare Workers relay |

M14 uses the [Haxeon RPC foundation plan](HAXEON-RPC.md): typed wire codecs,
bounded dispatch and reconnect in the first slice, with Exosuit-owned durable
replay and mutation reconciliation.

Ready-work order: M8 → M15 → M9 → M10 → M11 → M13 → M12 → M14. The web
target comes right after the baseline, to use the current Haxeon wasm work
(materia `app/web`). M11 and M13 are independent of M9, M10 and M15, so they
may proceed while those are blocked. Features added after M15 must declare
their capability (M15.1), so the browser build stays green.

Decisions taken by default (record any override in STATUS):

- PTY and local transport hardening go into NativeKit core. SQLite and the
  libtsm terminal emulator stay in exosuit as `native-packages/` with HXI
  bindings. Widget capabilities go into UIKit.
- M13 retains Pragtical control protocol v1 compatibility. M14 uses an
  Exosuit-owned workspace protocol built on Haxeon typed wire codecs;
  Pragtical Workbench is reference input only. Keep Exosuit storage and
  runtime directories separate.
- Vendor SQLite and libtsm (`tritao/libtsm@7b1de2d`). Before vendoring,
  confirm both licenses and record the notices in packaging.
- Claude Code and Codex are required M14 agent providers; opencode is deferred.
- Opt-in tests that need external CLIs (Claude Code, Codex, Chromium) record
  "pending" when the tool is absent. They are never skipped silently.

Still out of scope: SCM/diff UI, debugger UI, and Lua plugin compatibility.
Record any other addition explicitly instead of silently expanding a milestone.

## Release gates

M1: file-safety scenarios pass. M4: daily text/project workflows are usable.
M6: an edit/build/diagnose cycle works on this repository. M7: packaged build
works outside the checkout, with measured performance and platform evidence.
Carry correctness and performance checks through all stages; M7 consolidates them.
