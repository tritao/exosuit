"""M19 Phase 8: the last window closed wins its group, and a group only the other window touched keeps that window's
tabs. Window 1 stays open on the workspace (it is the run's own editor). It starts two windows on the group Second (A and
B). A opens a1.txt in Second, then goes to the group Third and opens a3.txt there; B opens a2.txt in Second. A is closed
(`exosuit.quit`, as closing the window does), then B. A new editor is started with the same state and no context: it must show a2.txt in Second (B closed
last) and a3.txt in Third (only A touched it). (The scenario uses groups that only its windows touch.)

Every window is driven over exohost's control plane, found by its pid."""
import ctypes
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from gui_driver import Gui
from m19_folders import menu, open_by_double_click
from m19_sessions_drag import create

FIXTURE = {"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"]}


def documents(state):
    return [t["title"].replace("\\", "/").split("/")[-1] for p in state["panes"] for t in p["tabs"] if t["kind"] == "document"]


def wait_exit(pid, seconds):
    """True when the process ended within `seconds`."""
    kernel32 = ctypes.windll.kernel32
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel32.OpenProcess(0x100000, False, int(pid))  # SYNCHRONIZE
    if not handle:
        return True
    try:
        return kernel32.WaitForSingleObject(handle, int(seconds * 1000)) == 0
    finally:
        kernel32.CloseHandle(handle)


def command_line(pid):
    """The argument list of a running process (PowerShell reads it from WMI; no window)."""
    command = "(Get-CimInstance Win32_Process -Filter 'ProcessId=%d').CommandLine" % int(pid)
    out = subprocess.run(["pwsh", "-NoProfile", "-WindowStyle", "Hidden", "-Command", command],
                         capture_output=True, text=True, timeout=30, creationflags=0x08000000).stdout.strip()
    count = ctypes.c_int()
    shell32 = ctypes.windll.shell32
    shell32.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
    argv = shell32.CommandLineToArgvW(out, ctypes.byref(count))
    return [argv[i] for i in range(count.value)]


def enter(window, work, name):
    """The quick switch to a group: focus goes to the tree first (a click on Work), since the editor swallows the chord."""
    window.click(window.element(open_row(window, "g", work)))
    quick_switch(window, name)


def close_window(gui, pid):
    gui.call("exosuit.quit", {"mode": "prompt"}, 30)
    return wait_exit(pid, 20)


def run(gui):
    pids = []
    try:
        out_dir = os.path.dirname(gui.out)
        gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and gui.find(s, pattern="^w:"), 60)
        alpha = ws(gui.state(), "Alpha")["id"]
        open_by_double_click(gui, alpha, "Alpha")
        show_workbench(gui)
        work = ensure_group(gui, alpha)
        create(gui, open_row(gui, "g", work), "New Group", "Second", "groups")
        create(gui, open_row(gui, "g", work), "New Group", "Third", "groups")
        second = next(g["id"] for g in gui.state()["groups"] if g["name"] == "Second")
        third = next(g["id"] for g in gui.state()["groups"] if g["name"] == "Third")
        launch = command_line(gui.pid)

        gui.step("window A and window B on the group Second")
        windows = []
        for index, name in enumerate(("A", "B")):
            gui.focus()
            known = {w["pid"] for w in gui.state()["otherWindows"]}
            reveal(gui, work, second)
            menu(gui, open_row(gui, "g", second), "Open in New Window")
            pid = gui.wait("window %s registered" % name,
                           lambda s: next((w["pid"] for w in s["state"]["otherWindows"] if w["pid"] not in known and w["context"].endswith("/" + second)), None), 60)
            pids.append(pid)
            window = Gui(pid, os.path.join(gui.out, "window" + name), max(10, gui.deadline - time.monotonic()), 30)
            window.wait("window %s attached" % name, lambda s: is_attached(s["state"], alpha), 40)
            windows.append(window)
        a, b = windows

        gui.step("A: a1.txt in Second, then a3.txt in Third")
        a.focus()
        show_workbench(a)
        open_file(a, "a1.txt")
        a.check("A shows a1.txt", lambda s: documents(s["state"]) == ["a1.txt"], 10, detail=lambda s: documents(s["state"]))
        enter(a, work, "Third")
        a.wait("A on Third", lambda s: s["state"]["context"].endswith("/" + third), 10)
        open_file(a, "a3.txt")
        a.check("A shows a3.txt in Third", lambda s: documents(s["state"]) == ["a3.txt"], 10, detail=lambda s: documents(s["state"]))

        gui.step("B: a2.txt in Second")
        b.focus()
        show_workbench(b)
        open_file(b, "a2.txt")
        b.check("B shows a2.txt", lambda s: documents(s["state"]) == ["a2.txt"], 10, detail=lambda s: documents(s["state"]))

        gui.step("close A, then B")
        gui.check("A closed", lambda s: close_window(a, pids[0]), 1)
        pids.remove(pids[0])
        gui.check("B closed", lambda s: close_window(b, pids[0]), 1)
        pids.clear()
        contexts = os.path.join(out_dir, "state", "contexts")
        gui.check("one snapshot file per touched group (Second, Third)", lambda s: os.path.isdir(contexts) and len(os.listdir(contexts)) >= 2, 5,
                  detail=lambda s: os.listdir(contexts) if os.path.isdir(contexts) else "no folder")

        gui.step("restart an editor on the same state")
        arguments = [x for x in launch if not x.startswith("--context=") and x != "--open-workbench"]
        program = next(x for x in arguments if x.lower().endswith(".hl"))
        root = os.path.abspath(os.path.join(os.path.dirname(program), "..", "..", ".."))
        env = dict(os.environ)
        # `haxeon run` gives the editor the native libraries of its build on PATH; do the same (the rule of scripts/exohost.py library_path).
        native = os.path.join(os.path.dirname(program), "native")
        libraries = [os.path.join(native, d) for d in sorted(os.listdir(native))] if os.path.isdir(native) else []
        libraries.append(os.path.dirname(arguments[0]))
        env["PATH"] = os.pathsep.join(libraries + [env.get("PATH", "")])
        os.makedirs(gui.out, exist_ok=True)
        log = open(os.path.join(gui.out, "restart.log"), "w")
        log.write(" ".join(arguments) + "\n"); log.flush()
        process = subprocess.Popen(arguments, env=env, cwd=root, stdout=log, stderr=subprocess.STDOUT, creationflags=0x08000000)
        pids.append(process.pid)
        r = Gui(process.pid, os.path.join(gui.out, "windowR"), max(10, gui.deadline - time.monotonic()), 25)
        r.wait("restarted editor attached", lambda s: is_attached(s["state"], alpha), 40)
        r.check("the restarted editor opens on the group Second (B closed last)", lambda s: s["state"]["context"].endswith("/" + second), 10,
                detail=lambda s: s["state"]["context"])
        r.check("Second shows B's tab: a2.txt", lambda s: documents(s["state"]) == ["a2.txt"], 15, detail=lambda s: documents(s["state"]))
        r.shot("restored-second")
        show_workbench(r)
        enter(r, work, "Third")
        r.check("Third shows A's tab: a3.txt (only A touched it)", lambda s: documents(s["state"]) == ["a3.txt"], 15, detail=lambda s: documents(s["state"]))
        r.shot("restored-third")
    finally:
        for pid in pids:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)


if __name__ == "__main__":
    main(run)
