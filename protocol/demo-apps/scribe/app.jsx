/** @jsxImportSource react */
// Scribe — a recorder with two honest needles (G3).
//
// SIGNATURE: **the needles.** Ledge has drawn plenty of meters that were
// theatre — bars breathing on a sine because something was playing. These are
// the first that are not: MIC and SYS are 0…1 RMS off the real capture engine,
// polled seven times a second, and a needle that stands still is a source that
// is genuinely silent. That is the whole reason the app exists, so the twin
// face is the stage and everything else on the panel serves it: one transport
// under it, and — depending on whether tape is rolling — either the jots you
// are taking or the sessions you have taken.
//
// Recording itself belongs to the shell (`ctx.record`): the microphone prompt
// is TCC and macOS attributes consent to the process with the UI, and the
// capture engine is one per process, which is why only one app records at a
// time. Playback and Finder are NOT the shell's — a finished file is just a
// file, so `open` is spawned here, the way radio spawns its own player.
//
// Laws it is written against: 1 (rows and one framed instrument, no cards) ·
// 3 (the face's cream and gold, and red for exactly one thing: live) ·
// 4 (the words are the jots — the user's own) · 5 (the record button IS the
// gesture; there is no "new session" dialog to name a take before it exists).
//
// Surfaces it exercises:
//   STAGE         the twin-needle meter, in the one framed region (§09).
//   WING CANVAS   a live activity while recording: the elapsed ticker in the
//                 left wing, a pulsing red dot in the right, re-claimed on a
//                 45 s heartbeat because the shell reclaims idle wings at Ta.
//   ADOPTION      the shell keeps recording through a worker restart, so the
//                 first `status()` of a new worker may find a live session of
//                 this app's own — it resumes rather than starting a second.
//   REDUCE MOTION the needles are SET once a second, no spring, no frames in
//                 between; the wing's dot holds at its middle radius.
//   SETTINGS      one native control: the format a take is written in, read at
//                 the moment the tape rolls and handed to `ctx.record.start`.
//   NO <mini>, NO NOTIFICATION — a recorder interrupting you is the joke that
//                 writes itself. Errors are one tertiary line under the
//                 transport, never a dialog.
//
// Test seam (host/test/scribe.test.ts drives the real worker):
//   LEDGE_RECORD_FAKE=1   swaps `ctx.record` for the fake below — no shell, no
//                         microphone, deterministic levels, real files.
//   LEDGE_RECORD_ROOT     where the fake keeps its sessions. The suite MUST
//                         set it: `import.meta.url` resolves through symlinks,
//                         so the fallback beside this file would land a test
//                         run's recordings in the repo (timer's
//                         LEDGE_ALARM_STORE lesson, learned once).

export const meta = {
  name: "Scribe",
  icon: "sf:mic",
  // Format is a choice because it is one: AAC is small and WAV is what an
  // editor wants, and no third answer is coming. The recorder's other knobs
  // (which sources, where the files go) are not settings — they are decisions
  // the shell owns, one per machine.
  settings: [
    {
      key: "format",
      label: "Recording format",
      type: "choice",
      options: ["aac", "wav"],
      default: "aac",
      hint: "WAV is uncompressed — larger files, no generation loss.",
    },
  ],
};

// ---------------------------------------------------------------- the seam

const FAKE = process.env.LEDGE_RECORD_FAKE === "1";
let faked = null;

/** Every `ctx.record` call in this file goes through here. Resolved lazily
 * because `ctx` only exists from the first monitor pass, and the timers below
 * outlive any single one of them. */
function rec() {
  if (FAKE) return (faked ??= fakeRecord());
  return ctxRef.record;
}

/**
 * The suite's recorder: the shell's reply shapes, sines instead of a
 * microphone, and a real `meta.json` written on stop — the session list is read
 * back off the disk, so a fake that only remembered things would leave the half
 * of this app that reads directories untested.
 */
