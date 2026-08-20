import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isAppSource, watchApps } from "../src/watcher";

// The file watcher (spec §7): app.jsx changes reload (debounced); other files do
// not. Uses real fs events on a temp dir. To dodge FSEvents' habit of replaying
// a just-created file to a freshly-attached watcher, each test starts watching an
// EMPTY app folder and drains before writing, so only its own writes are observed.

let cleanup: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const fn of cleanup) await fn();
  cleanup = [];
});

async function watchEmptyApp(debounceMs: number): Promise<{ appDir: string; reloads: string[] }> {
  const root = await mkdtemp(join(tmpdir(), "ledge-watch-"));
  const appDir = join(root, "app");
  await mkdir(appDir, { recursive: true });
  cleanup.push(() => rm(root, { recursive: true, force: true }));

  const reloads: string[] = [];
  const stop = watchApps({ appsRoot: root, apps: ["app"], debounceMs, onReload: (id) => reloads.push(id) });
  cleanup.push(stop);
  await Bun.sleep(150); // let the watcher attach and any replayed events drain
  return { appDir, reloads };
}

async function waitFor(predicate: () => boolean, timeoutMs = 3000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await Bun.sleep(25);
  }
  return false;
}

test("an app.jsx write triggers a reload", async () => {
  const { appDir, reloads } = await watchEmptyApp(50);
  await writeFile(join(appDir, "app.jsx"), "export default function(){}\n");
  expect(await waitFor(() => reloads.length >= 1)).toBe(true);
  expect(reloads.every((id) => id === "app")).toBe(true);
});

test("rapid saves coalesce into a single reload (debounce)", async () => {
  const { appDir, reloads } = await watchEmptyApp(200);
  // Three writes in a tight burst — all inside the 200 ms debounce window.
  await writeFile(join(appDir, "app.jsx"), "export default function(){ /* v1 */ }\n");
  await writeFile(join(appDir, "app.jsx"), "export default function(){ /* v2 */ }\n");
  await writeFile(join(appDir, "app.jsx"), "export default function(){ /* v3 */ }\n");
  expect(await waitFor(() => reloads.length >= 1)).toBe(true);
  await Bun.sleep(300); // past the debounce window; no further reloads should land
  expect(reloads).toEqual(["app"]);
});

test("a data-file write does not trigger a reload (spec §7)", async () => {
  const { appDir, reloads } = await watchEmptyApp(50);
  await writeFile(join(appDir, "data.sqlite"), "not code");
  await writeFile(join(appDir, "notes.txt"), "scratch");
  expect(await waitFor(() => reloads.length >= 1, 600)).toBe(false);
  expect(reloads).toEqual([]);
});

// An app is no longer assumed to be exactly one file: an agent that splits a
// growing app into modules must still get a hot reload, or its edits look
// ignored. The flip side is that everything an app WRITES lives in the same
// folder, so the predicate has to be exact — a monitor caching prices to JSON
// that reloaded the worker which wrote them is a reload loop with a network
// call in it.
test("source siblings reload; app-owned data and editor droppings do not", () => {
  for (const name of ["app.jsx", "board.jsx", "engine.js", "shared.ts", "ui.tsx"]) {
    expect(isAppSource(name)).toBe(true);
  }
  for (const name of [
    "prices.json",         // a monitor's cache
    "ledger.sqlite",
    "ledger.sqlite-wal",   // WAL churns constantly while an app runs
    "ledger.sqlite-shm",
    "crash.log",
    "art-6yqi8s7.jpg",
    ".builder.json",       // Ledge's own session pointer
    ".DS_Store",
    "app.jsx~",            // editor backup
    ".app.jsx.swp",        // vim swapfile
    "node_modules",        // fs.watch reports the top entry for deep writes
    ".build",
  ]) {
    expect(isAppSource(name)).toBe(false);
  }
});

// Creating an app is not atomic. An agent makes the folder, then writes
// app.jsx — and the gap can easily outlast the debounce. The rescan that the
// folder triggers correctly ignores a directory with no entry point, so unless
// that directory is ALSO being watched, the app.jsx landing later is seen by
// nobody and the app stays invisible until the host restarts.
test("an app.jsx written well after its folder still notifies", async () => {
  const root = await mkdtemp(join(tmpdir(), "ledge-watch-slow-"));
  cleanup.push(() => rm(root, { recursive: true, force: true }));

  let changes = 0;
  const stop = watchApps({
    appsRoot: root,
    apps: [],
    debounceMs: 50,
    onReload: () => {},
    onAppsChanged: () => {
      changes += 1;
    },
  });
  cleanup.push(stop);
  await Bun.sleep(150);

  await mkdir(join(root, "flights"), { recursive: true });
  // Long enough for the folder's own rescan to have run and dismissed it.
  await Bun.sleep(350);
  const afterFolder = changes;

  await writeFile(join(root, "flights", "app.jsx"), "export default function(){}\n");
  expect(await waitFor(() => changes > afterFolder)).toBe(true);
});

test("a new app folder notifies the root watcher", async () => {
  const root = await mkdtemp(join(tmpdir(), "ledge-watch-root-"));
  cleanup.push(() => rm(root, { recursive: true, force: true }));

  let changes = 0;
  const stop = watchApps({
    appsRoot: root,
    apps: [],
    debounceMs: 50,
    onReload: () => {},
    onAppsChanged: () => {
      changes += 1;
    },
  });
  cleanup.push(stop);
  await Bun.sleep(150);

  // What `ledge new` and an agent scaffolding an app both look like on disk.
  await mkdir(join(root, "flights"), { recursive: true });
  await writeFile(join(root, "flights", "app.jsx"), "export default function(){}\n");

  expect(await waitFor(() => changes >= 1)).toBe(true);
});
