#!/usr/bin/env python3
"""Extract app-ready sprites from AI-generated sheets.

The generated sheets (see docs/design/app-ideas.md wave 2) arrive with baked-in
labels, grid lines, and a *painted* checkerboard instead of alpha. This slices
the grid cells, removes the checkerboard by flood fill from the cell borders
(so enclosed light pixels — eye highlights, ivory bellies — survive), and
writes individual transparent PNGs the apps reference by absolute path.

Usage:
  python3 scripts/extract-sprites.py birds  <sheet.png> <outdir>
  python3 scripts/extract-sprites.py chess  <sheet.png> <outdir>
  python3 scripts/extract-sprites.py ledge  <scene.png> <out.png>
"""

import sys
from collections import deque
from pathlib import Path

from PIL import Image

BIRD_COLORS = ["cream", "sky", "sage", "lavender", "peach", "mint"]
BIRD_POSES = ["perched", "blink", "hop", "peck", "flyup", "flydown"]
CHESS_ROWS = ["w", "b"]
CHESS_COLS = ["K", "Q", "R", "B", "N", "P"]

# The checkerboard is light and neutral; sprite fills are warm or saturated.
def is_background(px):
    r, g, b = px[0], px[1], px[2]
    return min(r, g, b) > 190 and (max(r, g, b) - min(r, g, b)) < 20


def is_grid_dark(px):
    return max(px[0], px[1], px[2]) < 110


def line_bands(image, axis):
    """Indices of rows (axis=1) or columns (axis=0) that are mostly grid line."""
    width, height = image.size
    px = image.load()
    bands, run = [], []
    outer, inner = (height, width) if axis == 1 else (width, height)
    for i in range(outer):
        dark = 0
        for j in range(0, inner, 4):                     # sample every 4th px
            p = px[(j, i) if axis == 1 else (i, j)]
            if is_grid_dark(p):
                dark += 1
        if dark > (inner // 4) * 0.55:
            run.append(i)
        elif run:
            bands.append((run[0], run[-1]))
            run = []
    if run:
        bands.append((run[0], run[-1]))
    return bands


def cells_between(bands, limit, minimum):
    """Content spans between consecutive line bands, inset off the lines."""
    spans = []
    edges = [-1] + [b[1] for b in bands]
    starts = [b[0] for b in bands] + [limit]
    for lo, hi in zip(edges, starts):
        span = (lo + 1 + 6, hi - 6)                      # 6 px inset off lines
        if span[1] - span[0] >= minimum:
            spans.append(span)
    return spans


def strip_background(cell):
    """Flood-fill transparent from every border pixel that looks like board."""
    cell = cell.convert("RGBA")
    width, height = cell.size
    px = cell.load()
    seen = bytearray(width * height)
    queue = deque()
    for x in range(width):
        for y in (0, height - 1):
            queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        idx = y * width + x
        if seen[idx]:
            continue
        seen[idx] = 1
        p = px[x, y]
        # Grid-line remnants at the border are neutral-dark; eat those from the
        # border too, but only background-ish colors spread inward.
        if not (is_background(p) or (max(p[:3]) - min(p[:3]) < 24 and (x in (0, width - 1) or y in (0, height - 1)))):
            continue
        px[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return cell


def content_cells(sheet):
    horizontal = line_bands(sheet, axis=1)
    vertical = line_bands(sheet, axis=0)
    rows = cells_between(horizontal, sheet.size[1], 120)
    cols = cells_between(vertical, sheet.size[0], 120)
    return rows, cols


def extract_grid(sheet_path, outdir, row_names, col_names, cell_names):
    sheet = Image.open(sheet_path).convert("RGBA")
    rows, cols = content_cells(sheet)
    rows = rows[-len(row_names):]                        # drop the header band
    cols = cols[-len(col_names):]                        # drop the label band
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    written = []
    for (name_r, (y0, y1)) in zip(row_names, rows):
        for (name_c, (x0, x1)) in zip(col_names, cols):
            cell = strip_background(sheet.crop((x0, y0, x1, y1)))
            out = outdir / cell_names(name_r, name_c)
            cell.save(out)
            written.append(out.name)
    print(f"wrote {len(written)}: {', '.join(written)}")


def extract_ledge(scene_path, out_path):
    scene = Image.open(scene_path).convert("RGBA")
    width, height = scene.size
    target = 412 / 216                                    # aviary sky aspect
    crop_w = min(width, int(height * target))             # crop from the LEFT —
    scene = scene.crop((0, 0, crop_w, height))            # the ✦ watermark is right
    scene = scene.resize((1030, 540), Image.LANCZOS)      # 2.5× the 412×216 canvas
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    scene.save(out_path)
    print(f"wrote {out_path} ({scene.size[0]}x{scene.size[1]})")


def main():
    kind = sys.argv[1]
    if kind == "birds":
        extract_grid(
            sys.argv[2], sys.argv[3], BIRD_COLORS, BIRD_POSES,
            lambda color, pose: f"bird-{color}-{pose}.png",
        )
    elif kind == "chess":
        extract_grid(
            sys.argv[2], sys.argv[3], CHESS_ROWS, CHESS_COLS,
            lambda side, piece: f"{side}{piece}.png",
        )
    elif kind == "ledge":
        extract_ledge(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit(f"unknown kind {kind}")


if __name__ == "__main__":
    main()
