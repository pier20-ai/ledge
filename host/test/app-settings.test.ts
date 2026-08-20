import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import type { CatalogApp } from "../src/registry";
import type { Mutation } from "../src/render/mutations";
import { Router } from "../src/router";

// **The whole life of a setting** (spec §§1–5), end to end, through a real
// Router and real workers.
//
// An app declares native controls in `meta.settings`; the catalog carries the
// declaration and the effective values to the shell; the user moves one and the
// shell sends an `appControl` "setting" envelope back; the host stores it,
// hands the worker the complete new map, and re-publishes the catalog so the
// control the user is looking at confirms from truth rather than from optimism.
//
// Two halves, because they answer different questions:
//
//   the fixture   what a worker actually SEES — `ctx.settings` seeded before the
//                 first render, stale keys filtered out on the way, and
//                 `onEvent("settings")` firing on the change and NOT on the
//                 seeding;
//   the radio     what a user actually sees — the real
//                 `protocol/demo-apps/radio/app.jsx`, with a shorter band cut
//                 out of stations it had already fetched, counted off the
//                 frames it draws.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");
const DEMO_APPS = join(HOST_DIR, "..", "protocol", "demo-apps");

class RecordingSession implements ShellSession {
  gen = 1;
  screen = { notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480 };
  sent: Array<{ app: string; type: string; payload: Record<string, unknown> }> = [];
  send(app: string, type: string, payload: Record<string, unknown>): void {
    this.sent.push({ app, type, payload });
  }
  envelopesFor(app: string, type: string) {
    return this.sent.filter((e) => e.app === app && e.type === type);
  }
  get lastCatalog(): CatalogApp[] {
    return (this.envelopesFor("", "catalog").at(-1)?.payload.apps as CatalogApp[]) ?? [];
  }
  row(id: string): CatalogApp | undefined {
    return this.lastCatalog.find((app) => app.id === id);
  }
}

let roots: string[] = [];
let openRouter: Router | null = null;

/** A temp apps root holding one real demo app, by symlink per file — `scanApps`
 * looks for directories, so a symlinked folder would not be found, and the
 * app's own writes (its console.log, its station cache) must land here rather
 * than in the repo. */
async function appsRootWith(appId: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), `ledge-${appId}-settings-`));
  roots.push(root);
  await symlink(NODE_MODULES, join(root, "node_modules"));
  const source = join(DEMO_APPS, appId);
  await mkdir(join(root, appId), { recursive: true });
  for (const entry of await readdir(source)) {
    if (entry === "console.log") continue;
    await symlink(join(source, entry), join(root, appId, entry));
  }
  return root;
}

/** An apps root of written-here fixtures, inside its own directory so the
 * settings file the Router derives lands in the temp tree. */
async function makeRoot(apps: Record<string, string>): Promise<{ dir: string; appsRoot: string }> {
  const dir = await mkdtemp(join(tmpdir(), "ledge-app-settings-"));
  roots.push(dir);
  const appsRoot = join(dir, "apps");
  await mkdir(appsRoot, { recursive: true });
  await symlink(NODE_MODULES, join(appsRoot, "node_modules"));
  for (const [id, source] of Object.entries(apps)) {
    await mkdir(join(appsRoot, id), { recursive: true });
    await writeFile(join(appsRoot, id, "app.jsx"), source);
  }
  return { dir, appsRoot };
}

async function waitFor(predicate: () => boolean, timeoutMs = 15000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await Bun.sleep(20);
  }
  throw new Error("timed out waiting for condition");
}

function envelope(app: string, type: string, payload: Record<string, unknown>): Envelope {
  return { v: 1, app, seq: 1, type, payload };
}

/** The shell's own verb (spec §4): a control-plane frame, so the envelope's
 * `app` is `""` and the target is in the payload. */
function setting(router: Router, session: ShellSession, app: string, key: string, value: unknown): void {
  router.onEnvelope(session, envelope("", "appControl", { app, action: "setting", key, value }));
}

afterEach(async () => {
  openRouter?.shutdown();
  openRouter = null;
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
  await Bun.sleep(10);
});

// --- what the worker sees ----------------------------------------------------

/** An app whose whole job is to say what it was handed. The monitor prints
 * `ctx.settings` on a loop — the documented way to read it, fresh at the point
 * of use — and `onEvent` prints every delivery it is told about. */
const KNOBS_APP = `/** @jsxImportSource react */
export const meta = {
  name: "Knobs",
  icon: "sf:dial.min",
  settings: [
    { key: "model", label: "Model", type: "text", default: "gpt-5.6-luna" },
    { key: "loud", label: "Loud", type: "toggle" },
  ],
};

export function onEvent(name, data, ctx) {
  console.log("event " + name + ": " + JSON.stringify(data) + " ctx " + JSON.stringify(ctx.settings));
}

export async function monitor(ctx) {
  while (true) {
    console.log("reading: " + JSON.stringify(ctx.settings));
    await Bun.sleep(60);
  }
}

export default function Knobs() {
  return <text content="knobs" />;
}
`;

