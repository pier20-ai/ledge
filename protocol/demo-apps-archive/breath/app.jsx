/** @jsxImportSource react */
// Breath — pranayama on the weatherglass doctrine (G2.10, Manu's ratified
// proposal): simulate a SUBSTANCE, not a status. There is no ring, no bar, no
// countdown. There is a pane of night glass, and your breath on it:
//
//   exhale  → condensation blooms up the pane (warm breath on cold glass)
//   hold    → the fog hangs, and beads form along its edge; a long hold
//             sends one run sliding down, clearing a track
//   inhale  → the fog retreats
//
// Where you are in the cycle is simply how fogged the pane is — a pacer with
// zero words of chrome. Nadi Shodhana blooms one HALF of the pane per nostril.
// One quiet word under the pane ("in" / "hold" / "out") is the only text, and
// it is data.
//
// Laws: 1 (one well, one word, two controls) · 3 (ink and glass; no hue) ·
// 5 (the fog IS the datum) · 10 (Reduce Motion: the fog *steps* to each
// phase's end level — still, not slower) · 12 (the pane is the identity).
//
// The frame is a pure function of (t, pattern): each phase is annotated at
// select time with its start/end fog level per half, so a frame at any t is
// computed, never accumulated — the weather app's discipline, kept.
//
// Surfaces: WING (width) — while a session runs, the collapsed notch itself
// breathes: a pure-shape wing whose width follows the fog (the "breathing
// pacer" case the shell's wing law was written for). Under Reduce Motion the
// wing is the phase word instead. NO SUMMARY, NO MINI.
//
// Pattern glyphs: monochrome sprites named `glyph-<id>.png` beside this file
// are used when present (Manu supplies them); SF Symbols stand in until then.

export const meta = { name: "Breath", icon: "sf:wind" };

// ---------------------------------------------------------------- patterns

const LO = 0.06; // the glass is never bone dry mid-session
const HI = 0.78;

const PATTERNS = [
  {
    id: "box",
    name: "box",
    sf: "sf:square",
    phases: [
      { kind: "in", s: 4 },
      { kind: "hold", s: 4 },
      { kind: "out", s: 4 },
      { kind: "hold", s: 4 },
    ],
  },
  {
    id: "478",
    name: "4 · 7 · 8",
    sf: "sf:moon.zzz",
    phases: [
      { kind: "in", s: 4 },
      { kind: "hold", s: 7 },
      { kind: "out", s: 8 },
    ],
  },
  {
    id: "nadi",
    name: "nadi shodhana",
    sf: "sf:nose",
    phases: [
      { kind: "in", s: 4, side: "L" },
      { kind: "hold", s: 4 },
      { kind: "out", s: 4, side: "R" },
      { kind: "in", s: 4, side: "R" },
      { kind: "hold", s: 4 },
      { kind: "out", s: 4, side: "L" },
    ],
  },
];

/** Walk a pattern once, stamping each phase with its start and end fog level
 * per half — after this, the level at any t is a lerp, and the frame is pure.
 * (Every pattern here ends where it begins, so the cycle wraps seamlessly;
 * that is a property of the tables above worth keeping when adding one.) */
function annotate(pattern) {
  let level = { L: LO, R: LO };
  for (const phase of pattern.phases) {
    phase.from = { ...level };
    const sides = phase.side ? [phase.side] : ["L", "R"];
    if (phase.kind === "out") for (const s of sides) level[s] = HI;
    if (phase.kind === "in") for (const s of sides) level[s] = LO;
    phase.to = { ...level };
  }
  pattern.total = pattern.phases.reduce((sum, p) => sum + p.s, 0);
  return pattern;
}
PATTERNS.forEach(annotate);

const smooth = (k) => k * k * (3 - 2 * k);
const WORDS = { in: "in", hold: "hold", out: "out" };

/** The phase under `elapsed` seconds, with 0…1 progress inside it. */
function phaseAt(pattern, elapsed) {
  let t = elapsed % pattern.total;
  for (const phase of pattern.phases) {
    if (t < phase.s) return { phase, p: t / phase.s };
    t -= phase.s;
  }
  return { phase: pattern.phases[0], p: 0 };
}

/** Fog level for one half at `elapsed` — pure. */
function levelAt(pattern, elapsed, side) {
  const { phase, p } = phaseAt(pattern, elapsed);
  return phase.from[side] + (phase.to[side] - phase.from[side]) * smooth(p);
}

// ---------------------------------------------------------------- state