function fakeRecord() {
  const root = process.env.LEDGE_RECORD_ROOT || new URL("./recordings", import.meta.url).pathname;
  const TRANSCRIPTION = { available: false, reason: "transcription needs a Ledge build against the macOS 26 SDK" };
  let live = null;
  let since = 0;
  return {
    status: async () => ({
      available: true,
      recording: live !== null,
      mine: live !== null,
      root,
      ...(live ? { session: { ...live } } : {}),
      transcription: TRANSCRIPTION,
    }),
    start: async (options) => {
      if (live) throw new Error("already recording for 'scribe'");
      const { mkdir } = await import("node:fs/promises");
      const id = new Date().toISOString().replace(/[:.]/g, "-");
      const dir = `${root}/${id}`;
      await mkdir(dir, { recursive: true });
      since = Date.now();
      live = {
        id,
        dir,
        startedAt: new Date().toISOString(),
        sources: options?.sources ?? ["mic", "system"],
        format: options?.format ?? "aac",
      };
      return { ...live };
    },
    levels: async () => {
      if (!live) throw new Error("nothing is recording");
      const t = (Date.now() - since) / 1000;
      const wave = (hz) => (Math.sin(t * hz) + 1) / 2;
      // Absent key for a source that is not in the session — the one thing an
      // app must handle differently from a source that happens to read zero.
      return {
        ...(live.sources.includes("mic") ? { mic: wave(2.1) } : {}),
        ...(live.sources.includes("system") ? { system: wave(3.4) } : {}),
        seconds: t,
      };
    },
    stop: async () => {
      if (!live) throw new Error("nothing is recording");
      const ext = live.format === "wav" ? "wav" : "m4a";
      const seconds = (Date.now() - since) / 1000;
      await Bun.write(
        `${live.dir}/meta.json`,
        JSON.stringify({
          id: live.id,
          app: "scribe",
          startedAt: live.startedAt,
          seconds,
          sources: live.sources,
          format: live.format,
          // Basenames in meta.json, absolute paths in the reply — the shell's
          // own split, so the folder stays movable.
          files: Object.fromEntries(live.sources.map((s) => [s, `${s}.${ext}`])),
        }),
      );
      const done = {
        id: live.id,
        dir: live.dir,
        seconds,
        files: Object.fromEntries(live.sources.map((s) => [s, `${live.dir}/${s}.${ext}`])),
      };
      live = null;
      return done;
    },
  };
}

// ---------------------------------------------------------------- state

const LEVEL_MS = 150; // ~7 readings a second: the needles' own clock
const TICK_MS = 1000; // the ticker, the wing, and its heartbeat
const WING_HEARTBEAT_MS = 45_000; // re-claim before the shell's Ta reclaim

let ctxRef = null;
let expanded = false;
let started = false;

let root = ""; // this app's recordings directory, from status()
let transcription = { available: false };
let recording = false;
let session = null; // { id, dir, startedAt, sources, format } while live
let polled = null; // { seconds, at } — the last honest reading of the clock
let since = 0; // local fallback between polls, and for an adopted session
let live = { mic: 0, system: 0 }; // the levels as read
let needle = { mic: 0, system: 0 }; // …and as the face shows them, with mass
let vel = { mic: 0, system: 0 };
let jots = [];
let sessions = [];
let draft = "";
let note = ""; // the one tertiary line: what went wrong, in a sentence
let busy = false; // one transport press at a time

const message = (error) => String(error?.message ?? error);

/** Seconds into the recording. `levels()` is the authority — it is the engine's
 * own clock — and the local one only fills the gap between readings. */
function elapsed() {
  if (!recording) return 0;
  if (polled) return polled.seconds + (Date.now() - polled.at) / 1000;
  return (Date.now() - since) / 1000;
}

function clock(seconds) {
  const whole = Math.max(0, Math.floor(seconds));
  const pad = (n) => String(n).padStart(2, "0");
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor(whole / 60) % 60;
  return hours > 0
    ? `${hours}:${pad(minutes)}:${pad(whole % 60)}`
    : `${pad(minutes)}:${pad(whole % 60)}`;
}

/** A session's moment, the way a person says it: "Mon 24 · 14:02". */
function when(ms) {
  const at = new Date(ms);
  return (
    `${at.toLocaleDateString("en-US", { weekday: "short", day: "numeric" })} · ` +
    at.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false })
  );
}

/** `startedAt` is ISO on the wire and in meta.json; a number is accepted too,
 * because a file on disk outlives the code that wrote it. */