const PLAIN_APP = `/** @jsxImportSource react */
export const meta = { name: "Plain", icon: "sf:circle" };
export default function Plain() {
  return <text content="plain" />;
}
`;

describe("an app's declared controls, from the catalog to ctx.settings", () => {
  test("the catalog carries the surface, and the worker is handed the values", async () => {
    const { dir, appsRoot } = await makeRoot({ knobs: KNOBS_APP, plain: PLAIN_APP });
    const settingsPath = join(dir, "settings.json");
    // A file from a previous version of this app: one key it still declares,
    // and one it does not. The stale key must survive on disk and reach nobody.
    await writeFile(
      settingsPath,
      JSON.stringify({ disabled: [], values: { knobs: { model: "seeded", "long-gone": 3 } } }),
    );

    const log: string[] = [];
    const session = new RecordingSession();
    const router = new Router({ appsRoot, settingsPath, watch: false, log: (line) => log.push(line) });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => log.some((line) => line.includes("reading: ")));

    // §3: the declaration verbatim, and the EFFECTIVE values — stored over
    // declared defaults, one entry per declared key, always complete.
    await waitFor(() => session.row("knobs")?.settings !== undefined);
    expect(session.row("knobs")!.settings).toEqual([
      { key: "model", label: "Model", type: "text", default: "gpt-5.6-luna" },
      { key: "loud", label: "Loud", type: "toggle" },
    ]);
    expect(session.row("knobs")!.values).toEqual({ model: "seeded", loud: false });
    // An app that declares none carries NEITHER field — absent, not empty.
    expect(session.row("plain")!.settings).toBeUndefined();
    expect(session.row("plain")!.values).toBeUndefined();

    // §5(a): the worker has the same map, and the key the app no longer
    // declares was not part of it. On the monitor's FIRST pass, which is the
    // point — a setting that only arrives a message later is a setting the app
    // acts against once on every launch.
    expect(log.find((line) => line.includes("reading: "))!).toContain(
      `reading: {"model":"seeded","loud":false}`,
    );
    expect(log.join("\n")).not.toContain("long-gone");
    // The seeding delivery is not a change: nothing was told it changed.
    expect(log.some((line) => line.includes("event settings"))).toBe(false);

    // §4: the user moves the switch.
    setting(router, session, "knobs", "loud", true);
    await waitFor(() => log.some((line) => line.includes("event settings")));

    // The event carries the complete new map, and `ctx.settings` already agrees
    // with it by the time the handler runs.
    const event = log.find((line) => line.includes("event settings"))!;
    expect(event).toContain(`{"model":"seeded","loud":true} ctx {"model":"seeded","loud":true}`);
    // …the file remembers it, stale key and all…
    expect(await Bun.file(settingsPath).json()).toEqual({
      disabled: [],
      values: { knobs: { model: "seeded", "long-gone": 3, loud: true } },
    });
    // …and the catalog was re-published, so the switch confirms from truth.
    await waitFor(() => session.row("knobs")?.values?.loud === true);

    // A key this app does not declare, and a value of the wrong type: one log
    // line each, nothing stored, nothing delivered, no crash.
    const catalogs = session.envelopesFor("", "catalog").length;
    const events = log.filter((line) => line.includes("event settings")).length;
    setting(router, session, "knobs", "volume", 3);
    setting(router, session, "knobs", "loud", "yes");
    await Bun.sleep(150);
    expect(log.some((line) => line.includes("ignored (not declared)"))).toBe(true);
    expect(log.some((line) => line.includes("is not a toggle"))).toBe(true);
    expect(session.envelopesFor("", "catalog").length).toBe(catalogs);
    expect(log.filter((line) => line.includes("event settings")).length).toBe(events);
    expect(router.hasApp("knobs")).toBe(true);
  }, 30000);

  test("a restarted worker is handed the settings again, before its first render", async () => {
    // A worker is replaced by a hot reload, a crash respawn, or a resync, and
    // the fresh one starts with an empty `ctx.settings` — so the delivery hangs
    // off `meta`, which every worker posts at import (spec §5(a)).
    const { dir, appsRoot } = await makeRoot({ knobs: KNOBS_APP });
    const settingsPath = join(dir, "settings.json");
    const log: string[] = [];
    const session = new RecordingSession();
    const router = new Router({ appsRoot, settingsPath, watch: false, log: (line) => log.push(line) });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => log.some((line) => line.includes("reading: ")));

    setting(router, session, "knobs", "model", "gpt-5.6-nova");
    await waitFor(() => log.some((line) => line.includes("event settings")));

    log.length = 0;
    router.reloadApp("knobs");
    // The value the user set, not the declared default — from the fresh
    // worker's first pass, and as a seeding, because for THIS worker nothing
    // has changed yet.
    await waitFor(() => log.some((line) => line.includes("reading: ")));
    expect(log.find((line) => line.includes("reading: "))!).toContain(`"model":"gpt-5.6-nova"`);
    expect(log.some((line) => line.includes("event settings"))).toBe(false);
  }, 30000);
});

