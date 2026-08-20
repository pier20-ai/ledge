/** @jsxImportSource react */
// Now Playing — the app that owns the resting pill.
//
// SIGNATURE: the wing reel (G2.10, the weatherglass doctrine — simulate a
// substance, not a status). A tape reel spins in the collapsed notch while
// something plays, and the same node draws in the panel — one `ctx.draw`, two
// places. There is no audio tap on macOS, so the honest theatre is *rotation*:
// playing is the one thing we truly know, so the reel turns while it is true,
// coasts to a stop on pause, and winds back up on play. The old seven
// pseudo-waveform bars — sines pretending to be the song — are retired.
//
// Laws it exercises:
//   1   one step lighter — bare glyphs, no chips, no filled transport.
//   3   monochrome by choice: the artwork is the only colour, and no hue here
//       has a job, so none is spent.
//   4/5 no header, no labels, no clock digits — the title IS the display and
//       the meter IS the position.
//   8   NO <summary>. This app is its own summary, so a rested pointer opens
//       the visit directly.
//   9   live-activity wing: held while there is music. A track change is not a
//       stop — the surface stays, the ticker changes in place, and the wave
//       takes a *breath* (quiet, then a swell in the new track's character).
//       Released only once the player has really gone silent.
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

/**
 * How long the player may go quiet before the wing is given up.
 *
 * A gap between two tracks is **not** a stop. Both players spend a beat with
 * `current track` unreadable while the next one loads, and `readPlayback`
 * faithfully reports that as "nothing playing" — so the wing was released and
 * re-claimed a second later, and the notch blinked once per song. The wing is a
 * live activity: it should describe the *session*, not each individual sample of
 * it. Only a player that has stayed quiet for this long has really stopped.
 */
const STOP_GRACE_MS = 2_000;

/**
 * The breath (principle 9, and the reason a track change is not a flicker).
 *
 * On a new track the wave goes **quiet** — the bars ease to the floor — and then
 * swells back with the new track's own seed. It is the same surface throughout;
 * nothing is released, nothing reappears. Roughly a second, which is about how
 * long the gap between two songs is anyway.
 */
const QUIET_MS = 520;
const SWELL_MS = 620;

/** Re-declare the wing at least this often while it is held. The shell takes an
 * idle wing back after Ta (flow.md, "holder idle > Ta") and every request from
 * the holder re-arms that timer — so an app whose ticker happens not to change
 * for the length of a long track must still say it is alive, or the notch goes
 * bare in the middle of a song and nothing ever puts it back. */
const WING_HEARTBEAT_MS = 45_000;

// The reel (G2.10's fun pass, the weatherglass doctrine): the wing is a tape
// reel spinning at true elapsed rate — rotation is the one signal we honestly
// have (position, playing), so rotation is the theatre. Three spoke holes
// turn inside a dotted rim; pause and it coasts to a stop, play and it winds
// back up. No fake audio levels pretending to be the song.
const WAVE_W = 40;
const WAVE_H = 34; // the notch's own height — the wing canvas' coordinate space
const REEL_R = 13; // the rim's radius
const SPOKE_R = 7.5; // where the three holes ride
const REEL_RPS = 0.24; // revolutions per second: legible at 11 fps, calm

let ctxRef = null;
let now = null; // the last read playback state, or null
/**
 * What the surfaces are showing — which is deliberately **not** the last sample.
 *
 * Between two songs both players spend a beat with `current track` unreadable,
 * so `now` goes null and comes back a moment later with the next title. Rendered
 * literally, that emptied the panel to its invitation, unmounted the `<canvas>`,
 * and dropped the wing — the notch and the panel both blinked, once per song.
 * `shown` is the *session*: it survives a missing sample for `STOP_GRACE_MS`, and
 * only a player that has really gone quiet clears it.
 *
 * A **pause** is not a gap. A paused player still answers with its track, so
 * `now` is non-null and the wing goes at once (law 9) — the grace only ever
 * covers the case where there is no answer at all.
 */
let shown = null;
let artwork = null;
let expanded = false;
let polling = false;
let waking = null;
let started = false;

let wave = null; // the canvas node, from a ref; its id is what ctx.draw targets
let ink = 0; // the reel's eased visibility, 0…1
let spin = 0; // the reel's angle, in revolutions
let spinVel = 0; // revolutions per second — the reel has inertia
let breathAt = 0; // when the track last changed under a held wing; 0 = not breathing

// ---------------------------------------------------------------- the reel

/**
 * The breath, 0…1 — how much of the wave is *let through* this frame.
 *
 * One while a track is playing and settled. Zero while the player is between
 * two tracks, and zero for `QUIET_MS` after a new one lands, then smoothstepped
 * back over `SWELL_MS` with the new track's own seed. Because the bars are eased
 * toward their target rather than set to it (see `paint`), a target of zero is a
 * **fall to the floor**, not a cut — which is the whole difference between a
 * breath and a blink.
 *
 * Self-clearing: the envelope ends by putting `breathAt` back to 0, so nothing
 * has to remember to stop it.
 */
