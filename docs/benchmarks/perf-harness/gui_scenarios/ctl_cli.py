"""exosuitctl, pragtical-ctl and launch forwarding against a running window (docs/design/exosuitctl/TDD-exosuit-ctl.md §16
steps 4–7), with no input to the window at all:

- `exosuitctl list`, `status`, `call control.ping`, a bad command (exit 2) and an unknown window (exit 3);
- `exosuitctl open <folder>`: the window opens the workspace that holds it, and a folder no workspace holds becomes a
  workspace named after it and opens; `exosuitctl open <file>:<line>` opens a tab; `exosuitctl documents` lists it;
- `exosuitctl project add <folder>` adds a folder to the window's workspace, and `exosuitctl watch project.changed` prints the
  event;
- `exosuit <file>` (the editor started with a path) hands the file to this window and exits, and no second window stays;
- with PRAGTICAL_CTL naming Pragtical's console program (pragtical.com; it is run with --ctl) in a folder with no
  `user` folder: `list`, `open` and `documents` through exohost's Pragtical pipe, with PRAGTICAL_USERDIR set to exohost's
  home;
- last, `exosuitctl quit --mode recover` closes the window."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m19_common import *  # noqa: F401,F403

FIXTURE = {"workspaces": ["alpha", "beta"], "folders": ["loose", "extra"], "open": None, "appArgs": ["--open-workbench"]}
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))


def exosuitctl(*arguments, timeout=30):
    done = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "exohost.py"), "--ctl", *arguments],
                          capture_output=True, text=True, timeout=timeout)
    print("exosuitctl %s -> %d %s%s" % (" ".join(arguments), done.returncode, done.stdout.strip()[:300], done.stderr.strip()[:300]), flush=True)
    return done


def editor_environment():
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    from exohost import library_path, library_variable
    from haxeon_paths import hl as haxeon_hl
    haxeon = os.environ.get("HAXEON_ROOT", os.path.join(ROOT, "haxeon"))
    hl = str(haxeon_hl(Path(haxeon)))
    bytecode = os.path.join(ROOT, "graphical", "build", "host", "main.hl")
    env = dict(os.environ)
    env[library_variable()] = library_path(Path(bytecode), Path(hl), Path(haxeon), env.get(library_variable(), ""))
    return hl, bytecode, env


def tab_names(s):
    return [t["title"].replace("\\", "/").split("/")[-1] for p in s["state"]["panes"] for t in p["tabs"]]


def run(gui):
    fixture = os.path.join(os.path.dirname(gui.out), "fixture")
    norm = lambda p: p.replace("\\", "/").rstrip("/").lower()
    gui.wait("workspace rows", lambda s: len(s["state"]["machineWorkspaces"]) == 2, 60)
    alpha, beta = ws(gui.state(), "Alpha")["id"], ws(gui.state(), "Beta")["id"]
    gui.open_workspace(alpha)
    attached(gui, "Alpha")

    gui.step("exosuitctl's basic commands")
    listed = exosuitctl("list")
    gui.check("exosuitctl list names this window", lambda s: listed.returncode == 0 and gui.instance in listed.stdout, 1, detail=lambda s: listed.stdout)
    status = exosuitctl("--output", "json", "status")
    gui.check("exosuitctl status is this window's", lambda s: status.returncode == 0 and json.loads(status.stdout)["instance_id"] == gui.instance, 1,
              detail=lambda s: status.stdout)
    ping = exosuitctl("call", "control.ping", "{}")
    gui.check("exosuitctl call control.ping prints {\"ok\":true}", lambda s: ping.returncode == 0 and json.loads(ping.stdout) == {"ok": True}, 1,
              detail=lambda s: ping.stdout)
    bad = exosuitctl("frobnicate")
    gui.check("a bad command exits 2", lambda s: bad.returncode == 2, 1, detail=lambda s: bad.returncode)
    missing = exosuitctl("--instance", "w1-1", "status")
    gui.check("an unknown window exits 3", lambda s: missing.returncode == 3, 1, detail=lambda s: (missing.returncode, missing.stderr))

    gui.step("exosuitctl open <folder>: the workspace that holds it")
    opened = exosuitctl("open", os.path.join(fixture, "beta"))
    gui.check("exosuitctl open beta's folder exits 0", lambda s: opened.returncode == 0, 1, detail=lambda s: opened.stderr)
    gui.check("the window opened Beta", lambda s: is_attached(s["state"], beta), 30, detail=lambda s: s["state"]["openWorkspace"])
    gui.shot("opened-beta")

    gui.step("exosuitctl open <folder no workspace holds>: a new workspace named after it")
    loose = os.path.join(fixture, "loose")
    opened = exosuitctl("open", loose)
    gui.check("exosuitctl open the loose folder exits 0", lambda s: opened.returncode == 0, 1, detail=lambda s: opened.stderr)
    gui.check("exohost lists a workspace of the loose folder", lambda s: any(any(norm(f) == norm(loose) for f in w["folders"])
              for w in s["state"]["machineWorkspaces"]), 15, detail=lambda s: s["state"]["machineWorkspaces"])
    made = lambda s: next((w for w in s["state"]["machineWorkspaces"] if any(norm(f) == norm(loose) for f in w["folders"])), None)
    gui.check("it is named after the folder and the window is on it", lambda s: made(s) and made(s)["name"].lower() == "loose"
              and is_attached(s["state"], made(s)["id"]), 30, detail=lambda s: (made(s), s["state"]["openWorkspace"]))

    gui.step("exosuitctl open <file>:<line>; documents")
    target = os.path.join(fixture, "alpha", "a2.txt")
    opened = exosuitctl("open", target + ":2")
    gui.check("exosuitctl open a2.txt:2 exits 0", lambda s: opened.returncode == 0, 1, detail=lambda s: opened.stderr)
    gui.check("a2.txt is open in a tab", lambda s: "a2.txt" in tab_names(s), 10, detail=tab_names)
    documents = exosuitctl("--output", "json", "documents")
    gui.check("exosuitctl documents lists a2.txt", lambda s: documents.returncode == 0 and any(norm(d.get("path") or "") == norm(target)
              for d in json.loads(documents.stdout)["documents"]), 1, detail=lambda s: documents.stdout)

    gui.step("exosuitctl project add, and exosuitctl watch prints project.changed")
    watched = os.path.join(gui.out, "watch.txt")
    with open(watched, "w") as sink:  # exohost.py runs exohost under it: its output goes to a file, and the tree is stopped
        watcher = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "exohost.py"), "--ctl", "watch", "project.changed"],
                                   stdout=sink, stderr=subprocess.STDOUT)
    time.sleep(2)
    extra = os.path.join(fixture, "extra")
    added = exosuitctl("project", "add", extra)
    gui.check("exosuitctl project add exits 0", lambda s: added.returncode == 0, 1, detail=lambda s: added.stderr)
    gui.check("the window's workspace has the folder", lambda s: any(norm(f) == norm(extra) for w in s["state"]["machineWorkspaces"]
              for f in w["folders"]), 15, detail=lambda s: s["state"]["machineWorkspaces"])
    time.sleep(1)
    subprocess.run(["taskkill", "/PID", str(watcher.pid), "/T", "/F"], capture_output=True)
    watcher.wait(10)
    printed = open(watched, encoding="utf-8", errors="replace").read()
    gui.check("exosuitctl watch printed project.changed", lambda s: '"project.changed"' in printed, 1, detail=lambda s: printed[-400:])

    gui.step("exosuit <file> with this window open: the file comes here")
    hl, bytecode, env = editor_environment()
    forwarded = os.path.join(fixture, "beta", "b3.txt")
    began = time.monotonic()
    launched = subprocess.run([hl, bytecode, forwarded], env=env, capture_output=True, text=True, timeout=60)
    seconds = time.monotonic() - began
    print("forwarding launch: exit %d after %.1f s %s" % (launched.returncode, seconds, (launched.stdout + launched.stderr)[-300:]), flush=True)
    gui.check("the second launch exited 0", lambda s: launched.returncode == 0, 1, detail=lambda s: launched.stderr[-400:])
    gui.check("b3.txt is open in this window", lambda s: "b3.txt" in tab_names(s), 10, detail=tab_names)
    gui.check("only this window is linked", lambda s: len(gui.exohost.control("exosuit.instances")["instances"]) == 1, 3)

    ctl = os.environ.get("PRAGTICAL_CTL")
    if ctl:
        gui.step("pragtical-ctl through exohost's Pragtical pipe")
        penv = dict(os.environ, PRAGTICAL_USERDIR=os.environ["EXOSUIT_EXOHOST_HOME"])
        plist = subprocess.run([ctl, "--ctl", "--output", "json", "list"], env=penv, capture_output=True, text=True, timeout=30)
        print("pragtical-ctl list -> %d %s %s" % (plist.returncode, plist.stdout[:400], plist.stderr[:300]), flush=True)
        gui.check("pragtical-ctl list finds this window", lambda s: plist.returncode == 0 and gui.instance in plist.stdout, 1,
                  detail=lambda s: (plist.stdout, plist.stderr))
        third = os.path.join(fixture, "alpha", "a3.txt")
        popen = subprocess.run([ctl, "--ctl", "--instance", gui.instance, "open", third], env=penv, capture_output=True, text=True, timeout=30)
        print("pragtical-ctl open -> %d %s %s" % (popen.returncode, popen.stdout[:400], popen.stderr[:300]), flush=True)
        gui.check("pragtical-ctl open opens a3.txt here", lambda s: popen.returncode == 0 and "a3.txt" in tab_names(s), 10,
                  detail=lambda s: (popen.stdout, popen.stderr, tab_names(s)), known_bug="NativeKit listener stops on ERROR_NO_DATA (docs/haxeon-compiler-bugs.md)")
        pdocs = subprocess.run([ctl, "--ctl", "--instance", gui.instance, "--output", "json", "documents"], env=penv, capture_output=True, text=True, timeout=30)
        gui.check("pragtical-ctl documents lists it", lambda s: pdocs.returncode == 0 and "a3.txt" in pdocs.stdout, 1,
                  detail=lambda s: (pdocs.stdout, pdocs.stderr), known_bug="NativeKit listener stops on ERROR_NO_DATA (docs/haxeon-compiler-bugs.md)")
    else:
        print("SKIP pragtical-ctl: PRAGTICAL_CTL is not set", flush=True)

    gui.step("exosuitctl quit --mode recover closes the window")
    quit = exosuitctl("quit", "--mode", "recover")
    end = time.monotonic() + 15
    while time.monotonic() < end and gui.exohost.instance_of(gui.pid):
        time.sleep(0.3)
    gone = gui.exohost.instance_of(gui.pid) is None
    # The window is gone, so these are recorded without a snapshot of it.
    for name, ok, note in (("exosuitctl quit exits 0", quit.returncode == 0, quit.stderr.strip()),
                           ("the window closed and unlinked", gone, "")):
        gui.results.append({"check": name, "ok": ok, "note": note})
        print(("PASS " if ok else "FAIL ") + name + (" -- " + note if note and not ok else ""), flush=True)


if __name__ == "__main__":
    main(run)
