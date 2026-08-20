// Ledge's own durable state: which apps the user turned off (spec §3.6
// `enabled`, §8 "Settings … can enable/disable apps"), and what the user set
// each app's declared controls to (`meta.settings`, spec §2).
//
// It lives BESIDE the apps root — `~/.ledge/settings.json` in a real install —
// and never inside an app's folder. An app owns its folder (spec §6), and
// "may this app run" is the one fact about an app that the app itself must not
// be able to edit.
//
// The file records DISABLED ids, not enabled ones, because the default is on:
// an app installed while Ledge is running (the builder scaffolds one, spec §8)
// must start without anybody having written its name down first, and a settings
// file that has never been created has to mean "everything runs" rather than
// "nothing does".
//
// Every id is treated alike. There used to be one exemption — the `settings`
// app, which could not be switched off because it was the only surface that
// could switch anything back on — and it went when Settings became a native
// macOS window in the shell (spec §8), which nothing written here can reach.

import { dirname, join } from "node:path";
import { rename } from "node:fs/promises";
import type { SettingValue } from "./worker/meta";

/**
 * The on-disk shape. Two keys, and both are things only the user decides:
 * which apps are off, and what their controls are set to. Everything else the
 * Settings window shows is derived from the registry, and a setting nobody
 * honours is a switch that lies.
 *
 * `values` is keyed app → key → scalar. Nothing prunes it: a key an app has
 * stopped declaring keeps its value here (an app may declare it again next
 * version, and forgetting the user's choice on an upgrade is worse than a dead
 * line of JSON) but never reaches the shell or the worker — see the router,
 * which builds every effective map from the DECLARATION.
 */
interface SettingsFile {
  disabled?: unknown;
  values?: unknown;
}

const EMPTY: ReadonlySet<string> = new Set();

/**
 * The host's settings file, held in memory between writes.
 *
 * The host is the only writer, so the in-memory set IS the truth after `load`;
 * re-reading before every scan would only buy the ability for something else to
 * edit the file underneath us, which nothing does.
 */
export class SettingsStore {
  private readonly file: string;
  private disabledIds = new Set<string>();
  /** app id → key → value, exactly as the file holds it. Undeclared keys are
   * filtered where the declaration is known (the router), never here: this
   * object's job is to remember, not to judge. */
  private values = new Map<string, Record<string, SettingValue>>();
  /**
   * One durable mutation at a time.
   *
   * UI events are independent async requests, so two quick switches can reach
   * this object together. Chaining them makes each mutation observe the state
   * committed by the one before it and keeps the shared atomic temp path single
   * writer. A rejected write is swallowed only by the tail; its caller still
   * receives the rejection, while later settings remain usable.
   */
  private mutationTail: Promise<void> = Promise.resolve();

  constructor(path: string) {
    this.file = path;
  }

  /** Where the settings file goes for a given apps root: one level up, next to
   * the socket and the host log. `~/.ledge/apps` → `~/.ledge/settings.json`. */
  static pathFor(appsRoot: string): string {
    return join(dirname(appsRoot), "settings.json");
  }

  get path(): string {
    return this.file;
  }

  /** Ids the user has turned off. Empty until `load`. */
  get disabled(): ReadonlySet<string> {
    return this.disabledIds;
  }

  isEnabled(appId: string): boolean {
    return !this.disabledIds.has(appId);
  }

  /** What the user has set for one app, as stored. A fresh copy, because the
   * caller overlays defaults on it and a caller that mutated the store while
   * doing so would rewrite history it never wrote. */
  valuesFor(appId: string): Record<string, SettingValue> {
    return { ...(this.values.get(appId) ?? {}) };
  }