function breath() {
  if (!now?.playing) return 0; // the gap between two tracks: nothing to let through
  if (breathAt === 0) return 1;
  const dt = Date.now() - breathAt;
  if (dt < QUIET_MS) return 0;
  const k = (dt - QUIET_MS) / SWELL_MS;
  if (k >= 1) {
    breathAt = 0;
    return 1;
  }
  return k * k * (3 - 2 * k);
}

/** Arm the breath for a track that has just started.
 *
 * `hadGap` is true when the player had already gone silent for a beat — the
 * lead-in has then happened for real, in the world, and adding another half
 * second of flat bars on top of it would read as a stall rather than as a
 * breath. Dating the envelope back by `QUIET_MS` skips straight to the swell. */
function startBreath(hadGap) {
  breathAt = Date.now() - (hadGap ? QUIET_MS : 0);
}

/** One frame. Hex, not tokens — a canvas is pixels, not a view.
 *
 * `held` is whether the wave is up at all — which is *not* the same as "a track
 * is playing this instant": through a track change the surface is held and the
 * breath above takes the bars down and back. `still` is Reduce Motion (spec
 * §4.2, principle 10): the bars take the arch they would average out to and stay
 * there. Still, not slower and not blank — the meter still says "playing", it
 * just stops breathing, and the track-change breath is motion too, so it does
 * not run there either. */
/** A white with `v` (0…1) of alpha — every part of the reel scales with the
 * ink, so the track-change breath dims the whole instrument and swells it
 * back rather than resizing anything. */
function shade(v) {
  const a = Math.round(Math.min(1, Math.max(0, v)) * 255);
  return `#FFFFFF${a.toString(16).padStart(2, "0").toUpperCase()}`;
}

function dot(ops, x, y, d, v) {
  ops.push({ op: "rect", x: x - d / 2, y: y - d / 2, w: d, h: d, radius: d / 2, fill: shade(v) });
}

function paint(held, still = false) {
  if (!ctxRef || !wave) return;
  const open = still ? 1 : breath();
  const wanted = held ? (still ? 0.85 : open) : 0;
  // Ease, never jump: the reel is a body dimming, not a chart repainting.
  // Under Reduce Motion there is no easing — one frame, done.
  if (still) ink = wanted;
  else ink += (wanted - ink) * 0.25;

  const cx = WAVE_W / 2;
  const cy = WAVE_H / 2;
  const ops = [{ op: "clear" }];
  // The rim: ten fixed dots. The frame of the instrument, faint at rest.
  for (let i = 0; i < 10; i += 1) {
    const a = (i / 10) * Math.PI * 2;
    dot(ops, cx + Math.cos(a) * REEL_R, cy + Math.sin(a) * REEL_R, 2, 0.2 + 0.5 * ink);
  }
  // The three spoke holes: the part that turns. Under Reduce Motion the reel
  // stands still — `spin` simply stops advancing — but stays fully drawn.
  for (let k = 0; k < 3; k += 1) {
    const a = (spin + k / 3) * Math.PI * 2;
    dot(ops, cx + Math.cos(a) * SPOKE_R, cy + Math.sin(a) * SPOKE_R, 5, 0.15 + 0.75 * ink);
  }
  // The spindle.
  dot(ops, cx, cy, 3, 0.25 + 0.6 * ink);
  ctxRef.draw(wave.id, ops);
}

/** The animation clock. A setInterval, not a monitor pass: the monitor loop has
 * a 1 s spin floor (spec §6 rule 1), and a level meter at 1 fps is a bar chart.
 * It keeps running while the panel is collapsed on purpose — collapsed is when
 * the wing is the whole app. */
function tick() {
  // The surface's state, not the sample's — see `resolve`. Recomputed every
  // frame because it is a function of *time*: the grace window expires on the
  // clock, with no new reading to trigger it.
  const held = resolve();
  // Principle 10 (spec §4.2): with Reduce Motion on there is no loop at all —
  // one frame per state, and then nothing until the state changes. This is the
  // shape any canvas app should copy: check the flag inside the loop, because
  // the flag can flip while the loop is running.
  if (ctxRef?.reduceMotion) return still(held);
  lastStill = null;
  // The wing first: `publish` re-renders, and a render that drops to the empty
  // state takes the `<canvas>` — and `wave` — with it.
  publishWing(held);
  publish();
  // Stopped and dark is a still frame, not a slower one. The frames between
  // "stopped" and "dark" still run, which is how the reel coasts to rest and
  // fades instead of snapping — and how the wing gets released.
  if (!held && ink < 0.01 && spinVel < 0.005) return;
  // The reel's inertia: play winds it up briskly, pause lets it coast. The
  // spin advances from its own velocity, so a pause is a spin-down you can
  // see, not a freeze-frame.
  const wantVel = now?.playing ? REEL_RPS : 0;
  spinVel += (wantVel - spinVel) * (now?.playing ? 0.3 : 0.08);
  spin += spinVel * (FRAME_MS / 1000);
  paint(held);
}

