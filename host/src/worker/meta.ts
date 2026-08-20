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
//
// `meta.settings` is the same idea with a longer reach: an app declares native
// controls, the shell's Settings window draws them, and the values come back
// down as `ctx.settings`. Nothing about that surface is app-drawn, so this file
// is where "what an app may ask for" is decided — and it is decided once, for
// both sides of the Worker boundary and for the shell reading the catalog.

/** The panel size an app asks for (spec §5 extension). Both fields optional:
 * `width` in points, `maxHeight` the tallest the panel may grow before content
 * clips. Omitted fields mean "shell default". */
export interface PanelSpec {
  width?: number;
  maxHeight?: number;
}

/** What a setting can hold: the three JSON scalars and nothing else. A value
 * has to survive settings.json, a structured clone into the worker, and an
 * NSSwitch — a shape any one of those cannot carry is not a setting. */
export type SettingValue = boolean | string | number;

/** The four controls the Settings window can draw (spec §1): an NSSwitch, an
 * NSPopUpButton, an NSTextField, an NSSlider. The list is closed on purpose —
 * an app declares a control the shell already knows how to render, so nothing
 * on this side has to ship UI. */
export type SettingType = "toggle" | "choice" | "text" | "number";

/**
 * One native control an app asks the Settings window for.
 *
 * `key` is the identity — it names the value in settings.json, in the catalog's
 * `values` map, and in `ctx.settings` — so it is the one field with no fallback:
 * an entry whose key is unreadable is dropped rather than given a made-up name.
 *
 * `options` belongs to `choice` alone and `min`/`max`/`step` to `number` alone;
 * declared on another type they are dropped, because a field the shell's
 * renderer for that type never reads is a promise nothing keeps.
 */
export interface SettingSpec {
  key: string;
  label: string;
  type: SettingType;
  default?: SettingValue;
  options?: string[];
  hint?: string;
  min?: number;
  max?: number;
  step?: number;
}

/** `export const meta = { name, icon, panel, settings }` — every field optional,
 * because an app that declares nothing must still work (the host falls back to
 * the directory name and a placeholder icon, spec §6). */
export interface AppMeta {
  name?: string;
  icon?: string;
  panel?: PanelSpec;
  settings?: SettingSpec[];
}

/** Longest name/icon we put on the wire; a runaway string is an app bug, not a
 * reason to ship a 1 MiB catalog frame. */
const MAX_NAME = 64;
const MAX_ICON = 128;

/** The same reasoning, applied to the settings surface. A window with more than
 * sixteen rows in it is a preferences pane, which is not what this is; the rest
 * of the caps keep one app's declaration from filling a catalog frame. */
const MAX_SETTINGS = 16;
const MAX_LABEL = 48;
const MAX_HINT = 80;
const MAX_OPTIONS = 12;
const MIN_OPTIONS = 2;
const MAX_OPTION = 32;
/** How long a `text` value may be. The contract does not name a limit; this one
 * exists for the same reason MAX_NAME does — the value rides the catalog to the
 * shell on every snapshot. */
const MAX_TEXT = 200;
/** Lowercase, digits and hyphens, starting with a letter, at most 32 — the same
 * alphabet an app id has, because a key is read by people in a JSON file. */
const KEY_PATTERN = /^[a-z][a-z0-9-]{0,31}$/;

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

/** A number that is a number: `min`, `max` and `step` are geometry for a
 * slider, and NaN or Infinity is not a position on one. */
function cleanFinite(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return value;
}

/**
 * A `choice`'s options — the only strings here that are DATA rather than
 * display.
 *
 * So they are dropped when malformed and never truncated: an option is the
 * value that gets stored, delivered, and compared against inside the app, and a
 * silently shortened one would make `settings.format === "aac"` false for a
 * value the user picked. Fewer than two survivors is not a choice at all, which
 * is why the caller drops the whole entry when this returns nothing.
 */
function sanitizeOptions(raw: unknown): string[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const options: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string") continue;
    const trimmed = entry.trim();
    if (trimmed.length === 0 || trimmed.length > MAX_OPTION) continue;
    if (options.includes(trimmed)) continue;
    options.push(trimmed);
    if (options.length === MAX_OPTIONS) break;
  }
  return options.length >= MIN_OPTIONS ? options : undefined;
}

/**
 * Read `value` as this setting's type, or `undefined` when it is not one.
 *
 * The one place that decides what a setting may hold, so the app's declared
 * `default`, the shell's `setting` envelope (spec §4) and a hand-edited
 * settings.json are all judged by the same rules. A `number` out of range is
 * CLAMPED rather than refused — the range is the shell's slider, and a value at
 * its end is what the user was reaching for.
 */
