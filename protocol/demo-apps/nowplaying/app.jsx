/** @jsxImportSource react */
// Now Playing — the app that owns the resting pill.
//
// SIGNATURE: the wing waveform. Seven bars breathing in the collapsed notch
// while something plays, and the same node drawn in the panel — one `ctx.draw`,
// two places. There is no audio tap on macOS, so the levels are pseudo: sines
// seeded by the track, advanced only while the music advances, eased toward
// their target every frame. It has to read as alive, not as noise.
//
// Laws it exercises:
//   1   one step lighter — bare glyphs, no chips, no filled transport.
//   3   monochrome by choice: the artwork is the only colour, and no hue here
//       has a job, so none is spent.
//   4/5 no header, no labels, no clock digits — the title IS the display and
//       the meter IS the position.
//   8   NO <summary>. This app is its own summary, so a rested pointer opens
//       the visit directly.
//   9   live-activity wing: held while it plays, released the moment it stops.
//   10  Reduce Motion: the wave goes STILL (a static arch, not a slower one)
//       and the progress bar stops self-advancing. `ctx.reduceMotion`, §4.2.
//   13  a quiet default above all — nothing playing, bare notch. And no
//       notification ever: a track change is not worth interrupting for.
//
// The plumbing to Music.app and Spotify (and the reason neither is ever
// launched) is in players.js.

import { PLAYBACK_NOTIFICATIONS, ensureArtwork, readPlayback, sendCommand } from "./players.js";

export const meta = {
  name: "Now Playing",
  icon: "sf:waveform",
  panel: { width: 360 },
};

// Pacing (spec §4.2): the monitor runs whether the panel is open or not,
// because the wing does — it just asks less often when nobody is looking.
const POLL_EXPANDED_MS = 3_000;
const POLL_COLLAPSED_MS = 15_000;
const WAKE_MS = 250; // both players emit a burst per track change; collapse it
const FRAME_MS = 90;

const BARS = 7;
const BAR_W = 3;
const BAR_GAP = 3;
const WAVE_W = BARS * BAR_W + (BARS - 1) * BAR_GAP;
const WAVE_H = 34; // the notch's own height — the wing canvas' coordinate space
const BAR_MIN = 2;
const BAR_MAX = 22;

let ctxRef = null;
let now = null; // the last read playback state, or null
let artwork = null;
let expanded = false;
let polling = false;
let waking = null;
let started = false;

let wave = null; // the canvas node, from a ref; its id is what ctx.draw targets
const levels = new Array(BARS).fill(0);
let phase = 0; // advances only while the music does

// ---------------------------------------------------------------- the wave

/** A stable 0…1 from a string. The track's title is the only signal we have
 * about how it should move, so it is the one we use. */
function seedOf(text) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i += 1) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return (h >>> 0) / 4294967296;
}

/** The standing shape of the row: tallest in the middle. It is the whole
 * difference between a waveform and a row of rectangles, so it is also what is
 * left when the motion is taken away (see `paint`). */
function hump(i) {
  return 0.75 + 0.25 * Math.sin(((i + 0.5) / BARS) * Math.PI);
}

/** One bar's target level, 0…1. Two sines the seed detunes against each other
 * (so the pattern never quite repeats), offset per bar (so the shape *travels*
 * across the row instead of every bar pumping together), over a floor of 0.20
 * — a playing meter should never touch the height a stopped one sits at. The
 * hump keeps the middle bars tallest, which is the whole difference between a
 * waveform and a row of rectangles. */
function target(i, t, seed, energy) {
  const a = Math.sin(t * (1.35 + seed * 0.6) + i * 1.25);
  const b = Math.sin(t * (2.15 + seed * 1.1) - i * 0.85);
  const swell = (a * 0.55 + b * 0.45 + 1) / 2;
  return Math.min(1, (0.2 + 0.8 * swell * energy) * hump(i));
}

/** One frame. Hex, not tokens — a canvas is pixels, not a view.
 *
 * `still` is Reduce Motion (spec §4.2, principle 10): the bars take the arch
 * they would average out to and stay there. Still, not slower and not blank —
 * the meter still says "playing", it just stops breathing. */
