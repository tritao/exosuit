"""Entropy Steps 5-7: one process per workspace, the warm spare, links kept across switches. Real input throughout.

  open idle   Beta is idle; a double click opens it. Measured from the open-workspace mark to "Workspace connected" in the
              editor's own ConnectTimeline (the Step 0 mark for idle -> connected).
  terminal    New Terminal on Gamma's row while Gamma is idle: click -> tab, and keystroke -> echo of a marker typed as
              soon as the terminal is attached (to the middle of the state read that shows it; a read takes 0.1-0.2 s,
              so this one is coarse). With the shell up, keystroke -> echo comes from the terminal's own timeline marks
              (terminal-key -> terminal-echo, the frame that shows it), with no state read while it waits.
  switch      Alpha <-> Beta, both running, three times: the status never reads "connecting" (a switch is a focus change).
  services    exohost's `machine` lists one process per running workspace (read by the driver from exohost's CLI when
              EXOSUIT_ENTROPY_EXOHOST names the exohost bytecode).
  snapshot    Gamma's service stops; a second window shows Gamma's rows from its snapshot without a link to it. (The
              first window has Gamma's terminal open, so it starts Gamma again by design.)

Results go to results.json (checks named 'time ...' carry the measured milliseconds)."""
import json
import os
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403
from m19_two_windows_restart import command_line
from gui_driver import Gui

FIXTURE = {"workspaces": ["alpha", "beta", "gamma"], "open": "alpha", "appArgs": ["--open-workbench"]}


def after(timeline, start, test):
    for index in range(start, len(timeline)):
        if test(timeline[index]):
            return index
    return None


def terminal_text(state, terminal=None):
    return "\n".join(line for p in state["panes"] for t in p["tabs"] if t["kind"] == "terminal"
                     for line in t.get("lines", []))


def echo_ms(gui, text, timeout=10.0):
    """Types `text` and returns the milliseconds from when the window took it until the read of the window's state that
    shows its echo, counted to the middle of that read: a read of the whole state takes 0.1-0.2 s, as long as the echo."""
    gui.call("exosuit.ui.type", {"text": text})
    typed = time.monotonic()
    while time.monotonic() - typed < timeout:
        asked = time.monotonic()
        if text in terminal_text(gui.state()):
            return int(((asked + time.monotonic()) / 2 - typed) * 1000)
    return None


def echo_marks_ms(gui, text):
    """Types `text` and returns the milliseconds from the terminal's "terminal-key" mark (its first key reached the
    terminal) to its "terminal-echo" mark (the first frame drawn with output after it), as terminal_echo.py times them.
    Nothing reads the state while the echo is on its way: a read holds the UI thread for 0.1-0.2 s."""
    before = gui.state()["timeline"]
    start = before[-1]["t"] if before else -1
    gui.call("exosuit.ui.type", {"text": text})
    time.sleep(1.0)
    state = gui.state()
    if text not in terminal_text(state):
        return None
    timeline = [e for e in state["timeline"] if e["t"] > start]
    key = after(timeline, 0, lambda e: e["event"] == "terminal-key")
    echo = None if key is None else after(timeline, key, lambda e: e["event"] == "terminal-echo")
    return None if echo is None else timeline[echo]["t"] - timeline[key]["t"]


def record(gui, name, ms, budget):
    ok = ms is not None and ms <= budget
    gui.results.append({"check": "time " + name, "ok": ok, "ms": ms, "budget_ms": budget})
    print("%s time %s: %s ms (budget %s)" % ("PASS" if ok else "FAIL", name, ms, budget), flush=True)
    gui._save()


def statuses(gui, start):
    tl = gui.state()["timeline"]
    return [(e["t"], e["workspace"][:8], e["detail"]) for e in tl[start:] if e["event"] == "status"]