function startedMs(value) {
  if (typeof value === "number") return value;
  const parsed = Date.parse(String(value ?? ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

// ---------------------------------------------------------------- the disk

/** The sessions this app has already taken. The root may not exist yet — a
 * first launch has recorded nothing — and that is an empty list, not an error.
 * A directory with no `meta.json` is skipped rather than guessed at: it is a
 * take the shell has not finalized. */
async function loadSessions() {
  if (!root) return;
  const rows = [];
  try {
    const { readdir } = await import("node:fs/promises");
    for (const entry of await readdir(root, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const dir = `${root}/${entry.name}`;
      let meta = null;
      try {
        meta = await Bun.file(`${dir}/meta.json`).json();
      } catch {
        continue;
      }
      let count = 0;
      try {
        const kept = await Bun.file(`${dir}/jots.json`).json();
        count = Array.isArray(kept) ? kept.length : 0;
      } catch {
        // A session nobody wrote a note during.
      }
      const length = clock(Number(meta.seconds) || 0);
      rows.push({
        id: entry.name,
        dir,
        at: startedMs(meta.startedAt),
        when: when(startedMs(meta.startedAt)),
        sub: count > 0 ? `${length} · ${count} jot${count === 1 ? "" : "s"}` : length,
      });
    }
  } catch {
    // No root yet: nothing has ever been recorded.
  }
  rows.sort((a, b) => b.at - a.at); // newest first — the one you just took
  sessions = rows;
}

/** The jots, written after every append (temp file + rename, REFERENCE.md's
 * rule: a half-written JSON file is a crash loop on the next read). */
async function saveJots() {
  if (!session) return;
  const target = `${session.dir}/jots.json`;
  try {
    await Bun.write(`${target}.tmp`, JSON.stringify(jots));
    const { rename } = await import("node:fs/promises");
    await rename(`${target}.tmp`, target);
  } catch (error) {
    console.log(`jots: ${message(error)}`);
  }
}

// ---------------------------------------------------------------- actions

/** The whole transport: one press starts, the next stops. */
async function transport() {
  if (busy) return;
  busy = true;
  try {
    if (recording) await stopTake();
    else await startTake();
  } finally {
    busy = false;
  }
}

async function startTake() {
  note = "";
  let opened = null;
  try {
    // The format the user picked, read at the moment the take starts — never
    // before, because a setting changed between two takes has to land on the
    // second one. Absent (no delivery yet) means the shell's own default.
    opened = await rec().start({ format: ctxRef?.settings?.format });
  } catch (error) {
    // Denied microphone, another app already recording, no capability at all:
    // all of it is one line under the transport (§09 — never a dialog).
    note = message(error);
    commit();
    return;
  }
  adopt(opened, Date.now());
  jots = [];
  commit();
  paint();
  stagePaint();
}

/** Take over a live session — a fresh one from `start`, or this app's own found
 * still running by the first `status()` after a worker restart. */
function adopt(found, startedAtMs) {
  session = found;
  recording = true;
  polled = null;
  since = startedAtMs;
  live = { mic: 0, system: 0 };
  needle = { mic: 0, system: 0 };
  vel = { mic: 0, system: 0 };
}

async function stopTake() {
  try {
    await rec().stop();
    note = "";
  } catch (error) {
    // The files are the shell's to finalize; whatever it says, this worker is
    // no longer the one holding the session.
    note = message(error);
  }
  recording = false;
  session = null;
  polled = null;
  live = { mic: 0, system: 0 };
  needle = { mic: 0, system: 0 };
  vel = { mic: 0, system: 0 };
  await loadSessions();
  commit(); // …which hands the wing back
  paint();
  stagePaint();
}

/** Enter in the jot field. The field is cleared in TWO commits with a breath
 * between (timer's lesson): echo the typed value, then empty it, or the two
 * updates coalesce into a diff of nothing and the text stays put. */
async function jot(value) {
  const text = String(value ?? "").trim();
  draft = text;
  commit();
  await Bun.sleep(30);
  draft = "";
  commit();
  if (!text || !recording) return;
  jots.push({ at: Math.floor(elapsed()), text });
  commit();
  await saveJots();
}

/** Finder, not a capability: a finished session is a folder on disk. */
function reveal(dir) {
  Bun.spawn(["open", dir], { stdout: "ignore", stderr: "ignore" });
}

async function discard(dir) {
  try {
    const { rm } = await import("node:fs/promises");
    await rm(dir, { recursive: true, force: true });
  } catch (error) {
    note = message(error);
  }
  await loadSessions();
  commit();
}

// ---------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";
let wingSentAt = 0;

function commit() {
  if (!ctxRef) return;
  const props = {
    recording,
    elapsed: clock(elapsed()),
    jots: jots.map((row) => ({ at: row.at, stamp: `[${clock(row.at)}]`, text: row.text })),
    sessions,
    draft,
    note,
    // The one thing the panel says about transcription: that this machine
    // cannot do it. When it can, there is nothing to say.
    transcription: transcription.available ? "" : (transcription.reason ?? ""),
  };
  const signature = JSON.stringify(props);
  if (signature !== lastProps) {
    lastProps = signature;
    ctxRef.update(props);
  }

  // The live activity: held for the length of the take, released on stop — and
  // re-declared on a heartbeat, or an idle reclaim takes the notch back mid
  // session (REFERENCE.md, "Say it again, even when nothing changed").
  const held = recording && dot !== null;
  const wanted = held ? `${props.elapsed}|${dot.id}` : "";
  const stale = held && Date.now() - wingSentAt > WING_HEARTBEAT_MS;
  if (wanted === lastWing && !stale) return;
  lastWing = wanted;
  wingSentAt = Date.now();
  ctxRef.wing(held ? { text: props.elapsed, canvas: { id: dot.id, w: WING_W } } : null);
}

// ---------------------------------------------------------------- the dot

// The wing's whole picture: one red dot, breathing once a second. It is the
// oldest recording idiom there is, and it is the right one — the ticker beside
// it already says how long, so this only has to say *live*.

const WING_W = 14;
const WING_H = 14;
const HOT = "#E8402A";
const DOT_R = 4.5;

function paint() {
  if (!ctxRef || !dot) return;
  const still = Boolean(ctxRef.reduceMotion);
  const ops = [{ op: "clear" }];
  if (recording) {
    const r = still ? DOT_R : DOT_R + Math.sin((Date.now() / 1000) * Math.PI * 2);
    ops.push({
      op: "rect",
      x: WING_W / 2 - r,
      y: WING_H / 2 - r,
      w: r * 2,
      h: r * 2,
      radius: r,
      fill: HOT,
    });
  }
  ctxRef.draw(dot.id, ops);
}

// ---------------------------------------------------------------- the face
//
// The stage: two arc-swept needles on one dark slab, MIC left and SYS right,
// drawn as the same deco machine the radio dial is — cream scale, gold pivot
// cap, ticks reaching in from the arc, and the last fifth of each scale marked
// hot because that is where a recording starts to clip. The needles have mass
// (the radio's spring, faster: a level meter that lags is lying about a
// transient), and they read RED while the take is live and dim white when it
// is not.

const STAGE_W = 380;
const STAGE_H = 150;
const PIVOT_Y = 122;
const ARC_R = 74;
const SWEEP = 55; // degrees either side of vertical: 0 left, 1 right
const FACES = [
  { key: "mic", label: "MIC", cx: 100 },
  { key: "system", label: "SYS", cx: 280 },
];

const INK_SCALE = "#E8E2D0B8"; // cream
const INK_RULE = "#FFFFFF2E";
const INK_TICK = "#FFFFFF55";
const INK_MARK = "#C9A86ACC"; // gold
const INK_DIM = "#FFFFFF3D";

let stage = null;
let dot = null;

/** Where a 0…1 reading sits on the arc, in radians from straight up. */
const swing = (value) => (-SWEEP + Math.max(0, Math.min(1, value)) * SWEEP * 2) * (Math.PI / 180);
const armX = (cx, angle, r) => cx + Math.sin(angle) * r;
const armY = (angle, r) => PIVOT_Y - Math.cos(angle) * r;

function faceOps(ops, face, value, lit) {
  const { cx, label } = face;

  const arc = [];
  for (let i = 0; i <= 24; i += 1) {
    const a = swing(i / 24);
    arc.push([armX(cx, a, ARC_R), armY(a, ARC_R)]);
  }
  ops.push({ op: "line", points: arc, stroke: INK_RULE, width: 1 });

  for (let i = 0; i <= 12; i += 1) {
    const k = i / 12;
    const a = swing(k);
    const major = i % 3 === 0;
    const reach = major ? 9 : 5;
    ops.push({
      op: "line",
      points: [
        [armX(cx, a, ARC_R), armY(a, ARC_R)],
        [armX(cx, a, ARC_R - reach), armY(a, ARC_R - reach)],
      ],
      // The clipping end of the scale is marked on the face, not by turning
      // the needle red — the needle is already saying whether tape is rolling.
      stroke: k > 0.83 ? HOT : lit ? (major ? INK_TICK : INK_RULE) : INK_RULE,
      width: 1,
    });
  }

  ops.push({
    op: "text",
    content: label,
    x: cx - label.length * 2.7,
    y: PIVOT_Y + 10,
    size: 9,
    color: lit ? INK_SCALE : INK_DIM,
  });

  const a = swing(value);
  ops.push({
    op: "line",
    points: [
      [armX(cx, a, 6), armY(a, 6)],
      [armX(cx, a, ARC_R - 11), armY(a, ARC_R - 11)],
    ],
    stroke: lit ? HOT : "#FFFFFF4D",
    width: 2,
  });

  // The pivot, stepped: a plate and a cap, the dial's own hardware.
  ops.push({ op: "rect", x: cx - 10, y: PIVOT_Y - 3, w: 20, h: 8, radius: 3, fill: "#FFFFFF24" });
  ops.push({
    op: "rect",
    x: cx - 5,
    y: PIVOT_Y - 5,
    w: 10,
    h: 9,
    radius: 4,
    fill: lit ? INK_MARK : "#FFFFFF33",
  });
}

function stagePaint() {
  if (!ctxRef || !stage || !expanded) return;
  const ops = [
    { op: "clear" },
    { op: "rect", x: 0, y: 0, w: STAGE_W, h: STAGE_H, fill: "#0B0B0Ecc", radius: 6 },
  ];
  // The deco pediments, as on the dial: the face is a machine, and a machine
  // has edges.
  for (const capX of [11, STAGE_W - 11]) {
    ops.push({ op: "rect", x: capX - 1.5, y: 34, w: 3, h: 88, radius: 1.5, fill: "#FFFFFF24" });
  }
  ops.push({
    op: "line",
    points: [
      [24, PIVOT_Y + 22],
      [STAGE_W - 24, PIVOT_Y + 22],
    ],
    stroke: INK_RULE,
    width: 1,
  });
  for (const face of FACES) faceOps(ops, face, needle[face.key], recording);
  ctxRef.draw(stage.id, ops);
}

// ---------------------------------------------------------------- the clocks

let lastStill = 0;
let reading = false;

/** Advance the needles toward what the engine just said. Reduce Motion sets
 * them instead: still, not slower — and the reading itself still lands, because
 * a meter that froze would be broken rather than accessible (spec §4.2). */
function step(still) {
  for (const face of FACES) {
    const key = face.key;
    const target = typeof live[key] === "number" ? Math.max(0, Math.min(1, live[key])) : 0;
    if (still) {
      needle[key] = target;
      vel[key] = 0;
      continue;
    }
    vel[key] += (target - needle[key]) * 0.35;
    vel[key] *= 0.72;
    needle[key] += vel[key];
  }
}

async function sample() {
  if (!recording || !ctxRef) return;
  const still = Boolean(ctxRef.reduceMotion);
  // Under Reduce Motion the whole loop drops to 1 Hz: one reading, set onto
  // the needles, no interim frames to drop.
  if (still && Date.now() - lastStill < TICK_MS) return;
  lastStill = Date.now();
  if (!reading) {
    reading = true;
    try {
      const read = await rec().levels();
      polled = { seconds: Number(read.seconds) || 0, at: Date.now() };
      live = { mic: read.mic, system: read.system };
    } catch {
      // One failed poll is not worth a line in the panel: the transport still
      // works and the next reading is 150 ms away.
    } finally {
      reading = false;
    }
  }
  step(still);
  paint();
  stagePaint();
}

function tick() {
  if (!recording) return;
  commit(); // the ticker, and the wing's heartbeat with it
}

// ---------------------------------------------------------------- lifecycle

export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  if (phase === "expanded") expanded = true;
  if (phase === "collapsed") expanded = false;
  paint();
  stagePaint();
}

export async function monitor(ctx) {
  ctxRef = ctx;
  let status = null;
  try {
    status = await rec().status();
  } catch (error) {
    // No shell yet, or none that records. Say so and try again — this is the
    // one thing in the app worth the monitor loop's own pacing.
    note = message(error);
    commit();
    await Bun.sleep(5_000);
    return;
  }

  root = String(status.root ?? "");
  transcription = status.transcription ?? { available: false };
  note = status.available ? "" : (status.reason ?? "");

  if (!started) {
    started = true;
    // The shell keeps recording through a worker restart, so a live session of
    // this app's own is resumed, not replaced — its elapsed clock comes from
    // the session's own start, not from this worker's boot.
    if (status.recording && status.mine && status.session) {
      adopt(status.session, startedMs(status.session.startedAt) || Date.now());
      jots = [];
      try {
        const kept = await Bun.file(`${status.session.dir}/jots.json`).json();
        if (Array.isArray(kept)) jots = kept;
      } catch {
        // Nothing was jotted before the restart.
      }
    }
    await loadSessions();
    setInterval(sample, LEVEL_MS);
    setInterval(tick, TICK_MS);
    commit();
    paint();
    stagePaint();
  }

  // Nothing left to poll: the needles own the frame clock and the transport
  // owns the state. Park (REFERENCE.md, "The monitor loop").
  await new Promise(() => {});
}

// ---------------------------------------------------------------- the panel

export default function Scribe({
  recording: rolling = false,
  elapsed: ticker = "00:00",
  jots: notes = [],
  sessions: past = [],
  draft: text = "",
  note: line = "",
  transcription: transcriptionNote = "",
  onTransport = transport,
  onJot = jot,
  onReveal = reveal,
  onDiscard = discard,
}) {
  return (
    // Radio's alignment recipe: the outer column centres, the inner one lets
    // its children stretch to the widest of them — the meter's slab — so the
    // rows below line up with the instrument's edges exactly.
    <stack axis="v" pad={16} align="center">
      <stack axis="v" gap={8}>
        {/* The needles, in the one framed region (§09). Nothing is wired to
            them: a level meter is read, never pressed. */}
        <stack axis="v" pad={2} fill="black" stroke="hairline" radius={8}>
          <canvas
            ref={(node) => {
              stage = node;
            }}
            w={STAGE_W}
            h={STAGE_H}
          />
        </stack>

        {/* The transport. One press is the whole gesture — the take names
            itself by when it happened. */}
        <stack axis="h" gap={12} pad={6} align="center">
          <button
            icon={rolling ? "sf:stop.circle" : "sf:record.circle"}
            variant="ghost"
            size="l"
            onClick={() => onTransport?.()}
          />
          <text content={rolling ? ticker : ""} size="l" mono color="primary" />
          <spacer />
          {/* The wing's own dot, sitting in the panel: the shell mirrors this
              node's frames into the notch — the same pixels, two places. */}
          <canvas
            ref={(node) => {
              dot = node;
            }}
            w={WING_W}
            h={WING_H}
          />
        </stack>

        {line ? <text content={line} size="xs" color="tertiary" /> : null}

        {rolling ? (
          <>
            {/* The jots: your own words, stamped where you said them. */}
            <stack axis="v" gap={2} scroll>
              {notes.map((row, index) => (
                <stack key={`${row.at}-${index}`} axis="h" gap={8} pad={6} align="center">
                  <text content={row.stamp} size="xs" color="tertiary" mono />
                  <text content={row.text} size="s" color="primary" truncate />
                </stack>
              ))}
            </stack>
            <input
              value={text}
              placeholder="jot — Enter keeps it"
              onChange={({ value }) => onJot?.(value)}
            />
          </>
        ) : (
          <>
            {past.length === 0 ? (
              // §09's empty state: one glyph, one line, no apology.
              <stack axis="v" pad={22} gap={10} align="center">
                <image src="sf:mic" w={26} h={26} />
                <text content="Nothing recorded yet — press record." size="s" color="secondary" />
              </stack>
            ) : (
              <stack axis="v" gap={2} scroll>
                {past.map((row) => (
                  <stack key={row.id} axis="h" gap={10} pad={6} align="center">
                    <stack axis="v" gap={2}>
                      <text content={row.when} size="m" color="primary" />
                      <text content={row.sub} size="xs" color="tertiary" />
                    </stack>
                    <spacer />
                    <button icon="sf:folder" variant="ghost" onClick={() => onReveal?.(row.dir)} />
                    <button icon="sf:xmark" variant="ghost" onClick={() => onDiscard?.(row.dir)} />
                  </stack>
                ))}
              </stack>
            )}
            {transcriptionNote ? (
              <text content={transcriptionNote} size="xs" color="tertiary" />
            ) : null}
          </>
        )}
      </stack>
    </stack>
  );
}
