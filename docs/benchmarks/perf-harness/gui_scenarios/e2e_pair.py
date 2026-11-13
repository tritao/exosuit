"""Local end to end, machine level (M19 Phase 9): the phone (emulator) pairs ONCE with this machine through the REAL
editor's Remote Access panel and is granted workspaces one at a time.

Driven by scripts/e2e-local.ps1, which writes the run's configuration to the file named by EXOSUIT_E2E_CONFIG (relay
origins, adb, the fake agent's environment) and starts the relay, the emulator and the app first. This scenario then:

  1. waits for the editor to attach to workspace Alpha; creates a fake agent session in Alpha and one in Beta
     (Beta's workspace service is started here, the editor stays on Alpha);
  2. opens Remote Access in the editor, points it at the local relay, creates a pairing invitation;
  3. gives the invitation to the phone (debug intent extra) and waits until both show the same 6-digit code;
  4. ticks "I checked both codes", grants the device workspace Alpha only ("Access to Alpha" = All permissions) and
     presses Approve; the phone lists Alpha and not Beta;
  5. the phone opens Alpha, opens its session, sends a prompt and shows the fake reply;
  6. a Claude Code terminal (the fake TUI, tests/workspace-terminals/fake-claude-tui.py) is created in Alpha; the phone
     opens it by tapping, types into it with the soft keyboard and the extra-keys row (asserted in the fake's key log);
     the editor opens the same terminal and its window is captured;
  7. in the editor: Edit workspaces, "Access to Beta" = Read only, Save workspaces; the phone lists Beta without
     pairing again (one pairing code in its log).

Real input drives the editor (measure.ps1 rules: machine-wide mutex, window in front); the phone is driven with adb.
Every step leaves a screenshot of the editor window (PrintWindow) and of the phone in the result folder."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

CONFIG = json.load(open(os.environ["EXOSUIT_E2E_CONFIG"], encoding="utf-8")) if os.environ.get("EXOSUIT_E2E_CONFIG") else {}
FIXTURE = {"workspaces": ["alpha", "beta"], "open": "alpha", "env": CONFIG.get("editorEnv", {})}


def log(text):
    print("e2e: " + text, flush=True)


class Phone:
    def __init__(self, config, out):
        self.adb, self.serial, self.activity, self.out = config["adb"], config["serial"], config["activity"], out
        self.shots = 0

    def run(self, *arguments, timeout=30, binary=False):
        result = subprocess.run([self.adb, "-s", self.serial, *arguments], capture_output=True, timeout=timeout,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return result.stdout if binary else result.stdout.decode("utf-8", "replace")

    def logcat(self):
        return self.run("logcat", "-d", timeout=60)

    def wait_log(self, pattern, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            match = re.search(pattern, self.logcat())
            if match:
                return match.group(0)
            time.sleep(1)
        with open(os.path.join(self.out, "phone-logcat.txt"), "w", encoding="utf-8") as handle:
            handle.write(self.logcat())
        self.shot("failure")
        raise Failure("the phone never logged " + pattern)

    def shot(self, name):
        self.shots += 1
        path = os.path.join(self.out, "phone-%02d-%s.png" % (self.shots, name))
        with open(path, "wb") as handle:
            handle.write(self.run("exec-out", "screencap", "-p", binary=True))
        return path

    def tap(self, x, y):
        self.run("shell", "input", "tap", str(x), str(y))

    # The debug app's automation snapshot (as android/scripts/phone-ui.ps1 reads it): labelled elements in dp.
    def snapshot(self):
        try:
            return json.loads(self.run("shell", "run-as", "com.exosuit.mobile", "cat", "files/automation/snapshot.json"))
        except ValueError:
            return None

    def ensure_reverse(self, port):
        """The phone reaches the relay's TLS front through `adb reverse`; it is lost when the adb server restarts (another job on
        this machine can do that), and the app then shows its machine offline until it is added again."""
        if ("tcp:%s" % port) not in self.run("reverse", "--list"):
            self.run("reverse", "tcp:%s" % port, "tcp:%s" % port)
            log("adb reverse for port %s was gone; added again" % port)

    def ensure_automation(self):
        """The debug app writes the snapshot only when files/automation.on existed at launch (ExosuitActivity), so a
        rig paired without it is relaunched once; it reconnects from its stored credentials. The marker is left in place
        on purpose: the persistent rig needs it for the next step. The rig's keeper removes it when the rig stops
        (Stop-Rig in scripts/e2e-local.ps1), also when a step failed."""
        if self.snapshot():
            return
        self.run("shell", "run-as", "com.exosuit.mobile", "touch", "files/automation.on")
        self.run("shell", "am", "force-stop", "com.exosuit.mobile")
        self.run("shell", "am", "start", "-n", self.activity)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            if self.snapshot():
                return
            time.sleep(0.5)
        self.shot("failure-no-snapshot")
        raise Failure("the phone app wrote no automation snapshot (is it a debug build?)")

    def elements(self, pattern):
        snap = self.snapshot()
        if not snap:
            return [], None
        view = snap.get("viewport") or {}
        found = [e for e in snap.get("elements", []) if re.search(pattern, e.get("label") or "") and e.get("w", 0) > 0
                 and e.get("h", 0) > 0 and e.get("y", 0) < view.get("height", 1e9) and e.get("x", 0) < view.get("width", 1e9)]
        return sorted(found, key=lambda e: (e["y"], e["x"])), snap

    def wait_element(self, pattern, seconds=30):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            found, _ = self.elements(pattern)
            if found:
                return found[0]
            time.sleep(0.5)
        return None

    def tap_element(self, pattern, seconds=30, after=1.5, required=True):
        """Taps the centre of the topmost element whose label matches; False (or Failure) when none appears in time."""
        element = self.wait_element(pattern, seconds)
        if element is None:
            if required:
                self.shot("failure-no-" + re.sub(r"\W+", "-", pattern).strip("-"))
                raise Failure("the phone never showed an element labelled " + pattern)
            return False
        _, snap = self.elements(pattern)
        size = re.search(r"(\d+)x(\d+)", self.run("shell", "wm", "size"))
        scale = int(size.group(1)) / snap["viewport"]["width"]
        self.tap(int((element["x"] + element["w"] / 2) * scale), int((element["y"] + element["h"] / 2) * scale))
        time.sleep(after)
        return True


def phone_url(config, desktop_url):
    """The invitation as the phone dials it: the desktop's plain loopback origin becomes the TLS front's wss origin."""
    http = config["relayOrigin"].replace("http://", "ws://").replace("https://", "wss://")
    secure = config["tlsOrigin"].replace("https://", "wss://")
    if not desktop_url.startswith(http):
        raise Failure("the invitation %r does not start with the relay origin %r" % (desktop_url[:60], http))
    return secure + desktop_url[len(http):]


def create_fake_session(config, workspace_id, folder, name, start=False):
    """Creates a fake agent session through the workspace service (the same admin tool the test host uses). `start` first
    starts the service (a workspace the editor is not attached to); suit finds it by its state folder."""
    return admin_ensure(config, workspace_id, folder, ["--ensure-session", name], start, "provider_starting")


def admin_ensure(config, workspace_id, folder, admin_arguments, start=False, retry_on="provider_starting"):
    sys.path.insert(0, os.path.join(config["root"], "scripts"))
    from agent_test_runtime import manager_environment, runtime_paths
    root = Path(config["root"])
    runtime, bytecode = runtime_paths(root)
    env = manager_environment(root)
    env.update(config["editorEnv"])

    def hl(*arguments, program=None, timeout=90):
        return subprocess.run([str(runtime), str(program or bytecode), *arguments], env=env, cwd=folder, capture_output=True, text=True,
                              timeout=timeout, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if start:
        started = hl("--manager", "--workspace", workspace_id, "--folder", folder, "--detach", "--idle-seconds", "3000")
        if started.returncode != 0:
            raise Failure("starting the service failed (%s): %s%s" % (started.returncode, started.stderr, started.stdout))
    deadline = time.monotonic() + 60
    while True:  # the editor starts the service when it attaches; discovery answers 4 until the endpoint exists
        found = hl("--manager", "--workspace", workspace_id, "--discover")
        if found.returncode == 0 and found.stdout.strip():
            break
        if time.monotonic() > deadline:
            raise Failure("discover failed (%s): %s%s" % (found.returncode, found.stderr, found.stdout))
        time.sleep(1)
    socket = json.loads(found.stdout)["socket"]
    admin = config["admin"]
    deadline = time.monotonic() + 90
    while True:
        ensured = hl("--socket", socket, *admin_arguments, program=admin)
        if ensured.returncode == 0:
            return json.loads(ensured.stdout.strip().splitlines()[-1])
        if time.monotonic() > deadline or retry_on not in ensured.stderr:
            raise Failure("%s failed: %s%s" % (admin_arguments[0], ensured.stderr, ensured.stdout))
        time.sleep(2)


# Somewhere over the side panel (logical pixels), for the mouse wheel.
PANEL = {"x": 70, "y": 300, "w": 190, "h": 200}


def scroll_to(gui, label):
    """Scrolls the Remote Access panel until the element is on screen and clear of the status bar at the bottom (a
    button whose centre is under the status bar takes no click)."""
    def clear(snapshot, e):
        return gui.on_screen(snapshot, e) and e["y"] + e["h"] <= snapshot["viewport"]["height"] - 40
    for _ in range(10):
        snapshot = gui.snapshot()
        if [e for e in gui.find(snapshot, label) if clear(snapshot, e)]:
            return
        gui.scroll(PANEL, -3)
    raise Failure("could not scroll to " + label)


def choose(gui, label, option):
    """Picks `option` in the drop-down whose accessibility label is `label`."""
    scroll_to(gui, label)
    gui.click(gui.element(label))
    time.sleep(0.5)

    def visible(snapshot):
        return [e for e in gui.find(snapshot, pattern="^" + option + "$") if gui.on_screen(snapshot, e)]
    snapshot = gui.snapshot()
    if not visible(snapshot):
        with open(os.path.join(gui.out, "select-elements.json"), "w") as handle:
            json.dump([e["label"] for e in snapshot["elements"]], handle, indent=1)
        raise Failure("the option %r is not on screen after opening %r" % (option, label))
    gui.click(visible(snapshot)[-1])
    time.sleep(0.5)


STEPS = ["pair", "session", "terminal", "beta", "takeover", "editor-state", "hold", "coldstart", "recontrol", "keyboard", "restart-editor"]
RIG = os.path.dirname(CONFIG["screens"]) if CONFIG.get("screens") else ""


def geometry(phone):
    size = re.search(r"(\d+)x(\d+)", phone.run("shell", "wm", "size"))
    density = int(re.search(r"(\d+)", phone.run("shell", "wm", "density").split(":")[-1]).group(1))
    return int(size.group(1)), int(size.group(2)), density


def paired_record():
    try:
        return json.load(open(os.path.join(RIG, "paired.json"), encoding="utf-8"))
    except (OSError, ValueError):
        return None


def open_alpha(gui, ctx):
    """Precondition of the steps that work inside Alpha on the phone: the app in front, the Remote list, Alpha opened from it."""
    phone, config = ctx["phone"], ctx["config"]
    width, height, _ = geometry(phone)
    phone.ensure_reverse(config["tlsPort"])
    phone.run("shell", "am", "start", "-n", phone.activity)
    time.sleep(1)
    phone.ensure_automation()
    # The app logs "online" only when the machine's state changes, and an earlier step may have cleared the log, so the
    # Remote list itself is the signal: an open workspace hides it until the Remote panel is chosen.
    if phone.wait_element(r"^Alpha .*sessions", 5) is None:
        phone.tap_element(r"^Remote$", 60, after=2)
    if phone.wait_element(r"^Alpha ", 60) is None:  # the machine is online and lists Alpha
        phone.shot("failure-no-alpha")
        raise Failure("the phone's Remote list never showed Alpha")
    phone.tap_element(r"^Alpha ", 30, after=0)  # a no-op when Alpha is already the open workspace
    end = time.monotonic() + 60
    while time.monotonic() < end:  # the app's own state says when the workspace is connected (the log line is only written once)
        opened = (((phone.snapshot() or {}).get("state") or {}).get("phone") or {}).get("open") or {}
        if opened.get("id") == ctx["alpha"] and opened.get("connected"):
            break
        time.sleep(0.5)
    else:
        phone.shot("failure-alpha-not-connected")
        raise Failure("Alpha never showed as open and connected on the phone")
    time.sleep(4)


def step_pair(gui, ctx):
    """The one-time pairing (skipped when the rig is already paired and the editor lists the phone as connected)."""
    phone, config, alpha = ctx["phone"], ctx["config"], ctx["alpha"]
    record = paired_record()
    if record and not ctx.get("force_pair"):
        if gui.state().get("remoteAccess") is None:
            gui.click(gui.element("Remote Access"))
            gui.wait("the Remote Access panel", lambda s: s["state"].get("remoteAccess") is not None, 20)
        time.sleep(1)
        state = gui.state()["remoteAccess"]
        if any(d["deviceId"] == record["device"] for d in (state.get("devices") or [])):
            log("already paired (device %s); the pairing is kept, nothing to do" % record["device"])
            return
        raise Failure("paired.json names device %s but the editor does not list it; run e2e-local.ps1 reset and pair again" % record["device"])
    gui.step("open Remote Access in the editor")
    gui.click(gui.element("Remote Access"))
    gui.wait("the Remote Access panel", lambda s: s["state"].get("remoteAccess") is not None, 20)
    gui.wait("the panel is the machine's", lambda s: s["state"]["remoteAccess"].get("machine"), 30)
    time.sleep(0.5)
    gui.shot_window("editor-1-remote-access")
    with open(os.path.join(gui.out, "remote-access-elements.json"), "w") as handle:
        json.dump([e["label"] for e in gui.snapshot()["elements"]], handle, indent=1)

    gui.step("enable remote access with the local relay")
    state = gui.state()["remoteAccess"]
    if not (state["relay"] or {}).get("configured"):
        # The relay comes from the saved setting `remote/access/relay_url` (settings.json in the isolated state folder, picked up
        # while the editor runs), not from the built-in default and not from typing: the field must show it by itself.
        settings = os.path.join(os.environ["PRAGTICAL_PORTABLE"], "settings.json")
        with open(settings, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "values": {"remote/access/relay_url": config["relayOrigin"] + "/"}}, handle)
        gui.wait("the relay field shows the relay URL setting", lambda s: s["state"]["remoteAccess"].get("relayUrl") == config["relayOrigin"], 30)
        gui.shot_window("editor-1b-relay-from-setting")
        gui.click(gui.element(pattern="Enable remote access"))
    gui.wait("the relay is connected", lambda s: (s["state"]["remoteAccess"]["relay"] or {}).get("connected"), 60)
    gui.check("the editor shows the local relay as connected", lambda s: s["state"]["remoteAccess"]["relay"]["origin"] == config["relayOrigin"],
              detail=lambda s: s["state"]["remoteAccess"])
    gui.shot_window("editor-2-relay-connected")

    gui.step("create the pairing invitation")
    gui.click(gui.element(pattern="Create pairing invitation"))
    url = gui.wait("the invitation", lambda s: s["state"]["remoteAccess"]["invitationUrl"], 30)
    log("invitation created for %s" % url.split("?")[0])
    gui.shot_window("editor-3-invitation")
    pairing_url = phone_url(config, url)

    gui.step("give it to the phone")
    # The app takes the pairing_url extra only from a test rig, i.e. when files/automation.on exists.
    phone.ensure_automation()
    phone.run("logcat", "-c")
    phone.run("shell", "am", "start", "-n", phone.activity, "--es", "pairing_url", "'" + pairing_url + "'")
    code = phone.wait_log(r"exosuit-pairing: code [0-9 ]+", 90)
    phone_code = re.sub(r"\D", "", code)
    log("phone shows " + code)
    pending = gui.wait("a request waiting for approval", lambda s: s["state"]["remoteAccess"]["pending"], 30)
    desktop_code = re.sub(r"\D", "", pending[0]["code"])
    gui.check("the desktop and the phone show the same code", lambda s: desktop_code == phone_code, detail=lambda s: [desktop_code, phone_code])
    # The invitation carries the machine key's fingerprint (#mk=); the phone checked it against the key it reached.
    gui.check("the phone found the machine key the invitation names", lambda s: "exosuit-pairing: machine key matches the invitation" in phone.logcat(),
              detail=lambda s: "#mk=" in pairing_url)
    time.sleep(1)
    gui.shot_window("editor-4-code")
    phone.shot("1-code")

    # Either side may act first. EXOSUIT_E2E_PAIR_ORDER=confirm-first (default: the phone confirms, waits EXOSUIT_E2E_ORDER_GAP
    # seconds, default 12, then the owner approves) or approve-first (the owner approves, the phone confirms the same gap
    # later: the default is past the 10 s the machine once allowed after approving).
    order = os.environ.get("EXOSUIT_E2E_PAIR_ORDER", "confirm-first")
    gap = float(os.environ.get("EXOSUIT_E2E_ORDER_GAP", "12"))
    gui.step("pairing order %s: confirm the code on the phone and approve in the editor granting Alpha only" % order)
    # A tap, as a person confirms: the app accepts no intent extra that confirms a code.
    confirm_on_phone = lambda: phone.tap_element(r"The code matches", 30, after=0)
    if order == "confirm-first":
        confirm_on_phone()
        time.sleep(gap)
        phone.shot("1b-code-confirmed-waiting")
    device = pending[0]["deviceId"]
    gui.click(gui.element(pattern="I checked both codes|pairing-confirm"))
    choose(gui, "Access to Alpha", "All permissions")
    gui.shot_window("editor-4b-alpha-chosen")

    def approve_visible(snapshot):
        return [e for e in gui.find(snapshot, "Approve") if gui.on_screen(snapshot, e)]
    for _ in range(8):
        if approve_visible(gui.snapshot()):
            break
        gui.scroll(PANEL, -4)
    gui.click(gui.element("Approve"))
    if order == "approve-first":
        time.sleep(gap)
        phone.shot("1b-approved-waiting-for-confirm")
        confirm_on_phone()
    gui.wait("the device is paired with Alpha", lambda s: [d for d in s["state"]["remoteAccess"]["devices"]
             if d["deviceId"] == device and [w for w in d["workspaces"] if w["workspace"] == alpha]], 30)
    gui.shot_window("editor-5-approved-alpha")

    gui.step("the phone lists Alpha (and not Beta) with its session")
    listed = phone.wait_log(r"exosuit-machine: \S.* online \[Alpha:\w+:[1-9]\]", 90)
    log(listed)
    time.sleep(3)
    phone.shot("2-alpha-listed")
    gui.check("the editor lists the phone as a connected device",
              lambda s: any(d["deviceId"] == device and d["connected"] for d in s["state"]["remoteAccess"]["devices"]),
              timeout=30, detail=lambda s: s["state"]["remoteAccess"]["devices"])
    gui.shot_window("editor-6-device-connected")

    session = ctx["session"]
    with open(os.path.join(RIG, "paired.json"), "w") as handle:
        json.dump({"alpha": alpha, "beta": ctx["beta"], "device": device, "session": session, "phoneCode": phone_code}, handle)


def step_session(gui, ctx):
    """Open Alpha by tapping its row in the Remote list, open its session and send a prompt: every tap is by label from the
    phone's automation snapshot (no pixel positions), and the fake agent's reply is asserted."""
    phone, config, alpha = ctx["phone"], ctx["config"], ctx["alpha"]
    open_alpha(gui, ctx)
    phone.shot("3-alpha-open")
    phone.tap_element(r"^Workbench$", 30, after=2)  # the Workbench in the rail: Alpha's sessions and terminals
    phone.tap_element(r"^%s" % re.escape(config.get("sessionName", "Fake session")), 30, after=6)  # the session row
    phone.shot("4-session-open")
    prompt = "%s %d" % (CONFIG.get("prompt", "hello from the phone"), int(time.time()) % 100000)  # unique: an old reply must not pass
    phone.tap_element(r"^Codex prompt$", 30, after=2)  # the composer
    phone.run("shell", "input", "text", prompt.replace(" ", "%s"))
    time.sleep(2)
    phone.shot("5-composer")
    phone.tap_element(r"^Send$", 15, after=2)
    reply = phone.wait_element(r"FAKE-REPLY: " + re.escape(prompt), 40)
    phone.shot("6-reply")
    if reply is None:
        raise Failure("the phone never showed the fake agent's reply to " + prompt)
    log("the phone shows the reply: FAKE-REPLY: " + prompt)
    gui.shot_window("editor-7-after-prompt")


def step_terminal(gui, ctx):
    phone, config, alpha, fixture = ctx["phone"], ctx["config"], ctx["alpha"], ctx["fixture"]
    open_alpha(gui, ctx)
    width, height, density = geometry(phone)
    fake_log = config.get("fakeClaudeLog")
    created = admin_ensure(config, alpha, os.path.join(fixture, "alpha"), ["--ensure-terminal", "E2E Claude Code", "--provider", "claude"],
                           retry_on="terminal_starting")
    log("terminal %s created in Alpha (%s)" % (created.get("id"), created.get("state")))

    def fake_lines():
        return open(fake_log, encoding="utf-8").read().splitlines() if fake_log and os.path.exists(fake_log) else []

    def wait_fake(test, what, seconds=30):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if test(fake_lines()):
                return
            time.sleep(0.5)
        phone.shot("failure-" + what.replace(" ", "-"))
        raise Failure("the fake Claude never showed %s; its log: %s" % (what, fake_lines()))
    def extra_key(pattern, _unused=None):  # an extra-keys row button, tapped by its label
        phone.tap_element(pattern, 10, after=0)

    phone.tap_element(r"^Workbench$", 30, after=3)  # the Workbench in the rail
    phone.shot("8-workbench-terminals")
    phone.tap_element(r"Claude Code", 30, after=8)  # its terminal row: "Claude Code - Terminal"
    phone.shot("9-claude-terminal")
    phone.run("shell", "input", "text", "e2e%sphone")
    time.sleep(2)
    extra_key(r"^(Enter|⏎|Return)$", 1028)
    wait_fake(lambda lines: "KEY ENTER" in lines and "TEXT e" in lines and "TEXT p" in lines, "the typed text and Enter")
    for pattern, x, name in ((r"^↑$", 751, "UP"), (r"^S-Tab$", 381, "SHIFT_TAB"), (r"^Esc$", 197, "ESC")):
        before = len(fake_lines())
        extra_key(pattern, x)
        wait_fake(lambda lines: ("KEY " + name) in lines[before:], "extra key " + name, 15)
    time.sleep(2)
    phone.shot("10-claude-keys")
    gui.click(gui.element("Workbench"))  # the activity bar: the editor shows the Remote Access panel until now
    time.sleep(2)
    gui.click(gui.element(pattern="Claude Code . Terminal"))  # the same terminal, in the editor's Workbench
    time.sleep(6)
    gui.shot_window("editor-7b-claude-terminal")



def step_beta(gui, ctx):
    phone, config, alpha, beta, session = ctx["phone"], ctx["config"], ctx["alpha"], ctx["beta"], ctx["session"]
    record = paired_record()
    if not record:
        raise Failure("not paired: run e2e-local.ps1 pair first")
    device = record["device"]
    gui.click(gui.element("Remote Access"))
    gui.wait("the Remote Access panel", lambda s: s["state"].get("remoteAccess") is not None, 20)
    time.sleep(1)
    state = gui.state()["remoteAccess"]
    if any(d["deviceId"] == device and len(d["workspaces"]) == 2 for d in (state.get("devices") or [])):
        log("Beta is already granted; nothing to do (e2e-local.ps1 reset starts over)")
        return
    width, height, _ = geometry(phone)
    phone_code = record.get("phoneCode", "")
    phone.ensure_automation()
    phone.run("logcat", "-c")
    if not gui.find(gui.snapshot(), "Save workspaces"):  # a failed earlier run can leave the editor open
        gui.click(gui.element(pattern="^Edit workspaces|pairing-edit-grants"))
    choose(gui, "Access to Beta", "Read only")
    gui.shot_window("editor-8-beta-chosen")
    scroll_to(gui, "Save workspaces")
    gui.click(gui.element("Save workspaces"))
    gui.wait("the device has Alpha and Beta", lambda s: [d for d in s["state"]["remoteAccess"]["devices"]
             if d["deviceId"] == device and len(d["workspaces"]) == 2], 30)
    phone.wait_log(r"exosuit-machine: \S.* online \[Alpha:\w+:[0-9-]+,Beta:\w+:[1-9]\]", 90)
    time.sleep(3)
    phone.tap_element(r"^Remote$", 30, after=2)  # the Remote panel: the open workspace hides the list
    phone.wait_element(r"^Beta ", 30)
    phone.shot("7-beta-listed")
    gui.shot_window("editor-9-beta-granted")
    if "exosuit-pairing: code" in phone.logcat():
        raise Failure("the phone asked for a pairing code again")




def editor_control(gui):
    """What the editor's terminal pane says about control (state.terminalControl)."""
    return gui.state().get("terminalControl")


