# Ledge art direction — sprite prompts and procedural recipes

Companion to `design-system-v2.html` and `apps-v2.html`. Two halves: **what to generate** (MidJourney
prompts, matched to the house style we already have) and **what to grow** (procedural algorithms for
Focus Garden, which should stay generated rather than drawn).

---

## 0. The house style already exists

The chess set defines it, so nothing new should drift from it:

- **Flat vector.** No gradients, no rendered shading, no ambient occlusion.
- **One heavy outline**, near-black navy `#0E1116`, uniform weight, fully closed.
- **Warm cream fills** (`#FDEBD0` family) against cool dark counterparts (`#384048` family).
- **Minimal interior detail** — a couple of interior lines, never texture.
- **Orthographic, centred, transparent background.**

Everything below inherits that. The single most useful MidJourney technique for a coherent set:
**generate one hero object first, approve it, then pass its image URL as `--sref` on every
subsequent prompt.** Style drift across a 15-object set is the usual failure, and `--sref` is the fix.

**Pipeline notes.** MidJourney cannot output alpha, so generate on pure white and key it out —
the heavy dark outline makes that reliable. `scripts/extract-sprites.py` already does grid detection
and flood-fill background removal (it cut the aviary birds and the chess set), so ask for **grids**
rather than singles where you can: fewer generations, consistent scale, and the script slices them.

Shared suffix for every prompt below:

```
flat vector illustration, bold uniform dark navy outline, limited flat color fill,
no gradient, no shading, no texture, orthographic, centered, pure white background
--style raw --v 7 --no photorealism, 3d render, drop shadow, gradient, background scenery
```

---

## 1. Shelf — the biggest sprite need

Shelf is the one app whose whole interface *is* objects, so it needs the most art. Keep everything
slightly toy-like and three-quarter-front — readable at 30–60 pt.

**Hero object (generate first, use as `--sref` for the rest):**

```
a single wooden filing drawer front with a small metal pull handle and a paper label slot,
flat vector illustration, bold uniform dark navy outline, limited flat color fill,
warm cream and muted slate palette, no gradient, no shading, orthographic front view,
centered, pure white background --style raw --v 7 --ar 1:1
```

**Containers (one grid):**

```
sprite sheet, 2x3 grid, evenly spaced, consistent scale: an open filing drawer, a closed filing
drawer, a wire basket bucket, a shallow paper tray, an angled delivery chute, a flat shelf ledge,
flat vector illustration, bold uniform dark navy outline, limited flat color fill, warm cream and
muted slate palette, no gradient, no shading, orthographic, pure white background
--style raw --v 7 --ar 3:2 --sref <hero-url>
```

**File tokens (one grid — these are the things that travel):**

```
sprite sheet, 3x3 grid, evenly spaced, consistent scale: a paper document with a folded corner,
a photograph print, a PDF document, a zipped archive with a zipper pull, a spreadsheet page with
a small grid, a paper receipt with a torn edge, a video clip slate, an audio file card, a generic
unknown file with a question mark, flat vector illustration, bold uniform dark navy outline,
cream paper with muted accent details, no gradient, no shading, orthographic front view,
pure white background --style raw --v 7 --ar 1:1 --sref <hero-url>
```

**Rule furniture (one grid):**

```
sprite sheet, 2x2 grid: a paper label tag on a string, a rubber stamp, a small brass key,
an hourglass, flat vector illustration, bold uniform dark navy outline, warm cream and muted
slate palette, no gradient, no shading, orthographic, pure white background
--style raw --v 7 --ar 1:1 --sref <hero-url>
```

**Note.** The counter, rails, and drawer *shadows* stay CSS/canvas — sprites are for the objects,
not the architecture, so the shelf can resize without art rework.

---

## 2. Focus Garden — foliage brushes only

Do **not** sprite whole plants. The app's core claim is that no two gardens converge, and a fixed
set of plant sprites breaks that the moment a user sees the same tree twice. The hybrid that works
(and is what SpeedTree does) is: **procedural skeleton, sprite foliage.** Branch structure is grown
per plant; the leaves are a handful of brushes stamped onto it.

Brushes want to be *neutral* — no baked lighting, no strong silhouette of their own.

```
sprite sheet, 3x3 grid, evenly spaced: nine small clusters of leaves seen flat-on, varying
density and shape — broad round leaves, narrow willow leaves, a fern frond, a conifer sprig,
a grass tuft, a moss clump, a flowering head, a berry cluster, a bare twig,
flat vector illustration, bold uniform dark navy outline, limited flat green palette,
no gradient, no shading, orthographic flat-on view, pure white background
--style raw --v 7 --ar 1:1
```

```
sprite sheet, 2x3 grid: a small mossy rock, a larger boulder, a fallen mossy log, a mushroom
cluster, a patch of clover, a small fern, flat vector illustration, bold uniform dark navy
outline, limited flat palette, no gradient, no shading, orthographic, pure white background
--style raw --v 7 --ar 3:2 --sref <foliage-url>
```

---

## 3. Weatherglass — two objects, the rest is canvas

The wall, window recess, sill, and sky are all drawn — only the mounted hardware wants art, and
even that is optional since the CSS dial already reads well.

```
a round wall-mounted thermostat dial with a brushed metal bezel and a dark circular face,
seen straight on, flat vector illustration, bold uniform dark navy outline, muted slate and
cream palette, no gradient, no shading, orthographic front view, pure white background
--style raw --v 7 --ar 1:1
```

