# DMG artwork generation prompts

Generated with the built-in GPT Image tool. `ledge-hero-reference.png` was supplied by the user and used as a style reference for every generated asset.

## Night-sky sprites

```text
Use case: stylized-concept
Asset type: 3x3 sprite sheet for DMG night-sky dressing
Input image: Image 1 is the mandatory style reference only; do not reproduce its stone ledge or clovers.
Primary request: Create exactly nine isolated night-sky sprites arranged in a precise 3-column by 3-row grid, evenly spaced and centered. Row 1: a four-point twinkle star; a tiny round star; a crescent moon. Row 2: a small drifting cloud wisp; a shooting star with a short trail; a firefly with one small circular glow-ring outline. Row 3: three stars in a compact cluster; a thin wisp of mist; a five-point sparkle.
Scene/backdrop: pure solid white, with wide clean gutters and no grid lines
Style/medium: match Image 1's hand-inked vector-storybook visual language, dark green-navy outlines, gently organic shapes, confident linework, restrained cel-painted facets; preserve small-sprite readability
Composition: square sprite sheet, nine consistent visual cells, one item per cell, no overlaps
Color palette: warm cream and pale moonlight yellow with muted gray-green cloud accents, derived from Image 1
Constraints: exactly nine requested sprites, correct row order, uniform outline character and consistent scale, clean white background suitable for flood-fill sprite extraction, no text
Avoid: stone ledge, clovers, grass, scenery, night-sky background fill, grid borders, labels, typography, photorealism, 3D, complex glow, drop shadows, extra objects, watermark
```

## Install arrows

```text
Use case: stylized-concept
Asset type: 2x2 sprite sheet of install-gesture arrows for a macOS DMG background
Input image: Image 1 is the mandatory style reference only; do not reproduce its ledge, stone, grass, or clovers.
Primary request: Create exactly four distinct upward-pointing hand-drawn arrows in a precise 2-column by 2-row grid. Top-left: a curved arrow arcing upward. Top-right: a dotted-line arrow arcing upward. Bottom-left: a small upward arrow with one playful loop-the-loop in its tail. Bottom-right: a plain short upward arrow.
Scene/backdrop: pure solid white with wide clean gutters and no grid lines
Style/medium: playful slightly wobbly ink or chalk-mark arrows matching Image 1's confident dark green-navy hand-drawn contour character; simple line art only
Composition: square sheet, four equal visual cells, one arrow per cell, all four arrowheads unmistakably point toward the top edge, no overlaps
Color palette: one dark green-navy line color sampled conceptually from Image 1
Constraints: exactly four arrows, correct cell order, line-only marks with no enclosed decorative fill, consistent visual weight, clean white background suitable for sprite extraction
Avoid: downward or sideways arrowheads, double-ended arrows, text, labels, stone, plants, background scenery, grid borders, gradients, shadows, 3D, photorealism, extra objects, watermark
```

## Companion sprites

```text
Use case: stylized-concept
Asset type: 2x2 sprite sheet of whimsical perched companions for a macOS DMG background
Input image: Image 1 is the mandatory style reference only; borrow its line character, palette, mossy charm, and restrained cel-painted facets, but do not reproduce the ledge.
Primary request: Create exactly four isolated companion sprites arranged in a precise 2-column by 2-row grid at consistent scale. Top-left: a small round owl perched with eyes closed, clearly sleeping. Top-right: the same owl awake, eyes open and peeking upward. Bottom-left: a tiny snail sitting on one simple green leaf. Bottom-right: a little bird perched and looking upward expectantly.
Scene/backdrop: pure solid white with wide clean gutters and no grid lines
Style/medium: charming hand-inked vector-storybook illustration matching Image 1, dark green-navy outlines, organic contours, slightly toy-like proportions, restrained cel-painted facets, minimal interior detail, highly readable at small size
Composition: square sprite sheet, four equal visual cells, one centered character per cell, no overlaps; the two owls must visibly be the same character in different states
Color palette: warm cream, muted gray-slate, and moss greens drawn from Image 1
Constraints: exactly four sprites in requested order, consistent outline character and visual scale, clean closed silhouettes, white background suitable for flood-fill extraction, no text
Avoid: ledge, rock platform, scenery, extra characters, grid borders, labels, typography, photorealism, 3D, complicated feather or fur texture, dramatic shadows, watermark
```

## Volume icon

```text
Use case: stylized-concept
Asset type: compact macOS DMG volume icon artwork designed to remain readable at 64 pixels
Input image: Image 1 is the mandatory style reference; reinterpret its rocky ledge, cream stone top, moss greens, dark green-navy ink, and restrained cel-painted facets as a simplified icon.
Primary request: Create one single compact rounded badge-like composition containing a tiny simplified stone ledge with moss, a tiny round sleeping owl perched securely on top, and exactly one small four-point star above it.
Scene/backdrop: pure solid white only
Style/medium: hand-inked vector-storybook icon matching Image 1, bold clean dark green-navy outline, warm cream and muted slate stone, moss-green accents, restrained cel-painted facets, very minimal interior detail, large readable shapes
Composition: centered square icon artwork, compact near-circular silhouette with balanced negative space; one unified object, no separate sprite cells; sleeping owl clearly recognizable with closed eyes; star large enough to survive downscaling
Constraints: exactly one ledge, one sleeping owl, and one four-point star; strong closed outer silhouette; consistent outline character; suitable for later white-background extraction and 64px use; no text
Avoid: full scenic platform, multiple stars, multiple animals, clovers, UI, disk icon shell, lettering, badge text, border frame, complex rock cracks, feather texture, photorealism, 3D, drop shadow, background scenery, watermark
```
