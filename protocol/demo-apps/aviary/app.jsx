/** @jsxImportSource react */
// Ledge Aviary 🐦 — the mascot app (docs/design/app-ideas.md, wave 1): birds
// live on the notch. It is the demo for wings (§3.3 extension) meeting draw
// frames (§3.4), and the argument that the collapsed pill is a *surface* and not
// just chrome.
//
// V2 is the same flock wearing real pixels. Every bird is one `image` draw op
// (protocol/README.md §3.4) pointing at a file in this app's own `assets/`
// folder, named from `import.meta.dir` — no spritesheet and no source rect,
// because the art ships as one PNG per (colour, pose) cell and the shell caches
// one decode per path however many canvases blit it. The sky behind them is a
// single full-canvas `image` op of the same photographed ledge the app is named
// after.
//
// Two canvases, one flock:
//   - a 120 × 34 strip the app hands to `ctx.wing({ canvas: { id, w } })`. The
//     shell mirrors that node's frames into the right wing, so the birds you see
//     on the notch and the birds in the panel are drawn by one call. The same
//     node also sits in the panel as a "what your notch looks like" preview,
//     which is free: it is the same id.
//   - a wide canvas running the boid flock while you are looking at it.
//
// Clicking the sky scatters the flock away from where you clicked — a `canvas`
// `click` carries canvas-local `{x, y}` in the same y-down space the draw ops
// use, so the fright point needs no conversion. The Scatter / Feed / Perch
// buttons do the same things without aiming. Scatter also fires
// `ctx.attention()`, the glow the notch already knew how to draw — startling
// the birds startles the notch.
//
//   FACING, AND WHY THE FLOCK DRIFTS LEFT.
//   Every sprite in `assets/` faces left, and §3.4's `image` op has a source
//   rect but no flip — a negative destination width is normalised away by Core
//   Graphics, so an app cannot mirror a cell. A mirrored blit is a platform
//   item, not something to fake here. Until it exists this app *steers* around
//   the gap: airborne birds carry a small constant leftward drift (WIND), so
//   flight reads as a leftward loop, and the poses used in the air are the
//   wings-out `flyup`/`flydown` cells, whose silhouette is the least
//   directional of the six. Birds still travel right when their perch slot is
//   to the right of them — that walk home is deliberately the slowest movement
//   in the app, which is the cheapest way to make a wrong-facing sprite hard to
//   notice.
//
// FRAME RATES are driven by `onLifecycle(phase, ctx)` (§4.2): expanded runs the
// flock at ~15 fps and the notch strip at ~2 fps, collapsed stops drawing the
// panel canvas altogether and leaves only the 2 fps wing — which is the only
// surface anyone can see then. Expanding paints one flock frame immediately, so
// the panel is never briefly stale.

export const meta = {
  name: "Aviary",
  icon: "sf:bird",
  panel: { width: 440, maxHeight: 460 },
};

// ---------------------------------------------------------------------------
// Art
// ---------------------------------------------------------------------------

// Paths arrive at the shell **absolute** (protocol/README.md, `image.src`): a
// relative one would resolve against the shell's working directory, which is
// nowhere near this folder.
const ASSETS = `${import.meta.dir}/assets`;
const BACKDROP = `${ASSETS}/ledge-night.png`;

const PLUMAGE = ["cream", "sky", "sage", "lavender", "peach", "mint"];
const POSES = ["perched", "blink", "hop", "peck", "flyup", "flydown"];

/** Every path built once at import: a draw frame should allocate ops, not
 * strings, and the shell keys its decode cache on exactly these. */
const SPRITE = Object.fromEntries(
  PLUMAGE.map((colour) => [
    colour,
    Object.fromEntries(POSES.map((pose) => [pose, `${ASSETS}/bird-${colour}-${pose}.png`])),
  ]),
);

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

