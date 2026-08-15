/** @jsxImportSource react */
// Radio — the no-summary case, and the wing canvas.
//
// Laws it is written against: 1 (no card, no artwork frame — just the two
// lines), 3 (ink only; the level meter is white, never a hue), 4 (station and
// track are the only words, and both are data), 5 (no "Now playing:" label).
//
// Surfaces it exercises:
//   NO SUMMARY   this app declares neither <summary> nor <mini>. It is its own
//                summary, so a rested pointer must open the VISIT directly —
//                the test case for principle 8's second half. If a hover ever
//                swells a line here instead, the law is broken.
//   WING CANVAS  a live-activity strip in the right wing: five bars breathing
//                at ~8 fps, drawn imperatively so React never commits for a
//                frame. The same node sits in the panel — one ctx.draw, two
//                places.
//   REDUCE MOTION principle 10, via `ctx.reduceMotion` (spec §4.2): the bars
//                stop breathing and stand at a fixed profile. The station still
//                rotates — that is data, not motion.
//
// Nothing here plays audio. The station is a fixture; the "track" rotates on a
// timer, which is all the app has to be to exercise the surfaces.

export const meta = { name: "Radio", icon: "sf:dot.radiowaves.left.and.right" };

const STATION = "NTS 2";
const TRACKS = [
  "Aphex Twin — Rhubarb",
  "Alice Coltrane — Turiya",
  "Burial — Archangel",
  "Grouper — Heavy Water",
  "Steve Reich — Electric Counterpoint",
];

const TRACK_MS = 30_000;
const FRAME_MS = 120; // ~8 fps: enough for a breathing meter, cheap enough to leave on

/** Re-declare the wing at least this often while it is held.
 *
 * The shell takes an idle wing back after Ta (flow.md, "Ambient | holder idle >
 * Ta, or released | Resting"), and every request from the holder re-arms that
 * timer. This app's ticker is the track title, which only changes every
 * `TRACK_MS` — so with nothing but change-detection behind it the notch went
 * bare in the middle of a track and, because the app believed it had already
 * asked for exactly this wing, it never came back. Same shape as being
 * preempted by another app's wing: the app has to keep saying it is alive. */
const WING_HEARTBEAT_MS = 45_000;

const BARS = 5;
const BAR_W = 4;
const BAR_GAP = 4;
const WING_W = BARS * BAR_W + (BARS - 1) * BAR_GAP;
const WING_H = 34; // the notch's own height — the wing canvas' coordinate space

let ctxRef = null;
let meter = null; // the canvas node, from a ref
// Starts stopped: the resting notch is bare, and the wing is something you
// hand it (principle 13's "quiet default state"). It also keeps two demo apps
// from fighting over one wing on a fresh launch — the shell's arbitration is
// "latest asker wins", which is correct and confusing to feel-test by accident.
let playing = false;
let track = 0;
let startedAt = Date.now();
let frame = 0;

// ---------------------------------------------------------------- actions

function toggle() {
  playing = !playing;
  if (playing) startedAt = Date.now();
  commit();
  paint(); // the one frame the loop will not draw: bars going flat
}

function next() {
  track = (track + 1) % TRACKS.length;
  startedAt = Date.now();
  commit();
}

// ---------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";
let wingSentAt = 0;

function commit() {
  if (!ctxRef) return;
  const props = { station: STATION, track: TRACKS[track], playing };
  const signature = JSON.stringify(props);
  if (signature !== lastProps) {
    lastProps = signature;
    ctxRef.update(props);
  }

  // Live activity: the wing is held while it plays and released when it stops.
  // The wing FIRST, before any re-render: dropping `playing` unmounts nothing
  // here, but the ordering is the one that survives an app growing an empty
  // state (see nowplaying), and it costs nothing to be right about.
  const held = playing && meter !== null;
  const wanted = held ? `${TRACKS[track]}|${meter.id}` : "";
  // …and re-declared on a heartbeat even when nothing about it changed, so a
  // wing the shell reclaimed for idleness comes back. A change-detection gate
  // on its own is a claim the app can only ever make once.
  const stale = held && Date.now() - wingSentAt > WING_HEARTBEAT_MS;
  if (wanted === lastWing && !stale) return;
  lastWing = wanted;
  wingSentAt = Date.now();
  ctxRef.wing(held ? { text: TRACKS[track], canvas: { id: meter.id, w: WING_W } } : null);
}

