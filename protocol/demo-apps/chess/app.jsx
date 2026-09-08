/** @jsxImportSource react */
// Chess — the board, and nothing else.
//
// SIGNATURE: the well. A chessboard is the one thing in this folder worth most
// of a panel, so the panel *is* the board at 52 pt a square, plus one quiet
// line and two bare glyphs. §09's law says a big panel is legal for a true
// well, and this is what that sentence is about.
//
// Laws: 1 (ghosts and a hairline slab; nothing filled) · 2 (the shell names the
// app and owns the chrome — this app has a well, a line and two controls) ·
// 3 (ink at rest; the board's own palette is *content*, and red/green appear
// only for check and mate) · 4 (the line is never more than four words) ·
// 5 (the STATUS card, the MOVES card and the "you (white) vs stockfish"
// caption are gone — a position is a board, not a box about a board) ·
// 11 (the sprites are grandfathered: flat-vector content, never chrome) ·
// 12 (the board is the whole of this app's identity).
//
// Diet, against protocol/demo-apps-archive/chess:
//   CUT   the left wing (engine name + a thinking dot) · the STATUS card
//         (label, status line, opponent caption) · the MOVES card (seven
//         numbered pairs behind a "MOVES" label) · two labelled glass/plain
//         buttons · the 640 pt two-column layout that existed to hold them.
//   KEPT  the board well and its slab, the sprites, the overlay tints,
//         chess.js legality, the Stockfish subprocess and the built-in
//         fallback — all verbatim. The engines were never the problem.
//   NEW   one line under the well ("e4 · your move", s / ink-2) and a
//         `<summary>`, which is where the *evaluation* now lives: the one
//         reading a board cannot give you by being a board.
//
// Surfaces:
//   SUMMARY  the position in lingo, plus Stockfish's score — "your move · +0.8",
//            "mate in 2", "thinking…". Declaring it makes the session heavy: a
//            rested pointer reads the position instead of opening a game.
//   WING     none. A game is not a live activity; it is where you go.
//   MINI     none. Chess never interrupts — it is your move whenever you look.
//   REDUCE MOTION  nothing to switch off. A position is one full draw frame and
//            there has never been a piece-slide animation here, so
//            `ctx.reduceMotion` is deliberately unread. Adding a slide in order
//            to have something to suppress would be the wrong order of work.
//   SF SYMBOLS  every `sf:` glyph updates in place — a `<button icon>` through
//            `button.apply(symbol:)`, and (since G3) an `<image src="sf:…">`
//            through `LedgeSymbolView.apply(symbol:)`. No React `key` needed
//            anywhere for a glyph swap. This app renders no `<image>` at all.
//
//   THE STOCKFISH SITUATION (measured, not assumed — carried over intact):
//   the `stockfish` 18.0.8 package is an Emscripten bundle whose environment
//   sniffing is `typeof self !== "undefined" && self.location.hash…`. Bun
//   defines `self` but not `self.location`, so `require("stockfish")` throws
//   immediately under Bun — main thread and Worker alike. Worse, the same sniff
//   treats "node + worker_threads && !isMainThread" as "I am the engine's own
//   web worker" and takes over `postMessage`/`onmessage` — which in a Ledge app
//   worker is the host channel itself. So the engine cannot be loaded in-process
//   here under any shim.
//
//   What does work, and what this app does: run the same bundle as a UCI process
//   over stdio under `node`, spawned with `Bun.spawn` from the worker — one
//   process per move, killed when the search returns. `bestmove` lands ~847 ms
//   after spawn for a 700 ms search (lite-single build, warm cache), i.e. boot is
//   ~145 ms, which is cheaper than the orphaned engine a long-lived process
//   would leave behind on every hot reload. If `node` is missing, or the engine
//   does not answer, the app falls back to a built-in 2-ply material search —
//   silently, because the panel no longer has room to name an opponent, and
//   because the fallback's tell is honest enough on its own: no engine means no
//   score, so the summary simply reads "your move" with nothing after it.

import { Chess } from "chess.js";

