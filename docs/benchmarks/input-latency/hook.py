"""Records input as Windows receives it, before any app sees it. Usage: hook.py OUT SECONDS

Lines: `H <qpc> <x> <y> <injected>` mouse move, `D <qpc> <x> <y> <injected>` mouse button down/up,
`K <qpc> <vk> <down> <injected>` key. `injected` is 1 for SendInput events (a driver), 0 for a physical device."""
import ctypes, ctypes.wintypes as wt, sys, threading

user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
WH_KEYBOARD_LL, WH_MOUSE_LL, WM_QUIT = 13, 14, 0x0012
WM_MOUSEMOVE = 0x0200
BUTTONS = {0x0201, 0x0202, 0x0204, 0x0205, 0x0207, 0x0208}
KEY_DOWN, KEY_UP = {0x0100, 0x0104}, {0x0101, 0x0105}
LLMHF_INJECTED, LLKHF_INJECTED = 0x1, 0x10


class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", wt.POINT), ("mouseData", wt.DWORD), ("flags", wt.DWORD), ("time", wt.DWORD), ("extra", ctypes.c_size_t)]


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wt.DWORD), ("scanCode", wt.DWORD), ("flags", wt.DWORD), ("time", wt.DWORD), ("extra", ctypes.c_size_t)]


HOOKPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int, wt.WPARAM, wt.LPARAM)
user32.CallNextHookEx.argtypes = [wt.HHOOK, ctypes.c_int, wt.WPARAM, wt.LPARAM]
user32.CallNextHookEx.restype = ctypes.c_ssize_t
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wt.HINSTANCE, wt.DWORD]
user32.SetWindowsHookExW.restype = wt.HHOOK

counter = ctypes.c_int64()
events = []


def now():
    kernel32.QueryPerformanceCounter(ctypes.byref(counter))
    return counter.value


@HOOKPROC
def mouse_hook(code, wparam, lparam):
    if code == 0 and (wparam == WM_MOUSEMOVE or wparam in BUTTONS):
        t = now()
        info = ctypes.cast(lparam, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
        events.append(("H" if wparam == WM_MOUSEMOVE else "D", t, info.pt.x, info.pt.y, info.flags & LLMHF_INJECTED and 1))
    return user32.CallNextHookEx(None, code, wparam, lparam)


@HOOKPROC
def key_hook(code, wparam, lparam):
    if code == 0 and (wparam in KEY_DOWN or wparam in KEY_UP):
        t = now()
        info = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
        events.append(("K", t, info.vkCode, 1 if wparam in KEY_DOWN else 0, info.flags & LLKHF_INJECTED and 1))
    return user32.CallNextHookEx(None, code, wparam, lparam)


def main():
    out, seconds = sys.argv[1], float(sys.argv[2])
    hooks = [user32.SetWindowsHookExW(WH_MOUSE_LL, mouse_hook, None, 0), user32.SetWindowsHookExW(WH_KEYBOARD_LL, key_hook, None, 0)]
    if not all(hooks):
        sys.exit("SetWindowsHookExW failed")
    thread_id = kernel32.GetCurrentThreadId()
    threading.Timer(seconds, lambda: user32.PostThreadMessageW(thread_id, WM_QUIT, 0, 0)).start()
    message = wt.MSG()
    while user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
        pass
    for handle in hooks:
        user32.UnhookWindowsHookEx(handle)
    frequency = ctypes.c_int64()
    kernel32.QueryPerformanceFrequency(ctypes.byref(frequency))
    with open(out, "w") as file:
        file.write(f"# input hook clock=qpc frequency={frequency.value}\n")
        for kind, t, a, b, injected in events:
            file.write(f"{kind} {t} {a} {b} {injected}\n")
    print(f"{len(events)} input events logged")


main()
