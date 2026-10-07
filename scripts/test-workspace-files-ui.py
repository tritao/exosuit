#!/usr/bin/env python3
"""Xvfb desktop acceptance for RPC-backed file previews and preview-tab behavior."""
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
    (project / "README.md").write_text("First preview\n")
    expected = "# Remote preview fixture: café 🙂\n\n```haxe\nclass Example {}\n```\n"
    updated = "# Remote preview fixture: café 🙂 updated after listing\n\n```haxe\nclass Example {}\n```\n"
    refreshed = "# Remote preview fixture: café 🙂 refreshed from disk\n\n```haxe\nclass Example {}\n```\n"
    note = project / "notes.md"
    note.write_text(expected)
    state = fixture / "state"
    capture = fixture / "capture"
    environment = dict(os.environ,
        XDG_STATE_HOME=str(state),
        PRAGTICAL_PORTABLE=str(fixture / "settings"),
        EXOSUIT_AGENT_LAUNCHER=str(INSTALL / "tools/run-agent.py" if INSTALL else ROOT / "scripts/run-agent.py"))
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
            # Let the authenticated local workspace connection populate the tree.
            time.sleep(7)
            def click(x, y):
                subprocess.run(["xdotool", "mousemove", "--window", window, str(x), str(y), "click", "1"], check=True)

            click(145, 114)  # README.md: open as the temporary preview tab.
            time.sleep(.3)
            note.write_text(updated)  # Force readOpen to reject the now-stale listing revision.
            click(145, 140)  # notes.txt: replace the existing preview.
            time.sleep(.4)
            subprocess.run(["xdotool", "mousemove", "--window", window, "145", "140",
                "click", "--repeat", "2", "--delay", "180", "1"], check=True)
            time.sleep(.4)
            note.write_text(refreshed)
            click(1200, 100)  # Refresh the open saved-file snapshot.
            time.sleep(.5)
            click(500, 220)  # Focus the read-only file view and try to edit it.
            subprocess.run(["xdotool", "type", "--clearmodifiers", "SHOULD_NOT_EDIT"], check=True)
            assert app.wait(timeout=75) == 0, (fixture / "app.log").read_text()[-5000:]
            app = None

        diagnostic = json.loads((capture / "app-state.json").read_text())
        tabs = diagnostic["workspaceFileTabs"]
        tree = (capture / "ui-tree.txt").read_text()
        assert diagnostic["workspaceConnection"] == "Workspace connected", diagnostic
        assert len(tabs) == 1 and tabs[0]["path"] == "notes.md" and tabs[0]["preview"] is False, tabs
        assert tabs[0]["syntax"] == "Markdown", tabs
        assert "Remote preview fixture: café 🙂 refreshed from disk" in tree and "SHOULD_NOT_EDIT" not in tree, (
            "\n".join(line for line in tree.splitlines() if "workspace-file" in line or "Refresh" in line)
            + "\n" + tree[-1200:])
        assert note.read_text() == refreshed
        assert diagnostic["errors"] == [], diagnostic["errors"]
        print("PASS: RPC explorer, syntax preview, stale-revision recovery, manual refresh, sticky tab and read-only view")
    except Exception:
        if (fixture / "app.log").exists():
            print((fixture / "app.log").read_text()[-5000:])
        raise
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            app.wait(timeout=10)
        for endpoint in state.glob("exosuit/workspaces/*/endpoint.json"):
            try:
                pid = json.loads(endpoint.read_text())["managerPid"]
                os.kill(pid, signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