/** The profile the bars stand at when the user has asked for less motion: the
 * average of the standing wave, so it reads as the same meter held still. */
const STILL = [0.35, 0.6, 0.8, 0.6, 0.35];

/** One frame of the level meter. Bars are a cheap standing wave, not real
 * audio — the point is the surface, not the signal.
 *
 * Reduce Motion (spec §4.2) is read here rather than only in `tick`, because
 * `toggle` paints directly: wherever the pixels are decided, the flag has to be
 * in scope. */
function paint() {
  if (!ctxRef || !meter) return;
  const still = Boolean(ctxRef.reduceMotion);
  const ops = [{ op: "clear" }];
  for (let i = 0; i < BARS; i += 1) {
    const moving = (Math.sin(frame / 6 + i * 1.1) + 1) / 2;
    const wave = playing ? (still ? STILL[i] : moving) : 0;
    const h = Math.max(2, Math.round(4 + wave * 16));
    ops.push({
      op: "rect",
      x: i * (BAR_W + BAR_GAP),
      y: Math.round((WING_H - h) / 2),
      w: BAR_W,
      h,
      radius: 1,
      fill: playing ? "#FFFFFFCC" : "#FFFFFF33",
    });
  }
  ctxRef.draw(meter.id, ops);
}

function tick() {
  if (!playing) return; // stopped is a still frame, not a slower one
  if (Date.now() - startedAt >= TRACK_MS) next();
  // Principle 10 (spec §4.2): the track keeps rotating above — a station that
  // stopped changing tracks would be broken, not accessible — but the meter
  // stops here. Still, not slower.
  if (ctxRef?.reduceMotion) return;
  frame += 1;
  commit();
  paint();
}

/** The push half of `ctx.reduceMotion`: the flag rides the lifecycle envelope
 * (spec §4.2), so this is where a freshly-flipped switch gets its one frame. */
export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  paint();
}

export async function monitor(ctx) {
  ctxRef = ctx;
  commit();
  paint(); // the resting frame: five flat bars, which `tick` will not draw
  // A setInterval, not a monitor pass: the monitor loop has a 1 s spin floor
  // (spec §6 rule 1) and a level meter at 1 fps is a bar chart. Park here and
  // let the interval own the clock — the aviary pattern.
  setInterval(tick, FRAME_MS);
  await new Promise(() => {});
}

// ---------------------------------------------------------------- the panel

export default function Radio({
  station = STATION,
  track: title = TRACKS[0],
  playing: live = false,
  onToggle = toggle,
  onNext = next,
}) {
  return (
    <stack axis="v" pad={16} gap={8} align="center">
      {/* `align="center"` on the column centres these: a placed child is sized
          to its own words and capped at the column, so a long track title
          truncates in the middle of the panel instead of running off it. */}
      <text content={station} size="xs" weight="medium" color="tertiary" caps />
      <text content={title} size="l" weight="light" truncate />

      {/* The wing's own strip, sitting in the panel: the shell mirrors this
          node's frames into the notch, so they are literally the same pixels. */}
      <canvas ref={(node) => { meter = node; }} w={WING_W} h={WING_H} />

      <stack axis="h" gap={16}>
        {/* Ghosts (design.html §06): app controls are bare pure-white glyphs. */}
        <button icon={live ? "sf:pause" : "sf:play"} variant="ghost" onClick={() => onToggle?.()} />
        <button icon="sf:forward.end" variant="ghost" onClick={() => onNext?.()} />
      </stack>
    </stack>
  );
}
