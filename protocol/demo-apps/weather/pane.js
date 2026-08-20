// The pane — one canvas, and the whole app.
//
// The rule the whole file is written to: **simulate the glass, not the
// weather.** Nobody has ever been convinced by a cartoon raindrop. What reads as
// rain is what rain does to a window — beads that hold a tiny inverted copy of
// the scene behind them, a specular dot where the light is, fat ones that let go
// and run, leaving a clean track through the rest.
//
// `paneOps(scene)` is a **pure function of (t, weather(t))**. No state, no
// accumulators, no "last frame": the droplet field is regenerated from a fixed
// seed every frame and positioned by `t`, which is what lets the same function
// serve the live clock and the scrubber's time-travel. Scrub to +6 h and back
// and you get the identical picture both times.
//
// ---------------------------------------------------------------------------
// WHAT THE FIRST VERSION GOT WRONG, because everything below is a reaction to it
//
// It was written to the rule "softness is alpha: many faint overlapping discs
// have no findable edge, where one solid disc has an edge you can trace." That
// is true, and it is why the pane came out of the first pass as a **fuzzy grey
// blob**. Judged at 2× it looked atmospheric; at 1×, at the size a notch panel
// is actually glanced at, overcast, drizzle and fog were the same picture — a
// uniform wash with nothing in it to name.
//
// The correction is not more detail. It is **structure and value**:
//
//   * **Clouds are opaque shapes, not smudges.** A mass is a body you could
//     trace, and its softness comes from how close its value is to the sky's,
//     not from how transparent it is. Alpha stacking was buying blur at the
//     price of form, and form is the only thing legible at 412 × 188.
//   * **Three depth layers with distinct values**, drifting at different speeds.
//     An overcast sky is layered grey masses, not fog.
//   * **A horizon.** A flat dark silhouette along the bottom tenth of the pane.
//     It costs twenty ops and it gives every scene depth, scale, and something
//     for rain to streak against and snow to bank on. Without it the pane is a
//     swatch; with it, it is a window.
//   * **At least three separable values per condition.** Overcast: dark ceiling,
//     lit gap at the rim, black skyline. Fog: the opposite — the skyline is
//     *swallowed*, and that is how you tell the two apart at a glance.
//
// Two constraints shape every technique:
//
//   * **There is no blur filter.** §3.4 gives you `rect` (rounded, filled),
//     `line`, `gradient` (axial), `image` and `text`. What is genuinely soft
//     here — the sun's bloom, the fog veil, a cloud's shaded base — is built out
//     of gradients and near-neighbour values, and everything else is drawn.
//   * **A few hundred ops a frame, at ~11 fps.** Clear sky is ~90, a full
//     downpour ~330. The budget is why a droplet is three ops (rim, lens,
//     specular) and the mist between them is one.

import { WET_MM } from "./forecast.js";
import { sunOnPane } from "./solar.js";

const RAD = Math.PI / 180;

// ---------------------------------------------------------------- colour

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const lerp = (a, b, k) => a + (b - a) * k;
const mix = (a, b, k) => [lerp(a[0], b[0], k), lerp(a[1], b[1], k), lerp(a[2], b[2], k)];
const scale = (c, k) => [c[0] * k, c[1] * k, c[2] * k];
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];

const byte = (v) => {
  const n = Math.round(v < 0 ? 0 : v > 255 ? 255 : v);
  return n < 16 ? `0${n.toString(16)}` : n.toString(16);
};
/** Draw ops take hex, never palette tokens — a canvas is pixels, not a view. */
const hex = (c, alpha = 1) =>
  `#${byte(c[0])}${byte(c[1])}${byte(c[2])}${alpha >= 1 ? "" : byte(clamp01(alpha) * 255)}`;

/** Half-point quantisation: the renderer draws on a 2× backing store, so
 * anything finer is a blur the app is paying for and cannot see. */
const q = (v) => Math.round(v * 2) / 2;

/** Deterministic PRNG (mulberry32). Seeded per field, never per frame — the
 * droplets have to be in the same places at t and at t again. */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const frac = (v) => v - Math.floor(v);
const smooth = (k) => (k <= 0 ? 0 : k >= 1 ? 1 : k * k * (3 - 2 * k));

// ---------------------------------------------------------------- the ground
//
// Where the sky stops. Everything below this line is the silhouette band, and
// everything above it ramps from zenith to horizon — so the horizon colour lands
// *at the skyline* rather than at the bottom edge of a bottomless picture.

const HORIZON = 0.9;

/**
 * The three depth layers, in the order they arrive as the sky fills.
 *
 * `at`/`thick` are fractions of the pane's height, `speed` multiplies the wind's
 * drift so the deck has parallax, and `tone` is the mix from the deck's shadow
 * colour toward its lit colour.
 *
 * `lidShift` is what stops the value story from being a lie. A cloud in a blue
 * sky is *brighter* than the sky; the same cloud under a full deck is a
 * silhouette against the lit gap at the horizon and is *darker* than it. One
 * fixed tone per layer gets one of those two right and paints a pale shelf
 * across every overcast scene, which is what the first pass did.
 *
 * `lumps` says which edge is modelled. A heap is seen from the side and its
 * *top* is the shape; a ceiling is seen from underneath and its *base* is.
 */
const LAYERS = [
  // Always present once there is any cloud at all: the mid-distance heap.
  { at: 0.22, thick: 0.23, speed: 0.72, tone: 0.80, lidShift: 0.34, lumps: "top", masses: 2, span: 0.30 },
  // Appears as the sky fills: a band lying along the horizon, behind the rest.
  { at: 0.56, thick: 0.12, speed: 0.30, tone: 0.70, lidShift: 0.52, lumps: "top", masses: 2, span: 0.44 },
  // Overcast: the ceiling, overhead, dark, and continuous across the pane.
  { at: -0.04, thick: 0.34, speed: 1.15, tone: 0.17, lidShift: 0.06, lumps: "bottom", masses: 2, span: 0.76 },
];

// ---------------------------------------------------------------- the sky

/** Sky by sun elevation: zenith over horizon, keyframed and interpolated. The
 * two twilight rows are close together on purpose — the whole colour story of a
 * day happens in the twelve degrees either side of the horizon. */
