/** @jsxImportSource react */
// Alarm — the multi-state showcase (docs/design/app-ideas.md, wave 1). One app,
// three surfaces, and the app itself decides which:
//
//   collapsed  → a WING on the notch: "⏰ 07:30 · 5h 12m" for the next enabled
//                alarm, refreshed once a minute and released when nothing is set
//                (spec §3.3 extension).
//   expanded   → the EDITOR: the alarm list plus a real hour/minute picker.
//   ringing    → a COMPACT tree (big time, label, Snooze / Dismiss) that replaces
//                the editor, put on screen by ctx.expand() (spec §3.3).
//
// The compact-vs-editor choice is the app's own `ringing` flag arriving as a
// prop — there is no API for "show me a different tree", and there does not need
// to be one: a tree is a pure function of props, and the monitor owns the props.
//
// Alarms persist as JSON in the app's own folder (spec §6: persistence is the
// app's business), written temp-then-rename so a half-written file is never what
// the next start reads back. The host watches app.jsx only, so saving here does
// not reload the app.
//
// Ownership split, the same one the Settings reference app uses: the monitor owns
// the state and publishes it — including the action callbacks — through
// ctx.update; the component is pure and never sees ctx. The one thing that is
// *not* published is the picker's staged time: it is scratch, it is nobody's
// business but the panel's, and it lives in ordinary React state (spec §6 apps
// are React apps — the reconciler runs the app's own `react`).
//
// `react` is the only import here besides node: builtins. Apps import nothing
// from Ledge (host/README.md); `useState` is React's, and it resolves to the
// same module instance the reconciler uses.

import { useState } from "react";
import { rename } from "node:fs/promises";

export const meta = { name: "Alarm", icon: "sf:alarm" };

const STORE_PATH = `${import.meta.dir}/alarms.json`;
const TICK_MS = 1_000;
const SNOOZE_MS = 5 * 60_000;

// ---------------------------------------------------------------- model

// An alarm is a daily wall-clock time: { id, hour, minute, label, enabled }.
// `firedKey` (a YYYY-MM-DD-HH:MM stamp) is what stops it firing twice in the same
// minute — and, because it is persisted, what stops a restart mid-minute from
// re-ringing an alarm the user just dismissed. `snoozeUntil` is an epoch ms
// override that wins over the wall-clock time until it passes.
const DEFAULT_ALARMS = [
  { id: "wake", hour: 7, minute: 30, label: "Wake up", enabled: false },
];

let alarms = DEFAULT_ALARMS.map((alarm) => ({ ...alarm }));
let ringing = null; // the id of the alarm currently going off, or null
let ctxRef = null; // the monitor's ctx, kept for the button callbacks
let loaded = false;

const pad2 = (value) => String(value).padStart(2, "0");
const clockOf = (alarm) => `${pad2(alarm.hour)}:${pad2(alarm.minute)}`;
const dayKey = (date) =>
  `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}-${pad2(date.getHours())}:${pad2(date.getMinutes())}`;

/** Milliseconds from `now` until this alarm's next occurrence (snooze wins). */
function msUntil(alarm, now) {
  if (typeof alarm.snoozeUntil === "number") return Math.max(0, alarm.snoozeUntil - now.getTime());
  const next = new Date(now);
  next.setHours(alarm.hour, alarm.minute, 0, 0);
  if (next.getTime() <= now.getTime()) next.setDate(next.getDate() + 1);
  return next.getTime() - now.getTime();
}

/** "5h 12m" / "12m" / "now" — a glance, which is all a wing has room for.
 * Rounded *up*, so an alarm 30 s away reads "1m" rather than claiming "now" for
 * the last minute of every countdown. */
function formatIn(ms) {
  const minutes = Math.ceil(ms / 60_000);
  if (minutes <= 0) return "now";
  const hours = Math.floor(minutes / 60);
  return hours > 0 ? `${hours}h ${minutes % 60}m` : `${minutes}m`;
}

function nextAlarm(now) {
  const enabled = alarms.filter((alarm) => alarm.enabled);
  if (enabled.length === 0) return null;
  return enabled
    .map((alarm) => ({ alarm, in: msUntil(alarm, now) }))
    .sort((a, b) => a.in - b.in)[0];
}

// ---------------------------------------------------------------- persistence

