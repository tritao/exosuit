# TerminalKit

TerminalKit is a reusable Haxeon package around Pragtical's libtsm terminal
emulator backend. Initialize its libtsm submodule before building:

```sh
git submodule update --init native-packages/terminal/vendor/libtsm
native-packages/terminal/tests/run.sh
```

The C API feeds PTY output, reports terminal modes and cursor state, encodes
keyboard/mouse/focus replies through a callback, and saves/restores replayable
checkpoints. `terminalkit_snapshot()` exposes a cached cell grid for the selected
scrollback viewport.
`terminalkit_cells()` and `terminalkit_text()` borrow the grid and UTF-8 arena
until the next feed, resize, restore, snapshot or close. Each cell contains an
arena offset and length, display width and packed style; row-change flags are
computed from rendered content. Native callers can consume those arrays
without an additional copy. The Haxe `Emulator.rowCells()` copies only a row
requested by the caller into managed cells with style, width and UTF-8 text.
`rowText()` remains a simpler text-only copy. The Haxe wrapper can encode
keyboard, mouse and focus input and drain terminal replies from a bounded
1 MiB queue. Native callers can route replies directly to a PTY through a
borrowed callback without that queue. Checkpoints are available from Haxe as
owned byte buffers.

Selection stays in libtsm's screen/scrollback storage. `selectionWord()` and
`selectionLine()` start semantic selections; `selectionTarget()` extends by the
original word or visual-line unit, including backward dragging. `selectionExtend()`
extends the same anchor by characters. Wide-glyph continuations resolve to their
leading cell. Copied text joins soft-wrapped rows while retaining explicit line
breaks; an anchor evicted from bounded history clears its selection safely.

Selected cells carry `Emulator.SELECTED` (foreground attribute bit `0x40`) without
inverting their underlying colours. Renderers can paint theme-aware highlights
behind the original text. The desktop shares editor click recognition and edge
autoscroll: double-click selects a word, triple-click a visual line, and dragging
extends that unit. Shift-click extends an existing selection when the terminal
does not own mouse input. In mouse-tracking applications, holding Shift instead
forces local selection, including double/triple-click.

The package gate audits four C targets, runs a native conformance contract,
and launches a headless Haxeon smoke in either compiler mode. The native
contract covers screen cells, styles, modes, scrollback, input encoding,
checkpoint replay and the pinned libtsm combining-mark limit. On POSIX, a
separate smoke feeds a real PTY stream into the emulator and sends input back.
NativeKit `nk_pty` session integration and the Pragtical Lua terminal session
fixtures remain for M12.

Hosts can update the terminal defaults with `Emulator.setDefaultColors()`.
OSC 10/11 queries then report the current RGB palette. Applications can query
light/dark appearance with `CSI ? 996 n`, or subscribe to palette updates with
`CSI ? 2031 h` (disable with `CSI ? 2031 l`). Replies use `CSI ? 997 ; 1 n` for
dark backgrounds and `CSI ? 997 ; 2 n` for light backgrounds. DECRQM reports the
subscription state. Only actual palette changes notify subscribers; terminal
reset disables the subscription. Hosts must drain generated replies after a
palette update even when the PTY is idle. Remote renderers discard their mirror's
notifications because the workspace service owns the PTY reply stream.

Applications that cache startup RGB colours without subscribing or re-querying
will retain their old styling across a host theme change. Codex CLI 0.164.0 has
this limitation; terminal notifications alone cannot refresh its cached palette.