function paint(live, still = false) {
  if (!ctxRef || !wave) return;
  const seed = now ? seedOf(`${now.title}${now.artist}`) : 0;
  const energy = 0.75 + seed * 0.25; // the track's character: how hard it moves
  const ops = [{ op: "clear" }];
  for (let i = 0; i < BARS; i += 1) {
    const wanted = live ? (still ? 0.55 * hump(i) : target(i, phase, seed, energy)) : 0;
    // Ease, never jump: the bars are a body moving, not a chart repainting.
    // Under Reduce Motion there is no body and no easing — one frame, done.
    if (still) levels[i] = wanted;
    else levels[i] += (wanted - levels[i]) * 0.28;
    const h = Math.max(BAR_MIN, Math.round(BAR_MIN + levels[i] * (BAR_MAX - BAR_MIN)));
    ops.push({
      op: "rect",
      x: i * (BAR_W + BAR_GAP),
      y: Math.round((WAVE_H - h) / 2),
      w: BAR_W,
      h,
      radius: 1.5,
      fill: live ? "#FFFFFFD9" : "#FFFFFF33",
    });
  }
  ctxRef.draw(wave.id, ops);
}

/** The animation clock. A setInterval, not a monitor pass: the monitor loop has
 * a 1 s spin floor (spec §6 rule 1), and a level meter at 1 fps is a bar chart.
 * It keeps running while the panel is collapsed on purpose — collapsed is when
 * the wing is the whole app. */
function tick() {
  const live = Boolean(now?.playing);
  // Principle 10 (spec §4.2): with Reduce Motion on there is no loop at all —
  // one frame per state, and then nothing until the state changes. This is the
  // shape any canvas app should copy: check the flag inside the loop, because
  // the flag can flip while the loop is running.
  if (ctxRef?.reduceMotion) return still(live);
  lastStill = null;
  // Stopped and flat is a still frame, not a slower one. The frames between
  // "stopped" and "flat" still run, which is how the bars settle instead of
  // snapping — and how the wing gets released.
  if (!live && levels.every((value) => value < 0.01)) return;
  if (live) phase += FRAME_MS / 1000;
  publishWing();
  paint(live);
}

/** The Reduce Motion branch: redraw only when what the bars *mean* changed. */
let lastStill = null;
function still(live) {
  const signature = `${live}|${now?.title ?? ""}`;
  if (signature === lastStill) return;
  lastStill = signature;
  publishWing();
  paint(live, true);
}

// ---------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";

function publish() {
  if (!ctxRef) return;
  const props = {
    track: now && {
      title: now.title,
      artist: now.artist,
      playing: now.playing,
      // The meter is a fraction, and `rate` is what moves it between polls:
      // the shell advances it itself, so three commits a minute glide at 60 fps.
      done: now.duration > 0 ? Math.min(1, now.position / now.duration) : 0,
      // …and `rate: 0` under Reduce Motion: the shell's self-advance is an
      // animation too, so the bar steps once per poll instead of gliding.
      rate:
        now.playing && now.duration > 0 && !ctxRef?.reduceMotion ? 1 / now.duration : 0,
    },
    artwork,
  };
  const signature = JSON.stringify(props, (key, value) =>
    key === "done" ? Math.round(value * 200) : value,
  );
  if (signature === lastProps) return;
  lastProps = signature;
  ctxRef.update(props);
}

/** Live activity: held while it plays, released when it stops — so the notch
 * goes back to being a notch. Published from the frame loop because that is the
 * first place the canvas node's ref is guaranteed to have landed. */
function publishWing() {
  if (!ctxRef) return;
  const held = Boolean(now?.playing) && wave !== null;
  const next = held ? `${now.title}|${wave.id}` : "";
  if (next === lastWing) return;
  lastWing = next;
  ctxRef.wing(held ? { text: now.title, canvas: { id: wave.id, w: WAVE_W } } : null);
}

// ---------------------------------------------------------------- transport

async function command(script) {
  if (!ctxRef || !now) return;
  await sendCommand(ctxRef, now.player, script);
  // Re-read at once rather than waiting out the poll: a play button that takes
  // three seconds to change shape feels broken even when it worked.
  await poll(ctxRef);
}

const onToggle = () => void command("playpause");
const onNext = () => void command("next track");

// ---------------------------------------------------------------- monitor

/** One read. Guarded against overlap: a playback notification and a monitor
 * pass can land in the same tick, and two reads are twice the Apple events for
 * one answer. */
