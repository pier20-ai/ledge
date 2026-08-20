#!/usr/bin/env python3
"""Compose the Ledge DMG background (1200x800 @2x) from mj-artwork/dmg pieces.

Pipeline: key out the near-white generation background by flood fill from the
image borders (interior lights survive), slice the sprite grids, then paint the
scene: flat indigo night, menu-bar strip with THE NOTCH, mossy ledge bottom-left.
The two Finder icons (Ledge.app on the ledge, Applications in the notch) are
placed by make-dmg.sh's AppleScript, so this leaves those spots clear.
"""
import sys
from collections import deque
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps

ART = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("mj-artwork/dmg")
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("scripts/assets/dmg")
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "sprites").mkdir(exist_ok=True)

W, H = 1200, 800  # @2x for a 600x400 window

SKY = (28, 36, 55, 255)        # flat deep indigo
BAR = (10, 12, 16, 255)        # menu bar / notch — house navy #0E1116
CREAM = (253, 235, 208, 255)   # house cream #FDEBD0


def keyed(path, thresh=200, spread=28):
    """Flood-fill transparent from the borders over near-neutral light pixels."""
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size
    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        q.append((x, 0)); q.append((x, h - 1))
    for y in range(h):
        q.append((0, y)); q.append((w - 1, y))
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        r, g, b, a = px[x, y]
        if min(r, g, b) > thresh and (max(r, g, b) - min(r, g, b)) < spread:
            px[x, y] = (r, g, b, 0)
            q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return im


def cell(sheet, cols, rows, c, r):
    w, h = sheet.size
    cw, ch = w // cols, h // rows
    return sheet.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))


def trim(im):
    bbox = im.getbbox()
    return im.crop(bbox) if bbox else im


def tint(im, rgba):
    """Recolor a dark line drawing to rgba, keeping its alpha."""
    alpha = im.getchannel("A")
    solid = Image.new("RGBA", im.size, rgba)
    solid.putalpha(alpha)
    return solid


def fit(im, width=None, height=None):
    w, h = im.size
    if width:
        return im.resize((width, int(h * width / w)), Image.LANCZOS)
    return im.resize((int(w * height / h), height), Image.LANCZOS)


# --- load + slice -----------------------------------------------------------
hero = trim(keyed(ART / "ledge-hero-midjourney.png"))
companions = keyed(ART / "companion-sprites.png")
owl_sleep = trim(cell(companions, 2, 2, 0, 0))
night = keyed(ART / "night-sky-sprites.png")
star4 = trim(cell(night, 3, 3, 0, 0))
dot = trim(cell(night, 3, 3, 1, 0))
moon = trim(cell(night, 3, 3, 2, 0))
shooting = trim(cell(night, 3, 3, 1, 1))
firefly = trim(cell(night, 3, 3, 2, 1))
cluster = trim(cell(night, 3, 3, 0, 2))
star5 = trim(cell(night, 3, 3, 2, 2))
arrows = keyed(ART / "install-arrows.png")
arrow = trim(cell(arrows, 2, 2, 1, 0))  # dotted, arcing up

for name, im in [("hero", hero), ("owl-sleep", owl_sleep), ("arrow", arrow)]:
    im.save(OUT / "sprites" / f"{name}.png")

if __name__ != "__main__":
    sys.exit(0)

# --- paint ------------------------------------------------------------------
bg = Image.new("RGBA", (W, H), SKY)
d = ImageDraw.Draw(bg)

# menu bar + notch (one silhouette, like the real thing)
BAR_H = 52
NOTCH_W, NOTCH_H, NOTCH_R = 360, 92, 22
d.rectangle((0, 0, W, BAR_H), fill=BAR)
nx0, nx1 = (W - NOTCH_W) // 2, (W + NOTCH_W) // 2
d.rounded_rectangle((nx0, 0, nx1, NOTCH_H), radius=NOTCH_R, fill=BAR,
                    corners=(False, False, True, True))

# night dressing — sparse, asymmetric
def put(im, x, y, width):
    s = fit(im, width=width)
    bg.alpha_composite(s, (x - s.width // 2, y - s.height // 2))

put(moon, 1080, 150, 110)
put(star4, 150, 130, 46)
put(star5, 1010, 330, 40)
put(cluster, 90, 330, 90)
put(shooting, 320, 100, 110)
put(dot, 500, 180, 16)
put(dot, 760, 120, 14)
put(dot, 940, 230, 16)
put(dot, 220, 240, 12)
put(firefly, 620, 560, 56)

# the ledge, bottom-left, owl asleep on its right end
ledge = fit(hero, width=520)
lx, ly = 30, H - ledge.height - 10
bg.alpha_composite(ledge, (lx, ly))
owl = fit(owl_sleep, width=110)
bg.alpha_composite(owl, (lx + 355, ly + 8 - owl.height // 2 + 40))

# the gesture: cream dotted arrow arcing from the ledge toward the notch
arr = tint(fit(arrow, height=210), CREAM).rotate(18, expand=True,
                                                 resample=Image.BICUBIC)
bg.alpha_composite(arr, (475, 225))

# caption, set in real type
def load_font(size):
    for cand in ("/System/Library/Fonts/SFNS.ttf",
                 "/System/Library/Fonts/HelveticaNeue.ttc",
                 "/Library/Fonts/Arial.ttf"):
        try:
            return ImageFont.truetype(cand, size)
        except OSError:
            continue
    return ImageFont.load_default()

cap = "drag Ledge into the notch"
f = load_font(40)
tw = d.textlength(cap, font=f)
d.text((830 - tw / 2, H - 78), cap, font=f, fill=(253, 235, 208, 220))

bg.convert("RGB")
bg2x = OUT / "background@2x.png"
bg.save(bg2x)
bg.resize((W // 2, H // 2), Image.LANCZOS).save(OUT / "background.png")
print("wrote", bg2x)
