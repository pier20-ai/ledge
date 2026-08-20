/** @jsxImportSource react */
// Radio — three real stations, actually playing (G2.9).
//
// The fixture era is over: this app fetches the top three stations on Earth
// from the Radio Browser directory (https://api.radio-browser.info — community
// run, keyless) and plays the one you pick through AVFoundation. Ledge itself
// still renders nothing but glass: the audio lives in one spawned `osascript`
// runloop the worker owns and kills.
//
// Laws it is written against: 1 (no card, no artwork frame), 3 (ink only; the
// meter is white), 4 (station names are the only words, and they are data),
// 5 (the station list IS the switcher — three rows of the datum, the current
// one in primary ink; no segmented control invented around them).
//
// Surfaces it exercises:
//   NO SUMMARY   declares neither <summary> nor <mini>: it is its own summary,
//                so a rested pointer opens the visit directly (principle 8).
//   WING CANVAS  a live-activity strip in the right wing while playing, drawn
//                imperatively at ~8 fps; the same node sits in the panel.
//   REDUCE MOTION the bars stand at a fixed profile (spec §4.2).
//
// Test seams (host/test/radio.test.ts drives the real worker):
//   LEDGE_RADIO_STATIONS  JSON station list — skips the network.
//   LEDGE_RADIO_MUTE=1    skips the audio process — state still flows.

export const meta = { name: "Radio", icon: "sf:dot.radiowaves.left.and.right" };

// ---------------------------------------------------------------- the dial

/** Radio Browser mirrors, tried in order. The project asks clients to spread
 * load across mirrors and name themselves; both requests are cheap to honour. */
const MIRRORS = [
  "https://de1.api.radio-browser.info/json",
  "https://de2.api.radio-browser.info/json",
  "https://fi1.api.radio-browser.info/json",
];
const USER_AGENT = "Ledge-Radio/1.0";
/** Most-listened-to right now, not most-voted-ever: a radio app is live. */
const TOP = "stations/topclick/3?hidebroken=true";
/** Yesterday's dial, for a cold or offline launch (same pattern as weather). */
const CACHE = new URL("./stations.json", import.meta.url);

let mirror = MIRRORS[0];

async function fetchTop() {
  for (const base of MIRRORS) {
    try {
      const res = await fetch(`${base}/${TOP}`, {
        headers: { "User-Agent": USER_AGENT },
        signal: AbortSignal.timeout(6000),
      });
      if (!res.ok) continue;
      const rows = await res.json();
      if (!Array.isArray(rows) || rows.length === 0) continue;
      mirror = base;
      return rows.map((row) => ({
        uuid: row.stationuuid,
        name: String(row.name ?? "").trim() || "unnamed",
        url: row.url_resolved || row.url,
        country: String(row.countrycode ?? "").trim(),
      }));
    } catch {
      // The next mirror is the retry.
    }
  }
  return null;
}

async function loadStations() {
  // The test seam first: a suite must not depend on the public internet.
  const fixture = process.env.LEDGE_RADIO_STATIONS;
  if (fixture) return JSON.parse(fixture);
  const fresh = await fetchTop();
  if (fresh) {
    Bun.write(CACHE, JSON.stringify(fresh)).catch(() => {});
    return fresh;
  }
  try {
    const cached = await Bun.file(CACHE).json();
    if (Array.isArray(cached) && cached.length > 0) return cached;
  } catch {
    // No cache is the honest first launch.
  }
  return null;
}

/** Radio Browser etiquette: tell the directory a station was tuned. Fire and
 * forget — a click count is not worth a spinner, or an error. */
function registerClick(station) {
  if (!station.uuid || process.env.LEDGE_RADIO_STATIONS) return;
  fetch(`${mirror}/url/${station.uuid}`, {
    headers: { "User-Agent": USER_AGENT },
    signal: AbortSignal.timeout(6000),
  }).catch(() => {});
}

// ---------------------------------------------------------------- the sound

