/** @jsxImportSource react */
// Weather — the sky through a real pane.
//
// SIGNATURE: **the pane.** One canvas, drawn imperatively at ~11 fps, that
// simulates the *glass* rather than the weather — droplets that are lenses
// holding an inverted copy of the scene behind them, runners that let go and
// wipe a clean track, snow that sticks and banks along the sill, light that
// swings across the pane because the real sun moved. Everything else on this
// panel exists to serve it: a tick strip you drag to travel through the
// forecast, and one line of words. There is no city name (it is YOUR sky), no
// humidity grid, no seven-day rows.
//
// The architecture, in one sentence: `paneOps(t, weather(t))` is a **pure
// function**, so the live clock and the scrubber call exactly the same renderer
// and the picture at +6 h is the same picture whether you arrive at it by
// waiting or by dragging.
//
// Laws it is written against:
//    1  one step lighter — no chips, no buttons at all; the glass is the control.
//    3  the accent has exactly one job: the region of the ruler you scrubbed to.
//    4  ONE sentence, and it is data ("Rain for the next hour"). No label, no
//       city, no "Feels like".
//    5  the temperature is a bare numeral at `display`, not a labelled box.
//    8  a heavy visit, so it OWES a summary — `<summary>` is declared, and it
//       reads the way flow.md says: temp and the next hour.
//    9  the wing is an **ambient** ticker: the temperature, nothing else. Not a
//       live activity — nothing here is happening, it is just true.
//   10  Reduce Motion: the pane holds still (drops stop falling, no lightning)
//       and the scrub snaps instead of easing. Scrubbing itself keeps working —
//       that is the user moving something, not the app.
//   13  and no notification, ever. Weather is never worth interrupting for.
//
// The maths lives in siblings: `solar.js` (where the sun is), `forecast.js`
// (Open-Meteo + the words), `pane.js` (the glass), `ruler.js` (the strip).

import {
  conditionLine,
  fetchForecast,
  fetchPlace,
  readCache,
  snowDepthAt,
  summaryLine,
  weatherAt,
  writeCache,
} from "./forecast.js";
import { paneOps } from "./pane.js";
import { rulerOps } from "./ruler.js";

export const meta = { name: "Weather", icon: "sf:cloud.sun" };

const PANE_W = 412; // 440 pt panel − 14 pt of padding either side
const PANE_H = 188;
const RULER_H = 38;
const FRAME_MS = 90; // ~11 fps — weather is slow, and every frame is ~250 ops
const REFRESH_MS = 15 * 60_000;
const SCRUB_HOURS = 24;
const SETTLE_MS = 500;
const HOUR = 3_600_000;

let ctxRef = null;
let pane = null; // the canvas nodes, from refs; their ids are what ctx.draw targets
let ruler = null;

let place = null;
let forecast = null;
let started = false;
let showing = true; // false while the panel is collapsed or hidden

// The scrub, as an **offset** from now rather than an absolute instant: hold the
// ruler at +6 h and the clock underneath keeps running, which is what "six hours
// from now" means.
let offset = 0;
let dragging = false;
let settleFrom = 0;
let settleAt = 0;

// ---------------------------------------------------------------- time

const easeOut = (k) => 1 - (1 - k) ** 3;

/** The instant the whole app is currently showing. One value, read by the pane,
 * the ruler, the numeral and the line — so they can never disagree. */
function viewT() {
  return Date.now() + offset;
}

/** Advance the settle. Returns true if anything moved. */
function settle() {
  if (settleAt === 0) return false;
  const k = (Date.now() - settleAt) / SETTLE_MS;
  if (k >= 1) {
    offset = 0;
    settleAt = 0;
    return true;
  }
  offset = settleFrom * (1 - easeOut(k));
  return true;
}

// ---------------------------------------------------------------- the scrub

/**
 * The one gesture in the app. `phase` is `down`/`move`/`up` and the point is not
 * clamped to the canvas (spec §4.1), so the track decides its own edges: this
 * one saturates, because dragging past the end of the forecast should sit at the
 * end of the forecast rather than wrap around to this morning.
 */
function onScrub({ phase, x }) {
  if (!forecast) return;
  const u = Math.max(0, Math.min(1, x / PANE_W));
  offset = u * SCRUB_HOURS * HOUR;
  if (phase === "up") {
    dragging = false;
    // Let go and it eases home — the settle is the app's whole motion budget.
    // Under Reduce Motion it simply arrives (principle 10).
    if (ctxRef?.reduceMotion) {
      offset = 0;
      settleAt = 0;
    } else {
      settleFrom = offset;
      settleAt = Date.now();
    }
  } else {
    dragging = true;
    settleAt = 0;
  }
  frame();
}

// ---------------------------------------------------------------- drawing

/** One frame: the pane, the ruler, and the props under them. Called from the
 * interval, from the scrub, and from lifecycle — everywhere the picture could
 * have changed. */
function frame() {
  if (!ctxRef || !forecast) return;
  const t = viewT();
  const weather = weatherAt(forecast, t);

  if (pane) {
    ctxRef.draw(
      pane.id,
      paneOps({
        w: PANE_W,
        h: PANE_H,
        t,
        weather,
        place: forecast,
        snowDepth: snowDepthAt(forecast, t),
        reduceMotion: Boolean(ctxRef.reduceMotion),
      }),
    );
  }
  if (ruler) {
    ctxRef.draw(
      ruler.id,
      rulerOps({
        w: PANE_W,
        h: RULER_H,
        span: SCRUB_HOURS,
        offset,
        now: Date.now(),
        tz: forecast.offset,
      }),
    );
  }
  commit(weather, t);
}

