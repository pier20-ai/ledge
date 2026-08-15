/** @jsxImportSource react */
// Focus — timers and gentle alarms; calm by construction.
//
// SIGNATURE: the display numeral + the swell. design.html §01's Stage panel is
// literally this app, so the panel IS that specimen and nothing more — eyebrow,
// numeral with its ghosts at the end of the same row, one thin meter beneath.
// 336 pt because that is the width the specimen is drawn at.
//
// Laws: 1 (ghosts and hairlines; nothing filled but a glyph) · 2 (two controls
// on the numeral row, one row under the meter) · 3 (ink at rest, with the one
// exception §01 itself draws: the session meter is `color="accent"`, because
// the working moment is what this panel is about; the ring is red's only job)
// · 4 (one eyebrow word, a two-word alert) · 5 (press the
// datum — the numeral cycles the preset, the alarm row cycles its own time and
// Off is a position in that cycle, so there is no chip, stepper, slider,
// labelled box or keyboard anywhere here) · 10 (Reduce Motion below).
//
// Surfaces:
//   SUMMARY  remaining + a state glyph. Declaring it makes the session heavy —
//            a rested pointer reads the line instead of opening the panel.
//   WING     `{ text, meter: { value } }`: one number, and the shell draws the
//            bar, so this pill's meter is every other app's meter.
//   ALERT    zero, and the alarm: the same `<mini>` row, one action, alert
//            class (it holds until acted on), plus a gentle system notify —
//            no `attention`, no actions, nothing that overrides a sound.
//   REDUCE MOTION  the meter's shell-side self-advance is switched off and its
//            value quantised to ten steps. Nothing in this app ever pulses.
//   STORAGE  preset + alarm in `alarms.json` beside this file. Data, not
//            source, so the watcher never reloads the app on a save.

import { readFileSync, renameSync, writeFileSync } from "node:fs";

export const meta = { name: "Focus", icon: "sf:timer", panel: { width: 336 } };

const PRESETS = [5, 15, 25, 45]; // minutes, cycled by pressing the numeral
const ALARMS = [390, 420, 450, 480, 510, 540]; // 6:30 … 9:00, in minutes
const OFF = ALARMS.length; // one past the end of the cycle — the quiet position
const TICK_MS = 250; // a clock that only sometimes lands on the second stutters
const BAR_PX = 336 - 40; // the meter's width: quantise `done` to what it can show
const STORE = `${import.meta.dir}/alarms.json`;

let ctxRef = null;
let preset = 2; // index into PRESETS
let alarmAt = OFF; // index into ALARMS, or OFF
let firedOn = ""; // the day the alarm last rang, so it rings once
let endsAt = null; // epoch ms while running; null while paused, idle or ringing
let leftMs = PRESETS[preset] * 60_000;
let ring = null; // null | "done" | "alarm"

const totalMs = () => PRESETS[preset] * 60_000;
const clock = (ms) => {
  const s = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};
const hhmm = (m) => `${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}`;
const alarmLabel = () => (alarmAt === OFF ? null : hhmm(ALARMS[alarmAt]));

// -------------------------------------------------------------- persistence
// Temp file + rename: a half-written JSON here is a crash loop on the next boot,
// and rename is the only atomic write there is.

try {
  const saved = JSON.parse(readFileSync(STORE, "utf8"));
  if (PRESETS[saved.preset] !== undefined) preset = saved.preset;
  if (saved.alarmAt >= 0 && saved.alarmAt <= OFF) alarmAt = saved.alarmAt;
  if (typeof saved.firedOn === "string") firedOn = saved.firedOn;
  leftMs = totalMs();
} catch {
  /* first run, or a file someone hand-edited: the defaults are a fine app */
}

function save() {
  try {
    writeFileSync(`${STORE}.tmp`, JSON.stringify({ preset, alarmAt, firedOn }));
    renameSync(`${STORE}.tmp`, STORE);
  } catch (error) {
    console.log(`could not save: ${error.message}`);
  }
}

// -------------------------------------------------------------- actions
// Module functions, handed to the component as prop *defaults*: they exist from
// the first mount, before any monitor pass, and the component never sees ctx.

function toggle() {
  if (ring) return stop();
  if (endsAt === null) endsAt = Date.now() + Math.max(leftMs, 1000);
  else {
    leftMs = endsAt - Date.now();
    endsAt = null;
  }
  commit();
}

/** ✕ — the one way back to rest, and the alert's single action. */
function stop() {
  ring = null;
  endsAt = null;
  leftMs = totalMs();
  commit();
}

/** Idle only: the numeral is the control (law 5). */
function cycle() {
  if (endsAt !== null || ring) return;
  preset = (preset + 1) % PRESETS.length;
  leftMs = totalMs();
  save();
  commit();
}

/** The alarm's entire interface: one press walks 6:30 → … → 9:00 → Off. */
function cycleAlarm() {
  alarmAt = (alarmAt + 1) % (OFF + 1);
  firedOn = "";
  save();
  commit();
}

// -------------------------------------------------------------- publishing

let lastProps = "";
let lastWing = "";

function phase() {
  if (ring) return ring;
  if (endsAt !== null) return "running";
  return leftMs >= totalMs() ? "idle" : "paused";
}

