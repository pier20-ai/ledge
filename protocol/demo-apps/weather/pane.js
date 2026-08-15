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
// Two constraints shape every technique here:
//
//   * **There is no blur filter.** §3.4 gives you `rect` (rounded, filled),
//     `line`, `gradient` (axial), `image` and `text`. Softness has to be built
//     out of alpha: a dozen faint overlapping discs have no findable edge, where
//     one solid disc has an edge you can trace. Every soft thing here — clouds,
//     the sun's bloom, the fog — is that trick, and it is why the scene is
//     already defocused, which is what a pane does to a sky.
//   * **A few hundred ops a frame, at ~11 fps.** Clear sky is ~50, a full
//     downpour ~270. The budget is why a droplet is three ops (rim, lens,
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

  // Cloud and rain drain the colour out of a sky; the grey they drain it toward
  // is the sky's own brightness, so an overcast noon is pale and an overcast
  // midnight stays black.
  const greyness = Math.min(0.88, clamp01(cover * 0.85 + wet * 0.3));
  const grey = (c) => {
    const l = (c[0] * 0.3 + c[1] * 0.55 + c[2] * 0.15) * 0.82;
    return [l, l * 1.02, l * 1.1];
  };
  const dim = 1 - wet * 0.28;
  const zenith = scale(mix(band.zenith, grey(band.zenith), greyness), dim);
  const horizon = scale(mix(band.horizon, grey(band.horizon), greyness), dim);

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

  // Cloud masses. Drift is a function of wind and t, so the deck moves with the
  // scrubber the way the sun does.
  const drift = (phaseT / 3_600_000) * weather.wind * 2.4;
  const lateral = Math.sin(weather.dir * RAD);
  const count = cover < 0.04 ? 0 : Math.min(6, 1 + Math.round(cover * 5));
  const random = rng(0x5eed1);
  const masses = [];
  for (let i = 0; i < count; i += 1) {
    const span = (0.12 + cover * 0.16 + random() * 0.2) * w;
    const speed = 0.6 + random() * 0.9;
    const margin = span * 1.4;
    const x0 = random() * (w + 2 * margin);
    const x = ((x0 + drift * speed * lateral) % (w + 2 * margin)) - margin;
    masses.push({
      x: x < -margin ? x + w + 2 * margin : x,
      y: (0.04 + random() * 0.52) * h,
      span,
      thick: (0.1 + random() * 0.12) * h + span * 0.16,
      alpha: 0.4 + random() * 0.35,
      seed: 0x1000 + i * 97,
    });
  }

  // Cloud density across the pane, in buckets — the cheap version of the deck a
  // droplet samples. Sampling the real puff list per droplet is 40 × 21 gaussian
  // terms a frame; this is 24 numbers built once.
  const BUCKETS = 24;
  const density = new Float64Array(BUCKETS);
  for (const mass of masses) {
    for (let b = 0; b < BUCKETS; b += 1) {
      const x = ((b + 0.5) / BUCKETS) * w;
      const d = (x - mass.x) / (mass.span * 0.75);
      density[b] += mass.alpha * Math.exp(-d * d);
    }
  }

  // Warm only while there is a sun to be warm *from*: `warmth` rises as the sun
  // sinks, so multiplying by it alone paints midnight clouds in sunset orange.
  const cloudLit = mix([236, 240, 246], sunColour, warmth * clamp01(strength * 1.8) * 0.7);
  // At night a cloud is barely lighter than the sky it is in front of, and what
  // light it has comes off the city underneath it. Drawing it at daytime grey is
  // what turns a dark pane into a lava lamp.
  const cloudDark = add(
    scale(mix(zenith, [92, 100, 116], 0.22 + strength * 0.5), 1 - wet * 0.3),
    scale([40, 26, 12], glow * 0.7),
  );

  /** What is behind the glass at (x, y) — sky, plus the sun's bloom, plus
   * whatever cloud is in the way. This is the function the droplets refract. */
  const sample = (x, y) => {
    const k = clamp01(y / h) ** 1.15;
    let c = mix(zenith, horizon, k);
    if (glow > 0) c = add(c, scale([72, 46, 22], glow * k * k));
    if (strength > 0) {
      const dx = (x - sx) / (w * 0.62);
      const dy = (y - sy) / (h * 0.85);
      c = add(c, scale(sunColour, Math.exp(-(dx * dx + dy * dy) * 2.1) * strength * 0.85));
    }
    const b = Math.max(0, Math.min(BUCKETS - 1, Math.floor((x / w) * BUCKETS)));
    const d = clamp01(density[b] * 0.8);
    if (d > 0) {
      const lit = clamp01(strength * (1 - Math.abs(x - sx) / w) + 0.15);
      c = mix(c, mix(cloudDark, cloudLit, lit), d * 0.75);
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
    cloudLit,
    cloudDark,
    lateral,
    sample,
    weather,
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
      const y = q(random() * s.h * 0.7);
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

  // The city's floor under a night sky.
  if (s.glow > 0.02) {
    ops.push({
      op: "gradient",
      x: 0,
      y: s.h * 0.45,
      w: s.w,
      h: s.h * 0.55,
      from: hex([150, 96, 44], 0),
      to: hex([150, 96, 44], clamp01(s.glow) * 0.38),
    });
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

/** Cloud masses: a lid when the sky is shut, and heaps of faint discs when it
 * is not. A cloud with a findable edge is a sticker. */
function drawClouds(ops, s) {
  // A full deck is one shape, not seven: overcast reads as a lid, and seven
  // overlapping puffs at 90% coverage cost sixty ops to look like one.
  if (s.cover > 0.82) {
    const deck = s.h * (0.34 + s.cover * 0.3);
    const colour = mix(s.cloudDark, s.cloudLit, clamp01(s.strength * 0.6 + 0.12));
    // The underside of a deck is darkest right overhead and lifts toward the
    // horizon, where you are looking out from under it — the tonal range that
    // keeps a rainy pane from being one flat grey.
    ops.push({
      op: "gradient",
      x: -4,
      y: -4,
      w: s.w + 8,
      h: deck,
      from: hex(scale(colour, 0.62), 0.95),
      to: hex(colour, 0),
    });
  }

  // A puff is a *circle* — a rounded rect wider than it is tall is a stadium,
  // and a row of stadiums is a cartoon. But the real lesson of the first pass is
  // about alpha, not shape: **many faint discs, not a few solid ones.** A disc
  // at 90% has an edge you can trace; a dozen at 12%, jittered, accumulate into
  // a lump whose boundary nobody can find. That is the whole blur, and it costs
  // one op per disc.
  const PUFFS = 11;
  // Under a full deck the masses all but vanish: the lid above is already the
  // whole sky, and individual heaps showing through it read as soap bubbles.
  // They are kept at a trace so the deck still has some modelling in it.
  const solid = 1 - clamp01((s.cover - 0.78) / 0.3) * 0.8;
  for (const mass of s.masses) {
    const random = rng(mass.seed);
    const lit = clamp01(s.strength * (1 - Math.abs(mass.x - s.sx) / s.w) + 0.12);
    const colour = mix(s.cloudDark, s.cloudLit, lit);
    const base = mass.y + mass.thick * 0.5;
    for (let p = 0; p < PUFFS; p += 1) {
      const along = (p + 0.35 + random() * 0.3) / PUFFS;
      // Fat in the middle, thin at the ends — the arc that makes a heap — and a
      // flat-ish underside, which is what says "cloud" rather than "cotton".
      const swell = Math.sin(clamp01(along) * Math.PI) ** 0.6;
      const r = mass.thick * (0.26 + swell * 0.6) * (0.7 + random() * 0.6);
      const cx = mass.x + (along - 0.5) * mass.span;
      const cy = base - r * (0.7 + random() * 0.45);
      ops.push({
        op: "rect",
        x: q(cx - r),
        y: q(cy - r),
        w: q(r * 2),
        h: q(r * 2),
        radius: r,
        fill: hex(colour, mass.alpha * (0.15 + s.cover * 0.06) * solid),
      });
    }
  }
}

/** Rain falling *behind* the pane: soft slanted streaks, well out of focus.
 * The glass is the subject, but a window with beads on it and nothing happening
 * beyond reads as a leak rather than as weather. */
function drawFallingRain(ops, s, phaseT) {
  if (s.weather.precip < WET_MM) return;
  const wet = clamp01(s.weather.precip / 3);
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
  ops.push({
    op: "gradient",
    x: 0,
    y: 0,
    w: s.w,
    h: s.h,
    from: hex([255, 255, 255], 0.012 + 0.03 * s.luma),
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
    from: hex([255, 255, 255], 0.02 + 0.075 * s.luma),
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
    to: hex([10, 14, 22], 0.08 + 0.2 * s.luma),
    angle: 208,
  });
}

/** The pane's own recess — the four edges going dark. Without it the canvas is
 * a picture of a sky; with it, it is a hole in the panel with a sky behind it. */
function drawEdges(ops, s) {
  const d = 16;
  const ink = [0, 0, 0];
  const strong = 0.18 + 0.26 * s.luma;
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
  const beads = Math.round(8 + wet * 26);
  const runners = Math.round(0.6 + wet * 4.4);
  const tilt = clamp01(s.weather.wind / 55) * 0.45 * s.lateral;

  // The mist between the beads: single-op specks, no rim, no highlight. What
  // separates a downpour from a drizzle on glass is not bigger drops, it is the
  // fine spray filling the space between them.
  if (wet > 0.25) {
    const spray = rng(0x11157);
    const dots = Math.round(wet * 34);
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
      // with a soft one is falling through air.
      ops.push({
        op: "rect",
        x: q(x - r * 1.9),
        y: q(y - r * 1.9),
        w: q(r * 3.8),
        h: q(r * 3.8),
        radius: r * 1.9,
        fill: hex([236, 244, 255], bright * 0.16),
      });
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
  // Eighteen small mounds, not nine big ones: a crust is a continuous ripple,
  // and half-circles you can count are a row of scoops.
  for (let i = 0; i < 18; i += 1) {
    const mr = rim * (0.16 + random() ** 2 * 0.62);
    ops.push({
      op: "rect",
      x: q(((i + random() * 0.9) / 18) * (s.w + mr * 2) - mr),
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
  const fog = s.weather.kind === "fog" ? 0.5 : wet ? 0 : humid * cold * 0.38;
  if (fog < 0.05) return;

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
    return hex([214, 224, 236], fog * (1 - clear * 0.88));
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
