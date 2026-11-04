"""Windows console child: reports each key event the console delivers (ReadConsoleInputW), not VT text.

Prints READY, then one line per key-down: KEY vk=<virtual key> ctrl=<0|1> shift=<0|1> alt=<0|1> ch=<code>.
Shift, Control and Alt key-downs on their own (vk 16-18) are not reported.
Exits after the key event for 'q'. This is what a native console program sees through ConPTY.
"""
import ctypes
import sys
from ctypes import wintypes

k = ctypes.windll.kernel32
k.GetStdHandle.restype = wintypes.HANDLE
stdin = k.GetStdHandle(-10)


class Key(ctypes.Structure):
    _fields_ = [("down", wintypes.BOOL), ("repeat", wintypes.WORD), ("vk", wintypes.WORD), ("scan", wintypes.WORD),
                ("ch", wintypes.WCHAR), ("state", wintypes.DWORD)]


class Event(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("key", Key), ("pad", ctypes.c_byte * 16)]
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.WORD), ("u", _U)]


# Raw: no line input, echo or Ctrl+C processing, and no VT input, so ConPTY has to turn text into key events.
k.SetConsoleMode(stdin, 0x0008)  # ENABLE_WINDOW_INPUT only
print("READY", flush=True)
record, count = Event(), wintypes.DWORD()
while True:
    if not k.ReadConsoleInputW(stdin, ctypes.byref(record), 1, ctypes.byref(count)):
        sys.exit(2)
    if record.type != 1 or not record.key.down or record.key.vk in (16, 17, 18):
        continue
    state = record.key.state
    print("KEY vk=%d ctrl=%d shift=%d alt=%d ch=%d" % (record.key.vk, int(bool(state & 0xC)), int(bool(state & 0x10)),
                                                         int(bool(state & 0x3)), ord(record.key.ch)), flush=True)
    if record.key.vk == 0x51:
        break