const SKY_W = 412;
const SKY_H = 216;
// `ledge-night.png` is 1030 × 540 and its stone's lit top face runs from y ≈ 436
// to y ≈ 455 — the same 1.907 aspect as this canvas, so that face lands at
// 174…182 here and the birds' feet go *onto* the stone rather than in front of
// it. Everything vertical in this app is measured from that line.
const PERCH_Y = 180;
/** An airborne cell is anchored by its centre, but the art sits high in the
 * `flyup`/`flydown` cells — lifting the centre by this much puts the bird's
 * belly on `bird.y`, so the same physics floor works for both states. */
const AIR_LIFT = 12;

const WING_W = 120;
const WING_H = 34;
const WING_PERCH_Y = 30;

/** Drawn cell size. The art is ~300 px square with the bird filling about two
 * thirds of it, so a 34 pt cell is a ~27 × 23 pt bird — big enough to read as a
 * bird, small enough that eleven fit along the ledge. */
const SKY_CELL = 34;
const WING_CELL = 28;

const FLOCK = 11;
const WING_BIRDS = 4;

const SLOW_MS = 500; // 2 fps — the wing, which is on screen whatever happens
const FAST_MS = 66; // ~15 fps — the flock, only while the panel is expanded

/** A prevailing leftward acceleration on anything airborne — see FACING above. */
const WIND = 0.06;

// ---------------------------------------------------------------------------
// Flock state
// ---------------------------------------------------------------------------

let sky = null; // the big canvas node (from a ref)
let strip = null; // the 120 × 34 node the wing mirrors
let bridge = null; // ctx, kept for the loop
let timer = null;
let interval = 0;
let frame = 0;
/** Panel phase, from onLifecycle (§4.2). The shell sends one on connect too, so
 * this is only the pre-connect assumption. */
let expanded = false;
let lastWingText = "";
/** A lone bird crossing the notch strip: the collapsed pill's only animation,
 * and it costs one extra op on a 2 fps frame. */
let flyby = null;

/** Where the birds want to end up: evenly spaced along the ledge. */
function perchSlot(index) {
  const margin = 24;
  const span = SKY_W - margin * 2;
  return margin + (span * (index + 0.5)) / FLOCK;
}

function makeBird(index) {
  return {
    x: perchSlot(index),
    y: PERCH_Y,
    vx: 0,
    vy: 0,
    slot: index,
    perched: true,
    // Personality, not physics: how long this one stays up after a fright, how
    // fast it flaps, when it next blinks, hops or pecks.
    restless: 0,
    flap: Math.random() * Math.PI * 2,
    flapRate: 0.5 + Math.random() * 0.4,
    blink: Math.floor(Math.random() * 40) + 10,
    hop: 0,
    peck: 0,
    colour: PLUMAGE[index % PLUMAGE.length],
  };
}

let birds = Array.from({ length: FLOCK }, (_, index) => makeBird(index));
let feed = null; // { x, y, slot, life } — a scattering of seed on the stone

function perchedCount() {
  return birds.filter((bird) => bird.perched).length;
}

/** How far along the ledge is a slot from the seed, in slots. */
const FEED_REACH = 3;

/**
 * Where this bird wants to stand. With seed out, the handful of birds nearest it
 * each claim their own spot in the patch — the rest keep their slots, because a
 * flock that all converges on one pixel is a pile, not a flock.
 */
function wantedX(bird) {
  if (!feed) return perchSlot(bird.slot);
  const offset = bird.slot - feed.slot;
  if (Math.abs(offset) > FEED_REACH) return perchSlot(bird.slot);
  return Math.max(20, Math.min(SKY_W - 20, feed.x + offset * 25));
}

// ---------------------------------------------------------------------------
// Time of day — the one input this app takes from outside itself
// ---------------------------------------------------------------------------

/** Birds sleep. Between midnight and dawn a perched bird holds the `blink` cell
 * and stops hopping — the flock is still there, it is just not putting on a
 * show at 3am. */
function asleepNow() {
  const hour = new Date().getHours();
  return hour >= 0 && hour < 5;
}

/**
 * A translucent wash over the backdrop, by local hour. The photograph is a night
 * sky, so this never pretends to be daylight — it warms the stone at dawn and
 * dusk and deepens the blue after midnight, which is enough for the panel to
 * feel like it knows what time it is.
 */