export function coerceSettingValue(spec: SettingSpec, value: unknown): SettingValue | undefined {
  switch (spec.type) {
    case "toggle":
      return typeof value === "boolean" ? value : undefined;
    case "text":
      return typeof value === "string" ? value.slice(0, MAX_TEXT) : undefined;
    case "choice":
      // A string outside the declared options is a type mismatch, not a new
      // option: for a choice, the options ARE the type.
      return typeof value === "string" && spec.options?.includes(value) ? value : undefined;
    case "number": {
      const number = cleanFinite(value);
      if (number === undefined) return undefined;
      const floored = spec.min === undefined ? number : Math.max(spec.min, number);
      return spec.max === undefined ? floored : Math.min(spec.max, floored);
    }
  }
}

/** What this setting is worth when nobody has stored anything: the declared
 * default, or the type's own zero (spec §1 — toggle `false`, text `""`, choice
 * `options[0]`, number `min ?? 0`). */
export function defaultSettingValue(spec: SettingSpec): SettingValue {
  if (spec.default !== undefined) return spec.default;
  switch (spec.type) {
    case "toggle":
      return false;
    case "text":
      return "";
    case "choice":
      return spec.options?.[0] ?? "";
    case "number":
      return spec.min ?? 0;
  }
}

/**
 * The EFFECTIVE values for one app (spec §3): declared defaults with the stored
 * ones laid over them, one entry per declared key, always complete.
 *
 * Complete because every consumer — the shell's controls, `ctx.settings`, the
 * app reading `settings.model` — would otherwise need its own copy of the
 * default rules, and three copies of a rule is three chances to disagree.
 * Keyed off the DECLARATION, so a value left in the file by a key the app no
 * longer declares stays in the file and travels nowhere.
 */
export function effectiveSettings(
  specs: SettingSpec[] | undefined,
  stored: Record<string, unknown> | undefined,
): Record<string, SettingValue> {
  const values: Record<string, SettingValue> = {};
  for (const spec of specs ?? []) {
    const value = stored === undefined ? undefined : coerceSettingValue(spec, stored[spec.key]);
    values[spec.key] = value === undefined ? defaultSettingValue(spec) : value;
  }
  return values;
}

/**
 * One declared control, or `undefined` when it cannot be read as one.
 *
 * Everything an app can get wrong is either dropped or repaired here, never
 * thrown over: a settings surface is not worth an app that will not start. The
 * asymmetry to notice is between LABELS and VALUES — a label too long is cut
 * (it is display, and the shell has a width anyway), a value that is not of the
 * declared type is dropped (it is data, and a repaired one would be a lie).
 */
function sanitizeSetting(raw: unknown): SettingSpec | undefined {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return undefined;
  const record = raw as Record<string, unknown>;
  const key = typeof record.key === "string" ? record.key : "";
  if (!KEY_PATTERN.test(key)) return undefined;
  const label = cleanString(record.label, MAX_LABEL);
  if (label === undefined) return undefined;
  const type = record.type;
  if (type !== "toggle" && type !== "choice" && type !== "text" && type !== "number") {
    return undefined;
  }

  const spec: SettingSpec = { key, label, type };
  const hint = cleanString(record.hint, MAX_HINT);
  if (hint !== undefined) spec.hint = hint;

  if (type === "choice") {
    const options = sanitizeOptions(record.options);
    if (options === undefined) return undefined;
    spec.options = options;
  }
  if (type === "number") {
    const min = cleanFinite(record.min);
    const max = cleanFinite(record.max);
    // An inverted range is not a range: both ends go, and what is left is an
    // unbounded number field — which is still a control the user can use.
    if (min === undefined || max === undefined || min < max) {
      if (min !== undefined) spec.min = min;
      if (max !== undefined) spec.max = max;
    }
    const step = cleanFinite(record.step);
    if (step !== undefined) spec.step = step;
  }

  // Last, because a default is read through the spec it belongs to: a choice's
  // default has to be one of the options above, and a number's is clamped into
  // the range above.
  const fallback = coerceSettingValue(spec, record.default);
  if (fallback !== undefined) spec.default = fallback;
  return spec;
}

/**
 * The whole declaration. Entries are dropped one at a time — an app with one
 * bad row keeps its fifteen good ones — and the first entry to claim a key
 * keeps it, because a later duplicate would otherwise decide which of two
 * controls the user is actually looking at.
 *
 * An app that declares no usable settings gets `undefined`, not `[]`: the
 * catalog carries the field only when there is a surface to draw (spec §3).
 */
function sanitizeSettings(raw: unknown): SettingSpec[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const settings: SettingSpec[] = [];
  const keys = new Set<string>();
  for (const entry of raw) {
    const spec = sanitizeSetting(entry);
    if (!spec || keys.has(spec.key)) continue;
    keys.add(spec.key);
    settings.push(spec);
    if (settings.length === MAX_SETTINGS) break;
  }
  return settings.length > 0 ? settings : undefined;
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
  const settings = sanitizeSettings(record.settings);
  if (name !== undefined) meta.name = name;
  if (icon !== undefined) meta.icon = icon;
  if (panel !== undefined) meta.panel = panel;
  if (settings !== undefined) meta.settings = settings;
  return meta;
}
