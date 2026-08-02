#!/usr/bin/env python3
"""Composites App Store marketing screenshots from the real app renders.

`InditalkTests/ScreenshotGenerator` renders the shipping SwiftUI screens to 1290x2796
PNGs. This script frames each one: brand gradient, a headline, and the device screen with
rounded corners and a soft shadow.

It deliberately only ever *frames* a real render. It does not draw app UI, because an App
Store screenshot showing a screen the app does not have breaches App Review 2.3.3
("screenshots should show the app in use").

    python3 site/shots.py <raw-dir> <out-dir>
"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1290, 2796
DEVICE_W = 960
CORNER = 58
DEVICE_TOP = 660

FONT_DIRS = ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts"]
BOLD_CANDIDATES = ["HelveticaNeue.ttc", "Helvetica.ttc", "SFNSRounded.ttf", "SFNS.ttf", "Arial Bold.ttf"]
BODY_CANDIDATES = ["HelveticaNeue.ttc", "Helvetica.ttc", "SFNS.ttf", "Arial.ttf"]


def _font(candidates, size, index=None):
    for name in candidates:
        for d in FONT_DIRS:
            p = os.path.join(d, name)
            if os.path.exists(p):
                try:
                    return ImageFont.truetype(p, size, index=index) if index is not None \
                        else ImageFont.truetype(p, size)
                except Exception:
                    continue
    return ImageFont.load_default()


# (headline, subhead, top gradient, bottom gradient, text colour)
SLIDES = [
    ("01-chats",       "Every conversation\nin one place",
     "Text, photos, voice notes and files", (0x1C, 0x3A, 0x4B), (0x2F, 0x6E, 0x63), "light"),
    ("02-chat",        "Say it however\nyou like",
     "Reply, forward, star and search any chat", (0x2F, 0x6E, 0x63), (0x4A, 0x8F, 0x7B), "light"),
    ("03-calls",       "Voice and video\ncalls that just work",
     "Rings through iOS like an ordinary call", (0x24, 0x4C, 0x63), (0x37, 0x7D, 0x86), "light"),
    ("04-communities", "Groups for the\npeople who matter",
     "Create groups and add the people you choose", (0x8A, 0x6A, 0x28), (0xB8, 0x8E, 0x3A), "light"),
    ("05-updates",     "Updates that\ndisappear in 24h",
     "Share a moment without leaving a trail", (0x5C, 0x3F, 0x6B), (0x8A, 0x5F, 0x9B), "light"),
    ("06-settings",    "Your account,\nyour rules",
     "Everything about you, in one tab", (0x1C, 0x3A, 0x4B), (0x33, 0x5C, 0x70), "light"),
    ("07-privacy",     "You decide\nwho sees what",
     "Last seen, photo, About and read receipts", (0x1E, 0x5A, 0x50), (0x2F, 0x6E, 0x63), "light"),
    ("08-qr",          "Add contacts\nwith a scan",
     "Share your code, skip typing numbers", (0x2B, 0x4A, 0x7A), (0x4A, 0x6F, 0xA8), "light"),
    ("09-support",     "Help and safety,\none tap away",
     "Report, block, and reach a real person", (0x8A, 0x4A, 0x3A), (0xB5, 0x6B, 0x4A), "light"),
    ("10-account",     "Leave whenever\nyou want",
     "Delete your account and data from Settings", (0x3A, 0x3F, 0x4A), (0x5A, 0x62, 0x70), "light"),
]


def gradient(top, bottom):
    base = Image.new("RGB", (1, H))
    px = base.load()
    for y in range(H):
        t = y / (H - 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return base.resize((W, H), Image.BILINEAR)


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1],
                                           radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def draw_centered(draw, text, font, y, fill, line_gap=14):
    for line in text.split("\n"):
        box = draw.textbbox((0, 0), line, font=font)
        w = box[2] - box[0]
        draw.text(((W - w) // 2, y), line, font=font, fill=fill)
        y += (box[3] - box[1]) + line_gap
    return y


def build(raw_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    head_font = _font(BOLD_CANDIDATES, 86, index=1)   # HelveticaNeue.ttc index 1 == Bold
    sub_font = _font(BODY_CANDIDATES, 40, index=0)

    made = []
    for name, headline, subhead, top, bottom, _ in SLIDES:
        src = os.path.join(raw_dir, f"{name}.png")
        if not os.path.exists(src):
            print(f"  ! missing render {src} — skipped")
            continue

        canvas = gradient(top, bottom)
        draw = ImageDraw.Draw(canvas)

        y = draw_centered(draw, headline, head_font, 150, (255, 255, 255))
        draw_centered(draw, subhead, sub_font, y + 26, (255, 255, 255, 220))

        shot = Image.open(src).convert("RGB")
        dh = int(DEVICE_W * shot.height / shot.width)
        shot = shot.resize((DEVICE_W, dh), Image.LANCZOS)
        shot = rounded(shot, CORNER)

        x = (W - DEVICE_W) // 2
        # Soft drop shadow so the screen reads as a device against the gradient.
        shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            [x + 8, DEVICE_TOP + 18, x + DEVICE_W + 8, DEVICE_TOP + dh + 18],
            radius=CORNER, fill=(0, 0, 0, 105))
        shadow = shadow.filter(ImageFilter.GaussianBlur(26))

        canvas = canvas.convert("RGBA")
        canvas = Image.alpha_composite(canvas, shadow)
        canvas.paste(shot, (x, DEVICE_TOP), shot)

        # Thin light rim, so the dark app chrome doesn't merge into a dark gradient.
        ImageDraw.Draw(canvas).rounded_rectangle(
            [x, DEVICE_TOP, x + DEVICE_W, DEVICE_TOP + dh],
            radius=CORNER, outline=(255, 255, 255, 90), width=3)

        dest = os.path.join(out_dir, f"{name}.png")
        canvas.convert("RGB").save(dest, "PNG", optimize=True)
        assert Image.open(dest).size == (W, H), dest
        made.append(dest)
        print(f"  ✓ {name}.png  ({os.path.getsize(dest)//1024} KB)")

    print(f"{len(made)} marketing screenshots -> {out_dir}")
    return made


if __name__ == "__main__":
    raw = sys.argv[1] if len(sys.argv) > 1 else "shots-raw"
    out = sys.argv[2] if len(sys.argv) > 2 else "shots-final"
    build(raw, out)
