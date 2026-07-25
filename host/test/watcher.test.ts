import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { watchApps } from "../src/watcher";

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

test("a non-app.jsx write does not trigger a reload (spec §7)", async () => {
  const { appDir, reloads } = await watchEmptyApp(50);
  await writeFile(join(appDir, "data.sqlite"), "not code");
  await writeFile(join(appDir, "notes.txt"), "scratch");
  expect(await waitFor(() => reloads.length >= 1, 600)).toBe(false);
  expect(reloads).toEqual([]);
});
