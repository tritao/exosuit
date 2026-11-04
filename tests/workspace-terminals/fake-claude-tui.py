#!/usr/bin/env python3
"""A deterministic stand-in for the Claude Code terminal UI, for tests that drive a workspace terminal.

It behaves like the real one where a terminal pane can tell: alternate screen, a boxed prompt, bracketed paste,
a header that shows the grid it was given, a mode line that Shift+Tab cycles, history on Up/Down, Esc, Ctrl+C twice to
leave. Every key it receives is appended to $FAKE_CLAUDE_LOG (one line per key: `KEY NAME` or `TEXT chars`; `SIZE columns rows` whenever the grid changes), so a test
can assert what the terminal sent exactly instead of reading pixels.

Typing /big and Enter switches that mode on and off while it runs; FAKE_CLAUDE_BIG=1 starts with it on. It paints a mosaic over the whole screen between the header and the prompt: every cell has its own
truecolor foreground and background, so one redraw is far more than one relay frame (65487 bytes) of output and the
terminal's screen snapshot is as well. The log gets `BIG <cells>` for each redraw.

Started by the workspace service as the "claude" terminal agent:
  EXOSUIT_CLAUDE_BIN=<python>  EXOSUIT_CLAUDE_SCRIPT=<this file>  FAKE_CLAUDE_LOG=<file>
"""
import os
import queue
import sys
import threading
import time

LOG = os.environ.get("FAKE_CLAUDE_LOG")
BIG = os.environ.get("FAKE_CLAUDE_BIG") == "1"
# Symbols the real TUI prints that phone fonts lack (mode line, result marker, spinners); FAKE_CLAUDE_GLYPHS=1 shows them on row 3.
GLYPHS = os.environ.get("FAKE_CLAUDE_GLYPHS") == "1"
GLYPH_LINE = "⏵⏵ auto mode on ⏸ plan ⎿ Wrote 1 line ✻ ✽ ● ❯ ↓ …"
MODES = ["default", "accept edits on", "plan mode on"]
SEQUENCES = {
    b"\x1b[Z": "SHIFT_TAB", b"\x1b[A": "UP", b"\x1b[B": "DOWN", b"\x1b[C": "RIGHT", b"\x1b[D": "LEFT",
    b"\x1bOA": "UP", b"\x1bOB": "DOWN", b"\x1bOC": "RIGHT", b"\x1bOD": "LEFT",
    b"\x1b[5~": "PAGE_UP", b"\x1b[6~": "PAGE_DOWN", b"\x1b[3~": "DELETE", b"\x1b[H": "HOME", b"\x1b[F": "END",
}


def log(line):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def prepare_console():
    """Raw VT input and output on a Windows console (ConPTY); nothing to do elsewhere."""
    if os.name != "nt":
        import termios
        import tty
        tty.setraw(0)
        return
    import ctypes
    import msvcrt
    kernel = ctypes.windll.kernel32
    kernel.SetConsoleCP(65001)
    kernel.SetConsoleOutputCP(65001)
    stdin = kernel.GetStdHandle(-10)
    mode = ctypes.c_uint32()
    kernel.GetConsoleMode(stdin, ctypes.byref(mode))
    # ENABLE_VIRTUAL_TERMINAL_INPUT, without line input, echo and Ctrl+C processing.
    kernel.SetConsoleMode(stdin, (mode.value | 0x200) & ~(0x1 | 0x2 | 0x4))
    stdout = kernel.GetStdHandle(-11)
    kernel.GetConsoleMode(stdout, ctypes.byref(mode))
    kernel.SetConsoleMode(stdout, mode.value | 0x4 | 0x1)
    msvcrt.setmode(0, os.O_BINARY)


