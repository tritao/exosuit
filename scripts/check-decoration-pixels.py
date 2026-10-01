#!/usr/bin/env python3
"""Checks actual foreground/background decoration pixels in captured editor frames."""
import pathlib
import sys
from PIL import Image


def marks(path):
    image = Image.open(path).convert("RGB")
    red, yellow = [], []
    for y in range(115, min(300, image.height)):
        for x in range(200, image.width):
            r, g, b = image.getpixel((x, y))
            if r > 180 and g < 60 and b < 60:
                red.append((x, y))
            if r > 220 and g > 220 and b < 30:
                yellow.append((x, y))
    return red, yellow


root = pathlib.Path(sys.argv[1])
normal = marks(root / "decorated/frame.png")
moved = marks(root / "moved/frame.png")
cleared = marks(root / "cleared/frame.png")
assert len(normal[0]) >= 10 and len(normal[1]) >= 20, ("missing drawn decorations", [len(v) for v in normal])
assert len(moved[0]) >= 10 and len(moved[1]) >= 20, ("missing moved decorations", [len(v) for v in moved])
assert min(y for _, y in moved[0]) > max(y for _, y in normal[0]), "underline did not move to the next line"
assert not cleared[0] and not cleared[1], ("cleared decorations remain visible", [len(v) for v in cleared])
# The search background must stay below the highlighted keyword's glyphs.
image = Image.open(root / "decorated/frame.png").convert("RGB")
left = min(x for x, _ in normal[1])
right = max(x for x, _ in normal[1])
top = min(y for _, y in normal[1])
bottom = max(y for _, y in normal[1])
keyword_pixels = sum(1 for y in range(top, bottom + 1) for x in range(left, right + 1)
                     if (lambda rgb: rgb[0] > 130 and rgb[1] < 160 and rgb[2] > 150)(image.getpixel((x, y))))
assert keyword_pixels >= 10, "search background covered keyword glyphs"
print("PASS: actual editor wavy underline/search pixels, movement and clearing")


def caret_marks(path):
    image = Image.open(path).convert("RGB")
    cyan, magenta = [], []
    for y in range(115, min(300, image.height)):
        for x in range(200, image.width):
            r, g, b = image.getpixel((x, y))
            if r < 30 and g > 220 and b > 220:
                cyan.append((x, y))
            if r > 220 and g < 30 and b > 220:
                magenta.append((x, y))
    return cyan, magenta


caret = caret_marks(root / "caret/frame.png")
caret_moved = caret_marks(root / "caret-moved/frame.png")
caret_empty = caret_marks(root / "caret-empty/frame.png")
assert len(caret[0]) >= 20 and len(caret[1]) >= 1000, "missing bracket/current-line pixels"
assert max(x for x, _ in caret[1]) - min(x for x, _ in caret[1]) > 500, "current line did not fill editor width"
assert not caret_moved[0] and not caret_empty[0], "stale brackets survived caret movement"
assert len(caret_moved[1]) >= 1000 and len(caret_empty[1]) >= 1000, "empty or moved current line not drawn"
assert min(y for _, y in caret_empty[1]) > max(y for _, y in caret[1]), "current line did not move to empty paragraph"
assert min(y for _, y in caret_moved[1]) > max(y for _, y in caret_empty[1]), "current line did not move to comment paragraph"
print("PASS: actual bracket/current-line pixels, caret movement, empty paragraph and clearing")
