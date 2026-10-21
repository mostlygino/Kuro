#!/usr/bin/env python3
"""Builds docs/states.png, every state of every badge, and docs/marks.png,
every shape the Now Playing slot can show, both drawn by the bar's own code.

    python3 docs/make_states.py

Like the GIF, nothing here is a screenshot. Each cell is a renderer's own
still, the same PNG the bar shows, set on a pill, so the sheet is exactly as
sharp as the bar and can be rebuilt whenever a mark changes. Needs Pillow and
the renderers built (the bar builds them on first run).
"""

import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / "sketchybar" / "assets"
OUT = ROOT / "docs" / "states.png"
MARKS_OUT = ROOT / "docs" / "marks.png"
MEDIAWATCH = ASSETS / "mediawatch.app" / "Contents" / "MacOS" / "mediawatch"
FONT = "/System/Library/Fonts/SFNS.ttf"

BG = (8, 8, 9)
PILL = (28, 28, 30)
EDGE = (70, 70, 74)
TITLE = (245, 245, 247)
NOTE = (142, 142, 147)

GREEN, AMBER, RED, GREY = "0xff32d74b", "0xffff9f0a", "0xffff453a", "0xff8e8e93"
ORANGE, PURPLE = "0xffd97757", "0xffbf5af2"
DOTS = ["0xffff9f0a", "0xffff6ac1", "0xff64d2ff", "0xffbf5af2"]

# Each row: a badge, and its states as (renderer, arguments, caption).
ROWS = [
    ("Keep awake", [
        ("capsulemark", ["--state", "off"], "off"),
        ("capsulemark", ["--state", "on"], "on"),
    ]),
    ("Claude", [
        ("usagemark", ["--percent", "100", "--color", ORANGE], "fresh"),
        ("usagemark", ["--percent", "50", "--color", ORANGE], "half spent"),
        ("usagemark", ["--percent", "8", "--color", RED], "nearly out"),
        ("usagemark", ["--error"], "unreachable"),
        ("usagemark", ["--blocked"], "week spent"),
    ]),
    ("Tailscale", [
        ("vpnmark", ["--state", "up"], "connected"),
        ("vpnmark", ["--state", "pending"], "connecting"),
        ("vpnmark", ["--state", "attention"], "needs login"),
        ("vpnmark", ["--state", "down"], "off"),
    ]),
    ("Wi-Fi", [
        ("wifimark", ["--dots", "4", "--color", DOTS[3]], "excellent"),
        ("wifimark", ["--dots", "3", "--color", DOTS[2]], "good"),
        ("wifimark", ["--dots", "2", "--color", DOTS[1]], "fair"),
        ("wifimark", ["--dots", "1", "--color", DOTS[0]], "weak"),
        ("wifimark", ["--dots", "3", "--color", RED], "no internet"),
        ("wifimark", ["--dots", "0", "--color", GREY, "--off"], "off"),
        ("wifimark", ["--ethernet", "--color", DOTS[3]], "cable"),
    ]),
    ("Battery", [
        ("batterymark", ["--percent", "84", "--color", GREEN], "on battery"),
        ("batterymark", ["--percent", "62", "--color", GREEN, "--charging"], "charging"),
        ("batterymark", ["--percent", "28", "--color", AMBER], "low"),
        ("batterymark", ["--percent", "9", "--color", RED], "critical"),
    ]),
    ("Vitals", [
        ("vitalsmark", ["--level", "0", "--tone", "calm"], "idle"),
        ("vitalsmark", ["--level", "1", "--tone", "calm"], "light"),
        ("vitalsmark", ["--level", "2", "--tone", "calm"], "working"),
        ("vitalsmark", ["--level", "3", "--tone", "calm"], "heavy"),
        ("vitalsmark", ["--level", "4", "--tone", "calm"], "maxed out"),
        ("vitalsmark", ["--level", "0", "--tone", "dead"], "not running"),
    ]),
    ("OrbStack", [
        ("orbmark", ["--color", PURPLE], "running"),
        ("orbmark", ["--color", GREY], "idle"),
    ]),
    ("Empty display", [
        ("voidmark", [], "the void"),
    ]),
]

S = 2              # the stills are drawn at two pixels per point
LABEL_W = 170 * S
CELL_W = 92 * S
ROW_H = 64 * S
PAD = 34 * S


