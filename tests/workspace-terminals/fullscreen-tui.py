#!/usr/bin/env python3
"""A full-screen program for scripts/test-terminal-hosts.py: alternate screen, colours, mouse reporting, bracketed paste, a hidden cursor.

It redraws a frame counter twice a second until it is ended, so a test can tell that the same program kept running
(the counter went on) and that a terminal view shows its screen and modes after the service was stopped and started."""
import sys
import time

def out(text):
    sys.stdout.write(text)
    sys.stdout.flush()

if sys.platform == "win32":
    import ctypes
    kernel = ctypes.windll.kernel32
    handle = kernel.GetStdHandle(-11)
    mode = ctypes.c_uint32()
    kernel.GetConsoleMode(handle, ctypes.byref(mode))
    kernel.SetConsoleMode(handle, mode.value | 0x4 | 0x1)

# Alternate screen, mouse buttons with SGR coordinates, bracketed paste, application cursor keys, hidden cursor.
out("\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1h\x1b[?25l\x1b[2J")
frame = 0
try:
    while True:
        frame += 1
        out("\x1b[H\x1b[1;37;44m TUI_HEADER full-screen test \x1b[0m"
            "\x1b[3;3H\x1b[38;2;255;120;0mTUI_FRAME_%06d\x1b[0m"
            "\x1b[5;3H\x1b[32mgreen\x1b[0m \x1b[31mred\x1b[0m \x1b[48;5;236m\x1b[38;5;214m256\x1b[0m" % frame)
        time.sleep(0.5)
finally:
    out("\x1b[?25h\x1b[?1h\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[?1049l")