async function load() {
  loaded = true;
  try {
    const saved = await Bun.file(STORE_PATH).json();
    if (Array.isArray(saved?.alarms)) {
      alarms = saved.alarms
        .filter(
          (alarm) =>
            alarm &&
            Number.isInteger(alarm.hour) &&
            Number.isInteger(alarm.minute) &&
            alarm.hour >= 0 &&
            alarm.hour < 24 &&
            alarm.minute >= 0 &&
            alarm.minute < 60,
        )
        .map((alarm) => ({
          id: String(alarm.id ?? `a${Math.random().toString(36).slice(2, 8)}`),
          hour: alarm.hour,
          minute: alarm.minute,
          label: typeof alarm.label === "string" ? alarm.label : "Alarm",
          enabled: alarm.enabled !== false,
          firedKey: typeof alarm.firedKey === "string" ? alarm.firedKey : undefined,
          snoozeUntil: typeof alarm.snoozeUntil === "number" ? alarm.snoozeUntil : undefined,
        }));
      console.log(`loaded ${alarms.length} alarms`);
    }
  } catch {
    // No store yet (first run) or an unreadable one — the default alarm stands.
  }
}

/** Write-temp-then-rename (spec §6). Never throws: losing a save is a bad day,
 * crashing the app over it is a worse one (§6 rule 2). */
async function save() {
  const temporary = `${STORE_PATH}.tmp`;
  try {
    await Bun.write(temporary, JSON.stringify({ alarms }, null, 2));
    await rename(temporary, STORE_PATH);
  } catch (error) {
    console.log(`save failed: ${error?.message ?? error}`);
  }
}

// ---------------------------------------------------------------- publishing

/** Everything the panel needs, derived fresh. The countdown strings are part of
 * it, which is why the monitor re-publishes when the displayed minute changes. */
function viewProps(now = new Date()) {
  const rows = alarms.map((alarm) => ({
    id: alarm.id,
    time: clockOf(alarm),
    label: alarm.label,
    enabled: alarm.enabled,
    subtitle: alarm.enabled
      ? typeof alarm.snoozeUntil === "number"
        ? `snoozed · ${formatIn(msUntil(alarm, now))}`
        : `in ${formatIn(msUntil(alarm, now))}`
      : "off",
  }));
  const active = ringing ? alarms.find((alarm) => alarm.id === ringing) : null;
  return {
    rows,
    ringing: active ? { id: active.id, time: clockOf(active), label: active.label } : null,
    onToggle,
    onDelete,
    onAdd,
    onAddAt,
    onSnooze,
    onDismiss,
  };
}

/** A cheap signature of what the panel would show, so a 1 Hz monitor only sends
 * a commit when the picture actually changed. */
function signature(props) {
  return JSON.stringify([
    props.rows.map((row) => [row.id, row.time, row.label, row.enabled, row.subtitle]),
    props.ringing,
  ]);
}

let lastSignature = "";
let lastWing = "";

function publish(now = new Date()) {
  if (!ctxRef) return;
  const props = viewProps(now);
  const next = signature(props);
  if (next !== lastSignature) {
    lastSignature = next;
    ctxRef.update(props);
  }
}

/** The collapsed notch (spec §3.3 extension). One line, the next alarm; released
 * when nothing is enabled, so the notch goes back to being a notch. */
function publishWing(now = new Date()) {
  if (!ctxRef) return;
  const active = ringing ? alarms.find((alarm) => alarm.id === ringing) : null;
  const next = nextAlarm(now);
  const text = active
    ? `⏰ ${clockOf(active)} · ${active.label}`
    : next
      ? `⏰ ${clockOf(next.alarm)} · ${formatIn(next.in)}`
      : "";
  if (text === lastWing) return;
  lastWing = text;
  ctxRef.wing(text ? { text } : null);
  console.log(text ? `wing -> ${text}` : "wing released (no alarms enabled)");
}

// ---------------------------------------------------------------- actions
// Reach the component as props (it never sees ctx), exactly like the Settings
// reference app. Each one mutates, republishes, and persists.

function commit() {
  publish();
  publishWing();
  void save();
}

function onToggle(id) {
  const alarm = alarms.find((entry) => entry.id === id);
  if (!alarm) return;
  alarm.enabled = !alarm.enabled;
  if (!alarm.enabled) {
    alarm.snoozeUntil = undefined;
    if (ringing === id) ringing = null;
  }
  commit();
}

function onDelete(id) {
  alarms = alarms.filter((entry) => entry.id !== id);
  if (ringing === id) ringing = null;
  commit();
}

/** Ids only have to be unique within the list, but "unique" has to survive two
 * adds in the same millisecond — which the picker makes an ordinary thing to
 * do, not a race. */
let idCounter = 0;