export const meta = {
  name: "Chess",
  icon: "sf:crown",
  // The board decides the width: 448 pt of canvas + the slab's 3 pt inset each
  // side + the root's 14 pt padding. `panel` is a *request* — the shell clamps
  // it to the screen — and a well this size is exactly what the clamp is for.
  panel: { width: 482, maxHeight: 600 },
};

// ---------------------------------------------------------------------------
// Board vocabulary & geometry
// ---------------------------------------------------------------------------

const FILES = ["a", "b", "c", "d", "e", "f", "g", "h"];
const RANKS = ["8", "7", "6", "5", "4", "3", "2", "1"];

/** Absolute, because that is what an `image` op takes (REFERENCE.md, "Canvas
 * and games"): a relative path would resolve against the shell's working
 * directory. Built once per (colour, type) at import — a draw frame should
 * allocate ops, not strings, and the shell's decode cache is keyed on exactly
 * these twelve paths. */
const PIECE_SRC = Object.fromEntries(
  ["w", "b"].flatMap((colour) =>
    ["K", "Q", "R", "B", "N", "P"].map((type) => [
      colour + type,
      `${import.meta.dir}/assets/${colour}${type}.png`,
    ]),
  ),
);

const SQ = 52;
const BOARD = SQ * 8; // 416
// The coordinate gutter is symmetric now that the board is not sharing the
// panel with a column: an off-centre well reads as a mistake once it is the
// only thing on the glass.
const BOARD_X = 16;
const BOARD_Y = 6;
const CANVAS_W = BOARD_X + BOARD + BOARD_X; // 448
const CANVAS_H = BOARD_Y + BOARD + 18; // 440 — the file labels live in the last 18

/** The art is 251 × 328 per piece, cut from one sheet so every piece shares
 * the canvas, the aspect ratio, and the baseline: the king fills the height,
 * the pawn stands on the same bottom edge at its own size, and each piece is
 * centred on its *base*, not its bounding box, so a knight's overhanging head
 * does not shove it off-centre in the square. A piece is drawn bottom-aligned
 * at the sprites' own aspect ratio — squaring them would make every knight look
 * like it had been sat on. */
const PIECE_H = 46;
const PIECE_W = Math.round(PIECE_H * 0.765);

// The board's own palette. Both armies are faceted stone with a near-black
// outline: bone (median fill ~#BCB5AA, lit faces up to ~#E6E0D4) and charcoal
// (~#313332, with bone highlights and a red band). So the squares only have to
// avoid the two *fills*, and a mid slate pair clears both by a wide margin in
// value while sitting cool against the warm bone and staying well below the
// panel's own glass in brightness. Law 15 does not reach here: draw ops are
// pixels, and a palette token in an op silently draws white (REFERENCE.md).
const LIGHT_SQUARE = "#A2A9B4";
const DARK_SQUARE = "#5E6878";

// Overlay tints, keeping the semantics the `fill` tokens used to carry: accent
// for the square you picked up, green for where it may go, violet for the move
// that was just played.
const SELECTED_TINT = "#FFB4548C";
const TARGET_TINT = "#30D1583D";
const TARGET_DOT = "#30D158B0";
const LAST_MOVE_TINT = "#8F5DFF3A";
const LABEL_COLOR = "#FFFFFF59";

const HUMAN = "w";
const ENGINE_SIDE = "b";

/** ~1 s cap on a search, per the app brief. */
const THINK_MS = 700;

// ---------------------------------------------------------------------------
// Engine A: Stockfish as a UCI subprocess
// ---------------------------------------------------------------------------

/** Resolve the engine bundle out of the shared apps-root node_modules
 * (REFERENCE.md, "Dependencies") without needing the package's postinstall
 * symlink, which Bun's trust policy blocks: `stockfish.js` is never created, but
 * the versioned builds always ship. `lite-single` is the single-threaded build —
 * no SharedArrayBuffer, no nested workers, which is the only shape that survives
 * being someone else's child, and the only one scripts/bundle-app.sh keeps. */
function engineBundlePath() {
  const index = Bun.resolveSync("stockfish", import.meta.dir);
  const dir = index.slice(0, index.lastIndexOf("/"));
  return `${dir}/bin/stockfish-18-lite-single.js`;
}

/** `info depth 14 … score cp -34 …` / `… score mate 3 …`, from the point of view
 * of whoever is to move at the search root — which here is always the engine. */