function skyWash() {
  const hour = new Date().getHours();
  if (hour < 5) return "#020717AA"; // the small hours: deepest, coldest
  if (hour < 8) return "#FF9A5C2E"; // dawn on the stone
  if (hour < 17) return "#8FB4E024"; // daylight, such as it is
  if (hour < 20) return "#FF6A3A33"; // dusk
  return "#040B1C55"; // evening
}

// ---------------------------------------------------------------------------
// Simulation — boids, loosely, plus a strong opinion about going home
// ---------------------------------------------------------------------------

function step() {
  const asleep = asleepNow();

  if (feed) {
    feed.life -= 1;
    if (feed.life <= 0) feed = null;
  }

  for (const bird of birds) {
    bird.flap += bird.flapRate;

    if (bird.perched) {
      if (asleep) {
        bird.hop = 0;
        bird.peck = 0;
        continue;
      }

      // Idle theatre: blink, and occasionally hop or peck along the ledge.
      bird.blink -= 1;
      if (bird.blink < -3) bird.blink = 20 + Math.floor(Math.random() * 50);
      if (bird.peck > 0) bird.peck -= 1;

      // Where a perched bird would rather be standing: its spot at the seed if
      // there is any, otherwise its own slot. Walking is hops, which is why
      // `hop` both picks the sprite and carries the movement.
      const wanted = wantedX(bird);
      const gap = wanted - bird.x;
      if (Math.abs(gap) > (feed ? 3 : 1.5)) {
        if (bird.hop > 0) {
          bird.hop -= 1;
          bird.x += Math.sign(gap) * 1.3;
        } else if (Math.random() < (feed ? 0.5 : 0.08)) {
          bird.hop = 4;
        }
      } else if (bird.hop > 0) {
        bird.hop -= 1;
      } else if (feed) {
        // Arrived at the seed: heads down.
        if (bird.peck <= 0 && Math.random() < 0.4) bird.peck = 7;
      } else if (Math.random() < 0.006) {
        bird.hop = 5;
      } else if (bird.peck <= 0 && Math.random() < 0.004) {
        bird.peck = 8;
      }
      continue;
    }

    bird.restless = Math.max(0, bird.restless - 1);

    let ax = -WIND; // see FACING: the flock loops leftward
    let ay = 0;
    let neighbours = 0;
    let cx = 0;
    let cy = 0;
    let vx = 0;
    let vy = 0;

    for (const other of birds) {
      if (other === bird || other.perched) continue;
      const dx = other.x - bird.x;
      const dy = other.y - bird.y;
      const distance = Math.hypot(dx, dy);
      if (distance > 70 || distance === 0) continue;
      neighbours += 1;
      cx += other.x;
      cy += other.y;
      vx += other.vx;
      vy += other.vy;
      if (distance < 30) {
        ax -= (dx / distance) * 0.32; // separation — sprites are wider than dots
        ay -= (dy / distance) * 0.32;
      }
    }
    if (neighbours > 0) {
      ax += ((cx / neighbours - bird.x) / 100) * 0.9; // cohesion
      ay += ((cy / neighbours - bird.y) / 100) * 0.9;
      ax += ((vx / neighbours - bird.vx) / 8) * 0.9; // alignment
      ay += ((vy / neighbours - bird.vy) / 8) * 0.9;
    }

    // A goal: the seed if there is any, otherwise the bird's own perch slot once
    // it has calmed down.
    const goalX = wantedX(bird);
    const goalY = PERCH_Y;
    const pull = feed ? 0.05 : bird.restless > 0 ? 0.004 : 0.05;
    ax += (goalX - bird.x) * pull * 0.1;
    ay += (goalY - bird.y) * pull * 0.1;

    // Wander, so a calm flock still looks alive.
    ax += (Math.random() - 0.5) * 0.12;
    ay += (Math.random() - 0.5) * 0.12;

    bird.vx += ax;
    bird.vy += ay;

    const speed = Math.hypot(bird.vx, bird.vy);
    const max = bird.restless > 0 ? 3.4 : 2.2;
    if (speed > max) {
      bird.vx = (bird.vx / speed) * max;
      bird.vy = (bird.vy / speed) * max;
    }

    bird.x += bird.vx;
    bird.y += bird.vy;

    // Soft walls: the sky has edges and the birds know it.
    if (bird.x < 16) {
      bird.x = 16;
      bird.vx = Math.abs(bird.vx);
    }
    if (bird.x > SKY_W - 16) {
      bird.x = SKY_W - 16;
      bird.vx = -Math.abs(bird.vx);
    }
    if (bird.y < 16) {
      bird.y = 16;
      bird.vy = Math.abs(bird.vy);
    }
    if (bird.y > PERCH_Y) {
      bird.y = PERCH_Y;
      bird.vy = -Math.abs(bird.vy) * 0.4;
    }

    // Landing: home, slow, and no longer frightened.
    if (
      bird.restless === 0 &&
      !feed &&
      Math.abs(bird.x - perchSlot(bird.slot)) < 8 &&
      Math.abs(bird.y - PERCH_Y) < 5 &&
      Math.hypot(bird.vx, bird.vy) < 1.6
    ) {
      bird.perched = true;
      bird.y = PERCH_Y;
      bird.vx = 0;
      bird.vy = 0;
      bird.hop = 0;
      bird.peck = 0;
    }
  }
}

