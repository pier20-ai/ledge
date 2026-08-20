/** @jsxImportSource react */
// Alarms — a list you talk to (G2.12, Manu's redesign of the timer).
//
// The shape: a scrollable list of alarms, each row its NOTE ("7:30 pm",
// "45 min", "Sunset") with pause and delete at the trailing edge, and an
// empty text box at the bottom. You type what you want. A tight local parser
// covers the common shapes — clock times, durations, noon, tomorrow — and
// anything it cannot read goes to a small OpenAI model (GPT-5.6 Luna; the id
// is the app's one Settings control, with `LEDGE_ALARM_MODEL` behind it and
// `OPENAI_API_KEY` to enable it at all), which is what makes "ping me at
// sunset" an alarm rather than an error. The note the model returns is the
// intelligent label the row keeps.
//
// Laws: 1 (rows and ghosts, no cards) · 3 (ink until it rings, then red) ·
// 5 (the note IS the row; the sub-line is the resolved time, which is data).
//
// Surfaces it exercises (unchanged from the timer it replaces):
//   WING   the soonest alarm in the left wing and `meter: { value }` in the
//          right — the shell draws the bar; this app sends one fraction.
//   ALERT  at zero: `ctx.peek(_, { class: "alert" })` over a <mini> with one
//          action. An alert never auto-retracts; Stop is the way out.
//   INPUT  the §5 `input` node. The shell fires `onChange` on Enter — that IS
//          the submit today (`onSubmit` is in the shadow tree but nothing
//          emits it) — and clearing the field takes two commits: echo the
//          typed value into `value`, then empty it, because an update the
//          reconciler cannot see is an update the field never gets.
//
// Persistence: alarms.json beside this file (temp file + rename), so a host
// restart keeps the morning alarm. Stale alarms are dropped on load, loudly.

export const meta = {
  name: "Alarms",
  icon: "sf:alarm",
  // The one thing about this app worth a native control: which model reads the
  // sentences the grammar cannot. It is a text field because model ids are not
  // a list anybody can keep current — today's is `gpt-5.6-luna`, and the next
  // one ships without asking Ledge.
  settings: [
    {
      key: "model",
      label: "Model",
      type: "text",
      default: "gpt-5.6-luna",
      hint: "OpenAI model id for the parser",
    },
  ],
};

const TICK_MS = 250;
const WING_HEARTBEAT_MS = 45_000;
// `import.meta.url` resolves through symlinks, so under the suite's
// symlinked apps root the default store would land in the REPO — the test
// seam points it at the sandbox instead.
const STORE = process.env.LEDGE_ALARM_STORE
  ? new URL(`file://${process.env.LEDGE_ALARM_STORE}`)
  : new URL("./alarms.json", import.meta.url);
/** Whether the model fallback is armed — the empty state tells the truth. */
const HAS_MODEL = Boolean(process.env.OPENAI_API_KEY);

let ctxRef = null;
let alarms = []; // { id, note, fireAt, createdAt, remainMs|null (paused), pending }
let ringing = null; // the id mid-ring, or null
let draft = "";
let hint = "7:30 pm · in 20 min · at sunset";
let hintTimer = null;
let nextId = 1;
let loaded = false;

// ---------------------------------------------------------------- parsing

const MINUTE = 60_000;
const UNIT_MS = { s: 1000, m: MINUTE, h: 3_600_000 };
const UNIT_OF = (word) =>
  word.startsWith("h") ? "h" : word.startsWith("m") && !word.startsWith("mid") ? "m" : "s";

/** The next moment `hours:minutes` comes around, after `now`. */
function nextClock(now, hours, minutes) {
  const at = new Date(now);
  at.setHours(hours, minutes, 0, 0);
  if (at.getTime() <= now) at.setDate(at.getDate() + 1);
  return at.getTime();
}

const clockNote = (ms) =>
  new Date(ms)
    .toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })
    .toLowerCase();

/** The local grammar. Deliberately strict: it answers only when the WHOLE
 * text is one of its shapes, so "sunset over the marina" never half-parses
 * into a 6:00 alarm — ambiguity is the model's job, not a regex's. Exported
 * for the suite: a grammar is exactly the kind of thing to pin. */
