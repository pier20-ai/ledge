/** @jsxImportSource react */
// Radio — a car dial over a real directory (G2.13).
//
// The stage is an old-school car radio face: FM and AM rulers in cream, the
// world's most-listened stations set along the band as gold markers, and one
// red needle you DRAG — let go and it snaps to the nearest station through a
// burst of static. The dial is the switcher; there is no list. The stations
// are real: two dozen from the Radio Browser directory
// (https://api.radio-browser.info — community run, keyless), played through
// AVFoundation. Ledge itself still renders nothing but glass: the audio lives
// in one spawned `osascript` runloop the worker owns and kills.
//
// Laws it is written against: 1 (no card), 3 (ink plus exactly two working
// hues — the face's cream/gold and the needle's red, each with one job),
// 4 (the numerals and the station name are the only words, and they are the
// instrument's own), 5 (the dial IS the switcher — dragging the needle is the
// gesture, not a control invented beside it).
//
// Surfaces it exercises:
//   NO SUMMARY   declares neither <summary> nor <mini>: it is its own summary,
//                so a rested pointer opens the visit directly (principle 8).
//   WING CANVAS  a live-activity strip in the right wing while playing, drawn
//                imperatively at ~8 fps; the same node sits in the panel.
//   REDUCE MOTION the bars stand at a fixed profile (spec §4.2).
//   SETTINGS     two native controls in the Settings window: the band's length
//                (a re-cut of the stations already fetched, on the spot) and
//                whether the directory hears which one you tuned.
//
// Test seams (host/test/radio.test.ts drives the real worker):
//   LEDGE_RADIO_STATIONS  JSON station list — skips the network.
//   LEDGE_RADIO_MUTE=1    skips the audio process — state still flows.

export const meta = {
  name: "Radio",
  icon: "sf:dot.radiowaves.left.and.right",
  // Two native controls, and both are about the directory rather than the
  // sound: how many of its stations the band carries, and whether it hears
  // back from us. Volume is not here — it is the machine's, not this app's.
  settings: [
    {
      key: "dial-size",
      label: "Stations on the dial",
      type: "number",
      min: 6,
      max: 36,
      step: 6,
      default: 24,
      hint: "The band is re-cut from stations already fetched.",
    },
    {
      key: "clicks",
      label: "Report listens to the directory",
      type: "toggle",
      default: true,
      hint: "Radio Browser counts a tune-in when this is on.",
    },
  ],
};

// ---------------------------------------------------------------- the dial

/** Radio Browser mirrors, tried in order. The project asks clients to spread
 * load across mirrors and name themselves; both requests are cheap to honour. */
const MIRRORS = [
  "https://de1.api.radio-browser.info/json",
  "https://de2.api.radio-browser.info/json",
  "https://fi1.api.radio-browser.info/json",
];
const USER_AGENT = "Ledge-Radio/1.0";
/** Most-listened-to right now, not most-voted-ever: a radio app is live. The
 * over-fetch feeds the dedupe below — the directory lists the same network
 * under several relays, and a dial with "Radio Paradise" at three spots is a
 * bug, not a band plan — and it feeds the cut: the band's length is a setting,
 * and moving it must not cost a round trip. */
const TOP = "stations/topclick/40?hidebroken=true";
/** How many stations fit on the band before the markers stop being targets.
 * The user has the final say (`meta.settings`); this is what the dial carries
 * until the host has said otherwise. */
const DIAL_DEFAULT = 24;

/** The band's length, as the user set it. Read fresh: `ctx.settings` is the
 * live map, and a length captured once would be the one from before. */
function dialSize() {
  const asked = Number(ctxRef?.settings?.["dial-size"]);
  return Number.isFinite(asked) && asked > 0 ? asked : DIAL_DEFAULT;
}
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
      const seen = new Set();
      const list = [];
      for (const row of rows) {
        const name = String(row.name ?? "").trim() || "unnamed";
        if (seen.has(name.toLowerCase())) continue;
        seen.add(name.toLowerCase());
        list.push({
          uuid: row.stationuuid,
          name,
          url: row.url_resolved || row.url,
          country: String(row.countrycode ?? "").trim(),
        });
      }
      // Every station the directory gave us, uncut: the dial is sliced from
      // this list, so a longer band is already paid for.
      return list;
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
 * forget — a click count is not worth a spinner, or an error. The user can
 * decline the courtesy (`clicks`), which is the whole reason it is a setting:
 * it is the one thing this app tells anybody about what you listen to. */
