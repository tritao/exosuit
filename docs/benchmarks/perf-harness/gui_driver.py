"""Drives the real editor window with real OS input (SendInput) and checks what the app says afterwards.

The positions of UI elements and the app's state come from the app itself: with EXOSUIT_AUTOMATION_DIR set the editor
writes snapshot.json there (src/devtools/AutomationProbe.hx): every labelled element with its bounds, and the app's
state (context, workspaces, groups, tabs, the persisted session lines, ...). Nothing here uses a fixed pixel.

A scenario is a Python file with `def run(gui)`; see gui_scenarios/. Run it through measure.ps1 -Drive, which launches
the editor with isolated state, one capture at a time (the named mutex), and a deadline. Directly:

    python -I gui_scenarios/<name>.py --pid HLPID --dir AUTOMATION_DIR --out RESULT_DIR [--wait-window S]

Safety: before every mouse action the window under the pointer must belong to the editor's process; otherwise the run
stops. Every wait has a timeout, and the whole run has a deadline."""

import ctypes
import ctypes.wintypes as wt
import json
import os
import re
import struct
import sys
import time
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "input-latency"))
import driver  # noqa: E402  (SendInput helpers)

user32, gdi32, kernel32 = ctypes.windll.user32, ctypes.windll.gdi32, ctypes.windll.kernel32
user32.WindowFromPoint.argtypes = [wt.POINT]
user32.WindowFromPoint.restype = wt.HWND
user32.GetAncestor.argtypes = [wt.HWND, wt.UINT]
user32.GetAncestor.restype = wt.HWND

VK = {"ctrl": 0x11, "shift": 0x10, "alt": 0x12, "enter": 0x0D, "return": 0x0D, "esc": 0x1B, "escape": 0x1B, "tab": 0x09,
      "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27, "home": 0x24, "end": 0x23, "delete": 0x2E, "backspace": 0x08,
      "space": 0x20, "f2": 0x71, "f5": 0x74, "pageup": 0x21, "pagedown": 0x22}
for c in "abcdefghijklmnopqrstuvwxyz":
    VK[c] = ord(c.upper())
for c in "0123456789":
    VK[c] = ord(c)
EXTENDED = {0x26, 0x28, 0x25, 0x27, 0x24, 0x23, 0x2E, 0x21, 0x22}
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_UNICODE, KEYEVENTF_KEYUP = 0x1, 0x4, 0x2
MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP = 0x8, 0x10


class Failure(Exception):
    pass