export function parseAlarm(text, now = Date.now()) {
  const t = text.trim().toLowerCase().replace(/\s+/g, " ");
  if (!t) return null;

  if (t === "noon") return { fireAt: nextClock(now, 12, 0), note: "noon" };
  if (t === "midnight") return { fireAt: nextClock(now, 0, 0), note: "midnight" };

  // Durations, compound: "45 min", "in 1h 20m", "90 seconds", "1.5 hours".
  {
    const stripped = t.replace(/^(in|for)\s+/, "");
    const token = /(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b/g;
    let ms = 0;
    let consumed = "";
    for (const hit of stripped.matchAll(token)) {
      ms += Number(hit[1]) * UNIT_MS[UNIT_OF(hit[2])];
      consumed += hit[0];
    }
    const leftovers = stripped.replace(token, "").replace(/[\s,]|and/g, "");
    if (ms > 0 && leftovers === "") {
      const hours = Math.floor(ms / 3_600_000);
      const minutes = Math.round((ms % 3_600_000) / MINUTE);
      const note =
        ms < 2 * MINUTE
          ? `${Math.round(ms / 1000)} s`
          : hours > 0
            ? minutes > 0
              ? `${hours} h ${minutes} min`
              : `${hours} h`
            : `${minutes} min`;
      return { fireAt: now + ms, note };
    }
    if (consumed !== "") return null; // half a duration: the model's problem
  }

  // Clock times: "7", "7:30", "7:30 pm", "at 19:45", "tomorrow 9am".
  {
    const hit = t.match(/^(?:(tomorrow)\s+)?(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/);
    if (hit) {
      const [, tomorrow, hh, mm, half] = hit;
      let hours = Number(hh);
      const minutes = Number(mm ?? 0);
      if (hours > 23 || minutes > 59) return null;
      if (half === "pm" && hours < 12) hours += 12;
      if (half === "am" && hours === 12) hours = 0;
      let fireAt;
      if (!half && hours <= 12) {
        // No am/pm: the NEXT time that reading comes around, on either face
        // of the clock — "at 7" typed at 3 pm means 7 tonight.
        fireAt = Math.min(nextClock(now, hours, minutes), nextClock(now, (hours + 12) % 24, minutes));
      } else {
        fireAt = nextClock(now, hours, minutes);
      }
      if (tomorrow) {
        const at = new Date(now);
        at.setDate(at.getDate() + 1);
        at.setHours(hours, minutes, 0, 0);
        fireAt = at.getTime();
      }
      return { fireAt, note: clockNote(fireAt) };
    }
  }

  return null;
}

// ---------------------------------------------------------------- the model

/** Best-effort location, for "sunset" and friends — the weather app's trick.
 * One try per session; an alarm app must not block on geography. */
let place = undefined; // undefined = unasked, null = unknown
async function location() {
  if (place !== undefined) return place;
  place = null;
  try {
    const res = await fetch("http://ip-api.com/json/?fields=lat,lon,city,timezone", {
      signal: AbortSignal.timeout(4000),
    });
    if (res.ok) place = await res.json();
  } catch {
    // Unknown is an answer.
  }
  return place;
}

/** Everything the grammar refused goes to the smallest OpenAI model. It gets
 * the clock and the coordinates, so "sunset today" is arithmetic for it; it
 * answers one JSON object and nothing else. No key → the feature simply is
 * not there, and the hint says what the grammar knows. */
async function askModel(text) {
  const key = process.env.OPENAI_API_KEY;
  if (!key) return null;
  // The Settings window first, then the environment, then the id this app was
  // written against. `ctx.settings` is read here rather than kept anywhere: it
  // holds today's value, and a model id captured at import would be the one
  // from before the user changed it.
  const model = ctxRef?.settings?.model || process.env.LEDGE_ALARM_MODEL || "gpt-5.6-luna";
  const where = await location();
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const system =
    `You convert one natural-language alarm request into one exact firing time. ` +
    `Now: ${new Date().toString()} (${zone}).` +
    (where ? ` User location: ${where.city}, lat ${where.lat}, lon ${where.lon}.` : "") +
    ` Compute sun times from the location and date yourself. Reply with ONLY a JSON object: ` +
    `{"fireAt":"<ISO 8601 with offset>","note":"<a 1-3 word label, e.g. Sunset>"} — or ` +
    `{"error":"<a few words>"} if it cannot be an alarm.`;
  try {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: system },
          { role: "user", content: text },
        ],
        response_format: { type: "json_object" },
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) {
      console.log(`model: HTTP ${res.status} ${await res.text()}`);
      return null;
    }
    const body = await res.json();
    const answer = JSON.parse(body.choices?.[0]?.message?.content ?? "{}");
    const fireAt = Date.parse(answer.fireAt ?? "");
    if (!Number.isFinite(fireAt) || fireAt <= Date.now()) {
      console.log(`model: no usable time (${JSON.stringify(answer)})`);
      return null;
    }
    return { fireAt, note: String(answer.note ?? text).slice(0, 40) };
  } catch (error) {
    console.log(`model: ${error?.message ?? error}`);
    return null;
  }
}

// ---------------------------------------------------------------- actions

