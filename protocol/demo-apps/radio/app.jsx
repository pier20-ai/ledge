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

function tick() {
  if (!playing) return; // stopped is a still frame, not a slower one
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
