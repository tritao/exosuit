#!/usr/bin/env python3
"""Verify terminal symbols, shortcuts, cursor focus, retained rows and VT focus reports."""
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
            modes = ["focused", "unfocused", "refocused", "window-blur", "window-refocused", "hidden", "selection", "colors", "symbols", "row-reuse", "async-echo"]
            if shutil.which("fc-list") and all(subprocess.check_output(["fc-list", ":charset=" + cp, "--format=%{file}"], text=True).strip() for cp in ("2801", "1fb00")):
                modes.append("system-symbols")
            for mode in modes:
                capture = fixture / f"{scheme}-{mode}"
                command = [str(ROOT / "haxeon/.tools/hashlink/hl"),
                           str(PROJECT.parent / "build/host/main.hl"), str(capture), mode, scheme]
                if not environment.get("DISPLAY") and shutil.which("xvfb-run"):
                    command = ["xvfb-run", "-a", *command]
                subprocess.run(command, cwd=ROOT, env=environment, check=True, timeout=30)
                state = json.loads((capture / "app-state.json").read_text())
                image = Image.open(capture / "frame.png").convert("RGB")
                images[mode] = image
                if mode in ("symbols", "system-symbols"):
                    # A missing glyph also has ink: verify actual Braille dot geometry,
                    # including eight separate dots, rather than just nonblank pixels.
                    def cell_ink(column, row):
                        advance = state['cellWidth']
                        left = round(8 + column * advance)
                        top = round(4 + row * state['rowHeight'])
                        width = round(advance)
                        height = round(state['rowHeight'])
                        return {(x, y) for y in range(height) for x in range(width)
                                if max(abs(a - b) for a, b in zip(image.getpixel((left + x, top + y)), background)) > 40}

                    for column in range(8):
                        ink = cell_ink(column, 0)
                        assert ink, (scheme, 'missing Braille dot', column)
                        assert max(x for x, y in ink) - min(x for x, y in ink) < state['cellWidth'] / 2, (scheme, 'tofu instead of Braille', column)
                        assert max(y for x, y in ink) - min(y for x, y in ink) < state['rowHeight'] / 3, (scheme, 'tofu instead of Braille', column)
                    pending = cell_ink(8, 0)
                    components = 0
                    while pending:
                        frontier = [pending.pop()]
                        components += 1
                        while frontier:
                            x, y = frontier.pop()
                            for dx in (-1, 0, 1):
                                for dy in (-1, 0, 1):
                                    neighbor = (x + dx, y + dy)
                                    if neighbor in pending:
                                        pending.remove(neighbor)
                                        frontier.append(neighbor)
                    assert components == 8, (scheme, 'full Braille cell did not render eight dots', components)
                    count = 9 if mode == 'system-symbols' else 10
                    patterns = [frozenset(cell_ink(column, 1)) for column in range(count)]
                    assert all(patterns) and len(set(patterns)) >= 6, (scheme, mode, 'symbols rendered as repeated missing glyphs')
                    if mode == 'system-symbols':
                        # Spaces use the primary font; fallback glyphs must not
                        # accumulate their wider natural advance between them.
                        for column in (0, 2, 5, 10):
                            assert cell_ink(column, 3), (scheme, 'Braille drifted from cell', column)
                        for column in (1, 3, 4, 6, 7, 8, 9):
                            assert not cell_ink(column, 3), (scheme, 'Braille invaded a space', column)
                    continue
                if mode == "async-echo":
                    assert state["batches"] == state["renderedBatches"] == 10, state
                    assert state["renderedColumn"] == 30 and state["echoToSubmitMs"], state
                    x = math.floor(state["cursorX"] + state["cursorWidth"] / 2)
                    y = math.floor(state["cursorY"] + state["cursorHeight"] - 1)
                    cursor = (40, 102, 178) if scheme == "light" else (145, 191, 255)
                    assert image.getpixel((x, y)) == cursor, (scheme, "asynchronous cursor", image.getpixel((x, y)))
                    continue
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
                if mode == "selection":
                    assert state['selectionText'] == 'GREEN plain selected text\nsecond selected row', state
                    # Sample below the glyphs across fractional-width cell boundaries.
                    # Adjacent selected cells must paint a continuous solid background.
                    for row, start, end in ((1, 6, 24), (2, 0, 18)):
                        y = math.floor(4 + (row + 1) * state['rowHeight'] - 2)
                        colors = [image.getpixel((x, y)) for x in range(
                            math.ceil(8 + (start + .2) * state['cellWidth']),
                            math.floor(8 + (end + .8) * state['cellWidth']))]
                        assert len(set(colors)) == 1, (scheme, 'selection has cell seams', set(colors))
                        tint = state['selectionColor']
                        expected = tuple(round(tint[channel] * 255 * tint['alpha'] + base * (1 - tint['alpha']))
                                         for channel, base in zip(('red', 'green', 'blue'), background))
                        assert all(abs(actual - wanted) <= 3 for actual, wanted in zip(colors[0], expected)), \
                            (scheme, 'selection did not use the editor theme highlight', colors[0], expected)
                    continue
                x = math.floor(state["cursorX"] + state["cursorWidth"] / 2)
                y = math.floor(state["cursorY"] + state["cursorHeight"] / 2)
                active = mode in ("focused", "refocused", "window-refocused")
                assert state["focused"] == active, (scheme, mode, state)
                reports = "\x1b[I" + ("\x1b[O" if mode != "focused" else "") + ("\x1b[I" if mode in ("refocused", "window-refocused") else "")
                assert state["focusReports"] == reports, (scheme, mode, "missing or duplicate VT focus reports", state)
                assert image.getpixel((x, y)) == (foreground if active else background), (scheme, mode, "cursor interior")
                if mode in ("unfocused", "window-blur"):
                    for edge in (state["cursorY"], state["cursorY"] + state["cursorHeight"] - 1):
                        assert image.getpixel((x, math.floor(edge))) == foreground, (scheme, mode, "cursor border")
                if mode == "hidden":
                    assert image.getpixel((x, math.floor(state["cursorY"]))) == background, "Hidden cursor became visible"
            assert images["focused"].tobytes() == images["refocused"].tobytes(), "Refocusing left stale cursor pixels"
            assert images["focused"].tobytes() == images["window-refocused"].tobytes(), "Window activation left stale cursor pixels"
            assert images["unfocused"].tobytes() == images["window-blur"].tobytes(), "Widget and window blur differ"
        artifacts = os.environ.get("TERMINAL_CURSOR_ARTIFACTS")
        if artifacts:
            shutil.copytree(fixture, artifacts, dirs_exist_ok=True)
        print("PASS: terminal symbols, shortcuts, names, cursor focus, asynchronous echo, retained rows and seamless selection in both themes")


if __name__ == "__main__":
    main()
