"""A terminal survives the editor and its workspace service. An editor (A) opens the workspace Alpha, makes a terminal
and types a loop into it that prints a line and appends to a file every two seconds. A is closed (exosuit.quit, as closing it does), and the
workspace service is stopped with a stop request (what exohost's Stop and Quit send). The loop must keep running. A new
editor (R) is started on the same state: the terminal must be listed as running, its tab must show lines the loop printed
while no service ran, and the loop must still be the same process.

The run's own editor window stays open and idle with no workspace open, because the harness ends the scenario when that
process exits; A and R are processes the scenario starts.

Real input only. Everything started here is stopped at the end: the second editor, the service and the terminal host."""
import glob
import json
import os
import re
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from gui_driver import Gui
from m19_folders import open_by_double_click
from m19_sessions_drag import new_terminal
from m19_two_windows_restart import close_window, command_line
from sweep_common import running_services, stop_services

FIXTURE = {"workspaces": ["alpha"], "open": None, "appArgs": ["--open-workbench"]}


def terminal_text(state):
    return "\n".join(line for p in state["panes"] for t in p["tabs"] if t["kind"] == "terminal" for line in t.get("lines", []))


def ticks(path):
    """(pid, count) pairs the loop appended; PowerShell 7 writes UTF-8."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            found = [re.findall(r"\d+", line) for line in f]
        return [(int(p[0]), int(p[1])) for p in found if len(p) == 2]
    except OSError:
        return []


def alive(pid):
    out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True, creationflags=0x08000000).stdout
    return str(pid) in out


def run(gui):
    out_dir = os.path.dirname(gui.out)
    state_dir = os.path.join(out_dir, "agent-state")
    tick_file = os.path.join(out_dir, "ticks.txt")
    started = []
    host_pids = []

    def endpoints():
        """The workspace services of the run that still run."""
        return running_services(state_dir)

    def hosts():
        found = []
        for path in glob.glob(os.path.join(state_dir, "workspaces", "*", "terminal-hosts", "*", "host.json")):
            try:
                found.append(json.load(open(path))["pid"])
            except (OSError, ValueError, KeyError):
                pass
        return found


    def editor(name, arguments):
        """Starts an editor process on the run's state, as m19_two_windows_restart does; returns its Gui."""
        program = next(x for x in arguments if x.lower().endswith(".hl"))
        root = os.path.abspath(os.path.join(os.path.dirname(program), "..", "..", ".."))
        env = dict(os.environ)
        native = os.path.join(os.path.dirname(program), "native")
        libraries = [os.path.join(native, d) for d in sorted(os.listdir(native))] if os.path.isdir(native) else []
        libraries.append(os.path.dirname(arguments[0]))
        env["PATH"] = os.pathsep.join(libraries + [env.get("PATH", "")])
        os.makedirs(gui.out, exist_ok=True)
        log = open(os.path.join(gui.out, name + ".log"), "w")
        log.write(" ".join(arguments) + chr(10)); log.flush()
        process = subprocess.Popen(arguments, env=env, cwd=root, stdout=log, stderr=subprocess.STDOUT, creationflags=0x08000000)
        started.append(process.pid)
        return Gui(process.pid, os.path.join(gui.out, "window-" + name), max(10, gui.deadline - time.monotonic()), 30)

    def record(window):
        gui.results.extend(window.results)
        window.results = []

    try:
        gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and gui.find(s, pattern="^w:"), 60)
        alpha = ws(gui.state(), "Alpha")["id"]
        launch = [x for x in command_line(gui.pid) if not x.startswith("--context=")]
        a = editor("a", launch)
        a.wait("workspace rows in A", lambda s: len(s["state"]["machineWorkspaces"]) == 1 and a.find(s, pattern="^w:"), 40)
        open_by_double_click(a, alpha, "Alpha")
        show_workbench(a)

        gui.step("a terminal with a loop that never ends")
        terminal = new_terminal(a, "w:" + alpha)
        a.check("the terminal has a tab", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 10)
        time.sleep(2.5)  # the shell's prompt
        a.type_text('$n=0;for(;;){"TICK $PID $n";"$PID $n">>%s;$n++;sleep 2}' % tick_file, delay=0.02)
        a.chord("enter")
        a.check("the loop runs", lambda s: len(ticks(tick_file)) >= 2, 20, detail=lambda s: terminal_text(s["state"])[-400:])
        shell = ticks(tick_file)[0][0]
        a.check("the editor shows the loop's lines", lambda s: ("TICK %d " % shell) in terminal_text(s["state"]), 10,
                  detail=lambda s: terminal_text(s["state"])[-400:])
        host_pids.extend(hosts())
        a.check("the terminal runs in one terminal host", lambda s: len(host_pids) == 1 and alive(host_pids[0]), 2, detail=lambda s: host_pids)
        a.shot_window("1-before-close")

        gui.step("close the editor, then stop the workspace service (exohost's stop over its link, as exohost's Quit sends)")
        closed = close_window(a, a.pid)
        record(a)
        gui.results.append({"check": "editor A closed", "ok": closed, "note": ""})
        stop_services(out_dir, state_dir)
        end = time.monotonic() + 15
        while endpoints() and time.monotonic() < end:
            time.sleep(0.2)
        stopped = not endpoints()
        gui.results.append({"check": "the workspace service stopped", "ok": stopped, "note": ""})
        at_stop = ticks(tick_file)[-1][1]
        time.sleep(5)
        after = ticks(tick_file)
        gui.results.append({"check": "with no editor and no service, the loop keeps running (same pid %d)" % shell,
                            "ok": after[-1][1] >= at_stop + 2 and all(pid == shell for pid, _ in after) and alive(shell),
                            "note": "count %d at the stop, %d five seconds later" % (at_stop, after[-1][1])})

        gui.step("start an editor again on the same state")
        gui.results.append({"check": "the idle editor window did not bring the service back", "ok": not endpoints(), "note": ""})
        r = editor("r", launch)
        r.wait("the new editor attached to Alpha", lambda s: is_attached(s["state"], alpha), 40)
        r.check("the terminal is listed as running", lambda s: any(t["id"] == terminal and t["state"] == "running" for t in s["state"]["terminals"]), 20,
                detail=lambda s: s["state"]["terminals"])
        if not any(t["kind"] == "terminal" for p in r.state()["panes"] for t in p["tabs"]):
            show_workbench(r)
            r.click(r.element(open_row(r, "t", terminal)))
        r.check("the terminal has its tab", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 10)
        gap = "TICK %d %d" % (shell, at_stop + 1)
        r.check("the tab shows a line printed while no service ran (%s)" % gap, lambda s: gap in terminal_text(s["state"]), 15,
                detail=lambda s: terminal_text(s["state"])[-600:])
        seen = ticks(tick_file)[-1][1]
        r.check("new lines arrive in the tab", lambda s: ("TICK %d %d" % (shell, seen + 2)) in terminal_text(s["state"]), 15,
                detail=lambda s: terminal_text(s["state"])[-300:])
        r.check("still the same process and the same host", lambda s: alive(shell) and hosts() == host_pids and all(pid == shell for pid, _ in ticks(tick_file)), 2,
                detail=lambda s: (hosts(), host_pids))
        r.shot_window("2-after-restart")
        record(r)
    finally:
        for window in (locals().get("a"), locals().get("r")):
            if window is not None:
                record(window)
        for pid in started:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
        stop_services(out_dir, state_dir)
        for pid in set(host_pids + hosts()):
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)


if __name__ == "__main__":
    main(run)
