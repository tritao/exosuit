#!/usr/bin/env python3
"""Machine acceptance for the Android app on macOS and Linux (the checks of machine-acceptance.ps1 that need no Windows rig).

  android/scripts/machine-acceptance.py --machine-env ENV.sh --relay-ca ca.pem [--relay-tls https://localhost:18443]
      [--serial emulator-5584] [--workspace NAME] [--out DIR] [--order confirm-first|approve-first]

Drives a running emulator (adb) and an ISOLATED test machine (an exohost with remote access on, behind a local relay):
the machine is reached only through connect-real.py with --machine-env sourced first (the isolated home and credential store);
the owner's real exohost is never touched. The phone is read through the debug app's UI snapshot and logcat, never by pixels.

Asserted (each prints PASS or fails the run; screenshots and element lists go to --out, LOOK at them):
  pair        the phone shows a pairing code; it equals the machine's pending code; the invitation's machine key matched;
              confirm ("The code matches") and approve in either order
  online      the phone lists the machine online; the pairing code was asked for exactly once
  grant       granting a workspace makes it appear on the same channel (no second pairing)
  open        tapping the workspace row opens it (exosuit-open ... connected)
  reconnect   force-stop and start again: reconnects from the stored pairing, no new code
  revoke      the owner takes the workspace back and it leaves the phone's list
Not ported (skipped, they need scripts/mobile-machine-host.py's rig, whose exohost client speaks a Windows named pipe and
whose fake Claude TUI terminal is its own fixture): the Read only / Take control strip, extra keys, Ctrl, Paste,
New Agent Session, a second workspace, and the resume-* steps. The terminal round trip is terminal-roundtrip.py's job.
"""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PACKAGE = "com.exosuit.mobile"
ACTIVITY = f"{PACKAGE}/{PACKAGE}.ExosuitActivity"


def sh(command, **kw):
    return subprocess.run(command, capture_output=True, text=True, **kw)


class Rig:
    def __init__(self, a):
        self.a = a
        self.out = Path(a.out); self.out.mkdir(parents=True, exist_ok=True)
        sdk = os.environ.get("ANDROID_HOME") or os.path.expanduser("~/Library/Application Support/exosuit-android/sdk")
        self.adb = os.path.join(sdk, "platform-tools", "adb")
        self.serial = a.serial
        self.shots = 0

    def adb_(self, *args, timeout=60):
        return sh([self.adb, "-s", self.serial, *args], timeout=timeout)

    def run_as(self, *args):
        return self.adb_("shell", "run-as", PACKAGE, *args)

    def ctl(self, *args):
        """connect-real.py against the isolated machine (--machine-env sourced in a subshell)."""
        script = Path(self.a.connect_real).resolve()
        command = f'source "{self.a.machine_env}" && cd "{script.parent.parent.parent}" && python3 "{script}" ' + " ".join(f"'{x}'" for x in args)
        result = sh(["bash", "-c", command], timeout=90)
        if result.returncode != 0:
            raise SystemExit(f"machine command {args} failed: {result.stderr}{result.stdout}")
        return json.loads(result.stdout.strip().splitlines()[-1])

    def logcat(self):
        return self.adb_("logcat", "-d").stdout

    def wait_log(self, pattern, seconds):
        end = time.time() + seconds
        while time.time() < end:
            m = re.search(pattern, self.logcat())
            if m:
                return m.group(0)
            time.sleep(1)
        raise SystemExit(f"timed out after {seconds} s waiting for /{pattern}/ in logcat")

    def snapshot(self):
        text = self.run_as("cat", "files/automation/snapshot.json").stdout
        try:
            return json.loads(text)
        except ValueError:
            return None

    def elements(self, pattern, role=None):
        s = self.snapshot()
        if not s:
            return []
        found = [e for e in s["elements"] if re.search(pattern, e.get("label") or "") and (role is None or str(e.get("role")) == str(role))
                 and e["w"] > 0 and e["h"] > 0 and e["y"] < s["viewport"]["height"] and e["x"] < s["viewport"]["width"]]
        return sorted(found, key=lambda e: (e["y"], e["x"]))

    def wait_element(self, pattern, seconds=30, role=None):
        end = time.time() + seconds
        while time.time() < end:
            f = self.elements(pattern, role)
            if f:
                return f[0]
            time.sleep(0.7)
        labels = " | ".join(f"{e['role']}:{e['label']}" for e in self.elements("."))
        raise SystemExit(f"timed out waiting for an element /{pattern}/; on screen: {labels}")

    def tap(self, pattern, role=None, after=1.5):
        e = self.wait_element(pattern, role=role)
        size = re.search(r"(\d+)x(\d+)", self.adb_("shell", "wm", "size").stdout)
        scale = float(size.group(1)) / float(self.snapshot()["viewport"]["width"])
        x, y = int((e["x"] + e["w"] / 2) * scale), int((e["y"] + e["h"] / 2) * scale)
        self.adb_("shell", "input", "tap", str(x), str(y))
        time.sleep(after)

    def shot(self, name):
        path = self.out / name
        data = subprocess.run([self.adb, "-s", self.serial, "exec-out", "screencap", "-p"], capture_output=True, timeout=60).stdout
        path.write_bytes(data)
        s = self.snapshot()
        if s:
            path.with_suffix(".txt").write_text("\n".join(f"{e['role']}:{e['label']} {e['x']:.0f},{e['y']:.0f} {e['w']:.0f}x{e['h']:.0f}" for e in s["elements"]))
        print(f"screenshot: {path}")

    def start_app(self, *extras):
        self.adb_("shell", "am", "start", "-n", ACTIVITY, *extras)


