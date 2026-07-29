#!/usr/bin/env python3
"""Turn a square piece of generated artwork into scripts/assets/AppIcon.icns.

Usage:
    scripts/make-app-icon.py <source.png> [--out scripts/assets/AppIcon.icns]

The source is a 1024x1024 PNG with no alpha: a rounded-square
tile floating on a flat orange BLEED that fills the rest of the canvas. The
bleed is the same orange as the tile to within about five grey levels, so no
trim-by-colour survives contact with it. Everything below is measured instead —
and re-measurable, which is the point of the script existing at all.

Two geometries matter, and they are not the same geometry:

  * The tile inside the SOURCE. Found by Gaussian-blurring to kill the
    generator's dither and reading the residual step in luminance: the tile
    spans 67.5..955.5 on both axes (888 px, dead centred), with a near-circular
    corner of radius ~183 px, i.e. 0.206 of the side.

  * The macOS icon grid. Since Big Sur an app icon is a 1024 canvas with the
    body inset, and an icon that bleeds to the canvas edge simply looks too big
    in the Dock next to everything else. The numbers here were measured off a
    shipping system icon rather than quoted: `iconutil -c iconset` on
    Calculator.app, then the alpha channel of icon_128x128@2x.png. Opaque body
    25..231 of 256 — 100 px margin and an 824 px body once scaled to 1024 — and
    a corner that fits a superellipse of exponent 2.5 with semi-extent 0.2697 of
    the body, reproducing Apple's mask to under 0.03 RMS alpha.

The macOS corner (0.270) is rounder than the source's own (0.206), which is the
lucky part: the mask cuts strictly INSIDE the artwork's own arc, so the source's
corner — and the one-pixel bright fringe sitting on it, and every bleed pixel
beyond — is discarded rather than blended. That is why masking beats trimming
here, and why the crop can safely take the full 888 square.
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

# The tile inside the source, measured (see the module docstring). Given as a
# fraction of the source's own width so a 2048 px regeneration still works.
TILE_LEFT = 67.5 / 1024
TILE_SIZE = 888.0 / 1024

# The macOS grid, measured off Calculator.app.
CANVAS = 1024
BODY = 824
MARGIN = (CANVAS - BODY) // 2
CORNER = 0.2697          # semi-extent of the corner superellipse, in body widths
CORNER_EXPONENT = 2.5    # 2.0 would be a plain circle; Apple's corner is not one

# Every size an .icns can carry. Leaving any of them out does not mean "smaller
# file" — it means macOS scales the nearest one it has, and a resampled 128 in a
# 512 slot is visibly soft.
ICONSET = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def squircle(side: int, supersample: int = 8) -> Image.Image:
    """An 8-bit coverage mask of the macOS body shape, antialiased by area.

    Rendered at `supersample`x and box-averaged down rather than drawn and
    blurred: a blurred mask is soft on the straight edges too, and the straight
    edges are most of the shape.
    """
    r = CORNER * side
    n = supersample
    grid = (np.arange(side * n) + 0.5) / n
    u, v = np.meshgrid(grid, grid)
    # Distance into the corner box, zero anywhere along the straight edges.
    dx = np.clip(np.maximum(r - u, u - (side - r)), 0, None) / r
    dy = np.clip(np.maximum(r - v, v - (side - r)), 0, None) / r
    inside = (dx ** CORNER_EXPONENT + dy ** CORNER_EXPONENT) <= 1.0
    coverage = inside.reshape(side, n, side, n).mean(axis=(1, 3))
    return Image.fromarray(np.round(coverage * 255).astype(np.uint8), mode="L")


def build_master(source: pathlib.Path) -> Image.Image:
    art = Image.open(source).convert("RGB")
    if art.width != art.height:
        sys.exit(f"{source} is {art.width}x{art.height}; the source must be square")

    scale = art.width
    left = round(TILE_LEFT * scale)
    size = round(TILE_SIZE * scale)
    tile = art.crop((left, left, left + size, left + size))
    tile = tile.resize((BODY, BODY), Image.LANCZOS)
    tile.putalpha(squircle(BODY))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(tile, (MARGIN, MARGIN))
    return canvas


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=pathlib.Path)
    ap.add_argument(
        "--out",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent / "assets" / "AppIcon.icns",
    )
    ap.add_argument(
        "--keep-pngs",
        type=pathlib.Path,
        help="also copy the rendered .iconset here, to look at before shipping",
    )
    args = ap.parse_args()

    master = build_master(args.source)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for name, px in ICONSET:
            # Always from the 1024 master. Resizing 512 -> 256 -> 128 compounds
            # the filter's softening; one hop from the master does not.
            frame = master if px == CANVAS else master.resize((px, px), Image.LANCZOS)
            frame.save(iconset / name)

        args.out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(args.out)],
            check=True,
        )
        if args.keep_pngs:
            if args.keep_pngs.exists():
                shutil.rmtree(args.keep_pngs)
            shutil.copytree(iconset, args.keep_pngs)

    print(f"wrote {args.out} ({args.out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