// ---------------------------------------------------------------------------
// Drawing (spec §3.4 — every bird is one `image` op)
// ---------------------------------------------------------------------------

/**
 * Which of the six cells this bird is wearing.
 *
 * Airborne: the two wing cells alternate on the bird's own flap phase, which is
 * also what makes a flock of eleven flap out of step. Perched: hop and peck beat
 * the blink cycle, and a sleeping bird simply holds `blink` — closed eyes with
 * no alternation is the whole of "asleep".
 */
function poseFor(bird, asleep) {
  if (!bird.perched) return Math.sin(bird.flap) >= 0 ? "flyup" : "flydown";
  if (asleep) return "blink";
  if (bird.hop > 0) return "hop";
  if (bird.peck > 0) return "peck";
  return bird.blink > 0 ? "perched" : "blink";
}

/** A grounded bird: the cell's bottom edge is where the art puts the feet, so
 * the sprite is anchored by its bottom and the ledge line needs no fudge. The
 * `hop` and `peck` cells lift and dip the bird *within* the cell, which is why
 * this needs no per-pose offset. */
function groundOp(bird, pose, baseY, cell) {
  return {
    op: "image",
    src: SPRITE[bird.colour][pose],
    x: bird.x - cell / 2,
    y: baseY - cell,
    w: cell,
    h: cell,
  };
}

/** An airborne bird is anchored by the cell's centre instead: `flyup` sits high
 * in its cell and `flydown` low, so alternating them bobs the bird for free. */
function airOp(bird, pose, x, y, cell) {
  return { op: "image", src: SPRITE[bird.colour][pose], x: x - cell / 2, y: y - cell / 2, w: cell, h: cell };
}

function drawSky() {
  if (!bridge || !sky) return;
  const asleep = asleepNow();
  const ops = [
    { op: "clear" },
    // The whole photograph, no source rect: destination is smaller than the
    // source, so the shell interpolates it down rather than aliasing it.
    { op: "image", src: BACKDROP, x: 0, y: 0, w: SKY_W, h: SKY_H },
    // …and the hour of the day, as one translucent wash.
    { op: "rect", x: 0, y: 0, w: SKY_W, h: SKY_H, fill: skyWash() },
  ];

  if (feed) {
    // Grains on the lit face of the stone, scattered across the patch the
    // nearest birds walk to — before the birds, so they stand over them.
    for (let i = 0; i < 9; i += 1) {
      ops.push({
        op: "rect",
        x: feed.x - 40 + i * 10 + ((i * 13) % 7),
        y: feed.y + ((i * 5) % 4),
        w: 2.5,
        h: 2.5,
        fill: "#F2C877",
        radius: 1.25,
      });
    }
  }

  for (const bird of birds) {
    const pose = poseFor(bird, asleep);
    ops.push(
      bird.perched
        ? groundOp(bird, pose, PERCH_Y, SKY_CELL)
        : airOp(bird, pose, bird.x, bird.y - AIR_LIFT, SKY_CELL),
    );
  }

  bridge.draw(sky.id, ops);
}