/** One AVPlayer in one osascript process: no install, no dock icon, dies with
 * a kill. AVFoundation handles what stations actually stream — icecast mp3,
 * aac, HLS. Volume is set below full so a first play never blasts.
 *
 * AppleScriptObjC, NOT JXA (G2.10): JXA's ObjC bridge is built from headers
 * it does not have for AVFoundation — `$.AVPlayer` is simply `undefined` and
 * the process exits in a blink, which on device read as "play works for a
 * split second and stops". AppleScript's bridge introspects at runtime, so
 * the same classes are reachable. The repeat/delay loop is the keep-alive:
 * a bare runloop with no sources returns immediately; AVPlayer's audio
 * pipeline runs on its own threads while this one sleeps. */
const playerScript = (url) => [
  'use framework "AVFoundation"',
  "use scripting additions",
  `set streamURL to current application's NSURL's URLWithString:"${String(url).replace(/[\\"]/g, "")}"`,
  "set thePlayer to current application's AVPlayer's playerWithURL:streamURL",
  "thePlayer's setVolume:0.8",
  "thePlayer's play()",
  "repeat",
  "delay 60",
  "end repeat",
];

let proc = null;

function startAudio(station) {
  if (process.env.LEDGE_RADIO_MUTE === "1" || !station.url) return;
  registerClick(station);
  proc = Bun.spawn(["osascript", ...playerScript(station.url).flatMap((line) => ["-e", line])], {
    stdout: "ignore",
    stderr: "ignore",
  });
  const mine = proc;
  mine.exited.then(() => {
    // Superseded by a stop or a retune: nothing to report.
    if (proc !== mine) return;
    proc = null;
    // The stream died under us. The truthful state is stopped.
    if (playing) {
      playing = false;
      commit();
      paint();
    }
  });
}

function stopAudio() {
  const running = proc;
  proc = null; // first, so the exit handler knows it was asked for
  running?.kill();
}

// ---------------------------------------------------------------- state

const FRAME_MS = 120; // ~8 fps: enough for a breathing meter
const WING_HEARTBEAT_MS = 45_000; // re-claim before the shell's Ta reclaim

const BARS = 5;
const BAR_W = 4;
const BAR_GAP = 4;
const WING_W = BARS * BAR_W + (BARS - 1) * BAR_GAP;
const WING_H = 34;

let ctxRef = null;
let meter = null;
let stations = null; // null until the dial loads; then exactly three
let current = 0;
let playing = false;
let frame = 0;

// ---------------------------------------------------------------- actions

function toggle() {
  if (playing) {
    playing = false;
    stopAudio();
  } else {
    if (!stations?.[current]) return;
    playing = true;
    tunedAt = Date.now(); // powering on sweeps through the static too
    startAudio(stations[current]);
  }
  commit();
  paint();
}

/** Click a station row: that station plays. Radio has no "selected but
 * silent" — turning the dial is the whole gesture. */
function tune(index) {
  if (!stations?.[index]) return;
  if (index === current && playing) return;
  current = index;
  stopAudio();
  playing = true;
  tunedAt = Date.now(); // the static sweep: the dial audibly *travels*
  needle = 0; // the needle slams home and climbs back with the lock
  needleVel = 0;
  startAudio(stations[current]);
  commit();
  paint();
}

// ---------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";
let wingSentAt = 0;

function commit() {
  if (!ctxRef) return;
  const props = {
    stations: stations?.map((s) => ({ name: s.name, country: s.country })) ?? null,
    current,
    playing,
  };
  const signature = JSON.stringify(props);
  if (signature !== lastProps) {
    lastProps = signature;
    ctxRef.update(props);
  }

  // Live activity: the wing is held while it plays, released when it stops —
  // and re-declared on a heartbeat, or an idle reclaim keeps it forever.
  const held = playing && meter !== null && stations !== null;
  const wanted = held ? `${stations[current].name}|${meter.id}` : "";
  const stale = held && Date.now() - wingSentAt > WING_HEARTBEAT_MS;
  if (wanted === lastWing && !stale) return;
  lastWing = wanted;
  wingSentAt = Date.now();
  ctxRef.wing(
    held ? { text: stations[current].name, canvas: { id: meter.id, w: WING_W } } : null,
  );
}

/** The bars' standing profile under Reduce Motion: the same meter, held. */
const STILL = [0.35, 0.6, 0.8, 0.6, 0.35];

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

