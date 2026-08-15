/** @jsxImportSource react */
// Timer — the summary + alert exercise.
//
// Laws: 1 (hairlines and ghosts, no cards), 3 (ink until it rings, then red),
// 4 (one eyebrow word), 5 (the datum IS the control — press the numeral).
//
// Surfaces:
//   SUMMARY  the remaining time and one glyph. Declaring it makes this session
//            *heavy*: a rested pointer shows the line, not the panel.
//   WING     the clock in the left wing and `meter: { value }` in the right —
//            flow.md's meter as a wire form, so the bar is the shell's and this
//            app never draws one. The panel keeps its own `<canvas>` bar, which
//            is the same reading in red when it rings.
//   ALERT    at zero: `ctx.peek(_, { class: "alert" })` over a <mini> with one
//            action. An alert never auto-retracts; the action is the way out.
//   REDUCE MOTION  principle 10, via `ctx.reduceMotion` (spec §4.2): the bar
//            still reads the countdown — that is data — but it advances in ten
//            visible steps instead of creeping a pixel at a time.

export const meta = { name: "Timer", icon: "sf:timer" };

const DURATIONS = [1, 5, 15, 25]; // minutes, cycled by pressing the numeral
const TICK_MS = 250;
const BAR_W = 120; // the panel's own progress bar, drawn into a <canvas>
const BAR_BOX_H = 34;
const BAR_H = 2;
// The shell's wing meter is 64 pt wide, so the wing is re-sent only when the
// fraction would move it by a point (spec §3.3; the tick is 4 Hz).
const WING_METER_W = 64;

let ctxRef = null;
let bar = null; // the canvas node, from a ref; its id is what ctx.draw targets
let choice = DURATIONS.length - 1;
let endsAt = null; // epoch ms while running, null while paused or idle
let leftMs = DURATIONS[choice] * 60_000;
let ringing = false;

const totalMs = () => DURATIONS[choice] * 60_000;
const clock = (ms) => {
  const s = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

// ---------------------------------------------------------------- actions
// Module functions, handed to the component as prop *defaults*: they exist from
// the first mount, before any monitor pass, and the component never sees ctx.

function toggle() {
  if (ringing) return stop();
  if (endsAt === null) endsAt = Date.now() + Math.max(leftMs, 1000);
  else {
    leftMs = endsAt - Date.now();
    endsAt = null;
  }
  commit();
}

/** ✕ — the one way back to rest, and the alert's single action. */
function stop() {
  ringing = false;
  endsAt = null;
  leftMs = totalMs();
  commit();
}

/** Idle only: the numeral is the control (law 5). */
function cycle() {
  if (endsAt !== null || ringing) return;
  choice = (choice + 1) % DURATIONS.length;
  leftMs = totalMs();
  commit();
}

// ---------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";

/** Sent only when it changed: the tick is 4 Hz, a clock is 1 Hz. */
function commit() {
  if (!ctxRef) return;
  const props = { time: clock(leftMs), running: endsAt !== null, ringing, mins: DURATIONS[choice] };
  const signature = JSON.stringify(props);
  if (signature === lastProps) return;
  lastProps = signature;
  ctxRef.update(props);

  // The panel's own bar. Hex, not tokens — a canvas is pixels, not a view. The
  // wing's meter is the same fraction, drawn by the shell (see below).
  const done = Math.max(0, Math.min(1, 1 - leftMs / totalMs()));
  if (bar) {
    // Principle 10 (spec §4.2): a progress bar is a canvas that animates, so
    // Reduce Motion quantises it to ten steps. The reading is unchanged and
    // nothing disappears — it simply stops being in continuous motion.
    const shown = ctxRef.reduceMotion ? Math.floor(done * 10) / 10 : done;
    const y = (BAR_BOX_H - BAR_H) / 2;
    ctxRef.draw(bar.id, [
      { op: "clear" },
      { op: "rect", x: 0, y, w: BAR_W, h: BAR_H, fill: "#FFFFFF24", radius: 1 },
      { op: "rect", x: 0, y, w: Math.round(BAR_W * shown), h: BAR_H, radius: 1,
        fill: ringing ? "#FF453A" : "#FFFFFFCC" },
    ]);
  }

  // Held while it runs or rings; released when idle, so the notch goes back to
  // being a notch (law 1). The meter is a wire form: one number, and the shell
  // owns the bar's width, thickness and ink.
  const held = endsAt !== null || ringing;
  const next = held ? `${clock(leftMs)}|${Math.round(done * WING_METER_W)}` : "";
  if (next === lastWing) return;
  lastWing = next;
  ctxRef.wing(held ? { text: clock(leftMs), meter: { value: done } } : null);
}

function tick() {
  if (endsAt === null) return;
  leftMs = endsAt - Date.now();
  if (leftMs > 0) return commit();
  leftMs = 0;
  endsAt = null;
  ringing = true;
  commit(); // the <mini> must read "ringing" before the swell is asked for
  ctxRef.peek(6000, { class: "alert" }); // alert → the dwell is ignored; it holds
  console.log(`rang after ${DURATIONS[choice]}m`);
}

/** Reduce Motion rides the lifecycle envelope (spec §4.2), so a flip lands
 * here. `lastProps` is cleared because the props did not change — only the way
 * they should be drawn did, and `commit` is otherwise a no-op on equal props. */
export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  lastProps = "";
  commit();
}

export async function monitor(ctx) {
  ctxRef = ctx;
  commit();
  // A setInterval, not a monitor pass: the loop has a 1 s spin floor (spec §6
  // rule 1), and a clock that only *sometimes* ticks on the second stutters.
  setInterval(tick, TICK_MS);
  await new Promise(() => {});
}

// ---------------------------------------------------------------- the panel

export default function Timer({
  time = clock(DURATIONS[DURATIONS.length - 1] * 60_000),
  running = false,
  ringing: rang = false,
  mins = DURATIONS[DURATIONS.length - 1],
  onToggle = toggle,
  onStop = stop,
  onCycle = cycle,
}) {
  const numeral = (
    <text content={time} size="display" weight="light" color={rang ? "red" : "primary"} />
  );
  return (
    <stack axis="v" pad={16} gap={8} align="center">
      {/* Summary UX deferred by ruling (2026-08-15) — no app declares one. */}

      {/* The interruption. One glyph, one line, one action (flow.md). */}
      <mini>
        <stack axis="h" gap={10}>
          <image src="sf:timer" w={18} h={18} />
          <text content={`${mins} min`} size="s" weight="semibold" color="red" />
          <spacer />
          <button label="Stop" variant="plain" size="s" onClick={() => onStop?.()} />
        </stack>
      </mini>

      {/* `align="center"` on the column is the whole of the centring: a placed
          child keeps its own width, so the numeral is a numeral-sized press
          target rather than a full-width one (law 5). */}
      <text content="FOCUS" size="xs" weight="medium" color="tertiary" caps />

      {running || rang ? (
        numeral
      ) : (
        <button variant="plain" onClick={() => onCycle?.()}>
          {numeral}
        </button>
      )}

      {/* The panel's bar. The wing's is `meter: { value }` — the shell's. */}
      <canvas ref={(node) => { bar = node; }} w={BAR_W} h={BAR_BOX_H} />

      <stack axis="h" gap={16}>
        {/* Ghosts (design.html §06): app controls are bare pure-white glyphs,
            and a capsule appears only under the cursor. */}
        <button icon={running ? "sf:pause" : "sf:play"} variant="ghost" onClick={() => onToggle?.()} />
        <button icon="sf:xmark" variant="ghost" onClick={() => onStop?.()} />
      </stack>
    </stack>
  );
}