const SKY = [
  // The night rows are lifted well above "black": the pane sits on the panel's
  // own black glass, and a sky that is genuinely dark is not a night sky, it is
  // a hole. Real windows never go to zero either — there is always airglow.
  { el: -18, zenith: [15, 19, 36], horizon: [32, 38, 64] },
  { el: -6, zenith: [22, 29, 58], horizon: [62, 56, 92] },
  { el: -1, zenith: [44, 60, 106], horizon: [186, 106, 74] },
  { el: 6, zenith: [48, 106, 180], horizon: [236, 172, 110] },
  { el: 20, zenith: [42, 114, 198], horizon: [154, 196, 234] },
  { el: 45, zenith: [32, 101, 200], horizon: [172, 208, 242] },
  { el: 90, zenith: [27, 94, 198], horizon: [180, 214, 246] },
];

function skyBand(el) {
  if (el <= SKY[0].el) return SKY[0];
  for (let i = 1; i < SKY.length; i += 1) {
    if (el <= SKY[i].el) {
      const k = (el - SKY[i - 1].el) / (SKY[i].el - SKY[i - 1].el);
      return {
        zenith: mix(SKY[i - 1].zenith, SKY[i].zenith, k),
        horizon: mix(SKY[i - 1].horizon, SKY[i].horizon, k),
      };
    }
  }
  return SKY[SKY.length - 1];
}

// ---------------------------------------------------------------- the scene
//
// Everything the glass has behind it, as numbers — built once per frame and
// then sampled, because a droplet has to know what colour it is refracting.

function buildScene({ w, h, weather, place, phaseT }) {
  // `phaseT`, not the raw `t`: under Reduce Motion it is quantised, and the sun
  // has to be quantised with everything else or the pane is not actually still —
  // it just moves too slowly to catch, which is the same bug with better manners.
  const sun = sunOnPane(phaseT, place.lat, place.lon);
  const cover = clamp01(weather.cloud / 100);
  const wet = clamp01(weather.precip / 3);
  const band = skyBand(sun.elevation);
  const skyY = h * HORIZON;

  // Cloud and rain drain the colour out of a sky; the grey they drain it toward
  // is the sky's own brightness, so an overcast noon is pale and an overcast
  // midnight stays black.
  const greyness = Math.min(0.88, clamp01(cover * 0.85 + wet * 0.3));
  const grey = (c) => {
    const l = (c[0] * 0.3 + c[1] * 0.55 + c[2] * 0.15) * 0.82;
    return [l, l * 1.02, l * 1.1];
  };
  const dim = 1 - wet * 0.28;
  // **The deck opens the sky's own range rather than closing it.** Under cloud
  // the zenith is the underside of the ceiling — heavy — and the horizon is the
  // gap you are looking out through — luminous. Draining both toward one grey
  // (which is what the first version did) is exactly how a covered sky becomes a
  // swatch: two values a point apart, at the size of a stamp.
  // How much of a *lid* the cloud is, 0…1 — the knob for every "is this a
  // ceiling or a few clouds" decision below. Daylight deepens it (a deck at noon
  // is a dramatic thing), but it never falls to zero after dark, because an
  // overcast midnight is still overcast.
  const lidded = cover * (0.55 + 0.45 * clamp01((sun.elevation + 6) / 24));
  const zenith = scale(mix(band.zenith, grey(band.zenith), greyness), dim * (1 - 0.34 * lidded));
  const horizon = scale(mix(band.horizon, grey(band.horizon), greyness), dim * (1 + 0.24 * lidded));

  // The sun's light on the pane: strongest just above the horizon, gone below
  // it, mostly gone under a thick deck.
  const strength = clamp01((sun.elevation + 4) / 9) * (1 - cover * 0.72);
  const warmth = clamp01(1 - sun.elevation / 30);
  const sunColour = mix([255, 250, 236], [255, 186, 108], warmth);
  const sx = sun.across * w;
  const sy = (1 - sun.up) * h * 0.92;

  // A city under a night sky is not black — it puts an orange floor under the
  // clouds, and that floor is what the droplets refract after dark.
  const glow = clamp01(-sun.elevation / 8) * (0.22 + cover * 0.3);

  // Warm only while there is a sun to be warm *from*: `warmth` rises as the sun
  // sinks, so multiplying by it alone paints midnight clouds in sunset orange.
  // And **dim with the day**: white is a colour a cloud only has when something
  // is lighting it. A near-white heap at midnight is the single loudest wrong
  // note a sky like this can play.
  const daylight = clamp01((sun.elevation + 8) / 20);
  const cloudLit = scale(
    mix([236, 240, 246], sunColour, warmth * clamp01(strength * 1.8) * 0.7),
    0.2 + 0.8 * daylight,
  );
  // At night a cloud is barely lighter than the sky it is in front of, and what
  // light it has comes off the city underneath it. Drawing it at daytime grey is
  // what turns a dark pane into a lava lamp.
  // …and after dark the light it *does* have is the town's, which is warm. That
  // is not decoration either: an overcast city night is a dull orange lid, and
  // painting it as neutral grey leaves the deck and the sky at the same value,
  // which at 1× is a brown rectangle with nothing in it.
  const cloudDark = add(
    scale(mix(zenith, [92, 100, 116], 0.2 + strength * 0.42), 1 - wet * 0.34),
    scale([48, 31, 15], glow * 1.15),
  );

  // The deck. Drift is a function of wind and t, so the sky moves with the
  // scrubber the way the sun does — and each layer moves at its own rate, which
  // is the only depth cue a flat picture of a sky can have.
  const drift = (phaseT / 3_600_000) * weather.wind * 2.4;
  const lateral = Math.sin(weather.dir * RAD) || 0.4;
  // How many layers are in play. One heap is "a few clouds"; three is a lid.
  // Fog is not a cloudscape. Whatever the code says the cover is, what you can
  // see of the sky in fog is one soft bank and no structure at all — the veil is
  // the picture, and a legible deck behind it would contradict it.
  const depth =
    weather.kind === "fog"
      ? 1
      : cover < 0.05
        ? 0
        : cover < 0.3
          ? 1
          : cover < 0.72
            ? 2
            : 3;
  const random = rng(0x5eed1);
  const masses = [];
  for (let layer = 0; layer < depth; layer += 1) {
    const spec = LAYERS[layer];
    // Each layer's own value — this is where the three greys come from, and the
    // lid shift is what makes them come out in the right *order* under a deck.
    const colour = mix(cloudDark, cloudLit, clamp01(spec.tone - lidded * spec.lidShift));
    const span = spec.span * (0.8 + cover * 0.5) * w;
    const margin = span;
    const period = w + 2 * margin;
    for (let i = 0; i < spec.masses; i += 1) {
      const jitter = 0.7 + random() * 0.6;
      const x0 = ((i + 0.5) / spec.masses) * period + (random() - 0.5) * period * 0.3;
      const shift = drift * spec.speed * lateral;
      const x = ((((x0 + shift) % period) + period) % period) - margin;
      masses.push({
        x,
        top: spec.at * h + (random() - 0.5) * 0.05 * h,
        span: span * jitter,
        thick: spec.thick * h * jitter,
        colour,
        // The base is always darker than the body: it is the part of the cloud
        // the light never reaches, and it is what makes a mass look like it has
        // a volume rather than a footprint.
        base: mix(colour, scale(cloudDark, 0.82), 0.62),
        lumpsDown: spec.lumps === "bottom",
        // The ceiling has no top edge on the pane — it runs off it.
        toTop: spec.lumps === "bottom",
        seed: 0x1000 + layer * 977 + i * 97,
      });
    }
  }

  // Cloud density across the pane, in buckets — the cheap version of the deck a
  // droplet samples. Sampling the real mass list per droplet is dozens of terms
  // a frame; this is 24 numbers built once.
  const BUCKETS = 24;
  const density = new Float64Array(BUCKETS);
  for (const mass of masses) {
    for (let b = 0; b < BUCKETS; b += 1) {
      const x = ((b + 0.5) / BUCKETS) * w;
      const d = (x - mass.x) / (mass.span * 0.62);
      density[b] += Math.exp(-d * d) * (mass.toTop ? 1 : 0.6);
    }
  }

  // The silhouette along the bottom — the one thing in the picture with a known
  // size. See `drawSkyline`; it is built here because the droplets refract it.
  const skyline = buildSkyline(w, h, skyY);
  // A silhouette is not black: it takes the sky's own hue and almost none of its
  // light. Almost — at night "almost none of very little" is a hole, so it is
  // floored against a colour rather than against zero.
  const ink = mix(scale(horizon, 0.17), [9, 11, 15], 0.5);

  /** What is behind the glass at (x, y) — sky, plus the sun's bloom, plus
   * whatever cloud is in the way, plus the ground. This is the function the
   * droplets refract, and the ground being in it is why the beads along the
   * bottom of the pane carry a dark band: a lens there is looking at a roof. */
  const sample = (x, y) => {
    if (y >= skyline.heightAt(x)) return ink;
    const k = clamp01(y / skyY) ** 1.15;
    let c = mix(zenith, horizon, k);
    if (glow > 0) c = add(c, scale([72, 46, 22], glow * k * k));
    if (strength > 0) {
      const dx = (x - sx) / (w * 0.62);
      const dy = (y - sy) / (h * 0.85);
      c = add(c, scale(sunColour, Math.exp(-(dx * dx + dy * dy) * 2.1) * strength * 0.85));
    }
    const b = Math.max(0, Math.min(BUCKETS - 1, Math.floor((x / w) * BUCKETS)));
    // Only where there is actually deck above: a droplet low on the pane is
    // refracting the bright gap at the rim, not the ceiling.
    const d = clamp01(density[b]) * (1 - smooth(clamp01((y / skyY - 0.45) / 0.5)) * 0.8);
    if (d > 0) {
      const lit = clamp01(strength * (1 - Math.abs(x - sx) / w) + 0.15);
      c = mix(c, mix(cloudDark, cloudLit, lit), d * 0.7);
    }
    return c;
  };

  // How bright the scene is overall, 0…1 — the knob the glass effects scale
  // themselves by. A reflection that costs 26% of the light is a highlight at
  // noon and a black hole at midnight.
  const luma = clamp01(((zenith[1] + horizon[1]) / 2 / 150) ** 0.7);

  return {
    w,
    h,
    skyY,
    luma,
    sun,
    sx,
    sy,
    cover,
    wet,
    zenith,
    horizon,
    strength,
    sunColour,
    glow,
    masses,
    skyline,
    ink,
    cloudLit,
    cloudDark,
    lateral,
    sample,
    weather,
  };
}