let lastProps = "";
let lastWing = "";
let wingSentAt = 0;

/** Re-declare the wing at least this often. The shell takes an idle wing back
 * after Ta (flow.md, "Ambient | holder idle > Ta, or released | Resting") and
 * every request from the holder re-arms that timer. A temperature can easily go
 * an hour without changing by a degree, so with nothing but change-detection
 * behind it this app's ticker vanished from the notch and — because it believed
 * it had already asked for exactly this wing — never came back. */
const WING_HEARTBEAT_MS = 45_000;

function commit(weather, t) {
  if (!ctxRef) return;
  const props = {
    temp: `${Math.round(weather.temp)}°`,
    line: conditionLine(forecast, t),
    glance: summaryLine(forecast, Date.now()), // the summary is always about NOW
  };
  const signature = JSON.stringify(props);
  if (signature !== lastProps) {
    lastProps = signature;
    ctxRef.update(props);
  }

  // An **ambient** wing (flow.md's priority ladder, bottom rung): the current
  // temperature and nothing else. Not a live activity — nothing is happening
  // here, it is simply true, so it must never outrank a timer or a track. And
  // it reads *now*, never the scrub: the collapsed notch is not time-travelling.
  const text = `${Math.round(weatherAt(forecast, Date.now()).temp)}°`;
  if (text === lastWing && Date.now() - wingSentAt < WING_HEARTBEAT_MS) return;
  lastWing = text;
  wingSentAt = Date.now();
  ctxRef.wing({ text });
}

/** The frame clock. A `setInterval`, not a monitor pass: the monitor loop has a
 * 1 s spin floor (REFERENCE.md, "The monitor loop") and a pane at 1 fps is a
 * slideshow. */
function tick() {
  if (!ctxRef || !forecast || !showing) return;
  const moved = settle();
  // Reduce Motion: the pane is a still, so there is nothing to redraw between
  // seconds — but the *data* keeps moving (a temperature that froze would be
  // broken, not accessible), and a scrub or a settle is user-initiated motion
  // and still gets its frames.
  if (ctxRef.reduceMotion && !moved && !dragging) {
    const bucket = Math.floor(Date.now() / 600_000);
    if (bucket === lastStill) return;
    lastStill = bucket;
  }
  frame();
}
let lastStill = null;

// ---------------------------------------------------------------- the data

async function refresh() {
  if (!place) {
    place = await fetchPlace();
  }
  forecast = await fetchForecast(place);
  writeCache(import.meta.dir, { place, fetchedAt: Date.now(), forecast });
  frame();
}

export async function monitor(ctx) {
  ctxRef = ctx;
  if (!started) {
    started = true;
    // The cache first, always: a sky that appears the instant the panel opens
    // and then quietly corrects itself is worth far more than an empty state
    // that resolves in two seconds. It is also what makes the app work on a
    // train.
    const cached = readCache(import.meta.dir);
    if (cached) {
      place = cached.place;
      forecast = cached.forecast;
      frame();
    }
    setInterval(tick, FRAME_MS);
  }
  // …and this loop stays a *poller*, which is what the monitor is for: the
  // pacing below is a real fifteen minutes, not a frame budget, so there is
  // nothing here that the 1 s floor can distort.
  try {
    await refresh();
  } catch (error) {
    // A throw here is a crash-and-backoff loop. A forecast that failed to
    // arrive should leave the last one on the glass and try again.
    console.log(`refresh failed: ${error?.message ?? error}`);
  }
  await Bun.sleep(REFRESH_MS);
}

export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  if (phase === "collapsed" || phase === "hidden") {
    showing = false;
    return;
  }
  showing = true;
  // Reduce Motion rides this envelope and may have just flipped, so draw the
  // frame it implies rather than waiting for a loop that no longer runs.
  lastStill = null;
  frame();
}

// ---------------------------------------------------------------- the panel

export default function Weather({ temp = null, line = "" }) {
  // The invitation (design.html §09): one glyph, one line, no button, no
  // apology, and never the word "error".
  if (!temp) {
    return (
      <stack axis="v" pad={30} gap={12} align="center">
        <image src="sf:cloud.sun" w={26} h={26} />
        <text content="Your sky, as soon as there's a signal." size="s" color="secondary" />
      </stack>
    );
  }

  return (
    <stack axis="v" pad={14} gap={10}>
      {/* Heavy visit, so it owes a summary (principle 8): temp and the next
          hour, about NOW — the notch does not time-travel. */}
      {/* Summary UX deferred by ruling (2026-08-15) — no app declares one. */}

      {/* The well — the app's one framed region (design.html §09). */}
      <canvas ref={(node) => { pane = node; }} w={PANE_W} h={PANE_H} />

      {/* The ruler. `onDrag` and nothing else: no handle to grab, no buttons at
          either end — the strip is the control (principle 5). */}
      <canvas ref={(node) => { ruler = node; }} w={PANE_W} h={RULER_H} onDrag={onScrub} />

      {/* The one line the app is allowed, and the numeral it belongs to. They
          stay together at the left because a row places its children now (spec
          §5) — this used to need a trailing `<spacer />` to stop the row
          flinging the phrase to the far edge, which read as two unrelated facts
          instead of one sentence about the sky. */}
      <stack axis="h" gap={12} align="center">
        <text content={temp} size="display" weight="light" />
        <text content={line} size="s" color="secondary" truncate />
      </stack>
    </stack>
  );
}
