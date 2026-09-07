/** @jsxImportSource react */
// Blocks — the well, and one number.
//
// SIGNATURE: the bare score. Principle 5's own worked example is this app —
// "a score is a number, not a labeled box around a number" — and the archive
// was the box: three `SCORE` / `LINES` / `LEVEL` cards, each a labelled,
// stroked, filled slab wrapped around a numeral, plus a fourth for the B2B
// chain. They are gone. What is left is a 36 pt tabular numeral sitting
// directly on the glass, the level as four quiet characters beside it, and one
// ghost. The well is the identity (law 12); the numeral is the datum (law 5).
//
// Laws: 1 (one ghost, one hairline slab, nothing filled) · 2 (the shell names
// the app; this app owns a well, a number and one control) · 3 (ink at rest —
// the tetromino colours are *content*, inside the well, and no hue escapes it) ·
// 4 (the key legend is gone: a game teaches its own arrow keys, and a sentence
// under a well is a design failure) · 5 (see above) · 12 (the well).
//
// Diet, against protocol/demo-apps-archive/blocks:
//   CUT   the left wing (a dot and the phase word) · the `NEXT` card and its
//         second framed canvas · the SCORE / LINES / LEVEL stat boxes · the
//         B2B / combo box · the labelled Start/Pause/Resume button · the
//         "↑ rotate  space drop  p pause" legend · the whole side column.
//   KEPT  the game loop, the 7-bag, the kick table, the guideline scoring
//         (back-to-back and combo still pay, they just no longer have a box) —
//         all verbatim. The loop was never the problem.
//   NEW   the next piece is drawn *inside* the well, top-right, at half scale
//         and half alpha. §09 allows one framed region for drawn content, so
//         the preview stops being a second well and becomes what it always
//         was: content. And a `<summary>`, so a hover reads the game instead
//         of opening it.
//
// Surfaces:
//   SUMMARY  "12,480 · lv 6" / "paused" / "ready". Declaring it makes the
//            session heavy, which is the right answer for a game: resting the
//            pointer on the notch should tell you the score, not drop you into
//            a live well you did not mean to be responsible for.
//   WING     none. A game you are not looking at is a game you are losing.
//   MINI     none. Blocks never interrupts.
//   REDUCE MOTION  audited, and there is nothing to switch off. Every moving
//            pixel here is the user's own input or the gravity they started —
//            REFERENCE.md's rule is about *decoration*, and this app has none:
//            no pulse on a line clear, no flash on a four-line clear, no shake, no
//            animated banner. The one thing that was ambient — the archive's
//            wing — is cut. So `ctx.reduceMotion` is deliberately unread, and
//            the honest fix if a clear ever gets a flash is to gate the flash,
//            not the fall.
//   SF SYMBOLS  the ghost swaps ▶ / ‖ on every state change and updates in
//            place: a `<button icon>` goes through `button.apply(symbol:)`.
//            An `<image src="sf:…">` does too since G3 (`LedgeSymbolView`
//            gained the same partial-update entry point). No React `key`
//            workaround is needed for a glyph swap anywhere — do not add one.
//
// The loop is an ordinary worker `setInterval` — the platform's, not Ledge's
// (nothing the platform already does gets wrapped). It ticks at 120 ms and
// gravity drops the piece every N ticks, N falling with the level. A frame is
// pushed only when something moved, so a paused or finished game costs the
// socket nothing at all, and the interval is not even running. Collapsing the
// panel pauses the game outright (`onLifecycle`).
//
// Scoring is the guideline-style table most modern falling-block games share
// — see the Scoring section below for the exact mapping and the one row this
// game deliberately cannot implement.
//
// The piece palette is deliberately *not* the canonical one (cyan I, yellow O,
// purple T, and so on). The seven shapes are public domain; the shapes together
// with that exact colour set are the trade dress of a very litigious company.
// So every piece here wears a hue its canonical self never does. Do not "fix"
// it back.

export const meta = {
  name: "Blocks",
  icon: "sf:square.grid.3x3.fill",
  // The well wants 368: 336 pt of canvas (14 columns since G2.9 — Manu asked
  // for two more each side of the guideline ten; the panel was reading narrow
  // on device) + the slab's 2 pt inset each side + the root's 14 pt padding.
  panel: { width: 368, maxHeight: 640 },
};

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

// 14, not the guideline's 10: G2.9 widened the playfield by two columns each
// side. Everything else — spawns, preview, centring — derives from this.
const COLS = 14;
const ROWS = 20;
const CELL = 24;
const WELL_W = COLS * CELL; // 336
const WELL_H = ROWS * CELL; // 480
const TICK_MS = 120;