const SCORE_LINE = /\bscore (cp|mate) (-?\d+)\b/;

const Stockfish = {
  /** null = not probed yet, true/false = whether this machine can run it. */
  available: null,
  probing: null,

  /**
   * One engine PROCESS PER MOVE, spawned and killed around the search.
   *
   * A long-lived engine is the obvious design and the wrong one here: a Bun
   * Worker has no teardown hook, and a subprocess a worker spawned SURVIVES
   * `worker.terminate()` (measured) — so every hot reload of this file would
   * leave a ~100 MB `node` behind until the whole host exits. Boot costs ~145 ms
   * warm, which is small enough that per-move spawning is simply better: the
   * worst orphan is one in-flight search.
   *
   * `onLine` sees every complete line, which is how the evaluation gets out
   * without a second search. The buffer is drained line by line rather than
   * re-split per chunk (the archive re-scanned the whole transcript on every
   * read, and would have handed `onLine` the same `info` line a hundred times).
   */
  async run(commands, done, timeoutMs, onLine) {
    const node = Bun.which("node");
    if (!node) return null;
    let bundle;
    try {
      bundle = engineBundlePath();
    } catch {
      return null;
    }

    let proc = null;
    try {
      proc = Bun.spawn([node, bundle], { stdin: "pipe", stdout: "pipe", stderr: "ignore" });
      proc.stdin.write(`${commands.join("\n")}\n`);
      proc.stdin.flush();

      const decoder = new TextDecoder();
      const deadline = Date.now() + timeoutMs;
      let buffered = "";
      for await (const chunk of proc.stdout) {
        buffered += decoder.decode(chunk);
        let newline = buffered.indexOf("\n");
        while (newline >= 0) {
          const line = buffered.slice(0, newline).trim();
          buffered = buffered.slice(newline + 1);
          onLine?.(line);
          if (done(line)) return line;
          newline = buffered.indexOf("\n");
        }
        if (Date.now() > deadline) break;
      }
      return null;
    } catch (error) {
      console.log("[chess] stockfish failed:", String(error));
      return null;
    } finally {
      try {
        proc?.kill();
      } catch {
        /* already gone */
      }
    }
  },

  /** Cheap one-shot handshake, memoized, so the app knows which opponent
   * answered before the first move rather than after it. */
  ensure() {
    if (this.available !== null) return Promise.resolve(this.available);
    if (!this.probing) {
      this.probing = this.run(["uci"], (line) => line === "uciok", 15000).then((line) => {
        this.available = line !== null;
        console.log(`[chess] opponent: ${this.available ? "stockfish" : "built-in engine"}`);
        return this.available;
      });
    }
    return this.probing;
  },

  /** `{ uci, score }` for `fen`, or null to fall back. `score` is the deepest
   * `info` line of the same search — free, and the only thing the summary can
   * say that the board is not already saying. */
  async bestMove(fen, movetime) {
    if (!(await this.ensure())) return null;
    let score = null;
    const line = await this.run(
      [
        "uci",
        // Full strength is not fun in a notch; 8 is about a solid club player.
        "setoption name Skill Level value 8",
        `position fen ${fen}`,
        `go movetime ${movetime}`,
      ],
      (l) => l.startsWith("bestmove"),
      movetime + 10000,
      (l) => {
        const hit = SCORE_LINE.exec(l);
        if (hit) score = { kind: hit[1], value: Number(hit[2]) };
      },
    );
    if (!line) return null;
    const uci = line.split(/\s+/)[1];
    return uci && uci !== "(none)" ? { uci, score } : null;
  },
};

// ---------------------------------------------------------------------------
// Engine B: the built-in fallback (2-ply negamax over chess.js legal moves)
// ---------------------------------------------------------------------------

const VALUE = { p: 100, n: 320, b: 330, r: 500, q: 900, k: 0 };

function material(position) {
  let score = 0;
  for (const row of position.board()) {
    for (const square of row) {
      if (!square) continue;
      score += square.color === ENGINE_SIDE ? VALUE[square.type] : -VALUE[square.type];
    }
  }
  return score;
}

