// The time ruler — a tick strip you drag to travel.
//
// It is deliberately the dumbest surface in the app: hour ticks, taller every
// six, the hour numbers at those, and one amber region covering the span you
// have scrubbed into. No temperature curve, no precipitation bars, no legend.
// The ruler's whole job is to say *when*; the pane above it says everything
// else, and the moment this strip starts carrying data of its own it becomes a
// second thing to read (principle 5).
//
// Amber is the one hue on the glass, and this is its one job here (principle 3).

const HOUR = 3_600_000;

const hex = (a) => `#FFFFFF${Math.round(a * 255).toString(16).padStart(2, "0")}`;
/** design.html §03 `--accent: #FFB454`. Canvas ops take hex, not tokens, so the
 * one literal in this app lives here, named, beside the token it copies. */
const ACCENT = "FFB454";
const accent = (a) => `#${ACCENT}${Math.round(a * 255).toString(16).padStart(2, "0")}`;

const q = (v) => Math.round(v * 2) / 2;

/**
 * @param w      canvas width
 * @param h      canvas height
 * @param span   hours the strip covers (now → +span)
 * @param offset how far ahead the scrub currently is, in ms (0 = now)
 * @param now    epoch ms of "now"
 * @param tz     utc offset in ms, for the hour labels
 */
export function rulerOps({ w, h, span, offset, now, tz }) {
  const baseline = Math.round(h * 0.62) + 0.5;
  const x = (ms) => (ms / (span * HOUR)) * w;
  const head = Math.max(0, Math.min(w, x(offset)));
  const scrubbed = offset > 60_000;

  const ops = [{ op: "clear" }];

  // The travelled region. A wash, not a bar: it marks where you have gone, and
  // the head is the datum.
  if (scrubbed) {
    ops.push({
      op: "gradient",
      x: 0,
      y: 0,
      w: q(head),
      h,
      from: accent(0.03),
      to: accent(0.12),
      angle: 90,
    });
  }

  // The rule itself, and the ticks standing on it.
  ops.push({
    op: "rect",
    x: 0,
    y: baseline,
    w,
    h: 1,
    fill: hex(0.14),
  });

  const first = Math.ceil((now + tz) / HOUR) * HOUR - tz; // the next whole hour
  for (let t = first; t <= now + span * HOUR; t += HOUR) {
    const hour = new Date(t + tz).getUTCHours();
    const major = hour % 6 === 0;
    const tx = q(x(t - now));
    const height = major ? 9 : 5;
    const lit = scrubbed && t - now <= offset;
    ops.push({
      op: "rect",
      x: tx,
      y: baseline - height,
      w: 1,
      h: height,
      fill: lit ? accent(major ? 0.85 : 0.5) : hex(major ? 0.42 : 0.2),
    });
    // Two digits always, centred on their tick — and dropped rather than
    // clipped at the right-hand end, because half a number is worse than none.
    if (major && tx > 8 && tx < w - 12) {
      ops.push({
        op: "text",
        x: tx - 6,
        y: baseline + 4,
        content: String(hour).padStart(2, "0"),
        size: 8,
        color: lit ? accent(0.8) : hex(0.34),
      });
    }
  }

  // "Now" is the left edge, and it is always drawn: it is the thing the scrub
  // eases back to, so it has to be visible while you are away from it.
  ops.push({ op: "rect", x: 0, y: baseline - 11, w: 1.5, h: 13, fill: hex(0.5) });

  if (!scrubbed) return ops;

  // The head, and the one extra datum the scrub is allowed: how far ahead.
  ops.push({
    op: "rect",
    x: q(head - 0.75),
    y: baseline - 13,
    w: 1.5,
    h: 15,
    fill: accent(0.95),
  });
  const hours = offset / HOUR;
  const label = hours < 1 ? `+${Math.round(hours * 60)}m` : `+${Math.round(hours)}h`;
  ops.push({
    op: "text",
    x: q(Math.min(w - 22, head + 5)),
    y: 1,
    content: label,
    size: 9,
    color: accent(0.95),
  });
  return ops;
}