// ---------------------------------------------------------------- the horizon

/**
 * The skyline: rooftops as one flat dark shape along the bottom of the pane.
 *
 * The single most valuable twenty ops in the file. Before it, every scene was a
 * gradient with weather sprinkled on it — no scale, no depth, and no way to tell
 * a 412-point pane from a colour swatch. With it there is a *place*: the sky is
 * above something, rain streaks past something, snow banks against something,
 * and fog is legible precisely because it is the one condition where the
 * silhouette goes missing.
 *
 * Built as data rather than drawn directly because the droplets refract it —
 * `sample` asks `heightAt(x)` — and because it must be identical at t and at t
 * again. Deterministic: one fixed seed, no time in it at all. A skyline that
 * drifted would be an earthquake.
 */
function buildSkyline(w, h, skyY) {
  const random = rng(0xb1d5);
  const blocks = [];
  const deep = h - skyY; // the band's full depth, ~10% of the pane
  let x = -6;
  while (x < w + 6) {
    const width = 14 + random() * 46;
    // Most roofs sit low in the band; one in six is a taller block, and those
    // are what stop the row reading as a serrated line.
    const tall = random() < 0.17;
    const rise = deep * (tall ? 1.5 + random() * 1.1 : 0.28 + random() * 0.55);
    blocks.push({ x: q(x), w: q(width), top: q(h - rise) });
    x += width + (random() < 0.3 ? 2 + random() * 5 : 0);
  }
  return {
    blocks,
    /** The y of the roofline at x — the ground's silhouette, for `sample`. */
    heightAt: (px) => {
      for (const block of blocks) {
        if (px >= block.x && px < block.x + block.w) return block.top;
      }
      return h;
    },
  };
}

// ---------------------------------------------------------------- the scene, drawn

