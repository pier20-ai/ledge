import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import type { Mutation } from "../src/render/mutations";
import { Router } from "../src/router";

// Routing-focused Router coverage, complementing test/router.test.ts: per-app
// resync, reconnect reload, selection tracking, notify/attention bridges, and
// multi-app isolation. Same real-worker harness pattern.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");

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
}

const STATIC_APP = (label: string) => `/** @jsxImportSource react */
export default function App() {
  return <text content="${label}" />;
}
`;

const NOTIFYING_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  ctx.notify("price crossed", { attention: true });
  ctx.attention();
  await new Promise(() => {}); // park forever; terminate() ends us
}
export default function App() {
  return <text content="notifier" />;
}
`;

// Posts a notification with two action buttons, then folds whichever the user
// pressed back into its props — the agentic approval loop end to end.
const ACTION_APP = `/** @jsxImportSource react */
let apply = null;

export function onEvent(name, data, ctx) {
  if (name === "notification") ctx.update({ label: "pressed " + data.action });
}

export async function monitor(ctx) {
  apply = ctx;
  ctx.notify("Rerun the failed job?", {
    title: "CI medic",
    actions: [{ id: "execute", label: "Execute" }, { id: "skip", label: "Skip" }],
  });
  await new Promise(() => {});
}

export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

let roots: string[] = [];
let openRouter: Router | null = null;

async function makeAppsRoot(apps: Record<string, string>): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ledge-routing-"));
  roots.push(root);
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

describe("per-app resync (spec §4.3)", () => {
  test("resyncRequest respawns the app: reloaded lifecycle + a fresh full mount", async () => {
    const root = await makeAppsRoot({ solo: STATIC_APP("solo") });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("solo", "commit").length >= 1);

    const commitsBefore = session.envelopesFor("solo", "commit").length;
    router.onEnvelope(session, envelope("", "resyncRequest", { app: "solo" }));

    await waitFor(() => session.envelopesFor("solo", "app").some((e) => e.payload.state === "reloaded"));
    await waitFor(() => session.envelopesFor("solo", "commit").length > commitsBefore);
    const remount = session.envelopesFor("solo", "commit").at(-1)!.payload.mutations as Mutation[];
    expect(remount.at(-1)!.op).toBe("setRoot");
  }, 30000);

  test("shell-level resyncRequest re-sends the catalog", async () => {
    const root = await makeAppsRoot({ solo: STATIC_APP("solo") });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    const catalogsBefore = session.envelopesFor("", "catalog").length;
    router.onEnvelope(session, envelope("", "resyncRequest", { app: "" }));
    await waitFor(() => session.envelopesFor("", "catalog").length > catalogsBefore);
  }, 20000);
});

describe("reconnect (spec §1)", () => {
  test("a second bindSession reloads running apps for a fresh full commit", async () => {
    const root = await makeAppsRoot({ solo: STATIC_APP("solo") });
    const first = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(first);
    await waitFor(() => first.envelopesFor("solo", "commit").length >= 1);

    router.clearSession();
    const second = new RecordingSession();
    second.gen = 2;
    await router.bindSession(second);

    // The new generation gets its own catalog and a fresh full mount.
    await waitFor(() => second.envelopesFor("", "catalog").length >= 1);
    await waitFor(() => second.envelopesFor("solo", "app").some((e) => e.payload.state === "reloaded"));
    await waitFor(() => second.envelopesFor("solo", "commit").length >= 1);
    const mount = second.envelopesFor("solo", "commit").at(-1)!.payload.mutations as Mutation[];
    expect(mount.at(-1)!.op).toBe("setRoot");
  }, 30000);
});

// Principle 10 reaching app code: the shell reads the accessibility preference
// (a worker cannot) and it rides the lifecycle envelope to `ctx.reduceMotion`.
const MOTION_APP = `/** @jsxImportSource react */
export function onLifecycle(phase, ctx) {
  ctx.update({ label: phase + (ctx.reduceMotion ? " still" : " moving") });
}
export default function App({ label = "unheard" }) {
  return <text content={label} />;
}
`;