/** Sent only when it changed: the tick is 4 Hz, a clock is 1 Hz. */
function commit() {
  if (!ctxRef) return;
  const state = phase();
  const done = Math.max(0, Math.min(1, 1 - leftMs / totalMs()));
  // Principle 10: `rate` is the shell advancing the bar itself between commits,
  // which is an animation — so Reduce Motion sends rate 0 and ten visible steps.
  // The bar still reads the countdown; it stops being in continuous motion.
  // Otherwise it is quantised to the bar's own pixels, which is what keeps this
  // a 1 Hz app: a raw fraction differs on every 4 Hz tick and commits on each.
  const still = ctxRef.reduceMotion;
  const props = {
    // A ringing alarm's protagonist is the alarm, not the untouched preset.
    time: state === "alarm" ? alarmLabel() : clock(leftMs),
    state,
    done:
      state === "alarm" ? 0 : still ? Math.floor(done * 10) / 10 : Math.round(done * BAR_PX) / BAR_PX,
    rate: state === "running" && !still ? 1000 / totalMs() : 0,
    alarm: alarmLabel(),
  };
  const signature = JSON.stringify(props);
  if (signature === lastProps) return;
  lastProps = signature;
  ctxRef.update(props);

  // Held while it runs or rings, released when it doesn't, so the notch goes
  // back to being a notch. `meter` is a wire form: one number, no draw loop, and
  // every app's pill meter is then the same object.
  const held = state === "running" || state === "done";
  const next = held ? `${props.time}|${Math.round(done * 64)}` : "";
  if (next === lastWing) return;
  lastWing = next;
  ctxRef.wing(held ? { text: props.time, meter: { value: done } } : null);
}

/** Zero, and the alarm: the same interruption, twice. */
function fire(kind) {
  ring = kind;
  endsAt = null;
  commit(); // the <mini> must read the right row before the swell is asked for
  ctxRef.peek(6000, { class: "alert" }); // alert → the dwell is ignored; it holds
  ctxRef.notify(kind === "alarm" ? "Alarm" : "Focus done", { title: "Focus" });
  console.log(`rang: ${kind}`);
}

function tick() {
  if (alarmAt !== OFF && !ring) {
    const now = new Date();
    const day = now.toDateString();
    if (firedOn !== day && now.getHours() * 60 + now.getMinutes() === ALARMS[alarmAt]) {
      firedOn = day;
      save();
      return fire("alarm");
    }
  }
  if (endsAt === null) return;
  leftMs = endsAt - Date.now();
  if (leftMs > 0) return commit();
  leftMs = 0;
  fire("done");
}

/** Reduce Motion rides the lifecycle envelope (spec §4.2), so a flip lands here.
 * `lastProps` is cleared because the props did not change — only the way they
 * should be drawn did, and `commit` is a no-op on equal props. */
// The phase itself is not read here — this app draws the same thing collapsed
// or expanded — so it is named `_phase` rather than left looking forgotten.
export function onLifecycle(_phase, ctx) {
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

// -------------------------------------------------------------- the panel

export default function Focus({
  time = clock(PRESETS[2] * 60_000),
  state = "idle",
  done = 0,
  rate = 0,
  alarm = null,
  onToggle = toggle,
  onStop = stop,
  onCycle = cycle,
  onAlarm = cycleAlarm,
}) {
  const ringing = state === "done" || state === "alarm";
  const live = ringing || state === "running" || state === "paused";
  const numeral = (
    <text content={time} size="display" weight="light" color={ringing ? "red" : "primary"} />
  );

  return (
    <stack axis="v" pad={20} gap={14}>
      {/* The hover's glance surface; the shell adds the chevron. Idle, the news
          is the armed alarm, not a preset nobody started — so the line reads
          whichever number is actually doing something. */}
      <summary>
        <stack axis="h" gap={7} align="center">
          <text content={state === "idle" && alarm ? alarm : time} size="s" weight="medium" />
          {state === "paused" ? <image src="sf:pause.fill" w={9} h={9} /> : null}
          {ringing || (state === "idle" && alarm) ? <image src="sf:bell.fill" w={9} h={9} /> : null}
        </stack>
      </summary>

      {/* The interruption. One glyph, one line, one action (flow.md). */}
      <mini>
        <stack axis="h" gap={10} align="center">
          <image src={state === "alarm" ? "sf:bell.fill" : "sf:timer"} w={18} h={18} />
          <text content={state === "alarm" ? time : "Focus done"} size="s" weight="semibold"
                color="red" />
          <spacer />
          <button label={state === "alarm" ? "Stop" : "Done"} variant="plain" size="s"
                  onClick={() => onStop?.()} />
        </stack>
      </mini>

      {/* §01: eyebrow, then the numeral with its ghosts at the far end of the
          same row. The numeral is its own press target — a placed child keeps
          its own width — so choosing a duration costs no second control. */}
      <stack axis="v" gap={6}>
        <text content="Focus" size="xs" weight="semibold" color="tertiary" mono caps />
        <stack axis="h" gap={6} align="center">
          {live ? numeral : <button variant="plain" onClick={() => onCycle?.()}>{numeral}</button>}
          <spacer />
          {ringing ? null : (
            <button icon={state === "running" ? "sf:pause.fill" : "sf:play.fill"} variant="ghost"
                    onClick={() => onToggle?.()} />
          )}
          {live ? <button icon="sf:xmark" variant="ghost" onClick={() => onStop?.()} /> : null}
        </stack>
      </stack>

      {/* Elapsed — the reading the numeral above is not already giving.
          Accent, as design.html §01 draws it: this bar is the working moment,
          and it is the only coloured thing on the panel. */}
      <progress value={done} rate={rate} color="accent" />

      {/* The gentle half of the job, and only at rest: while a session runs the
          panel is §01's specimen and nothing else. */}
      {live ? null : (
        <button variant="plain" onClick={() => onAlarm?.()}>
          <stack axis="h" gap={6} align="center" pad={4}>
            <image src={alarm ? "sf:bell" : "sf:bell.slash"} w={11} h={11} />
            <text content={alarm ?? "Off"} size="s" color={alarm ? "secondary" : "tertiary"} />
            <spacer />
          </stack>
        </button>
      )}
    </stack>
  );
}
