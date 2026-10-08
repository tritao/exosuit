#!/usr/bin/env python3
"""Xvfb desktop acceptance for editable files in an attached local workspace."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
INSTALL = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
RUNNER = [str(INSTALL / "exosuit")] if INSTALL else [
    str(ROOT / "haxeon/scripts/haxeon"), "run", "--project",
    str(ROOT / "graphical/haxeon.json"), "--"
]

with tempfile.TemporaryDirectory(prefix="exworkspacefilesui-") as temporary:
    fixture = Path(temporary)
    project = fixture / "project"
    project.mkdir()
    (project / "README.md").write_text("Local project readme\n", encoding="utf-8")
    (project / "notes.md").write_text("Initial local note\n", encoding="utf-8")
    state = fixture / "state"
    capture = fixture / "capture"
    environment = dict(os.environ,
        XDG_STATE_HOME=str(state),
        PRAGTICAL_PORTABLE=str(fixture / "settings"),
        EXOSUIT_AGENT_LAUNCHER=str(INSTALL / "tools/exosuit-agent.hl" if INSTALL else ROOT / "agent/build/host/main.hl"))
    if INSTALL:
        environment.update(HAXEON_BIN="/no/source/compiler", HAXEON_ROOT="/no/source/tree", LD_LIBRARY_PATH="")
    app = None
    try:
        with (fixture / "app.log").open("w") as log:
            app = subprocess.Popen([
                *RUNNER, str(project), "--capture-dir=" + str(capture), "--capture-seconds=15"
            ], cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
            window = subprocess.check_output([
                "timeout", "60", "xdotool", "search", "--sync", "--onlyvisible", "--name", "^exosuit$"
            ], text=True).splitlines()[0]
            subprocess.run(["xdotool", "windowfocus", "--sync", window], check=True)
            # Allow the local workspace connection and Files tree to initialize.
            time.sleep(5)

            def click(x, y):
                subprocess.run(["xdotool", "mousemove", "--window", window, str(x), str(y)], check=True)
                subprocess.run(["xdotool", "click", "1"], check=True)

            # Open notes.md from Files, replace its contents, then save the normal document.
            subprocess.run(["xdotool", "mousemove", "--window", window, "145", "140"], check=True)
            subprocess.run(["xdotool", "click", "--repeat", "2", "--delay", "180", "1"], check=True)
            time.sleep(.5)
            click(500, 220)
            subprocess.run(["xdotool", "key", "--clearmodifiers", "ctrl+a"], check=True)
            subprocess.run(["xdotool", "type", "--clearmodifiers", "Editable local file: LOCAL_EDIT"], check=True)
            subprocess.run(["xdotool", "key", "--clearmodifiers", "ctrl+s"], check=True)
            time.sleep(.5)
            assert app.wait(timeout=75) == 0, (fixture / "app.log").read_text()[-5000:]
            app = None

        diagnostic = json.loads((capture / "app-state.json").read_text())
        tree = (capture / "ui-tree.txt").read_text()
        assert diagnostic["workspaceConnection"] == "Workspace connected", diagnostic
        assert "notes.md" in diagnostic["documents"], diagnostic["documents"]
        assert diagnostic["workspaceFileTabs"] == [], diagnostic["workspaceFileTabs"]
        assert "Read-only" not in tree, tree[-1500:]
        assert (project / "notes.md").read_text(encoding="utf-8") == "Editable local file: LOCAL_EDIT"
        assert diagnostic["errors"] == [], diagnostic["errors"]
        print("PASS: desktop Files opens an attached local file as an editable document and saves changes")
    except Exception:
        if (fixture / "app.log").exists():
            print((fixture / "app.log").read_text()[-5000:])
        raise
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            app.wait(timeout=10)
        for endpoint in (fixture / "state").rglob("endpoint.json"):
            try:
                pid = json.loads(endpoint.read_text())["managerPid"]
                os.kill(pid, signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
