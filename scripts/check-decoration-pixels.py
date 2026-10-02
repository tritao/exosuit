#!/usr/bin/env python3
"""Checks actual foreground/background decoration pixels in captured editor frames."""
import pathlib
import json
import sys
from PIL import Image


def editor_pixels(path):
    nodes = json.loads(path.with_name("layout.json").read_text())
    by_id = {node["id"]: node for node in nodes}
    editors = [node for node in nodes if node.get("styleType") == "text-field"]
    assert len(editors) == 1, "pixel fixture must contain one text editor"
    editor = editors[0]
    ancestor = editor
    while ancestor.get("styleType") != "scroll-view":
        ancestor = by_id[ancestor["parentId"]]
    bounds = ancestor["bounds"]
    return (range(int(editor["bounds"]["x"]), int(bounds["x"] + bounds["width"])),
            range(int(bounds["y"]), int(bounds["y"] + bounds["height"])))


def marks(path):
    image = Image.open(path).convert("RGB")
    red, yellow = [], []
    xs, ys = editor_pixels(path)
    for y in ys:
        for x in xs:
            r, g, b = image.getpixel((x, y))
            if r > 180 and g < 60 and b < 60:
                red.append((x, y))
            if r > 220 and g > 220 and b < 30:
                yellow.append((x, y))
    return red, yellow


root = pathlib.Path(sys.argv[1])
gutter_image = Image.open(root / "gutter-aligned/frame.png").convert("RGB")
gutter_geometry = json.loads((root / "state-gutter-aligned/gutter-baselines.json").read_text())
baselines = gutter_geometry["baselines"]
assert len(baselines) >= 8, "gutter fixture has insufficient visible logical lines"
red_rows = []
for y in range(int(min(baselines) - 12), int(max(baselines) + 2)):
    if any((lambda c: c[0] > 120 and c[1] < 50 and c[2] < 50)(gutter_image.getpixel((x, y)))
           for x in range(int(gutter_geometry["left"]), int(gutter_geometry["right"]))):
        red_rows.append(y)
        assert any(baseline - 12 <= y <= baseline + 1 for baseline in baselines), \
            ("line number painted between logical lines", y, baselines)
for baseline in baselines:
    assert any(baseline - 2 <= y <= baseline + 1 for y in red_rows), \
        ("line number baseline diverged from editor text", baseline, red_rows)
assert max(b - a for a, b in zip(baselines, baselines[1:])) > 50, \
    "gutter fixture did not exercise a wrapped logical line"
print("PASS: gutter baselines follow shaped text after wrapping, blank lines, scrolling and edits")
clip_image = Image.open(root / "selection-clipped/frame.png").convert("RGB")
clip_bounds = json.loads((root / "state-selection-clipped/editor-bounds.json").read_text())
selection_pixels = 0
for y in range(clip_image.height):
    for x in range(clip_image.width):
        r, g, b = clip_image.getpixel((x, y))
        if r < 30 and g > 220 and b < 30:
            selection_pixels += 1
            assert (clip_bounds["x"] <= x < clip_bounds["x"] + clip_bounds["width"] and
                    clip_bounds["y"] <= y < clip_bounds["y"] + clip_bounds["height"]), \
                ("selection painted outside editor viewport", x, y, clip_bounds)
assert selection_pixels > 1000, "clipping test did not paint a substantial selection"
print("PASS: long-document selection pixels remain inside the editor viewport")
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
    xs, ys = editor_pixels(path)
    for y in ys:
        for x in xs:
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


def green_rows(path):
    image = Image.open(path).convert("RGB")
    rows = {}
    xs, ys = editor_pixels(path)
    for y in ys:
        count = sum(1 for x in xs
                    if (lambda rgb: rgb[1] > 100 and rgb[1] > 2 * rgb[0] and rgb[1] > 2 * rgb[2])(image.getpixel((x, y))))
        if count:
            rows[y] = count
    return rows


selected = green_rows(root / "multi-selected/frame.png")
typed = green_rows(root / "multi-typed/frame.png")
for rows, minimum in ((selected, 10), (typed, 1)):
    assert rows and max(rows) - min(rows) >= 35, ("selection/caret pixels do not span both text rows", rows)
    middle = (min(rows) + max(rows)) // 2
    assert max(count for y, count in rows.items() if y <= middle) >= minimum, "missing first selection/caret"
    assert max(count for y, count in rows.items() if y > middle) >= minimum, "missing second selection/caret"
print("PASS: actual additional selection and multi-caret pixels after transactional typing/undo")

# Closing a multiline comment must repair the following keyword row. Undo
# restores its comment color after both generations have been rendered.
def keyword_rows(path):
    image = Image.open(path).convert("RGB")
    rows = {}
    xs, ys = editor_pixels(path)
    for y in ys:
        count = sum(1 for x in xs
                    if (lambda rgb: rgb[0] > 130 and rgb[1] < 160 and rgb[2] > 150
                        and rgb[2] > rgb[1] * 1.2)(image.getpixel((x, y))))
        if count >= 2:
            rows[y] = count
    return rows

syntax_open = keyword_rows(root / "syntax-open/frame.png")
syntax_closed = keyword_rows(root / "syntax-closed/frame.png")
syntax_restored = keyword_rows(root / "syntax-restored/frame.png")
assert syntax_open and syntax_closed, "missing syntax keyword pixels"
assert min(syntax_closed) < min(syntax_open) - 20, "closing comment did not recolor the following row"
assert syntax_restored == syntax_open, "undo left stale keyword colors inside the multiline comment"
print("PASS: actual multiline syntax colors repair after boundary edit and undo")