function registerClick(station) {
  if (ctxRef?.settings?.clicks === false) return;
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
let fetched = null; // every station the directory gave us, deduped
let stations = null; // …and the cut of them the band carries; null until loaded
let current = 0;
let playing = false;
let frame = 0;

// ---------------------------------------------------------------- actions

/** Cut the band out of what was fetched. The fetch is the expensive half and
 * it is over-sized on purpose, so a different band length is a different
 * slice of what is already here — never another round trip. */
function cutDial() {
  const tuned = stations?.[current] ?? null;
  stations = fetched ? fetched.slice(0, dialSize()) : null;
  if (stations && current >= stations.length) current = Math.max(0, stations.length - 1);
  // A shorter band can push the station that is playing off its end. The
  // needle lands on the nearest one that survived and the sound goes with it:
  // a dial showing one station while another plays is a broken dial.
  if (playing && tuned && stations?.[current] && stations[current] !== tuned) {
    stopAudio();
    tunedAt = Date.now();
    startAudio(stations[current]);
  }
}

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
  stagePaint();
}

/** Land the needle on a station: that station plays. Radio has no "selected
 * but silent" — turning the dial is the whole gesture. */
function tune(index) {
  if (!stations?.[index]) return;
  if (index === current && playing) return;
  current = index;
  stopAudio();
  playing = true;
  tunedAt = Date.now(); // the static sweep: the dial audibly *travels*
  startAudio(stations[current]);
  commit();
  paint();
  stagePaint();
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

// ---------------------------------------------------------------- the dial
//
// The stage instrument (G2.13 — "the old-school car FM/AM radio interface"):
// a horizontal band with an FM ruler above and an AM ruler below, both in
// cream numerals, the stations set between them as gold markers, and one red
// needle spanning the face. The needle is the whole interface: DRAG it — it
// follows the finger dead (no spring against a hand) — and on release it
// snaps to the nearest marker and that station plays, through the static
// burst of the dial travelling. Weatherglass discipline: the numerals are
// theatre (the directory has no frequencies), the markers and the name below
// are data.

const STAGE_W = 380;
const STAGE_H = 150;
const BAND_X = 30; // where the scale starts
const BAND_W = STAGE_W - BAND_X * 2;
const FM_Y = 52; // the FM ruler's line
const AM_Y = 106; // the AM ruler's line
const MARK_Y = (FM_Y + AM_Y) / 2; // the stations, on the band between them
const NEEDLE_TOP = 28;
const NEEDLE_BOT = 130;
const STATIC_MS = 550; // how long a retune crackles before the lock

// The face's palette: weather's deco creams and golds as the machine, and the
// needle in the one red — a car dial's needle has been red since Bakelite.
const INK_SCALE = "#E8E2D0B8"; // cream numerals
const INK_RULE = "#FFFFFF2E";
const INK_TICK = "#FFFFFF55";
const INK_MARK = "#C9A86ACC"; // gold station markers
const INK_NEEDLE = "#E8402AE6";

const FM_NUMBERS = [88, 92, 96, 100, 104, 108];
const AM_NUMBERS = [55, 70, 90, 110, 140, 160];

let stage = null; // the stage canvas node, from a ref
let dial = 0; // the needle, 0…1 across the band — it has mass
let dialVel = 0;
let dragPos = null; // the finger's own position while it holds the needle
let tunedAt = 0; // when the dial last landed; drives the static sweep

/** Deterministic speckle for the static sweep — pure in (frame, i). */
function crackle(seed) {
  const x = Math.sin(seed * 127.1) * 43758.5453;
  return x - Math.floor(x);
}

/** Where station `i` sits on the band, 0…1 — evenly set, ends included. */
function stationK(i) {
  const n = stations?.length ?? 0;
  return n > 1 ? i / (n - 1) : 0.5;
}

/** Advance the needle toward where it belongs; true while it is still moving.
 * A held needle does not move itself — the finger owns it. */
function dialStep() {
  if (dragPos !== null) return true;
  const wanted = stationK(current);
  if (ctxRef?.reduceMotion) {
    const moved = Math.abs(dial - wanted) > 0.0005;
    dial = wanted;
    dialVel = 0;
    return moved;
  }
  dialVel += (wanted - dial) * 0.16;
  dialVel *= 0.7;
  dial += dialVel;
  return Math.abs(wanted - dial) > 0.0005 || Math.abs(dialVel) > 0.0005;
}

/** The needle, dragged (§4.1 `drag`). Down and move: the needle rides the
 * finger. Up: snap to the nearest station and tune it — releasing the knob IS
 * the click. A drag that lets go where it started just re-seats the needle. */
function turnDial({ phase, x }) {
  if (!stations || stations.length === 0) return;
  const k = Math.max(0, Math.min(1, (x - BAND_X) / BAND_W));
  if (phase !== "up") {
    dragPos = k;
    dial = k;
    dialVel = 0;
    stagePaint();
    return;
  }
  dragPos = null;
  tune(Math.round(k * (stations.length - 1)));
  stagePaint(); // a same-station release still needs the highlight back
}

function stagePaint() {
  if (!ctxRef || !stage || !expanded) return;
  const still = Boolean(ctxRef.reduceMotion);
  const now = Date.now();
  const inStatic = playing && !still && now - tunedAt < STATIC_MS;
  const lit = playing || dragPos !== null; // a held dial wakes the face
  const ops = [
    { op: "clear" },
    { op: "rect", x: 0, y: 0, w: STAGE_W, h: STAGE_H, fill: "#0B0B0Ecc", radius: 6 },
  ];

  // Stepped deco columns at either end — the band's pediments.
  for (const capX of [11, STAGE_W - 11]) {
    ops.push({ op: "rect", x: capX - 1.5, y: 40, w: 3, h: 74, radius: 1.5, fill: "#FFFFFF24" });
    ops.push({ op: "rect", x: capX + (capX < STAGE_W / 2 ? 5 : -7), y: 50, w: 2, h: 54, radius: 1, fill: "#FFFFFF14" });
  }

  // The rulers: FM reads above its line, AM below, ticks reaching into the
  // band from both — the classic two-row face.
  ops.push({ op: "text", content: "FM", x: 9, y: FM_Y - 6, size: 9, color: lit ? INK_SCALE : "#FFFFFF3D" });
  ops.push({ op: "text", content: "AM", x: 9, y: AM_Y - 6, size: 9, color: lit ? INK_SCALE : "#FFFFFF3D" });
  ops.push({ op: "line", points: [[BAND_X, FM_Y], [BAND_X + BAND_W, FM_Y]], stroke: INK_RULE, width: 1 });
  ops.push({ op: "line", points: [[BAND_X, AM_Y], [BAND_X + BAND_W, AM_Y]], stroke: INK_RULE, width: 1 });
  for (let i = 0; i <= 20; i += 1) {
    const x = BAND_X + (i / 20) * BAND_W;
    const major = i % 4 === 0;
    ops.push({ op: "line", points: [[x, FM_Y], [x, FM_Y + (major ? 8 : 4)]], stroke: major ? INK_TICK : INK_RULE, width: 1 });
    ops.push({ op: "line", points: [[x, AM_Y], [x, AM_Y - (major ? 8 : 4)]], stroke: major ? INK_TICK : INK_RULE, width: 1 });
  }
  FM_NUMBERS.forEach((n, j) => {
    const label = String(n);
    ops.push({
      op: "text", content: label,
      x: BAND_X + (j / (FM_NUMBERS.length - 1)) * BAND_W - label.length * 2.7,
      y: FM_Y - 17, size: 9,
      color: lit ? INK_SCALE : "#FFFFFF3D",
    });
  });
  AM_NUMBERS.forEach((n, j) => {
    const label = String(n);
    ops.push({
      op: "text", content: label,
      x: BAND_X + (j / (AM_NUMBERS.length - 1)) * BAND_W - label.length * 2.7,
      y: AM_Y + 7, size: 9,
      color: lit ? INK_SCALE : "#FFFFFF3D",
    });
  });

  // The stations, as gold markers between the rulers. The tuned one — or,
  // under a finger, the one the needle would land on — wears a halo.
  const landing = dragPos !== null ? Math.round(dragPos * (stations.length - 1)) : current;
  stations?.forEach((_, i) => {
    const x = BAND_X + stationK(i) * BAND_W;
    if (i === landing) {
      ops.push({ op: "rect", x: x - 5, y: MARK_Y - 5, w: 10, h: 10, radius: 5, fill: "#C9A86A3D" });
      ops.push({ op: "rect", x: x - 2, y: MARK_Y - 2, w: 4, h: 4, radius: 2, fill: "#E8E2D0E6" });
    } else {
      ops.push({ op: "rect", x: x - 1.5, y: MARK_Y - 1.5, w: 3, h: 3, radius: 1.5, fill: lit ? INK_MARK : "#C9A86A66" });
    }
  });

  // The red needle, spanning the whole face, with a bead at each end — the
  // one hot accent, and the one thing on the face you can hold.
  const needleX = BAND_X + dial * BAND_W;
  ops.push({ op: "line", points: [[needleX, NEEDLE_TOP], [needleX, NEEDLE_BOT]], stroke: INK_NEEDLE, width: 2.5 });
  ops.push({ op: "rect", x: needleX - 4, y: NEEDLE_TOP - 5, w: 8, h: 6, radius: 3, fill: "#E8402AB8" });
  ops.push({ op: "rect", x: needleX - 4, y: NEEDLE_BOT - 1, w: 8, h: 6, radius: 3, fill: "#E8402AB8" });

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
  // Stopped, the needle still has to *land*: it glides to the tuned marker
  // and only then do the frames stop.
  const moving = dialStep();
  if (!playing && !moving) return;
  if (ctxRef?.reduceMotion) {
    commit(); // the heartbeat must outlive the animation (spec §4.2)
    stagePaint();
    return;
  }
  frame += 1;
  commit();
  paint();
  if (moving || dragPos !== null || (playing && Date.now() - tunedAt < STATIC_MS + 200)) stagePaint();
}

let expanded = false;

export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  if (phase === "expanded") expanded = true;
  if (phase === "collapsed") expanded = false;
  paint();
  stagePaint();
}

