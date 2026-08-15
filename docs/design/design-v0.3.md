# Design system v0.3 — "the beauty wave" (PROPOSAL)

**Status:** awaiting ratification · **Drafted:** 2026-08-09 · **Mockups:** `mockup-v0.3.html`
(open in a browser; the motion proposals are animated there) · **Companion ticket:**
`docs/tickets/0001-widget-genre-gaps.md` (A1 drag, A7 gradients).

v0.2 gave us discipline: one metrics enum, capsule controls, semantic tokens. v0.3 is
about *beauty* — the gap between our snapshots and Alcove/the world-clock reference is
five specific things (timid type scale, boxes-not-rows, no materials, snapping values,
apologetic empty states), and all five are platform-fixable so every app improves at
once. Same format as v0.2: D-numbered proposals with recommendations inline, Q-numbered
calls for Manu at the end.

Current facts these proposals amend (verified in `ProtocolRenderer.swift` /
`Metrics.swift`, 2026-08-09):

- Text ramp: `xs` 10 · `s` 11.5 · `m` 12.5 · `l` 15 · `xl` 30. Weights: regular /
  medium / semibold / bold. **No light. Nothing between 15 and 30, nothing above 30.**
- Tabular digits are already free: non-mono text uses the monospaced-*digit* system
  font, so ticking values never jitter. Undocumented in the spec — apps don't know.
- `image` already does SF Symbols (`sf:play.fill`) but with no weight/color control.
- `divider` and `chart` (sparkline) exist. Gradients don't (known delta since the
  graduation refactor).

---

## D1 — Display typography

The references are 70% typography: a huge light numeral, a tiny mono eyebrow, nothing
in between. Nothing in our ramp can be the protagonist of a panel.

- Add `size: "display"` → **36 pt** and `size: "hero"` → **48 pt** (hero intended for
  mini/wing moments, display for panel headliners). `xl` stays 30 — existing apps
  don't move.
- Add `weight: "light"` (`.light`). Recommend **not** ultralight: SF below 30 pt at
  ultralight loses the stroke, and light already reads "jewelry" at 36.
- Add `caps: true` on text → uppercases **and** applies +6% tracking. This is the
  eyebrow idiom (`xs` + `mono` + `caps` + `secondary`). Apps can uppercase strings
  themselves but cannot letterspace, which is what makes an eyebrow an eyebrow — that's
  why it's a prop, not a convention.
- Spec documents the tabular-digit guarantee so app authors stop reaching for `mono`
  on prices out of fear.

Cost: renderer switch cases + spec table row + fixture. Trivial.

## D2 — Rows, not boxes

Stocks is six stroked cards; alarm is stacked outlined boxes; the references are
full-bleed rows with hairlines where negative space does the structure. Ruling:

> **Stroked/filled boxes are for true containers** — game boards, artwork wells,
> input surfaces. **List content is full-width rows**: inset padding, `divider`
> between, no stroke, hover = `raisedHover` fill only.

Component kit gets a `LedgeRowView` (inset + hover + optional chevron) so the idiom
is one reach away. Guidance lands in the spec beside §5, and stocks + alarm are the
proof retrofits (stocks: ticker rows w/ sparkline right; alarm: alarm rows).

Cost: guidance + one component + two app retrofits.

## D3 — Materials: wash, canvas gradient, app accent

Flat fills are why our panels read "dev tool". Three pieces, deliberately narrow:

- **`wash` prop on stack** — `wash: "#1DB9A6"` renders a standardized gradient
  (color at ~22% alpha, top → transparent by 60% height, behind children). One knob,
  no free-form gradient soup; every app's wash has the same geometry, so panels stay
  siblings. The now-playing artwork wash is `wash` fed by the dominant artwork color
  (host-side average — LedgeImageStore already decodes the bitmap).
- **Canvas `gradient` op** (§3.4): `{op:"gradient", x,y,w,h, from,to, angle}` — for
  bespoke surfaces (world-clock sky, weather). Unknown-op rule means no version bump.
- **`meta.accent`** — an app declares one accent hex; the shell tints its chrome
  *sparingly* (recommendation: selected states + hairline emphasis only, not the strip
  icon, not text). Alcove's trick of content coloring the surface, kept on a leash.

