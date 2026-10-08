#!/usr/bin/env python3
"""Embed icon2.png as NativeKit RGBA icons. Requires Pillow; rerun after artwork changes."""
from pathlib import Path
import base64
from PIL import Image

root = Path(__file__).resolve().parent.parent
sizes = (16, 24, 32, 48, 64, 128, 256)
with Image.open(root / "icon2.png") as source:
    image = source.convert("RGBA")
    data = b"".join(image.resize((size, size), Image.Resampling.LANCZOS).tobytes() for size in sizes)
encoded = base64.b64encode(data).decode("ascii")
lines = [
    "package app;", "",
    "import haxe.crypto.Base64;",
    "import haxeon.ui.host.ApplicationIconSet;",
    "import haxeon.ui.host.WindowIcon;", "",
    "// Generated from icon2.png by scripts/generate-app-icons.py.",
    "// Embedded so packaged apps and launches from other directories use the same icon.",
    "class ApplicationIcons {",
    "\tpublic static function create():ApplicationIconSet {",
    '\t\tvar pixels = Base64.decode([',
    *['\t\t\t"' + encoded[offset:offset + 4096] + '",' for offset in range(0, len(encoded), 4096)],
    '\t\t].join(""));',
    "\t\tvar images:Array<WindowIcon> = [];",
    "\t\tvar offset = 0;",
    "\t\tfor (size in [" + ", ".join(map(str, sizes)) + "]) {",
    "\t\t\tvar length = size * size * 4;",
    "\t\t\timages.push(new WindowIcon(size, size, size * 4, pixels.sub(offset, length)));",
    "\t\t\toffset += length;",
    "\t\t}",
    "\t\treturn new ApplicationIconSet(images);",
    "\t}", "}", "",
]
(root / "graphical/src/app/ApplicationIcons.hx").write_text("\n".join(lines))
print(f"Embedded {len(sizes)} icon sizes ({len(data)} RGBA bytes)")
