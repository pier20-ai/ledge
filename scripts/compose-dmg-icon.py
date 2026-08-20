#!/usr/bin/env python3
"""Cut the DMG volume icon from mj-artwork/dmg/volume-icon.png into an iconset."""
import sys
from collections import deque
from pathlib import Path
from PIL import Image

ART, OUT = Path(sys.argv[1]), Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)


def keyed(path, thresh=200, spread=28):
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


im = keyed(ART / "volume-icon.png")
im = im.crop(im.getbbox())
side = max(im.size)
pad = int(side * 0.06)
canvas = Image.new("RGBA", (side + 2 * pad,) * 2, (0, 0, 0, 0))
canvas.alpha_composite(im, ((canvas.width - im.width) // 2,
                            (canvas.height - im.height) // 2))
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        suffix = "" if scale == 1 else "@2x"
        canvas.resize((px, px), Image.LANCZOS).save(
            OUT / f"icon_{pt}x{pt}{suffix}.png")
print("iconset at", OUT)