/** Negamax from the side to move's point of view, scores in engine-side terms. */
function search(position, depth) {
  if (depth === 0 || position.isGameOver()) {
    if (position.isCheckmate()) {
      // The side to move is mated: terrible for them, so good for the other.
      return position.turn() === ENGINE_SIDE ? -99999 : 99999;
    }
    if (position.isDraw() || position.isStalemate()) return 0;
    return material(position);
  }
  const engineToMove = position.turn() === ENGINE_SIDE;
  let best = engineToMove ? -Infinity : Infinity;
  for (const move of position.moves()) {
    position.move(move);
    const score = search(position, depth - 1);
    position.undo();
    best = engineToMove ? Math.max(best, score) : Math.min(best, score);
  }
  return best;
}

function builtInMove(fen) {
  const position = new Chess(fen);
  const moves = position.moves({ verbose: true });
  if (moves.length === 0) return null;
  let best = null;
  let bestScore = -Infinity;
  for (const move of moves) {
    position.move(move);
    // A whisper of noise so the fallback does not play the same game every time.
    const score = search(position, 1) + Math.random();
    position.undo();
    if (score > bestScore) {
      bestScore = score;
      best = move;
    }
  }
  return best ? best.from + best.to + (best.promotion ?? "") : null;
}

// ---------------------------------------------------------------------------
// App state (module-level; the component is a pure function of published props)
// ---------------------------------------------------------------------------

const game = new Chess();
let bridge = null; // the monitor's ctx; stable for the worker's whole life
let board = null; // the board canvas node (from a ref)
let selected = null;
let targets = [];
let lastMove = null;
let thinking = false;
/** The last search's score, in the engine's own terms; null when unknown —
 * before the first reply, during a search, and forever with the fallback. */
let evaluation = null;
/** Panel phase. A collapsed panel is not worth a frame; expanding is, because
 * the shell keeps the last buffer and a resync would leave it blank. */
let expanded = false;

// ---------------------------------------------------------------------------
// The board, as one draw frame
// ---------------------------------------------------------------------------

/** Which overlay a square wears, if any — the same priority the `fill` tokens
 * had: what you picked up beats where it can go beats what was just played. */
function overlayFor(square) {
  if (square === selected) return SELECTED_TINT;
  if (targets.includes(square)) return TARGET_TINT;
  if (lastMove && (square === lastMove.from || square === lastMove.to)) return LAST_MOVE_TINT;
  return null;
}

/**
 * A full frame, every time. A position change is at most a few times a second
 * and the whole board is ~120 ops — dirty-rect bookkeeping would cost more to
 * maintain than it could ever save, and a full frame can never be stale.
 */
function drawBoard() {
  if (!bridge || !board) return;
  const rows = game.board(); // rank 8 first, matching our top-left origin
  const ops = [{ op: "clear" }];

  for (let rank = 0; rank < 8; rank += 1) {
    for (let file = 0; file < 8; file += 1) {
      const x = BOARD_X + file * SQ;
      const y = BOARD_Y + rank * SQ;
      ops.push({
        op: "rect",
        x,
        y,
        w: SQ,
        h: SQ,
        fill: (file + rank) % 2 === 0 ? LIGHT_SQUARE : DARK_SQUARE,
      });

      const square = `${FILES[file]}${8 - rank}`;
      const tint = overlayFor(square);
      if (tint) ops.push({ op: "rect", x, y, w: SQ, h: SQ, fill: tint });

      const piece = rows[rank][file];
      if (piece) {
        ops.push({
          op: "image",
          src: PIECE_SRC[piece.color + piece.type.toUpperCase()],
          x: x + (SQ - PIECE_W) / 2,
          y: y + SQ - 4 - PIECE_H,
          w: PIECE_W,
          h: PIECE_H,
        });
      } else if (tint === TARGET_TINT) {
        // An empty legal square also gets a dot, because a wash alone is easy
        // to lose under a crowded position.
        ops.push({
          op: "rect",
          x: x + SQ / 2 - 5,
          y: y + SQ / 2 - 5,
          w: 10,
          h: 10,
          radius: 5,
          fill: TARGET_DOT,
        });
      }
    }
  }

  // Files along the bottom, ranks down the left gutter. `text` draws from its
  // top-left in the same y-down space as everything else here. These are board
  // coordinates, not labels about the board — the same ink the squares are.
  for (let file = 0; file < 8; file += 1) {
    ops.push({
      op: "text",
      content: FILES[file],
      x: BOARD_X + file * SQ + SQ / 2 - 3,
      y: BOARD_Y + BOARD + 3,
      size: 10,
      color: LABEL_COLOR,
    });
  }
  for (let rank = 0; rank < 8; rank += 1) {
    ops.push({
      op: "text",
      content: RANKS[rank],
      x: 5,
      y: BOARD_Y + rank * SQ + SQ / 2 - 7,
      size: 10,
      color: LABEL_COLOR,
    });
  }

  bridge.draw(board.id, ops);
}