/** The user moved one of this app's controls (spec §5). `dial-size` is the one
 * that shows: the band is re-cut from the stations already in hand and the
 * face redrawn, with no fetch and no interruption to what is playing. */
export function onEvent(name, values, ctx) {
  ctxRef = ctxRef ?? ctx;
  if (name !== "settings") return;
  cutDial();
  commit();
  stagePaint();
}

let timer = null;

export async function monitor(ctx) {
  ctxRef = ctx;
  commit();
  paint();
  if (!timer) timer = setInterval(tick, FRAME_MS);
  if (!fetched) {
    fetched = await loadStations();
    cutDial();
    commit();
  }
  // The dial refreshes hourly; an empty one retries on the next minute. The
  // meter's clock is the interval above — the monitor only owns the fetch.
  await Bun.sleep(fetched ? 3_600_000 : 60_000);
}

// ---------------------------------------------------------------- the panel

export default function Radio({
  stations: list = null,
  current: tuned = 0,
  playing: live = false,
  onToggle = toggle,
  onDial = turnDial,
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
    // no align — its children stretch to the widest of them (the dial's slab),
    // so the rows below line up with the instrument's edges exactly.
    <stack axis="v" pad={16} align="center">
      <stack axis="v" gap={8}>
        {/* The dial, front and centre — the one framed region (§09). `onDrag`
            and nothing else: the needle is the switcher (principle 5). */}
        <stack axis="v" pad={2} fill="black" stroke="hairline" radius={8}>
          <canvas
            ref={(node) => {
              stage = node;
            }}
            w={STAGE_W}
            h={STAGE_H}
            onDrag={onDial}
          />
        </stack>

        {/* Below the face: what the needle is on. The name is the datum — the
            dial's numerals are only the machine. */}
        <stack axis="h" gap={10} pad={6} align="center">
          <text
            content={list[tuned]?.name ?? ""}
            size="l"
            weight="medium"
            color={live ? "primary" : "secondary"}
            truncate
          />
          <spacer />
          <text content={list[tuned]?.country ?? ""} size="xs" color="tertiary" caps />
        </stack>

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