const PANE_W = 396;
const PANE_H = 240;
const FRAME_MS = 90; // ~11 fps, the weather pane's cadence
const WING_HEARTBEAT_MS = 45_000;

let ctxRef = null;
let pane = null; // the canvas node, from a ref
let pattern = PATTERNS[0];
let running = false;
let startedAt = 0; // Date.now() at session start
let expanded = false;
let glyphs = null; // { id: absolute sprite path } for the ones that exist

const elapsedNow = () => (running ? (Date.now() - startedAt) / 1000 : 0);

// ---------------------------------------------------------------- actions

function toggleRun() {
  running = !running;
  if (running) startedAt = Date.now();
  commit();
  draw();
}

function select(id) {
  const next = PATTERNS.find((p) => p.id === id);
  if (!next || next === pattern) return;
  pattern = next;
  // Mid-session the cycle restarts clean: a pattern is a rhythm, and joining
  // a new rhythm mid-bar is not a feature.
  if (running) startedAt = Date.now();
  commit();
  draw();
}

// ---------------------------------------------------------------- the pane

/** Deterministic bead field: fixed fractional positions, so every frame at
 * the same t draws the same droplets (pure, and Reduce-Motion friendly). */
const BEADS = [
  [0.08, 0.13], [0.19, 0.05], [0.27, 0.3], [0.36, 0.11], [0.45, 0.22],
  [0.57, 0.07], [0.66, 0.27], [0.74, 0.15], [0.83, 0.04], [0.92, 0.2],
];

function circle(ops, x, y, d, fill) {
  ops.push({ op: "rect", x: x - d / 2, y: y - d / 2, w: d, h: d, radius: d / 2, fill });
}

/** One half's fog: the bloom band, its soft edge, beads on holds, and — deep
 * into a full hold — one run clearing a track. Pure in (t, level, phase). */
function pushFog(ops, x0, w, level, hold, holdP) {
  if (level <= 0.01) return;
  const top = PANE_H - level * (PANE_H - 26);
  // The soft leading edge, then the body of the bloom — denser toward the
  // bottom edge where the breath lands.
  ops.push({ op: "gradient", x: x0, y: top - 34, w, h: 34, from: "#FFFFFF00", to: "#FFFFFF26" });
  ops.push({ op: "gradient", x: x0, y: top, w, h: PANE_H - top, from: "#FFFFFF26", to: "#FFFFFF3A" });

  // Beads form along the edge while the fog hangs, each at its own moment.
  if (hold && level > 0.3) {
    const grown = Math.floor(holdP * BEADS.length + 0.0001);
    for (let i = 0; i < grown; i += 1) {
      const [fx, fy] = BEADS[i];
      const x = x0 + fx * w;
      const y = top + 6 + fy * 26;
      const d = 3 + (i % 3);
      circle(ops, x, y, d, "#FFFFFF3D");
      circle(ops, x - d * 0.15, y - d * 0.2, 1.2, "#FFFFFF66");
    }
    // A long hold sends one bead running: a cleared track down the fog.
    if (holdP > 0.65) {
      const runP = (holdP - 0.65) / 0.35;
      const x = x0 + 0.62 * w;
      const length = runP * (PANE_H - top - 20);
      ops.push({
        op: "line",
        points: [[x, top + 8], [x, top + 8 + length]],
        stroke: "#0A0E1466",
        width: 3,
      });
      circle(ops, x, top + 8 + length, 4.5, "#FFFFFF52");
    }
  }
}

/** The whole frame — pure in (pattern, elapsed, still). */
function frame(elapsed, still) {
  const ops = [{ op: "clear" }];
  // Night glass, and a moon for the fog to mean something against.
  ops.push({ op: "gradient", x: 0, y: 0, w: PANE_W, h: PANE_H, from: "#0A0E14", to: "#111826" });
  circle(ops, PANE_W - 74, 52, 44, "#F5EFDC14");
  circle(ops, PANE_W - 74, 52, 30, "#F5EFDC2E");
  circle(ops, PANE_W - 74, 52, 22, "#F5EFDCB8");

  const { phase, p } = phaseAt(pattern, elapsed);
  const hold = phase.kind === "hold";
  // Reduce Motion: the fog stands at the phase's END level — it steps at each
  // boundary instead of sliding, and the beads stand finished.
  const at = (side) =>
    still ? phase.to[side] : levelAt(pattern, elapsed, side);
  const holdP = still ? 1 : p;

  if (running || still) {
    const left = at("L");
    const right = at("R");
    if (Math.abs(left - right) < 0.005) {
      pushFog(ops, 0, PANE_W, left, hold, holdP);
    } else {
      pushFog(ops, 0, PANE_W / 2, left, hold, holdP);
      pushFog(ops, PANE_W / 2, PANE_W / 2, right, hold, holdP);
    }
  } else {
    // At rest the glass keeps a whisper of fog along the sill — a pane that
    // has been breathed on before, waiting.
    ops.push({
      op: "gradient",
      x: 0, y: PANE_H - 30, w: PANE_W, h: 30,
      from: "#FFFFFF00", to: "#FFFFFF1A",
    });
  }
  return ops;
}