def step_takeover(gui, ctx):
    """The editor opens the Claude terminal the phone controls, so it takes control: the phone must show the Read only strip."""
    gui.click(gui.element("Workbench"))
    time.sleep(2)
    gui.click(gui.element(pattern="Claude Code . Terminal"))
    time.sleep(2)  # the editor opens it as an observer: the phone controls it
    gui.click(gui.element(pattern="^Take control$"))
    stamp = time.time()
    log("takeover at %.3f" % stamp)
    time.sleep(4)
    log("editor terminal control: %r" % (editor_control(gui),))
    gui.shot_window("editor-takeover")


def step_editor_state(gui, ctx):
    """Reports and saves the editor's terminal control state: after the phone takes control back it must be read only."""
    log("editor terminal control: %r" % (editor_control(gui),))
    gui.shot_window("editor-after-phone-take")


def step_hold(gui, ctx):
    """A second client (the admin tool, a stand-in for another desktop) attaches to the Claude terminal and takes control for 15 s."""
    log("hold at %.3f" % time.time())
    held = admin_ensure(ctx["config"], ctx["alpha"], os.path.join(ctx["fixture"], "alpha"),
                        ["--hold-control", "E2E Claude Code", "--hold-seconds", "15", "--columns", "120", "--rows", "30"], retry_on="terminal_starting")
    log("held: %r" % (held,))

