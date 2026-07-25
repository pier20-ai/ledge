import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import { Router } from "../src/router";
import type { CatalogApp } from "../src/registry";

// The four platform-API groups end to end on the host side, driven by REAL Bun
// workers: meta extraction into the catalog (§6 → §3.6), ctx.draw frames (§3.4),
// ctx.wing (§3.3 extension) with its arbitration and lifecycle clearing, and
// worker-requested expand/collapse (§3.3). Everything below is a genuine
// app.jsx: if the worker contract drifts, these stop passing.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");

class RecordingSession implements ShellSession {
  gen = 1;
  screen = { notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 700 };
  sent: Array<{ app: string; type: string; payload: Record<string, unknown> }> = [];
  send(app: string, type: string, payload: Record<string, unknown>): void {
    this.sent.push({ app, type, payload });
  }
  envelopesFor(app: string, type: string) {
    return this.sent.filter((e) => e.app === app && e.type === type);
  }
  get catalogs(): CatalogApp[][] {
    return this.envelopesFor("", "catalog").map((e) => e.payload.apps as CatalogApp[]);
  }
  get lastCatalog(): CatalogApp[] {
    return this.catalogs.at(-1) ?? [];
  }
  /** Every chrome envelope for an app, in order. */
  chromeFor(app: string) {
    return this.envelopesFor(app, "chrome").map((e) => e.payload);
  }
}

// --- App sources -------------------------------------------------------------

const META_APP = `/** @jsxImportSource react */
export const meta = {
  name: "Chess",
  icon: "sf:crown",
  panel: { width: 520, maxHeight: 560 },
};
export default function App() {
  return <text content="e4" />;
}
`;

const NO_META_APP = `/** @jsxImportSource react */
export default function App() {
  return <text content="anonymous" />;
}
`;

const JUNK_META_APP = `/** @jsxImportSource react */
export const meta = "not an object";
export default function App() {
  return <text content="junk" />;
}
`;

/** Draws one frame per monitor pass, keyed off the canvas node the tree owns. */
const DRAW_APP = `/** @jsxImportSource react */
export const meta = { name: "Tetris", icon: "sf:square.grid.3x3" };

let canvas = null;

export async function monitor(ctx) {
  if (canvas) {
    ctx.draw(canvas.id, [{ op: "clear" }, { op: "rect", x: 1, y: 1, w: 4, h: 4, fill: "#30D158" }]);
    ctx.draw(canvas.id, "not an op list");   // rejected at the ctx boundary
    ctx.draw(1.5, []);                       // ditto: ids are integers
  }
  await new Promise(() => {});               // park; terminate() ends us
}

export default function App() {
  return (
    <stack axis="v">
      <canvas ref={(node) => { canvas = node; }} w={200} h={320} focusable onKey={() => {}} />
    </stack>
  );
}
`;

/** The §4.1 key loop, worker side: a key event has to reach onKey and the
 * handler's draw has to come back out as a draw envelope. */
const KEY_APP = `/** @jsxImportSource react */
// The documented game-loop pattern, both halves of it:
//   - ctx is the monitor's argument, and the object lives as long as the worker,
//     so an event handler keeps the reference;
//   - a ref on the canvas yields its node instance, whose \`id\` is the id
//     ctx.draw addresses — an app never has to guess a node id.
let bridge = null;
let canvas = null;

export async function monitor(ctx) {
  bridge = ctx;
  await new Promise(() => {});
}

export default function App() {
  return (
    <stack axis="v">
      <canvas
        ref={(node) => { canvas = node; }}
        w={200}
        h={320}
        focusable
        onKey={(data) => {
          if (!bridge || !canvas) return;
          bridge.draw(canvas.id, [{ op: "text", x: 0, y: 0, content: data.key + ":" + data.down }]);
        }}
      />
    </stack>
  );
}
`;

const WING_APP = (text: string) => `/** @jsxImportSource react */
export async function monitor(ctx) {
  ctx.wing({ text: "${text}", canvas: { id: 2, w: 64 } });
  await new Promise(() => {});
}
export default function App() {
  return <stack axis="v"><canvas w={64} h={34} /></stack>;
}
`;

const BREATHING_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  for (const width of [220, 260, 300]) ctx.wing({ width });
  ctx.wing(null);
  await new Promise(() => {});
}
export default function App() {
  return <text content="breathe" />;
}
`;

const CHROME_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  ctx.expand();
  ctx.collapse();
  await new Promise(() => {});
}
export default function App() {
  return <text content="alarm" />;
}
`;

