# TerminalKit

TerminalKit is a reusable Haxeon package around Pragtical's libtsm terminal
emulator backend. Initialize its libtsm submodule before building:

```sh
git submodule update --init native-packages/terminal/vendor/libtsm
native-packages/terminal/tests/run.sh
```

The C API feeds PTY output, reports terminal modes and cursor state, encodes
keyboard/mouse/focus replies through a callback, and saves/restores replayable
checkpoints. `terminalkit_snapshot()` exposes a cached active-screen cell grid.
`terminalkit_cells()` and `terminalkit_text()` borrow the grid and UTF-8 arena
until the next feed, resize, restore, snapshot or close. Each cell contains an
arena offset and length, display width and packed style; row-change flags are
computed from rendered content. Native callers can consume those arrays
without an additional copy. The thin Haxe `Emulator.rowText()` makes a safe
copy when a managed string is needed.

The package gate audits four C targets, runs a native conformance contract,
and launches a headless Haxeon smoke in either compiler mode. The native
contract covers screen cells, styles, modes, scrollback, input encoding,
checkpoint replay and the pinned libtsm combining-mark limit. The Pragtical
Lua terminal session fixtures still need a port after session integration.
