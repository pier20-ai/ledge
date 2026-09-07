/** @jsxImportSource react */
// Blocks — the imperative-draw demo (docs/design/app-ideas.md, wave 1). It is
// the app `ctx.draw` (§3.4) and `focusable` + `onKey` (§5, §4.1) exist for:
// the well is a `canvas` whose pixels never go through the reconciler, and the
// side column beside it is ordinary §5 vocabulary that only re-commits when the
// score actually changes.
//
// The loop is an ordinary worker `setInterval` — the platform's, not Ledge's
// (spec §6: nothing the platform already does gets wrapped). It ticks at 120 ms
// and gravity drops the piece every N ticks, N falling with the level. A frame
// is pushed only when something moved, so a paused or finished game costs the
// socket nothing at all, and the interval is not even running. Collapsing the
// panel pauses the game outright (`onLifecycle`, §4.2).
//
// The well is 10 × 20 cells of 24 pt — 240 × 480 — which asks for a 620 pt panel
// and gets it: the shell's cap is a fraction of the screen (~707 pt on a 16"),
// and a game the size of a business card is not a game.
//
// Draw batches stay small on purpose: one `clear`, one well rect, one rect per
// *occupied* cell, four for the piece and four hairline ghosts. A full well is
// ~110 rects; a normal one is nearer 40.
//
// The canvas node id comes from a ref, per host/README.md — `<canvas ref={n =>
// well = n} />` yields the node instance and `well.id` is exactly what the
// reconciler allocated. `ctx` is the monitor's argument but lives as long as the
// worker, so the tick and the key handler both draw with the reference the
// monitor was handed.
//
// Scoring is the guideline-style table most modern falling-block games share
// — see the Scoring section below for the exact
// mapping and the one row this game deliberately cannot implement.

export const meta = {
  name: "Blocks",
  icon: "sf:square.grid.3x3.fill",
  panel: { maxHeight: 620 },
};

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

const COLS = 10;
const ROWS = 20;
const CELL = 24;
const WELL_W = COLS * CELL; // 240
const WELL_H = ROWS * CELL; // 480
const NEXT_SIZE = 84;
const TICK_MS = 120;

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
let preview = null; // the next-piece canvas node
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
// Drawing (spec §3.4 ops: clear / rect / line / text)
// ---------------------------------------------------------------------------

function block(ops, x, y, color) {
  ops.push({ op: "rect", x: x * CELL + 1, y: y * CELL + 1, w: CELL - 2, h: CELL - 2, fill: color, radius: 3 });
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

  if (phase !== "playing") {
    ops.push({ op: "rect", x: 0, y: WELL_H / 2 - 34, w: WELL_W, h: 68, fill: "#000000D8" });
    const banner =
      phase === "over" ? "GAME OVER" : phase === "paused" ? "PAUSED" : "READY";
    const hint =
      phase === "over"
        ? `${score} points`
        : phase === "paused"
          ? "p to resume"
          : "↵ or Start to play";
    ops.push({ op: "text", x: 16, y: WELL_H / 2 - 26, content: banner, size: 20, color: "#FFFFFF" });
    ops.push({ op: "text", x: 16, y: WELL_H / 2 + 6, content: hint, size: 12, color: "#FFFFFF99" });
  }

  bridge.draw(well.id, ops);
  drawPreview();
}

function drawPreview() {
  if (!bridge || !preview || !nextKind) return;
  const { box, color } = PIECES[nextKind];
  const cells = rotated(nextKind, 0);
  const size = 18;
  const originX = (NEXT_SIZE - box * size) / 2;
  const originY = (NEXT_SIZE - box * size) / 2;
  const ops = [{ op: "clear" }];
  for (const [cx, cy] of cells) {
    ops.push({
      op: "rect",
      x: originX + cx * size + 1,
      y: originY + cy * size + 1,
      w: size - 2,
      h: size - 2,
      fill: color,
      radius: 3,
    });
  }
  bridge.draw(preview.id, ops);
}

// ---------------------------------------------------------------------------
// Commands (shared by the key handler and the buttons)
// ---------------------------------------------------------------------------