Cost: A7 ticket, upgraded from cosmetic to launch-blocking. Renderer + one host-side
dominant-color helper + spec.

## D4 — Content motion: the `transition` prop

Shell motion is good; *content* teleports. A time flipping 06:59→07:00 or a price
ticking is where this genre feels alive. Declarative and shell-side — no wire chatter,
the shell animates between committed values:

- `transition: "roll"` on text — per-digit odometer roll when old/new content differ
  only in numerals (the common ticking case); falls back to fade otherwise.
- `transition: "fade"` — crossfade for labels (track titles, statuses).
- Default remains none. **Opt-in, not ambient** — restraint is a feature; an app
  should choose its one live element.

Implementation sketch: on `update` of `content` where a `transition` is set, the
renderer keeps the old glyph layer, builds the new, and animates with the standard
spring. Digit roll = per-character vertical strip layers, CATransaction-disabled
during drag-like bursts (same rule as the slider fix).

Cost: the one genuinely new renderer feature in this wave. Medium. Fixture:
`commit-text-transition(-update)`. If we ship one thing for beauty, ship this.

## D5 — Designed empty states

Every snapshot in `.snapshots/` is an empty state, and it's what a first-launch user
sees. Pattern (convention + component, not law): one glyph (`sf:` at display size,
tertiary), one quiet sentence in the interface's voice, at most one action capsule.
No "no data". Component kit: `LedgeEmptyState(glyph:line:action:)`. Copy rules: plain
verbs, sentence case, the empty screen is an invitation to act — "Play something and
it lands here", not "Nothing playing".

Cost: one component + copy pass over all nine demo apps. An afternoon, huge first-run
delta.

## D6 — SF Symbol control

`sf:` images exist but render at fixed weight/no tint. Extend `image` with `weight`
(text ramp vocabulary) and semantic `color` for `sf:` sources. Ruling: **chrome
iconography is SF Symbols; emoji is legal only as content** (the world clock's ☾ is
content; a gear emoji in a header is not).

Cost: trivial; symbol configuration already exists in AppKit.

## D7 — One signature per app (process law)

Each launch app names **one** signature element in its header comment — the single
memorable device — and everything else in the panel stays quiet. Review checklist
gains: *"what is this app's signature? is anything else competing with it?"* Where the
current demos feel nice-but-not-art, it's because nothing is the star.

Signatures for the launch lineup: now-playing → **waveform on the artwork wash**;
world clock → **the drag-scrub ruler**; calendar copilot → **the T−minus countdown
that rolls**; pomodoro → **the ring**; weather → **the minutecast ruler**.

---

## Open questions for ratification

- **Q1 — Display ramp values/names.** `display` 36 / `hero` 48 as proposed? (Rec:
  yes; 36 fits a world-clock row at our 440 pt width with a mono eyebrow above.)
- **Q2 — `caps` prop vs app-side uppercase.** (Rec: prop — tracking is the point and
  only the shell can do it.)
- **Q3 — Standardized `wash` vs free-form gradient fills on stacks.** (Rec: `wash`
  only at §5 level, free gradients only inside canvas. Keeps sibling panels related;
  we can always loosen later, never tighten.)
- **Q4 — `transition` opt-in per node vs automatic for all numeric text.** (Rec:
  opt-in. Automatic would make *everything* roll and nothing special; also avoids
  surprise cost in dense grids like stocks.)
- **Q5 — How far does `meta.accent` tint chrome?** (Rec: selected states + hairline
  emphasis only. Strip icons stay ink; text stays semantic.)
- **Q6 — D5 as spec law vs convention?** (Rec: convention + component. Legislating
  copy feels wrong; the component makes the good path the lazy path.)

## Sequencing (after ratification)

1. **Platform wave:** D1 + D6 (trivial) → D3 (A7) → D4 (the real feature), each
   fixture-first. A1 (canvas drag, ticket 0001) rides along — the world clock needs it.
2. **Retrofit wave:** D2 rows + D5 empty states across the nine demo apps.
3. **Hero wave:** now-playing v2, world clock, calendar copilot — each built against
   its mockup panel and screenshot-reviewed on the real notch (`screencapture -x -R`,
   same as the mini-geometry review).