/** The notch strip: the calmest members of the flock, small, on a hairline. */
function drawWing() {
  if (!bridge || !strip) return;
  const asleep = asleepNow();
  const ops = [{ op: "clear" }];
  ops.push({
    op: "line",
    points: [
      [4, WING_PERCH_Y + 1.5],
      [WING_W - 4, WING_PERCH_Y + 1.5],
    ],
    stroke: "#FFFFFF2E",
    width: 1.5,
  });

  // A lone bird crossing the pill, leftward — the collapsed surface's only
  // motion, and cheap enough to run at 2 fps forever.
  if (flyby) {
    flyby.x -= flyby.speed;
    flyby.flap += 1.3;
    if (flyby.x < -WING_CELL) flyby = null;
    else {
      ops.push(
        airOp(
          { colour: flyby.colour },
          Math.sin(flyby.flap) >= 0 ? "flyup" : "flydown",
          flyby.x,
          flyby.y,
          WING_CELL,
        ),
      );
    }
  } else if (!asleep && Math.random() < 0.02) {
    flyby = {
      x: WING_W + WING_CELL,
      y: 9 + Math.random() * 4,
      speed: 8 + Math.random() * 5,
      flap: 0,
      colour: PLUMAGE[Math.floor(Math.random() * PLUMAGE.length)],
    };
  }

  const flying = birds.filter((bird) => !bird.perched).length;
  for (let i = 0; i < WING_BIRDS; i += 1) {
    const bird = birds[i];
    const x = 18 + i * ((WING_W - 36) / (WING_BIRDS - 1));
    if (i < WING_BIRDS - Math.min(WING_BIRDS, flying)) {
      ops.push(groundOp({ ...bird, x }, poseFor(bird, asleep), WING_PERCH_Y, WING_CELL));
    } else {
      // Airborne birds cross the strip above the perch, out of phase.
      const y = 12 + Math.sin(frame * 0.25 + i) * 3;
      ops.push(airOp(bird, poseFor(bird, asleep), x, y, WING_CELL));
    }
  }

  bridge.draw(strip.id, ops);

  const perched = perchedCount();
  const text = perched === 1 ? "1 perched" : `${perched} perched`;
  if (text !== lastWingText) {
    // Only on change: a wing request and a commit per frame would be two
    // envelopes an hour's worth of birds does not need.
    lastWingText = text;
    bridge.wing({ text, canvas: { id: strip.id, w: WING_W } });
    publish();
  }
}

// ---------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------

function retime(ms) {
  if (interval === ms) return;
  interval = ms;
  if (timer) clearInterval(timer);
  timer = setInterval(tick, ms);
}

function tick() {
  frame += 1;
  step();
  if (expanded) {
    drawSky();
    if (frame % 7 === 0) drawWing(); // the wing never needs 15 fps
    retime(FAST_MS);
  } else {
    // Nobody can see the panel canvas, so nothing is drawn into it: collapsed
    // costs exactly one 120 pt strip frame every 500 ms.
    drawWing();
    retime(SLOW_MS);
  }
}

/**
 * Panel phase (spec §4.2). `expanded` is the only reason to run a flock at frame
 * rate; every other phase is the wing alone.
 */
