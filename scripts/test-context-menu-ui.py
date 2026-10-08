#!/usr/bin/env python3
"""Exercise context menus with real X11 mouse/key events; run under xvfb-run -a."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "tests/context-menu-ui-smoke/haxeon.json"


def main():
    subprocess.run([str(ROOT / "haxeon/scripts/haxeon"), "build", "--project", str(PROJECT)], check=True)
    with tempfile.TemporaryDirectory(prefix="exosuit-native-menu-") as directory:
        fixture = Path(directory)
        (fixture / "Main.hx").write_text("class Main { static function main() {} }\n")
        native = PROJECT.parent / "build/host/native"
        libraries = [ROOT / "haxeon/out", ROOT / "haxeon/.tools/hashlink",
                     *sorted(path for path in native.iterdir() if path.is_dir())]
        env = dict(os.environ, LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)),
                   PRAGTICAL_PORTABLE=str(fixture / "settings"))
        with (fixture / "app.log").open("w") as log:
            app = subprocess.Popen([str(ROOT / "haxeon/.tools/hashlink/hl"),
                                    str(PROJECT.parent / "build/host/main.hl"), str(fixture)],
                                   cwd=ROOT, env=env, stdout=log, stderr=log)
            state = {}

            def wait(predicate, description):
                nonlocal state
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((fixture / "state.json").read_text())
                        if predicate(state):
                            return state
                    except (OSError, ValueError):
                        pass
                    if app.poll() is not None:
                        raise AssertionError((fixture / "app.log").read_text())
                    time.sleep(.04)
                raise AssertionError(f"{description}: {state}")

            def xdo(*args):
                return subprocess.check_output(["xdotool", *map(str, args)], text=True).strip()

            def click(node, button=1):
                xdo("mousemove", "--window", window, int(node["x"] + node["width"] / 2),
                    int(node["y"] + node["height"] / 2), "click", button)

            def menu_items():
                return [n for n in state["nodes"] if n["menuItem"] and n["enabled"]]

            try:
                wait(lambda s: any(n["key"] == "activity-manage" for n in s["nodes"]), "App did not start")
                window = xdo("search", "--name", "^Context menu native input smoke$").splitlines()[-1]
                xdo("windowfocus", "--sync", window)
                gear = next(n for n in state["nodes"] if n["key"] == "activity-manage")
                for cycle in range(3):
                    click(gear)
                    wait(lambda s: s["menuOpen"] and s["focusLabel"] == "Menu", "Mouse menu retained a selection")
                    first = next(n for n in state["nodes"] if n["key"] == "manage-palette")
                    xdo("key", "Down")
                    wait(lambda s: s["focus"] == first["id"], "First native Down failed without hovering")
                    middle = next(n for n in state["nodes"] if n["key"] == "manage-keyboard")
                    xdo("mousemove", "--window", window, int(middle["x"] + 20), int(middle["y"] + 10))
                    wait(lambda s: s["focus"] == middle["id"], "Pointer did not select middle action")
                    xdo("key", "Escape")
                    wait(lambda s: not s["menuOpen"], "Escape did not close menu")
                editor = next(n for n in state["nodes"] if (n["key"] or "").startswith("editor:"))
                for cycle in range(3):
                    click(editor, 3)
                    wait(lambda s: s["menuOpen"] and s["focusLabel"] == "Menu", "Editor right-click retained a selection")
                    items = menu_items()
                    assert items, "No enabled editor commands"
                    xdo("key", "Down")
                    wait(lambda s: s["focus"] == items[0]["id"], "Editor's first Down failed without hovering")
                    middle = items[len(items) // 2]
                    xdo("mousemove", "--window", window, int(middle["x"] + 20), int(middle["y"] + 10))
                    wait(lambda s: s["focus"] == middle["id"], "Pointer did not select editor action")
                    xdo("key", "Escape")
                    wait(lambda s: not s["menuOpen"], "Editor Escape did not close menu")
                click(editor)
                xdo("key", "shift+F10")
                wait(lambda s: s["menuOpen"] and s["focus"] in [n["id"] for n in s["nodes"] if n["menuItem"]],
                     "Keyboard context menu did not select an action")
                print("PASS: native editor right-click, Down without hover, repeated reopenings, and Shift+F10")
            finally:
                app.terminate()
                app.wait(timeout=5)


if __name__ == "__main__":
    main()