function drawSky(ops, s) {
  ops.push({
    op: "gradient",
    x: 0,
    y: 0,
    w: s.w,
    h: s.h,
    from: hex(s.zenith),
    to: hex(s.horizon),
  });

  // Stars, before anything is in front of them. Not decoration: after dark they
  // are the only thing in the scene with an edge, and an edge is what a droplet
  // needs in order to look like a lens.
  if (s.sun.elevation < -4 && s.cover < 0.7) {
    const random = rng(0xa571);
    const visible = clamp01((-s.sun.elevation - 4) / 8) * (1 - s.cover / 0.7);
    for (let i = 0; i < 16; i += 1) {
      const x = q(random() * s.w);
      const y = q(random() * s.skyY * 0.78);
      const size = random() < 0.25 ? 1.5 : 1;
      ops.push({
        op: "rect",
        x,
        y,
        w: size,
        h: size,
        radius: size / 2,
        fill: hex([222, 230, 246], visible * (0.3 + random() * 0.5)),
      });
    }
  }

  // The city's floor under a night sky. It sits low and stops at the roofline,
  // because it is light coming *off the ground* — a glow that reached the zenith
  // would be a fire, not a town.
  if (s.glow > 0.02) {
    ops.push({
      op: "gradient",
      x: 0,
      y: s.skyY * 0.58,
      w: s.w,
      h: s.skyY * 0.42,
      from: hex([150, 96, 44], 0),
      to: hex([150, 96, 44], clamp01(s.glow) * 0.34),
    });
  }

  // **The gap at the rim.** Under a deck the brightest thing in the picture is
  // the strip of sky just above the horizon, where you are looking out from
  // underneath the cloud rather than up into it. It is the second value of the
  // three an overcast scene needs, and drawing it explicitly (rather than hoping
  // the sky gradient supplies it) is what makes 100% cloud read as a *ceiling*
  // instead of as fog.
  const rim = s.cover * clamp01(0.3 + s.sun.elevation / 24) * (1 - s.wet * 0.25);
  if (rim > 0.04) {
    ops.push({
      op: "gradient",
      x: 0,
      y: s.skyY * 0.46,
      w: s.w,
      h: s.skyY * 0.54,
      from: hex(s.horizon, 0),
      to: hex(mix(s.horizon, [255, 255, 255], 0.22), clamp01(rim) * 0.62),
    });
  }
}

/**
 * The skyline, drawn.
 *
 * A flat dark shape, one rect per block, and a single polyline along the tops.
 * The line is what keeps the silhouette from disappearing into a night sky: a
 * roof edge catches a thread of whatever light there is, and one `line` op buys
 * the separation that would otherwise cost a gradient per block.
 */
function drawSkyline(ops, s) {
  const ink = s.ink;
  for (const block of s.skyline.blocks) {
    ops.push({ op: "rect", x: block.x, y: block.top, w: block.w, h: q(s.h - block.top) + 2, fill: hex(ink) });
  }

  // The rim light along the roofline, one polyline: up the left edge of each
  // block, across its top, down its right edge. Faint, and brighter at night
  // relative to its sky, which is when a silhouette needs it.
  const points = [];
  for (const block of s.skyline.blocks) {
    points.push([block.x, block.top], [q(block.x + block.w), block.top]);
  }
  ops.push({
    op: "line",
    points,
    stroke: hex(mix(s.horizon, [255, 255, 255], 0.3), 0.22 + 0.2 * (1 - s.luma)),
    width: 1,
  });

  // Windows. Four or five warm specks once the sun is down — the only warm
  // colour in a night scene, and the reason the glow above is believable.
  if (s.sun.elevation < -2) {
    const random = rng(0x77d0);
    const lit = clamp01(-s.sun.elevation / 6);
    for (const block of s.skyline.blocks) {
      if (random() > 0.34) continue;
      const wx = q(block.x + 3 + random() * Math.max(1, block.w - 8));
      const wy = q(block.top + 3 + random() * Math.max(1, s.h - block.top - 8));
      ops.push({
        op: "rect",
        x: wx,
        y: wy,
        w: 1.5,
        h: 2,
        fill: hex([255, 206, 132], lit * (0.35 + random() * 0.45)),
      });
    }
  }
}

/**
 * The sun: concentric discs, painted outside in.
 *
 * §3.4 has no radial gradient, so a bloom costs rings — and the naive version
 * (a handful of discs at eyeballed alphas) reads as a dartboard. The alphas here
 * are *solved* instead: for a Gaussian profile `P(r)`, painting a disc of alpha
 * `a` over accumulated coverage `C` yields `C + a(1 − C)`, so each ring's alpha
 * is whatever closes the gap to `P` at its radius. Sixteen of those and the
 * seams fall under the eye.
 */
function drawSun(ops, s) {
  if (s.strength <= 0.01) return;

  // The broad half of the light: one full-pane wash, aimed *from* the sun. It
  // covers the pane, so it has no edge of its own, and it does the work the
  // outer rings would otherwise do badly — this is the "directional warm
  // gradient that moves with the real sun position" the brief asks for.
  const dx = s.sx - s.w / 2;
  const dy = s.sy - s.h / 2;
  if (dx !== 0 || dy !== 0) {
    ops.push({
      op: "gradient",
      x: 0,
      y: 0,
      w: s.w,
      h: s.h,
      from: hex(s.sunColour, 0),
      to: hex(s.sunColour, 0.16 * s.strength),
      angle: (Math.atan2(dx, dy) * 180) / Math.PI,
    });
  }

  // Forty rings, not sixteen. The alphas are solved, but the *profile* is still
  // a staircase, and a 5% step between two adjacent discs is a Mach band you can
  // trace with a finger. Halving the step is the only cure the op set allows.
  // Under a deck there is no *disc* of light, only a brightening — so the rings
  // fade with the square of the clear sky while the wash above does not. A warm
  // blob showing through 92% cloud is the tell that the sun was drawn as a
  // sprite rather than as light.
  const focus = (1 - s.cover) ** 2;
  if (focus < 0.03) return;
  const RINGS = 40;
  const sigma = Math.min(s.w, s.h) * 0.16;
  const outer = sigma * 3.4;
  const peak = Math.min(0.95, 0.5 + s.strength * 0.5) * focus;
  let covered = 0;
  for (let i = RINGS; i >= 1; i -= 1) {
    const r = (outer * i) / RINGS;
    const target = peak * Math.exp(-((r / sigma) ** 2)) * s.strength;
    const alpha = (target - covered) / (1 - covered);
    covered = target;
    if (alpha < 0.0015) continue;
    ops.push({
      op: "rect",
      x: q(s.sx - r),
      y: q(s.sy - r),
      w: q(r * 2),
      h: q(r * 2),
      radius: r,
      fill: hex(s.sunColour, alpha),
    });
  }
  // The disc itself, only when there is enough clear sky to see one.
  if (s.cover < 0.55 && s.sun.elevation > -1) {
    const r = 7 + (1 - clamp01(s.sun.elevation / 40)) * 3;
    ops.push({
      op: "rect",
      x: q(s.sx - r),
      y: q(s.sy - r),
      w: q(r * 2),
      h: q(r * 2),
      radius: r,
      fill: hex(mix(s.sunColour, [255, 255, 255], 0.5), 0.85 * (1 - s.cover / 0.55)),
    });
  }
}