/** Canvas-local `{x, y}` → a square name, or null outside the board. */
function squareAt(point) {
  const file = Math.floor((point.x - BOARD_X) / SQ);
  const rank = Math.floor((point.y - BOARD_Y) / SQ);
  if (file < 0 || file > 7 || rank < 0 || rank > 7) return null;
  return `${FILES[file]}${8 - rank}`;
}

function onBoardClick(data) {
  const square = squareAt(data);
  if (square) onSquare(square);
}

// ---------------------------------------------------------------------------
// The two strings this app is allowed
// ---------------------------------------------------------------------------

/** The position in lingo, and the one hue that has a job here. Four words is
 * the ceiling (law 4); "you (white) vs stockfish" was six and said nothing the
 * board did not. */
function positionState() {
  if (game.isCheckmate()) {
    return game.turn() === HUMAN
      ? { text: "checkmate · you lost", color: "red" }
      : { text: "checkmate · you win", color: "green" };
  }
  if (game.isStalemate()) return { text: "stalemate", color: "secondary" };
  if (game.isDraw()) return { text: "draw", color: "secondary" };
  if (thinking) return { text: "thinking…", color: "secondary" };
  if (game.isCheck()) return { text: "check", color: "red" };
  return game.turn() === HUMAN
    ? { text: "your move", color: "secondary" }
    : { text: "black to move", color: "secondary" };
}

/** Stockfish's score, said the way a player says it: from White's side, because
 * White is you. UCI reports from the root side to move, which is always Black
 * here, so the sign flips. Null with the fallback engine, which has no score
 * worth publishing. */
function evaluationText() {
  if (!evaluation || thinking || game.isGameOver()) return null;
  if (evaluation.kind === "mate") {
    const moves = Math.abs(evaluation.value);
    return moves === 0 ? null : `mate in ${moves}`;
  }
  const pawns = -evaluation.value / 100;
  return `${pawns >= 0 ? "+" : "-"}${Math.abs(pawns).toFixed(1)}`;
}

function snapshot() {
  const state = positionState();
  const history = game.history();
  const played = history[history.length - 1] ?? null;
  const score = evaluationText();
  return {
    // Under the well: what just happened, and whose move it is.
    line: played ? `${played} · ${state.text}` : state.text,
    // On the hover: where you stand, which is the reading the board withholds.
    glance: score ? `${state.text} · ${score}` : state.text,
    tone: state.color,
    canUndo: history.length >= 2 && !thinking,
  };
}

/**
 * The board is pixels and the line beside it is a tree, so a position change is
 * one draw frame plus one commit. Everything that used to call `publish()`
 * calls this instead — there is no state the two halves can disagree about,
 * because both read the same `game`.
 */
function publish() {
  bridge?.update(snapshot());
  drawBoard();
}

/** Panel phase. Nothing needs painting while collapsed; on the way back the
 * board is repainted once so the panel never opens onto a blank slab after a
 * resync. There is no motion here to reduce, so nothing else rides this. */
export function onLifecycle(phase) {
  const next = phase === "expanded";
  if (next === expanded) return;
  expanded = next;
  if (expanded) drawBoard();
}

// ---------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------