/**
 * `ctx.platform.observe` end to end (spec §6 extension): the app registers, the
 * shell acknowledges, and the id-0 `platform` event the shell later pushes
 * arrives at `onEvent` and turns into a prop.
 *
 * This is a *plain* app, not Settings: observe/unobserve are for every app,
 * because "poll for truth, be woken for latency" is every monitor's problem.
 */
const OBSERVING_APP = `/** @jsxImportSource react */
let armed = null;

export function onEvent(name, data, ctx) {
  if (name !== "platform") return;
  ctx.update({ label: "woke on " + data.name });
}

export async function monitor(ctx) {
  armed = ctx;
  await ctx.platform.observe("distributedNotification", "com.apple.Music.playerInfo");
  await ctx.platform.unobserve("distributedNotification", "com.spotify.client.PlaybackStateChanged");
  await new Promise(() => {});
}

export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

/**
 * The Tier 1 + Tier 2 request/reply calls, end to end through a real worker:
 * each one is awaited, and what the shell answers becomes a prop.
 */
const CALLING_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  const events = await ctx.platform.calendar({ from: "2026-07-25T09:00:00Z" });
  const info = await ctx.platform.workspace();
  const volume = await ctx.platform.setVolume(1.4);
  ctx.update({ label: events.length + "|" + info.frontmost.localizedName + "|" + volume });
  await new Promise(() => {});
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

/** A refused TCC prompt is an ordinary outcome an app branches on. */
const DEGRADING_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  let label;
  try {
    await ctx.platform.location();
    label = "located";
  } catch (error) {
    label = "degraded: " + String(error.message);
  }
  ctx.update({ label });
  await new Promise(() => {});
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

/** Every new observe kind, declared in one pass. */
const KINDS_APP = `/** @jsxImportSource react */
export function onEvent(name, data, ctx) {
  if (name === "platform") ctx.update({ label: data.kind + ":" + data.userInfo.interface });
}
export async function monitor(ctx) {
  for (const kind of ["workspace", "pasteboard", "power", "reachability", "audio"]) {
    await ctx.platform.observe(kind, kind === "workspace" ? "screenLocked" : "changed");
  }
  await new Promise(() => {});
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

const CRASHING_WING_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  ctx.wing({ text: "alive" });
  await Bun.sleep(30);
  throw new Error("kaboom");
}
export default function App() {
  return <text content="doomed" />;
}
`;

// --- Harness -----------------------------------------------------------------

let roots: string[] = [];
let openRouter: Router | null = null;

async function makeAppsRoot(apps: Record<string, string>): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ledge-platform-"));
  roots.push(root);
  // This temp root gets the host's own node_modules symlinked in; the repo's
  // demo apps root (protocol/demo-apps) is a real package with its own lockfile.
  await symlink(NODE_MODULES, join(root, "node_modules"));
  for (const [id, source] of Object.entries(apps)) {
    await mkdir(join(root, id), { recursive: true });
    await writeFile(join(root, id, "app.jsx"), source);
  }
  return root;
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

afterEach(async () => {
  openRouter?.shutdown();
  openRouter = null;
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
  await Bun.sleep(10);
});

// --- A: meta extraction ------------------------------------------------------

describe("meta extraction → catalog (spec §6 → §3.6)", () => {
  test("a declared meta replaces the dirname fallback and re-sends the FULL catalog", async () => {
    const root = await makeAppsRoot({ chess: META_APP, plain: NO_META_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    // The first snapshot is the registry scan alone: no worker has spoken yet.
    expect(session.catalogs[0]!.map((a) => a.name)).toEqual(["Chess", "Plain"]);
    expect(session.catalogs[0]!.every((a) => a.icon === "sf:square.dashed")).toBe(true);

    await waitFor(() => session.lastCatalog.some((a) => a.icon === "sf:crown"));
    const chess = session.lastCatalog.find((a) => a.id === "chess")!;
    expect(chess.name).toBe("Chess");
    expect(chess.icon).toBe("sf:crown");
    expect(chess.panel).toEqual({ width: 520, maxHeight: 560 });

    // The app that declares nothing keeps the dirname fallback and no panel.
    const plain = session.lastCatalog.find((a) => a.id === "plain")!;
    expect(plain.name).toBe("Plain");
    expect(plain.icon).toBe("sf:square.dashed");
    expect(plain.panel).toBeUndefined();

    // Snapshots, not diffs (spec §3.6): every catalog frame is the whole list.
    expect(session.catalogs.every((c) => c.length === 2)).toBe(true);
  }, 30000);

  test("a junk meta is survivable: the app still runs on its fallback identity", async () => {
    const root = await makeAppsRoot({ junk: JUNK_META_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("junk", "commit").length >= 1);
    expect(session.lastCatalog[0]!.name).toBe("Junk");
    expect(session.lastCatalog[0]!.icon).toBe("sf:square.dashed");
  }, 30000);

  test("meta arrives before the app's mount commit", async () => {
    const root = await makeAppsRoot({ chess: META_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("chess", "commit").length >= 1);

    // Catalog carrying the real icon, then the commit — so the strip never shows
    // a placeholder for an app whose panel is already on screen.
    const metaAt = session.sent.findIndex(
      (e) => e.type === "catalog" && (e.payload.apps as CatalogApp[])[0]!.icon === "sf:crown",
    );
    const commitAt = session.sent.findIndex((e) => e.type === "commit" && e.app === "chess");
    expect(metaAt).toBeGreaterThan(-1);
    expect(metaAt).toBeLessThan(commitAt);
  }, 30000);

  test("a reload re-declares meta wholesale, so a removed field falls back again", async () => {
    const root = await makeAppsRoot({ chess: META_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.lastCatalog[0]!.icon === "sf:crown");

    await writeFile(join(root, "chess", "app.jsx"), NO_META_APP);
    router.reloadApp("chess");
    await waitFor(() => session.lastCatalog[0]!.icon === "sf:square.dashed");
    expect(session.lastCatalog[0]!.name).toBe("Chess");   // the dirname, not the old meta
    expect(session.lastCatalog[0]!.panel).toBeUndefined();
  }, 30000);
});

// --- B: draw path ------------------------------------------------------------

describe("worker draw path (spec §3.4)", () => {
  test("ctx.draw becomes a per-app draw envelope; malformed frames never reach the wire", async () => {
    const root = await makeAppsRoot({ tetris: DRAW_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("tetris", "draw").length >= 1);
    const mount = session.envelopesFor("tetris", "commit")[0]!.payload.mutations as Array<{
      op: string;
      id: number;
      kind?: string;
    }>;
    const canvasId = mount.find((m) => m.op === "create" && m.kind === "canvas")!.id;

    const draw = session.envelopesFor("tetris", "draw")[0]!;
    expect(draw.payload.id).toBe(canvasId);
    expect((draw.payload.ops as unknown[]).length).toBe(2);

    // The two bad calls are dropped at the ctx boundary — one frame per pass.
    await Bun.sleep(120);
    const perPass = session.envelopesFor("tetris", "draw");
    expect(perPass.every((e) => Array.isArray(e.payload.ops))).toBe(true);
    expect(perPass.every((e) => Number.isInteger(e.payload.id))).toBe(true);
  }, 30000);

  test("a §4.1 key event reaches onKey and its draw comes back out (the game loop)", async () => {
    const root = await makeAppsRoot({ game: KEY_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("game", "commit").length >= 1);
    // Let the monitor run once so the handler has a ctx to draw with.
    await waitFor(() => session.envelopesFor("game", "app").some((e) => e.payload.state === "started"));
    await Bun.sleep(50);

    // The shell addresses the canvas by the node id the reconciler allocated —
    // read it out of the mount batch exactly as the shell would.
    const mount = session.envelopesFor("game", "commit")[0]!.payload.mutations as Array<{
      op: string;
      id: number;
      kind?: string;
    }>;
    const canvasId = mount.find((m) => m.op === "create" && m.kind === "canvas")!.id;

    router.onEnvelope(
      session,
      envelope("game", "event", { id: canvasId, name: "key", data: { key: "ArrowLeft", down: true } }),
    );
    await waitFor(() => session.envelopesFor("game", "draw").length >= 1);
    const frame = session.envelopesFor("game", "draw")[0]!;
    const ops = frame.payload.ops as Array<{ content: string }>;
    expect(ops[0]!.content).toBe("ArrowLeft:true");
    // The app addressed its own canvas node, learned from a ref — not a guess.
    expect(frame.payload.id).toBe(canvasId);
  }, 30000);
});

// --- C: wings + worker-driven presentation -----------------------------------

describe("wings (spec §3.3 extension)", () => {
  test("ctx.wing becomes a chrome wing request carrying the spec", async () => {
    const root = await makeAppsRoot({ stocks: WING_APP("AAPL") });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.chromeFor("stocks").some((p) => p.request === "wing" && p.wing));
    const wing = session.chromeFor("stocks").find((p) => p.request === "wing")!.wing;
    expect(wing).toEqual({ text: "AAPL", canvas: { id: 2, w: 64 } });
  }, 30000);

  test("a bare width request is a wing too, and null releases it", async () => {
    const root = await makeAppsRoot({ breathe: BREATHING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.chromeFor("breathe").filter((p) => p.request === "wing").length >= 4);
    const wings = session.chromeFor("breathe").filter((p) => p.request === "wing").map((p) => p.wing);
    expect(wings.slice(0, 3)).toEqual([{ width: 220 }, { width: 260 }, { width: 300 }]);
    expect(wings[3]).toBeNull();
  }, 30000);

  test("a crash releases the app's wing before the crashed lifecycle goes out", async () => {
    const root = await makeAppsRoot({ doomed: CRASHING_WING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("doomed", "app").some((e) => e.payload.state === "crashed"));
    const release = session.sent.findIndex(
      (e) => e.app === "doomed" && e.type === "chrome" && e.payload.request === "wing" && e.payload.wing === null,
    );
    const crashed = session.sent.findIndex(
      (e) => e.app === "doomed" && e.type === "app" && e.payload.state === "crashed",
    );
    expect(release).toBeGreaterThan(-1);
    expect(release).toBeLessThan(crashed);
  }, 30000);

  test("a reload releases the wing, and the fresh worker re-declares it", async () => {
    const root = await makeAppsRoot({ stocks: WING_APP("AAPL") });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.chromeFor("stocks").some((p) => p.request === "wing" && p.wing));

    const releasesBefore = session.chromeFor("stocks").filter((p) => p.wing === null).length;
    const wingsBefore = session.chromeFor("stocks").filter((p) => p.wing).length;
    await writeFile(join(root, "stocks", "app.jsx"), WING_APP("MSFT"));
    router.reloadApp("stocks");

    await waitFor(() => session.chromeFor("stocks").filter((p) => p.wing === null).length > releasesBefore);
    await waitFor(() => session.chromeFor("stocks").filter((p) => p.wing).length > wingsBefore);
    expect(session.chromeFor("stocks").filter((p) => p.wing).at(-1)!.wing).toMatchObject({ text: "MSFT" });
  }, 30000);

  test("stopping an app releases its wing (spec §3.2 `stopped`)", async () => {
    const root = await makeAppsRoot({ stocks: WING_APP("AAPL") });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.chromeFor("stocks").some((p) => p.request === "wing" && p.wing));

    const before = session.chromeFor("stocks").filter((p) => p.wing === null).length;
    router.shutdown();
    openRouter = null;
    expect(session.chromeFor("stocks").filter((p) => p.wing === null).length).toBeGreaterThan(before);
  }, 30000);

  test("no wing is held across a disconnect: nothing is replayed on rebind", async () => {
    const root = await makeAppsRoot({ stocks: WING_APP("AAPL") });
    const first = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(first);
    await waitFor(() => first.chromeFor("stocks").some((p) => p.request === "wing" && p.wing));

    router.clearSession();
    const second = new RecordingSession();
    second.gen = 2;
    await router.bindSession(second);
    // The reload that follows a rebind re-declares the wing from scratch; the
    // dead connection's wing is never replayed onto the new one.
    await waitFor(() => second.chromeFor("stocks").some((p) => p.request === "wing" && p.wing));
    expect(second.chromeFor("stocks")[0]!.wing).toBeTruthy();
  }, 30000);
});

// --- D: ctx.platform.observe -------------------------------------------------

describe("ctx.platform.observe (spec §6 extension)", () => {
  test("observe/unobserve become platform envelopes and settle on platformResult", async () => {
    const root = await makeAppsRoot({ music: OBSERVING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("music", "platform").length >= 1);
    const observe = session.envelopesFor("music", "platform")[0]!.payload;
    // `call` is the verb and `kind` is the source being watched — two axes, so
    // the worker's own discriminant is not what goes on the wire.
    expect(observe.call).toBe("observe");
    expect(observe.kind).toBe("distributedNotification");
    expect(observe.name).toBe("com.apple.Music.playerInfo");
    expect(Number.isInteger(observe.id)).toBe(true);

    // The app awaits the acknowledgement, so the second call only goes out once
    // the first has been settled — which is what proves the bridge is matched
    // on (app, id) rather than fired and forgotten.
    router.onEnvelope(
      session,
      envelope("music", "platformResult", { id: observe.id, ok: true }),
    );
    await waitFor(() => session.envelopesFor("music", "platform").length >= 2);
    const unobserve = session.envelopesFor("music", "platform")[1]!.payload;
    expect(unobserve.call).toBe("unobserve");
    expect(unobserve.name).toBe("com.spotify.client.PlaybackStateChanged");
  }, 30000);

  test("a shell-pushed platform event reaches onEvent at id 0", async () => {
    const root = await makeAppsRoot({ music: OBSERVING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("music", "commit").length >= 1);

    router.onEnvelope(
      session,
      envelope("music", "event", {
        id: 0,
        name: "platform",
        data: {
          kind: "distributedNotification",
          name: "com.apple.Music.playerInfo",
          userInfo: { "Player State": "Playing" },
        },
      }),
    );

    await waitFor(() =>
      session
        .envelopesFor("music", "commit")
        .some((e) =>
          JSON.stringify(e.payload.mutations).includes("woke on com.apple.Music.playerInfo"),
        ),
    );
  }, 30000);

  test("a failed platformResult rejects the app's promise instead of hanging", async () => {
    const root = await makeAppsRoot({ music: OBSERVING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("music", "platform").length >= 1);

    const observe = session.envelopesFor("music", "platform")[0]!.payload;
    router.onEnvelope(
      session,
      envelope("music", "platformResult", {
        id: observe.id,
        ok: false,
        error: "unsupported observe kind 'carrierPigeon'",
      }),
    );
    // The app's monitor awaits the observe, so a rejection is an unhandled
    // throw in `monitor` — an app crash with backoff (spec §6 rule 2), which is
    // the honest outcome for "I asked to watch something and was refused".
    await waitFor(() =>
      session.envelopesFor("music", "app").some((e) => e.payload.state === "crashed"),
    );
  }, 30000);

  test("the Settings-only calls are unchanged: answered locally, never sent on", async () => {
    const root = await makeAppsRoot({ music: OBSERVING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("music", "platform").length >= 1);

    const before = session.envelopesFor("music", "platform").length;
    // App management is a different half of the same bridge and is still
    // unimplemented in this phase — it must answer the worker rather than sit
    // there, and it must not reach the shell dressed as an observe.
    router.platform("music", 999, { kind: "stats" });
    await Bun.sleep(30);
    expect(session.envelopesFor("music", "platform")).toHaveLength(before);
  }, 30000);
});

// --- E: the Tier 1 + Tier 2 platform calls -----------------------------------

describe("ctx.platform calls (spec §6 extension)", () => {
  test("each call becomes its own platform envelope and its data settles the Promise", async () => {
    const root = await makeAppsRoot({ agenda: CALLING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    // The app awaits each call, so the second only goes out once the first has
    // been settled — which is what proves the bridge is matched on (app, id).
    await waitFor(() => session.envelopesFor("agenda", "platform").length >= 1);
    const calendar = session.envelopesFor("agenda", "platform")[0]!.payload;
    expect(calendar.call).toBe("calendar");
    expect(calendar.from).toBe("2026-07-25T09:00:00Z");
    // A range end the app did not name is absent, not null: the shell owns the
    // default (+24 h) and the cap (14 days).
    expect("to" in calendar).toBe(false);

    router.onEnvelope(
      session,
      envelope("agenda", "platformResult", {
        id: calendar.id,
        ok: true,
        data: [{ title: "Standup", start: "a", end: "b", allDay: false, calendar: "Work" }],
      }),
    );

    await waitFor(() => session.envelopesFor("agenda", "platform").length >= 2);
    const workspace = session.envelopesFor("agenda", "platform")[1]!.payload;
    expect(workspace).toEqual({ id: workspace.id, call: "workspace" });
    router.onEnvelope(
      session,
      envelope("agenda", "platformResult", {
        id: workspace.id,
        ok: true,
        data: { frontmost: { bundleId: "com.apple.dt.Xcode", localizedName: "Xcode" }, idleSeconds: 4.5 },
      }),
    );

    await waitFor(() => session.envelopesFor("agenda", "platform").length >= 3);
    const setVolume = session.envelopesFor("agenda", "platform")[2]!.payload;
    // Unclamped on the way out — clamping lives next to the device that knows
    // its own range — and the applied value comes back.
    expect(setVolume).toEqual({ id: setVolume.id, call: "setVolume", value: 1.4 });
    router.onEnvelope(
      session,
      envelope("agenda", "platformResult", { id: setVolume.id, ok: true, data: { volume: 1 } }),
    );

    await waitFor(() =>
      session
        .envelopesFor("agenda", "commit")
        .some((e) => JSON.stringify(e.payload.mutations).includes("1|Xcode|1")),
    );
  }, 30000);

  test("a refused call rejects, and an app can degrade instead of crashing", async () => {
    const root = await makeAppsRoot({ weather: DEGRADING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("weather", "platform").length >= 1);
    const request = session.envelopesFor("weather", "platform")[0]!.payload;
    expect(request.call).toBe("location");
    router.onEnvelope(
      session,
      envelope("weather", "platformResult", {
        id: request.id,
        ok: false,
        error: "location access was refused in System Settings › Privacy & Security › Location Services",
      }),
    );

    // The denial is an ordinary outcome the app catches — a machine where the
    // user said no should say so, not disappear behind an error card.
    await waitFor(() =>
      session
        .envelopesFor("weather", "commit")
        .some((e) => JSON.stringify(e.payload.mutations).includes("degraded: location access was refused")),
    );
    expect(session.envelopesFor("weather", "app").some((e) => e.payload.state === "crashed")).toBe(false);
  }, 30000);

  test("every new observe kind rides the same envelope, with its translated name", async () => {
    const root = await makeAppsRoot({ probe: KINDS_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    // Each observe is awaited, so acknowledging one releases the next.
    for (let index = 0; index < 5; index += 1) {
      await waitFor(() => session.envelopesFor("probe", "platform").length >= index + 1);
      const request = session.envelopesFor("probe", "platform")[index]!.payload;
      router.onEnvelope(session, envelope("probe", "platformResult", { id: request.id, ok: true }));
    }

    const observes = session.envelopesFor("probe", "platform").map((e) => e.payload);
    expect(observes.map((p) => p.kind)).toEqual([
      "workspace",
      "pasteboard",
      "power",
      "reachability",
      "audio",
    ]);
    expect(observes.every((p) => p.call === "observe")).toBe(true);
    expect(observes[0]!.name).toBe("screenLocked");
    expect(observes.slice(1).every((p) => p.name === "changed")).toBe(true);

    // …and an event on one of them reaches onEvent at id 0, like every other.
    router.onEnvelope(
      session,
      envelope("probe", "event", {
        id: 0,
        name: "platform",
        data: {
          kind: "reachability",
          name: "changed",
          userInfo: { satisfied: true, expensive: false, constrained: false, interface: "wifi" },
        },
      }),
    );
    await waitFor(() =>
      session
        .envelopesFor("probe", "commit")
        .some((e) => JSON.stringify(e.payload.mutations).includes("reachability:wifi")),
    );
  }, 30000);

  test("a call the shell never answers is failed by the host, not left hanging", async () => {
    const root = await makeAppsRoot({ weather: DEGRADING_APP });
    const session = new RecordingSession();
    // The TCC-gated calls get a two-minute deadline in production because the
    // thing they wait for is a person; shortened here to assert the mechanism.
    const router = new Router({ appsRoot: root, watch: false, timeouts: { platformGrant: 60 } });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("weather", "platform").length >= 1);
    await waitFor(() =>
      session
        .envelopesFor("weather", "commit")
        .some((e) => JSON.stringify(e.payload.mutations).includes("degraded: ctx.platform timed out")),
    );
  }, 30000);
});

describe("worker-requested chrome (spec §3.3)", () => {
  test("ctx.expand and ctx.collapse become chrome envelopes for that app", async () => {
    const root = await makeAppsRoot({ alarm: CHROME_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.chromeFor("alarm").length >= 2);
    expect(session.chromeFor("alarm").map((p) => p.request)).toEqual(["expand", "collapse"]);
  }, 30000);
});