/** The Reduce Motion branch: redraw only when what the bars *mean* changed. */
let lastStill = null;
function still(held) {
  publishWing(held);
  publish();
  const signature = `${held}|${shown?.title ?? ""}`;
  if (signature === lastStill) return;
  lastStill = signature;
  paint(held, true);
}

// ---------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";
/** When the player last answered with nothing at all; 0 while it is answering. */
let quietSince = 0;
/** When the wing was last declared, for the heartbeat. */
let wingSentAt = 0;

/**
 * Fold the latest sample into what the surfaces show, and answer the one
 * question everything downstream needs: **is the live activity up?**
 *
 * Three cases, and the middle one is the whole fix:
 *
 *   * the player answered and is playing — `shown` is it, the wing is up;
 *   * the player did not answer at all — a track change, most of the time. For
 *     `STOP_GRACE_MS` the previous track stays on both surfaces and the wing
 *     stays held; the *wave* goes quiet (see `breath`), which is the visible
 *     breath in place of a vanish;
 *   * the player answered and is paused or stopped — an explicit, user-visible
 *     stop. The panel keeps the track (there is one to keep) and the wing goes
 *     at once, because law 9 is about the notch, not about the panel.
 *
 * Pure bookkeeping: it sends nothing. `publish` and `publishWing` do that.
 */
function resolve() {
  if (now) {
    quietSince = 0;
    shown = now;
    return Boolean(now.playing);
  }
  if (quietSince === 0) quietSince = Date.now();
  if (shown && Date.now() - quietSince < STOP_GRACE_MS) return true;
  shown = null;
  return false;
}

function publish() {
  if (!ctxRef) return;
  const props = {
    track: shown && {
      title: shown.title,
      artist: shown.artist,
      // Through the gap there is no sample to be paused *by*, and the transport
      // must not flicker to a play glyph and back between two songs.
      playing: now ? now.playing : true,
      // The meter is a fraction, and `rate` is what moves it between polls:
      // the shell advances it itself, so three commits a minute glide at 60 fps.
      done: shown.duration > 0 ? Math.min(1, shown.position / shown.duration) : 0,
      // …and `rate: 0` under Reduce Motion: the shell's self-advance is an
      // animation too, so the bar steps once per poll instead of gliding.
      rate:
        now?.playing && shown.duration > 0 && !ctxRef?.reduceMotion
          ? 1 / shown.duration
          : 0,
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

/**
 * Live activity: held while there is music, released when there is not — so the
 * notch goes back to being a notch. Published from the frame loop because that
 * is the first place the canvas node's ref is guaranteed to have landed.
 *
 * Two things it does that the naive version did not:
 *
 *   * **It holds across a track change.** `resolve` decides that; this only has
 *     to send the *same* surface with a new ticker instead of a release
 *     followed by a fresh claim. One `wing` envelope, text updated in place.
 *   * **It says it is alive.** The shell reclaims an idle wing after Ta
 *     (flow.md, "holder idle > Ta"), re-armed by every request the holder
 *     sends. A five-minute track changes nothing about the ticker, so without
 *     the heartbeat the notch went bare mid-song and — because the app believed
 *     it had already asked for exactly this wing — nothing ever put it back.
 */
function publishWing(held) {
  if (!ctxRef) return;
  // `wave` folds into the claim rather than guarding the whole function: the
  // canvas unmounts with the empty state, and a release that skipped itself
  // because there was no canvas left to mirror would strand the wing forever.
  const up = held && shown !== null && wave !== null;
  const next = up ? `${shown.title}|${wave.id}` : "";
  const stale = up && Date.now() - wingSentAt > WING_HEARTBEAT_MS;
  if (next === lastWing && !stale) return;
  lastWing = next;
  wingSentAt = Date.now();
  ctxRef.wing(up ? { text: shown.title, canvas: { id: wave.id, w: WAVE_W } } : null);
}

// ---------------------------------------------------------------- transport

async function command(script) {
  // `shown`, not `now`: pressing skip in the beat between two tracks must still
  // reach the player the panel is currently describing.
  if (!ctxRef || !shown) return;
  await sendCommand(ctxRef, shown.player, script);
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
    if (now?.title !== previous && now?.title) {
      // A new track: the reel takes a breath before it turns for it — dim,
      // then a swell. `previous` being absent means the player had already
      // gone silent between the two, so the quiet has been served.
      startBreath(previous === undefined);
    }
    resolve();
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
    resolve();
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
  const held = resolve();
  if (ctxRef?.reduceMotion) still(held);
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
    // The panel's own inset (design.html §09: `.stagepanel` is `20px 22px 22px`,
    // and Focus is already written to it). At 16 the sleeve, the progress bar and
    // the transport all but touched the glass edge — on device the panel read as
    // a screenshot of content rather than as content sitting on a surface.
    <stack axis="v" pad={20} gap={14}>
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
