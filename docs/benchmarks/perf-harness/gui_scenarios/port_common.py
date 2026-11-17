"""What the port-against-baseline scenarios (port_*.py) share: frame traces in the fixture, stage and input marks on the
QueryPerformanceCounter clock, checks over the frames the app rendered, and a clean quit so the allocation census is
written.

Every port scenario runs unchanged against both checkouts (measure.ps1 -Root picks the checkout; the scenario and this
module come from the harness that runs it):

- The fixture adds EXOSUIT_SWITCH_TRACE={result}/switch.txt (an `R <ticks> <context>` line per rendered frame, see
  src/devtools/SwitchTrace.hx) and NK_LATENCY_TRACE={result}/nk.txt.
- PORT_MEASURE=alloc in measure.ps1's environment adds EXOSUIT_ALLOCATION_PROFILE={result}/census.txt: the app starts the
  census after construction, resets it at its 20th frame and writes it when the window closes, which `close_window` below does.
  Timing numbers of such a run are not used.
- PORT_VERIFY=N adds HAXEON_UI_VERIFY_RETENTION=N: every Nth frame is compared with a fresh build and a difference
  throws (the missed-dependency run; the port only).

The driver writes marks.txt next to results.json: `stage <ticks> <name>` where a measured stage starts, `input <ticks>
<what>` just before each input it sends in a stage, `end <ticks> -` after the last stage. port_frames.py reads it with
switch.txt. Inputs go through exohost's control plane (synthetic events in the window's own queue), so input -> frame
includes that hop on both sides alike. Nothing reads the window's state inside a measured stage unless the stage says
so: a snapshot costs the UI thread time and can draw a frame."""
import ctypes
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweep_common import *  # noqa: F401,F403
from gui_driver import Failure, qpc, qpc_frequency  # noqa: E402

TRACES = {"EXOSUIT_SWITCH_TRACE": "{result}/switch.txt", "NK_LATENCY_TRACE": "{result}/nk.txt"}


def port_fixture(base):
    """`base` (a gui_fixture FIXTURE) with the frame traces, and the census or retention check the environment asks for."""
    fixture = dict(base)
    env = dict(base.get("env", {}), **TRACES)
    # The scenario can find the checkout it drives (measure.ps1 puts the fixture's env into its own environment).
    env["PORT_ROOT"] = "{root}"
    if os.environ.get("PORT_MEASURE") == "alloc":
        env["EXOSUIT_ALLOCATION_PROFILE"] = "{result}/census.txt"
    if os.environ.get("PORT_VERIFY"):
        env["HAXEON_UI_VERIFY_RETENTION"] = os.environ["PORT_VERIFY"]
    fixture["env"] = env
    return fixture


def checkout():
    """The checkout this run drives (PORT_ROOT, set through the fixture)."""
    root = os.environ.get("PORT_ROOT")
    if not root:
        raise Failure("PORT_ROOT is not set: run the scenario through measure.ps1 -Drive")
    return root


# ---- marks ------------------------------------------------------------------------------------------------------------
def _marks(gui):
    if not hasattr(gui, "marks"):
        gui.marks = []
        save = gui._save

        def save_with_marks():
            save()
            with open(os.path.join(gui.out, "marks.txt"), "w") as f:
                f.write("# port marks clock=qpc frequency=%d\n" % qpc_frequency())
                for kind, ticks, text in gui.marks:
                    f.write("%s %d %s\n" % (kind, ticks, text))
        gui._save = save_with_marks
    return gui.marks


def begin(gui, name):
    """A measured stage starts now; it lasts until the next stage or `end`."""
    _marks(gui).append(("stage", qpc(), name))
    gui.step("stage " + name)
    gui._save()


def end(gui):
    _marks(gui).append(("end", qpc(), "-"))
    gui._save()


def mark(gui, what):
    _marks(gui).append(("input", qpc(), what.replace("\n", " ")))


def key(gui, chord, pause=0.0):
    mark(gui, "key " + chord)
    gui.call("exosuit.ui.key", {"chord": chord})
    if pause:
        time.sleep(pause)


def type_keys(gui, text, interval=0.12):
    """Types `text` one character per input, each stamped, `interval` seconds apart (a person typing, not a paste)."""
    for ch in text:
        mark(gui, "type " + ch)
        gui.call("exosuit.ui.type", {"text": ch})
        time.sleep(interval)


