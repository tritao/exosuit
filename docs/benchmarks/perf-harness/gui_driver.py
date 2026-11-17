"""Drives a real editor window over suit's control plane and checks what the app says afterwards.

Everything goes through suit's pipe (docs/design/suitctl/TDD-exosuit-ctl.md §8.4): `exosuit.ui.snapshot` gives every
labelled element with its bounds and the app's state (context, workspaces, groups, tabs, the persisted session lines,
...); clicks, keys and text are `exosuit.ui.*` calls the window turns into synthetic events in its own input queue;
dialogs wait for `exosuit.dialog.answer`. The real mouse and keyboard are never touched, and the window need not be in
front. Nothing here uses a fixed pixel.

A scenario is a Python file with `def run(gui)`; see gui_scenarios/. Run it through measure.ps1 -Drive, which launches
the editor with isolated state and an isolated suit, and a deadline. Directly, with EXOSUIT_SUIT_HOME set to the
editor's suit home:

    python -I gui_scenarios/<name>.py --pid HLPID --out RESULT_DIR [--wait-window S]

A scenario that measures real input latency sets REAL_INPUT = True and gets RealInputGui, which sends OS input
(SendInput) the way a person does; it is the only one that may move the mouse."""

import ctypes
import ctypes.wintypes as wt
import json
import os
import re
import struct
import sys
import time
import zlib

user32, gdi32, kernel32 = ctypes.windll.user32, ctypes.windll.gdi32, ctypes.windll.kernel32
user32.PrintWindow.argtypes = [wt.HWND, wt.HDC, wt.UINT]
user32.PrintWindow.restype = wt.BOOL
kernel32.PeekNamedPipe.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.c_void_p, ctypes.POINTER(wt.DWORD), ctypes.c_void_p]

_counter = ctypes.c_int64()


def qpc():
    """QueryPerformanceCounter ticks: the clock of the input hook, NativeKit's NK_LATENCY_TRACE and the app's switch trace."""
    kernel32.QueryPerformanceCounter(ctypes.byref(_counter))
    return _counter.value


def qpc_frequency():
    frequency = ctypes.c_int64()
    kernel32.QueryPerformanceFrequency(ctypes.byref(frequency))
    return frequency.value


class Failure(Exception):
    pass


class ControlError(Failure):
    def __init__(self, error):
        self.code = error.get("code", "internal")
        self.retryable = bool(error.get("retryable"))
        super().__init__("%s: %s" % (self.code, error.get("message", "")))


class Suit:
    """suit's main pipe: one connection per call, HMPK frames carrying JSON (src/suit/SuitControl.hx does the same)."""

    def __init__(self, home=None):
        self.home = home or os.environ.get("EXOSUIT_SUIT_HOME")
        if not self.home:
            raise Failure("EXOSUIT_SUIT_HOME is not set: the driver talks to the editor's own, isolated suit")

    def endpoint(self, timeout=30.0):
        end = time.monotonic() + timeout
        while True:
            try:
                with open(os.path.join(self.home, "daemon.json"), encoding="utf-8") as f:
                    return json.load(f)["endpoint"]
            except (OSError, ValueError, KeyError):
                if time.monotonic() > end:
                    raise Failure("suit is not running in " + self.home)
                time.sleep(0.2)

    def request(self, message, timeout=15.0):
        data = json.dumps(message).encode()
        end = time.monotonic() + timeout
        while True:
            try:
                pipe = open(self.endpoint(), "r+b", buffering=0)
                break
            except OSError:  # every instance of the pipe is busy for a moment
                if time.monotonic() > end:
                    raise Failure("cannot connect to suit")
                time.sleep(0.05)
        with pipe:
            pipe.write(b"HMPK\x01\x00" + len(data).to_bytes(4, "big") + data)
            import msvcrt
            handle = msvcrt.get_osfhandle(pipe.fileno())
            buffer = b""
            while True:
                if len(buffer) >= 10:
                    length = int.from_bytes(buffer[6:10], "big")
                    if len(buffer) >= 10 + length:
                        return json.loads(buffer[10:10 + length])
                count = wt.DWORD(0)
                if not kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(count), None):
                    raise Failure("suit closed the connection")
                if count.value:
                    buffer += pipe.read(count.value)
                    continue
                if time.monotonic() > end:
                    raise Failure("suit did not answer %s in %.0f s" % (message.get("method", message.get("op")), timeout))
                time.sleep(0.005)

    def control(self, method, params=None, target=None, timeout=15.0):
        reply = self.request({"op": "control", "version": 1, "client_id": "gui_driver:%d" % os.getpid(), "method": method,
                              "params": params or {}, "target": target or {}}, timeout)
        if reply.get("ok") is not True:
            raise ControlError(reply.get("error") or {"message": str(reply)})
        return reply.get("result") or {}

    def instance_of(self, pid):
        for instance in self.control("exosuit.instances")["instances"]:
            if instance["pid"] == pid:
                return instance["instance_id"]
        return None


