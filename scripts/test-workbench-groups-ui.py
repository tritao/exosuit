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
    environment = dict(os.environ, XDG_STATE_HOME=str(state), PRAGTICAL_PORTABLE=str(fixture / "settings"), SHELL="/bin/sh", EXOSUIT_AGENT_LAUNCHER=str(INSTALL / "tools/exosuit-agent.hl" if INSTALL else ROOT / "agent/build/host/main.hl"))
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
        for index in range(12):
            capture = fixture / str(index)
            flags = ["--open-workbench"]
            with (fixture / ("app-" + str(index) + ".log")).open("w") as log:
                app = subprocess.Popen([*RUNNER, str(project), *flags, "--capture-dir=" + str(capture), "--capture-seconds=9"], cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
                window = subprocess.check_output(["timeout", "60", "xdotool", "search", "--sync", "--onlyvisible", "--name", "^exosuit$"], text=True).splitlines()[0]
                subprocess.run(["xdotool", "windowfocus", "--sync", window], check=True)
                time.sleep(2)
                if index in (1, 2):
                    layout = json.loads((fixture / "0/layout.json").read_text())
                    click(window, locate(layout, "Workbench actions")); time.sleep(0.3)
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "Home", "Down", "Down", "Return"], check=True); time.sleep(0.5)
                    if index == 2:
                        editor = json.loads((fixture / "1/layout.json").read_text())
                        field(window, editor, "Group name", "Tools")
                        subprocess.run(["xdotool", "key", "--clearmodifiers", "Return"], check=True)
                elif index in (3, 4):
                    layout = json.loads((fixture / "2/layout.json").read_text())
                    click(window, locate(layout, "Tools · " + str(project))); time.sleep(.3)
                    click(window, locate(layout, "Workbench actions")); time.sleep(.3)
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "Home", "Down", "Down", "Down", "Down", "Return"], check=True)
                    time.sleep(.4)
                    if index == 4:
                        editor = json.loads((fixture / "3/layout.json").read_text())
                        field(window, editor, "Directory (empty inherits)", str(child))
                        click(window, locate(editor, "Save group"))
                elif index == 5:
                    layout = json.loads((fixture / "4/layout.json").read_text())
                    click(window, locate(layout, "Tools · " + str(child))); time.sleep(.5)
                    click(window, locate(layout, "New terminal")); time.sleep(1)
                elif index == 6:
                    subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "1", "printf RESTORED_WORKBENCH > ui-restored"], check=True)
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "Return"], check=True)
                elif index == 7:
                    previous = json.loads((fixture / "6/layout.json").read_text())
                    groups = [n for n in previous if (n.get("label") or "").startswith("Tools ·") and n["visible"]]
                    assert groups, previous
                    click(window, groups[0]["bounds"])
                elif index == 8:
                    collapsed = json.loads((fixture / "6/layout.json").read_text())
                    group = next(n for n in collapsed if (n.get("label") or "").startswith("Tools ·") and n["visible"])
                    click(window, group["bounds"]); time.sleep(.3)
                    # Closing hides the editor view; activating the resource twice
                    # reuses the session and creates only one editor tab.
                    previous = json.loads((fixture / "7/layout.json").read_text())
                    diagnostic = json.loads((fixture / "6/app-state.json").read_text())
                    record = diagnostic["terminalCatalog"]["terminals"][0]
                    tab = locate(previous, record["name"])
                    subprocess.run(["xdotool", "mousemove", "--window", window,
                                    str(round(tab["x"] + tab["width"] / 2)), str(round(tab["y"] + tab["height"] / 2)), "click", "2"], check=True)
                    time.sleep(.4)
                    bounds = locate(previous, record["name"] + " · " + record["state"])
                    click(window, bounds); time.sleep(.4)
                    click(window, bounds); time.sleep(.4)
                    subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "1", "printf REOPENED_WORKBENCH > ui-reopened"], check=True)
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "Return"], check=True)
                elif index in (9, 10):
                    previous = json.loads((fixture / "8/layout.json").read_text())
                    group = next(n for n in previous if (n.get("label") or "").startswith("Tools ·") and n["visible"])
                    click(window, group["bounds"])
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "F2"], check=True)
                    time.sleep(.4)
                    if index == 10:
                        editor = json.loads((fixture / "9/layout.json").read_text())
                        field(window, editor, "Group name", "Tools renamed")
                        subprocess.run(["xdotool", "key", "--clearmodifiers", "Return"], check=True)
                elif index == 11:
                    previous = json.loads((fixture / "10/layout.json").read_text())
                    click(window, locate(previous, "Workbench actions")); time.sleep(.3)
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "Home", "Down", "Down", "Return"], check=True)
                    time.sleep(.3)
                    subprocess.run(["xdotool", "type", "--clearmodifiers", "Discarded group"], check=True)
                    subprocess.run(["xdotool", "key", "--clearmodifiers", "Escape"], check=True)
                assert app.wait(timeout=80) == 0, (fixture / ("app-" + str(index) + ".log")).read_text()
                app = None
            if index in (1, 2):
                nodes = json.loads((capture / "layout.json").read_text())
                assert not any(n.get("label") == "Save group" and n["visible"] for n in nodes), nodes
            if index >= 2:
                diagnostic = json.loads((capture / "app-state.json").read_text())
                catalog = diagnostic["terminalCatalog"]
                assert catalog is not None, diagnostic
                if index in (2, 10):
                    created_group = next(g for g in catalog["groups"] if g["id"] != "work")
                    assert diagnostic["workbenchSelectedNode"] == "g:" + created_group["id"], diagnostic
                assert len(catalog["groups"]) == 2, catalog
                groups = [g for g in catalog["groups"] if g["name"] == ("Tools renamed" if index >= 10 else "Tools")]
                assert len(groups) == 1 and groups[0]["cwd"] == (str(child) if index >= 4 else None) and groups[0]["parent"] == "work", groups
                if index >= 5:
                    terminals = [t for t in catalog["terminals"] if t["group"] == groups[0]["id"]]
                    assert len(terminals) == 1 and terminals[0]["cwd"] == str(child), terminals
                    assert len(diagnostic["terminalResourceIds"]) == 1, diagnostic
                    assert diagnostic["terminalEditorTabs"] == [terminals[0]["id"]], diagnostic
                    if index == 5:
                        assert diagnostic["workbenchSelectedNode"] == "t:" + terminals[0]["id"], diagnostic
                        nodes = json.loads((capture / "layout.json").read_text())
                        assert any(n.get("label") == terminals[0]["name"] + " · " + terminals[0]["state"] and n["visible"] for n in nodes), nodes
                    assert diagnostic["terminalPanelTabs"] == [], diagnostic
                    assert diagnostic["terminalHiddenTabs"] == [], diagnostic
                    if index == 8:
                        previous = json.loads((fixture / "6/app-state.json").read_text())
                        assert diagnostic["terminalIds"] == previous["terminalIds"], diagnostic
        assert (child / "ui-restored").read_text() == "RESTORED_WORKBENCH"
        assert (child / "ui-reopened").read_text() == "REOPENED_WORKBENCH"
        print("PASS: Workbench terminal editor tabs close/reopen without duplicates; Workbench controls create a nested directory group, launch in it, and restore the same remote resource from its workspace scope")
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
