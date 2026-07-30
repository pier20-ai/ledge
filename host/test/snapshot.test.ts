import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { renderAppCommit, shootApp } from "../src/snapshot";

// `ledge shot` (src/snapshot.ts): rendering an app to a picture with no screen.
//
// The reason it exists is worth restating where it is tested: an agent editing
// an app cannot see it, `screencapture` returns the wallpaper without a Screen
// Recording grant, and a real transcript shows an agent taking that black PNG as
// evidence. This path never touches the screen — the app is re-rendered through
// the real reconciler and replayed through the real renderer.
//
// Nothing here runs the shell binary: the process boundary is injected, so the
// suite asserts what the CLI *asks for* rather than shelling out to a build
// product that may not exist.

const DEMO_APPS = join(import.meta.dir, "..", "..", "protocol", "demo-apps");

let roots: string[] = [];
afterEach(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
});

async function tempDir(prefix = "ledge-shot-test-"): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), prefix));
  roots.push(dir);
  return dir;
}

/** A temp apps root that looks like a real one: an app, and the shared
 * node_modules its `react` resolves out of (spec §6). */
async function tempAppsRoot(source: string): Promise<string> {
  const appsRoot = await tempDir();
  await symlink(join(DEMO_APPS, "node_modules"), join(appsRoot, "node_modules"));
  await mkdir(join(appsRoot, "solo"), { recursive: true });
  await writeFile(join(appsRoot, "solo", "app.jsx"), source);
  return appsRoot;
}

describe("rendering an app without a screen", () => {
  test("a real app renders to a real commit batch", async () => {
    const dump = await renderAppCommit({ entryPath: join(DEMO_APPS, "stocks", "app.jsx") });
    expect(dump.app).toBe("stocks");
    // `meta.name`, sanitized by the same code the worker runs.
    expect(dump.name).toBe("Stocks");
    expect(dump.mutations.length).toBeGreaterThan(10);
    // A tree, not a list of orphans: something has to become the root.
    expect(dump.mutations.some((mutation) => mutation.op === "setRoot")).toBe(true);
  });

  test("--click reaches a page that only exists after pressing something", async () => {
    const entryPath = join(DEMO_APPS, "stocks", "app.jsx");
    const mount = await renderAppCommit({ entryPath });
    const clicked = await renderAppCommit({ entryPath, click: 0 });
    // The click's re-render is appended, so the batch is strictly longer and
    // ends somewhere the mount never did.
    expect(clicked.mutations.length).toBeGreaterThan(mount.mutations.length);
    expect(clicked.mutations.some((mutation) => mutation.op === "remove")).toBe(true);
  });

  test("a click index nobody offers is an error naming how many there are", async () => {
    await expect(
      renderAppCommit({ entryPath: join(DEMO_APPS, "stocks", "app.jsx"), click: 999 }),
    ).rejects.toThrow(/clickable nodes/);
  });

  test("shootApp hands the shell a commit and returns the PNG it wrote", async () => {
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
export const meta = { name: "Solo" };
export default function App() {
  return <stack axis="v" pad={14}><text content="hello" /></stack>;
}
`);
    const outDir = await tempDir("ledge-shot-out-");
    const calls: Array<{ bin: string; args: string[] }> = [];
    let handed: { name?: string } | null = null;

    const png = await shootApp({
      appsRoot,
      appId: "solo",
      outDir,
      shellBin: "/fake/LedgeShell",
      run: async (bin, args) => {
        calls.push({ bin, args });
        // Read the batch HERE: the commits directory is temporary and is swept
        // as soon as the shell is done with it.
        handed = await Bun.file(join(args[3]!, "solo.json")).json();
        // Stand in for the shell: the contract is that it writes <app>.png into
        // the output directory it was given.
        await writeFile(join(outDir, "solo.png"), "not really a png");
        return { ok: true, output: "" };
      },
    });

    expect(png).toBe(join(outDir, "solo.png"));
    expect(calls).toHaveLength(1);
    expect(calls[0]!.args[0]).toBe("--snapshots");
    expect(calls[0]!.args[1]).toBe(outDir);
    // The batch it renders is written where the shell was told to look — and
    // swept afterwards, so a `ledge shot` loop does not fill /tmp with JSON.
    // Assignment happens inside the injected async runner, which TypeScript's
    // control-flow analysis cannot follow back into this scope.
    expect((handed as { name?: string } | null)?.name).toBe("Solo");
    expect(await Bun.file(join(calls[0]!.args[3]!, "solo.json")).exists()).toBe(false);
  });

  test("a shell that writes nothing is an error, not a path to a missing file", async () => {
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
export default function App() { return <stack><text content="hi" /></stack>; }
`);
    const outDir = await tempDir("ledge-shot-out-");

    await expect(
      shootApp({
        appsRoot,
        appId: "solo",
        outDir,
        shellBin: "/fake/LedgeShell",
        run: async () => ({ ok: true, output: "" }),
      }),
    ).rejects.toThrow(/wrote no solo.png/);
  });

  test("an app that is not there says so before anything is spawned", async () => {
    const appsRoot = await tempDir();
    let ran = false;
    await expect(
      shootApp({
        appsRoot,
        appId: "ghost",
        shellBin: "/fake/LedgeShell",
        run: async () => {
          ran = true;
          return { ok: true, output: "" };
        },
      }),
    ).rejects.toThrow(/no app.jsx/);
    expect(ran).toBe(false);
  });
});
