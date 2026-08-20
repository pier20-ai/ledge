#!/usr/bin/env python3
"""Slice MidJourney sprite sheets in mj-artwork/ into app-ready transparent PNGs.

MidJourney returns sheets on an opaque white (or warm cream) card, with baked
soft drop shadows and drifting, non-uniform cell placement. This script:

  1. estimates the card colour from the top border band,
  2. flood-fills the card away from the image border, so *enclosed* light
     pixels — cream fills, paper highlights, wire-basket gaps — survive
     (a global "delete every light pixel" would hollow the cream out),
  3. ramps alpha across the soft MidJourney edge instead of hard-thresholding,
     and kills the baked drop shadows — spotted as a flat per-channel scaling
     of the card, which works on the warm cream cards too,
  4. segments objects as connected components of the alpha mask rather than by
     a fixed grid, because the cells drift and some cells hold two objects,
  5. trims each sprite to its true bounding box, pads 2%, and downsamples with
     premultiplied-alpha LANCZOS so edges do not fringe.

Usage:
  python3 scripts/extract-mj-sprites.py            # write every sprite
  python3 scripts/extract-mj-sprites.py --debug    # numbered overlays only
  python3 scripts/extract-mj-sprites.py --only shelf-containers
  python3 scripts/extract-mj-sprites.py --verify   # re-check what is on disk
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "mj-artwork"
OUT = ROOT / "docs" / "design" / "assets"
DEBUG_DIR = Path("/tmp/mj-sprite-debug")

# Alpha ramp, in RGB euclidean distance from the estimated card colour.
T_LO = 12.0    # at or under: pure card
T_HI = 44.0    # at or over: pure subject (cream #FDEBD0 on white sits at ~50)
MAX_SIDE = 512
PAD_FRAC = 0.02


# --------------------------------------------------------------------------- #
# background removal
# --------------------------------------------------------------------------- #

def card_colour(rgb: np.ndarray) -> np.ndarray:
    """The sheet's paper colour. Every sheet here has a clean top band."""
    return np.median(rgb[:4].reshape(-1, 3), axis=0)


def alpha_from_card(rgb: np.ndarray, kill_shadows: bool = True, drop_holes: bool = False,
                    t_lo: float = T_LO, t_hi: float = T_HI,
                    shadow_spread: float = 0.05, hole_tol: float | None = None,
                    hole_light: float | None = None) -> np.ndarray:
    """Alpha for one sheet: card removed, subject kept, soft edges ramped.

    drop_holes also clears *enclosed* card-coloured pockets — sky between bare
    branches, the gaps inside a leaf sprig, a key's bow. Leave it off wherever
    the artwork's own fills sit at card colour: the shelf sheet's pale cream box
    fronts read as pure white and would be punched straight out.
    """
    bg = card_colour(rgb)
    f = rgb.astype(np.float32)
    dist = np.sqrt(((f - bg) ** 2).sum(axis=2))

    # Anything lighter than the card on every channel is card (or a white
    # halo MidJourney sprayed around the subject) — never a fill.
    dist[np.all(f >= bg + 1.5, axis=2)] = 0.0

    # A baked drop shadow is the card scaled down uniformly, so its per-channel
    # ratio to the card stays flat. Cream, tan and slate fills tilt their
    # channels apart, and outlines are far too dark. This reads shadows on a
    # white card and on the warm cream cards alike, where chroma would not.
    ratio = f / np.maximum(bg, 1.0)
    shadow = ((ratio.max(axis=2) - ratio.min(axis=2)) < shadow_spread) \
        & (ratio.mean(axis=2) > 0.55)

    # Spread inward through card-ish pixels — and through shadow, which is
    # otherwise too dark to wade into and would set as an opaque grey crescent.
    porous = dist < t_hi
    if kill_shadows:
        porous = porous | shadow
    if hole_light is not None:
        # Pale wash is neither card nor shadow but is lighter than any fill on
        # the sheet, so let the fill wade through it as well.
        porous = porous | (f.min(axis=2) > hole_light)
    lab, n = ndimage.label(porous)
    border = np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]])
    bg_ids = set(np.unique(border[border > 0]).tolist())
    if drop_holes:
        # A porous island holding a real patch of untouched card is background
        # too, however enclosed it is. Its own component carries the soft edge.
        # Requiring near-card pixels — rather than taking every enclosed island
        # — is what keeps a mushroom's pale stem and an hourglass's glass.
        cardish = dist < (t_lo if hole_tol is None else hole_tol)
        if hole_light is not None:
            # Some pockets never reach paper white — MidJourney washes them a
            # pale blue-grey. Anything lighter than every fill on the sheet is
            # that wash, so give the sheet its own lightness floor.
            cardish |= f.min(axis=2) > hole_light
        pure = np.bincount(lab[cardish].ravel(), minlength=n + 1)
        area = np.bincount(lab.ravel(), minlength=n + 1)
        # Proportional, not absolute: the daylight between two leaves is often
        # only a twenty-pixel sliver, but it is card almost all the way through.
        frac = pure / np.maximum(area, 1)
        bg_ids |= {i for i in range(1, n + 1) if area[i] >= 6 and frac[i] >= 0.5}
    outside = np.isin(lab, sorted(bg_ids))

    alpha = np.full(rgb.shape[:2], 255.0, dtype=np.float32)
    ramp = np.clip((dist - t_lo) / (t_hi - t_lo), 0.0, 1.0) * 255.0
    alpha[outside] = ramp[outside]

    if kill_shadows:
        alpha[outside & shadow] = 0.0

    return alpha