class Exohost:
    """The run's isolated exohost, from the driver: its CLI list, its pipe, and second editor windows."""

    def __init__(self, gui):
        self.gui = gui
        self.out = os.path.dirname(gui.out)
        self.launch = [x for x in command_line(gui.pid) if not x.startswith("--context=")]
        self.hl = self.launch[0]
        program = next(x for x in self.launch if x.lower().endswith(".hl"))
        self.root = os.path.abspath(os.path.join(os.path.dirname(program), "..", "..", ".."))
        self.bytecode = os.path.join(self.root, "exohost", "build", "host", "main.hl")
        self.env = dict(os.environ, EXOSUIT_EXOHOST_HOME=os.path.join(self.out, "exohost-home"))
        native = os.path.join(os.path.dirname(self.bytecode), "native")
        self.env["PATH"] = os.pathsep.join([os.path.join(native, d) for d in sorted(os.listdir(native))] + [os.path.dirname(self.hl), self.env.get("PATH", "")])
        self.started = []

    def services(self):
        """exohost's workspace processes as (kind, pid, workspace); raises when `exohost list` fails, so no check reads a failed
        listing as an empty one."""
        result = subprocess.run([self.hl, self.bytecode, "list", "--json"], env=self.env, capture_output=True, text=True,
                                timeout=30, creationflags=0x08000000)
        if result.returncode != 0:
            raise RuntimeError("exohost list failed (exit %d): %s" % (result.returncode, (result.stderr or result.stdout)[-500:]))
        listed = json.loads(result.stdout)
        found = []
        def walk(value):
            if isinstance(value, dict):
                if str(value.get("kind", "")).startswith("workspace-"):
                    found.append((value.get("kind"), value.get("pid"), value.get("workspace") or value.get("root")))
                for item in value.values():
                    walk(item)
            elif isinstance(value, list):
                for item in value:
                    walk(item)
        walk(listed)
        return sorted(set(found), key=str)

    def request(self, message):
        endpoint = json.load(open(os.path.join(self.out, "exohost-home", "daemon.json")))["endpoint"]
        data = json.dumps(message).encode()
        with open(endpoint, "r+b", buffering=0) as pipe:
            pipe.write(bytes([72, 77, 80, 75, 1, 0]) + len(data).to_bytes(4, "big") + data)
            header = pipe.read(10)
            return json.loads(pipe.read(int.from_bytes(header[6:10], "big")))

    def editor(self, name):
        """A second editor process on the run's state (as term_survive starts one); its Gui."""
        env = dict(os.environ)
        program = next(x for x in self.launch if x.lower().endswith(".hl"))
        native = os.path.join(os.path.dirname(program), "native")
        libraries = [os.path.join(native, d) for d in sorted(os.listdir(native))] if os.path.isdir(native) else []
        libraries.append(os.path.dirname(self.hl))
        env["PATH"] = os.pathsep.join(libraries + [env.get("PATH", "")])
        log = open(os.path.join(self.gui.out, name + ".log"), "w")
        # --new-window: the run's folder argument would otherwise go to the open window (LaunchForwarding) and this
        # process would exit.
        process = subprocess.Popen(self.launch + ["--new-window"], env=env, cwd=self.root, stdout=log, stderr=subprocess.STDOUT, creationflags=0x08000000)
        self.started.append(process)
        return Gui(process.pid, os.path.join(self.gui.out, "window-" + name), max(10, self.gui.deadline - time.monotonic()), 30)

    def close_editors(self):
        for process in self.started:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)], capture_output=True, creationflags=0x08000000)
        self.started = []


def collapse(gui, row_key):
    """Clicks the chevron of the row `row_key` when it is expanded (as m19_common.expand finds it)."""
    def chevron(s):
        rows = gui.find(s, row_key)
        if not rows:
            return None
        row = rows[0]
        return next((e for e in gui.find(s, pattern="^(Expand|Collapse)$", role="1")
                     if row["y"] <= e["y"] + e["h"] / 2 <= row["y"] + row["h"] and row["x"] <= e["x"] + e["w"] / 2 <= row["x"] + row["w"]), None)
    target = gui.wait("chevron of " + row_key, chevron, 8)
    if target["label"] == "Collapse":
        gui.click(target)


