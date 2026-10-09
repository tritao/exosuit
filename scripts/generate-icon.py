#!/usr/bin/env python3
"""Render Exosuit's vector artwork. Install dependencies: pip install cairosvg pillow.

Run from any directory: python scripts/generate-icon.py
The standalone mark SVG is the source of truth; icon3.png is only a reference.
"""
import argparse
import re
import subprocess
import sys
from io import BytesIO
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "graphical/assets/icons"
SIZES = (16, 24, 32, 48, 64, 128, 256)


def generate_brand(mark):
    """Compile the blue titlebar mark to native vector geometry."""
    svg = ET.fromstring(ET.tostring(mark))
    svg.set("viewBox", "8 9 48 48")
    for child in svg:
        if child.get("fill") is not None:
            child.set("fill", "#4b7ff2")
    artwork = ET.tostring(svg, encoding="unicode") + "\n"
    (ASSETS / "exosuit-brand.svg").write_text(artwork)
    shell, cutouts = [], []
    for child in mark:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag == "path":
            contours = re.findall(r"M[^M]+", child.attrib["d"])
            shell.extend(path_commands(contours[0]))
            for contour in contours[1:]:
                cutouts.extend(path_commands(contour))
        elif tag == "rect":
            values = [child.attrib[name] for name in ("x", "y", "width", "height", "rx")]
            shell.append(".roundRect(" + ", ".join(values) + ")")
        elif tag != "title":
            raise ValueError(f"Unsupported branding element: {tag}")
    lines = ["package ui;", "", "import haxeon.ui.Path;", "import haxeon.ui.PathBuilder;", "",
             "// Generated from exosuit-mark.svg by scripts/generate-icon.py.",
             "class BrandingIconData {"]
    for name, commands in [("createShell", shell), ("createCutouts", cutouts)]:
        lines += [f"\tpublic static function {name}():Path {{", "\t\treturn new PathBuilder()",
                  *["\t\t\t" + command for command in commands], "\t\t\t.build();", "\t}"]
    lines += ["}", ""]
    (ROOT / "graphical/src/ui/BrandingIconData.hx").write_text("\n".join(lines))


def path_commands(contour):
    """Compile the mark's absolute SVG commands to native quadratic/cubic paths."""
    tokens = re.findall(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?", contour)
    counts = {"M": 2, "L": 2, "H": 1, "V": 1, "Q": 4, "C": 6, "Z": 0}
    methods = {"M": "moveTo", "L": "lineTo", "Q": "quadraticTo", "C": "cubicTo", "Z": "close"}
    result, x, y, start = [], "0", "0", ("0", "0")
    while tokens:
        command = tokens.pop(0)
        if command not in counts:
            raise ValueError(f"Unsupported branding SVG command: {command}")
        count = counts[command]
        values, tokens = tokens[:count], tokens[count:]
        if command == "H":
            values, command = [values[0], y], "L"
        elif command == "V":
            values, command = [x, values[0]], "L"
        if command == "Z":
            x, y = start
        else:
            x, y = values[-2:]
            if command == "M":
                start = (x, y)
        result.append("." + methods[command] + "(" + ", ".join(values) + ")")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "icon.png")
    parser.add_argument("--size", type=int, default=1024)
    args = parser.parse_args()
    if not 1 <= args.size <= 4096:
        parser.error("--size must be between 1 and 4096")

    mark = ET.parse(ASSETS / "exosuit-mark.svg").getroot()
    generate_brand(mark)
    geometry = "\n".join(ET.tostring(child, encoding="unicode").strip() for child in mark
                         if child.tag.rsplit("}", 1)[-1] != "title")
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <title>Exosuit application icon</title>
  <defs>
    <linearGradient id="blue" x1="0%" y1="0%" x2="60%" y2="100%">
      <stop offset="0" stop-color="#437bfa"/>
      <stop offset="1" stop-color="#2942cc"/>
    </linearGradient>
  </defs>
  <!-- 29px tile in a 32px canvas, matching the visual weight of taskbar peers. -->
  <g transform="translate(3 3) scale(0.90625)">
    <path fill="url(#blue)" d="M15 0 H49 Q64 0 64 15 V49 Q64 64 49 64
      H15 Q0 64 0 49 V15 Q0 0 15 0 Z"/>
    {geometry}
  </g>
</svg>
'''
    (ASSETS / "exosuit.svg").write_text(svg)
    # Render above target resolution, then filter for consistent antialiasing.
    render_size = max(2048, args.size * 2)
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=render_size,
                          output_height=render_size)
    with Image.open(BytesIO(png)) as rendered:
        source = rendered.convert("RGBA")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        source.resize((args.size, args.size), Image.Resampling.LANCZOS).save(args.output)
        for size in SIZES:
            source.resize((size, size), Image.Resampling.LANCZOS).save(ASSETS / f"exosuit-{size}.png")
    print(f"Generated {args.output}, exosuit.svg, and {len(SIZES)} app icon sizes")
    if args.output.resolve() == ROOT / "icon.png":
        subprocess.run([sys.executable, str(ROOT / "scripts/generate-app-icons.py")], check=True)


if __name__ == "__main__":
    main()
