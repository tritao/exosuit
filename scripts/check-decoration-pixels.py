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
print("PASS: actual editor wavy underline/search pixels, movement and clearing")