# --------------------------------------------------------------------------- #
# segmentation: connected components, each object owning its own pixels
# --------------------------------------------------------------------------- #

def _bbox_gap(a, b) -> int:
    return max(max(a[0] - b[2], b[0] - a[2], 0), max(a[1] - b[3], b[1] - a[3], 0))


def segment(alpha: np.ndarray, min_area: int, adopt_gap: int):
    """Objects as connected components of the soft alpha mask.

    Labelling at alpha > 24 (not a hard threshold) means each component already
    carries its own antialiased fringe, so a sprite can be masked to its own
    component and no neighbour bleeds in through an overlapping bounding box.
    Sub-threshold crumbs — a detached mushroom cap, a ground-line dash — are
    adopted by the nearest object they sit against, and otherwise dropped.
    """
    solid = ndimage.binary_closing(alpha > 24, np.ones((3, 3)))
    lab, n = ndimage.label(solid, structure=np.ones((3, 3)))
    if n == 0:
        return []
    areas = np.bincount(lab.ravel())
    areas[0] = 0
    slices = ndimage.find_objects(lab)
    box_of = {i + 1: (sl[1].start, sl[0].start, sl[1].stop, sl[0].stop)
              for i, sl in enumerate(slices) if sl is not None}

    big = [i for i in box_of if areas[i] >= min_area]
    groups = {i: [i] for i in big}
    for i in box_of:
        if i in groups:
            continue
        near = [(_bbox_gap(box_of[i], box_of[j]), j) for j in big]
        gap, host = min(near)
        if gap <= adopt_gap:
            groups[host].append(i)

    objects = []
    for host, members in groups.items():
        bs = [box_of[i] for i in members]
        box = (min(b[0] for b in bs), min(b[1] for b in bs),
               max(b[2] for b in bs), max(b[3] for b in bs))
        objects.append((box, np.isin(lab, members)))
    return objects


def reading_order(objects, row_tol):
    """Group into rows by vertical position, then left-to-right inside a row."""
    objects = sorted(objects, key=lambda o: o[0][1])
    rows, cur = [], []
    for o in objects:
        if cur and o[0][1] > min(c[0][1] for c in cur) + row_tol:
            rows.append(cur)
            cur = []
        cur.append(o)
    if cur:
        rows.append(cur)
    return [o for row in rows for o in sorted(row, key=lambda o: o[0][0])]


# --------------------------------------------------------------------------- #
# sprite writing
# --------------------------------------------------------------------------- #

def finish(rgb: np.ndarray, alpha: np.ndarray, box, own=None) -> Image.Image:
    x0, y0, x1, y1 = box
    a = alpha.copy()
    if own is not None:
        a[~own] = 0.0                     # this sprite keeps only its own pixels
    ys, xs = np.nonzero(a[y0:y1, x0:x1] > 8)
    if len(ys):
        x1, y1 = x0 + int(xs.max()) + 1, y0 + int(ys.max()) + 1
        x0, y0 = x0 + int(xs.min()), y0 + int(ys.min())
    w, h = x1 - x0, y1 - y0
    pad = max(2, int(round(max(w, h) * PAD_FRAC)))

    canvas = np.zeros((h + 2 * pad, w + 2 * pad, 4), dtype=np.uint8)
    canvas[pad:pad + h, pad:pad + w, :3] = rgb[y0:y1, x0:x1]
    canvas[pad:pad + h, pad:pad + w, 3] = np.round(a[y0:y1, x0:x1]).astype(np.uint8)
    img = Image.fromarray(canvas, "RGBA")

    if max(img.size) > MAX_SIDE:
        s = MAX_SIDE / max(img.size)
        size = (max(1, round(img.width * s)), max(1, round(img.height * s)))
        # premultiplied resize: keeps edges from fringing toward white
        img = img.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")
    return img


# --------------------------------------------------------------------------- #
# the sheets
# --------------------------------------------------------------------------- #