async function engineTurn() {
  if (game.isGameOver() || game.turn() !== ENGINE_SIDE || thinking) return;
  thinking = true;
  evaluation = null; // a stale score under "thinking…" is a lie
  publish();
  try {
    const fen = game.fen();
    const best = await Stockfish.bestMove(fen, THINK_MS);
    let uci = best?.uci ?? null;
    if (best) {
      evaluation = best.score;
    } else {
      evaluation = null;
      uci = builtInMove(fen);
    }
    if (uci && game.turn() === ENGINE_SIDE) {
      const move = game.move({
        from: uci.slice(0, 2),
        to: uci.slice(2, 4),
        promotion: uci.length > 4 ? uci[4] : "q",
      });
      if (move) lastMove = { from: move.from, to: move.to };
    }
  } catch (error) {
    console.log("[chess] engine turn failed:", String(error));
  } finally {
    thinking = false;
    publish();
  }
}

function onSquare(square) {
  if (thinking || game.isGameOver() || game.turn() !== HUMAN) return;

  if (selected && targets.includes(square)) {
    const move = game.move({ from: selected, to: square, promotion: "q" });
    selected = null;
    targets = [];
    if (move) lastMove = { from: move.from, to: move.to };
    publish();
    void engineTurn(); // deliberately not awaited: the panel stays live
    return;
  }

  const legal = game.moves({ square, verbose: true });
  if (legal.length > 0 && legal[0].color === HUMAN) {
    selected = square === selected ? null : square;
    targets = selected ? legal.map((m) => m.to) : [];
  } else {
    selected = null;
    targets = [];
  }
  publish();
}

/** ↺ — the first of the two ghosts. */
function newGame() {
  game.reset();
  selected = null;
  targets = [];
  lastMove = null;
  thinking = false;
  evaluation = null;
  publish();
}

/** ↩ — the second. Flip was the other candidate and lost: you are always White
 * and the board is always drawn White-at-the-bottom, so flipping is a taste
 * with no job, while taking back a blunder is the recurring thing a casual
 * game against a club-strength engine actually needs. Two controls, law 2, and
 * this is the one that earns the slot. */
function undo() {
  if (thinking || game.history().length < 2) return;
  game.undo(); // the engine's reply
  game.undo(); // and your move
  selected = null;
  targets = [];
  lastMove = null;
  evaluation = null;
  publish();
}

// ---------------------------------------------------------------------------
// Monitor: capture ctx, warm the engine, then park (everything else is events)
// ---------------------------------------------------------------------------

export async function monitor(ctx) {
  bridge = ctx;
  publish();
  await Stockfish.ensure();
  // No polling to do: a chess game advances on clicks, and the engine's reply is
  // kicked off by the click that provoked it. Parking keeps the monitor's 1 s
  // floor (REFERENCE.md) out of a loop that has nothing to poll.
  await new Promise(() => {});
}

// ---------------------------------------------------------------------------
// View — a well, a line, two glyphs
// ---------------------------------------------------------------------------

const INITIAL = snapshot();

export default function ChessApp({
  line = INITIAL.line,
  tone = INITIAL.tone,
  canUndo = false,
  onNewGame = newGame,
  onUndo = undo,
}) {
  return (
    <stack axis="v" pad={14} gap={10}>
      {/* The hover's glance surface; the shell adds the chevron. This is the
          only place the evaluation appears — a number the board cannot draw,
          on the surface that exists for exactly that. */}
      {/* Summary UX deferred by ruling (2026-08-15) — no app declares one. */}

      {/* The well: the one framed region for drawn content (§09). The frame is
          a `stack`, not pixels, so the mount tree says "there is a board here"
          before a single frame lands — which is the state a snapshot renders. */}
      <stack axis="v" pad={3} fill="black" stroke="hairline" radius={7}>
        <canvas
          ref={(node) => {
            board = node;
          }}
          w={CANVAS_W}
          h={CANVAS_H}
          onClick={onBoardClick}
        />
      </stack>

      {/* One quiet line, and the two ghosts at the far end of it. No card, no
          label, no chevron, no second row. */}
      <stack axis="h" gap={6} align="center">
        <text content={line} size="s" color={tone} />
        <spacer />
        <button
          icon="sf:arrow.uturn.backward"
          variant="ghost"
          disabled={!canUndo}
          onClick={() => onUndo?.()}
        />
        <button icon="sf:arrow.counterclockwise" variant="ghost" onClick={() => onNewGame?.()} />
      </stack>
    </stack>
  );
}