/**
 * The deck: two or three layers of cloud, back to front, each a value of its
 * own and each drifting at its own rate.
 *
 * **Opaque.** That is the whole reversal from the first version, which drew
 * clouds as a dozen discs at 12% alpha on the theory that an edge you can trace
 * is a sticker. It is a good theory and it produced a pane with no clouds in it:
 * at 1×, twelve faint discs are a smudge, and a sky full of smudges is a swatch.
 * A cloud reads as a cloud because it has a *form* — a lumpy top, a shaded base,
 * a silhouette against something else. Softness is then a matter of how close
 * its value sits to the sky's, which is a thing you can tune; blur is not
 * something this op set can do at all.
 *
 * One mass is: a slab, a run of discs along the modelled edge, and a second
 * shorter run along the base in a darker tone. Twelve-ish ops, and the darker
 * run is what gives the mass a volume rather than a footprint.
 */
function drawMass(ops, s, mass) {
  const thick = mass.thick;
  const left = mass.x - mass.span / 2;
  const bottom = mass.top + thick;
  // The ceiling runs off the top of the pane; a heap floats.
  const top = mass.toTop ? -10 : mass.top;

  // **How many swellings** is not a constant — it is whatever makes them
  // *overlap*. A mass four times wider than it is thick, decorated with a fixed
  // seven circles, is a string of beads with a bar behind it, which is precisely
  // what the previous attempt drew. Spacing has to stay under the smallest
  // radius the loop can produce, so the count comes out of the geometry.
  const smallest = thick * 0.29;
  const lumps = Math.max(3, Math.min(9, Math.ceil(mass.span / (smallest * 1.6))));

  /** One pass of the silhouette — slab plus swellings — in a single colour. */
  const silhouette = (colour, dy) => {
    const slabTop = mass.lumpsDown ? top : top + thick * 0.42;
    const slabBottom = mass.lumpsDown ? bottom - thick * 0.3 : bottom;
    ops.push({
      op: "rect",
      x: q(left),
      y: q(slabTop + dy),
      w: q(mass.span),
      h: q(Math.max(2, slabBottom - slabTop)),
      radius: q(mass.toTop ? 8 : (slabBottom - slabTop) / 2),
      fill: hex(colour),
    });
    const random = rng(mass.seed);
    const edgeY = mass.lumpsDown ? slabBottom : slabTop;
    // The cap above can leave the swellings too far apart on a very wide, thin
    // mass — the horizon band, which is four times wider than the ceiling is
    // thick. When that happens the radius floor rises to meet the spacing, so
    // the edge is always a continuous ripple and never a dotted line.
    const floor = Math.max(thick * 0.29, (mass.span / lumps) * 0.62);
    for (let i = 0; i < lumps; i += 1) {
      const along = (i + 0.5) / lumps;
      // The arc: fat in the middle, thin at the ends. Anything flatter is a bar.
      const swell = Math.sin(along * Math.PI) ** 0.42;
      const r = Math.max(floor, thick * (0.29 + swell * 0.33) * (0.88 + random() * 0.3));
      const cx = left + along * mass.span + (random() - 0.5) * thick * 0.3;
      const cy = edgeY + (mass.lumpsDown ? -1 : 1) * r * 0.55 + (random() - 0.5) * thick * 0.1;
      ops.push({
        op: "rect",
        x: q(cx - r),
        y: q(cy - r + dy),
        w: q(r * 2),
        h: q(r * 2),
        radius: q(r),
        fill: hex(colour),
      });
    }
  };

  // The soft underside, in the only way this op set can honestly do one: the
  // **same silhouette, in the shadow tone, nudged down**. What shows is a dark
  // rim that follows the mass's own lumpy edge exactly — which is what a cloud's
  // shaded base is — and it costs no clipping, no mask and no guesswork about
  // where the outline went.
  silhouette(mass.base, thick * (mass.lumpsDown ? 0.1 : 0.17));
  silhouette(mass.colour, 0);
}

function drawClouds(ops, s) {
  // A shut sky is **continuous**. Two drifting ceiling masses will sooner or
  // later show a gap between their rounded ends, and a rounded corner in the
  // corner of the pane reads as a bubble rather than as weather. So when the sky
  // is closed, one full-width slab underwrites the masses and they become
  // modelling on top of it rather than the ceiling itself.
  if (s.cover > 0.8 && s.masses.length > 0) {
    const ceiling = s.masses[s.masses.length - 1];
    ops.push({
      op: "rect",
      x: -4,
      y: -4,
      w: s.w + 8,
      h: q(ceiling.top + ceiling.thick * 0.7 + 4),
      fill: hex(ceiling.colour),
    });
  }
  for (const mass of s.masses) drawMass(ops, s, mass);

  // The fringe: one soft wash pulling the deck's lowest edge into the sky under
  // it, so the ceiling has a hem rather than a cut. Gradients are the one thing
  // in the op set that *is* genuinely soft, so the softness is spent here, on
  // the join, instead of being smeared over the whole sky.
  if (s.cover > 0.7) {
    const hem = s.masses.reduce((y, mass) => Math.max(y, mass.top + mass.thick), 0);
    ops.push({
      op: "gradient",
      x: 0,
      y: q(hem - 12),
      w: s.w,
      h: q(Math.max(8, s.skyY * 0.3)),
      from: hex(mix(s.cloudDark, s.cloudLit, 0.16), 0.55 * clamp01((s.cover - 0.7) / 0.3)),
      to: hex(s.horizon, 0),
    });
  }
}

/** Rain falling *behind* the pane: soft slanted streaks, well out of focus.
 * The glass is the subject, but a window with beads on it and nothing happening
 * beyond reads as a leak rather than as weather. */
function drawFallingRain(ops, s, phaseT) {
  if (s.weather.precip < WET_MM) return;
  const wet = clamp01(s.weather.precip / 3);
  // Extinction. Rain is a lot of water between you and the roofs, and it eats
  // the far end of the scene — which is a *scene* effect, so it goes on before
  // the glass and it is the one veil in the file that earns its alpha: it is
  // what makes a wet skyline sit further away than a dry one.
  ops.push({
    op: "gradient",
    x: 0,
    y: 0,
    w: s.w,
    h: s.h,
    from: hex(mix(s.horizon, [188, 196, 208], 0.5), 0.02 + wet * 0.05),
    to: hex(mix(s.horizon, [188, 196, 208], 0.5), 0.06 + wet * 0.16),
  });
  const count = Math.round(6 + wet * 12);
  const slant = s.lateral * clamp01(s.weather.wind / 45) * 26;
  const random = rng(0xfa11);
  const back = mix(s.zenith, [255, 255, 255], 0.55);
  for (let i = 0; i < count; i += 1) {
    const speed = 300 + random() * 260;
    const x = random() * (s.w + 60) - 30 + slant * 0.6;
    const y = frac(phaseT / speed + random()) * (s.h + 70) - 60;
    const len = 26 + random() * 34 + wet * 22;
    const points = [
      [q(x), q(y)],
      [q(x + (slant * len) / 100), q(y + len)],
    ];
    ops.push({ op: "line", points, stroke: hex(back, 0.028 + wet * 0.03), width: 3.2 });
    ops.push({ op: "line", points, stroke: hex(back, 0.04 + wet * 0.045), width: 1.4 });
  }
}