def read_input(events):
    pending = b""
    while True:
        chunk = os.read(0, 4096)
        if not chunk:
            events.put(("EOF", None))
            return
        pending += chunk
        while pending:
            if pending.startswith(b"\x1b[200~"):
                end = pending.find(b"\x1b[201~")
                if end < 0:
                    break
                events.put(("PASTE", pending[6:end].decode("utf-8", "replace")))
                pending = pending[end + 6:]
                continue
            matched = next((s for s in SEQUENCES if pending.startswith(s)), None)
            if matched:
                events.put(("KEY", SEQUENCES[matched]))
                pending = pending[len(matched):]
                continue
            if pending[:1] == b"\x1b":
                if len(pending) == 1:
                    events.put(("KEY", "ESC"))
                    pending = b""
                elif pending[1:2] == b"[" or pending[1:2] == b"O":
                    # An unknown or partial escape sequence: take it whole once it is complete.
                    final = next((i for i in range(2, len(pending)) if 0x40 <= pending[i] <= 0x7e), None)
                    if final is None:
                        break
                    events.put(("KEY", "CSI " + pending[1:final + 1].decode("ascii", "replace")))
                    pending = pending[final + 1:]
                else:
                    events.put(("KEY", "ALT_" + chr(pending[1]).upper()))
                    pending = pending[2:]
                continue
            first = pending[0]
            if first in (0x0d, 0x0a):
                events.put(("KEY", "ENTER")); pending = pending[1:]
            elif first == 0x09:
                events.put(("KEY", "TAB")); pending = pending[1:]
            elif first in (0x7f, 0x08):
                events.put(("KEY", "BACKSPACE")); pending = pending[1:]
            elif first == 0x03:
                events.put(("KEY", "CTRL_C")); pending = pending[1:]
            elif first < 0x20:
                events.put(("KEY", "CTRL_" + chr(first + 64))); pending = pending[1:]
            else:
                length = 1 if first < 0x80 else (2 if first < 0xe0 else 3 if first < 0xf0 else 4)
                if len(pending) < length:
                    break
                events.put(("TEXT", pending[:length].decode("utf-8", "replace")))
                pending = pending[length:]


def clip(text, width):
    return text if len(text) <= width else text[:max(0, width - 1)] + "…"


