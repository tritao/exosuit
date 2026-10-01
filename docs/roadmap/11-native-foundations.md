# M11 — Native foundations: PTY, local IPC, storage, emulator

Depends on M8. The terminal, the control plane and Workbench need native
capabilities that no workspace repository provides today. NativeKit has
AF_UNIX `nk_transport` (unsupported on Windows), tasks and wake events. It has
no PTY, ConPTY, named pipes, SQLite or terminal emulator. Haxeon's stdlib has
MessagePack (`stdlib/haxeon/wire`) and threads.

Placement:

- PTY (M11.1) and transport hardening (M11.2) go into NativeKit. Both deliver
  through the shared `nk` event queue, so per `modules/README.md` they belong
  in core.
- SQLite (M11.3) and the terminal emulator (M11.4) stay in this repository as
  native packages with HXI bindings only. They do not go into NativeKit.

Each exosuit native package lives under `native-packages/<name>/` and has its
own `haxeon.json`. It contains vendored C sources, a small exosuit-owned C
header (`<name>_import.h`), a generated `.hxi`/`.hxmap` pair registered under
the manifest's `ffi` section, and thin hand-written Haxe wrappers. Generate
and audit the bindings with `haxeon/scripts/haxeon-ffi-import` and
`haxeon-ffi-audit`, the same tools NativeKit's `tools/update-haxeon-hxi.sh`
drives. Use the `utf8` string convention from `haxeon/docs/C_HEADER_FFI.md`;
do not use `@:hlNative`. Only the manifests that need a package depend on it:
the agent and tests for SQLite; the graphical app, the agent and tests for the
terminal. The headless core stays free of both.

Port behavior from the Pragtical C sources (MIT) rather than rewriting from
scratch, and keep attribution in notices.

## M11.1 — Pseudo-terminal runtime

- [ ] Add a PTY runtime to NativeKit (`nk_pty_*`): spawn with argv, cwd, env
  and size; write; resize; nonblocking read or poll; exit status; close or
  kill. On POSIX use `forkpty` and `TIOCSWINSZ`. On Windows use
  `CreatePseudoConsole`/`ResizePseudoConsole`, polled without a reader thread.
  The reference is `../pragtical/subprojects/terminal/native/runtime/terminal_runtime.c`.
- [ ] Wake the UI loop on output with `nk_wake_events`. Never block the
  frame. Bound reads per turn.

Acceptance: native tests spawn a shell, echo, resize (`stty size` reflects it),
handle an output flood without stalling frames, report exit, and clean up
children on close. Windows code compiles in CI or is recorded pending.

## M11.2 — Hardened local transport

- [ ] On POSIX, `NK_TRANSPORT_LOCAL` must create sockets with mode 0600.
  Require a user-owned, non-symlink parent directory with no group or other
  permissions. Unlink a stale socket only if it is a socket owned by the same
  uid. Reject peers whose `SO_PEERCRED` uid differs.
- [ ] On Windows, use named pipes with a current-user-only DACL. The
  reference is `../pragtical/src/api/local_transport.c`. Fix
  `nk_transport_query_capabilities` so it reports what is actually supported.

Acceptance: tests cover the permission refusals, stale-socket recovery,
unauthorized-peer rejection, framing split byte-by-byte, and payload limits.

## M11.3 — Embedded storage

- [ ] Add `native-packages/sqlite`: vendored amalgamation, opaque handles,
  prepare/bind/step/column, transactions and a busy timeout. Workbench (M14)
  needs migrations, transactions and compare-and-swap revisions.

Acceptance: transaction rollback, concurrent-open refusal through a lock file,
and blob round-trip tests pass.

## M11.4 — Terminal emulator

- [ ] Add `native-packages/terminal`, wrapping the libtsm backend used by
  Pragtical. That is
  `github.com/tritao/libtsm` at `7b1de2d`, via
  `subprojects/terminal/native/emulator/terminal_emulator_libtsm.c`. The wrap
  covers feed, screen cells with attributes, scrollback, cursor, modes
  (alternate screen, mouse, focus reporting, synchronized output), input
  encoding, and checkpoint serialize/restore.
- [ ] Expose a cell-grid snapshot API that is cheap to diff per frame.

Acceptance: port the conformance fixtures from Pragtical
`tests/lua/terminal_conformance.lua` and `tests/native_components.c`. A
checkpoint restored into a fresh emulator reproduces the screen.

Exit: Haxe wrappers for all four are usable from a headless Haxeon test project.
The SQLite and terminal packages build through `haxeon build` with no NativeKit
changes.