async function poll(ctx) {
  if (polling) return;
  polling = true;
  try {
    const previous = now?.title;
    now = await readPlayback(ctx);
    artwork = await ensureArtwork(ctx, now, import.meta.dir);
    if (now?.title !== previous) phase = 0; // a new track starts its own wave
    publish();
  } finally {
    polling = false;
  }
}

export async function monitor(ctx) {
  ctxRef = ctx;
  if (!started) {
    started = true;
    for (const name of PLAYBACK_NOTIFICATIONS) {
      // Passive, and the latency fix rather than the truth: the poll stays the
      // authority on what is loaded, this only says when to ask.
      try {
        await ctx.platform.observe("distributedNotification", name);
      } catch (error) {
        console.log(`observe ${name}: ${error?.message ?? error}`);
      }
    }
    setInterval(tick, FRAME_MS);
  }
  try {
    await poll(ctx);
  } catch (error) {
    // A throw here would be a crash-and-backoff loop (spec §6 rule 2). A player
    // that quit mid-question should go quiet instead.
    console.log(`poll failed: ${error?.stack ?? error}`);
    now = null;
    publish();
  }
  await Bun.sleep(expanded ? POLL_EXPANDED_MS : POLL_COLLAPSED_MS);
}

export function onEvent(name, _data, ctx) {
  if (name !== "platform") return;
  ctxRef = ctxRef ?? ctx;
  clearTimeout(waking);
  waking = setTimeout(() => {
    void poll(ctxRef).catch((error) => console.log(`wake: ${error?.message ?? error}`));
  }, WAKE_MS);
}

export function onLifecycle(phaseName, ctx) {
  expanded = phaseName === "expanded";
  // Reduce Motion rides this envelope (spec §4.2) and may have just flipped, so
  // redraw once here rather than waiting for the loop that no longer runs.
  ctxRef = ctxRef ?? ctx;
  lastStill = null;
  if (ctxRef?.reduceMotion) still(Boolean(now?.playing));
  publish();
}

// ---------------------------------------------------------------- the panel

/** The well — the one framed region on the glass (design.html §09), at the
 * content radius. Everything else here sits unframed. */
const Sleeve = ({ src }) =>
  src ? (
    // `stroke` on the image itself (spec §5): artwork letterboxes, and a sleeve
    // that does not fill its box would otherwise lose the well's frame. A
    // stroked wrapper stack would double-frame it the moment one does fill.
    <image src={src} w={72} h={72} radius={14} stroke="hairline" />
  ) : (
    <stack fill="raised" stroke="hairline" radius={14} pad={36} />
  );

export default function NowPlaying({
  track = null,
  artwork: art = null,
  onPlayPause = onToggle,
  onSkip = onNext,
}) {
  // The invitation (design.html §09): one glyph, one line, no button. The glyph
  // is the signature at rest — flat bars are what silence looks like here.
  if (!track) {
    return (
      <stack axis="v" pad={26} gap={12} align="center">
        <image src="sf:waveform" w={26} h={26} />
        <text content="Play something — it lands here." size="s" color="secondary" />
      </stack>
    );
  }

  return (
    <stack axis="v" pad={16} gap={14}>
      {/* No <summary> and no <mini>, deliberately — see the header. */}
      <stack axis="h" gap={14} align="center">
        <Sleeve src={art} />
        <stack axis="v" gap={4}>
          <text content={track.title} size="l" truncate />
          <text content={track.artist} size="s" color="secondary" truncate />
        </stack>
        <spacer />
      </stack>

      <progress value={track.done} rate={track.rate} />

      <stack axis="h" gap={16} align="center">
        {/* The wing's own strip, sitting in the panel: the shell mirrors this
            node's frames into the notch, so they are literally the same pixels. */}
        <canvas ref={(node) => { wave = node; }} w={WAVE_W} h={WAVE_H} />
        <spacer />
        {/* Ghosts, not chips (design.html §06): app controls are bare pure-white
            glyphs and get a capsule only under the cursor. */}
        <button
          icon={track.playing ? "sf:pause.fill" : "sf:play.fill"}
          variant="ghost"
          onClick={() => onPlayPause?.()}
        />
        <button icon="sf:forward.end.fill" variant="ghost" onClick={() => onSkip?.()} />
      </stack>
    </stack>
  );
}
