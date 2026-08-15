// Ledge's own durable state — today, exactly one fact: which apps the user
// turned off (spec §3.6 `enabled`, §8 "Settings … can enable/disable apps").
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

/** The on-disk shape. Deliberately one key: everything else the Settings window
 * shows is derived from the registry, and a setting nobody honours is a switch
 * that lies. */
interface SettingsFile {
  disabled?: unknown;
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
      await this.write(next);
      this.disabledIds = next;
    });
    this.mutationTail = mutation.catch(() => {});
    return mutation;
  }

  /** Write-temp-then-rename, the same atomicity rule apps are given for their
   * own JSON (spec §6): a host killed mid-write must not leave a truncated file
   * that reads as "nothing is disabled" on the next launch. */
  private async write(disabled: ReadonlySet<string>): Promise<void> {
    const body = JSON.stringify({ disabled: [...disabled].sort() }, null, 2);
    const temp = `${this.file}.tmp`;
    await Bun.write(temp, `${body}\n`);
    await rename(temp, this.file);
  }
}

/** A store that owns nothing, for the paths that scan without one (the CLI,
 * tests that only care about what is on disk). */
export const NO_DISABLED_APPS = EMPTY;
