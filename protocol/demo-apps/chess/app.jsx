/** @jsxImportSource react */
// Chess — the "big panel + background compute" demo (docs/design/app-ideas.md,
// wave 1). It is the app that motivated `meta.panel` (protocol/README.md): a
// board plus a move list does not fit in 440 pt, so this app *asks* for 520 and
// the shell decides.
//
// The board is ONE `canvas` and a §3.4 op list; everything beside it (status,
// move list, buttons) is ordinary §5 vocabulary. That split is the point: a
// chessboard is 64 squares, up to 32 pieces and 16 edge labels, which as a
// component tree is ~200 nodes reconciled on every move, and as a draw frame is
// ~120 ops the shell blits in one pass. Pieces are `image` ops naming files in
// this app's own `assets/` folder off `import.meta.dir` (protocol/README.md
// §3.4); the squares and the selection/legal/last-move tints are `rect` ops, so
// this file — not the shell — owns the board's palette. That is the one place a
// Ledge app is allowed raw colours: draw ops are pixels, not components.
//
// A click on the canvas arrives as canvas-local `{x, y}` in the same y-down
// space the ops are written in, so a square is two divisions and no conversion.
//
// Legality is chess.js; the opponent is Stockfish when it can be run and a small
// built-in search when it cannot. Both are ordinary async work in the worker:
// the click handler makes the human move, publishes, and *kicks off* the engine
// without awaiting it, so the panel is never blocked on a search.
//
//   THE STOCKFISH SITUATION (measured, not assumed):
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
//   does not answer, the app falls back to a
//   built-in 2-ply material/mobility search and says so in the panel — the
//   status line always names the opponent you are actually playing.

import { Chess } from "chess.js";

export const meta = {
  name: "Chess",
  icon: "sf:crown",
  // A real board wants ~450 pt, and a move list wants its own column beside it.
  // `panel` is a *request* — the shell clamps it to the screen (§5 extension).
  panel: { width: 640, maxHeight: 620 },
};

// ---------------------------------------------------------------------------
// Board vocabulary & geometry
// ---------------------------------------------------------------------------

const FILES = ["a", "b", "c", "d", "e", "f", "g", "h"];
const RANKS = ["8", "7", "6", "5", "4", "3", "2", "1"];

/** Absolute, because that is what an `image` op takes (protocol/README.md): a
 * relative path would resolve against the shell's working directory. Built once
 * per (colour, type) at import — a draw frame should allocate ops, not strings,
 * and the shell's decode cache is keyed on exactly these twelve paths. */
const PIECE_SRC = Object.fromEntries(
  ["w", "b"].flatMap((colour) =>
    ["K", "Q", "R", "B", "N", "P"].map((type) => [
      colour + type,
      `${import.meta.dir}/assets/${colour}${type}.png`,
    ]),
  ),
);

const SQ = 52;
const BOARD_X = 22; // the rank-label gutter
const BOARD_Y = 6;
const BOARD = SQ * 8; // 416
const CANVAS_W = BOARD_X + BOARD + 8; // 446
const CANVAS_H = BOARD_Y + BOARD + 20; // 442 — the file labels live in the last 20

/** The art is ~410 × 537 with a flat base on the bottom edge, so a piece is
 * drawn bottom-aligned inside its square at the sprites' own aspect ratio —
 * squaring them would make every knight look like it had been sat on. */
const PIECE_H = 46;
const PIECE_W = Math.round(PIECE_H * 0.765);

// The board's own palette. Both armies carry a contrasting outline (ivory
// pieces are outlined near-black, charcoal pieces outlined cream), so the
// squares only have to avoid the two *fills*: ivory sits at ~#F8E8C8 and
// charcoal at ~#384048. A mid slate pair clears both by a wide margin in value
// and sits cool against the warm ivory, while staying well below the panel's
// own glass in brightness.
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