  /**
   * Read the file, tolerating everything an absent or hand-edited one can be.
   *
   * A malformed settings file must not stop Ledge from starting: the failure
   * mode of "I could not parse this" is every app enabled, which is the same
   * state a fresh install is in, and the user can see and fix it. Refusing to
   * boot over it would strand them with no way in to repair it.
   */
  async load(): Promise<void> {
    let parsed: SettingsFile | null = null;
    try {
      parsed = (await Bun.file(this.file).json()) as SettingsFile;
    } catch {
      parsed = null;
    }
    const disabled = new Set<string>();
    if (parsed && Array.isArray(parsed.disabled)) {
      for (const id of parsed.disabled) {
        if (typeof id === "string" && id.length > 0) disabled.add(id);
      }
    }
    // Every id in the file is honoured, with no exemptions. There used to be
    // one — the `settings` app was forced back on however the file was edited,
    // because it was the only surface that could undo a switch. Settings is a
    // native macOS window in the shell now (spec §8), so the way back is not an
    // app any more and cannot be disabled by anything written here.
    this.disabledIds = disabled;
    this.values = readValues(parsed?.values);
  }

  /**
   * Turn one app on or off and persist it. Resolves once the file is on disk,
   * so the caller can tell an app "done" and mean it.
   */
  setEnabled(appId: string, enabled: boolean): Promise<void> {
    const mutation = this.mutationTail.then(async () => {
      if (enabled === this.isEnabled(appId)) return;
      const next = new Set(this.disabledIds);
      if (enabled) next.delete(appId);
      else next.add(appId);
      await this.write(next, this.values);
      this.disabledIds = next;
    });
    this.mutationTail = mutation.catch(() => {});
    return mutation;
  }

  /**
   * Record one app's setting and persist it. Persist-first, like `setEnabled`:
   * the caller tells the worker and the shell about a value only once the file
   * says the same thing, so a host that dies in between comes back agreeing
   * with what the user last saw.
   *
   * The value is stored as given. Whether it is a value this app may hold is
   * decided against the app's declared spec by the caller (the router, spec
   * §4), which is the only place that knows the declaration.
   */
  setValue(appId: string, key: string, value: SettingValue): Promise<void> {
    const mutation = this.mutationTail.then(async () => {
      const current = this.values.get(appId);
      if (current && current[key] === value) return;
      const next = new Map(this.values);
      next.set(appId, { ...(current ?? {}), [key]: value });
      await this.write(this.disabledIds, next);
      this.values = next;
    });
    this.mutationTail = mutation.catch(() => {});
    return mutation;
  }

  /** Write-temp-then-rename, the same atomicity rule apps are given for their
   * own JSON (spec §6): a host killed mid-write must not leave a truncated file
   * that reads as "nothing is disabled" on the next launch.
   *
   * `values` is written only once there is one, so a machine where nobody has
   * touched a control keeps the file it has always had. */
  private async write(
    disabled: ReadonlySet<string>,
    values: ReadonlyMap<string, Record<string, SettingValue>>,
  ): Promise<void> {
    const file: SettingsFile = { disabled: [...disabled].sort() };
    if (values.size > 0) {
      file.values = Object.fromEntries([...values].sort(([a], [b]) => a.localeCompare(b)));
    }
    const body = JSON.stringify(file, null, 2);
    const temp = `${this.file}.tmp`;
    await Bun.write(temp, `${body}\n`);
    await rename(temp, this.file);
  }
}

/**
 * Read the `values` half of the file, tolerating everything a hand-edited one
 * can be — the same rule the `disabled` list is read by, for the same reason.
 *
 * Non-scalars are dropped here rather than at delivery: a value that could not
 * have been written by `setValue` is not a setting anybody chose, and letting
 * one through would put an object where an app expects a string.
 */
function readValues(raw: unknown): Map<string, Record<string, SettingValue>> {
  const values = new Map<string, Record<string, SettingValue>>();
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return values;
  for (const [appId, entry] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) continue;
    const kept: Record<string, SettingValue> = {};
    for (const [key, value] of Object.entries(entry as Record<string, unknown>)) {
      if (typeof value === "boolean" || typeof value === "string") kept[key] = value;
      else if (typeof value === "number" && Number.isFinite(value)) kept[key] = value;
    }
    if (Object.keys(kept).length > 0) values.set(appId, kept);
  }
  return values;
}

/** A store that owns nothing, for the paths that scan without one (the CLI,
 * tests that only care about what is on disk). */
export const NO_DISABLED_APPS = EMPTY;
