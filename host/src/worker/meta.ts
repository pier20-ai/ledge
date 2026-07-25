// App-declared metadata — `export const meta` in an app.jsx (spec §6), which the
// worker extracts after import and posts to the host thread as a `meta` message.
// The host merges it into that app's catalog entry and re-sends the FULL catalog
// snapshot (spec §3.6 — full snapshots, no diffs).
//
// This module is deliberately dependency-free: the worker imports it (so it must
// not touch the socket, framing, or envelopes), and the host thread imports it
// too, so a value that reached the host as a structured clone of app-controlled
// data is sanitized by exactly the same code on both sides.
//
// Sanitizing is about TYPES, not about policy: an app may ask for a 4000 pt wide
// panel and that request survives the host untouched. Sizing policy belongs to
// the shell, which owns the screen and clamps (spec §5).

/** The panel size an app asks for (spec §5 extension). Both fields optional:
 * `width` in points, `maxHeight` the tallest the panel may grow before content
 * clips. Omitted fields mean "shell default". */
export interface PanelSpec {
  width?: number;
  maxHeight?: number;
}

/** `export const meta = { name, icon, panel }` — every field optional, because
 * an app that declares nothing must still work (the host falls back to the
 * directory name and a placeholder icon, spec §6). */
export interface AppMeta {
  name?: string;
  icon?: string;
  panel?: PanelSpec;
}

/** Longest name/icon we put on the wire; a runaway string is an app bug, not a
 * reason to ship a 1 MiB catalog frame. */
const MAX_NAME = 64;
const MAX_ICON = 128;

function cleanString(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (trimmed.length === 0) return undefined;
  return trimmed.slice(0, limit);
}

function cleanNumber(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return undefined;
  return Math.round(value);
}

function sanitizePanel(raw: unknown): PanelSpec | undefined {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return undefined;
  const record = raw as Record<string, unknown>;
  const panel: PanelSpec = {};
  const width = cleanNumber(record.width);
  const maxHeight = cleanNumber(record.maxHeight);
  if (width !== undefined) panel.width = width;
  if (maxHeight !== undefined) panel.maxHeight = maxHeight;
  return Object.keys(panel).length > 0 ? panel : undefined;
}

/**
 * Coerce whatever an app exported as `meta` into an `AppMeta`. Tolerates
 * anything — missing, null, a string, a function, partially-typed fields — and
 * never throws: a malformed `meta` must not be the difference between an app
 * that runs and an app that doesn't.
 */
export function sanitizeAppMeta(raw: unknown): AppMeta {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return {};
  const record = raw as Record<string, unknown>;
  const meta: AppMeta = {};
  const name = cleanString(record.name, MAX_NAME);
  const icon = cleanString(record.icon, MAX_ICON);
  const panel = sanitizePanel(record.panel);
  if (name !== undefined) meta.name = name;
  if (icon !== undefined) meta.icon = icon;
  if (panel !== undefined) meta.panel = panel;
  return meta;
}