function draw() {
  if (!ctxRef || !pane || !expanded) return;
  ctxRef.draw(pane.id, frame(elapsedNow(), Boolean(ctxRef.reduceMotion) && running));
}

// ---------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";
let wingSentAt = 0;

const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

function commit() {
  if (!ctxRef) return;
  const { phase } = phaseAt(pattern, elapsedNow());
  const props = {
    pattern: pattern.id,
    running,
    word: running ? WORDS[phase.kind] : "",
    elapsed: running ? clock(elapsedNow()) : "",
    glyphs,
  };
  const signature = JSON.stringify(props);
  if (signature !== lastProps) {
    lastProps = signature;
    ctxRef.update(props);
  }

  // The wing: while a session runs, the notch itself breathes — a pure-shape
  // width request following the fog. Under Reduce Motion the word stands in
  // for the motion. Heartbeat, or the idle reclaim takes it mid-session.
  let spec = null;
  if (running) {
    if (ctxRef.reduceMotion) {
      spec = { text: WORDS[phase.kind] };
    } else {
      const fog = Math.max(levelAt(pattern, elapsedNow(), "L"), levelAt(pattern, elapsedNow(), "R"));
      // Quantised so the wire sees a few widths per breath, not one per frame.
      spec = { width: 224 + Math.round((fog * 56) / 4) * 4 };
    }
  }
  const wanted = JSON.stringify(spec);
  const stale = spec !== null && Date.now() - wingSentAt > WING_HEARTBEAT_MS;
  if (wanted === lastWing && !stale) return;
  lastWing = wanted;
  wingSentAt = Date.now();
  ctxRef.wing(spec);
}

function tick() {
  if (!running) return;
  commit();
  draw();
}

export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  if (phase === "expanded") expanded = true;
  if (phase === "collapsed") expanded = false;
  // The session does not pause with the panel: collapsed is when the wing IS
  // the app. Only the pane's frames stop.
  draw();
}

export async function monitor(ctx) {
  ctxRef = ctx;
  if (glyphs === null) {
    // Manu's sprites, when they land beside this file; SF Symbols until then.
    const found = {};
    for (const p of PATTERNS) {
      const url = new URL(`./glyph-${p.id}.png`, import.meta.url);
      found[p.id] = (await Bun.file(url).exists()) ? url.pathname : null;
    }
    glyphs = found;
  }
  expanded = true; // first present arrives with the mount; corrected by lifecycle
  commit();
  draw();
  setInterval(tick, FRAME_MS);
  await new Promise(() => {});
}

// ---------------------------------------------------------------- the panel

export default function Breath({
  pattern: tuned = "box",
  running: live = false,
  word = "",
  elapsed = "",
  glyphs: sprites = null,
  onSelect = select,
  onToggle = toggleRun,
}) {
  const current = PATTERNS.find((p) => p.id === tuned) ?? PATTERNS[0];
  return (
    <stack axis="v" pad={16} gap={10} align="center">
      {/* The pane — the one framed region for drawn content (§09). */}
      <stack axis="v" pad={2} fill="black" stroke="hairline" radius={8}>
        <canvas
          ref={(node) => {
            pane = node;
          }}
          w={PANE_W}
          h={PANE_H}
        />
      </stack>

      {/* One quiet word: where the breath is. Data, not chrome. */}
      <text content={live ? word : current.name} size="xs" color="tertiary" caps />

      <stack axis="h" gap={18} align="center">
        {/* The patterns, as glyphs (sprites when Manu ships them). */}
        {PATTERNS.map((p) => (
          <button key={p.id} variant="ghost" onClick={() => onSelect?.(p.id)}>
            <image src={sprites?.[p.id] ?? p.sf} w={20} h={20} />
          </button>
        ))}
        <spacer />
        {elapsed ? <text content={elapsed} size="s" color="tertiary" /> : null}
        <button
          icon={live ? "sf:pause" : "sf:play"}
          variant="ghost"
          onClick={() => onToggle?.()}
        />
      </stack>
    </stack>
  );
}