@dataclass
class Sheet:
    key: str
    app: str
    src: str
    names: list[str]
    min_area: int = 900       # components smaller than this are not objects
    adopt_gap: int = 14       # crumbs this close to an object join it
    row_tol: int = 120        # vertical slack when grouping boxes into rows
    kill_shadows: bool = True
    drop_holes: bool = False  # clear enclosed card-coloured pockets too
    t_lo: float = T_LO
    t_hi: float = T_HI
    shadow_spread: float = 0.05
    hole_tol: float | None = None   # how card-like a pocket must be to clear
    hole_light: float | None = None # or: lighter than any fill on this sheet
    single: bool = False      # one subject; never segment


SHEETS = [
    Sheet(
        key="shelf-hero",
        app="shelf",
        src="shelf/hero.png",
        names=["cabinet-two-drawer-front"],
        single=True,
    ),
    Sheet(
        key="shelf-containers",
        app="shelf",
        src="shelf/scutifer_sprite_sheet_2x3_grid_evenly_spaced_consistent_scale_"
            "201b122d-183f-4f6f-bb23-2cda045917a0_2.png",
        names=[
            "box-open-papers", "box-open-folder", "box-lidded",
            None, "tray-letter-slate", "tray-shallow-cream",   # basket: pass 2
            "bucket-round", "bin-scoop", "box-flat-lidded",
        ],
        row_tol=140,
    ),
    Sheet(
        # Second pass over the same sheet. Hole-dropping is what the wire mesh
        # needs and what the pale cream box fronts cannot survive, so the
        # basket is lifted separately and every other cell is skipped.
        key="shelf-containers-basket",
        app="shelf",
        src="shelf/scutifer_sprite_sheet_2x3_grid_evenly_spaced_consistent_scale_"
            "201b122d-183f-4f6f-bb23-2cda045917a0_2.png",
        names=[None, None, None, "basket-wire", None, None, None, None, None],
        row_tol=140,
        drop_holes=True,
    ),
    Sheet(
        key="shelf-labels",
        app="shelf",
        src="shelf/scutifer_sprite_sheet_2x2_grid_a_paper_label_tag_on_a_string_"
            "_56b09466-4c4b-438c-911b-a303b0ded390_1.png",
        names=[
            "tag-cream", "stamp-handle", "key-ornate",
            "tag-slate", "key-brass", "hourglass",
        ],
        row_tol=140,
        drop_holes=True,          # grommet holes and key bows must see through
    ),
    Sheet(
        key="shelf-filetypes",
        app="shelf",
        src="shelf/scutifer_sprite_sheet_3x3_grid_evenly_spaced_consistent_scale_"
            "85d967db-412c-47f1-968f-a8d696101666_3.png",
        names=[
            "file-text", "file-image", "file-pdf", "file-archive",
            "file-blank-curled", "file-blank", "file-spreadsheet", "file-torn",
            "file-video-screen", "file-clapperboard", "file-audio-clip", "file-unknown",
        ],
        row_tol=110,
    ),
    Sheet(
        key="garden-terrain",
        app="focus-garden",
        src="focus-garden/scutifer_sprite_sheet_2x3_grid_a_small_mossy_rock_a_larger_bo_"
            "8356d6c4-8925-460b-95bd-e4e1f8a7a344_3.png",
        names=[
            "rock-mossy", "boulder", "log-mossy", "mushroom-cluster",
            "clover-sprigs", "moss-mound", "sapling-fern",
        ],
        row_tol=150,
        drop_holes=True,          # daylight between stems and caps
    ),
    Sheet(
        key="garden-plants",
        app="focus-garden",
        src="focus-garden/scutifer_sprite_sheet_3x3_grid_evenly_spaced_nine_small_clust_"
            "6c7cc593-8239-420d-bca4-199aa78cca5f_2.png",
        names=[
            "leaf-broad-cluster", "sprig-slender", "frond-upright",
            "grass-tuft", "shrub-mossy", "shrub-round",
            "groundcover-dense", "shrub-leafy", "twig-bare",
        ],
        row_tol=120,
        drop_holes=True,          # daylight between leaves
        hole_light=185.0,         # gaps wash pale blue; every green fill is darker
    ),
    Sheet(
        key="weatherglass-dial",
        app="weatherglass",
        src="weatherglass/scutifer_a_round_wall-mounted_thermostat_dial_with_a_brushed_"
            "_08b3cef7-c401-4cb9-9af6-1cb58397e504_2.png",
        names=["thermostat-dial"],
        single=True,
        # A 3D render on a cream card: the soft cast shadow and the pale outer
        # bezel share a colour family. Cut higher and let the flat-ratio test
        # eat the shadow; the bezel proper is far enough from the card to stay.
        t_lo=25.0, t_hi=90.0, shadow_spread=0.085,
    ),
    Sheet(
        key="weatherglass-objects",
        app="weatherglass",
        src="weatherglass/scutifer_sprite_sheet_1x3_a_small_potted_succulent_a_short_cu_"
            "867b14e0-b020-4baa-8ed0-5ef0a36ca4a7_1.png",
        names=["succulent-potted", "kindling-bundle", "hook-on-rope"],
        row_tol=999,                      # one row
    ),
    Sheet(
        key="night-sky-horizon",
        app="night-sky",
        src="night-sky/scutifer_a_long_horizontal_silhouette_strip_of_a_distant_tree_"
            "9dc66cfc-38f2-4d45-b453-a3b767c05d9e_2.png",
        names=["horizon-treeline"],
        single=True,
        kill_shadows=False,       # the pale house is neutral and light
        drop_holes=True,          # sky between the branches
    ),
]