/** The in-well preview: half a cell, half alpha, hugging the top-right corner.
 * Pieces spawn centred (columns 5–8 on the 14-wide well), so it never sits
 * under a falling piece; the only thing it can ever overlap is a stack that
 * has already reached row 0, at which point the game is over anyway. */
const PREVIEW_CELL = CELL / 2;
const PREVIEW_INSET = 8;
const PREVIEW_ALPHA = "8C"; // ~55%

// Cells for rotation 0, inside a box of `n` × `n`; rotation is the usual
// (x, y) → (n − 1 − y, x) quarter turn, which is why O lives in a 2-box (it
// must rotate to itself) and I in a 4-box.
const PIECES = {
  I: { box: 4, color: "#E2E8F0", cells: [[0, 1], [1, 1], [2, 1], [3, 1]] },
  O: { box: 2, color: "#2DD4BF", cells: [[0, 0], [1, 0], [0, 1], [1, 1]] },
  T: { box: 3, color: "#FBBF24", cells: [[1, 0], [0, 1], [1, 1], [2, 1]] },
  S: { box: 3, color: "#818CF8", cells: [[1, 0], [2, 0], [0, 1], [1, 1]] },
  Z: { box: 3, color: "#A3E635", cells: [[0, 0], [1, 0], [1, 1], [2, 1]] },
  J: { box: 3, color: "#F87171", cells: [[0, 0], [0, 1], [1, 1], [2, 1]] },
  L: { box: 3, color: "#38BDF8", cells: [[2, 0], [0, 1], [1, 1], [2, 1]] },
};

const KINDS = Object.keys(PIECES);

// ---------------------------------------------------------------------------
// Scoring — the guideline-style table most modern falling-block games share.
// The whole table:
//
//   Single                 100 × level
//   Double                 300 × level
//   Triple                 500 × level
//   Four                   800 × level          (a "difficult" clear)
//   Back-to-back difficult action score × 1.5   (excluding soft/hard drop)
//   Combo                  50 × combo count × level
//   Soft drop              1 per cell
//   Hard drop              2 per cell
//
// Three consequences worth spelling out, because each one is a place the old
// code was wrong or a place it is easy to get wrong again:
//
//  * "Level is always considered to be the level before the line clear", and
//    guideline levels start at **1** — so `level` here is 1-based and a clear
//    is paid at the level that was showing when the piece locked, not the one
//    the clear promotes you to.
//  * The two drops are flat: no level multiplier, no back-to-back bonus. The
//    table says so explicitly ("excluding soft drop and hard drop").
//  * Only a Single/Double/Triple breaks the back-to-back chain. A piece that
//    clears nothing ends a *combo* but leaves the chain intact.
//
// The rest of the table is T-spins, and this game has no honest way to score
// them: recognising a T-spin is a property of the *rotation system* (the
// 3-corner rule, applied to an SRS kick that ended in a T slot), and `tryRotate`
// below is a plain quarter turn with horizontal nudges. Bolting on a corner
// count would award T-spins for rotations that are not T-spins, which is worse
// than not having them. So: no T-spins, and `cleared === 4` is the only
// "difficult" action here.
//
// The chain and the combo lost their box in D4, not their effect: they are two
// multipliers on a number the panel already shows, and a number is the honest
// display of a number (principle 5). If you want to know whether the chain is
// live, clear four rows and watch the score jump by half again.
const CLEAR_POINTS = [0, 100, 300, 500, 800]; // index = lines cleared at once
const B2B_MULTIPLIER = 1.5;
const COMBO_POINTS = 50;
const SOFT_DROP_POINTS = 1; // per cell actually descended
const HARD_DROP_POINTS = 2; // per cell