// ---------------------------------------------------------------- the VU
//
// The stage instrument (G2.11 — "show the fun front and centre"): a big VU
// meter drawn as a flat-ink machine face, weatherglass style. We have no
// honest signal — tapping the stream is private-API territory — so the honest
// theatre is the INSTRUMENT: a needle with mass and damping chasing a
// programme-shaped level, that slams home when you retune and climbs back as
// the dial locks through a burst of static.

const STAGE_W = 380;
const STAGE_H = 150;
const PIVOT_X = STAGE_W / 2;
const PIVOT_Y = STAGE_H - 18;
const NEEDLE_LEN = 108;
const SWEEP = (50 * Math.PI) / 180; // half-sweep, radians
const STATIC_MS = 550; // how long a retune crackles before the lock

let stage = null; // the stage canvas node, from a ref
let needle = 0; // the needle's position, 0…1 — it has mass
let needleVel = 0;
let tunedAt = 0; // when the dial last turned; drives the static sweep

/** The programme level the needle chases: two detuned sines and a flutter —
 * music-shaped, deliberately not music. */
function programme(t) {
  const slow = Math.sin(t / 620) * Math.sin(t / 1310);
  const flutter = Math.sin(t / 97) * 0.12;
  return 0.55 + 0.28 * slow + flutter;
}

/** Deterministic speckle for the static sweep — pure in (frame, i). */
function crackle(seed) {
  const x = Math.sin(seed * 127.1) * 43758.5453;
  return x - Math.floor(x);
}

/** A point on the dial: `k` 0…1 across the sweep, at radius `r`. */
function dialPoint(k, r) {
  const angle = -Math.PI / 2 + (k * 2 - 1) * SWEEP;
  return [PIVOT_X + Math.cos(angle) * r, PIVOT_Y + Math.sin(angle) * r];
}

function stagePaint() {
  if (!ctxRef || !stage || !expanded) return;
  const still = Boolean(ctxRef.reduceMotion);
  const now = Date.now();
  const inStatic = playing && !still && now - tunedAt < STATIC_MS;
  const ops = [
    { op: "clear" },
    { op: "rect", x: 0, y: 0, w: STAGE_W, h: STAGE_H, fill: "#0B0B0Ecc", radius: 6 },
  ];

  // The dial arc, as a fine polyline — the instrument's horizon.
  const arc = [];
  for (let i = 0; i <= 24; i += 1) arc.push(dialPoint(i / 24, NEEDLE_LEN + 6));
  ops.push({ op: "line", points: arc, stroke: "#FFFFFF26", width: 1 });

  // Eleven ticks; the last three are the hot end, heavier and brighter —
  // the red zone spoken in ink.
  for (let i = 0; i <= 10; i += 1) {
    const hot = i >= 8;
    const [x1, y1] = dialPoint(i / 10, NEEDLE_LEN + 6);
    const [x2, y2] = dialPoint(i / 10, NEEDLE_LEN + 6 - (hot ? 12 : 8));
    ops.push({
      op: "line",
      points: [[x1, y1], [x2, y2]],
      stroke: playing ? (hot ? "#FFFFFFE6" : "#FFFFFF73") : "#FFFFFF30",
      width: hot ? 2.5 : 1.5,
    });
  }

  // Ballistics: the needle is a body. It kicks on transients and rings a
  // little on the way down — VU behaviour, at panel scale.
  const level = !playing ? 0 : still ? 0.62 : inStatic ? 0.15 + crackle(frame) * 0.5 : programme(now);
  if (still) {
    needle = level;
    needleVel = 0;
  } else {
    needleVel += (level - needle) * 0.35;
    needleVel *= 0.72;
    needle = Math.max(0, Math.min(1, needle + needleVel));
  }
  const [tipX, tipY] = dialPoint(needle, NEEDLE_LEN);
  const [tailX, tailY] = dialPoint(needle, -16); // the counterweight, past the pivot
  ops.push({
    op: "line",
    points: [[tailX, tailY], [tipX, tipY]],
    stroke: playing ? "#FFFFFFE6" : "#FFFFFF40",
    width: 2,
  });

  // The pivot: a stepped art-deco base and a dome.
  ops.push({ op: "rect", x: PIVOT_X - 26, y: PIVOT_Y + 8, w: 52, h: 5, radius: 2.5, fill: "#FFFFFF24" });
  ops.push({ op: "rect", x: PIVOT_X - 16, y: PIVOT_Y + 3, w: 32, h: 5, radius: 2.5, fill: "#FFFFFF33" });
  ops.push({ op: "rect", x: PIVOT_X - 6, y: PIVOT_Y - 6, w: 12, h: 12, radius: 6, fill: "#FFFFFFB8" });

  // The static sweep: the dial travelling between stations, as speckle.
  if (inStatic) {
    for (let i = 0; i < 26; i += 1) {
      ops.push({
        op: "rect",
        x: Math.floor(crackle(frame * 31 + i) * (STAGE_W - 4)) + 2,
        y: Math.floor(crackle(frame * 31 + i + 0.5) * (STAGE_H - 8)) + 4,
        w: 2, h: 2, radius: 0,
        fill: "#FFFFFF4D",
      });
    }
  }

  ctxRef.draw(stage.id, ops);
}