class Screen:
    def __init__(self):
        self.buffer = ""
        self.mode = 0
        self.transcript = []
        self.history = []
        self.cursor = None
        self.keys = []
        self.tabs = 0
        self.interrupts = 0
        self.last_size = None
        self.big = BIG

    def size(self):
        try:
            columns, rows = os.get_terminal_size()
        except OSError:
            columns, rows = 80, 24
        return columns, rows

    def note(self, name):
        self.keys = (self.keys + [name])[-6:]

    def draw(self):
        columns, rows = self.size()
        if self.last_size != (columns, rows):
            log(f"SIZE {columns} {rows}")
        self.last_size = (columns, rows)
        out = ["\x1b[?2026h\x1b[H\x1b[2J"]
        header = f"FAKE CLAUDE CODE  cols={columns} rows={rows}"
        out.append(f"\x1b[1;1H\x1b[1;38;5;208m{clip(header, columns)}\x1b[0m")
        out.append(f"\x1b[2;1H\x1b[2m{clip('cwd ' + os.getcwd(), columns)}\x1b[0m")
        if GLYPHS:
            out.append(f"[3;1H{clip(GLYPH_LINE, columns)}")
        if self.big:
            # Rows 3 .. rows-5; the box and the status line below stay readable.
            cells = 0
            for row in range(3, max(3, rows - 4)):
                line = [f"\x1b[{row};1H"]
                for column in range(columns):
                    seed = row * 131 + column * 17 + self.mode * 7
                    fg = (seed * 37 % 256, seed * 59 % 256, seed * 13 % 256)
                    bg = (255 - seed * 11 % 256, seed * 29 % 256, seed * 71 % 256)
                    line.append("\x1b[38;2;%d;%d;%d;48;2;%d;%d;%dm%s" % (*fg, *bg, chr(0x41 + (row + column) % 26)))
                    cells += 1
                line.append("\x1b[0m")
                out.append("".join(line))
            log(f"BIG {cells}")
        room = max(0, rows - 8) if not self.big else 0
        shown = self.transcript[-room:] if room else []
        for index, line in enumerate(shown):
            out.append(f"\x1b[{4 + index};1H{clip(line, columns)}")
        inner = max(4, columns - 4)
        top = rows - 4
        out.append(f"\x1b[{top};1H\x1b[38;5;244m╭{'─' * (inner + 2)}╮\x1b[0m")
        prompt = "> " + self.buffer
        visible = prompt[-inner:] if len(prompt) > inner else prompt
        out.append(f"\x1b[{top + 1};1H\x1b[38;5;244m│\x1b[0m {visible.ljust(inner)} \x1b[38;5;244m│\x1b[0m")
        out.append(f"\x1b[{top + 2};1H\x1b[38;5;244m╰{'─' * (inner + 2)}╯\x1b[0m")
        status = f"mode: {MODES[self.mode]} | tabs {self.tabs} | keys {' '.join(self.keys)}"
        out.append(f"\x1b[{rows};1H\x1b[2m{clip(status, columns - 1)}\x1b[0m")
        out.append(f"\x1b[{top + 1};{min(columns - 2, 4 + len(visible))}H\x1b[?2026l")
        sys.stdout.write("".join(out))
        sys.stdout.flush()

    def handle(self, kind, value):
        if kind == "TEXT":
            self.buffer += value
            self.note("text")
            self.interrupts = 0
            log("TEXT " + value)
            return True
        if kind == "PASTE":
            self.buffer += value.replace("\r", " ").replace("\n", " ")
            self.transcript.append(f"[pasted {len(value)} chars]")
            self.note("paste")
            log("PASTE " + value)
            return True
        log("KEY " + value)
        self.note(value.lower())
        if value != "CTRL_C":
            self.interrupts = 0
        if value == "ENTER":
            if self.buffer == "/big":
                self.big = not self.big
                self.buffer = ""
                self.transcript.append(f"[big mosaic {'on' if self.big else 'off'}]")
            elif self.buffer:
                self.transcript.append("> " + self.buffer)
                self.transcript.append("FAKE-CLAUDE-REPLY: " + self.buffer)
                self.history.append(self.buffer)
                self.buffer = ""
                self.cursor = None
        elif value == "BACKSPACE":
            self.buffer = self.buffer[:-1]
        elif value == "SHIFT_TAB":
            self.mode = (self.mode + 1) % len(MODES)
            self.transcript.append(f"[mode: {MODES[self.mode]}]")
        elif value == "TAB":
            self.tabs += 1
        elif value == "ESC":
            if self.buffer:
                self.buffer = ""
                self.transcript.append("[esc: cleared the prompt]")
            else:
                self.transcript.append("[esc: interrupted]")
        elif value == "UP" and self.history:
            self.cursor = len(self.history) - 1 if self.cursor is None else max(0, self.cursor - 1)
            self.buffer = self.history[self.cursor]
            self.transcript.append(f"[history {self.cursor + 1}/{len(self.history)}]")
        elif value == "DOWN" and self.history and self.cursor is not None:
            self.cursor += 1
            if self.cursor >= len(self.history):
                self.cursor = None
                self.buffer = ""
            else:
                self.buffer = self.history[self.cursor]
            self.transcript.append("[history down]")
        elif value in ("LEFT", "RIGHT", "PAGE_UP", "PAGE_DOWN", "HOME", "END", "DELETE"):
            self.transcript.append(f"[{value.lower()}]")
        elif value == "CTRL_C":
            self.interrupts += 1
            if self.interrupts >= 2:
                return False
            self.transcript.append("[press Ctrl-C again to exit]")
        else:
            self.transcript.append(f"[{value}]")
        return True


def main():
    prepare_console()
    events = queue.Queue()
    threading.Thread(target=read_input, args=(events,), daemon=True).start()
    log("START")
    sys.stdout.write("\x1b[?1049h\x1b[?2004h\x1b[?25h")
    screen = Screen()
    screen.draw()
    alive = True
    while alive:
        try:
            kind, value = events.get(timeout=0.2)
        except queue.Empty:
            if screen.size() != screen.last_size:
                screen.draw()
            continue
        if kind == "EOF":
            break
        alive = screen.handle(kind, value)
        screen.draw()
    sys.stdout.write("\x1b[?2004l\x1b[?1049l\nFake Claude Code: goodbye\n")
    sys.stdout.flush()
    log("EXIT")
    time.sleep(0.3)


if __name__ == "__main__":
    main()
