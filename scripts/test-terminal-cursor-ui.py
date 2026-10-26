#!/usr/bin/env python3
"""Verify terminal cursor focus presentation, retained rows and VT focus reports."""
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "tests/terminal-cursor-ui-smoke/haxeon.json"


def main():
    subprocess.run([str(ROOT / "haxeon/scripts/haxeon"), "build", "--project", str(PROJECT)], check=True)
    native = PROJECT.parent / "build/host/native"
    libraries = [ROOT / "haxeon/out", ROOT / "haxeon/.tools/hashlink",
                 *sorted(path for path in native.iterdir() if path.is_dir())]
    with tempfile.TemporaryDirectory(prefix="exosuit-terminal-cursor-") as temporary:
        fixture = Path(temporary)
        environment = dict(os.environ, LD_LIBRARY_PATH=os.pathsep.join(map(str, libraries)),
                           XDG_STATE_HOME=str(fixture / "state"), PRAGTICAL_PORTABLE=str(fixture / "settings"))
        for scheme in ("light", "dark"):
            foreground = (32, 42, 54) if scheme == "light" else (220, 227, 236)
            background = (255, 255, 255) if scheme == "light" else (23, 28, 35)
            images = {}
            for mode in ("focused", "unfocused", "refocused", "window-blur", "hidden", "colors", "row-reuse"):
                capture = fixture / f"{scheme}-{mode}"
                command = [str(ROOT / "haxeon/.tools/hashlink/hl"),
                           str(PROJECT.parent / "build/host/main.hl"), str(capture), mode, scheme]
                if not environment.get("DISPLAY") and shutil.which("xvfb-run"):
                    command = ["xvfb-run", "-a", *command]
                subprocess.run(command, cwd=ROOT, env=environment, check=True, timeout=30)
                state = json.loads((capture / "app-state.json").read_text())
                image = Image.open(capture / "frame.png").convert("RGB")
                images[mode] = image
                if mode == "row-reuse":
                    assert state["rowReuseChecks"] == 25 and state["stableRowWidgets"] == 6, state
                    comparisons = sorted(capture.glob("comparison-*.png"))
                    assert len(comparisons) == 25, len(comparisons)
                    for comparison in comparisons:
                        pixels = Image.open(comparison).convert("RGB")
                        difference = ImageChops.difference(pixels.crop((0, 0, 360, 140)),
                                                          pixels.crop((360, 0, 720, 140)))
                        assert difference.getbbox() is None, (scheme, comparison, difference.getbbox())
                    continue
                if mode == "colors":
                    assert "RED RED" in state["lines"][0], state
                    assert "INDEXED TRUECOLOR" in state["lines"][1], state
                    continue
                x = math.floor(state["cursorX"] + state["cursorWidth"] / 2)
                y = math.floor(state["cursorY"] + state["cursorHeight"] / 2)
                active = mode in ("focused", "refocused")
                assert state["focused"] == active, (scheme, mode, state)
                reports = "\x1b[I" + ("\x1b[O" if mode != "focused" else "") + ("\x1b[I" if mode == "refocused" else "")
                assert state["focusReports"] == reports, (scheme, mode, "missing or duplicate VT focus reports", state)
                assert image.getpixel((x, y)) == (foreground if active else background), (scheme, mode, "cursor interior")
                if mode in ("unfocused", "window-blur"):
                    for edge in (state["cursorY"], state["cursorY"] + state["cursorHeight"] - 1):
                        assert image.getpixel((x, math.floor(edge))) == foreground, (scheme, mode, "cursor border")
                if mode == "hidden":
                    assert image.getpixel((x, math.floor(state["cursorY"]))) == background, "Hidden cursor became visible"
            assert images["focused"].tobytes() == images["refocused"].tobytes(), "Refocusing left stale cursor pixels"
            assert images["unfocused"].tobytes() == images["window-blur"].tobytes(), "Widget and window blur differ"
        artifacts = os.environ.get("TERMINAL_CURSOR_ARTIFACTS")
        if artifacts:
            shutil.copytree(fixture, artifacts, dirs_exist_ok=True)
        print("PASS: terminal cursor focus, colors and retained-row comparisons in both themes")


if __name__ == "__main__":
    main()