function insertAlarm(hour, minute, label) {
  const alarm = {
    id: `a${Date.now().toString(36)}${(idCounter++).toString(36)}`,
    hour,
    minute,
    label,
    enabled: true,
  };
  alarms = [...alarms, alarm].sort((a, b) => a.hour * 60 + a.minute - (b.hour * 60 + b.minute));
  commit();
  return alarm;
}

/** Quick add: an alarm at the wall-clock time `minutes` from now. Daily, like
 * every other alarm here — "+1h" is a nap that becomes a habit. */
function onAdd(minutes) {
  const when = new Date(Date.now() + minutes * 60_000);
  const label = minutes >= 480 ? "Tomorrow" : minutes >= 60 ? "Later" : "Soon";
  const alarm = insertAlarm(when.getHours(), when.getMinutes(), label);
  console.log(`added alarm ${clockOf(alarm)} (+${minutes}m)`);
}

/** Picker add: an alarm at an absolute wall-clock time, which is what the
 * staging row's Add button sends. The component stages the time and never sees
 * ctx; this is the only thing that crosses back. Both fields are re-normalised
 * here rather than trusted — the panel is the only caller today, and that is
 * exactly the kind of thing that stops being true. */
function onAddAt(hour, minute) {
  const h = ((Math.trunc(hour) % 24) + 24) % 24;
  const m = ((Math.trunc(minute) % 60) + 60) % 60;
  const label = h < 12 ? "Morning" : h < 18 ? "Afternoon" : "Evening";
  const alarm = insertAlarm(h, m, label);
  console.log(`added alarm ${clockOf(alarm)} (picker)`);
}

function onSnooze() {
  const alarm = alarms.find((entry) => entry.id === ringing);
  if (alarm) {
    alarm.snoozeUntil = Date.now() + SNOOZE_MS;
    console.log(`snoozed ${clockOf(alarm)} for 5m`);
  }
  ringing = null;
  commit();
  ctxRef?.collapse();
}

function onDismiss() {
  const alarm = alarms.find((entry) => entry.id === ringing);
  if (alarm) {
    alarm.snoozeUntil = undefined;
    console.log(`dismissed ${clockOf(alarm)}`);
  }
  ringing = null;
  commit();
  ctxRef?.collapse();
}

// ---------------------------------------------------------------- monitor

/** Fire at most one alarm per tick — two alarms in the same minute is a UI with
 * no answer, and the second one rings on the next tick anyway. */
function dueAlarm(now) {
  const stamp = dayKey(now);
  return alarms.find((alarm) => {
    if (!alarm.enabled || alarm.firedKey === stamp) return false;
    if (typeof alarm.snoozeUntil === "number") return now.getTime() >= alarm.snoozeUntil;
    return alarm.hour === now.getHours() && alarm.minute === now.getMinutes();
  });
}

export async function monitor(ctx) {
  try {
    ctxRef = ctx;
    if (!loaded) {
      await load();
      publish();
      publishWing();
    }

    const now = new Date();
    const due = ringing ? null : dueAlarm(now);
    if (due) {
      due.firedKey = dayKey(now);
      due.snoozeUntil = undefined;
      ringing = due.id;
      // Order matters: publish the ringing tree first so the commit is already
      // on the wire when the expand lands — the shell refuses to expand an app
      // with no tree, and opening onto the editor would be a flash of the wrong
      // surface. The reconciler root is synchronous, so `update` has posted its
      // commit by the time `expand` is posted, and the worker→host channel is
      // FIFO.
      publish(now);
      publishWing(now);
      ctx.notify(`${due.label} — ${clockOf(due)}`, { attention: true });
      // Peek rather than expand (§3.3 extension). Seizing the whole panel is the
      // one thing the notch should never do to you mid-sentence — and an alarm
      // firing while you are reading another app is exactly when it would. The
      // peek says what is ringing; hovering it opens this panel, Snooze and
      // Dismiss included. The notification above is still the loud channel.
      ctx.peek(8000);
      console.log(`ALARM FIRED: ${due.label} at ${clockOf(due)}`);
      await save();
    } else {
      publish(now);
      publishWing(now);
    }
  } catch (error) {
    // A throw here is an app crash with backoff (spec §6 rule 2) — an alarm that
    // silently stops ringing because of one bad tick is the worst possible bug.
    console.log(`monitor tick failed: ${error?.stack ?? error}`);
  }
  // 1 Hz: fine enough that an alarm rings on the right minute, and the publish
  // guards above mean a quiet minute costs zero commits.
  await Bun.sleep(TICK_MS);
}

