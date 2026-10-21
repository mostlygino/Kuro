#!/usr/bin/env python3
"""Builds docs/anatomy.png: both ends of the bar with every part labelled.

    python3 docs/make_anatomy.py

Takes the two bar screenshots in docs/ and draws callouts under them. The x
positions are where each part sits in those screenshots (2x pixels); retake the
screenshots and these may need nudging.
"""

import pathlib

from PIL import Image, ImageDraw, ImageFont

DOCS = pathlib.Path(__file__).resolve().parent
FONT = "/System/Library/Fonts/SFNS.ttf"

BG = (8, 8, 9)
LINE = (70, 70, 74)
TITLE = (245, 245, 247)
NOTE = (142, 142, 147)
DOT = {"purple": (191, 90, 242), "orange": (217, 119, 87), "green": (50, 215, 75), "amber": (255, 159, 10),
       "white": (245, 245, 247)}

# (x in the screenshot, title, note, accent) for each strip.
LEFT = [
    (120, "Workspaces", "per screen, darker when empty", "white"),
    (290, "Focused app", "with its own icon", "white"),
    (450, "Now Playing", "a record at 60 fps, a mark per service", "white"),
    (720, "Title and artist", "measured to fit", "white"),
]
RIGHT = [
    (512, "Keep awake", "the capsule snaps shut and fills", "amber"),
    (576, "Claude usage", "rays go out as the session is spent", "orange"),
    (640, "Tailscale", "connect and disconnect", "green"),
    (712, "Wi-Fi", "four dots, lit to the signal", "white"),
    (788, "Battery", "a ring in green, amber or red", "green"),
    (919, "Clock", "right-click for the date and the month", "white"),
]

PAD = 56
ROW_GAP = 36
# Only the pills: the screenshots carry a band of wallpaper either side.
LEFT_CROP = (0, 0, 1090, 104)
RIGHT_CROP = (456, 0, 1000, 104)


def font(size, weight="Regular"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


TIER = 42


def strip(canvas, draw, image, origin, callouts):
    ox, oy = origin
    canvas.paste(image, (ox, oy))
    title_font, note_font = font(24, "Semibold"), font(19)
    base = oy + image.height + 18
    # The rightmost part gets the shortest leader. Every label runs rightwards
    # from its own leader, so this way no leader ever crosses a label.
    for i, (x, title, note, accent) in enumerate(callouts):
        cx = ox + x
        tier = len(callouts) - 1 - i
        ty = base + 22 + tier * TIER
        # A leader from the part down to its label, ending in a small dot.
        draw.line([(cx, oy + image.height - 6), (cx, ty - 6)], fill=LINE, width=2)
        draw.ellipse((cx - 5, ty - 11, cx + 5, ty - 1), fill=DOT[accent])
        draw.text((cx + 14, ty - 20), title, font=title_font, fill=TITLE)
        width = draw.textlength(title, font=title_font)
        draw.text((cx + 22 + width, ty - 16), note, font=note_font, fill=NOTE)


def main():
    left = Image.open(DOCS / "bar-left.png").convert("RGB").crop(LEFT_CROP)
    right = Image.open(DOCS / "bar-right.png").convert("RGB").crop(RIGHT_CROP)
    right_callouts = [(x - RIGHT_CROP[0], *rest) for x, *rest in RIGHT]
    left_h = left.height + 18 + 22 + TIER * len(LEFT)
    right_h = right.height + 18 + 22 + TIER * len(RIGHT)
    width = 1180
    height = PAD * 2 + left_h + ROW_GAP + right_h
    canvas = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(canvas)

    strip(canvas, draw, left, (PAD, PAD), LEFT)
    strip(canvas, draw, right, (PAD, PAD + left_h + ROW_GAP), right_callouts)

    canvas.save(DOCS / "anatomy.png", optimize=True)
    print(f"wrote docs/anatomy.png: {width}x{height}")


if __name__ == "__main__":
    main()
