#!/usr/bin/env python3
"""Render Exosuit's vector artwork. Install dependencies: pip install cairosvg pillow.

Run from any directory: python scripts/generate-icon.py
The standalone mark SVG is the source of truth; icon3.png is only a reference.
"""
import argparse
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "icon.png")
    parser.add_argument("--size", type=int, default=1024)
    args = parser.parse_args()
    if not 1 <= args.size <= 4096:
        parser.error("--size must be between 1 and 4096")

    mark = ET.parse(ASSETS / "exosuit-mark.svg").getroot()
    geometry = "\n".join(ET.tostring(child, encoding="unicode").strip() for child in mark
                         if child.tag.rsplit("}", 1)[-1] != "title")
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1254 1254">
  <title>Exosuit application icon</title>
  <defs>
    <path id="tile" d="M 300,0 H 954 C 1164,0 1254,90 1254,300
      V 954 C 1254,1164 1164,1254 954,1254 H 300
      C 90,1254 0,1164 0,954 V 300 C 0,90 90,0 300,0 Z"/>
    <clipPath id="tile-clip"><use href="#tile"/></clipPath>
    <linearGradient id="blue" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0" stop-color="#4778ff"/>
      <stop offset="0.46" stop-color="#3048f4"/>
      <stop offset="1" stop-color="#17118e"/>
    </linearGradient>
    <radialGradient id="light" cx="22%" cy="8%" r="85%">
      <stop offset="0" stop-color="#a7c8ff" stop-opacity="0.25"/>
      <stop offset="1" stop-color="#a7c8ff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="edge" x1="0%" y1="0%" x2="25%" y2="100%">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.38"/>
      <stop offset="0.45" stop-color="#ffffff" stop-opacity="0.08"/>
      <stop offset="1" stop-color="#08084b" stop-opacity="0.22"/>
    </linearGradient>
    <g id="emblem">{geometry}</g>
    <!-- Layered offsets keep the soft shadow portable across SVG renderers. -->
    <mask id="emblem-mask" maskUnits="userSpaceOnUse"
          x="0" y="0" width="1254" height="1254">
      <use href="#emblem"/>
    </mask>
  </defs>
  <use href="#tile" fill="url(#blue)"/>
  <use href="#tile" fill="url(#light)"/>
  <g clip-path="url(#tile-clip)">
    <use href="#tile" fill="none" stroke="url(#edge)" stroke-width="5"/>
    <g fill="#080d61">
      <rect width="1254" height="1254" mask="url(#emblem-mask)"
            transform="translate(0 10)" opacity="0.045"/>
      <rect width="1254" height="1254" mask="url(#emblem-mask)"
            transform="translate(0 7)" opacity="0.055"/>
      <rect width="1254" height="1254" mask="url(#emblem-mask)"
            transform="translate(0 4)" opacity="0.07"/>
    </g>
    <use href="#emblem"/>
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
