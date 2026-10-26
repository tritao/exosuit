"""Drives the editor with X11 input through the XTEST extension: the X server receives it as it would from a device (it skips
the kernel and evdev, which the Windows driver's SendInput does not). Usage: driver_x11.py TITLE [--seconds S]
[--wait-window S] [--settle S] [--seed N]

Phases: mouse sweeps at ~1 kHz across the window, each after a 0.3-0.9 s pause (so movement onsets can be measured), then
a click in the middle of the window and arrow-key taps and holds (holds repeat at 30 Hz like keyboard autorepeat). Arrow
keys only, so no file is modified. Stops after S seconds of input (default 60)."""
import argparse, random, sys, time

from Xlib import X, XK, display
from Xlib.ext import xtest


def find_window(root, title):
    """The first window below root whose name contains title, or None."""
    stack = [root]
    while stack:
        window = stack.pop()
        try:
            name = window.get_wm_name()
            if name and title in (name if isinstance(name, str) else name.decode("utf-8", "replace")):
                return window
            stack.extend(window.query_tree().children)
        except Exception:
            continue
    return None


def spin_until(deadline):
    """Waits to deadline (time.perf_counter) with a short sleep and a spin, as the sweeps need ~1 ms steps."""
    while True:
        left = deadline - time.perf_counter()
        if left <= 0:
            return
        if left > 0.0015:
            time.sleep(left - 0.001)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("title")
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--wait-window", type=float, default=90)
    parser.add_argument("--settle", type=float, default=8, help="seconds to let the editor start before the first input")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    random.seed(args.seed)
    d = display.Display()
    root = d.screen().root

    deadline = time.time() + args.wait_window
    window = None
    while window is None and time.time() < deadline:
        window = find_window(root, args.title)
        if window is None:
            time.sleep(0.25)
    if window is None:
        print("driver: no window titled %r" % args.title, file=sys.stderr)
        return 1
    time.sleep(args.settle)
    geometry = window.get_geometry()
    origin = window.translate_coords(root, 0, 0)
    left, top = -origin.x, -origin.y
    width, height = geometry.width, geometry.height
    print("driver: window %dx%d at %d,%d" % (width, height, left, top), flush=True)

    def move(x, y):
        xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y))
        d.flush()

    def button(down):
        xtest.fake_input(d, X.ButtonPress if down else X.ButtonRelease, 1)
        d.flush()

    def key(code, down):
        xtest.fake_input(d, X.KeyPress if down else X.KeyRelease, code)
        d.flush()

    codes = {name: d.keysym_to_keycode(getattr(XK, "XK_" + name)) for name in ("Left", "Right", "Up", "Down")}
    end = time.perf_counter() + args.seconds

    # Mouse sweeps: ~1 kHz steps of 4 px across the window, separated by stillness.
    sweeps = 0
    while time.perf_counter() < end - args.seconds * 0.4:
        time.sleep(random.uniform(0.3, 0.9))
        y = top + random.uniform(0.15, 0.85) * height
        x0, x1 = (left + 20, left + width - 20) if sweeps % 2 == 0 else (left + width - 20, left + 20)
        steps = int(abs(x1 - x0) / 4)
        started = time.perf_counter()
        for i in range(steps):
            move(x0 + (x1 - x0) * i / steps, y + 40 * __import__("math").sin(i / 17.0))
            spin_until(started + (i + 1) * 0.001)
        sweeps += 1
    print("driver: %d sweeps" % sweeps, flush=True)

    # A click in the middle of the window, then arrow-key taps and holds.
    move(left + width / 2, top + height / 2)
    time.sleep(0.2)
    button(True)
    time.sleep(0.05)
    button(False)
    time.sleep(0.5)
    taps = 0
    while time.perf_counter() < end:
        code = codes[random.choice(["Left", "Right", "Up", "Down"])]
        if random.random() < 0.7:
            time.sleep(random.uniform(0.15, 0.5))
            key(code, True)
            time.sleep(0.04)
            key(code, False)
            taps += 1
        else:
            time.sleep(random.uniform(0.15, 0.4))
            started = time.perf_counter()
            hold = random.uniform(0.4, 1.0)
            key(code, True)
            while time.perf_counter() - started < hold:
                time.sleep(1 / 30)
                key(code, True)  # autorepeat: the server sees the same key pressed again
            key(code, False)
            taps += 1
    print("driver: %d key actions" % taps, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
