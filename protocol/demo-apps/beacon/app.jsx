/** @jsxImportSource react */
// Beacon — the notification exerciser.
//
// Laws it is written against: 2 (two controls, no more), 4 (one word each,
// no sentences anywhere), 5 (the count is a numeral, not a labelled box).
//
// Surfaces it exercises, both of them the same swell with different manners
// (flow.md, Interruption):
//   AMBIENT   "Ping" fires after 1 s: glyph + one line, no action. It retracts
//             on Ti (~6 s) by itself.
//   ALERT     "Alarm" fires after 3 s: glyph + one line + ONE action. It does
//             not retract; the action is the way out.
// The delays exist so you can press the control, watch the panel close, and
// still be looking at a bare notch when the swell arrives.
//
// Three clicks to check on device, all of them on the swell:
//   the action button          → the app's own §4.1 event; the swell clears.
//   anywhere else on the swell → the VISIT opens on this app.
//   nothing at all             → ambient goes on its own, alert stays.

export const meta = { name: "Beacon", icon: "sf:antenna.radiowaves.left.and.right" };

const PING_DELAY_MS = 1_000;
const ALARM_DELAY_MS = 3_000;

let ctxRef = null;
let armed = false; // one queued fire at a time; both controls go inert meanwhile
let kind = "ambient"; // what <mini> is currently rendering
let fired = 0;

// ---------------------------------------------------------------- actions

/** A setTimeout, not a monitor pass: the monitor loop has a 1 s spin floor
 * (spec §6 rule 1), so "one second from now" would land anywhere in two. The
 * timer dies with the worker on reload or crash, which is the right lifetime
 * for a delay nobody has seen yet. */
function arm(next, delay) {
  if (armed) return;
  armed = true;
  commit();
  setTimeout(() => fire(next), delay);
}

const ping = () => arm("ambient", PING_DELAY_MS);
const alarm = () => arm("alert", ALARM_DELAY_MS);

function fire(next) {
  armed = false;
  kind = next;
  fired += 1;
  // Order matters: <mini> has to be rendering the right row before the shell is
  // asked to raise it. `update` posts its commit synchronously and the
  // worker→host channel is FIFO, so the peek lands behind it.
  commit();
  ctxRef?.peek(6000, { class: kind });
  console.log(`fired ${kind} (#${fired})`);
}

/** The alert's single action. The shell retracts the swell on its own the
 * moment a node event comes back from a mini, so all this has to do is take the
 * red back out of the row — and leave a line in console.log, which is how you
 * prove on device that the app's own handler ran. */
function clear() {
  kind = "ambient";
  console.log("alert acted on");
  commit();
}

// ---------------------------------------------------------------- publishing

let last = "";

function commit() {
  if (!ctxRef) return;
  const props = { fired, kind, armed };
  const signature = JSON.stringify(props);
  if (signature === last) return;
  last = signature;
  ctxRef.update(props);
}

export async function monitor(ctx) {
  ctxRef = ctx;
  commit();
  // Nothing to poll — every fire is a timeout armed by a button. Park.
  await new Promise(() => {});
}

// ---------------------------------------------------------------- the panel

export default function Beacon({
  fired: count = 0,
  kind: cls = "ambient",
  armed: waiting = false,
  onPing = ping,
  onAlarm = alarm,
  onClear = clear,
}) {
  const alert = cls === "alert";
  return (
    <stack axis="v" pad={16} gap={10} align="center">
      {/* The interruption itself. One glyph, one line, and — for an alert only
          — one action (flow.md). An ambient row with a button on it would be a
          decision nobody asked to make. */}
      <mini>
        <stack axis="h" gap={10}>
          <image
            src={alert ? "sf:bell.fill" : "sf:dot.radiowaves.left.and.right"}
            w={18}
            h={18}
          />
          <text
            content={alert ? "Alarm" : "Ping"}
            size="s"
            weight="semibold"
            color={alert ? "red" : "primary"}
          />
          <spacer />
          {alert ? <button label="Stop" variant="plain" size="s" onClick={() => onClear?.()} /> : null}
        </stack>
      </mini>

      {/* No <summary>: this panel is already a glance, so a rested pointer
          should open it rather than describe it. */}

      {/* Both centred by the column's `align`, nothing else: a placed child
          keeps its own width, so the row of controls is as wide as the two
          buttons and no spacers are needed to hold it in the middle. */}
      <text content={String(count)} size="hero" weight="light" />

      <stack axis="h" gap={10}>
        <button label="Ping" variant="plain" disabled={waiting} onClick={() => onPing?.()} />
        <button label="Alarm" variant="plain" disabled={waiting} onClick={() => onAlarm?.()} />
      </stack>
    </stack>
  );
}