// ---------------------------------------------------------------- the glass

/** Haze and the room. The pane is between you and the sky: a little of the sky
 * scatters on the way in, and a little of the room you are standing in comes
 * back off the inner surface. Both are what makes the picture sit *behind*
 * something rather than being the something. */
function drawHaze(ops, s) {
  // Halved against the first version, and it is the cheapest legibility there
  // is: three white washes at a couple of percent each *add up*, and on a bright
  // overcast pane they were most of the reason the picture had no blacks in it.
  ops.push({
    op: "gradient",
    x: 0,
    y: 0,
    w: s.w,
    h: s.h,
    from: hex([255, 255, 255], 0.008 + 0.014 * s.luma),
    to: hex([255, 255, 255], 0),
  });
}

/**
 * The reflection and the specular sheen, drawn *over* the water: one surface,
 * and the drops are on it. Kept faint — at any strength you can name it, it
 * stops being glass and becomes a white triangle.
 *
 * Both cover the **whole pane**. An overlay gradient inset from the edge shows
 * its own rectangle: `drawsBeforeStartingLocation` paints right up to the rect's
 * boundary and then stops dead, so a half-height wash lays a hard horizontal
 * seam across the sky. Cover the pane and the only edge is the pane's.
 */
function drawSurface(ops, s) {
  ops.push({
    op: "gradient",
    x: 0,
    y: 0,
    w: s.w,
    h: s.h,
    from: hex([255, 255, 255], 0.014 + 0.042 * s.luma),
    to: hex([255, 255, 255], 0),
    angle: 128,
  });
  ops.push({
    op: "gradient",
    x: 0,
    y: 0,
    w: s.w,
    h: s.h,
    from: hex([10, 14, 22], 0),
    to: hex([10, 14, 22], 0.06 + 0.14 * s.luma),
    angle: 208,
  });
}

/** The pane's own recess — the four edges going dark. Without it the canvas is
 * a picture of a sky; with it, it is a hole in the panel with a sky behind it. */
function drawEdges(ops, s) {
  const d = 14;
  const ink = [0, 0, 0];
  const strong = 0.14 + 0.18 * s.luma;
  const edge = (x, y, w, h, angle) =>
    ops.push({ op: "gradient", x, y, w, h, from: hex(ink, strong), to: hex(ink, 0), angle });
  edge(0, 0, s.w, d, 0);
  edge(0, s.h - d, s.w, d, 180);
  edge(0, 0, d, s.h, 90);
  edge(s.w - d, 0, d, s.h, 270);
}

// ---------------------------------------------------------------- water

/**
 * One droplet: a lens, and only a lens.
 *
 * A bead of water on a window is a short-focus lens. It shows you what is
 * *beyond* it, **inverted**, squeezed into a few points, and brighter than the
 * surroundings because it gathers light from a wider cone than the flat glass
 * around it. So the fill is a gradient built from two samples of the scene taken
 * above and below the drop and swapped — top of the drop shows what is under it,
 * bottom shows what is over it. That inversion is the entire trick; without it
 * you have a grey circle, and with it people say "it's raining."
 *
 * Three ops: the rim (a darker disc half a point larger, which is the meniscus),
 * the lens, and the specular dot — placed on the side the light is coming from.
 */
function droplet(ops, s, x, y, r, alpha = 1) {
  const reach = r * 4.2;
  const above = s.sample(x, Math.max(0, y - reach));
  const below = s.sample(x, Math.min(s.h, y + reach));
  const gain = 1.3;

  // A bead under about two points is a highlight and nothing else — the rim and
  // the specular are smaller than a pixel there, and the ops they cost are
  // better spent on more beads.
  if (r > 1.8) {
    ops.push({
      op: "rect",
      x: q(x - r - 0.5),
      y: q(y - r - 0.5),
      w: q(r * 2 + 1),
      h: q(r * 2 + 1),
      radius: r + 0.5,
      fill: hex([0, 0, 0], 0.3 * alpha),
    });
  }
  ops.push({
    op: "gradient",
    x: q(x - r),
    y: q(y - r),
    w: q(r * 2),
    h: q(r * 2),
    radius: r,
    // `from` lands at the TOP of the rect (angle 0 runs top to bottom), and it
    // is the sample from *below* the drop: that swap is the inversion, and the
    // inversion is the only reason this reads as a lens.
    from: hex(scale(below, gain), alpha),
    to: hex(scale(above, gain * 0.72), alpha),
  });
  if (r > 1.6) {
    // Toward the light: at night that is the horizon glow, so it falls low.
    const dx = s.strength > 0.05 ? Math.sign(s.sx - x) || 1 : 0;
    const dy = s.strength > 0.05 ? -1 : 1;
    const sr = Math.max(0.75, r * 0.3);
    ops.push({
      op: "rect",
      x: q(x + dx * r * 0.34 - sr),
      y: q(y + dy * r * 0.36 - sr),
      w: q(sr * 2),
      h: q(sr * 2),
      radius: sr,
      fill: hex([255, 255, 255], 0.62 * alpha),
    });
  }
}

/** Rain, as it appears on the *inside* of a window: beads that sit and grow,
 * and a few heavy ones that let go and run, wiping a clean track behind them. */