PACKAGE = "com.exosuit.mobile"


def keyboard_shown(phone):
    return "mInputShown=true" in phone.run("shell", "dumpsys", "input_method")


def fake_key_lines(config):
    log_path = config.get("fakeClaudeLog")
    return open(log_path, encoding="utf-8").read().splitlines() if log_path and os.path.exists(log_path) else []


def step_coldstart(gui, ctx):
    """Cold start reopens the last view. Precondition: the phone shows the Claude terminal (run the terminal step first). The app
    process is killed and started again; the terminal view must come back by itself (its extra-keys row is on screen)."""
    phone, config = ctx["phone"], ctx["config"]
    phone.ensure_automation()
    if phone.wait_element(r"^S-Tab$", 10) is None:
        phone.shot("failure-no-terminal-before-kill")
        raise Failure("the phone does not show the Claude terminal; run the terminal step first")
    phone.shot("cs-1-terminal-before-kill")
    phone.run("shell", "am", "force-stop", PACKAGE)
    phone.run("shell", "run-as", PACKAGE, "rm", "-f", "files/automation/snapshot.json")   # a stale snapshot would pass for the new process
    time.sleep(2)
    started = time.monotonic()
    phone.run("shell", "am", "start", "-n", phone.activity)
    if phone.wait_element(r"^S-Tab$", 90) is None:
        phone.shot("failure-cold-start-not-reopened")
        raise Failure("after the app was killed and started, the Claude terminal did not reopen by itself")
    log("terminal view back %.1f s after the start" % (time.monotonic() - started))
    time.sleep(3)
    phone.shot("cs-2-terminal-reopened")
    log("cold start reopened the Claude terminal by itself")