// ---------------------------------------------------------------- the panel

function AlarmRow({ row, onToggle, onDelete }) {
  return (
    <stack axis="h" gap={10} pad={8} fill="raised" stroke="hairline" radius={10}>
      <text
        content={row.time}
        size="l"
        weight="bold"
        mono
        color={row.enabled ? "primary" : "secondary"}
      />
      <stack axis="v" gap={2}>
        <text
          content={row.label}
          size="s"
          weight="semibold"
          color={row.enabled ? "primary" : "secondary"}
          truncate
        />
        <text content={row.subtitle} size="xs" weight="medium" color="secondary" />
      </stack>
      <spacer />
      {/* §5's `toggle` (D6 "New kinds"). It reports the state it is moving *to*,
          which is exactly what `onToggle` already does with the id — so the
          `on` payload is ignored on purpose: the alarm list, not the switch, is
          the thing that knows whether this alarm is enabled. */}
      <toggle on={row.enabled} onChange={() => onToggle?.(row.id)} />
      <button label="✕" variant="plain" onClick={() => onDelete?.(row.id)} />
    </stack>
  );
}

/** The ringing surface: deliberately nothing but the alarm and the two answers
 * to it. This is what ctx.expand() puts on screen. */
function Ringing({ ringing, onSnooze, onDismiss }) {
  return (
    <stack axis="v" pad={18} gap={10}>
      {/* Panel wing (spec §5), not a title row: the shell names the app, and the
          middle of a title row is the camera housing. */}
      <wing side="left">
        <text content="●" size="xs" color="red" />
        <text content="ringing" size="s" weight="semibold" color="red" />
      </wing>

      {/* The peek surface (§3.3 extension): what a firing alarm says before you
          have reached for anything. Deliberately has no Snooze/Dismiss — a
          glance you might not be looking at is the wrong place for a button you
          could hit by accident. Hovering promotes to this panel, which has both. */}
      <mini>
        <stack axis="h" gap={10}>
          <image src="sf:alarm.waves.left.and.right" w={22} h={22} />
          <text content={ringing.time} size="l" weight="bold" mono />
          <text content={ringing.label} size="s" color="secondary" truncate />
        </stack>
      </mini>

      {/* A spacer either side centres the group — leftover space in one stack is
          split evenly between its spacers (protocol/README.md). */}
      <stack axis="h" gap={10}>
        <spacer />
        <image src="sf:alarm.waves.left.and.right" w={30} h={30} />
        <text content={ringing.time} size="xl" weight="bold" mono />
        <spacer />
      </stack>
      <stack axis="h">
        <spacer />
        <text content={ringing.label} size="m" weight="semibold" color="secondary" />
        <spacer />
      </stack>

      <stack axis="h" gap={8} distribute="equal">
        <button label="Snooze 5m" icon="sf:zzz" variant="glass" onClick={() => onSnooze?.()} />
        <button label="Dismiss" icon="sf:checkmark" variant="accent" onClick={() => onDismiss?.()} />
      </stack>
    </stack>
  );
}

// The picker stages one number: minutes since midnight, and §5's `stepper` (D6
// "New kinds") steps it. Everything the four h±/m± buttons used to do is that
// one number plus a step size, which is what makes m+15 at 07:45 carry into
// 08:00 and h+ at 23:xx wrap to 00:xx without a single carry case written out.
// 24h throughout, because the alarm list is 24h — an am/pm segment here would
// mean the panel showed a time in one format and then listed it in another, so
// the segment picks the *field* instead, which is the other thing D6 names it for.
const DAY_MINUTES = 24 * 60;
const STAGED_DEFAULT = 7 * 60; // 07:00 — a constant, not `new Date()`, so the
// mount tree scripts/snapshot-demos.sh dumps is the same tree every run.

const stagedClock = (minutes) => `${pad2(Math.floor(minutes / 60))}:${pad2(minutes % 60)}`;

/** Which field the stepper steps. The step sizes are the old buttons' deltas, so
 * the set of times the picker can reach is unchanged — a minute step of 1 would
 * be 15 presses to cross a quarter hour on a control you use half awake. */
const FIELDS = [
  { id: "hour", label: "Hour" },
  { id: "minute", label: "Minute" },
];
const FIELD_STEP = { hour: 60, minute: 15 };

/** The staging row + Add + the two quick chips. The time is a `segment` (which
 * field) and a `stepper` (step it): `format` is the app's own 24h string, so the
 * shell renders "07:30" over a value that is still minutes since midnight. */
