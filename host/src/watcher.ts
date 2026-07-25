// App file watcher (spec §7): watch each app folder's `app.jsx` ONLY — app data
// files and `.build/` never trigger a reload — and debounce rapid saves before
// firing. We watch the *folder* (not the file) and filter on the name so an
// editor's write-temp-then-rename save, which replaces the inode, still fires;
// a direct file watch would go dead after the first rename.

import { watch, type FSWatcher } from "node:fs";
import { join } from "node:path";

export interface AppWatcherOptions {
  appsRoot: string;
  /** App ids (folder names) to watch. */
  apps: string[];
  /** Coalesce bursts of save events (default 120 ms). */
  debounceMs?: number;
  /** Called (debounced) when an app's app.jsx changed. */
  onReload: (appId: string) => void;
  /** Called if watching a folder fails (missing dir, etc.). */
  onError?: (appId: string, error: unknown) => void;
}

/** Start watching; returns a stop function that closes watchers and cancels any
 * pending debounced reloads. */
export function watchApps(options: AppWatcherOptions): () => void {
  const debounceMs = options.debounceMs ?? 120;
  const timers = new Map<string, ReturnType<typeof setTimeout>>();
  const watchers: FSWatcher[] = [];

  for (const appId of options.apps) {
    const dir = join(options.appsRoot, appId);
    try {
      const watcher = watch(dir, (_event, filename) => {
        // fs.watch reports the changed entry's name; only app.jsx counts (§7).
        if (filename !== "app.jsx") return;
        const existing = timers.get(appId);
        if (existing) clearTimeout(existing);
        timers.set(
          appId,
          setTimeout(() => {
            timers.delete(appId);
            options.onReload(appId);
          }, debounceMs),
        );
      });
      watchers.push(watcher);
    } catch (error) {
      options.onError?.(appId, error);
    }
  }

  return () => {
    for (const timer of timers.values()) clearTimeout(timer);
    timers.clear();
    for (const watcher of watchers) watcher.close();
  };
}
