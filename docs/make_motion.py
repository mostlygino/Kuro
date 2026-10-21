#!/usr/bin/env python3
"""Builds docs/motion.gif: the badges changing state, from the real renderers.

    python3 docs/make_motion.py

Nothing here is a screen recording. Each frame is the renderers' own output,
the same stills and transition frames the bar shows, composed onto a pill, so
the GIF is exactly as crisp as the badges and can be rebuilt whenever they
change. Needs Pillow and the renderers built (the bar builds them on first run,
or: swiftc -O assets/<name>.swift -o assets/<name>).
"""

import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / "sketchybar" / "assets"
OUT = ROOT / "docs" / "motion.gif"

PURPLE, GREY, ORANGE, RED = "0xffbf5af2", "0xff8e8e93", "0xffd97757", "0xffff453a"
GREEN = "0xff32d74b"

# Each badge: renderer, arguments for state A, arguments for state B, and how
# the "from" side of a transition is spelled for that renderer.
# In the bar's own order: OrbStack, keep-awake, Claude, VPN, Wi-Fi, battery. Each
# goes from its off or error state to its liveliest, and back.
BADGES = [
    ("orbmark", ["--color", GREY], ["--color", PURPLE],
     lambda a: ["--from-color", a[1]]),
    ("capsulemark", ["--state", "off"], ["--state", "on"],
     lambda a: ["--from-state", a[1]]),
    ("usagemark", ["--error"], ["--percent", "63", "--color", ORANGE],
     lambda a: ["--from-error"] if "--error" in a else ["--from-percent", a[1], "--from-color", a[3]]),
    ("vpnmark", ["--state", "down"], ["--state", "up"],
     lambda a: ["--from-state", a[1]]),
    ("wifimark", ["--dots", "0", "--color", GREY, "--off"], ["--dots", "4", "--color", PURPLE],
     lambda a: ["--from-dots", a[1], "--from-color", a[3]] + (["--from-off"] if "--off" in a else [])),
    ("batterymark", ["--percent", "12", "--color", RED],
     ["--percent", "84", "--color", GREEN, "--charging"],
     lambda a: ["--from-percent", a[1], "--from-color", a[3]] + (["--from-charging"] if "--charging" in a else [])),
]

SCALE = 2          # the renderers draw at two pixels per point
GAP = 16 * SCALE   # ITEM_GAP, between badge boxes
INSET = 12 * SCALE
PILL_H = 34 * SCALE
MARGIN = 28 * SCALE
FRAME_MS = 20      # 50 fps; browsers treat anything under 20ms as 100ms
STAGGER = 8        # frames between one badge starting and the next
HOLD = 60          # frames resting in each state


def render(tmp: pathlib.Path, name: str, args: list[str], tag: str) -> Image.Image:
    out = tmp / f"{name}-{tag}.png"
    subprocess.run([str(ASSETS / name), *args, "--out", str(out)], check=True)
    return Image.open(out).convert("RGBA")


def transition(tmp: pathlib.Path, name: str, to: list[str], frm: list[str], spell, tag: str):
    out = tmp / f"{name}-{tag}"
    subprocess.run([str(ASSETS / name), *to, *spell(frm), "--transition", str(out)], check=True)
    return [Image.open(p).convert("RGBA") for p in sorted(out.glob("frame-*.png"))]


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = pathlib.Path(t)
        tracks = []
        for name, a, b, spell in BADGES:
            tracks.append({
                "a": render(tmp, name, a, "a"),
                "b": render(tmp, name, b, "b"),
                "ab": transition(tmp, name, b, a, spell, "ab"),
                "ba": transition(tmp, name, a, b, spell, "ba"),
            })

        widths = [tr["a"].width for tr in tracks]
        height = max(tr["a"].height for tr in tracks)
        pill_w = INSET * 2 + sum(widths) + GAP * (len(widths) - 1)
        canvas = (pill_w + MARGIN * 2, PILL_H + MARGIN * 2)

        base = Image.new("RGBA", canvas, (11, 11, 12, 255))
        draw = ImageDraw.Draw(base)
        pill = (MARGIN, MARGIN, MARGIN + pill_w, MARGIN + PILL_H)
        draw.rounded_rectangle(pill, radius=PILL_H // 2, fill=(28, 28, 30, 255),
                               outline=(90, 90, 92, 255), width=2)

        length = len(tracks[0]["ab"])

        def frame_for(track, phase, local):
            forward = phase == 0
            start, end = (track["a"], track["b"]) if forward else (track["b"], track["a"])
            seq = track["ab"] if forward else track["ba"]
            if local < 0:
                return start
            if local < length:
                return seq[local]
            return end

        span = STAGGER * (len(tracks) - 1) + length
        frames = []
        for phase in (0, 1):
            for f in range(span + HOLD):
                img = base.copy()
                x = MARGIN + INSET
                for i, track in enumerate(tracks):
                    badge = frame_for(track, phase, f - i * STAGGER)
                    y = MARGIN + (PILL_H - badge.height) // 2
                    img.alpha_composite(badge, (x, y))
                    x += widths[i] + GAP
                frames.append(img.convert("RGB"))

        # One palette for every frame, or the quantiser picks a slightly
        # different grey each frame and the pill shimmers.
        sample = Image.new("RGB", (canvas[0], canvas[1] * 4))
        for k, idx in enumerate((0, span // 2, span + HOLD + span // 2, len(frames) - 1)):
            sample.paste(frames[idx], (0, canvas[1] * k))
        palette = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
        quantised = [fr.quantize(palette=palette, dither=Image.Dither.NONE) for fr in frames]
        quantised[0].save(OUT, save_all=True, append_images=quantised[1:],
                          duration=FRAME_MS, loop=0, optimize=False, disposal=1)
        print(f"wrote {OUT.relative_to(ROOT)}: {len(frames)} frames, {canvas[0]}x{canvas[1]}")


if __name__ == "__main__":
    main()