export function onLifecycle(phase) {
  const next = phase === "expanded";
  if (next === expanded) return;
  expanded = next;
  if (expanded) {
    // Paint immediately rather than up to 500 ms later, so the panel opens onto
    // live birds instead of the last collapsed frame.
    drawSky();
    retime(FAST_MS);
  } else {
    retime(SLOW_MS);
  }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

function publish() {
  bridge?.update({ perched: perchedCount(), flying: FLOCK - perchedCount(), fed: Boolean(feed) });
}

/**
 * Something frightened them. `from` is where it happened in canvas coordinates
 * — a click point, or the middle of the ledge when the button did it — and every
 * bird leaves along the line away from it, faster the closer it was.
 */
function scatter(from = { x: SKY_W / 2, y: PERCH_Y + 24 }) {
  for (const bird of birds) {
    bird.perched = false;
    bird.restless = 90 + Math.floor(Math.random() * 60);
    const dx = bird.x - from.x;
    const dy = bird.y - from.y;
    const distance = Math.hypot(dx, dy) || 1;
    const push = 2.4 + 2.4 / (1 + distance / 60);
    bird.vx = (dx / distance) * push + (Math.random() - 0.5);
    bird.vy = (dy / distance) * push - 1.4; // and up: birds flee upward
  }
  feed = null;
  bridge?.attention(); // the notch flinches too
  publish();
}

/** A `canvas` click arrives in canvas-local, y-down coordinates — the same space
 * the draw ops are written in, so the point is usable as-is. */
function onSkyClick(data) {
  scatter({ x: data.x, y: data.y });
}

/** Seed on the stone. The birds nearest it hop along the ledge and peck;
 * anything already up treats the patch as somewhere to land. */
function scatterFeed() {
  const slot = 2 + Math.floor(Math.random() * (FLOCK - 4));
  feed = { x: perchSlot(slot), y: PERCH_Y - 2, slot, life: 160 };
  publish();
}

function callHome() {
  feed = null;
  for (const bird of birds) bird.restless = 0;
  publish();
}

// ---------------------------------------------------------------------------
// Monitor: take the notch, start the loop, then park
// ---------------------------------------------------------------------------

export async function monitor(ctx) {
  bridge = ctx;
  publish();
  drawWing(); // claims the notch: the first wing frame carries the wing spec
  if (expanded) drawSky(); // lifecycle may already have landed
  retime(expanded ? FAST_MS : SLOW_MS);
  // The flock is a setInterval, not a monitor pass: a 1 s floor is not a frame
  // rate. Park and let the loop own the clock.
  await new Promise(() => {});
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

export default function Aviary({ perched = FLOCK, flying = 0, fed = false }) {
  return (
    <stack axis="v" pad={12} gap={8}>
      {/* Panel wing (spec §5) rather than a title row: the shell names the app,
          and the flock count used to be drawn under the camera. */}
      <wing side="left">
        <text content="🐦" size="xs" />
        <text
          content={flying > 0 ? `${flying} up · ${perched} perched` : `${perched} perched`}
          size="s"
          weight="semibold"
          color={flying > 0 ? "accent" : "secondary"}
        />
      </wing>

      {/* The sky is framed by a `stack`, so it reads as a window onto the ledge
          even before the first frame lands (a fresh mount, a snapshot). */}
      <stack axis="v" pad={2} fill="black" stroke="hairline" radius={12}>
        <canvas
          ref={(node) => {
            sky = node;
          }}
          w={SKY_W}
          h={SKY_H}
          onClick={onSkyClick}
        />
      </stack>

      <stack axis="h" gap={10} pad={7} fill="raised" stroke="hairline" radius={10}>
        <stack axis="v" gap={1}>
          <text content="ON THE NOTCH" size="xs" weight="bold" color="tertiary" mono />
          <text content={fed ? "there is seed out" : "roosting"} size="xs" color="secondary" />
        </stack>
        <spacer />
        {/* The wing's own canvas, sitting in the panel as a preview: the shell
            mirrors this node's frames into the notch, so it is literally the
            same pixels — one `ctx.draw`, two places. */}
        <canvas
          ref={(node) => {
            strip = node;
          }}
          w={WING_W}
          h={WING_H}
        />
      </stack>

      <stack axis="h" gap={8} distribute="equal">
        {/* Wrapped, not passed by reference: a handler is called with the
            event's data, and `scatter` reads its argument as a fright point. */}
        <button label="Scatter" icon="sf:wind" variant="accent" onClick={() => scatter()} />
        <button label="Feed" icon="sf:leaf" variant="glass" onClick={scatterFeed} />
        <button label="Perch" icon="sf:arrow.down.to.line" variant="plain" onClick={callHome} />
      </stack>
    </stack>
  );
}