def load(sheet: Sheet):
    rgb = np.asarray(Image.open(SRC / sheet.src).convert("RGB"))
    alpha = alpha_from_card(rgb, kill_shadows=sheet.kill_shadows,
                            drop_holes=sheet.drop_holes, t_lo=sheet.t_lo,
                            t_hi=sheet.t_hi, shadow_spread=sheet.shadow_spread,
                            hole_tol=sheet.hole_tol, hole_light=sheet.hole_light)
    if sheet.single:
        ys, xs = np.nonzero(alpha > 8)
        box = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
        return rgb, alpha, [(box, None)]
    objects = segment(alpha, sheet.min_area, sheet.adopt_gap)
    return rgb, alpha, reading_order(objects, sheet.row_tol)


def write_debug(sheet: Sheet, rgb, objects):
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    img = Image.fromarray(rgb).convert("RGB")
    d = ImageDraw.Draw(img)
    for i, ((x0, y0, x1, y1), _own) in enumerate(objects):
        d.rectangle([x0, y0, x1, y1], outline=(220, 40, 40), width=4)
        d.text((x0 + 8, y0 + 6), str(i), fill=(220, 40, 40))
        d.ellipse([x0, y0, x0 + 34, y0 + 34], fill=(220, 40, 40))
        d.text((x0 + 12, y0 + 11), str(i), fill=(255, 255, 255))
    s = 1100 / max(img.size)
    if s < 1:
        img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    p = DEBUG_DIR / f"{sheet.key}.png"
    img.save(p)
    print(f"  debug -> {p}  ({len(objects)} objects)")


def run(sheets, debug=False):
    written = []
    for sheet in sheets:
        rgb, alpha, objects = load(sheet)
        print(f"{sheet.key}: {len(objects)} objects, expected {len(sheet.names)}")
        if debug:
            write_debug(sheet, rgb, objects)
            continue
        if len(objects) != len(sheet.names):
            print(f"  !! count mismatch, skipping {sheet.key}", file=sys.stderr)
            write_debug(sheet, rgb, objects)
            continue
        outdir = OUT / sheet.app
        outdir.mkdir(parents=True, exist_ok=True)
        for name, (box, own) in zip(sheet.names, objects):
            if not name:
                continue
            img = finish(rgb, alpha, box, own)
            path = outdir / f"{name}.png"
            img.save(path)
            written.append(path)
            print(f"  {path.relative_to(ROOT)}  {img.width}x{img.height}")
    return written


def verify(paths=None):
    paths = paths or sorted(OUT.rglob("*.png"))
    bad = []
    print(f"\nverifying {len(paths)} sprites")
    for p in paths:
        img = Image.open(p)
        problems = []
        if img.mode != "RGBA":
            problems.append(f"mode={img.mode}")
        a = np.asarray(img.convert("RGBA"))[..., 3]
        clear = float((a < 16).mean())
        if clear < 0.005:
            problems.append(f"no background removed (only {clear:.1%} clear)")
        if clear > 0.92:
            problems.append(f"subject erased ({clear:.1%} clear)")
        ys, xs = np.nonzero(a > 24)
        if not len(ys):
            problems.append("empty")
        else:
            bw, bh = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
            fill = float(bw * bh) / (img.width * img.height)
            if fill < 0.55:
                problems.append(f"bbox only fills {fill:.0%} of canvas (bad trim)")
            if min(bw, bh) < 24:
                problems.append(f"tiny content {bw}x{bh}")
        flag = "FAIL" if problems else "ok"
        if problems:
            bad.append(p)
        print(f"  [{flag}] {p.relative_to(ROOT)}  {img.width}x{img.height}  "
              f"clear={clear:.0%}  {'; '.join(problems)}")
    print(f"\n{len(paths) - len(bad)}/{len(paths)} sprites passed")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    if args.verify:
        verify()
        return
    sheets = [s for s in SHEETS if not args.only or s.key in args.only]
    written = run(sheets, debug=args.debug)
    if written and not args.debug:
        verify(written)


if __name__ == "__main__":
    main()
