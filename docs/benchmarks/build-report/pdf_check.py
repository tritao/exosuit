"""Checks a printed report: every text the rendered page shows is in the PDF, and nothing lies outside a page.

Usage: python -I pdf_check.py <rendered dom.html> <report.pdf> [<png dir>]

<rendered dom.html> is the page after its scripts ran (Edge --dump-dom), so chart and diagram labels count too.
Texts are compared with all whitespace removed, since the PDF wraps lines (and breaks long words) where the page
did not. A text that is not found whole is checked word by word. Exit 1 when anything is missing or clipped.
With a PNG directory, every page is also rendered there at 60 dpi for a look.
"""

import re
import sys
from html.parser import HTMLParser
from pathlib import Path

import pymupdf

SKIP = {"script", "style", "title", "head", "noscript"}


class Texts(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.texts = []

    def handle_starttag(self, tag, attrs):
        if tag not in ("br", "img", "meta", "link", "input", "hr", "wbr"):
            self.stack.append(tag)

    def handle_endtag(self, tag):
        while self.stack:
            if self.stack.pop() == tag:
                break

    def handle_data(self, data):
        if any(t in SKIP for t in self.stack):
            return
        text = " ".join(data.split())
        if text:
            self.texts.append(text)


def squash(text):
    return re.sub(r"\s+", "", text).replace("­", "")


def main():
    dom, pdf_path = Path(sys.argv[1]), Path(sys.argv[2])
    parser = Texts()
    parser.feed(dom.read_text(encoding="utf-8", errors="replace"))
    doc = pymupdf.open(pdf_path)
    pdf_text = "".join(page.get_text() for page in doc)
    flat = squash(pdf_text)
    missing, partial = [], 0
    for text in parser.texts:
        if squash(text) in flat:
            continue
        words = [w for w in text.split() if squash(w) not in flat]
        if words:
            missing.append((text, words))
        else:
            partial += 1
    clipped = []
    for number, page in enumerate(doc, 1):
        box = page.rect
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                for span in line["spans"]:
                    x0, y0, x1, y1 = span["bbox"]
                    if span["text"].strip() and (x0 < -1 or y0 < -1 or x1 > box.x1 + 1 or y1 > box.y1 + 1):
                        clipped.append((number, span["text"][:60], [round(v) for v in span["bbox"]]))
    if len(sys.argv) > 3:
        out = Path(sys.argv[3])
        out.mkdir(parents=True, exist_ok=True)
        for number, page in enumerate(doc, 1):
            page.get_pixmap(dpi=60).save(out / f"p{number:02d}.png")
    print(f"{len(doc)} pages ({doc[0].rect.width:.0f} x {doc[0].rect.height:.0f} pt); {len(parser.texts)} page texts; "
          f"{len(parser.texts) - len(missing)} found ({partial} only word by word); {len(missing)} missing; {len(clipped)} spans outside a page")
    for text, words in missing[:40]:
        print(f"  missing: {text[:100]!r} (words not found: {' '.join(words)[:80]})")
    for item in clipped[:20]:
        print("  outside page:", item)
    return 1 if missing or clipped else 0


if __name__ == "__main__":
    sys.exit(main())