def run(gui):
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 3 and gui.find(s, pattern="^w:"), 60)
    state = gui.state()
    alpha, beta, gamma = (ws(state, n)["id"] for n in ("Alpha", "Beta", "Gamma"))
    attached(gui, "Alpha")
    show_workbench(gui)
    # Let the spare (Step 6) come up after the window linked, as it would in daily use.
    time.sleep(float(os.environ.get("EXOSUIT_ENTROPY_SETTLE", "4")))

    gui.step("open idle: Beta by a double click")
    mark = len(gui.state()["timeline"])
    gui.click(gui.element("w:" + beta), count=2)
    attached(gui, "Beta")
    tl = gui.state()["timeline"]
    opened = after(tl, mark, lambda e: e["event"] == "open-workspace" and e["workspace"] == beta)
    connected = after(tl, mark, lambda e: e["event"] == "status" and e["detail"] == "Workspace connected" and e["workspace"] == beta)
    ready = after(tl, mark, lambda e: e["event"] == "ready" and e["workspace"] == beta)
    reply = after(tl, mark, lambda e: e["event"] == "exohost-reply" and e["detail"].startswith("workspace.open"))
    events = [] if opened is None else ["%d %s %s %s" % (e["t"] - tl[opened]["t"], e["event"], e["workspace"][:8], e["detail"])
                                        for e in tl[opened:(connected or opened) + 1]]
    gui.results.append({"check": "open idle events", "ok": opened is not None and connected is not None, "events": events})
    record(gui, "open idle -> connected", None if opened is None or connected is None else tl[connected]["t"] - tl[opened]["t"],
           int(os.environ.get("EXOSUIT_ENTROPY_OPEN_BUDGET", "1000")))
    if reply is not None:
        gui.results.append({"check": "exohost workspace.open reply", "ok": True, "note": tl[reply]["detail"]})
    if ready is not None and opened is not None:
        gui.results.append({"check": "open idle -> ready", "ok": True, "ms": tl[ready]["t"] - tl[opened]["t"]})

    gui.step("terminal: New Terminal on idle Gamma, then type")
    show_workbench(gui)
    mark = len(gui.state()["timeline"])
    clicked = time.monotonic()
    # The terminal is made in Gamma and opens in a tab here; the window stays on Beta, so Gamma's terminal list is not
    # the window's. The timeline names the terminal the tab opened.
    menu(gui, "w:" + gamma, "New Terminal")
    terminal = gui.wait("a new terminal", lambda s: next((e["detail"] for e in s["state"]["timeline"][mark:] if e["event"] == "terminal-open"), None), 20)
    gui.wait("terminal attached", lambda s: any(e["event"] == "terminal-attached" and terminal in e["detail"] for e in s["state"]["timeline"][mark:]), 20)
    gui.wait("terminal tab", lambda s: any(t["kind"] == "terminal" for p in s["state"]["panes"] for t in p["tabs"]), 10)
    attached_at = time.monotonic()
    marker = "zq%d" % (int(time.time()) % 10000)
    record(gui, "new terminal click -> attached", int((attached_at - clicked) * 1000), 5000)
    record(gui, "keystroke -> echo", echo_ms(gui, marker), 500)
    # The same with the shell up: what the editor, service and terminal host add to a keystroke. The first echo above
    # waits for the shell's own startup (it reads input only once its prompt is up).
    gui.chord("ctrl+c")
    gui.wait("prompt after ctrl+c", lambda s: terminal_text(s["state"]).rstrip().endswith(">"), 10)
    # terminal_echo.py, 2026-11-16: median 125-138 ms, p90 143-160 ms, max 180 ms (110 keys each, before and after the
    # entropy pass); the budget leaves room for one sample.
    record(gui, "keystroke -> echo, shell up", echo_marks_ms(gui, "zr%d" % (int(time.time()) % 10000)), 250)
    gui.chord("ctrl+c")
    gui.shot("terminal")

    gui.step("switch: Alpha <-> Beta, both running")
    show_workbench(gui)
    mark = len(gui.state()["timeline"])
    for name, wid in (("Alpha", alpha), ("Beta", beta), ("Alpha", alpha), ("Beta", beta), ("Alpha", alpha)):
        gui.click(gui.element("w:" + wid), count=2)
        attached(gui, name, 20)
        show_workbench(gui)
    seen = statuses(gui, mark)
    connecting = [s for s in seen if "onnecting" in s[2] or "tarting" in s[2]]
    gui.results.append({"check": "switching between running workspaces never shows connecting", "ok": not connecting,
                        "statuses": seen})
    print("%s switch statuses %s" % ("PASS" if not connecting else "FAIL", seen), flush=True)

    gui.step("services: one process per running workspace (exohost's own list)")
    exohost = Exohost(gui)
    found = exohost.services()
    hosts = [f for f in found if f[0] == "workspace-host"]
    spares = [f for f in found if f[0] == "workspace-spare"]
    gui.results.append({"check": "exohost lists one process per running workspace (Alpha, Beta, Gamma)", "ok": len(hosts) == 3, "note": found})
    gui.results.append({"check": "exohost holds %s spare" % ("one" if os.environ.get("EXOSUIT_EXOHOST_SPARE") != "0" else "no"),
                        "ok": len(spares) == (0 if os.environ.get("EXOSUIT_EXOHOST_SPARE") == "0" else 1), "note": spares})
    print("services:", found, flush=True)

    gui.step("snapshot: Gamma's service stops; a new window shows its rows with nothing started")
    gamma_host = next((f for f in hosts if f[2] and "gamma" in str(f[2]).lower()), None)
    stopped = False
    if gamma_host:
        exohost.request({"op": "service-stop", "pid": gamma_host[1]})
        end = time.monotonic() + 15
        while time.monotonic() < end and not stopped:
            stopped = not [f for f in exohost.services() if f[0] == "workspace-host" and f[1] == gamma_host[1]]
            time.sleep(0.3)
    gui.results.append({"check": "Gamma's service stopped", "ok": stopped, "note": gamma_host})
    if stopped:
        second = exohost.editor("r")
        try:
            second.wait("rows in the second window", lambda s: len(s["state"]["machineWorkspaces"]) == 3 and second.find(s, pattern="^w:"), 40)
            def gamma_rows(s):
                w = next((x for x in s["state"].get("watched", []) if x["workspace"] == gamma), None)
                return w if w and w["hasCatalog"] and w["terminals"] >= 1 and not w["running"] and gamma not in s["state"]["links"] else None
            second.check("Gamma's rows come from its snapshot (a terminal listed, not running, no link)", gamma_rows, 10,
                         detail=lambda s: (next((x for x in s["state"].get("watched", []) if x["workspace"] == gamma), None), s["state"]["links"]))
            show_workbench(second)
            expand(second, "w:" + gamma)
            second.check("Gamma's terminal row is shown", lambda s: second.find(s, pattern="^t:" + gamma + r"\|"), 8)
            second.shot_window("snapshot-rows")
            gui.results.extend(second.results)
            second.results = []
        finally:
            exohost.close_editors()

    if os.environ.get("EXOSUIT_ENTROPY_IDLE") == "1":
        gui.step("idle: Beta collapsed and not shown; its link closes after 30 s, then its service idles out")
        show_workbench(gui)
        state = gui.state()
        if state["openWorkspace"] != alpha:
            gui.click(gui.element("w:" + alpha), count=2)
            attached(gui, "Alpha", 20)
        collapse(gui, "w:" + beta)
        left_at = time.monotonic()
        gui.check("Beta still has a link right after the switch", lambda s: beta in s["state"].get("links", []), 5,
                  detail=lambda s: s["state"].get("links"))
        closed = gui.wait("Beta's link closed", lambda s: beta not in s["state"].get("links", []), 50)
        gui.results.append({"check": "a collapsed workspace the window does not show holds no connection (link closed after %.0f s)"
                            % (time.monotonic() - left_at), "ok": True, "links": gui.state().get("links")})
        idle = float(os.environ.get("EXOSUIT_SERVICE_IDLE_SECONDS", "600"))
        gone_at = None
        end = time.monotonic() + idle + 25
        while time.monotonic() < end:
            if not [f for f in exohost.services() if f[0] == "workspace-host" and f[2] and "beta" in str(f[2]).lower()]:
                gone_at = time.monotonic()
                break
            time.sleep(1)
        gui.results.append({"check": "the unused workspace left exohost's list after its idle time (%.0f s)" % idle, "ok": gone_at is not None,
                            "note": None if gone_at is None else "%.0f s after its link closed" % (gone_at - left_at - 30)})
        print("idle: Beta's service %s" % ("left exohost's list" if gone_at else "still listed"), flush=True)

    with open(os.path.join(gui.out, "timeline.json"), "w") as f:
        json.dump(gui.state()["timeline"], f, indent=1)
    gui.shot("end")


if __name__ == "__main__":
    main(run)
