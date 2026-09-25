"""Draw the CareHive app icon, and write the asset catalog around it.

    python ci/make_app_icon.py

The icon is generated rather than hand-drawn in a design tool because the one
thing that matters about it here is that it exists and is complete: the App
Store validator rejects an upload with no `CFBundleIconName`, no 120x120 for
iPhone and no 152x152 for iPad, and it does so at *export* time. Nothing before
that point notices. The simulator build compiles and runs perfectly with no
icon at all, so a missing icon is invisible until the one step that cannot be
re-run cheaply.

That is exactly how this file came to exist.

## The mark

A honeycomb cell, filled white, with a check cut out of it, on honey.

  * The hexagon is the hive -- the family, not the patient. CareHive's whole
    claim is that several people look after one person, and every other
    medication app draws a single-user object (a pill, a bottle, a cross).
  * The check is the fact the app exists to record. It is the same mark the
    app already uses for a dose that has been given (`DS.style(for:)` maps
    `.given` to `checkmark.circle.fill`), so the icon says what the first
    screen says.
  * The colour is deliberately warm. A medication app that arrives in clinical
    blue is telling the family it is a medical instrument; this one is a
    shared family record, and amber is the only colour in the palette that
    reads as household rather than hospital.

The check is *cut out* rather than drawn in a second colour, so the mark is
literally the background showing through. Two colours, no shading, and the
gradient does the work that a second ink would have done.

## Sizes

The full traditional set, not the modern single 1024.

A single-size catalog is the current recommendation and actool does derive the
rest -- but the validator's complaint named two specific pixel sizes in words
("exactly '120x120' pixels", "exactly '152x152' pixels"), and the cheapest way
to be certain that complaint is answered is to put those two files in the
bundle rather than to reason about a build step that generates them. The set
below is a few kilobytes.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "Resources" / "Assets.xcassets"
ICONSET = CATALOG / "AppIcon.appiconset"

# Drawn large and reduced, because the whole mark is four straight edges and a
# mitre joint. At 1024 the hexagon's corners are visibly stepped; at 4096 with
# a LANCZOS reduction they are not.
CANVAS = 4096
FINAL = 1024

# Honey. Dark enough at the bottom that white stays legible on it, light enough
# at the top that the mark reads as warm rather than as a warning.
HONEY_TOP = (255, 190, 74)
HONEY_BOTTOM = (214, 122, 12)
MARK = (255, 255, 255)

# The flat-top hexagon: vertices left and right, edges along the top and
# bottom. Chosen over the pointy-top cell for one reason -- a check is wider
# than it is tall, and this orientation is the one with room for it.
HEX_RADIUS = 0.300 * CANVAS
STROKE = 0.140 * HEX_RADIUS


def hexagon(cx: float, cy: float, r: float) -> list[tuple[float, float]]:
    """A regular hexagon, flat-top, circumradius `r`."""
    return [(cx + r * math.cos(math.radians(a)),
             cy + r * math.sin(math.radians(a)))
            for a in (0, 60, 120, 180, 240, 300)]


def draw_mark() -> Image.Image:
    """The white area: the cell, minus the check."""
    size = (CANVAS, CANVAS)
    c = CANVAS / 2
    r = HEX_RADIUS

    cell = Image.new("L", size, 0)
    ImageDraw.Draw(cell).polygon(hexagon(c, c, r), fill=255)

    # Three points and a mitre, sized against the hexagon rather than the
    # canvas so the mark keeps its proportions if the hexagon is ever resized.
    # The down-stroke is short and the up-stroke long, which is what makes a
    # check read as a check rather than as a tick the eye has to finish.
    p1 = (c - 0.36 * r, c + 0.00 * r)
    p2 = (c - 0.11 * r, c + 0.25 * r)
    p3 = (c + 0.38 * r, c - 0.25 * r)

    check = Image.new("L", size, 0)
    d = ImageDraw.Draw(check)
    d.line([p1, p2, p3], fill=255, width=int(STROKE), joint="curve")
    # Round caps. `joint="curve"` rounds the middle vertex but says nothing
    # about the two ends, and a square-cut end on the long stroke is the
    # difference between a mark and a piece of typography.
    for x, y in (p1, p3):
        d.ellipse([x - STROKE / 2, y - STROKE / 2,
                   x + STROKE / 2, y + STROKE / 2], fill=255)

    return ImageChops.subtract(cell, check)


def draw_background() -> Image.Image:
    """The honey gradient."""
    img = Image.new("RGB", (1, CANVAS))
    px = img.load()
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        px[0, y] = tuple(
            round(a + (b - a) * t) for a, b in zip(HONEY_TOP, HONEY_BOTTOM))
    return img.resize((CANVAS, CANVAS), Image.NEAREST)


def render() -> Image.Image:
    art = draw_background()
    art.paste(Image.new("RGB", art.size, MARK), mask=draw_mark())
    # `.convert("RGB")` on the way out is not cosmetic: the App Store rejects
    # an icon whose PNG carries an alpha channel, and PIL is happy to write
    # one for a mode-"RGB" image the moment a mask has been composited into it.
    return art.resize((FINAL, FINAL), Image.LANCZOS).convert("RGB")


# (idiom, point size, scale, pixels). Pixel size is the only thing the
# validator looks at; the rest is bookkeeping that actool requires.
SIZES: list[tuple[str, str, int, int]] = [
    ("iphone", "20x20", 2, 40),
    ("iphone", "20x20", 3, 60),
    ("iphone", "29x29", 2, 58),
    ("iphone", "29x29", 3, 87),
    ("iphone", "40x40", 2, 80),
    ("iphone", "40x40", 3, 120),   # named by the validator
    ("iphone", "60x60", 2, 120),
    ("iphone", "60x60", 3, 180),
    ("ipad", "20x20", 1, 20),
    ("ipad", "20x20", 2, 40),
    ("ipad", "29x29", 1, 29),
    ("ipad", "29x29", 2, 58),
    ("ipad", "40x40", 1, 40),
    ("ipad", "40x40", 2, 80),
    ("ipad", "76x76", 1, 76),
    ("ipad", "76x76", 2, 152),     # named by the validator
    ("ipad", "83.5x83.5", 2, 167),
    ("ios-marketing", "1024x1024", 1, 1024),
]

CONTENTS_HEADER = {
    "info": {"author": "ci/make_app_icon.py", "version": 1},
}


def main() -> int:
    ICONSET.mkdir(parents=True, exist_ok=True)

    art = render()
    # One file per distinct pixel size. 120 appears twice in the table (iPhone
    # 40@3x and 60@2x) and 40 three times; writing each size once and pointing
    # several entries at it is both smaller and one less thing to keep in sync.
    written: dict[int, str] = {}
    for px in sorted({s[3] for s in SIZES}):
        name = f"AppIcon-{px}.png"
        art.resize((px, px), Image.LANCZOS).save(ICONSET / name, "PNG")
        written[px] = name
        print(f"  {name}")

    images = [
        {"idiom": idiom, "size": size, "scale": f"{scale}x",
         "filename": written[px]}
        for idiom, size, scale, px in SIZES
    ]
    (ICONSET / "Contents.json").write_text(
        json.dumps({"images": images, **CONTENTS_HEADER}, indent=2) + "\n",
        encoding="utf-8")

    (CATALOG / "Contents.json").write_text(
        json.dumps(CONTENTS_HEADER, indent=2) + "\n", encoding="utf-8")

    alpha = art.mode
    print(f"\n{ICONSET}")
    print(f"  {len(written)} files, mode {alpha} (RGB -- the store rejects alpha)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