class Gui:
    def __init__(self, pid, directory, out, deadline_seconds=100, wait_window=90):
        self.pid, self.dir, self.out = int(pid), directory, out
        os.makedirs(out, exist_ok=True)
        self.started = time.monotonic()
        self.deadline = self.started + deadline_seconds
        self.results = []
        self.seq_seen = 0
        self.shots = 0
        self.log_lines = []
        self.held_keys = []
        self.held_buttons = []
        driver.winmm.timeBeginPeriod(1)
        self.hwnd = self._find_window(time.time() + wait_window)
        self.focus()

    # ---- window and geometry ------------------------------------------------------------------------------------
    def _find_window(self, deadline):
        WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
        found = []

        def visit(hwnd, _):
            if user32.IsWindowVisible(hwnd):
                pid = wt.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if pid.value == self.pid:
                    r = wt.RECT()
                    user32.GetWindowRect(hwnd, ctypes.byref(r))
                    area = (r.right - r.left) * (r.bottom - r.top)
                    if area > 300 * 300:
                        found.append((area, hwnd))
            return True

        while time.time() < deadline:
            found.clear()
            user32.EnumWindows(WNDENUMPROC(visit), 0)
            if found:
                return max(found)[1]
            time.sleep(0.5)
        raise Failure("no editor window for pid %d" % self.pid)

    def focus(self):
        driver.foreground(self.hwnd)

    def client(self):
        """(left, top, width, height) of the window's client area in physical screen pixels."""
        r = wt.RECT()
        user32.GetClientRect(self.hwnd, ctypes.byref(r))
        p = wt.POINT(0, 0)
        user32.ClientToScreen(self.hwnd, ctypes.byref(p))
        return p.x, p.y, r.right - r.left, r.bottom - r.top

    # ---- the app's snapshot -------------------------------------------------------------------------------------
    def snapshot(self, timeout=10):
        path = os.path.join(self.dir, "snapshot.json")
        end = time.monotonic() + timeout
        while True:
            try:
                with open(path, encoding="utf-8") as f:
                    snap = json.load(f)
                self.seq_seen = snap["seq"]
                return snap
            except (OSError, ValueError, KeyError):
                if time.monotonic() > end:
                    raise Failure("no snapshot in %s (is EXOSUIT_AUTOMATION_DIR set and the app built with the probe?)" % path)
                time.sleep(0.05)

    def state(self):
        return self.snapshot()["state"]

    def wait(self, what, predicate, timeout=10.0, settle=0.0):
        """Waits until predicate(snapshot) is truthy (returns its value); records nothing. Raises Failure on timeout."""
        end = min(time.monotonic() + timeout, self.deadline)
        last = None
        while True:
            self._check_deadline()
            try:
                last = self.snapshot(2)
                value = predicate(last)
                if value:
                    if settle:
                        time.sleep(settle)
                    return value
            except Failure:
                pass
            except (KeyError, IndexError, TypeError):
                pass
            if time.monotonic() > end:
                raise Failure("timed out waiting for " + what)
            time.sleep(0.05)

    def _check_deadline(self):
        if time.monotonic() > self.deadline:
            raise Failure("scenario deadline passed")

    # ---- elements -------------------------------------------------------------------------------------------------
    @staticmethod
    def find(snap, label=None, pattern=None, role=None):
        """Visible elements whose label equals `label` or matches `pattern`, optionally of `role`, top to bottom."""
        rx = re.compile(pattern) if pattern else None
        hits = [e for e in snap["elements"]
                if (label is None or e["label"] == label) and (rx is None or rx.search(e["label"]))
                and (role is None or e["role"] == role)]
        return sorted(hits, key=lambda e: (e["y"], e["x"]))

    def element(self, label=None, pattern=None, role=None, timeout=8.0, index=0):
        def look(snap):
            hits = [e for e in self.find(snap, label, pattern, role) if self.on_screen(snap, e)]
            return hits[index] if len(hits) > index else None
        return self.wait("element %r" % (label or pattern), look, timeout)

    def on_screen(self, snap, e):
        v = snap["viewport"]
        cx, cy = e["x"] + e["w"] / 2, e["y"] + e["h"] / 2
        return 0 <= cx < v["width"] and 0 <= cy < v["height"]

    def screen_point(self, element, fx=0.5, fy=0.5):
        """Physical screen pixels of a point inside an element (fractions of its size); the scale comes from the app's
        viewport size and the window's client size."""
        snap = self.snapshot()
        left, top, w, h = self.client()
        v = snap["viewport"]
        sx, sy = w / v["width"], h / v["height"]
        return left + (element["x"] + element["w"] * fx) * sx, top + (element["y"] + element["h"] * fy) * sy

    # ---- input ------------------------------------------------------------------------------------------------------
    def _guard(self, x, y):
        """The window under the pointer must be the editor's, else stop: input must never reach another program."""
        hwnd = user32.WindowFromPoint(wt.POINT(int(x), int(y)))
        root = user32.GetAncestor(hwnd, 2) if hwnd else None
        pid = wt.DWORD()
        if root:
            user32.GetWindowThreadProcessId(root, ctypes.byref(pid))
        if pid.value != self.pid:
            raise Failure("another window is under the pointer at %d,%d (pid %d); stopping" % (x, y, pid.value))

    def _foreground_pid(self):
        hwnd = user32.GetForegroundWindow()
        root = user32.GetAncestor(hwnd, 2) if hwnd else None
        pid = wt.DWORD()
        if root:
            user32.GetWindowThreadProcessId(root, ctypes.byref(pid))
        return pid.value

    def _guard_keyboard(self):
        """Key presses go to the foreground window, so it must be the editor's at the moment of every key press."""
        pid = self._foreground_pid()
        if pid != self.pid:
            self.release_all()
            raise Failure("the foreground window is not the editor's (pid %d); refusing to send keys" % pid)

    def _guard_button(self):
        """A button press needs the editor in front and under the pointer."""
        self._guard_keyboard()
        try:
            self._guard(*self._pointer())
        except Failure:
            self.release_all()
            raise

    def release_all(self):
        """Releases every key and button this driver holds down (always sent: a release does no harm elsewhere)."""
        for vk in reversed(self.held_keys):
            self._send_key(vk, False)
        self.held_keys = []
        for button in self.held_buttons:
            self._send_button(button, False)
        self.held_buttons = []

    def move(self, x, y):
        self._check_deadline()
        self._guard(x, y)
        driver.move(x, y)

    def glide(self, x, y, steps=12, pause=0.008):
        """A visible, human-like pointer path to x, y so hover states and drag thresholds see real movement."""
        px, py = self._pointer()
        left, top, w, h = self.client()
        if not (left <= px < left + w and top <= py < top + h):
            # The pointer is elsewhere (the user's desktop): jump to the target (checked), do not sweep across other windows.
            self.move(x, y)
            time.sleep(0.1)
            px, py = x, y
        for i in range(1, steps + 1):
            self.move(px + (x - px) * i / steps, py + (y - py) * i / steps)
            time.sleep(pause)

    def _pointer(self):
        p = wt.POINT()
        user32.GetCursorPos(ctypes.byref(p))
        return p.x, p.y

    def click(self, element, count=1, button="left", fx=0.5, fy=0.5):
        x, y = self.screen_point(element, fx, fy)
        self.glide(x, y)
        time.sleep(0.12)
        for i in range(count):
            self._button(button, True)
            time.sleep(0.04)
            self._button(button, False)
            time.sleep(0.07)
        time.sleep(0.15)

    def _button(self, button, down):
        if down:
            self._guard_button()
            self.held_buttons.append(button)
        elif button in self.held_buttons:
            self.held_buttons.remove(button)
        self._send_button(button, down)

    def _send_button(self, button, down):
        i = driver.INPUT(type=driver.INPUT_MOUSE)
        flags = {("left", True): driver.MOUSEEVENTF_LEFTDOWN, ("left", False): driver.MOUSEEVENTF_LEFTUP,
                 ("right", True): MOUSEEVENTF_RIGHTDOWN, ("right", False): MOUSEEVENTF_RIGHTUP}[(button, down)]
        i.u.mi = driver.MOUSEINPUT(0, 0, 0, flags, 0, 0)
        driver.send(i)

    def drag(self, source, target, source_fy=0.5, target_fy=0.5, hold=0.25):
        """Press on `source`, move to a point of `target` in steps, hold, release. Fractions pick the point inside each
        element (target_fy 0.1 is near its top edge, 0.5 its middle)."""
        sx, sy = self.screen_point(source, 0.3, source_fy)
        tx, ty = self.screen_point(target, 0.3, target_fy)
        self.glide(sx, sy)
        time.sleep(0.15)
        self._button("left", True)
        time.sleep(0.12)
        for i in range(1, 26):
            self.move(sx + (tx - sx) * i / 25, sy + (ty - sy) * i / 25)
            time.sleep(0.02)
        time.sleep(hold)
        self.move(tx + 1, ty)
        time.sleep(0.1)
        self._button("left", False)
        time.sleep(0.3)

    def chord(self, spec):
        """'ctrl+shift+a', 'alt+up', 'enter', ...: modifiers down in order, the key tapped, modifiers up in reverse."""
        self._check_deadline()
        keys = [VK[part] for part in spec.lower().split("+")]
        for vk in keys:
            self._key(vk, True)
            time.sleep(0.02)
        time.sleep(0.04)
        for vk in reversed(keys):
            self._key(vk, False)
            time.sleep(0.02)
        time.sleep(0.2)

    def _key(self, vk, down):
        if down:
            self._guard_keyboard()
            self.held_keys.append(vk)
        elif vk in self.held_keys:
            self.held_keys.remove(vk)
        self._send_key(vk, down)

    def _send_key(self, vk, down):
        i = driver.INPUT(type=driver.INPUT_KEYBOARD)
        flags = (0 if down else KEYEVENTF_KEYUP) | (KEYEVENTF_EXTENDEDKEY if vk in EXTENDED else 0)
        i.u.ki = driver.KEYBDINPUT(vk, user32.MapVirtualKeyW(vk, 0), flags, 0, 0)
        driver.send(i)

    def type_text(self, text, delay=0.03):
        for ch in text:
            self._check_deadline()
            self._guard_keyboard()
            for flag in (KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP):
                i = driver.INPUT(type=driver.INPUT_KEYBOARD)
                i.u.ki = driver.KEYBDINPUT(0, ord(ch), flag, 0, 0)
                driver.send(i)
            time.sleep(delay)
        time.sleep(0.15)

    # ---- evidence and checks --------------------------------------------------------------------------------------
    def shot(self, name):
        """Screenshot of the editor's client area (supporting evidence) as PNG in the result folder."""
        left, top, w, h = self.client()
        screen = user32.GetDC(0)
        mem = gdi32.CreateCompatibleDC(screen)
        bitmap = gdi32.CreateCompatibleBitmap(screen, w, h)
        gdi32.SelectObject(mem, bitmap)
        gdi32.BitBlt(mem, 0, 0, w, h, screen, left, top, 0x00CC0020)

        class BMI(ctypes.Structure):
            _fields_ = [("size", wt.DWORD), ("w", wt.LONG), ("h", wt.LONG), ("planes", wt.WORD), ("bits", wt.WORD),
                        ("comp", wt.DWORD), ("img", wt.DWORD), ("x", wt.LONG), ("y", wt.LONG), ("u", wt.DWORD), ("i", wt.DWORD)]
        info = BMI(ctypes.sizeof(BMI), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
        buf = ctypes.create_string_buffer(w * h * 4)
        gdi32.GetDIBits(mem, bitmap, 0, h, buf, ctypes.byref(info), 0)
        gdi32.DeleteObject(bitmap)
        gdi32.DeleteDC(mem)
        user32.ReleaseDC(0, screen)
        raw = bytearray()
        row = w * 4
        data = buf.raw
        for y in range(h):
            raw.append(0)
            line = data[y * row:(y + 1) * row]
            rgb = bytearray(w * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = line[2::4], line[1::4], line[0::4]
            raw += rgb
        def chunk(tag, body):
            return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
            + chunk(b"IDAT", zlib.compress(bytes(raw), 3)) + chunk(b"IEND", b"")
        self.shots += 1
        path = os.path.join(self.out, "%02d-%s.png" % (self.shots, name))
        with open(path, "wb") as f:
            f.write(png)
        return path

    def check(self, name, predicate, timeout=6.0, detail=None, known_bug=None):
        """Waits up to `timeout` for predicate(snapshot); records pass/fail with the app state it saw. Continues on failure.
        `known_bug` names a bug already reported: its failure is listed as KNOWN-BUG and does not fail the run, and when
        the check passes it says FIXED so the mark can be removed."""
        try:
            self.wait(name, predicate, timeout)
            ok, note = True, ""
        except Failure as failure:
            ok, note = False, str(failure)
        record = {"check": name, "ok": ok or bool(known_bug), "note": note, "at": round(time.monotonic() - self.started, 1)}
        if known_bug:
            record["known_bug"] = known_bug
            record["status"] = "FIXED" if ok else "KNOWN-BUG"
        if detail is not None and not ok:
            try:
                record["saw"] = detail(self.snapshot(2))
            except Exception as error:  # noqa: BLE001
                record["saw"] = "unavailable: %s" % error
        self.results.append(record)
        label = ("FIXED " if ok else "KNOWN-BUG ") if known_bug else ("PASS " if ok else "FAIL ")
        print(label + name + (" -- " + note if note else ""), flush=True)
        self._save()
        return ok

    def step(self, text):
        print("step: " + text, flush=True)

    def _save(self):
        with open(os.path.join(self.out, "results.json"), "w") as f:
            json.dump({"results": self.results, "seconds": round(time.monotonic() - self.started, 1)}, f, indent=1)

    def expect_refusal(self, name, action):
        """Runs `action`, which must make the driver refuse (raise Failure); records the check."""
        try:
            action()
        except Failure as failure:
            self.results.append({"check": name, "ok": True, "note": str(failure)})
            print("PASS " + name + " -- " + str(failure), flush=True)
            return True
        self.release_all()
        self.results.append({"check": name, "ok": False, "note": "the driver sent input although the editor was not in front"})
        print("FAIL " + name, flush=True)
        return False

    def finish(self):
        self._save()
        failed = [r for r in self.results if not r["ok"]]
        print("%d checks, %d failed, %.0f s" % (len(self.results), len(failed), time.monotonic() - self.started), flush=True)
        return 1 if failed else 0


def main(run):
    args = sys.argv[1:]
    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default
    gui = Gui(opt("--pid"), opt("--dir"), opt("--out"), float(opt("--deadline", 100)), float(opt("--wait-window", 90)))
    code = 1
    try:
        run(gui)
    except Failure as failure:
        gui.results.append({"check": "scenario", "ok": False, "note": str(failure)})
        print("FAIL scenario -- " + str(failure), flush=True)
        try:
            gui.shot("failure")
            with open(os.path.join(gui.out, "failure-snapshot.json"), "w") as f:
                json.dump(gui.snapshot(2), f, indent=1)
        except Exception:  # noqa: BLE001
            pass
    except Exception as error:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        gui.results.append({"check": "scenario", "ok": False, "note": repr(error)})
    gui.release_all()
    code = gui.finish()
    sys.exit(code)
