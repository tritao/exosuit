"""Drives the editor through a fixed session with OS-level input (SendInput), so runs before and after a change see the
same input. Usage: scenario.py OUT.json [--wait-window SECONDS] [--seed N]

Phases, after the editor window appears and settles:
  idle-start   5 s nothing: an idle editor should draw (almost) nothing
  hover       10 s mouse sweeps at 1 kHz with pauses, over the activity bar and the text
  keys         5 s one click in the text, arrow taps, then arrow holds (no file is changed)
  scroll       3 s wheel notches down and up over the text
  idle-scroll  4 s nothing, while the scrollbar fades
  sidebar      4 s clicks on three rows of the side bar's file tree
  idle-end     4 s nothing
OUT.json gets each phase's start and end on time.perf_counter_ns() (QueryPerformanceCounter, the clock NativeKit stamps
input with) and the time of the first injected move, which metrics.py aligns with the first input in the trace.
Keep the desktop unlocked: SendInput does not reach a locked session."""

import ctypes
import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "input-latency"))
import driver  # noqa: E402  (SendInput helpers and the editor window finder)

MOUSEEVENTF_WHEEL = 0x0800
VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN = 0x25, 0x27, 0x26, 0x28


def wheel(notches):
    i = driver.INPUT(type=driver.INPUT_MOUSE)
    i.u.mi = driver.MOUSEINPUT(0, 0, ctypes.c_uint32(-120 * notches).value, MOUSEEVENTF_WHEEL, 0, 0)
    driver.send(i)


def sweep(rng, x, y, tx, ty):
    steps = int(rng.uniform(150, 500))
    t = time.perf_counter()
    for s in range(1, steps + 1):
        driver.move(x + (tx - x) * s / steps, y + (ty - y) * s / steps)
        t += 0.001
        driver.sleep_until(t)
    return tx, ty


def main():
    out = sys.argv[1]
    wait_window = float(sys.argv[sys.argv.index("--wait-window") + 1]) if "--wait-window" in sys.argv else 300
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1
    rng = random.Random(seed)
    driver.winmm.timeBeginPeriod(1)
    hwnd, (left, top, right, bottom) = driver.editor_window(time.time() + wait_window)
    time.sleep(4)  # first frames, language server start
    driver.foreground(hwnd)
    x0, y0, x1, y1 = left + 20, top + 60, right - 20, bottom - 40
    text_x, text_y = left + (right - left) * 0.55, top + (bottom - top) * 0.45
    phases = []
    first_move_ns = None

    def phase(name, seconds, body):
        start = time.perf_counter_ns()
        end = time.perf_counter() + seconds
        body(end)
        driver.sleep_until(end)
        phases.append({"name": name, "start_ns": start, "end_ns": time.perf_counter_ns()})

    def idle(end):
        pass

    def hover(end):
        nonlocal first_move_ns
        x, y = (x0 + x1) / 2, (y0 + y1) / 2
        first_move_ns = time.perf_counter_ns()
        driver.move(x, y)
        while time.perf_counter() < end - 1.0:
            time.sleep(rng.uniform(0.3, 0.8))
            tx = rng.uniform(x0, x0 + 40) if rng.random() < 0.4 else rng.uniform(x0, x1)
            x, y = sweep(rng, x, y, tx, rng.uniform(y0, y1))

    def keys(end):
        driver.move(text_x, text_y)
        time.sleep(0.2)
        driver.click()
        time.sleep(0.3)
        for vk in (VK_DOWN, VK_DOWN, VK_RIGHT, VK_RIGHT, VK_UP, VK_LEFT, VK_DOWN, VK_RIGHT):
            driver.key(vk, True)
            time.sleep(0.05)
            driver.key(vk, False)
            time.sleep(rng.uniform(0.15, 0.3))
        for vk in (VK_DOWN, VK_UP):  # held: autorepeat at about 30 Hz
            driver.key(vk, True)
            t = time.perf_counter()
            for _ in range(20):
                t += 0.033
                driver.sleep_until(t)
                driver.key(vk, True)
            driver.key(vk, False)
            time.sleep(0.2)

    def scroll(end):
        driver.move(text_x, text_y)
        for notches in (1,) * 8 + (-1,) * 8:
            wheel(notches)
            time.sleep(0.15)

    def sidebar(end):
        for row in range(3):
            driver.move(left + 110, top + 120 + row * 24)
            time.sleep(0.3)
            driver.click()
            time.sleep(0.9)
        driver.move(text_x, text_y)

    phase("idle-start", 5, idle)
    phase("hover", 10, hover)
    phase("keys", 5, keys)
    phase("scroll", 3, scroll)
    phase("idle-scroll", 4, idle)
    phase("sidebar", 4, sidebar)
    phase("idle-end", 4, idle)
    with open(out, "w") as f:
        json.dump({"first_move_ns": first_move_ns, "phases": phases, "window": [left, top, right, bottom]}, f, indent=1)
    print(f"scenario done: {len(phases)} phases")


if __name__ == "__main__":
    main()