def font(size, weight="Regular"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


# The Now Playing slot, grouped the way the pill decides: by what is playing.
MARK_ROWS = [
    ("Music and podcasts", [("music", "music"), ("podcast", "podcast"), ("silence", "silence")]),
    ("In the browser", [("youtube", "YouTube"), ("youtubeMusic", "YT Music"), ("netflix", "Netflix"),
                        ("disney", "Disney+"), ("prime", "Prime Video"), ("twitch", "Twitch"),
                        ("vimeo", "Vimeo"), ("appleTV", "Apple TV"), ("soundcloud", "SoundCloud"),
                        ("spotifyWeb", "Spotify"), ("appleMusicWeb", "Apple Music")]),
    ("Apps and calls", [("com.apple.TV", "TV app"), ("com.apple.QuickTimePlayerX", "QuickTime"),
                        ("video", "other video"), ("call", "a call"), ("browser", "other tab")]),
]


def sheet(rows, cell_w, stills, out):
    """A pill per row with its marks and captions, like the states sheet."""
    cols = max(len(items) for _, items in rows)
    width = PAD * 2 + LABEL_W + cols * cell_w
    height = PAD * 2 + len(rows) * ROW_H
    img = Image.new("RGBA", (width, height), BG + (255,))
    draw = ImageDraw.Draw(img)
    title, note = font(15 * S, "Semibold"), font(11 * S)
    for r, (name, items) in enumerate(rows):
        y = PAD + r * ROW_H
        draw.text((PAD, y + ROW_H // 2 - 22), name, font=title, fill=TITLE, anchor="lm")
        left = PAD + LABEL_W - 10 * S
        right = left + len(items) * cell_w + 20 * S
        draw.rounded_rectangle((left, y + 6 * S, right, y + 40 * S), radius=17 * S,
                               fill=PILL + (255,), outline=EDGE + (255,), width=2)
        for c, (key, caption) in enumerate(items):
            mark = stills[(r, c)]
            cx = PAD + LABEL_W + c * cell_w + cell_w // 2
            img.alpha_composite(mark, (cx - mark.width // 2, y + 23 * S - mark.height // 2))
            draw.text((cx, y + 52 * S), caption, font=note, fill=NOTE, anchor="mm")
    img.convert("RGB").save(out, optimize=True)
    print(f"wrote {out.relative_to(ROOT)}: {width}x{height}")


def marks() -> None:
    """The slot's marks, rendered by mediawatch itself (--marks)."""
    with tempfile.TemporaryDirectory() as t:
        subprocess.run([str(MEDIAWATCH), "--marks", t], check=True, capture_output=True)
        stills = {}
        rows = []
        for name, items in MARK_ROWS:
            kept = [(k, c) for k, c in items if (pathlib.Path(t) / f"{k}.png").exists()]
            rows.append((name, kept))
            for c, (key, _) in enumerate(kept):
                im = Image.open(pathlib.Path(t) / f"{key}.png").convert("RGBA")
                # 24pt in the slot: the cover and the icons are drawn at 2x, the
                # podcast bars and the dot at 1x, so those are doubled here.
                if im.width < 48:
                    im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
                stills[(len(rows) - 1, c)] = im
        sheet(rows, 72 * S, stills, MARKS_OUT)


def main() -> None:
    cols = max(len(states) for _, states in ROWS)
    width = PAD * 2 + LABEL_W + cols * CELL_W
    height = PAD * 2 + len(ROWS) * ROW_H
    sheet = Image.new("RGBA", (width, height), BG + (255,))
    draw = ImageDraw.Draw(sheet)
    title, note = font(15 * S, "Semibold"), font(11 * S)
    with tempfile.TemporaryDirectory() as t:
        tmp = pathlib.Path(t)
        for r, (name, states) in enumerate(ROWS):
            y = PAD + r * ROW_H
            draw.text((PAD, y + ROW_H // 2 - 22), name, font=title, fill=TITLE, anchor="lm")
            # One pill per row, the badges sitting on it as they do on the bar.
            left = PAD + LABEL_W - 10 * S
            right = left + len(states) * CELL_W + 20 * S
            draw.rounded_rectangle((left, y + 6 * S, right, y + 40 * S), radius=17 * S,
                                   fill=PILL + (255,), outline=EDGE + (255,), width=2)
            for c, (renderer, args, caption) in enumerate(states):
                out = tmp / f"{r}-{c}.png"
                subprocess.run([str(ASSETS / renderer), *args, "--out", str(out)], check=True)
                mark = Image.open(out).convert("RGBA")
                cx = PAD + LABEL_W + c * CELL_W + CELL_W // 2
                sheet.alpha_composite(mark, (cx - mark.width // 2, y + 23 * S - mark.height // 2))
                draw.text((cx, y + 52 * S), caption, font=note, fill=NOTE, anchor="mm")
    sheet.convert("RGB").save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(ROOT)}: {width}x{height}")


if __name__ == "__main__":
    main()
    marks()