```
sprite sheet, 1x3: a small potted succulent, a short curtain tieback, a hanging brass hook,
flat vector illustration, bold uniform dark navy outline, no gradient, no shading, orthographic,
pure white background --style raw --v 7 --ar 3:1 --sref <thermostat-url>
```

The potted plant on the sill is the detail that makes the window feel like *a room's* window.

---

## 4. Night Sky — one silhouette strip

Everything celestial is computed and drawn. The only art worth having is a foreground horizon so
the sky has something to rise behind.

```
a long horizontal silhouette strip of a distant treeline with a few rooftops and a chimney,
pure solid black shape on pure white, no interior detail, no outline, flat, seamless left and
right edges --style raw --v 7 --ar 5:1 --no gradient, texture, sky, stars
```

Generate two or three and let the app pick by location type (urban / suburban / rural).

---

## 5. Not needed

**Now Playing** and **Tetris** are fully generative — sprites would actively hurt them.
**Chess** already has its set.

**Departures** needs none either, and that's the interesting case. The split-flap departure board is
built entirely from **type and CSS**: a dot-matrix board ground, per-character tiles with a hairline
seam across the middle, and a fast `scaleY` flip on any character that changes. Amber for data,
green and red for remarks, straight from our own tokens rather than an airport's. Two things to
respect if this gets built for real — the flip should stagger by a few tens of milliseconds per
character (a board that flips in perfect unison reads as a screen, not a board), and it must
respect Reduce Motion by swapping characters without the flip. Line badges should use the transit
operator's own colours; invented transit glyphs will look wrong beside a real network's identity.

---

## 6. Focus Garden — the procedural stack

Manu's read is right: what's there now is too thin. It's value noise plus scattered lollipops, and
it looks scattered because **nothing decides where a plant should be.** Richness comes less from
prettier plants than from placement that appears reasoned. Here's the full stack, in the order it
should be built, with what each stage buys.

**One freeing constraint first:** the garden is a *static* scene. It changes when a session ends,
not per frame. So none of the op-budget arithmetic that governs Now Playing applies — this can be
as expensive as we like, drawn once and cached. That's unusual and worth exploiting.

### Stage 1 — Terrain: fBm with domain warping
Fractional Brownian motion (4–6 octaves of Perlin/simplex), with the input coordinates displaced by
a second noise field. Domain warping is the cheap trick that turns blobby hills into ridges and
valleys with a sense of flow. *This alone fixes most of what looks wrong today.*

### Stage 2 — Erosion: droplet simulation
Hydraulic erosion by particle: drop a few thousand droplets, let each carry sediment downhill,
erode where fast and deposit where slow. A few seconds of compute buys drainage channels that read
as real landscape. If that's too much, **thermal erosion** (slump anything past the talus angle) is
far cheaper and still helps.

### Stage 3 — Moisture: flow accumulation
The D8 algorithm from terrain GIS: every cell drains to its lowest neighbour; accumulate how many
cells drain through each. High accumulation is a wet valley floor, low is a dry ridge.
**This is the highest-value stage in the whole list** — it's what lets planting look considered
rather than sprinkled.

### Stage 4 — Habitat suitability
Per species, score every cell from elevation, slope, moisture, and aspect (which way it faces, so
moss favours the shaded side). Now trees cluster in valleys, scrub takes the slopes, moss finds the
damp north face — and the viewer reads intention they can't quite name.

### Stage 5 — Distribution: Poisson-disc with variable radius
Bridson's algorithm for blue-noise spacing, but with the exclusion radius driven by suitability:
tight where the habitat is good, sparse where it isn't. Blue noise is what makes scattering look
natural rather than random; the variable radius is what makes density mean something.

### Stage 6 — Succession: a cellular automaton over the ledger
The literal mechanism the brief names. States: bare → lichen → moss → grass → forb → shrub →
pioneer tree → canopy. Each tick, a cell may advance with probability from its neighbours' states
plus accumulated session energy. Run one tick per session, so the timeline *is* the ledger.

### Stage 7 — Individual plants
- **Space colonization** (Runions et al., 2007) for trees: scatter attractor points inside a crown
  envelope and iteratively grow branches toward them. This is the single biggest upgrade available —
  it produces believable, never-repeating branch structure, and it takes maybe 60 lines.
- **Stochastic parametric L-systems** (Prusinkiewicz & Lindenmayer) for ferns, grasses, and
  flowering stalks — cheaper than space colonization and ideal at small scale.
- **Phyllotaxis** (golden-angle placement) for leaves and petals on a stem.

### Stage 8 — Ground patterning
**Reaction–diffusion** (Gray–Scott) makes gorgeous organic lichen and moss blotches. **Worley /
Voronoi with Lloyd relaxation** gives meadow patchiness and stone fields. Both are cheap on a
static scene.

### Stage 9 — Depth
Not an algorithm, but the largest perceived-quality jump per line of code: three or four parallax
bands, each progressively hazed and desaturated. Atmospheric perspective is most of why a landscape
reads as a place rather than a diagram.

### Stage 10 — Colour
Interpolate a seasonal palette from the real date, then jitter the hue per garden from the ledger
hash so two people with identical session counts still don't match.

### Determinism
Everything seeds from a hash of the ledger. Erosion and the CA are iterative, so they need a fixed
seed **and** a fixed iteration count — otherwise the garden quietly changes every time it's redrawn,
which would break the promise that the ledger is the source of truth.

### Suggested build order
Stages 1 → 3 → 5 → 7a give most of the payoff. Erosion (2), succession (6), reaction–diffusion (8),
and seasonal colour (10) are the second pass. Depth (9) can be done at any point and should be done
early, because it flatters everything else.
