#!/usr/bin/env python3
"""Exercise context menus with real X11 mouse/key events; run under xvfb-run -a."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
os.environ.setdefault("EXOSUIT_SUIT_AUTOSTART", "0")  # tests must not start the user's suit daemon

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
                destinations = [n for n in state['nodes'] if isinstance(n['key'], str) and n['key'].startswith('activity:')]
                initial_activity = state['activityId']
                initial_visibility = state['sidebarVisible']

                def auxiliary_click(node, button):
                    releases = state['pointerUps']
                    click(node, button)
                    wait(lambda s: s['pointerUps'] > releases, 'Auxiliary pointer release was not processed')

                for destination in [*destinations, gear]:
                    for button in (3, 2):
                        auxiliary_click(destination, button)
                        assert (state['activityId'], state['sidebarVisible'], state['menuOpen']) == \
                               (initial_activity, initial_visibility, False), ('Auxiliary click activated sidebar', destination, state)
                other = next(n for n in destinations if n['key'] != 'activity:' + initial_activity)
                click(other)
                wait(lambda s: s['activityId'] == other['key'][9:] and s['sidebarVisible'], 'Primary sidebar click failed')
                auxiliary_click(other, 3)
                assert state['sidebarVisible'], 'Right-click collapsed the selected sidebar'
                original = next(n for n in destinations if n['key'] == 'activity:' + initial_activity)
                click(original)
                wait(lambda s: s['activityId'] == initial_activity and s['sidebarVisible'], 'Could not restore sidebar')
                if not initial_visibility:
                    click(original)
                    wait(lambda s: not s['sidebarVisible'], 'Could not restore sidebar visibility')
                if os.environ.get("EXOSUIT_MENU_TERMINAL"):
                    wait(lambda s: any(n["key"] == "terminal-pane" for n in s["nodes"]), "Terminal did not open")
                    for cycle in range(20 if os.environ.get("EXOSUIT_MENU_BUSY") else 4):
                        terminal = next(n for n in state["nodes"] if n["key"] == "terminal-pane")
                        click(terminal)
                        wait(lambda s: s["focusKey"] == "terminal-pane", "Terminal did not receive focus")
                        if cycle == 0 and os.environ.get("EXOSUIT_MENU_BUSY"):
                            command = "printf '\\033[?1000h\\033[?1006h\\033[?1004h'; while :; do printf 'redraw\\r\\n'; sleep 0.01; done"
                            xdo("type", "--clearmodifiers", "--delay", 1, command)
                            xdo("key", "Return")
                            time.sleep(.2)
                        layout = next(n for n in state["nodes"] if n["key"] == "layout-menu")
                        xdo("mousemove", "--window", window, int(layout["x"] + layout["width"] / 2), int(layout["y"] + layout["height"] / 2))
                        before = fixture / "before-menu.png"
                        after = fixture / "after-menu.png"
                        subprocess.run(["import", "-window", window, str(before)], check=True)
                        if cycle % 2:
                            xdo("mousedown", 1)
                            time.sleep(.15)
                            xdo("mouseup", 1)
                        else:
                            xdo("click", 1)
                        wait(lambda s: s["menuOpen"] and any(n["key"] == "view.layout-bottom" for n in s["nodes"]), "First Layout click failed after terminal focus")
                        time.sleep(.08)
                        subprocess.run(["import", "-window", window, str(after)], check=True)
                        from PIL import Image, ImageChops
                        item = next(n for n in state["nodes"] if n["key"] == "view.layout-bottom")
                        box = (int(item["x"]), int(item["y"]), int(item["x"] + item["width"]), int(item["y"] + item["height"]))
                        with Image.open(before) as before_image, Image.open(after) as after_image:
                            assert ImageChops.difference(before_image.convert("RGB").crop(box), after_image.convert("RGB").crop(box)).getbbox(), "Layout exists in UI state but was not painted"
                        xdo("key", "Escape")
                        wait(lambda s: not s["menuOpen"], "Escape did not close Layout")
                    print("PASS: first Layout click after terminal focus (" + os.environ["EXOSUIT_MENU_TERMINAL"] + ")")
                    return
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
                layout = next(n for n in state["nodes"] if n["key"] == "layout-menu")
                for cycle in range(3):
                    click(gear)
                    wait(lambda s: s["menuOpen"] and any(n["key"] == "manage-palette" for n in s["nodes"]), "Manage menu did not open")
                    click(layout)
                    wait(lambda s: s["menuOpen"] and any(n["key"] == "view.layout-bottom" for n in s["nodes"]), "First Layout click only dismissed the previous menu")
                    click(gear)
                    wait(lambda s: s["menuOpen"] and any(n["key"] == "manage-palette" for n in s["nodes"]), "First Manage click only dismissed Layout")
                    click(gear)
                    wait(lambda s: not s["menuOpen"], "Manage trigger did not toggle closed")
                    click(layout)
                    wait(lambda s: s["menuOpen"], "First Layout click failed without a popup")
                    click(layout)
                    wait(lambda s: not s["menuOpen"], "Layout trigger did not toggle closed")
                click(editor, 3)
                wait(lambda s: s["menuOpen"], "Editor menu did not open for switching")
                click(layout)
                wait(lambda s: s["menuOpen"] and any(n["key"] == "view.layout-bottom" for n in s["nodes"]), "Context menu blocked switching to Layout")
                click(editor)
                wait(lambda s: not s["menuOpen"], "Ordinary outside click did not dismiss Layout")
                click(layout)
                wait(lambda s: s["menuOpen"], "Layout did not reopen after outside dismissal")
                xdo("key", "Escape")
                wait(lambda s: not s["menuOpen"], "Escape did not close Layout")
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
                xdo("key", "Escape")
                wait(lambda s: not s["menuOpen"], "Keyboard menu did not close")
                for workbench in (False, True):
                    if workbench:
                        (fixture / "workbench-menu").touch()
                        # Request a frame so the fixture installs the workbench handler.
                        click(gear)
                        wait(lambda s: s["menuOpen"], "Manage menu did not open")
                        xdo("key", "Escape")
                        wait(lambda s: not s["menuOpen"], "Manage menu did not close")
                    for offset in (80, 220):
                        px = int(editor["x"] + offset)
                        py = int(editor["y"] + 90)
                        xdo("mousemove", "--window", window, px, py, "click", 3)
                        wait(lambda s: s["menuOpen"], "Positioned context menu did not open")
                        assert state["anchor"] == {"x": px, "y": py}, (workbench, state)
                        if workbench:
                            assert any(n["key"] == "smoke-action" for n in state["nodes"]), state
                        xdo("key", "Escape")
                        wait(lambda s: not s["menuOpen"], "Positioned menu did not close")
                    click(editor)
                    xdo("key", "shift+F10")
                    wait(lambda s: s["menuOpen"] and s["focus"] in [n["id"] for n in s["nodes"] if n["menuItem"]],
                         "Keyboard context menu did not select an action")
                    assert state["anchor"] != {"x": 0, "y": 0}, state
                    xdo("key", "Escape")
                    wait(lambda s: not s["menuOpen"], "Keyboard context menu did not close")
                print("PASS: native menu switching/toggling, outside dismissal, navigation, pointer anchors and Shift+F10")
            finally:
                app.terminate()
                app.wait(timeout=5)


if __name__ == "__main__":
    main()
