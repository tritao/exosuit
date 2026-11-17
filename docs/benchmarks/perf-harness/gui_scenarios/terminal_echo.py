"""Keystroke -> echo in a terminal whose shell is up, timed inside the editor. Real input (SendInput), one key at a time.

The terminal marks each keystroke that reaches it ("terminal-key", RpcTerminalBackend.write), the reply that brings
its echo ("terminal-echo-received") and the first frame drawn after the emulator applied that echo ("terminal-echo") in
the connect timeline. Nothing reads the editor's state while the keys are typed (a state read costs the UI thread
0.1-0.2 s), so the samples see only the editor, the service and the terminal host. The timeline is read once at the end.

  EXOSUIT_ECHO_SAMPLES   keys timed (default 20); EXOSUIT_ECHO_BUDGET  median budget in ms (default 200; measured 2026-11-16: medians 116-143 ms).

Results go to results.json: per-key samples, median and p90 of key -> echo on screen and key -> echo received."""
import inspect
import os
import random
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "input-latency"))
from m19_common import *  # noqa: F401,F403
import driver  # noqa: E402  (SendInput helpers)

FIXTURE = {"workspaces": ["alpha"], "open": "alpha", "appArgs": ["--open-workbench"]}
KEYEVENTF_UNICODE, KEYEVENTF_KEYUP = 0x4, 0x2


def send_char(gui, ch):
    if gui._foreground_pid() != gui.pid:
        raise Failure("the foreground window is not the editor's; refusing to send keys")
    for flag in (KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP):
        i = driver.INPUT(type=driver.INPUT_KEYBOARD)
        i.u.ki = driver.KEYBDINPUT(0, ord(ch), flag, 0, 0)
        driver.send(i)


def marks(gui, name):
    return [e for e in gui.state()["timeline"] if e["event"] == name]


def pairs(timeline):
    """(key t, received t, drawn t) for each "terminal-key" mark, from the marks that follow it before the next key."""
    out, key, received = [], None, None
    for e in timeline:
        if e["event"] == "terminal-key":
            key, received = e["t"], None
        elif e["event"] == "terminal-echo-received" and key is not None:
            received = e["t"]
        elif e["event"] == "terminal-echo" and key is not None:
            out.append((key, received, e["t"]))
            key = None
    return out


def stats(values):
    values = sorted(values)
    if not values:
        return None, None
    median = values[len(values) // 2] if len(values) % 2 else (values[len(values) // 2 - 1] + values[len(values) // 2]) / 2
    return median, values[min(len(values) - 1, int(round(0.9 * (len(values) - 1))))]


def run(gui):
    attached(gui, "Alpha")
    gui.focus()
    show_workbench(gui)
    gui.click(gui.element("New terminal"))
    # The shell's prompt: a key typed before it is up waits for the shell's startup. Type until one echoes.
    pause = os.path.join(getattr(gui, "dir", "") or "", "pause")
    end = time.monotonic() + 30
    while True:
        send_char(gui, "x")
        time.sleep(1.5)
        if pairs(gui.state()["timeline"]):
            break
        if time.monotonic() > end:
            raise Failure("no echo of a typed key in 30 s (is the terminal focused?)")
    time.sleep(1.0)
    before = gui.state()["timeline"]
    start = before[-1]["t"] if before else -1
    count = int(os.environ.get("EXOSUIT_ECHO_SAMPLES", "20"))
    gui.step("typing %d keys, one every 0.3-0.4 s" % count)
    # The baseline's automation probe serializes the whole state every 0.1 s on the UI thread; its pause file stops that
    # while the keys are timed (a later probe answers reads on request and needs none).
    if getattr(gui, "dir", None):
        open(pause, "w").close()
    try:
        for index in range(count):
            send_char(gui, "abcdefghijklmnopqrstuvwxyz"[index % 26])
            time.sleep(0.3 + random.random() * 0.1)
        time.sleep(0.5)
    finally:
        if getattr(gui, "dir", None) and os.path.exists(pause):
            os.remove(pause)
            time.sleep(1.0)  # the probe writes a fresh snapshot
    timeline = [e for e in gui.state()["timeline"] if e["t"] > start]
    samples = pairs(timeline)
    legs = {}
    key = None
    for e in timeline:
        if e["event"] == "terminal-key":
            key, seen = e["t"], set()
        elif key is not None and e["event"].startswith("terminal-") and e["event"] not in seen:
            seen.add(e["event"])
            legs.setdefault(e["event"], []).append(e["t"] - key)
            if e["event"] == "terminal-echo":
                key = None
    drawn = [d - k for k, _, d in samples]
    received = [r - k for k, r, _ in samples if r is not None]
    median, p90 = stats(drawn)
    rmedian, rp90 = stats(received)
    budget = int(os.environ.get("EXOSUIT_ECHO_BUDGET", "200"))
    ok = len(samples) >= count * 0.8 and median is not None and median <= budget
    gui.results.append({"check": "keystroke -> echo on screen (median %s ms, p90 %s ms, budget %d)" % (median, p90, budget),
                        "ok": ok, "samples": len(samples), "typed": count, "median_ms": median, "p90_ms": p90,
                        "drawn_ms": drawn, "received_median_ms": rmedian, "received_p90_ms": rp90, "received_ms": received,
                        "legs_median_ms": {name: stats(values)[0] for name, values in legs.items()}})
    print("%s keystroke -> echo on screen: median %s ms p90 %s ms (%d samples) | received: median %s p90 %s | %s"
          % ("PASS" if ok else "FAIL", median, p90, len(samples), rmedian, rp90, drawn), flush=True)
    print("legs (median ms after the key): %s" % {name: stats(values)[0] for name, values in legs.items()}, flush=True)
    gui._save()


if __name__ == "__main__":
    if "real_input" in inspect.signature(main).parameters:
        main(run, real_input=True)
    else:
        main(run)