function tick() {
  // Stopped, the needle still has to *land*: it eases to rest with a little
  // ring (a VU is a body), and only then do the frames stop.
  const settling = !playing && (needle > 0.01 || Math.abs(needleVel) > 0.005);
  if (!playing && !settling) return;
  if (ctxRef?.reduceMotion) {
    commit(); // the heartbeat must outlive the animation (spec §4.2)
    return;
  }
  frame += 1;
  commit();
  paint();
  stagePaint();
}

let expanded = false;

export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  if (phase === "expanded") expanded = true;
  if (phase === "collapsed") expanded = false;
  paint();
  stagePaint();
}

let timer = null;

export async function monitor(ctx) {
  ctxRef = ctx;
  commit();
  paint();
  if (!timer) timer = setInterval(tick, FRAME_MS);
  if (!stations) {
    stations = await loadStations();
    if (stations && current >= stations.length) current = 0;
    commit();
  }
  // The dial refreshes hourly; an empty one retries on the next minute. The
  // meter's clock is the interval above — the monitor only owns the fetch.
  await Bun.sleep(stations ? 3_600_000 : 60_000);
}

// ---------------------------------------------------------------- the panel

export default function Radio({
  stations: list = null,
  current: tuned = 0,
  playing: live = false,
  onToggle = toggle,
  onTune = tune,
}) {
  if (!list) {
    // §09's empty state: one line, never an apology. The dial is loading or
    // the network is gone; either way the next monitor pass retries.
    return (
      <stack axis="v" pad={20} gap={8} align="center">
        <text content="tuning the dial…" size="s" color="tertiary" />
      </stack>
    );
  }

  return (
    // Tetris's alignment recipe: the outer column centres, the inner one has
    // no align — its children stretch to the widest of them (the VU's slab),
    // so the station rows line up with the instrument's edges exactly.
    <stack axis="v" pad={16} align="center">
      <stack axis="v" gap={8}>
        {/* The VU, front and centre (G2.11) — the one framed region (§09). */}
        <stack axis="v" pad={2} fill="black" stroke="hairline" radius={8}>
          <canvas
            ref={(node) => {
              stage = node;
            }}
            w={STAGE_W}
            h={STAGE_H}
          />
        </stack>

        {/* The list is the switcher (principle 5): three rows of the datum,
            the tuned one in primary ink. A row is a button in the child form —
            the whole line is the target. */}
        {list.map((station, index) => (
          <button key={index} onClick={() => onTune?.(index)}>
            <stack axis="h" gap={10} pad={6} align="center">
              <text
                content={station.name}
                size="m"
                weight={index === tuned ? "medium" : "regular"}
                color={index === tuned ? "primary" : "tertiary"}
                truncate
              />
              <spacer />
              <text content={station.country} size="xs" color="tertiary" caps />
            </stack>
          </button>
        ))}

        {/* The wing's own strip, sitting in the panel: the shell mirrors this
            node's frames into the notch — the same pixels, two places. */}
        <stack axis="h" gap={12} pad={6} align="center">
          <canvas
            ref={(node) => {
              meter = node;
            }}
            w={WING_W}
            h={WING_H}
          />
          <spacer />
          <button
            icon={live ? "sf:pause" : "sf:play"}
            variant="ghost"
            onClick={() => onToggle?.()}
          />
        </stack>
      </stack>
    </stack>
  );
}