function publish() {
  bridge?.update({ score, lines, level, phase, b2b, combo });
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
  if (!data.down) return; // key-up is the other half of every press (§4.1)
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
 * Panel phase (spec §4.2). Collapsing the panel over a live game pauses it: the
 * well is not on screen, so continuing would only be a game you lose without
 * watching — and it stops the tick pushing frames at a canvas nobody can see.
 * Expanding repaints at once rather than waiting for the next state change.
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
// View
// ---------------------------------------------------------------------------

function Stat({ label, value, color = "primary" }) {
  return (
    <stack axis="v" gap={1} pad={7} fill="raised" stroke="hairline" radius={9}>
      <text content={label} size="xs" weight="bold" color="tertiary" mono />
      <text content={value} size="l" weight="bold" color={color} mono />
    </stack>
  );
}

export default function Blocks({
  score: points = 0,
  lines: cleared = 0,
  level: tier = 1,
  phase: state = "ready",
  b2b: chain = false,
  combo: streak = -1,
}) {
  const live = state === "playing";
  return (
    <stack axis="v" pad={8} gap={6}>
      {/* The title row is gone (the shell names the app), and the key hints have
          moved to the bottom of the panel rather than into the left wing: the
          wing is ~95 pt on a 440 pt panel and the hints are a full sentence, so
          up there they would be an ellipsis. The wing carries the one word that
          fits — whether the well is live. */}
      <wing side="left">
        <text content={live ? "●" : "○"} size="xs" color={live ? "green" : "secondary"} />
        <text content={state} size="s" weight="semibold" color="secondary" />
      </wing>

      <stack axis="h" gap={12} align="start">
        {/* focusable + onKey: the shell gives the presented app's first
            focusable canvas first responder, which is what makes the arrow keys
            arrive here instead of in whatever the user was typing in. */}
        {/* The frame is a `stack`, not pixels: a canvas with no frames yet (a
            fresh mount, a collapsed panel) still reads as a well. */}
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

        <stack axis="v" gap={8}>
          <stack axis="v" gap={4} pad={7} fill="raised" stroke="hairline" radius={9}>
            <stack axis="h" gap={4}>
              <text content="NEXT" size="xs" weight="bold" color="tertiary" mono />
              <spacer min={80} />
            </stack>
            <canvas
              ref={(node) => {
                preview = node;
              }}
              w={NEXT_SIZE}
              h={NEXT_SIZE}
            />
          </stack>

          <Stat label="SCORE" value={String(points)} color="accent" />
          <Stat label="LINES" value={String(cleared)} />
          <Stat label="LEVEL" value={String(tier)} color="violet" />

          {/* The two score modifiers, kept deliberately quiet: B2B lights when
              the next four-line clear is worth × 1.5, and the combo count is what the
              next clear multiplies 50 × level by. Both are always drawn so the
              column never changes height mid-game. */}
          <stack
            axis="h"
            gap={4}
            pad={6}
            fill={chain ? "accentTint" : "raised"}
            stroke={chain ? "accent" : "hairline"}
            radius={9}
          >
            <text content="B2B" size="xs" weight="bold" mono color={chain ? "accent" : "tertiary"} />
            <spacer />
            <text
              content={streak > 0 ? `${streak}×` : "–"}
              size="xs"
              weight="bold"
              mono
              color={streak > 0 ? "violet" : "tertiary"}
            />
          </stack>

          <spacer />

          <button
            label={state === "playing" ? "Pause" : state === "paused" ? "Resume" : "Start"}
            icon={state === "playing" ? "sf:pause.fill" : "sf:play.fill"}
            variant={live ? "glass" : "accent"}
            onClick={togglePause}
          />
        </stack>

        <spacer />
      </stack>

      {/* Below the well, where a full-width line of key hints reads as a legend
          rather than as a truncated status. */}
      <stack axis="h">
        <text content="↑ rotate  space drop  p pause" size="xs" weight="medium" color="tertiary" mono />
        <spacer />
      </stack>
    </stack>
  );
}