def step_recontrol(gui, ctx):
    """A phone that held control of the terminal asks before taking it back after the app was killed. Precondition: the phone
    shows the Claude terminal and controls it. Kills and starts the app. When another client (the editor) took the freed lease,
    the phone must come back read only with the question (Take control / Not now) and must not have taken control by itself;
    Take control then gives it back. When nobody took the lease the phone controls at once and there is no strip. Either
    way an extra key must reach the fake TUI at the end."""
    phone, config = ctx["phone"], ctx["config"]
    phone.ensure_automation()
    if phone.wait_element(r"^S-Tab$", 10) is None or phone.elements(r"^Take control$")[0]:
        phone.shot("failure-precondition")
        raise Failure("precondition: the phone must show the Claude terminal and control it")
    phone.shot("rc-1-controlling-before-kill")
    phone.run("shell", "am", "force-stop", PACKAGE)
    phone.run("shell", "run-as", PACKAGE, "rm", "-f", "files/automation/snapshot.json")
    time.sleep(2)
    phone.run("shell", "am", "start", "-n", phone.activity)
    if phone.wait_element(r"^S-Tab$", 90) is None:
        phone.shot("failure-terminal-not-reopened")
        raise Failure("the terminal did not reopen after the kill")
    time.sleep(3)
    phone.shot("rc-2-after-kill")
    if phone.elements(r"^Take control$")[0]:
        if not phone.elements(r"^Not now$")[0]:
            phone.shot("failure-observer-without-question")
            raise Failure("the phone came back as an observer without the Take control back? question (no Not now button)")
        # The question must stay until it is answered: nothing takes control meanwhile.
        time.sleep(5)
        if not phone.elements(r"^Not now$")[0]:
            phone.shot("failure-question-went-away")
            raise Failure("the Take control back? question went away without an answer")
        log("the phone came back read only and asks before taking control back")
        phone.tap_element(r"^Take control$", 10, after=1)
        end = time.monotonic() + 10
        while time.monotonic() < end and phone.elements(r"^Take control$")[0]:
            time.sleep(0.5)
        phone.shot("rc-3-after-take-control")
        if phone.elements(r"^Take control$")[0]:
            raise Failure("the strip did not go away within 10 s of Take control")
    else:
        log("nobody took the lease while the phone was gone: it controls the terminal again without a question")
    before = len(fake_key_lines(config))
    phone.tap_element(r"^↑$", 10, after=0)
    end = time.monotonic() + 15
    while time.monotonic() < end and "KEY UP" not in fake_key_lines(config)[before:]:
        time.sleep(0.5)
    phone.shot("cs-3-after-up-key")
    if "KEY UP" not in fake_key_lines(config)[before:]:
        raise Failure("the extra key did not reach the terminal: the phone does not hold control")
    log("the phone holds control again after the kill (KEY UP reached the fake TUI)")


