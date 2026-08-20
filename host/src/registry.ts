// App registry (spec §6): one folder = one app; the directory name is the
// canonical app id; app.jsx is the entry and the only file the host watches.

import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { NO_DISABLED_APPS } from "./settings";
import {
  sanitizeAppMeta,
  type AppMeta,
  type PanelSpec,
  type SettingSpec,
  type SettingValue,
} from "./worker/meta";

/** One row of the `catalog` snapshot (spec §3.6). `panel` is the app's declared
 * panel size (spec §5 extension) — absent means "shell default"; present is a
 * *request*, which the shell clamps to what the screen can hold. */
export interface CatalogApp {
  id: string;
  name: string;
  icon: string;
  order: number;
  enabled: boolean;
  running: boolean;
  panel?: PanelSpec;
  /** The native controls this app declared (`meta.settings`), sanitized. Absent
   * — not empty — for an app that declares none: the Settings window draws a
   * section for a row that has one, and nothing at all for a row that does not. */
  settings?: SettingSpec[];
  /** What those controls are currently set to: one entry per declared key,
   * always complete (the router builds it; see `effectiveSettings`). Travels
   * with `settings` and never without it. */
  values?: Record<string, SettingValue>;
}

export const DEFAULT_ROOT = join(
  process.env.HOME ?? "~",
  ".ledge",
  "apps",
);

const DEFAULT_ICON = "sf:square.dashed";

/** The fallback identity for an app that has not declared (or has not yet
 * declared) a `meta`: the capitalized directory name and a placeholder icon. */
export function fallbackIdentity(id: string): { name: string; icon: string } {
  return { name: id.charAt(0).toUpperCase() + id.slice(1), icon: DEFAULT_ICON };
}

/**
 * Merge an app's declared `meta` (spec §6) over its registry entry. Only fields
 * the app actually declared win — a `meta` without a name keeps the dirname
 * fallback, which is what makes `meta` optional in practice.
 */
export function applyMeta(app: CatalogApp, meta: AppMeta | undefined): CatalogApp {
  if (!meta) return app;
  const merged: CatalogApp = { ...app };
  if (meta.name !== undefined) merged.name = meta.name;
  if (meta.icon !== undefined) merged.icon = meta.icon;
  if (meta.panel !== undefined) merged.panel = meta.panel;
  // The declaration only; `values` needs the settings file, which the registry
  // does not have and should not read (see `scanApps` on `disabled`).
  if (meta.settings !== undefined) merged.settings = meta.settings;
  return merged;
}

/**
 * Validate one catalog row coming off the wire (the golden fixtures, and any
 * future non-registry producer). Throws on a row that could not have come from
 * `scanApps` + `applyMeta`; `panel` is optional and type-checked the same way
 * the worker sanitizes it.
 */
export function parseCatalogApp(raw: unknown): CatalogApp {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new TypeError("catalog entry must be a JSON object");
  }
  const record = raw as Record<string, unknown>;
  const { id, name, icon, order, enabled, running } = record;
  if (typeof id !== "string" || id.length === 0) throw new TypeError("catalog.id must be a non-empty string");
  if (typeof name !== "string") throw new TypeError("catalog.name must be a string");
  if (typeof icon !== "string") throw new TypeError("catalog.icon must be a string");
  if (typeof order !== "number" || !Number.isInteger(order)) throw new TypeError("catalog.order must be an integer");
  if (typeof enabled !== "boolean") throw new TypeError("catalog.enabled must be a boolean");
  if (typeof running !== "boolean") throw new TypeError("catalog.running must be a boolean");

  const app: CatalogApp = { id, name, icon, order, enabled, running };
  if (record.panel !== undefined) {
    // Reuse the app-meta sanitizer so "what a panel may say" has exactly one
    // definition on this side of the wire.
    const panel = sanitizeAppMeta({ panel: record.panel }).panel;
    if (!panel) throw new TypeError("catalog.panel must declare a positive width and/or maxHeight");
    app.panel = panel;
  }
  return app;
}

/** Scans `root` for app folders (any directory containing app.jsx).
 *
 * Name/icon/panel come from the app's `export const meta`, which only the app's
 * own worker can evaluate (the host thread never imports app code) — so a scan
 * produces the dirname fallback, and the router merges each worker's `meta`
 * message over it before the snapshot goes out (spec §3.6). Order is
 * alphabetical until Settings owns persistence.
 *
 * `disabled` is the host's settings file (src/settings.ts), passed in rather
 * than read here: a scan is a filesystem question, and threading the answer
 * through keeps "who may write this" in the one place that does write it.
 * Absent means every app found is enabled, which is what a machine with no
 * settings file yet is.
 */
export async function scanApps(
  root: string = DEFAULT_ROOT,
  disabled: ReadonlySet<string> = NO_DISABLED_APPS,
): Promise<CatalogApp[]> {
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }

  const apps: CatalogApp[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
    if (!(await Bun.file(join(root, entry.name, "app.jsx")).exists())) continue;
    apps.push({
      id: entry.name,
      ...fallbackIdentity(entry.name),
      order: apps.length,
      enabled: !disabled.has(entry.name),
      running: false,
    });
  }
  apps.sort((a, b) => a.id.localeCompare(b.id));
  apps.forEach((app, index) => {
    app.order = index;
  });
  return apps;
}