function drawRain(ops, s, phaseT) {
  const rate = s.weather.precip;
  if (rate < WET_MM) return;
  const wet = clamp01(rate / 3);
  // **Drizzle is a bead count, not a bead size.** The two conditions that were
  // impossible to tell apart at 1× were overcast and drizzle, and the reason was
  // arithmetic: at 0.35 mm this used to draw eleven small beads and no mist at
  // all, which on a grey pane is invisible. The floor is what gives a light rain
  // a signature of its own — a stippled pane — and the slope is what still makes
  // a downpour obviously heavier.
  const beads = Math.round(16 + wet * 20);
  const runners = Math.round(wet * 5);
  const tilt = clamp01(s.weather.wind / 55) * 0.45 * s.lateral;

  // The mist between the beads: single-op specks, no rim, no highlight. What
  // separates a downpour from a drizzle on glass is not bigger drops, it is the
  // fine spray filling the space between them — and drizzle is *mostly* spray,
  // so it starts at the first millimetre rather than at a quarter of the scale.
  {
    const spray = rng(0x11157);
    const dots = Math.round(14 + wet * 16);
    for (let i = 0; i < dots; i += 1) {
      const x = spray() * s.w;
      const y = spray() * s.h;
      const r = 0.5 + spray() * 0.7;
      ops.push({
        op: "rect",
        x: q(x - r),
        y: q(y - r),
        w: q(r * 2),
        h: q(r * 2),
        radius: r,
        fill: hex(scale(s.sample(x, y), 1.5), 0.3 + spray() * 0.35),
      });
    }
  }

  const random = rng(0xd20b1);
  // Beads cluster. Water finds the places water already is, so two thirds of
  // them land near one of five seeds and the rest are scattered — an even
  // sprinkle across the pane reads as a texture, not as rain.
  const nests = [];
  for (let i = 0; i < 5; i += 1) nests.push([random() * s.w, random() * s.h]);
  for (let i = 0; i < beads; i += 1) {
    const nest = i % 3 === 0 ? null : nests[i % nests.length];
    const x = nest
      ? nest[0] + (random() - 0.5) * s.w * 0.34
      : random() * s.w;
    const y = nest ? nest[1] + (random() - 0.5) * s.h * 0.42 : random() * s.h;
    const base = 1.5 + random() * (1.9 + wet * 2.2);
    const phase = random();
    const cycle = 5200 + random() * 7000;
    // The bead's life: it grows as it gathers, then lets go and starts again.
    // Deterministic in t, so the same instant always shows the same drop.
    const u = frac(phaseT / cycle + phase);
    const r = base * (0.5 + u * 0.85);
    droplet(ops, s, x, y, r, 0.55 + u * 0.45);
    // Just shed: the micro-drops it left behind (app-ideas: "merge-and-run with
    // shed micro-drops").
    if (u < 0.12 && base > 2.2) {
      const shed = 0.6 + base * 0.16;
      droplet(ops, s, x + base * 0.7, y + base * 1.5, shed, 0.7);
    }
  }

  for (let i = 0; i < runners; i += 1) {
    const x0 = random() * s.w;
    const phase = random();
    const period = (2600 - wet * 1100) * (0.7 + random() * 0.6);
    const u = frac(phaseT / period + phase);
    const r = 2.4 + wet * 2.4 + random() * 1.2;
    const y = -r + u * (s.h + 2 * r);
    const x = x0 + y * tilt;
    const width = r * 1.05;

    // The clean track: glass a drop has crossed is *clearer* than the glass
    // around it, so it is a brightening rather than a line. It runs a fixed
    // length behind the head and fades out at the top — above that the pane has
    // had time to re-bead, and a track drawn from the ceiling every time reads
    // as a light beam, not as water.
    const track = Math.min(y, 34 + wet * 60);
    ops.push({
      op: "gradient",
      x: q(x - track * tilt * 0.5 - width / 2),
      y: q(y - track),
      w: q(width),
      h: q(Math.max(1, track)),
      radius: width / 2,
      from: hex([255, 255, 255], 0),
      to: hex([255, 255, 255], 0.055 + wet * 0.06),
    });
    droplet(ops, s, x, y, r);
    // The tail it drags: a runner is a comma, not a circle.
    droplet(ops, s, x - r * tilt * 1.2, y - r * 1.9, r * 0.55, 0.8);
  }
}

/** Snow: flakes drifting at the wind's angle, a few stuck to the glass, and the
 * rim of settled snow growing along the bottom edge. */
function drawSnow(ops, s, phaseT, depthCm) {
  const falling = s.weather.snow > 0.005 || s.weather.kind === "snow";
  const rim = Math.min(s.h * 0.13, depthCm * 5.5);

  if (falling) {
    const heavy = clamp01(s.weather.snow / 1.2);
    const flakes = Math.round(22 + heavy * 40);
    const random = rng(0x5f10a);
    const sway = s.lateral * clamp01(s.weather.wind / 40);
    for (let i = 0; i < flakes; i += 1) {
      // Depth of field: `near` flakes are big, bright and fast, far ones are
      // specks. Two populations in one loop is what gives the fall its volume.
      const near = random() ** 1.4;
      const r = 0.9 + near * 2.6;
      const speed = 11_000 - near * 6000 - heavy * 2000;
      const phase = random();
      const u = frac(phaseT / speed + phase);
      const settle = s.h - rim - r * 0.6;
      let y = -r + u * (s.h + 2 * r);
      let stuck = false;
      // Sticks at the sill for the last beat of its cycle, before it is buried.
      if (y > settle) {
        y = settle;
        stuck = true;
      }
      const x =
        frac(random() + (phaseT / 90_000) * sway * (0.4 + near)) * (s.w + 24) -
        12 +
        Math.sin(phaseT / 1400 + phase * 9) * (3 + near * 5) * (1 - Math.abs(sway));
      const bright = stuck ? 0.72 : 0.34 + near * 0.6;
      // A halo under the core: a flake with one hard edge is a pixel, a flake
      // with a soft one is falling through air. Only the near ones get it — a
      // speck two points across has no room for a halo, and fifty of them is a
      // third of the frame's budget spent on nothing anybody can see.
      if (near > 0.4) {
        ops.push({
          op: "rect",
          x: q(x - r * 1.9),
          y: q(y - r * 1.9),
          w: q(r * 3.8),
          h: q(r * 3.8),
          radius: r * 1.9,
          fill: hex([236, 244, 255], bright * 0.16),
        });
      }
      ops.push({
        op: "rect",
        x: q(x - r),
        y: q(y - r),
        w: q(r * 2),
        h: q(r * 2),
        radius: r,
        fill: hex([246, 250, 255], bright),
      });
    }
  }

  if (rim < 1) return;
  // The rim: a settled bank, with a crust of overlapping mounds along its top so
  // the edge is snow rather than a white rectangle. Mounds first, then the solid
  // bank over them — otherwise every mound's flat bottom shows.
  const random = rng(0xc205);
  const snowWhite = [240, 246, 254];
  // Fourteen small mounds, not seven big ones: a crust is a continuous ripple,
  // and half-circles you can count are a row of scoops.
  const MOUNDS = 14;
  for (let i = 0; i < MOUNDS; i += 1) {
    const mr = rim * (0.2 + random() ** 2 * 0.66);
    ops.push({
      op: "rect",
      x: q(((i + random() * 0.9) / MOUNDS) * (s.w + mr * 2) - mr),
      y: q(s.h - rim - mr * (0.2 + random() * 0.7)),
      w: q(mr * 2),
      h: q(mr * 2 + rim),
      radius: mr,
      fill: hex(snowWhite, 0.94),
    });
  }
  ops.push({
    op: "gradient",
    x: -2,
    y: q(s.h - rim),
    w: s.w + 4,
    h: q(rim + 4),
    from: hex(mix(snowWhite, [176, 196, 222], 0.35), 0.96),
    to: hex(snowWhite, 0.98),
  });
  ops.push({
    op: "gradient",
    x: 0,
    y: q(s.h - rim - 9),
    w: s.w,
    h: 10,
    from: hex([110, 140, 184], 0),
    to: hex([110, 140, 184], 0.3),
  });
}