def step_keyboard(gui, ctx):
    """The soft keyboard closes when the terminal view closes. Opens the Claude terminal from the Workbench (the keyboard comes
    up with it), then chooses Remote in the rail, which replaces the terminal view; the keyboard must go away."""
    phone = ctx["phone"]
    phone.ensure_automation()
    phone.tap_element(r"^Workbench$", 30, after=2)
    phone.tap_element(r"Claude Code", 30, after=5)
    if phone.wait_element(r"^S-Tab$", 20) is None:
        phone.shot("failure-no-terminal")
        raise Failure("the phone did not open the Claude terminal")
    end = time.monotonic() + 10
    while time.monotonic() < end and not keyboard_shown(phone):
        time.sleep(0.5)
    phone.shot("kb-1-terminal-with-keyboard")
    if not keyboard_shown(phone):
        raise Failure("precondition: the soft keyboard is not up on the terminal view")
    phone.tap_element(r"^Remote$", 10, after=0)   # the rail's Remote entry: the terminal view goes away
    end = time.monotonic() + 8
    while time.monotonic() < end and keyboard_shown(phone):
        time.sleep(0.5)
    time.sleep(1)
    phone.shot("kb-2-terminal-closed")
    if keyboard_shown(phone):
        raise Failure("the soft keyboard stayed open after the terminal view closed")
    log("the soft keyboard closed with the terminal view")


