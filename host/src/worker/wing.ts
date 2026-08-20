// Wings — the collapsed notch as a live-activity surface an app can own
// (spec §3.3 extension; proposed in protocol/README.md). An app posts a wing
// spec with `ctx.wing(spec)` and releases it with `ctx.wing(null)`.
//
// Like `meta.ts` this module is dependency-free and shared by the worker and the
// host thread, so app-controlled data is sanitized by the same code on both
// sides. Type sanitation only — the *clamps* (how wide a wing may actually get)
// belong to the shell, which owns the notch.

/** A drawable strip in the right wing. `id` is the app's own canvas node id —
 * the same id its `ctx.draw(id, ops)` frames target (spec §3.4), so a wing
 * canvas and an in-panel canvas can be the same node drawn in two places. */
export interface WingCanvas {
  id: number;
  /** Requested width in points; the shell clamps it (~160 pt per wing). */
  w: number;
}

/**
 * A **meter** — flow.md's third wing form (glyph / ticker / meter / canvas),
 * and the one every app used to hand-draw. `value` is a fraction of the whole,
 * `0…1`; the shell owns the bar's width, thickness, radius and ink, which is
 * what makes two apps' meters look like one system.
 *
 * Out-of-range values clamp rather than being dropped: a progress that briefly
 * computes 1.02 is a full bar, not a wing that blinks out.
 */
export interface WingMeter {
  value: number;
}

/**
 * What an app wants the collapsed notch to look like.
 *
 * - `text`   — a short label in the LEFT wing.
 * - `canvas` — a drawable strip in the RIGHT wing (height = notch height).
 * - `meter`  — a shell-drawn progress bar in the RIGHT wing. The stock form of
 *              the thing a canvas would otherwise be used for.
 * - `width`  — the total collapsed pill width in points. On its own (no text, no
 *              canvas) it is a bare shape request: pure geometry, no content —
 *              which is the whole of the breathing-pacer app.
 *
 * An empty object is a valid "wing with nothing in it"; `null` (not a spec)
 * releases the notch.
 */
export interface WingSpec {
  text?: string;
  width?: number;
  canvas?: WingCanvas;
  meter?: WingMeter;
}

/** A wing label is a glance, not a paragraph. */
const MAX_TEXT = 48;

/**
 * Coerce an app-supplied wing into a `WingSpec`, or `null` for "clear". Anything
 * that isn't an object clears, so `ctx.wing(null)` and `ctx.wing(undefined)`
 * behave the same. Never throws.
 */
export function sanitizeWing(raw: unknown): WingSpec | null {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
  const record = raw as Record<string, unknown>;
  const wing: WingSpec = {};

  if (typeof record.text === "string") {
    const text = record.text.trim();
    if (text.length > 0) wing.text = text.slice(0, MAX_TEXT);
  }
  if (typeof record.width === "number" && Number.isFinite(record.width) && record.width > 0) {
    wing.width = Math.round(record.width);
  }
  const canvas = record.canvas;
  if (typeof canvas === "object" && canvas !== null && !Array.isArray(canvas)) {
    const { id, w } = canvas as Record<string, unknown>;
    if (typeof id === "number" && Number.isInteger(id) && id > 0) {
      const width = typeof w === "number" && Number.isFinite(w) && w > 0 ? Math.round(w) : 0;
      if (width > 0) wing.canvas = { id, w: width };
    }
  }
  const meter = record.meter;
  if (typeof meter === "object" && meter !== null && !Array.isArray(meter)) {
    const { value } = meter as Record<string, unknown>;
    // Clamped, not rejected: a meter is a fraction of a whole and an app that
    // divides by a total it just changed can produce 1.02 for one frame. NaN is
    // the one value with no sensible reading, so it is dropped.
    if (typeof value === "number" && Number.isFinite(value)) {
      wing.meter = { value: Math.min(1, Math.max(0, value)) };
    }
  }
  return wing;
}
