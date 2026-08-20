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

/**
 * A two-page app, for the `--click` assertions.
 *
 * It used to be a demo app, but "which shipped app happens to change its tree
 * on its first button" is not a property the snapshot path should depend on —
 * the demo set turned over once and took the test with it. What `--click` has
 * to do is press a node and append the re-render, and a fixture states that
 * without borrowing anybody's design. The page lives in `useState`, exactly as
 * REFERENCE.md tells app authors to write one.
 */
const TWO_PAGES = `/** @jsxImportSource react */
import { useState } from "react";
export const meta = { name: "Pages" };
export default function App() {
  const [open, setOpen] = useState(false);
  return open
    ? <stack axis="v" pad={14}><text content="detail" /></stack>
    : <stack axis="v" pad={14}>
        <text content="list" />
        <button label="open" onClick={() => setOpen(true)} />
      </stack>;
}
`;

/** Every `text` string in a batch — what the picture would actually say. */
function contents(mutations: Awaited<ReturnType<typeof renderAppCommit>>["mutations"]): string[] {
  return mutations.flatMap((mutation) =>
    (mutation.op === "create" || mutation.op === "update") &&
    typeof mutation.props.content === "string"
      ? [mutation.props.content]
      : [],
  );
}

describe("rendering an app without a screen", () => {
  test("a real app renders to a real commit batch", async () => {
    const dump = await renderAppCommit({ entryPath: join(DEMO_APPS, "timer", "app.jsx") });
    expect(dump.app).toBe("timer");
    // `meta.name`, sanitized by the same code the worker runs.
    expect(dump.name).toBe("Alarms");
    expect(dump.mutations.length).toBeGreaterThan(10);
    // A tree, not a list of orphans: something has to become the root.
    expect(dump.mutations.some((mutation) => mutation.op === "setRoot")).toBe(true);
  });

  test("--click reaches a page that only exists after pressing something", async () => {
    const appsRoot = await tempAppsRoot(TWO_PAGES);
    const entryPath = join(appsRoot, "solo", "app.jsx");
    const mount = await renderAppCommit({ entryPath });
    const clicked = await renderAppCommit({ entryPath, click: 0 });
    // The click's re-render is appended, so the batch is strictly longer and
    // ends somewhere the mount never did.
    expect(clicked.mutations.length).toBeGreaterThan(mount.mutations.length);
    expect(clicked.mutations.some((mutation) => mutation.op === "remove")).toBe(true);
  });

  test("a click index nobody offers is an error naming how many there are", async () => {
    await expect(
      renderAppCommit({ entryPath: join(DEMO_APPS, "timer", "app.jsx"), click: 999 }),
    ).rejects.toThrow(/clickable nodes/);
  });

  // `--props`: every data-driven app has an empty state and a real one, and the
  // real one used to need a throwaway preview module beside the app — a second
  // source of truth about what the app looks like.
  test("--props mounts the state a monitor would have produced", async () => {
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
export const meta = { name: "Solo" };
export default function App({ track = null }) {
  return track
    ? <stack axis="v"><text content={track.title} /></stack>
    : <stack axis="v"><text content="nothing playing" /></stack>;
}
`);
    const entryPath = join(appsRoot, "solo", "app.jsx");

    const empty = await renderAppCommit({ entryPath });
    expect(contents(empty.mutations)).toContain("nothing playing");

    const loaded = await renderAppCommit({
      entryPath,
      props: { track: { title: "Rhubarb" } },
    });
    expect(contents(loaded.mutations)).toContain("Rhubarb");
    expect(contents(loaded.mutations)).not.toContain("nothing playing");
  });

  // `--wing`: an app's *signature* — what it puts in the collapsed pill — is
  // never in the mount tree, because a wing is published imperatively.
  test("--wing keeps the wing and the frame the monitor drew into it", async () => {
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
export const meta = { name: "Solo" };
let node = null;
export async function monitor(ctx) {
  ctx.wing({ text: "NTS 2", canvas: { id: node.id, w: 40 } });
  ctx.draw(node.id, [{ op: "clear" }, { op: "rect", x: 0, y: 0, w: 4, h: 8 }]);
  await new Promise(() => {});
}
export default function App() {
  return <stack axis="v"><canvas ref={(n) => { node = n; }} w={40} h={34} /></stack>;
}
`);
    const entryPath = join(appsRoot, "solo", "app.jsx");

    // Without the flag the monitor never runs, and the dump is panel-only.
    const plain = await renderAppCommit({ entryPath });
    expect(plain.wing).toBeUndefined();

    const winged = await renderAppCommit({ entryPath, wing: true, wingMs: 120 });
    expect(winged.wing).toEqual({ text: "NTS 2", canvas: { id: 1, w: 40 } });
    // The ops are the app's own §3.4 frame, keyed to the wing's canvas node.
    expect(winged.wingOps).toEqual([
      { op: "clear" },
      { op: "rect", x: 0, y: 0, w: 4, h: 8 },
    ]);
  });

  test("--wing falls back to a canvas the app drew but never claimed a wing for", async () => {
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
let node = null;
export async function monitor(ctx) {
  ctx.draw(node.id, [{ op: "rect", x: 0, y: 0, w: 2, h: 2 }]);
  await new Promise(() => {});
}
export default function App() {
  return <stack axis="v"><canvas ref={(n) => { node = n; }} w={28} h={34} /></stack>;
}
`);
    // The strip an app mirrors into the panel IS the wing it would hold while
    // it is live; a snapshot of the resting frame is worth more than nothing.
    const winged = await renderAppCommit({
      entryPath: join(appsRoot, "solo", "app.jsx"),
      wing: true,
      wingMs: 120,
    });
    expect(winged.wing).toEqual({ canvas: { id: 1, w: 28 } });
    expect(winged.wingOps).toHaveLength(1);
  });

  test("--wing on an app whose monitor cannot get going captures nothing, quietly", async () => {
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
export async function monitor(ctx) {
  // No host answers a bridge call here, so this never settles — the shape of
  // every real app that reads a player or the network before it draws.
  await ctx.apple.script("tell app \\"Music\\" to get name");
  ctx.wing({ text: "never" });
}
export default function App() { return <text content="quiet" />; }
`);
    const winged = await renderAppCommit({
      entryPath: join(appsRoot, "solo", "app.jsx"),
      wing: true,
      wingMs: 100,
    });
    expect(winged.wing).toBeUndefined();
    expect(winged.wingOps).toBeUndefined();
    expect(winged.draws).toBeUndefined();
  });

  // `draws`: the same capture, kept for EVERY canvas rather than the wing's one.
  // A panel canvas is the case this exists for — three of the nine demo apps are
  // a well and nothing else, and their whole signature used to be invisible.
  test("--wing keeps every panel canvas the monitor painted, keyed by node id", async () => {
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
export const meta = { name: "Solo" };
let pane = null;
let ruler = null;
export async function monitor(ctx) {
  ctx.draw(pane.id, [{ op: "rect", x: 0, y: 0, w: 4, h: 4 }]);
  ctx.draw(ruler.id, [{ op: "rect", x: 1, y: 1, w: 2, h: 2 }]);
  // The later frame wins, exactly as the shell's coalescer would have it: a
  // snapshot wants the settled state, not the first paint.
  ctx.draw(pane.id, [{ op: "rect", x: 0, y: 0, w: 8, h: 8 }]);
  await new Promise(() => {});
}
export default function App() {
  return (
    <stack axis="v">
      <canvas ref={(n) => { pane = n; }} w={40} h={34} />
      <canvas ref={(n) => { ruler = n; }} w={40} h={8} />
    </stack>
  );
}
`);
    const winged = await renderAppCommit({
      entryPath: join(appsRoot, "solo", "app.jsx"),
      wing: true,
      wingMs: 120,
    });
    // Keys are strings because JSON object keys are — this map crosses a file.
    expect(winged.draws).toEqual({
      "1": [{ op: "rect", x: 0, y: 0, w: 8, h: 8 }],
      "2": [{ op: "rect", x: 1, y: 1, w: 2, h: 2 }],
    });
    // Without the flag the monitor never runs, so there is nothing to keep.
    const plain = await renderAppCommit({ entryPath: join(appsRoot, "solo", "app.jsx") });
    expect(plain.draws).toBeUndefined();
  });

  test("a canvas that arrives on a re-render is still captured", async () => {
    // Weather's shape: the app mounts an empty state, the monitor reads its
    // cache and calls `ctx.update`, and the canvas appears on the second render.
    // Matching the frames against the *mount* batch would drop it.
    const appsRoot = await tempAppsRoot(`/** @jsxImportSource react */
export const meta = { name: "Solo" };
let node = null;
export async function monitor(ctx) {
  ctx.update({ ready: true });
  await Bun.sleep(10);
  ctx.draw(node.id, [{ op: "rect", x: 0, y: 0, w: 3, h: 3 }]);
  await new Promise(() => {});
}
export default function App({ ready = false }) {
  return ready
    ? <stack axis="v"><canvas ref={(n) => { node = n; }} w={40} h={34} /></stack>
    : <stack axis="v"><text content="nothing yet" /></stack>;
}
`);
    const winged = await renderAppCommit({
      entryPath: join(appsRoot, "solo", "app.jsx"),
      wing: true,
      wingMs: 150,
    });
    expect(Object.values(winged.draws ?? {})).toEqual([
      [{ op: "rect", x: 0, y: 0, w: 3, h: 3 }],
    ]);
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