function flashHint(line) {
  hint = line;
  commit();
  clearTimeout(hintTimer);
  hintTimer = setTimeout(() => {
    hint = "7:30 pm · in 20 min · at sunset";
    commit();
  }, 5000);
}

async function submit(value) {
  const text = String(value ?? "").trim();
  // The two-step clear (see the header): echo, then empty — with a breath
  // between, so the two updates cannot coalesce into a diff of nothing.
  draft = text;
  commit();
  await Bun.sleep(30);
  draft = "";
  commit();
  if (!text) return;

  const local = parseAlarm(text);
  if (local) {
    alarms.push({ id: nextId++, ...local, createdAt: Date.now(), remainMs: null });
    alarms.sort((a, b) => (a.fireAt ?? Infinity) - (b.fireAt ?? Infinity));
    save();
    commit();
    return;
  }

  // The model's turn, with a visible pending row so the panel says what is
  // happening — a request that vanished for three seconds would read as a
  // swallowed keystroke.
  const id = nextId++;
  alarms.push({ id, note: text, fireAt: null, createdAt: Date.now(), remainMs: null, pending: true });
  commit();
  const answer = await askModel(text);
  const row = alarms.find((a) => a.id === id);
  if (!row) return; // deleted while thinking: the user won
  if (!answer) {
    alarms = alarms.filter((a) => a.id !== id);
    flashHint(process.env.OPENAI_API_KEY ? "didn't catch that" : "didn't catch that — try 7:30 pm");
    commit();
    return;
  }
  row.note = answer.note;
  row.fireAt = answer.fireAt;
  row.pending = false;
  alarms.sort((a, b) => (a.fireAt ?? Infinity) - (b.fireAt ?? Infinity));
  save();
  commit();
}

function pause(id) {
  const row = alarms.find((a) => a.id === id);
  if (!row || row.pending) return;
  if (row.remainMs === null) {
    row.remainMs = Math.max(1000, row.fireAt - Date.now());
    row.fireAt = null;
  } else {
    row.fireAt = Date.now() + row.remainMs;
    row.remainMs = null;
  }
  save();
  commit();
}

function remove(id) {
  alarms = alarms.filter((a) => a.id !== id);
  if (ringing === id) ringing = null;
  save();
  commit();
}

/** ✕ on the swell — the alert's single action, and the ring's only exit. */
function stop() {
  if (ringing !== null) remove(ringing);
  ringing = null;
  commit();
}

// ---------------------------------------------------------------- persistence

async function save() {
  const keep = alarms.filter((a) => !a.pending);
  try {
    const temp = new URL(`${STORE.href}.tmp`);
    await Bun.write(temp, JSON.stringify({ alarms: keep, nextId }));
    const { rename } = await import("node:fs/promises");
    await rename(temp.pathname, STORE.pathname);
  } catch (error) {
    console.log(`save: ${error?.message ?? error}`);
  }
}

async function load() {
  try {
    const stored = await Bun.file(STORE).json();
    nextId = stored.nextId ?? 1;
    const now = Date.now();
    for (const row of stored.alarms ?? []) {
      if (row.remainMs === null && row.fireAt !== null && row.fireAt < now - 5000) {
        console.log(`dropped stale alarm: ${row.note}`);
        continue;
      }
      alarms.push(row);
    }
  } catch {
    // First launch: an empty list is the whole state.
  }
}

// ---------------------------------------------------------------- publishing

const remaining = (row) =>
  row.remainMs !== null ? row.remainMs : Math.max(0, (row.fireAt ?? 0) - Date.now());

/** The row's second line: the resolved moment, and how far away it is. */
function subOf(row) {
  if (row.pending) return "thinking…";
  if (row.remainMs !== null) return `paused · ${short(row.remainMs)} held`;
  const day = new Date(row.fireAt).getDate() === new Date().getDate() ? "" : "tomorrow ";
  return `${day}${clockNote(row.fireAt)} · in ${short(remaining(row))}`;
}