def step_restart_editor(gui, ctx):
    """The editor window is closed and the editor started again (the keeper does it, see Restart-Editor in e2e-local.ps1,
    with WM_CLOSE and no mouse). The phone, paired and showing the Claude terminal (run the `terminal` step first), must come
    back online by itself, list Alpha, and its terminal must still take input. Prints the time from the editor being ready
    to the phone online and to the first key reaching the fake."""
    phone, config = ctx["phone"], ctx["config"]
    fake_log = config.get("fakeClaudeLog")

    def fake_lines():
        return open(fake_log, encoding="utf-8").read().splitlines() if fake_log and os.path.exists(fake_log) else []

    def wait_fake(test, what, seconds=60):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if test(fake_lines()):
                return time.time()
            time.sleep(0.25)
        phone.shot("failure-" + what.replace(" ", "-"))
        raise Failure("the fake Claude never showed %s; its log: %s" % (what, fake_lines()[-8:]))

    # Precondition: Alpha open on the phone with the Claude terminal in front (the app does not restore the view after a
    # relaunch, so open it again by label, as the terminal step does).
    admin_ensure(config, ctx["alpha"], os.path.join(ctx["fixture"], "alpha"), ["--ensure-terminal", "E2E Claude Code", "--provider", "claude"],
                 retry_on="terminal_starting")
    phone.run("shell", "am", "start", "-n", phone.activity)
    time.sleep(1)
    phone.ensure_automation()
    if phone.wait_element(r"^(Esc|S-Tab)$", 4) is None:  # not in the terminal yet
        if phone.wait_element(r"^Workbench$", 3) is None:
            open_alpha(gui, ctx)
        phone.tap_element(r"^Workbench$", 30, after=3)
        phone.tap_element(r"Claude Code", 30, after=8)
    # A rig restart ends the terminal's process ("Session ended" with a Restart button at the top right).
    if not phone.tap_element(r"^Restart$", 3, after=6, required=False):
        before_restart = len(fake_lines())
        width, height, _ = geometry(phone)
        phone.tap(967 * width // 1080, 361 * height // 2400)
        time.sleep(6)
        log("tapped Restart by position; the fake started again: %s" % (len(fake_lines()) != before_restart))
    phone.shot("rs-1-before")
    before = len(fake_lines())
    phone.run("shell", "input", "text", "before")
    wait_fake(lambda lines: "TEXT b" in lines[before:], "the text typed before the restart", 45)
    phone.run("logcat", "-c")
    request, answer = os.path.join(RIG, "restart-editor"), os.path.join(RIG, "restart-editor.done")
    if os.path.exists(answer):
        os.remove(answer)
    open(request, "w").write("1")
    end = time.monotonic() + 240
    while not os.path.exists(answer):
        if time.monotonic() > end:
            raise Failure("the keeper never answered the restart request (is the rig up with this script's keeper?)")
        time.sleep(0.5)
    time.sleep(0.3)
    done = json.load(open(answer, encoding="utf-8-sig"))
    if done.get("error"):
        raise Failure("the editor restart failed: " + done["error"])
    ready = done["ready"]
    log("editor closed at %.3f, ready again at %.3f (%.1f s)" % (done["closed"], ready, ready - done["closed"]))
    phone.shot("rs-2-editor-back")
    # Back online by itself: the machine logs "online" again (the log was cleared before the restart).
    # The app logs "online" only when the machine's state changes; a phone that never noticed the close logs nothing, so a
    # missing line is not a failure: the terminal taking input below is the check.
    try:
        phone.wait_log(r"exosuit-machine: \S.* online \[[^\]]+\]", 20)
        log("phone logged online %.1f s after the editor was ready" % (time.time() - ready))
    except Failure:
        log("the phone logged no online change (it may never have noticed the close)")
    online = time.time()
    # The terminal still takes input without any tap on the phone's navigation.
    before = len(fake_lines())
    phone.run("shell", "input", "text", "after")
    typed = wait_fake(lambda lines: "TEXT a" in lines[before:], "the text typed after the restart", 60)
    log("first key reached the fake %.1f s after the editor was ready" % (typed - ready))
    phone.shot("rs-3-after-typed")
    # And the list works: back to the Remote list shows Alpha, which opens again to the same terminal.
    phone.run("shell", "input", "keyevent", "KEYCODE_BACK")
    time.sleep(1.5)
    if phone.wait_element(r"^Alpha ", 3) is None:
        phone.tap_element(r"^Remote$", 20, after=2)
    if phone.wait_element(r"^Alpha ", 30) is None:
        phone.shot("failure-no-alpha-after")
        raise Failure("the phone's Remote list does not show Alpha after the restart")
    phone.shot("rs-4-list")
    phone.tap_element(r"^Alpha ", 30, after=6)
    phone.shot("rs-5-reopened")
    log("restart-resume: online %.1f s, first key %.1f s after the editor was ready" % (online - ready, typed - ready))


def run(gui):
    config = CONFIG
    phone = Phone(config, gui.out)
    alpha = attached(gui, "Alpha")
    beta = ws(gui.state(), "Beta")["id"]
    fixture = os.path.abspath(os.path.join(gui.dir, "..", "fixture"))
    wanted = [s for s in os.environ.get("EXOSUIT_E2E_STEPS", "all").split(",") if s]
    chosen = STEPS if wanted == ["all"] else wanted
    for name in chosen:
        if name not in STEPS:
            raise Failure("unknown step %r; steps: %s" % (name, ", ".join(STEPS)))
    gui.step("fake agent sessions exist in Alpha and Beta (idempotent: ensured by name)")
    session = create_fake_session(config, alpha, os.path.join(fixture, "alpha"), config["sessionName"])
    beta_session = create_fake_session(config, beta, os.path.join(fixture, "beta"), "Beta fake session", start=True)
    log("sessions %s (Alpha) and %s (Beta) ready" % (session.get("id"), beta_session.get("id")))
    ctx = {"phone": phone, "config": config, "alpha": alpha, "beta": beta, "fixture": fixture, "session": session,
           "force_pair": os.environ.get("EXOSUIT_E2E_FORCE_PAIR") == "1"}
    for name in chosen:
        gui.step("step " + name)
        {"pair": step_pair, "session": step_session, "terminal": step_terminal, "beta": step_beta, "takeover": step_takeover, "editor-state": step_editor_state, "hold": step_hold, "coldstart": step_coldstart, "recontrol": step_recontrol, "keyboard": step_keyboard, "restart-editor": step_restart_editor}[name](gui, ctx)
        log("step %s done" % name)


if __name__ == "__main__":
    main(run)
