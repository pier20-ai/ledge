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
//                imperatively at ~11 fps; the same node sits in the panel.
//                Since G2.10 it is a VU needle with ballistics — see "the VU".
//   REDUCE MOTION the needle stands at a fixed deflection (spec §4.2).
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

const FRAME_MS = 90; // ~11 fps: a needle with ballistics needs the frames
const WING_HEARTBEAT_MS = 45_000; // re-claim before the shell's Ta reclaim

const WING_W = 44;
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

// ---------------------------------------------------------------- the VU
//
// The fun pass (G2.10, the weatherglass doctrine): the meter is a **VU
// needle with real ballistics**, not a bar chart. We have no honest signal —
// tapping the stream is private-API territory — so the honest theatre is the
// *instrument*: a needle with mass and damping chasing a programme-shaped
// level, that slams home when you retune and climbs back as the dial locks
// through a burst of static.

const STATIC_MS = 550; // how long a retune crackles before the lock

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

/** Deterministic speckle for the static sweep — pure in (frame). */
function crackle(seed) {
  const x = Math.sin(seed * 127.1) * 43758.5453;
  return x - Math.floor(x);
}

/** Needle geometry: pivot at the bottom centre, sweeping −54°…+54°. */
const PIVOT_X = WING_W / 2;
const PIVOT_Y = WING_H - 4;
const NEEDLE_LEN = 24;
const SWEEP = (54 * Math.PI) / 180;

function needleTip(position) {
  const angle = -Math.PI / 2 + (position * 2 - 1) * SWEEP;
  return [PIVOT_X + Math.cos(angle) * NEEDLE_LEN, PIVOT_Y + Math.sin(angle) * NEEDLE_LEN];
}

function paint() {
  if (!ctxRef || !meter) return;
  const still = Boolean(ctxRef.reduceMotion);
  const now = Date.now();
  const inStatic = playing && !still && now - tunedAt < STATIC_MS;
  const ops = [{ op: "clear" }];

  // The scale: five tick dots along the arc. The instrument is always there;
  // only the needle's life changes with the state.
  for (let i = 0; i < 5; i += 1) {
    const [tx, ty] = needleTip(i / 4);
    const d = i === 4 ? 2.5 : 2;
    ops.push({
      op: "rect",
      x: tx - d / 2, y: ty - d / 2, w: d, h: d, radius: d / 2,
      fill: playing ? (i === 4 ? "#FFFFFFE0" : "#FFFFFF66") : "#FFFFFF2E",
    });
  }

  // Ballistics: the needle is a body. Spring toward the level, damped, so it
  // kicks on transients and rings a little on the way down — VU behaviour.
  const level = !playing ? 0 : still ? 0.62 : inStatic ? 0.15 + crackle(frame) * 0.5 : programme(now);
  if (still) {
    needle = level;
    needleVel = 0;
  } else {
    needleVel += (level - needle) * 0.35;
    needleVel *= 0.72;
    needle = Math.max(0, Math.min(1, needle + needleVel));
  }
  const [tipX, tipY] = needleTip(needle);
  ops.push({
    op: "line",
    points: [[PIVOT_X, PIVOT_Y], [tipX, tipY]],
    stroke: playing ? "#FFFFFFD9" : "#FFFFFF40",
    width: 1.5,
  });
  ops.push({
    op: "rect",
    x: PIVOT_X - 2, y: PIVOT_Y - 2, w: 4, h: 4, radius: 2,
    fill: playing ? "#FFFFFFCC" : "#FFFFFF40",
  });

  // The static sweep: the dial travelling between stations, as speckle.
  if (inStatic) {
    for (let i = 0; i < 9; i += 1) {
      const r1 = crackle(frame * 9 + i);
      const r2 = crackle(frame * 9 + i + 0.5);
      ops.push({
        op: "rect",
        x: Math.floor(r1 * (WING_W - 2)),
        y: Math.floor(r2 * (WING_H - 10)) + 2,
        w: 1.5, h: 1.5, radius: 0,
        fill: "#FFFFFF59",
      });
    }
  }

  ctxRef.draw(meter.id, ops);
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
}

export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  paint();
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
    <stack axis="v" pad={16} gap={2}>
      {/* The list is the switcher (principle 5): three rows of the datum, the
          tuned one in primary ink. A row is a button in the child form — the
          whole line is the target. */}
      {list.map((station, index) => (
        <button key={index} onClick={() => onTune?.(index)}>
          <stack axis="h" gap={10} pad={8} align="center">
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
      <stack axis="h" gap={12} pad={8} align="center">
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
  );
}
