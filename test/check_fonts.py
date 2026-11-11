"""Check the fonts that glyphs-export-action exported in CI.

Usage: check_fonts.py COMPONENT FILE_NAME...

Reads the action's `fonts` and `output-dir` outputs from the FONTS and
OUTPUT_DIR environment variables. Checks that every expected file was
exported into the output folder, that every exported font opens, and that
glyph C in TrueType fonts uses COMPONENT: B as drawn in the test sources,
or A after the UnnestComponents filter has run.
"""

import os
import sys

from fontTools.ttLib import TTFont


def main(component, expected):
    output_dir = os.environ["OUTPUT_DIR"]
    fonts = os.environ["FONTS"].splitlines()
    problems = []

    missing = sorted(set(expected) - {os.path.basename(path) for path in fonts})
    if missing:
        problems.append(f"not exported: {', '.join(missing)}")

    for path in fonts:
        if os.path.dirname(path) != output_dir:
            problems.append(f"{path} is not in {output_dir}")
        font = TTFont(path)
        glyphs = font.getGlyphOrder()
        absent = [name for name in "ABC" if name not in glyphs]
        if absent:
            problems.append(f"{path} has no glyph {', '.join(absent)}")
        elif "glyf" in font:
            components = [c.glyphName for c in font["glyf"]["C"].components]
            if components != [component]:
                problems.append(f"{path}: C uses {components}, expected [{component!r}]")
        print(f"ok  {path} ({len(glyphs)} glyphs)")

    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2:]))
