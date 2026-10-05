#!/usr/bin/env python3
"""Under Xvfb: create a directory group using real controls, launch and restore its terminal."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
HAXEON = str(ROOT / "haxeon/scripts/haxeon")
INSTALL = Path(sys.argv[1]).resolve(strict=True) if len(sys.argv) > 1 else None
RUNNER = [str(INSTALL / "exosuit")] if INSTALL else [HAXEON, "run", "--project", str(ROOT / "graphical/haxeon.json"), "--"]
with tempfile.TemporaryDirectory(prefix="exgroupsui-") as temporary:
    fixture = Path(temporary)
    project = fixture / "project"; project.mkdir()
    child = project / "tools dir"; child.mkdir()
    state = fixture / "state"
    environment = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(fixture / "settings"), SHELL="/bin/sh", EXOSUIT_AGENT_LAUNCHER=str(INSTALL / "tools/run-agent.py" if INSTALL else ROOT / "scripts/run-agent.py"))
    environment.pop("EXOSUIT_AGENT_ALWAYS_AVAILABLE", None)
    if INSTALL:
        environment.update(HAXEON_BIN="/no/source/compiler", HAXEON_ROOT="/no/source/tree", LD_LIBRARY_PATH="")
    app = None
    def click(window, bounds):
        subprocess.run(["xdotool", "mousemove", "--window", window, str(round(bounds["x"] + bounds["width"] / 2)), str(round(bounds["y"] + bounds["height"] / 2)), "click", "1"], check=True)
    def locate(layout, label):
        nodes = [n for n in layout if n.get("label") == label and n["visible"] and n["bounds"]["width"] > 0]
        assert nodes, (label, [n.get("label") for n in layout if n["visible"]])
        return nodes[0]["bounds"]
    def field(window, layout, label, value):
        candidates = [n for n in layout if n.get("label") == label and n.get("focusable") and n["visible"]]
        assert candidates, label
        click(window, candidates[0]["bounds"])
        subprocess.run(["xdotool", "key", "--clearmodifiers", "ctrl+a"], check=True)
        subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "1", value], check=True)
    try:
        for index in range(5):
            capture = fixture / str(index)
            flags = ["--open-workbench"]
            with (fixture / ("app-" + str(index) + ".log")).open("w") as log:
                app = subprocess.Popen([*RUNNER, str(project), *flags, "--capture-dir=" + str(capture), "--capture-seconds=9"], cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
                window = subprocess.check_output(["timeout", "60", "xdotool", "search", "--sync", "--onlyvisible", "--name", "^exosuit$"], text=True).splitlines()[0]
                subprocess.run(["xdotool", "windowfocus", "--sync", window], check=True)
                time.sleep(2)
                if index in (1, 2):
                    layout = json.loads((fixture / "0/layout.json").read_text())
                    click(window, locate(layout, "New group")); time.sleep(0.5)
                    if index == 2:
                        editor = json.loads((fixture / "1/layout.json").read_text())
                        field(window, editor, "Group name", "Tools")
                        field(window, editor, "Directory (empty inherits)", str(child))
                        click(window, locate(editor, "Save group"))
                elif index == 3:
                    layout = json.loads((fixture / "2/layout.json").read_text())
                    click(window, locate(layout, "Tools · " + str(child))); time.sleep(0.5)
                    click(window, locate(layout, "New terminal")); time.sleep(1)
                elif index == 4:
                    subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "1", "printf RESTORED_WORKBENCH > ui-restored"], check=True)
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "Return"], check=True)
                assert app.wait(timeout=80) == 0, (fixture / ("app-" + str(index) + ".log")).read_text()
                app = None
            if index >= 2:
                diagnostic = json.loads((capture / "app-state.json").read_text())
                catalog = diagnostic["terminalCatalog"]
                assert catalog is not None, diagnostic
                groups = [g for g in catalog["groups"] if g["name"] == "Tools"]
                assert len(groups) == 1 and groups[0]["cwd"] == str(child) and groups[0]["parent"] == "work", groups
                if index >= 3:
                    terminals = [t for t in catalog["terminals"] if t["group"] == groups[0]["id"]]
                    assert len(terminals) == 1 and terminals[0]["cwd"] == str(child), terminals
                    assert len(diagnostic["terminalResourceIds"]) == 1, diagnostic
        assert (child / "ui-restored").read_text() == "RESTORED_WORKBENCH"
        print("PASS: Workbench controls create a nested directory group, launch in it, and restore the same remote resource from its workspace scope")
    except Exception:
        for path in sorted(fixture.glob("app-*.log")):
            print(path.name + ":\n" + path.read_text()[-5000:])
        raise
    finally:
        if app is not None and app.poll() is None:
            app.terminate(); app.wait(timeout=10)
        for endpoint in state.glob("exosuit/workspaces/*/endpoint.json"):
            try:
                pid = json.loads(endpoint.read_text())["managerPid"]
                os.kill(pid, signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