def passed(what):
    print(f"PASS {what}", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--machine-env", required=True, help="env.sh that isolates the test machine (sourced before every machine command)")
    p.add_argument("--connect-real", default=str(HERE / "connect-real.py"))
    p.add_argument("--relay-ca", required=True, help="the development CA (public cert); trusted inside the app only, never in a keychain")
    p.add_argument("--relay-tls", default="https://localhost:18443")
    p.add_argument("--relay-plain", default="http://127.0.0.1:18787", help="the invitation's relay origin, replaced by --relay-tls")
    p.add_argument("--serial", default="emulator-5584")
    p.add_argument("--workspace", default="demo", help="workspace (by name) to grant and open")
    p.add_argument("--out", default=str(HERE.parent / "build" / "machine-acceptance"))
    p.add_argument("--order", choices=["confirm-first", "approve-first"], default="confirm-first")
    p.add_argument("--keep-automation", action="store_true")
    a = p.parse_args()
    r = Rig(a)
    port = re.search(r":(\d+)$", a.relay_tls).group(1)

    r.ctl("status")  # fails early when the machine is not reachable

    # Setup: fresh app data, the CA inside the app, automation marker, quiet system UI.
    r.adb_("reverse", f"tcp:{port}", f"tcp:{port}")
    r.adb_("shell", "pm", "clear", PACKAGE)
    r.run_as("mkdir", "-p", "files")
    ca = Path(a.relay_ca).read_text()
    sh([r.adb, "-s", r.serial, "shell", "run-as", PACKAGE, "sh", "-c", "cat > files/dev-ca.pem"], input=ca)
    r.run_as("touch", "files/automation.on")
    for key in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
        r.adb_("shell", "settings", "put", "global", key, "0")
    r.adb_("shell", "settings", "put", "secure", "stylus_handwriting_enabled", "0")
    r.adb_("logcat", "-c")
    try:
        invite = r.ctl("invite")
        url = invite["invitation"]["invitationUrl"].replace(a.relay_plain.replace("http", "ws"), a.relay_tls.replace("https", "wss"), 1)
        device = invite["deviceId"] if "deviceId" in invite else invite["invitation"]["deviceId"]
        r.start_app("--es", "pairing_url", f"'{url}'")
        phone = re.sub(r"\D", "", r.wait_log(r"exosuit-pairing: code [0-9 ]+", 90))
        if "exosuit-pairing: machine key matches the invitation" not in r.logcat():
            raise SystemExit("the phone did not find the invitation's machine key")
        end = time.time() + 60; machine_code = ""
        while time.time() < end and not machine_code:
            time.sleep(1)
            for item in r.ctl("devices").get("pending", []):
                if item["deviceId"] == device:
                    machine_code = re.sub(r"\D", "", str(item["authenticationCode"]))
        print(f"phone code {phone}, machine code {machine_code}")
        if not phone or phone != machine_code:
            raise SystemExit("the phone and the machine show different pairing codes")
        time.sleep(2); r.shot("1-pairing-code.png")
        passed("pair: codes match and the machine key matched the invitation")
        if a.order == "approve-first":
            r.ctl("approve", "--device", device); time.sleep(3); r.tap("The code matches", role=1, after=0)
        else:
            r.tap("The code matches", role=1, after=0); time.sleep(12); r.ctl("approve", "--device", device)
        try:
            r.wait_log(r"exosuit-machine: \S.* online \[\]", 90)
        except SystemExit:
            r.shot("2-NOT-PAIRED.png"); raise
        time.sleep(2); r.shot("2-nothing-granted.png")
        passed("online: the machine is paired and online with nothing granted")

        status = r.ctl("status")
        ids = status.get("workspaces") or []
        wid = None
        for item in ids:
            if a.workspace in (item.get("name"), item.get("id")):
                wid = item["id"]
        if not wid:
            raise SystemExit(f"workspace {a.workspace!r} not found in machine status: {json.dumps(status)[:400]}")
        r.ctl("grant", "--device", device, "--workspace", wid)
        r.wait_log(r"exosuit-machine: \S.* online \[\S+:\w+:[0-9-]+\]", 60)
        time.sleep(2); r.shot("3-granted.png")
        if len(re.findall("exosuit-pairing: code", r.logcat())) != 1:
            raise SystemExit("the phone asked for more than one pairing code")
        passed("grant: the workspace appeared on the same channel; one pairing code only")

        if not r.elements(r"^%s " % re.escape(a.workspace)):
            r.tap("^Remote$|^Machines$", role=1, after=2)
        r.tap(r"^%s " % re.escape(a.workspace), role=1, after=1)
        r.wait_log(r"exosuit-open: \S+ connected", 60); time.sleep(6); r.shot("5-open.png")
        passed("open: the workspace opened and connected")

        r.adb_("shell", "am", "force-stop", PACKAGE); r.adb_("logcat", "-c")
        rules = r.adb_("reverse", "--list").stdout
        if f"tcp:{port}" not in rules:
            r.adb_("reverse", f"tcp:{port}", f"tcp:{port}")
        r.start_app()
        r.wait_log(r"exosuit-machine: \S.* online \[\S+:\w+:[0-9-]+\]", 90); time.sleep(3); r.shot("7-reconnected.png")
        if "exosuit-pairing: code" in r.logcat():
            raise SystemExit("the restarted app asked to pair again")
        passed("reconnect: back online from the stored pairing, no new code")

        r.ctl("grant", "--device", device)  # no workspaces: takes everything back
        r.wait_log(r"exosuit-machine: \S.* online \[\]", 60); time.sleep(2); r.shot("8-revoked.png")
        passed("revoke: the workspace left the phone's list")
        print(f"OK: evidence in {a.out}; look at each screenshot")
    finally:
        Path(a.out, "logcat.txt").write_text(r.logcat())
        if not a.keep_automation:
            r.run_as("rm", "-f", "files/automation.on")


if __name__ == "__main__":
    main()