class Gui:
    def __init__(self, pid, out, deadline_seconds=100, wait_window=90):
        self.pid, self.out = int(pid), out
        os.makedirs(out, exist_ok=True)
        self.started = time.monotonic()
        self.deadline = self.started + deadline_seconds
        self.results = []
        self.shots = 0
        self.suit = Suit()
        self.instance = self._wait_instance(time.monotonic() + wait_window)
        self.hwnd = None

    # ---- the window over suit -------------------------------------------------------------------------------------
    def _wait_instance(self, deadline):
        while True:
            try:
                found = self.suit.instance_of(self.pid)
                if found:
                    return found
            except Failure:
                pass
            if time.monotonic() > deadline:
                raise Failure("the editor (pid %d) did not link to suit" % self.pid)
            time.sleep(0.3)

    def call(self, method, params=None, timeout=15.0):
        """A control method of this window. A `busy` answer (the user's own input is recent) is tried again."""
        while True:
            self._check_deadline()
            try:
                return self.suit.control(method, params, {"instance_id": self.instance}, timeout)
            except ControlError as error:
                if not error.retryable or error.code != "busy":
                    raise
                time.sleep(0.5)

    def snapshot(self, timeout=10):
        snap = self.call("exosuit.ui.snapshot", {"state": True}, timeout)
        snap["seq"] = snap.get("frame", 0)
        return snap

    def state(self):
        return self.call("exosuit.state.get")["state"]

    def wait(self, what, predicate, timeout=10.0, settle=0.0):
        """Waits until predicate(snapshot) is truthy (returns its value); records nothing. Raises Failure on timeout."""
        end = min(time.monotonic() + timeout, self.deadline)
        while True:
            self._check_deadline()
            try:
                value = predicate(self.snapshot(5))
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

    @staticmethod
    def point(element, fx=0.5, fy=0.5):
        """A point of an element for the control plane: the element itself (its id), and where inside it."""
        return {"element_id": element["id"], "fx": fx, "fy": fy, "x": element["x"] + element["w"] * fx, "y": element["y"] + element["h"] * fy}

    def _at(self, method, element, params, fx=0.5, fy=0.5):
        """An input call on an element; an element that was rebuilt since the snapshot is reached at its last position."""
        target = self.point(element, fx, fy)
        try:
            return self.call(method, dict(params, element_id=target["element_id"], fx=fx, fy=fy))
        except ControlError as error:
            if error.code != "not_found":
                raise
            return self.call(method, dict(params, x=target["x"], y=target["y"]))

    # ---- input: synthetic events in the window's own queue --------------------------------------------------------
    def click(self, element, count=1, button="left", fx=0.5, fy=0.5):
        result = self._at("exosuit.ui.activate", element, {"button": button, "count": count}, fx, fy)
        time.sleep(0.1)
        return result

    def hover(self, element, fx=0.5, fy=0.5):
        return self._at("exosuit.ui.hover", element, {}, fx, fy)

    def scroll(self, element, notches=-3):
        """Wheel notches over an element (negative scroll down)."""
        self._at("exosuit.ui.scroll", element, {"notches": notches})
        time.sleep(0.2)

    def drag(self, source, target, source_fy=0.5, target_fy=0.5, hold=0.25):
        """Press on `source`, move to a point of `target` in steps, hold, release. Fractions pick the point inside each
        element (target_fy 0.1 is near its top edge, 0.5 its middle)."""
        self.call("exosuit.ui.drag", {"from": self.point(source, 0.3, source_fy), "to": self.point(target, 0.3, target_fy)})
        time.sleep(0.3)

    def chord(self, spec):
        """'ctrl+shift+a', 'alt+up', 'enter', ...: the key with the modifiers held."""
        result = self.call("exosuit.ui.key", {"chord": spec})
        time.sleep(0.1)
        return result

    def type_text(self, text, delay=None):
        self.call("exosuit.ui.type", {"text": text})
        time.sleep(0.1)

    def answer_dialog(self, paths=None, choice=None, kind=None, timeout=8.0):
        """Answers the dialog the window is waiting on (a folder or file picker: `paths`; a question: `choice`)."""
        end = time.monotonic() + timeout
        while True:
            waiting = [d for d in self.call("exosuit.dialogs.list")["dialogs"] if kind is None or d["kind"] == kind]
            if waiting:
                params = {"id": waiting[0]["id"]}
                if paths is not None:
                    params["paths"] = list(paths)
                if choice is not None:
                    params["choice"] = choice
                return self.call("exosuit.dialog.answer", params)
            if time.monotonic() > end:
                raise Failure("no %s dialog opened" % (kind or "waiting"))
            time.sleep(0.1)

    def open_workspace(self, workspace_id):
        """What a double click on a workspace row does, sent to the window whatever is on screen."""
        return self.call("exosuit.workspace.open", {"id": workspace_id})

    def release_all(self):
        """Synthetic input holds nothing down between calls; kept for scenarios that clean up after a failure."""

    def focus(self, seconds=5.0):
        """Raises the window (only screenshots of the screen need it in front; input does not)."""
        try:
            self.call("window.focus")
        except Failure:
            pass

    # ---- evidence and checks --------------------------------------------------------------------------------------
    def window(self):
        if self.hwnd is None:
            self.hwnd = find_window(self.pid, time.time() + 10)
        return self.hwnd

    def shot(self, name):
        """The editor window's own pixels (PrintWindow) as PNG in the result folder; covering windows are not in it."""
        return self.shot_window(name)

    def shot_window(self, name):
        hwnd = self.window()
        window = wt.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(window))
        ww, wh = window.right - window.left, window.bottom - window.top
        screen = user32.GetDC(0)
        mem = gdi32.CreateCompatibleDC(screen)
        bitmap = gdi32.CreateCompatibleBitmap(screen, ww, wh)
        gdi32.SelectObject(mem, bitmap)
        user32.PrintWindow(hwnd, mem, 2)

        class BMI(ctypes.Structure):
            _fields_ = [("size", wt.DWORD), ("w", wt.LONG), ("h", wt.LONG), ("planes", wt.WORD), ("bits", wt.WORD),
                        ("comp", wt.DWORD), ("img", wt.DWORD), ("x", wt.LONG), ("y", wt.LONG), ("u", wt.DWORD), ("i", wt.DWORD)]
        info = BMI(ctypes.sizeof(BMI), ww, -wh, 1, 32, 0, 0, 0, 0, 0, 0)
        buf = ctypes.create_string_buffer(ww * wh * 4)
        gdi32.GetDIBits(mem, bitmap, 0, wh, buf, ctypes.byref(info), 0)
        gdi32.DeleteObject(bitmap)
        gdi32.DeleteDC(mem)
        user32.ReleaseDC(0, screen)
        data = buf.raw
        row = ww * 4
        raw = bytearray()
        for y in range(wh):
            raw.append(0)
            line = data[y * row:(y + 1) * row]
            rgb = bytearray(ww * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = line[2::4], line[1::4], line[0::4]
            raw += rgb

        def chunk(tag, body):
            return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ww, wh, 8, 2, 0, 0, 0)) \
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

    def finish(self):
        self._save()
        failed = [r for r in self.results if not r["ok"]]
        print("%d checks, %d failed, %.0f s" % (len(self.results), len(failed), time.monotonic() - self.started), flush=True)
        return 1 if failed else 0


