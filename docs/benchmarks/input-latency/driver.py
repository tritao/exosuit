"""Drives the editor with OS-level input (SendInput), which takes the same path through Windows as a physical mouse and
keyboard. Usage: driver.py SECONDS [--wait-window SECONDS] [--seed N]

Phases: mouse sweeps at ~1 kHz over the window, each after a 0.3-0.9 s pause (so movement onsets can be measured), then
one click in the middle of the text area and arrow-key taps and holds (holds repeat at 30 Hz like keyboard autorepeat).
Arrow keys only, so no file is modified."""
import ctypes, ctypes.wintypes as wt, math, random, sys, time

user32, kernel32, winmm = ctypes.windll.user32, ctypes.windll.kernel32, ctypes.windll.winmm
try:
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # per-monitor v2: physical pixels, as the hook reports
except Exception:
    pass

INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
MOUSEEVENTF_MOVE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_VIRTUALDESK = 0x1, 0x8000, 0x4000
MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x2, 0x4
KEYEVENTF_KEYUP = 0x2
VK_LEFT, VK_UP, VK_RIGHT, VK_DOWN = 0x25, 0x26, 0x27, 0x28


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD), ("dwFlags", wt.DWORD), ("time", wt.DWORD),
                ("dwExtraInfo", ctypes.c_size_t)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _U(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("u", _U)]


def send(*inputs):
    array = (INPUT * len(inputs))(*inputs)
    if user32.SendInput(len(inputs), array, ctypes.sizeof(INPUT)) != len(inputs):
        raise OSError("SendInput was blocked (is the session locked?)")


vx, vy = user32.GetSystemMetrics(76), user32.GetSystemMetrics(77)
vw, vh = user32.GetSystemMetrics(78), user32.GetSystemMetrics(79)


def move(x, y):
    i = INPUT(type=INPUT_MOUSE)
    i.u.mi = MOUSEINPUT(int((x - vx) * 65535 / (vw - 1)), int((y - vy) * 65535 / (vh - 1)), 0,
                        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0, 0)
    send(i)


def click():
    down, up = INPUT(type=INPUT_MOUSE), INPUT(type=INPUT_MOUSE)
    down.u.mi = MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTDOWN, 0, 0)
    up.u.mi = MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTUP, 0, 0)
    send(down)
    time.sleep(0.05)
    send(up)


def key(vk, down):
    i = INPUT(type=INPUT_KEYBOARD)
    i.u.ki = KEYBDINPUT(vk, 0, 0 if down else KEYEVENTF_KEYUP, 0, 0)
    send(i)


def editor_window(deadline):
    """The largest visible top-level window of an hl.exe process that is not a compile server."""
    psapi = ctypes.windll.psapi
    found = []
    WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def visit(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        handle = kernel32.OpenProcess(0x1000, False, pid.value)
        if handle:
            name = ctypes.create_unicode_buffer(260)
            psapi.GetProcessImageFileNameW(handle, name, 260)
            kernel32.CloseHandle(handle)
            if name.value.lower().endswith("\\hl.exe"):
                rect = wt.RECT()
                user32.GetWindowRect(hwnd, ctypes.byref(rect))
                area = (rect.right - rect.left) * (rect.bottom - rect.top)
                if area > 200 * 200:
                    found.append((area, hwnd, (rect.left, rect.top, rect.right, rect.bottom)))
        return True

    while time.time() < deadline:
        found.clear()
        user32.EnumWindows(WNDENUMPROC(visit), 0)
        if found:
            return max(found)[1:]
        time.sleep(0.5)
    sys.exit("no editor window appeared")


def foreground(hwnd):
    # Windows lets a process take the foreground right after it sends input; an Alt tap satisfies that.
    key(0x12, True)
    key(0x12, False)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.3)


def sleep_until(t):
    while True:
        left = t - time.perf_counter()
        if left <= 0:
            return
        time.sleep(left if left > 0.002 else 0)


def main():
    seconds = float(sys.argv[1])
    wait_window = float(sys.argv[sys.argv.index("--wait-window") + 1]) if "--wait-window" in sys.argv else 120
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1
    rng = random.Random(seed)
    winmm.timeBeginPeriod(1)
    hwnd, (left, top, right, bottom) = editor_window(time.time() + wait_window)
    time.sleep(3)  # let the first frames settle
    foreground(hwnd)
    # Stay inside the window with a margin; the editor's left activity bar and its text area both get hovered.
    x0, y0, x1, y1 = left + 20, top + 60, right - 20, bottom - 40
    end = time.perf_counter() + seconds * 0.7
    sweeps = moves = 0
    x, y = (x0 + x1) / 2, (y0 + y1) / 2
    while time.perf_counter() < end:
        time.sleep(rng.uniform(0.3, 0.9))
        tx, ty = rng.uniform(x0, x1), rng.uniform(y0, y1)
        if rng.random() < 0.4:  # sweep along the activity bar, as a person hovering its buttons does
            tx = rng.uniform(x0, x0 + 40)
        steps = int(rng.uniform(150, 600))  # one move per millisecond, like a 1 kHz mouse
        t = time.perf_counter()
        for s in range(1, steps + 1):
            f = s / steps
            ease = 0.5 - 0.5 * math.cos(math.pi * f)
            move(x + (tx - x) * ease, y + (ty - y) * ease)
            moves += 1
            t += 0.001
            sleep_until(t)
        x, y = tx, ty
        sweeps += 1
    # Keyboard: focus the text area, then taps and held keys.
    move((x0 + x1) / 2, (y0 + y1) / 2)
    time.sleep(0.2)
    click()
    end = time.perf_counter() + seconds * 0.3
    presses = 0
    while time.perf_counter() < end:
        vk = rng.choice([VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN])
        time.sleep(rng.uniform(0.15, 0.5))
        if rng.random() < 0.7:
            key(vk, True)
            time.sleep(rng.uniform(0.04, 0.1))
            key(vk, False)
            presses += 1
        else:
            key(vk, True)
            time.sleep(0.4)  # autorepeat delay, then 30 Hz repeats
            for _ in range(rng.randint(5, 20)):
                key(vk, True)
                presses += 1
                time.sleep(1 / 30)
            key(vk, False)
    winmm.timeEndPeriod(1)
    print(f"driver: {sweeps} sweeps, {moves} moves, {presses} key presses")


if __name__ == "__main__":
    main()