function short(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} s`;
  if (s < 5400) return `${Math.round(s / 60)} min`;
  return `${Math.round(s / 360) / 10} h`;
}

let lastProps = "";
let lastWing = "";
let wingSentAt = 0;

function commit() {
  if (!ctxRef) return;
  const ring = alarms.find((a) => a.id === ringing) ?? null;
  const props = {
    alarms: alarms.map((a) => ({
      id: a.id,
      note: a.note,
      sub: subOf(a),
      paused: a.remainMs !== null,
      pending: Boolean(a.pending),
    })),
    draft,
    hint,
    ringNote: ring?.note ?? "",
    ringing: ring !== null,
  };
  const signature = JSON.stringify(props);
  if (signature !== lastProps) {
    lastProps = signature;
    ctxRef.update(props);
  }

  // The wing: the soonest live alarm, as the shell's meter — elapsed over its
  // own span, so the bar fills toward the ring exactly like the timer's did.
  const soon = alarms
    .filter((a) => a.fireAt !== null && !a.pending)
    .sort((a, b) => a.fireAt - b.fireAt)[0];
  const held = Boolean(soon) || ring !== null;
  let spec = null;
  if (ring) {
    spec = { text: ring.note, meter: { value: 1 } };
  } else if (soon) {
    const span = Math.max(1000, soon.fireAt - soon.createdAt);
    const value = Math.max(0, Math.min(1, 1 - remaining(soon) / span));
    spec = { text: short(remaining(soon)), meter: { value } };
  }
  const wanted = held ? JSON.stringify([spec.text, Math.round((spec.meter.value ?? 0) * 64)]) : "";
  const stale = held && Date.now() - wingSentAt > WING_HEARTBEAT_MS;
  if (wanted === lastWing && !stale) return;
  lastWing = wanted;
  wingSentAt = Date.now();
  ctxRef.wing(spec);
}

function tick() {
  const now = Date.now();
  if (ringing === null) {
    const due = alarms.find((a) => a.fireAt !== null && !a.pending && a.fireAt <= now);
    if (due) {
      ringing = due.id;
      commit(); // the <mini> must read the note before the swell is asked for
      ctxRef.peek(6000, { class: "alert" }); // alert: the dwell is ignored; it holds
      console.log(`rang: ${due.note}`);
      return;
    }
  }
  commit(); // sub-lines and the wing move with the clock; the signature gates
}

export function onLifecycle(phase, ctx) {
  ctxRef = ctxRef ?? ctx;
  lastProps = "";
  commit();
}

export async function monitor(ctx) {
  ctxRef = ctx;
  if (!loaded) {
    loaded = true;
    await load();
    setInterval(tick, TICK_MS);
  }
  commit();
  await new Promise(() => {});
}

// ---------------------------------------------------------------- the panel

export default function Alarms({
  alarms: rows = [],
  draft: text = "",
  hint: placeholder = "7:30 pm · in 20 min · at sunset",
  ringNote = "",
  ringing: rang = false,
  onSubmit = submit,
  onPause = pause,
  onDelete = remove,
  onStop = stop,
}) {
  return (
    <stack axis="v" pad={16} gap={8}>
      {/* The interruption. One glyph, one line, one action (flow.md). */}
      <mini>
        <stack axis="h" gap={10}>
          <image src="sf:alarm" w={18} h={18} />
          <text content={ringNote || "alarm"} size="s" weight="semibold" color="red" />
          <spacer />
          <button label="Stop" variant="plain" size="s" onClick={() => onStop?.()} />
        </stack>
      </mini>

      {/* The empty state (G2.13): the app's one trick, taught in its own
          grammar. Honest about the model — the third line only promises what
          the environment can actually deliver. */}
      {rows.length === 0 ? (
        <stack axis="v" pad={22} gap={10} align="center">
          <image src="sf:alarm" w={26} h={26} />
          <text content="An alarm is a sentence — type one below." size="s" color="secondary" />
          <stack axis="v" gap={3} align="center">
            <text content="7:30 pm  ·  in 20 min  ·  tomorrow 9am" size="xs" color="tertiary" />
            <text
              content={
                HAS_MODEL
                  ? "or an idea — “ping me at sunset” gets figured out"
                  : "set OPENAI_API_KEY and “ping me at sunset” works too"
              }
              size="xs"
              color="tertiary"
            />
          </stack>
        </stack>
      ) : null}

      {/* The list. Each row is its note; the machinery hangs off the right. */}
      <stack axis="v" gap={2} scroll>
        {rows.map((row) => (
          <stack key={row.id} axis="h" gap={10} pad={6} align="center">
            <stack axis="v" gap={2}>
              <text
                content={row.note}
                size="m"
                color={rang && !row.paused ? "red" : row.paused || row.pending ? "tertiary" : "primary"}
                truncate
              />
              <text content={row.sub} size="xs" color="tertiary" />
            </stack>
            <spacer />
            {row.pending ? null : (
              <button
                icon={row.paused ? "sf:play" : "sf:pause"}
                variant="ghost"
                onClick={() => onPause?.(row.id)}
              />
            )}
            <button icon="sf:xmark" variant="ghost" onClick={() => onDelete?.(row.id)} />
          </stack>
        ))}
      </stack>

      {/* The grammar. Type a time, a duration, or an idea. */}
      <input
        value={text}
        placeholder={placeholder}
        onChange={({ value }) => onSubmit?.(value)}
      />
    </stack>
  );
}