function AddAlarm({ staged, field, onField, onStage, onAdd, onAddAt }) {
  return (
    <stack axis="v" gap={8} pad={8} fill="raised" stroke="hairline" radius={10}>
      <stack axis="h" gap={7}>
        <text content="Add an alarm" size="s" weight="semibold" color="secondary" />
        <spacer />
        <text content="24h" size="xs" weight="medium" color="tertiary" mono />
      </stack>

      {/* Field on the left, the staged time on the right, the slack between them
          (protocol/README.md). No `min`/`max` on the stepper, deliberately:
          clamping would stop h+ dead at 23:xx, and wrapping to 00:xx is the whole
          reason the staged time is one number — `onStage` does the modulo. */}
      <stack axis="h" gap={8}>
        <segment
          options={FIELDS}
          value={field}
          onChange={(data) => onField?.(data?.value ?? field)}
        />
        <spacer />
        <stepper
          value={staged}
          step={FIELD_STEP[field] ?? 15}
          format={stagedClock(staged)}
          onChange={(data) => onStage?.(data?.value)}
        />
      </stack>

      {/* A v-stack stretches its children to its own width, so the commit step
          is the full-width accent button and nothing competes with it. */}
      <button
        label={`Add ${stagedClock(staged)}`}
        icon="sf:alarm"
        variant="accent"
        onClick={() => onAddAt?.(Math.floor(staged / 60), staged % 60)}
      />

      {/* The two relative shortcuts that survived: they answer a different
          question ("wake me in a bit") than the picker does. */}
      <stack axis="h" gap={8}>
        <text content="from now" size="xs" weight="medium" color="tertiary" mono />
        <spacer />
        <button label="+15m" icon="sf:plus" variant="glass" onClick={() => onAdd?.(15)} />
        <button label="+1h" icon="sf:plus" variant="glass" onClick={() => onAdd?.(60)} />
      </stack>
    </stack>
  );
}

// Mount state (what scripts/snapshot-demos.sh dumps — the monitor never runs
// there): the editor with the one default alarm, disabled, and the picker
// staged at STAGED_DEFAULT.
const PLACEHOLDER_ROWS = DEFAULT_ALARMS.map((alarm) => ({
  id: alarm.id,
  time: clockOf(alarm),
  label: alarm.label,
  enabled: alarm.enabled,
  subtitle: "off",
}));

export default function Alarm({
  rows = PLACEHOLDER_ROWS,
  ringing = null,
  onToggle,
  onDelete,
  onAdd,
  onAddAt,
  onSnooze,
  onDismiss,
}) {
  // The staged picker time, in minutes since midnight, and which field the
  // stepper steps. Ordinary React state: both are scratch, neither leaves the
  // panel until Add, and persistence has nothing to say about either. Declared
  // *above* the ringing branch because hooks run unconditionally — an alarm going
  // off must not change the hook order.
  const [staged, setStaged] = useState(STAGED_DEFAULT);
  const [field, setField] = useState("hour");
  // Wrap, don't clamp: an unbounded stepper hands 23:30 + 1h over as 1470, and
  // the modulo is what lands it on 00:30.
  const stage = (minutes) => {
    if (!Number.isFinite(minutes)) return;
    setStaged(((minutes % DAY_MINUTES) + DAY_MINUTES) % DAY_MINUTES);
  };

  // One app, two trees. The flag is the app's own state arriving as a prop —
  // no new protocol, no "mode" API.
  if (ringing) return <Ringing ringing={ringing} onSnooze={onSnooze} onDismiss={onDismiss} />;

  const enabled = rows.filter((row) => row.enabled).length;
  return (
    <stack axis="v" pad={14} gap={8}>
      <wing side="left">
        <text content="●" size="xs" color={enabled > 0 ? "green" : "secondary"} />
        <text
          content={enabled > 0 ? `${enabled} on` : "none set"}
          size="s"
          weight="semibold"
          color="secondary"
        />
      </wing>

      {rows.length === 0 ? (
        <stack axis="h" pad={12} fill="raised" stroke="hairline" radius={10}>
          <spacer />
          <text content="No alarms" size="s" weight="medium" color="secondary" />
          <spacer />
        </stack>
      ) : (
        rows.map((row) => (
          <AlarmRow key={row.id} row={row} onToggle={onToggle} onDelete={onDelete} />
        ))
      )}

      <AddAlarm
        staged={staged}
        field={field}
        onField={setField}
        onStage={stage}
        onAdd={onAdd}
        onAddAt={onAddAt}
      />
    </stack>
  );
}