def hover(gui, element, fx=0.5, fy=0.5):
    mark(gui, "hover " + element["label"][:40])
    gui.hover(element, fx, fy)


def click(gui, element, count=1, button="left", fx=0.5, fy=0.5):
    mark(gui, "click " + element["label"][:40])
    gui.click(element, count, button, fx, fy)


def wheel(gui, x, y, notches):
    """Wheel notches at a point of the window (negative scrolls down)."""
    mark(gui, "wheel %d" % notches)
    gui.call("exosuit.ui.scroll", {"x": x, "y": y, "notches": notches})


def idle(gui, name, seconds):
    """A stage in which nothing is sent and nothing is read."""
    begin(gui, name)
    time.sleep(seconds)


# ---- frames -------------------------------------------------------------------------------------------------------------
def frames(gui):
    """Tick of every frame the app rendered so far (switch.txt in the result folder)."""
    try:
        with open(os.path.join(gui.out, "switch.txt"), encoding="utf-8") as f:
            return [int(parts[1]) for parts in (line.split(" ", 2) for line in f) if len(parts) >= 2 and parts[0] == "R" and parts[1].isdigit()]
    except OSError:
        return []


def stage_span(gui, name):
    """(start, end) ticks of the stage `name` from the marks so far."""
    marks = _marks(gui)
    for index, (kind, ticks, text) in enumerate(marks):
        if kind == "stage" and text == name:
            following = [t for k, t, _ in marks[index + 1:] if k in ("stage", "end")]
            return ticks, following[0] if following else qpc()
    raise Failure("no stage " + name)


def frame_rate(gui, name):
    """Frames per second the app rendered during stage `name`."""
    start, stop = stage_span(gui, name)
    count = sum(1 for t in frames(gui) if start <= t < stop)
    return count / ((stop - start) / qpc_frequency())


def check_rate(gui, name, low, high, what):
    """Records whether stage `name` rendered between `low` and `high` frames per second."""
    rate = frame_rate(gui, name)
    ok = low <= rate <= high
    gui.results.append({"check": "%s: %.2f frames/s in [%g, %g]" % (what, rate, low, high), "ok": ok, "rate": round(rate, 2)})
    print("%s %s: %.2f frames/s (expected %g-%g)" % ("PASS" if ok else "FAIL", what, rate, low, high), flush=True)
    gui._save()
    return ok


def check_traced(gui):
    """The frame trace is being written: without it the run measures nothing."""
    gui.check("the app writes its frame trace (EXOSUIT_SWITCH_TRACE)", lambda s: len(frames(gui)) > 0, 10)


# ---- the end of a run ---------------------------------------------------------------------------------------------------
def _wait_exit(pid, seconds):
    kernel32 = ctypes.windll.kernel32
    kernel32.OpenProcess.restype = ctypes.c_void_p
    handle = kernel32.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
    if not handle:
        return True
    try:
        return kernel32.WaitForSingleObject(ctypes.c_void_p(handle), int(seconds * 1000)) == 0
    finally:
        kernel32.CloseHandle(ctypes.c_void_p(handle))


def close_window(gui, seconds=20):
    """Closes the window as exohost's Quit does (unsaved edits kept for recovery, no prompt) and waits for the process to
    exit, so the census is written before measure.ps1 stops what is left."""
    try:
        gui.call("exosuit.quit", {"mode": "recover"}, 15)
    except Failure as failure:
        gui.results.append({"check": "the window closes on exosuit.quit", "ok": False, "note": str(failure)})
        return
    exited = _wait_exit(gui.pid, seconds)
    gui.results.append({"check": "the window closes on exosuit.quit", "ok": exited})
    if os.environ.get("PORT_MEASURE") == "alloc":
        census = os.path.join(gui.out, "census.txt")
        gui.results.append({"check": "the allocation census is written", "ok": os.path.isfile(census)})
    gui._save()


def label_of(snap, pattern):
    """The first visible label matching `pattern`, or None."""
    rx = re.compile(pattern)
    return next((e["label"] for e in snap["elements"] if rx.search(e["label"])), None)


def run_port(run):
    """main() with a run that records its marks even when it fails half way."""
    def wrapped(gui):
        _marks(gui)
        try:
            run(gui)
        finally:
            if not any(kind == "end" for kind, _, _ in gui.marks):
                end(gui)
    main(wrapped)
