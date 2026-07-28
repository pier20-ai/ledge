// App file watcher (spec §7). Two jobs, both debounced:
//
//   1. **Per app** — reload when the app's own source changes. We watch the
//      *folder* (not the file) and filter on the name, so an editor's
//      write-temp-then-rename save, which replaces the inode, still fires; a
//      direct file watch would go dead after the first rename.
//   2. **The apps root** — notice folders appearing and disappearing, so an app
//      an agent just scaffolded shows up without restarting the host.

import { readdirSync, watch, type Dirent, type FSWatcher } from "node:fs";
import { join } from "node:path";

/**
 * Extensions that count as an app's source.
 *
 * The spec says the host watches `app.jsx` "only", and that was right when an
 * app *was* one file. It stops being right the moment an agent does the normal
 * thing and splits a growing app into `board.jsx` + `engine.js` — those edits
 * would hot-reload nothing, and the app would appear to ignore the change.
 */
const SOURCE_EXTENSIONS = [".jsx", ".js", ".ts", ".tsx", ".mjs", ".cjs"];

/**
 * Folder names whose contents must never trigger a reload.
 *
 * `fs.watch` on a directory reports the *direct entry* that changed, so a write
 * deep inside `node_modules` surfaces here as the string "node_modules".
 */
const IGNORED_ENTRIES = new Set([".build", "node_modules", ".git"]);

/** True when a changed entry should reload the app. */
export function isAppSource(filename: string): boolean {
  if (!filename) return false;
  // Editors write `.app.jsx.swp`, `.#app.jsx`, `app.jsx~`; none are the source.
  if (filename.startsWith(".") || filename.endsWith("~")) return false;
  if (IGNORED_ENTRIES.has(filename)) return false;
  // Anything the app itself writes is data, not source (spec §6: apps own their
  // persistence, and they keep it next to app.jsx). A monitor caching prices to
  // JSON must not restart the worker that wrote them — that is a reload loop
  // with a network call in it.
  return SOURCE_EXTENSIONS.some((extension) => filename.endsWith(extension));
}

export interface AppWatcherOptions {
  appsRoot: string;
  /** App ids (folder names) to watch. */
  apps: string[];
  /** Coalesce bursts of save events (default 120 ms). */
  debounceMs?: number;
  /** Called (debounced) when an app's source changed. */
  onReload: (appId: string) => void;
  /** Called (debounced) when the set of folders under the apps root may have
   * changed. The callback is expected to rescan and diff — this fires on any
   * root-level activity, not only on a genuine add or remove. */
  onAppsChanged?: () => void;
  /** Called if watching a folder fails (missing dir, etc.). */
  onError?: (appId: string, error: unknown) => void;
}

/** Start watching; returns a stop function that closes watchers and cancels any
 * pending debounced work. */
export function watchApps(options: AppWatcherOptions): () => void {
  const debounceMs = options.debounceMs ?? 120;
  const timers = new Map<string, ReturnType<typeof setTimeout>>();
  const watchers: FSWatcher[] = [];

  /** One pending call per key; a burst of saves collapses to a single fire. */
  const schedule = (key: string, run: () => void) => {
    const existing = timers.get(key);
    if (existing) clearTimeout(existing);
    timers.set(
      key,
      setTimeout(() => {
        timers.delete(key);
        run();
      }, debounceMs),
    );
  };

  const known = new Set(options.apps);
  /** Directories already being watched, so re-syncing is idempotent. */
  const watchedDirs = new Set<string>();

  /**
   * Watch one directory under the apps root.
   *
   * **Every** directory, not only the valid apps — this is what closes the
   * scaffold race. Creating an app is not atomic: an agent (or `ledge new`, or
   * a human with a text editor) makes the folder first and writes `app.jsx` a
   * moment later. The root watcher fires on the folder, the debounced rescan
   * finds a directory with no entry point and correctly ignores it — and if the
   * only watchers we ever attached were for *valid* apps, the `app.jsx` that
   * lands 350 ms later is seen by nobody and the app stays invisible until the
   * host restarts.
   *
   * So a source write in a directory we do not recognise triggers a rescan
   * rather than a reload: the same signal, routed by what the directory has
   * become rather than by what it was when we attached.
   */
  const watchDirectory = (name: string) => {
    if (watchedDirs.has(name)) return;
    const dir = join(options.appsRoot, name);
    try {
      const watcher = watch(dir, (_event, filename) => {
        if (!filename || !isAppSource(filename)) return;
        if (known.has(name)) {
          schedule(`app:${name}`, () => options.onReload(name));
        } else if (options.onAppsChanged) {
          schedule("root", options.onAppsChanged);
        }
      });
      watchers.push(watcher);
      watchedDirs.add(name);
    } catch (error) {
      options.onError?.(name, error);
    }
  };

  /** Attach watchers to any directory that does not have one yet. */
  const syncDirectories = () => {
    let entries: Dirent[];
    try {
      entries = readdirSync(options.appsRoot, { withFileTypes: true });
    } catch (error) {
      options.onError?.("", error);
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      // Not apps: the shared dependency tree and build output (spec §6).
      if (entry.name.startsWith(".") || IGNORED_ENTRIES.has(entry.name)) continue;
      watchDirectory(entry.name);
    }
  };

  // Known apps first, so an app whose folder somehow can't be listed is still
  // watched, then everything else on disk.
  for (const appId of options.apps) watchDirectory(appId);
  syncDirectories();

  // The apps root itself: `ledge new`, an agent scaffolding a folder, or a
  // deletion. Without this the registry is whatever it was at connect time, and
  // a brand-new app is invisible until the host restarts — which is exactly the
  // moment the builder is trying to show the user what it just made.
  if (options.onAppsChanged) {
    const onAppsChanged = options.onAppsChanged;
    try {
      const rootWatcher = watch(options.appsRoot, () => {
        // Attach to any folder that just appeared BEFORE the debounce, so a
        // fast scaffold is covered by a watcher even though the rescan it also
        // schedules has not run yet.
        syncDirectories();
        // No filtering: a rename can arrive with a stale or absent name, and a
        // rescan is cheap next to missing an app. The router diffs the result.
        schedule("root", onAppsChanged);
      });
      watchers.push(rootWatcher);
    } catch (error) {
      options.onError?.("", error);
    }
  }

  return () => {
    for (const timer of timers.values()) clearTimeout(timer);
    timers.clear();
    for (const watcher of watchers) watcher.close();
  };
}