/** Resolve the engine bundle out of the shared apps-root node_modules (spec §6)
 * without needing the package's postinstall symlink, which Bun's trust policy
 * blocks: `stockfish.js` is never created, but the versioned builds always ship.
 * `lite-single` is the single-threaded build — no SharedArrayBuffer, no nested
 * workers, which is the only shape that survives being someone else's child. */
function engineBundlePath() {
  const index = Bun.resolveSync("stockfish", import.meta.dir);
  const dir = index.slice(0, index.lastIndexOf("/"));
  return `${dir}/bin/stockfish-18-lite-single.js`;
}

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
   */
  async run(commands, done, timeoutMs) {
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
        const hit = buffered.split("\n").find((line) => done(line.trim()));
        if (hit) return hit.trim();
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

  /** Cheap one-shot handshake, memoized, so the panel can name the opponent
   * before the first move rather than after it. */
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

  /** UCI long-algebraic best move for `fen`, or null to fall back. */
  async bestMove(fen, movetime) {
    if (!(await this.ensure())) return null;
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
    );
    if (!line) return null;
    const move = line.split(/\s+/)[1];
    return move && move !== "(none)" ? move : null;
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
let opponent = "…"; // until the probe says which engine answered
/** Panel phase (§4.2). A collapsed panel is not worth a frame; expanding is,
 * because the shell keeps the last buffer and a resync would leave it blank. */
let expanded = false;

// ---------------------------------------------------------------------------
// The board, as one draw frame (spec §3.4)
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
  // top-left in the same y-down space as everything else here.
  for (let file = 0; file < 8; file += 1) {
    ops.push({
      op: "text",
      content: FILES[file],
      x: BOARD_X + file * SQ + SQ / 2 - 3,
      y: BOARD_Y + BOARD + 4,
      size: 10,
      color: LABEL_COLOR,
    });
  }
  for (let rank = 0; rank < 8; rank += 1) {
    ops.push({
      op: "text",
      content: RANKS[rank],
      x: 8,
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

/** Move list as White/Black pairs, newest last. */
function movePairs() {
  const history = game.history();
  const pairs = [];
  for (let i = 0; i < history.length; i += 2) {
    pairs.push({
      no: i / 2 + 1,
      white: history[i] ?? "",
      black: history[i + 1] ?? "",
    });
  }
  return pairs.slice(-7);
}

function statusLine() {
  if (game.isCheckmate()) {
    return {
      text: game.turn() === HUMAN ? "Checkmate — you lost" : "Checkmate — you win",
      color: game.turn() === HUMAN ? "red" : "green",
    };
  }
  if (game.isStalemate()) return { text: "Stalemate — draw", color: "secondary" };
  if (game.isDraw()) return { text: "Draw", color: "secondary" };
  if (thinking) return { text: "Thinking…", color: "accent" };
  if (game.isCheck()) {
    return game.turn() === HUMAN
      ? { text: "Check — your move", color: "red" }
      : { text: "Check", color: "red" };
  }
  return game.turn() === HUMAN
    ? { text: "Your move", color: "primary" }
    : { text: "Black to move", color: "secondary" };
}

function snapshot() {
  const status = statusLine();
  return {
    pairs: movePairs(),
    status: status.text,
    statusColor: status.color,
    thinking,
    opponent,
    turn: game.turn(),
    over: game.isGameOver(),
  };
}

/**
 * The board is pixels and the column beside it is a tree, so a position change
 * is one draw frame plus one commit. Everything that used to call `publish()`
 * calls this instead — there is no state the two halves can disagree about,
 * because both read the same `game`.
 */
function publish() {
  bridge?.update(snapshot());
  drawBoard();
}

/** Panel phase (spec §4.2). Nothing needs painting while collapsed; on the way
 * back the board is repainted once so the panel never opens onto a blank slab
 * after a resync. */
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
  publish();
  try {
    const fen = game.fen();
    let uci = await Stockfish.bestMove(fen, THINK_MS);
    if (uci) {
      opponent = "stockfish";
    } else {
      opponent = "built-in";
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

function newGame() {
  game.reset();
  selected = null;
  targets = [];
  lastMove = null;
  thinking = false;
  publish();
}

function undo() {
  if (thinking) return;
  game.undo(); // the engine's reply
  game.undo(); // and your move
  selected = null;
  targets = [];
  lastMove = null;
  publish();
}

// ---------------------------------------------------------------------------
// Monitor: capture ctx, warm the engine, then park (everything else is events)
// ---------------------------------------------------------------------------

export async function monitor(ctx) {
  bridge = ctx;
  publish();
  opponent = (await Stockfish.ensure()) ? "stockfish" : "built-in";
  publish();
  // No polling to do: a chess game advances on clicks, and the engine's reply is
  // kicked off by the click that provoked it.
  await new Promise(() => {});
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

const INITIAL = snapshot();

export default function ChessApp({
  pairs = INITIAL.pairs,
  status = INITIAL.status,
  statusColor = INITIAL.statusColor,
  thinking: busy = false,
  opponent: engine = "…",
  over = false,
}) {
  return (
    <stack axis="v" pad={14} gap={9}>
      {/* The title row is gone: the shell names the app in the panel's left
          wing, and this row's engine label used to sit under the camera. The
          wing replaces the name with something the name could not say — which
          engine is answering, and whether it is thinking. */}
      <wing side="left">
        <text content={busy ? "◍" : "●"} size="xs" color={busy ? "accent" : "green"} />
        <text content={`Chess · ${engine}`} size="s" weight="semibold" color="secondary" />
      </wing>

      <stack axis="h" gap={10} align="start">
        {/* The board sits on its own sunken slab, and the slab is a `stack`
            rather than another draw op so the mount tree still says "there is a
            board here" before a single frame lands — which is exactly the state
            scripts/snapshot-demos.sh renders. */}
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

        <stack axis="v" gap={7}>
          <stack axis="v" gap={2} pad={8} fill="raised" stroke="hairline" radius={9}>
            {/* A nested fill-width row sits at the card edge, so it needs its
                own inset. The sizing spacer is 16 pt narrower to compensate for
                the row's horizontal padding and keep the column fixed. */}
            <stack axis="h" gap={4} pad={8}>
              <text content="STATUS" size="xs" weight="bold" color="tertiary" mono />
              {/* `min` on a spacer is the only way an app asks for a column
                  width: a v-stack sizes to its widest child, so this row is
                  what decides how much of the panel the board leaves over. */}
              <spacer min={112} />
            </stack>
            <text content={status} size="s" weight="semibold" color={statusColor} />
            <text content={`you (white) vs ${engine}`} size="xs" color="tertiary" />
          </stack>

          <stack axis="v" gap={1} pad={8} fill="raised" stroke="hairline" radius={9}>
            <text content="MOVES" size="xs" weight="bold" color="tertiary" mono />
            {pairs.length === 0 ? (
              <text content="—" size="xs" color="secondary" mono />
            ) : (
              pairs.map((pair) => (
                <stack key={`m${pair.no}`} axis="h" gap={5}>
                  <text content={`${pair.no}.`} size="xs" color="tertiary" mono />
                  <text content={pair.white} size="xs" color="primary" mono />
                  <spacer />
                  <text content={pair.black} size="xs" color="secondary" mono />
                </stack>
              ))
            )}
          </stack>

          <spacer />

          {/* size="s" (28, D8 Q4) rather than the default 34: this column has to
              fit beside a fixed-height board, and every point the two controls
              give back is a point the move list keeps. */}
          <button
            label={over ? "Play again" : "New game"}
            icon="sf:arrow.counterclockwise"
            variant={over ? "accent" : "glass"}
            size="s"
            onClick={newGame}
          />
          <button
            label="Take back"
            icon="sf:arrow.uturn.backward"
            variant="plain"
            size="s"
            onClick={undo}
          />
        </stack>

        {/* Slack in this row lands here rather than stretching the board: a
            spacer hugs weaker than anything else in a stack. */}
        <spacer />
      </stack>
    </stack>
  );
}
