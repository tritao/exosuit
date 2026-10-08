#!/usr/bin/env python3
"""Generate icon design studies without changing the app icon.

Requires cairosvg and Pillow. Outputs SVGs, PNGs, and a comparison sheet under
out/icon-variants. Pass --reference /path/to/code.png to include a comparison.
"""
import argparse
from io import BytesIO
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out/icon-variants"

# Rounded, generously spaced code cutouts, shared by the two solid shells.
CUTOUTS = '''
 M24 30 Q25 29 26 30 Q27 31 26 32 L22 36 L26 40
 Q27 41 26 42 Q25 43 24 42 L18.5 37.5 Q17 36 18.5 34.5 Z
 M40 30 Q39 29 38 30 Q37 31 38 32 L42 36 L38 40
 Q37 41 38 42 Q39 43 40 42 L45.5 37.5 Q47 36 45.5 34.5 Z
 M33.5 28.5 Q34.2 27 35.7 27.7 Q37.2 28.4 36.5 29.9
 L30.5 43.5 Q29.8 45 28.3 44.3 Q26.8 43.6 27.5 42.1 Z
'''

VARIANTS = {
    "A": ("Simplified suit", f'''<path fill="white" fill-rule="evenodd" d="
      M25 15 L17 20 Q15 21 15 23 L15 27 L12 29 Q11 30 11 32
      L11 43 Q11 45 13 46 L29 55 Q32 57 35 55 L51 46
      Q53 45 53 43 L53 32 Q53 30 52 29 L49 27 L49 23
      Q49 21 47 20 L39 15 L39 23 Q39 25 37 25 H27
      Q25 25 25 23 Z {CUTOUTS}"/>
      <rect x="29" y="11" width="6" height="11" rx="1.8" fill="white"/>'''),
    "B": ("Code shield", f'''<path fill="white" fill-rule="evenodd" d="
      M29 14 Q32 12 35 14 L48 21 Q50 22 50 25 V41
      Q50 45 47 47 L35 54 Q32 56 29 54 L17 47
      Q14 45 14 41 V25 Q14 22 16 21 Z {CUTOUTS}"/>'''),
    "C": ("Open exoframe", '''<g fill="none" stroke="white" stroke-width="5"
      stroke-linecap="round" stroke-linejoin="round">
      <path d="M24 17 L15 23 V43 L24 49 M40 17 L49 23 V43 L40 49"/>
      <path d="M25 28 L19 34 L25 40 M39 28 L45 34 L39 40" stroke-width="3.5"/>
      <path d="M35 26 L29 42" stroke-width="3.5"/>
      <path d="M32 14 V20 M28 51 L32 54 L36 51" stroke-width="4"/>
      </g>'''),
}


def render(mark):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
      <defs><linearGradient id="blue" x1="0" y1="0" x2="0.6" y2="1">
      <stop stop-color="#437bfa"/><stop offset="1" stop-color="#2942cc"/>
      </linearGradient></defs>
      <path fill="url(#blue)" d="M15 0 H49 Q64 0 64 15 V49 Q64 64 49 64
        H15 Q0 64 0 49 V15 Q0 0 15 0 Z"/>{mark}</svg>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--reference-box", type=int, nargs=4, metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"),
                        help="Crop a reference tile from a screenshot; compare at its native size")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    images = []
    if args.reference:
        reference = Image.open(args.reference).convert("RGBA")
        if args.reference_box:
            reference = reference.crop(tuple(args.reference_box))
        images.append(("VS Code", reference))
    images.append(("Current", Image.open(ROOT / "icon.png").convert("RGBA")))
    for key, (label, mark) in VARIANTS.items():
        svg = render(mark)
        (OUT / f"variant-{key}.svg").write_text(svg + "\n")
        im = Image.open(BytesIO(cairosvg.svg2png(bytestring=svg.encode(),
                            output_width=1024, output_height=1024))).convert("RGBA")
        im.save(OUT / f"variant-{key}.png")
        images.append((f"{key}  {label}", im))
    font = ImageFont.truetype("DejaVuSans.ttf", 15)
    sheet = Image.new("RGB", (790, 60 + len(images) * 166), "#25262b")
    draw = ImageDraw.Draw(sheet)
    columns = [(235, 16), (295, 24), (365, 32), (445, 48), (595, 128)]
    for x, size in columns:
        draw.text((x, 22), f"{size} px", font=font, fill="#b9bdc9")
    for row, (label, im) in enumerate(images):
        y = 60 + row * 166
        draw.text((20, y + 61), label, font=font, fill="#f0f2f8")
        for x, size in columns:
            if label == "VS Code" and args.reference_box and size > 32:
                draw.text((x, y + 61), "—", font=font, fill="#707582")
                continue
            icon = im.resize((size, size), Image.Resampling.LANCZOS)
            sheet.paste(icon, (x, y + (148 - size) // 2), icon)
            if label not in ("VS Code", "Current"):
                icon.save(OUT / f"variant-{label[0]}-{size}.png")
    sheet.save(OUT / "comparison.png")
    print(OUT / "comparison.png")


if __name__ == "__main__":
    main()
