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
    changed = "# Remote preview fixture: café 🙂 changed live on disk\n\n```haxe\nclass Example {}\n```\n"
    refreshed = "# Remote preview fixture: café 🙂 refreshed from disk\n\n```haxe\nclass Example {}\n```\n"
    note = project / "notes.md"
    note.write_text(expected)
    state = fixture / "state"
    environment = dict(os.environ,
        XDG_STATE_HOME=str(state),
        PRAGTICAL_PORTABLE=str(fixture / "settings"),
        EXOSUIT_AGENT_LAUNCHER=str(INSTALL / "tools/run-agent.py" if INSTALL else ROOT / "scripts/run-agent.py"))
    if INSTALL:
        environment.update(HAXEON_BIN="/no/source/compiler", HAXEON_ROOT="/no/source/tree", LD_LIBRARY_PATH="")
    def run_capture(name, actions):
        target = fixture / name
        app = None
        try:
            with (fixture / (name + ".log")).open("w") as log:
                app = subprocess.Popen([
                    *RUNNER, str(project), "--capture-dir=" + str(target), "--capture-seconds=15"
                ], cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
                window = subprocess.check_output([
                    "timeout", "60", "xdotool", "search", "--sync", "--onlyvisible", "--name", "^exosuit$"
                ], text=True).splitlines()[0]
                subprocess.run(["xdotool", "windowfocus", "--sync", window], check=True)
                # Let the authenticated local workspace connection populate the tree.
                time.sleep(7)

                def click(x, y):
                    subprocess.run(["xdotool", "mousemove", "--window", window, str(x), str(y), "click", "1"], check=True)

                def double_click(x, y):
                    subprocess.run(["xdotool", "mousemove", "--window", window, str(x), str(y),
                        "click", "--repeat", "2", "--delay", "180", "1"], check=True)

                actions(click, double_click)
                assert app.wait(timeout=75) == 0, (fixture / (name + ".log")).read_text()[-5000:]
                app = None
            return (json.loads((target / "app-state.json").read_text()),
                (target / "ui-tree.txt").read_text())
        except Exception:
            if (fixture / (name + ".log")).exists():
                print((fixture / (name + ".log")).read_text()[-5000:])
            raise
        finally:
            if app is not None and app.poll() is None:
                app.terminate()
                app.wait(timeout=10)

    try:
        def verify_live_stale(click, double_click):
            double_click(145, 140)  # Open notes.md as a sticky read-only tab.
            time.sleep(.4)
            note.write_text(changed)
            time.sleep(1.0)  # Native watcher coalesces and delivers the root cursor.

        stale_diagnostic, stale_tree = run_capture("stale", verify_live_stale)
        stale_tabs = stale_diagnostic["workspaceFileTabs"]
        assert stale_diagnostic["workspaceConnection"] == "Workspace connected", stale_diagnostic
        assert stale_diagnostic["explorerWatching"] is True, stale_diagnostic
        assert len(stale_tabs) == 1 and stale_tabs[0]["path"] == "notes.md", stale_tabs
        assert stale_tabs[0]["diskChanged"] is True, stale_tabs
        assert "File changed on disk. Refresh to load the latest version." in stale_tree, stale_tree[-1600:]

        def verify_refresh(click, double_click):
            click(145, 114)  # README.md: open as the temporary preview tab.
            time.sleep(.3)
            note.write_text(updated)  # Force readOpen to reject the now-stale listing revision.
            click(145, 140)  # notes.md: replace the existing preview.
            time.sleep(.4)
            double_click(145, 140)  # Keep the file in a sticky tab.
            time.sleep(.4)
            note.write_text(refreshed)
            time.sleep(.7)
            click(1200, 100)  # Refresh the open saved-file snapshot.
            time.sleep(.5)
            click(500, 220)  # Focus the read-only file view and try to edit it.
            subprocess.run(["xdotool", "type", "--clearmodifiers", "SHOULD_NOT_EDIT"], check=True)

        diagnostic, tree = run_capture("refreshed", verify_refresh)
        tabs = diagnostic["workspaceFileTabs"]
        assert diagnostic["workspaceConnection"] == "Workspace connected", diagnostic
        assert diagnostic["explorerWatching"] is True, diagnostic
        assert len(tabs) == 1 and tabs[0]["path"] == "notes.md" and tabs[0]["preview"] is False, tabs
        assert tabs[0]["syntax"] == "Markdown" and tabs[0]["diskChanged"] is False, tabs
        assert "Remote preview fixture: café 🙂 refreshed from disk" in tree and "SHOULD_NOT_EDIT" not in tree, (
            "\n".join(line for line in tree.splitlines() if "workspace-file" in line or "Refresh" in line)
            + "\n" + tree[-1200:])
        assert note.read_text() == refreshed
        assert diagnostic["errors"] == [], diagnostic["errors"]
        print("PASS: RPC explorer, syntax preview, live stale-file notice, stale-revision recovery, manual refresh, sticky tab and read-only view")
    finally:
        for endpoint in state.glob("exosuit/workspaces/*/endpoint.json"):
            try:
                pid = json.loads(endpoint.read_text())["managerPid"]
                os.kill(pid, signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