function rotated(kind, rotation) {
  const { box, cells } = PIECES[kind];
  let out = cells;
  for (let turn = 0; turn < ((rotation % 4) + 4) % 4; turn += 1) {
    out = out.map(([x, y]) => [box - 1 - y, x]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Game state (module-level; the tree is a function of what `publish` sends)
// ---------------------------------------------------------------------------

let well = null; // the playfield canvas node (from a ref)
let bridge = null; // ctx, kept for the tick and the key handler
let timer = null;

let grid = [];
let bag = [];
let piece = null; // { kind, rotation, x, y }
let nextKind = null;
let score = 0;
let lines = 0;
let level = 1; // guideline levels are 1-based, and the level multiplies clears
let b2b = false; // last clear was "difficult" — the next one pays × 1.5
let combo = -1; // consecutive clearing pieces − 1; −1 means no chain running
let phase = "ready"; // ready | playing | paused | over
let tickCount = 0;
let dirty = true;

function emptyGrid() {
  return Array.from({ length: ROWS }, () => Array(COLS).fill(null));
}

/** 7-bag: every kind appears once per seven pieces. */
function pullFromBag() {
  if (bag.length === 0) {
    bag = KINDS.slice();
    for (let i = bag.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [bag[i], bag[j]] = [bag[j], bag[i]];
    }
  }
  return bag.pop();
}

function spawnOf(kind) {
  const { box } = PIECES[kind];
  return { kind, rotation: 0, x: Math.floor((COLS - box) / 2), y: box === 4 ? -1 : 0 };
}

function collides(candidate) {
  for (const [cx, cy] of rotated(candidate.kind, candidate.rotation)) {
    const x = candidate.x + cx;
    const y = candidate.y + cy;
    if (x < 0 || x >= COLS || y >= ROWS) return true;
    if (y >= 0 && grid[y][x]) return true;
  }
  return false;
}

function spawn() {
  piece = spawnOf(nextKind ?? pullFromBag());
  nextKind = pullFromBag();
  if (collides(piece)) {
    phase = "over";
    stopLoop();
  }
  dirty = true;
}

function lock() {
  for (const [cx, cy] of rotated(piece.kind, piece.rotation)) {
    const y = piece.y + cy;
    const x = piece.x + cx;
    if (y >= 0) grid[y][x] = PIECES[piece.kind].color;
  }
  const kept = grid.filter((row) => row.some((cell) => cell === null));
  const cleared = ROWS - kept.length;
  // "Level is always considered to be the level before the line clear."
  const paidAt = level;
  if (cleared > 0) {
    grid = [...Array.from({ length: cleared }, () => Array(COLS).fill(null)), ...kept];
    const difficult = cleared === 4;
    const chained = difficult && b2b; // the *second* difficult clear is the one that pays
    combo += 1;
    let gained = Math.round(CLEAR_POINTS[cleared] * (chained ? B2B_MULTIPLIER : 1)) * paidAt;
    if (combo > 0) gained += COMBO_POINTS * combo * paidAt;
    score += gained;
    b2b = difficult;
    lines += cleared;
    level = 1 + Math.floor(lines / 10);
    console.log(
      `cleared ${cleared} @ level ${paidAt}${chained ? " b2b" : ""}` +
        `${combo > 0 ? ` combo ${combo}` : ""} -> +${gained} (score ${score})`,
    );
  } else {
    // A piece that clears nothing ends the combo. It does *not* break the
    // back-to-back chain — only a Single, Double or Triple does that.
    combo = -1;
  }
  spawn();
  publish();
}

/** Ticks of gravity per drop — the whole difficulty curve. Level is 1-based
 * (guideline), so level 1 is the eight-tick fall this game has always opened
 * with and level 8 is one tick. */
function ticksPerDrop() {
  return Math.max(1, 9 - level);
}

function tryMove(dx, dy) {
  if (!piece) return false;
  const candidate = { ...piece, x: piece.x + dx, y: piece.y + dy };
  if (collides(candidate)) return false;
  piece = candidate;
  dirty = true;
  return true;
}

function tryRotate() {
  if (!piece) return;
  for (const kick of [0, -1, 1, -2, 2]) {
    const candidate = { ...piece, rotation: piece.rotation + 1, x: piece.x + kick };
    if (!collides(candidate)) {
      piece = candidate;
      dirty = true;
      return;
    }
  }
}

function hardDrop() {
  let distance = 0;
  while (tryMove(0, 1)) distance += 1;
  score += distance * HARD_DROP_POINTS; // flat: no level, no back-to-back
  lock();
}

function gravity() {
  if (!tryMove(0, 1)) lock();
}

// ---------------------------------------------------------------------------
// Loop — started only while a game is actually running
// ---------------------------------------------------------------------------

function startLoop() {
  if (timer) return;
  timer = setInterval(() => {
    tickCount += 1;
    if (tickCount % ticksPerDrop() === 0) gravity();
    if (dirty) {
      draw();
      dirty = false;
    }
  }, TICK_MS);
}

function stopLoop() {
  if (!timer) return;
  clearInterval(timer);
  timer = null;
}

// ---------------------------------------------------------------------------
// Drawing — one canvas, one frame. Draw ops take hex, never a palette token.
// ---------------------------------------------------------------------------

function block(ops, x, y, color) {
  ops.push({ op: "rect", x: x * CELL + 1, y: y * CELL + 1, w: CELL - 2, h: CELL - 2, fill: color, radius: 3 });
}

/** The next piece, half scale and half alpha, hugging the well's top-right.
 * Placed by the piece's *occupied* bounds rather than its rotation box, so an
 * O and an I both sit against the same corner instead of drifting with the
 * box they happen to live in. */
function pushPreview(ops) {
  if (!nextKind) return;
  const { color } = PIECES[nextKind];
  const cells = rotated(nextKind, 0);
  const right = Math.max(...cells.map(([x]) => x));
  const top = Math.min(...cells.map(([, y]) => y));
  const originX = WELL_W - PREVIEW_INSET - (right + 1) * PREVIEW_CELL;
  const originY = PREVIEW_INSET - top * PREVIEW_CELL;
  for (const [cx, cy] of cells) {
    ops.push({
      op: "rect",
      x: originX + cx * PREVIEW_CELL + 1,
      y: originY + cy * PREVIEW_CELL + 1,
      w: PREVIEW_CELL - 2,
      h: PREVIEW_CELL - 2,
      fill: color + PREVIEW_ALPHA,
      radius: 2,
    });
  }
}

function draw() {
  if (!bridge || !well) return;

  const ops = [{ op: "clear" }, { op: "rect", x: 0, y: 0, w: WELL_W, h: WELL_H, fill: "#0B0B0Ecc", radius: 6 }];

  for (let y = 0; y < ROWS; y += 1) {
    for (let x = 0; x < COLS; x += 1) {
      if (grid[y][x]) block(ops, x, y, grid[y][x]);
    }
  }

  if (piece && phase !== "over") {
    // Ghost first, so the piece always draws over its own landing spot.
    let ghostY = piece.y;
    while (!collides({ ...piece, y: ghostY + 1 })) ghostY += 1;
    for (const [cx, cy] of rotated(piece.kind, piece.rotation)) {
      if (ghostY + cy >= 0) block(ops, piece.x + cx, ghostY + cy, "#FFFFFF1F");
    }
    for (const [cx, cy] of rotated(piece.kind, piece.rotation)) {
      if (piece.y + cy >= 0) block(ops, piece.x + cx, piece.y + cy, PIECES[piece.kind].color);
    }
  }

  // Only while there is a game to be next *in*: a preview over the ready well
  // would be a piece you cannot do anything with yet.
  if (phase === "playing" || phase === "paused") pushPreview(ops);

  if (phase !== "playing") {
    // §09's empty state, inside the well where it belongs: one line, never
    // "no data", never an apology. No banner word above it and no second line
    // of hints — the score below already says how it went, and the ghost beside
    // it already says what to press.
    const word = phase === "over" ? "game over" : phase === "paused" ? "paused" : "↵ to play";
    ops.push({ op: "rect", x: 0, y: 0, w: WELL_W, h: WELL_H, fill: "#000000B0", radius: 6 });
    ops.push({
      op: "text",
      // Draw ops cannot measure text, so the centring is arithmetic on an
      // average advance — close enough for two words at 14 pt, and it is the
      // same estimate the archive's banner used, just centred instead of inset.
      x: Math.round((WELL_W - word.length * 7) / 2),
      y: WELL_H / 2 - 9,
      content: word,
      size: 14,
      color: "#FFFFFFCC",
    });
  }

  bridge.draw(well.id, ops);
}

// ---------------------------------------------------------------------------
// Commands (shared by the key handler and the one control)
// ---------------------------------------------------------------------------

let lastProps = "";

/** The panel is three strings; sending them again on every soft-drop point is
 * a commit the shell has to reconcile for nothing, so the signature is checked
 * first. Everything here is an integer or a word — there is no float to
 * quantise, which is the other half of the same rule (REFERENCE.md, Reduce
 * Motion: a raw fraction differs on every tick and commits on each). */
function publish() {
  const props = { score, level, phase };
  const signature = JSON.stringify(props);
  if (signature === lastProps) return;
  lastProps = signature;
  bridge?.update(props);
}

function reset() {
  grid = emptyGrid();
  bag = [];
  piece = null;
  nextKind = null;
  score = 0;
  lines = 0;
  level = 1;
  b2b = false;
  combo = -1;
  tickCount = 0;
  phase = "ready";
  stopLoop();
  dirty = true;
}

function start() {
  reset();
  spawn();
  phase = "playing";
  startLoop();
  draw();
  publish();
}

/** ▶ / ‖ — the only visible control. It starts, pauses, resumes and restarts,
 * because those are one question ("is the well running?") and law 2 gives an
 * app two controls at most; this app needs one. */
function togglePause() {
  if (phase === "playing") {
    phase = "paused";
    stopLoop();
  } else if (phase === "paused") {
    phase = "playing";
    startLoop();
  } else {
    start();
    return;
  }
  dirty = true;
  draw();
  publish();
}

function onKey(data) {
  if (!data.down) return; // key-up is the other half of every press
  const key = data.key;

  if (key === "Enter" || (phase !== "playing" && key === " ")) {
    if (phase !== "playing") start();
    return;
  }
  if (key === "p" || key === "P") {
    togglePause();
    return;
  }
  if (phase !== "playing") return;

  switch (key) {
    case "ArrowLeft":
      tryMove(-1, 0);
      break;
    case "ArrowRight":
      tryMove(1, 0);
      break;
    case "ArrowDown":
      // Soft drop: 1 point per cell the piece *actually* descended, so a press
      // against the floor is worth nothing. Flat — the level never touches it.
      if (tryMove(0, 1)) {
        score += SOFT_DROP_POINTS;
        publish();
      }
      break;
    case "ArrowUp":
      tryRotate();
      break;
    case " ":
      hardDrop();
      break;
    default:
      return;
  }
  if (dirty) {
    draw();
    dirty = false;
  }
}

/**
 * Panel phase. Collapsing the panel over a live game pauses it: the well is not
 * on screen, so continuing would only be a game you lose without watching — and
 * it stops the tick pushing frames at a canvas nobody can see. Expanding
 * repaints at once rather than waiting for the next state change.
 */
export function onLifecycle(panelPhase) {
  if (panelPhase === "expanded") {
    draw();
    return;
  }
  if (panelPhase === "collapsed" && phase === "playing") {
    togglePause();
  }
}

// ---------------------------------------------------------------------------
// Monitor: capture ctx, paint the idle well, then park
// ---------------------------------------------------------------------------

export async function monitor(ctx) {
  bridge = ctx;
  if (grid.length === 0) reset();
  nextKind = nextKind ?? pullFromBag();
  draw();
  publish();
  // Nothing to poll: gravity is a setInterval and every other transition is a
  // key or a click. Parking keeps the 1 s monitor floor out of the game loop.
  await new Promise(() => {});
}

// ---------------------------------------------------------------------------
// View — a well, a number, a glyph
// ---------------------------------------------------------------------------

/** Grouped, because a score is read at a glance and 12480 is not. */
const points = (n) => n.toLocaleString("en-US");

export default function Blocks({ score: value = 0, level: tier = 1, phase: state = "ready" }) {
  const live = state === "playing";

  return (
    // `align="center"` places the column at its own width instead of stretching
    // it, which is what keeps the well 240 pt wide inside a 320 pt panel. The
    // inner column has no `align`, so *its* children stretch to the widest of
    // them — the slab — and the score row lines up with the well's edges
    // exactly. Alignment is the whole reason for the extra stack.
    <stack axis="v" pad={14} align="center">
      {/* Heavy on purpose: a rested pointer should read the score, not open a
          well that is about to start dropping pieces at you. */}
      {/* Summary UX deferred by ruling (2026-08-15) — no app declares one. */}

      <stack axis="v" gap={10}>
        {/* The well — the one framed region for drawn content (§09). `focusable`
            + `onKey`: the shell gives the presented app's first focusable canvas
            first responder, which is what makes the arrow keys arrive here
            rather than in whatever the user was typing in. The frame is a
            `stack`, not pixels, so a canvas with no frames yet still reads as a
            well. */}
        <stack axis="v" pad={2} fill="black" stroke="hairline" radius={8}>
          <canvas
            ref={(node) => {
              well = node;
            }}
            w={WELL_W}
            h={WELL_H}
            focusable
            onKey={onKey}
          />
        </stack>

        {/* Principle 5, literally. The numeral is not in anything: no fill, no
            stroke, no radius, no eyebrow, no caps label. The level is the one
            secondary datum allowed beside it, and it is four characters. */}
        <stack axis="h" gap={8} align="center">
          <text content={points(value)} size="display" weight="light" />
          <text content={`lv ${tier}`} size="s" color="tertiary" />
          <spacer />
          <button
            icon={live ? "sf:pause.fill" : "sf:play.fill"}
            variant="ghost"
            onClick={togglePause}
          />
        </stack>
      </stack>
    </stack>
  );
}