/** Fog on the inside of the glass, and the tracks a hand wiped through it.
 * Strips rather than one veil, because you cannot subtract from a canvas — a
 * clear track has to be a strip that was never fogged. */
function drawFog(ops, s, phaseT) {
  // Rain and snow wash a pane; condensation is what happens when nothing is
  // hitting it. So this is the *dry* cold-and-humid case, plus the fog codes.
  const humid = clamp01((s.weather.rh - 80) / 18);
  const cold = clamp01((11 - s.weather.temp) / 15);
  const wet = s.weather.precip >= WET_MM || s.weather.snow > 0.005;
  const fog = s.weather.kind === "fog" ? 0.78 : wet ? 0 : humid * cold * 0.34;
  if (fog < 0.05) return;

  // **Fog is the condition where the horizon goes missing**, and that is now the
  // whole of how it is told apart from overcast at a glance: everything else in
  // the pane has a black skyline along the bottom, and this one does not. So the
  // veil is laid on thickly enough to actually swallow it — at half strength it
  // was a grey wash over a legible city, which reads as "overcast, dirty window".
  // Denser low, the way ground fog really is.
  ops.push({
    op: "gradient",
    x: 0,
    y: 0,
    w: s.w,
    h: s.h,
    from: hex([206, 216, 228], fog * 0.34),
    to: hex([220, 228, 238], fog * 0.86),
  });

  const STRIPS = 20;
  // Two wipes, slowly re-fogging: a cleared track closes over about ten minutes.
  const wipes = [
    { at: 0.3 + 0.1 * Math.sin(phaseT / 900_000), width: 0.11 },
    { at: 0.68 + 0.08 * Math.sin(phaseT / 1_300_000 + 2), width: 0.08 },
  ];
  const age = clamp01(frac(phaseT / 600_000) * 1.6);
  const veilAt = (u) => {
    let clear = 0;
    for (const wipe of wipes) {
      const d = (u - wipe.at) / wipe.width;
      clear = Math.max(clear, Math.exp(-d * d) * (1 - age));
    }
    // The wipe tracks ride on top of the wash above, so the strips carry only
    // the part of the veil a hand can take away.
    return hex([214, 224, 236], fog * 0.5 * (1 - clear * 0.9));
  };
  for (let i = 0; i < STRIPS; i += 1) {
    // Each strip is a **gradient**, not a flat fill, running left to right
    // between the veil's value at its two edges. Flat strips were two bugs at
    // once: overlapping them composited the veil twice and drew a bright line at
    // every boundary, and abutting them turned the wipe's soft edge into a
    // staircase of twenty-six visible blocks. Sharing the edge colour makes the
    // sampling continuous, and twenty ops draw a smooth veil.
    const x0 = q((i * s.w) / STRIPS);
    const x1 = q(((i + 1) * s.w) / STRIPS);
    ops.push({
      op: "gradient",
      x: x0,
      y: 0,
      w: x1 - x0,
      h: s.h,
      angle: 90,
      from: veilAt(i / STRIPS),
      to: veilAt((i + 1) / STRIPS),
    });
  }
}

/** Lightning: a full-pane flash, twice, and then nothing for a while. Timed off
 * a hash of the ten-second bucket so it is unpredictable to watch and identical
 * to re-scrub. */
function drawLightning(ops, s, phaseT) {
  if (s.weather.kind !== "storm") return;
  const bucket = Math.floor(phaseT / 9000);
  const roll = rng(bucket * 2654435761)();
  if (roll > 0.5) return;
  const strike = bucket * 9000 + roll * 14_000;
  const dt = phaseT - strike;
  if (dt < 0 || dt > 460) return;
  // Two peaks: the leader, then the return stroke a beat later.
  const envelope = Math.exp(-dt / 90) * 0.7 + (dt > 130 ? Math.exp(-(dt - 130) / 110) : 0);
  const a = clamp01(envelope) * 0.5;
  if (a < 0.01) return;
  ops.push({ op: "rect", x: 0, y: 0, w: s.w, h: s.h, fill: hex([226, 236, 255], a) });
}

// ---------------------------------------------------------------- the frame

/**
 * One frame of the pane. Pure: same arguments, same ops, forever.
 *
 * `reduceMotion` quantises the *animation* clock to ten minutes and drops the
 * lightning — so nothing moves between frames, the drops stand still where they
 * are, and the flash never fires — while `t` itself still drives the sun, the
 * sky and the weather. Still, not blank and not slower (REFERENCE.md, Reduce
 * Motion), and the scrubber keeps working, because scrubbing is the user moving
 * something, not the app.
 */
export function paneOps({ w, h, t, weather, place, snowDepth = 0, reduceMotion = false }) {
  const phaseT = reduceMotion ? Math.round(t / 600_000) * 600_000 : t;
  const s = buildScene({ w, h, weather, place, phaseT });

  const ops = [{ op: "clear" }];
  drawSky(ops, s);
  drawSun(ops, s);
  drawClouds(ops, s);
  // After the clouds and before the weather: the ground is in front of the sky
  // and behind everything falling through the air between it and the glass.
  drawSkyline(ops, s);
  drawFallingRain(ops, s, phaseT);
  drawHaze(ops, s);
  drawFog(ops, s, phaseT);
  drawRain(ops, s, phaseT);
  drawSnow(ops, s, phaseT, snowDepth);
  drawSurface(ops, s);
  drawEdges(ops, s);
  if (!reduceMotion) drawLightning(ops, s, phaseT);
  return quantise(ops);
}

/** One sweep over the finished list, so no emitter can leak a fractional
 * coordinate. The backing store is 2×; anything off the half point is an
 * antialiased edge the app is paying for and nobody can see — and, worse, a
 * source of frame-to-frame jitter in a picture that is supposed to hold still. */
function quantise(ops) {
  for (const op of ops) {
    for (const key of ["x", "y", "w", "h", "radius"]) {
      if (typeof op[key] === "number") op[key] = q(op[key]);
    }
    if (op.op === "line") op.points = op.points.map(([x, y]) => [q(x), q(y)]);
  }
  return ops;
}