// --- what the user sees ------------------------------------------------------

/** The band's midline in `protocol/demo-apps/radio/app.jsx` — every station
 * marker is centred on it. */
const MARK_Y = 79;

/**
 * How many stations the dial is carrying, counted off the last frame it drew.
 *
 * The face is a canvas, so there is no node to count: the markers are rects
 * centred on the band's midline, and the tuned one wears a halo — a second rect
 * at the same centre — which is why this counts distinct centres rather than
 * rects.
 */
function markerCount(session: RecordingSession, stageId: number): number {
  const frame = session
    .envelopesFor("radio", "draw")
    .filter((e) => e.payload.id === stageId)
    .at(-1);
  if (!frame) return 0;
  const centres = new Set<number>();
  for (const op of frame.payload.ops as Array<Record<string, unknown>>) {
    if (op.op !== "rect") continue;
    const y = Number(op.y);
    const h = Number(op.h);
    if (Math.abs(y + h / 2 - MARK_Y) > 0.001) continue;
    centres.add(Number(op.x) + Number(op.w) / 2);
  }
  return centres.size;
}

describe("radio, re-cutting its dial from stations it already has", () => {
  test("a shorter band costs no fetch, and the face says so", async () => {
    // Twelve stations on the fixture dial, and no audio process: a suite must
    // not touch the public internet or make a noise.
    process.env.LEDGE_RADIO_STATIONS = JSON.stringify(
      Array.from({ length: 12 }, (_, i) => ({
        uuid: `u${i}`,
        name: `Dial ${i}`,
        url: `http://example.test/${i}`,
        country: "DE",
      })),
    );
    process.env.LEDGE_RADIO_MUTE = "1";

    const root = await appsRootWith("radio");
    const settingsPath = join(root, "settings.json");
    // A band the user shortened in some previous session. It has to be the cut
    // the FIRST frame is drawn from: a setting that only takes hold once you
    // change something else is a setting that forgot.
    await writeFile(settingsPath, JSON.stringify({ disabled: [], values: { radio: { "dial-size": 6 } } }));
    const log: string[] = [];
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, settingsPath, watch: false, log: (line) => log.push(line) });
    openRouter = router;
    await router.bindSession(session);

    const creates = () =>
      session
        .envelopesFor("radio", "commit")
        .flatMap((e) => e.payload.mutations as Mutation[])
        .filter((m): m is Extract<Mutation, { op: "create" }> => m.op === "create");
    await waitFor(() => creates().some((m) => m.kind === "canvas" && m.props.w === 380));
    const stage = creates().find((m) => m.kind === "canvas" && m.props.w === 380)!;

    // The dial is drawn on a visit, so the shell pays one (as it does for real).
    router.onEnvelope(session, envelope("radio", "lifecycle", { phase: "expanded", reduceMotion: false }));
    await waitFor(() => markerCount(session, stage.id) > 0);
    // Six markers, from the stored value, on the first frame there is — the
    // twelve fetched stations are all in hand; only six are on the band.
    expect(markerCount(session, stage.id)).toBe(6);

    // The declaration the shell will draw the Settings section from, with the
    // effective values beside it.
    await waitFor(() => session.row("radio")?.settings !== undefined);
    expect(session.row("radio")!.settings!.map((spec) => spec.key)).toEqual(["dial-size", "clicks"]);
    expect(session.row("radio")!.values).toEqual({ "dial-size": 6, clicks: true });

    // Let the band back out. The app was over-fetched on purpose, so this is a
    // different slice of what it already has — no fetch, no re-tune.
    setting(router, session, "radio", "dial-size", 24);
    await waitFor(() => markerCount(session, stage.id) === 12);
    await waitFor(() => session.row("radio")?.values?.["dial-size"] === 24);
    expect(await Bun.file(settingsPath).json()).toEqual({
      disabled: [],
      values: { radio: { "dial-size": 24 } },
    });

    // A number past the declared end is clamped to the end, not refused: the
    // control the user dragged has to hold what the host holds.
    setting(router, session, "radio", "dial-size", 900);
    await waitFor(() => session.row("radio")?.values?.["dial-size"] === 36);
  }, 40000);
});
