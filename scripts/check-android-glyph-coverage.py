#!/usr/bin/env python3
"""Check that the terminal symbols Claude Code and other TUIs print have a glyph on Android.

  adb pull /system/fonts <dir>
  python3 scripts/check-android-glyph-coverage.py <dir>/fonts

The fonts are the ones the text engine offers as fallbacks (haxeon/packages/ui/src/prepare/system_fonts.cpp). A
symbol passes when one of them has it, or when graphical/src/ui/TerminalGlyphs.hx replaces it by a character one
of them has. Needs fontTools.
"""
import re
import sys
from pathlib import Path

from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
FALLBACKS = ["NotoSansSymbols-Regular-Subsetted.ttf", "NotoSansSymbols-Regular-Subsetted2.ttf", "Roboto-Regular.ttf",
             "DroidSansMono.ttf"]
# Mode line, tool results, spinners, prompts, boxes and arrows as Claude Code draws them.
USED = [0x23F5, 0x23F8, 0x23F9, 0x23FA, 0x23F4, 0x23BF, 0x273B, 0x273D, 0x2733, 0x2722, 0x2736, 0x25CF, 0x25CB, 0x25D0,
        0x25D1, 0x25CE, 0x26A0, 0x276F, 0x2192, 0x2190, 0x2191, 0x2193, 0x21B3, 0x2026, 0x2713, 0x2717, 0x2500, 0x2502,
        0x256D, 0x256E, 0x2570, 0x256F, 0x2514, 0x251C, 0x2588, 0x2591, 0x25B6, 0x25C0, 0x25A0, 0x2605, 0x2234, 0x2398]


def main(directory):
    covered = {}
    for name in FALLBACKS:
        path = Path(directory) / name
        if path.exists():
            for code in TTFont(path, lazy=True).getBestCmap():
                covered.setdefault(code, name)
    source = (ROOT / "graphical/src/ui/TerminalGlyphs.hx").read_text(encoding="utf-8")
    stand_ins = {int(a, 16): int(b, 16) for a, b in re.findall(r"0x([0-9A-Fa-f]{4}) => 0x([0-9A-Fa-f]{4})", source)}
    failures = []
    for code in USED:
        shown = stand_ins.get(code, code)
        if shown not in covered:
            failures.append("U+%04X (drawn as U+%04X) has no glyph" % (code, shown))
    for code, shown in stand_ins.items():
        if code in covered:
            failures.append("U+%04X is covered by %s; drop its stand-in" % (code, covered[code]))
    if failures:
        raise SystemExit("\n".join(failures))
    print("PASS: %d symbols covered, %d through stand-ins" % (len(USED), len([c for c in USED if c in stand_ins])))


if __name__ == "__main__":
    main(sys.argv[1])