describe("reduce motion (spec §4.2)", () => {
  test("the lifecycle envelope's reduceMotion reaches the app's ctx", async () => {
    const root = await makeAppsRoot({ mover: MOTION_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("mover", "commit").length >= 1);

    const label = () => {
      const commits = session.envelopesFor("mover", "commit");
      for (let i = commits.length - 1; i >= 0; i -= 1) {
        const mutations = commits[i]!.payload.mutations as Mutation[];
        const update = mutations.find((m) => m.op === "update");
        if (update) return (update as Extract<Mutation, { op: "update" }>).props.content;
      }
      return null;
    };

    router.onEnvelope(
      session,
      envelope("mover", "lifecycle", { phase: "expanded", reduceMotion: true }),
    );
    await waitFor(() => label() === "expanded still");

    router.onEnvelope(
      session,
      envelope("mover", "lifecycle", { phase: "collapsed", reduceMotion: false }),
    );
    await waitFor(() => label() === "collapsed moving");

    // A shell that never mentions the flag leaves it where it was — absent is
    // "unchanged", not "motion is fine".
    router.onEnvelope(session, envelope("mover", "lifecycle", { phase: "visible" }));
    await waitFor(() => label() === "visible moving");
  }, 30000);
});

describe("selection tracking (spec §4.3)", () => {
  test("selection envelopes update router.presented, including the null/surface form", async () => {
    const root = await makeAppsRoot({});
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    router.onEnvelope(session, envelope("", "selection", { app: "music" }));
    expect(router.presented).toBe("music");
    router.onEnvelope(session, envelope("", "selection", { app: null, surface: "settings" }));
    expect(router.presented).toBeNull();
  });
});

describe("notify/attention bridges (spec §6, §3.3)", () => {
  test("ctx.notify sends a notify envelope to the shell plus chrome attention; ctx.attention sends chrome only", async () => {
    const root = await makeAppsRoot({ pinger: NOTIFYING_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    // The notification itself is now the shell's job (it owns the bundle, and
    // only it can draw action buttons) — the host just routes the envelope.
    await waitFor(() => session.envelopesFor("pinger", "notify").length >= 1);
    const notify = session.envelopesFor("pinger", "notify")[0]!.payload;
    expect(notify.text).toBe("price crossed");
    expect(typeof notify.id).toBe("number");
    // `attention` is NOT part of the notify payload: the glow is a §3.3 chrome
    // request, so it stays its own envelope.
    expect(notify.attention).toBeUndefined();

    // Two chrome attention envelopes: one from notify's flag, one from ctx.attention().
    await waitFor(() => session.envelopesFor("pinger", "chrome").length >= 2);
    for (const chrome of session.envelopesFor("pinger", "chrome")) {
      expect(chrome.payload.request).toBe("attention");
    }
  }, 20000);

  test("a notification action comes back as the id-0 app-level event", async () => {
    const root = await makeAppsRoot({ pinger: ACTION_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("pinger", "notify").length >= 1);
    const id = session.envelopesFor("pinger", "notify")[0]!.payload.id as number;
    expect(session.envelopesFor("pinger", "notify")[0]!.payload.actions).toEqual([
      { id: "execute", label: "Execute" },
      { id: "skip", label: "Skip" },
    ]);

    // The shell reports the press; the worker sees it as onEvent("notification").
    router.onEnvelope(session, envelope("pinger", "notifyAction", { id, action: "execute" }));
    await waitFor(() =>
      session
        .envelopesFor("pinger", "commit")
        .some((e) =>
          JSON.stringify(e.payload.mutations).includes("pressed execute"),
        ),
    );
  }, 20000);
});

describe("multi-app isolation", () => {
  test("an event for app B never reaches app A", async () => {
    const root = await makeAppsRoot({ alpha: STATIC_APP("alpha"), beta: STATIC_APP("beta") });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(
      () =>
        session.envelopesFor("alpha", "commit").length >= 1 &&
        session.envelopesFor("beta", "commit").length >= 1,
    );

    const alphaCommits = session.envelopesFor("alpha", "commit").length;
    const betaCommits = session.envelopesFor("beta", "commit").length;
    // Static apps have no handlers: a bogus event routes to beta's worker and is
    // dropped there; alpha must see nothing at all.
    router.onEnvelope(session, envelope("beta", "event", { id: 1, name: "click", data: {} }));
    await Bun.sleep(150);
    expect(session.envelopesFor("alpha", "commit").length).toBe(alphaCommits);
    expect(session.envelopesFor("beta", "commit").length).toBe(betaCommits);
  }, 30000);
});