def find_window(pid, deadline):
    """The editor's largest visible top-level window: screenshots and the real-input driver need it."""
    WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    found = []

    def visit(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            owner = wt.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
            if owner.value == pid:
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
    raise Failure("no editor window for pid %d" % pid)


class RealInputGui(Gui):
    """OS input (SendInput) for scenarios that measure real input latency: the pointer and keys a person uses. Positions
    still come from `exosuit.ui.snapshot`. Before every action the editor must be in front and under the pointer, else
    the run stops, so input never reaches another program. Every input sent is stamped (sent.txt in the result folder)."""

    VK = {"ctrl": 0x11, "shift": 0x10, "alt": 0x12, "enter": 0x0D, "return": 0x0D, "esc": 0x1B, "escape": 0x1B, "tab": 0x09,
          "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27, "home": 0x24, "end": 0x23, "delete": 0x2E, "backspace": 0x08,
          "space": 0x20, "f2": 0x71, "f4": 0x73, "f5": 0x74, "pageup": 0x21, "pagedown": 0x22}
    VK.update({c: ord(c.upper()) for c in "abcdefghijklmnopqrstuvwxyz"})
    VK.update({c: ord(c) for c in "0123456789"})
    EXTENDED = {0x26, 0x28, 0x25, 0x27, 0x24, 0x23, 0x2E, 0x21, 0x22}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "input-latency"))
        import driver  # noqa: E402  (SendInput helpers)
        self.driver = driver
        user32.WindowFromPoint.argtypes = [wt.POINT]
        user32.WindowFromPoint.restype = wt.HWND
        user32.GetAncestor.argtypes = [wt.HWND, wt.UINT]
        user32.GetAncestor.restype = wt.HWND
        self.sent = []
        driver.winmm.timeBeginPeriod(1)
        self.window()
        self.focus()

    def focus(self, seconds=5.0):
        deadline = time.time() + seconds
        self.driver.foreground(self.window())
        while self._foreground_pid() != self.pid and time.time() < deadline:
            time.sleep(0.2)
            self.driver.foreground(self.window())

    def _owner(self, hwnd):
        root = user32.GetAncestor(hwnd, 2) if hwnd else None
        pid = wt.DWORD()
        if root:
            user32.GetWindowThreadProcessId(root, ctypes.byref(pid))
        return pid.value

    def _foreground_pid(self):
        return self._owner(user32.GetForegroundWindow())

    def _guard(self, x, y):
        if self._foreground_pid() != self.pid or self._owner(user32.WindowFromPoint(wt.POINT(int(x), int(y)))) != self.pid:
            raise Failure("the editor is not in front and under the pointer at %d,%d; stopping" % (x, y))

    def screen_point(self, element, fx=0.5, fy=0.5):
        snap = self.snapshot()
        r = wt.RECT()
        user32.GetClientRect(self.window(), ctypes.byref(r))
        p = wt.POINT(0, 0)
        user32.ClientToScreen(self.window(), ctypes.byref(p))
        v = snap["viewport"]
        sx, sy = (r.right - r.left) / v["width"], (r.bottom - r.top) / v["height"]
        return p.x + (element["x"] + element["w"] * fx) * sx, p.y + (element["y"] + element["h"] * fy) * sy

    def click(self, element, count=1, button="left", fx=0.5, fy=0.5):
        x, y = self.screen_point(element, fx, fy)
        self._guard(x, y)
        self.driver.move(x, y)
        time.sleep(0.12)
        down, up = (self.driver.MOUSEEVENTF_LEFTDOWN, self.driver.MOUSEEVENTF_LEFTUP) if button == "left" else (0x8, 0x10)
        for _ in range(count):
            self._guard(x, y)
            for flag in (down, up):
                i = self.driver.INPUT(type=self.driver.INPUT_MOUSE)
                i.u.mi = self.driver.MOUSEINPUT(0, 0, 0, flag, 0, 0)
                self.sent.append(("down" if flag == down else "up", qpc(), button))
                self.driver.send(i)
                time.sleep(0.04)
        time.sleep(0.15)

    def chord(self, spec):
        keys = [self.VK[part] for part in spec.lower().split("+")]
        for down in (True, False):
            for vk in (keys if down else reversed(keys)):
                if down and self._foreground_pid() != self.pid:
                    raise Failure("the foreground window is not the editor's; refusing to send keys")
                i = self.driver.INPUT(type=self.driver.INPUT_KEYBOARD)
                flags = (0 if down else 0x2) | (0x1 if vk in self.EXTENDED else 0)
                i.u.ki = self.driver.KEYBDINPUT(vk, user32.MapVirtualKeyW(vk, 0), flags, 0, 0)
                self.sent.append(("keydown" if down else "keyup", qpc(), vk))
                self.driver.send(i)
                time.sleep(0.02)
        time.sleep(0.2)

    def type_text(self, text, delay=0.03):
        for ch in text:
            if self._foreground_pid() != self.pid:
                raise Failure("the foreground window is not the editor's; refusing to send keys")
            for flag in (0x4, 0x4 | 0x2):
                i = self.driver.INPUT(type=self.driver.INPUT_KEYBOARD)
                i.u.ki = self.driver.KEYBDINPUT(0, ord(ch), flag, 0, 0)
                self.driver.send(i)
            time.sleep(delay)
        time.sleep(0.15)

    def _save(self):
        super()._save()
        if self.sent:
            with open(os.path.join(self.out, "sent.txt"), "w") as f:
                f.write("# driver sends clock=qpc frequency=%d\n" % qpc_frequency())
                for kind, ticks, detail in self.sent:
                    f.write("%s %d %s\n" % (kind, ticks, detail))


def main(run, real_input=False):
    args = sys.argv[1:]

    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default
    kind = RealInputGui if real_input else Gui
    gui = kind(opt("--pid"), opt("--out"), float(opt("--deadline", 100)), float(opt("--wait-window", 90)))
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
    sys.exit(gui.finish())
