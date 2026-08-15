import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import type { CatalogApp } from "../src/registry";
import { scanApps } from "../src/registry";
import { Router } from "../src/router";
import { SettingsStore } from "../src/settings";

// The enable/disable machinery (spec §3.6 `enabled`, §8): the file that
// remembers which apps are off, the registry flag it produces, the `appControl`
// envelope the shell flips it with, and the privileged `ctx.platform` bridge
// that is the other way in.
//
// This file used to end with tests of the shipped Settings *app*. There is no
// such app: Settings is a native macOS window in the shell now, and the demo is
// archived at `protocol/demo-apps-archive/settings-app`. What is left here is
// the wire underneath it, which the native window drives instead — so every
// test below mounts a fixture, and none of them read an app off disk.
//
// Nothing here touches the real ~/.ledge: every root is a temp directory, and
// each Router is given an explicit settings path inside it.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");

const roots: string[] = [];
let openRouter: Router | null = null;

afterEach(async () => {
  openRouter?.shutdown();
  openRouter = null;
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

class RecordingSession implements ShellSession {
  gen = 3;
  screen = { notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 700 };
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
}

// --- fixtures ----------------------------------------------------------------

/**
 * A stand-in for the privileged app: reads the catalog once, then waits to be
 * told what to toggle. The id-0 event is the app-level convention (§4.1), which
 * is the cheapest way for a test to press a switch without owning a node id.
 *
 * It has to be installed under the id `settings`, because that is the folder
 * name the host grants the management half of `ctx.platform` to (router.ts,
 * `SETTINGS_APP_ID`) — the privilege is keyed on the id and nothing else.
 */
const PRIVILEGED_APP = `/** @jsxImportSource react */
export const meta = { name: "Settings", icon: "sf:slider.horizontal.3" };

export async function monitor(ctx) {
  const stats = await ctx.platform.stats();
  console.log("catalog: " + (stats?.apps ?? []).map((a) => a.id + "=" + a.enabled).join(","));
  await new Promise(() => {});
}

export async function onEvent(name, data, ctx) {
  if (name !== "toggle") return;
  try {
    await (data.on ? ctx.platform.enable(data.app) : ctx.platform.disable(data.app));
    console.log("ok: " + data.app + " -> " + data.on);
  } catch (error) {
    console.log("refused: " + String(error));
  }
}

export default function App() {
  return <text content="settings" />;
}
`;

const PLAIN_APP = (name: string) => `/** @jsxImportSource react */
export const meta = { name: "${name}", icon: "sf:circle" };
export default function App() {
  return <text content="${name}" />;
}
`;

/** An apps root inside its own temp directory, so the settings file the Router
 * derives lands in the temp tree and not in $TMPDIR itself. */
async function makeRoot(apps: Record<string, string>): Promise<{ dir: string; appsRoot: string }> {
  const dir = await mkdtemp(join(tmpdir(), "ledge-settings-"));
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
  return { v: 1, app, seq: 1, type, payload } as Envelope;
}

/** Press a switch in the fixture app above. */
function toggle(router: Router, session: ShellSession, app: string, on: boolean): void {
  router.onEnvelope(
    session,
    envelope("settings", "event", { id: 0, name: "toggle", data: { app, on } }),
  );
}

// --- the file ----------------------------------------------------------------

describe("settings.json (the host's own state)", () => {
  test("a machine with no settings file has every app enabled", async () => {
    const { dir } = await makeRoot({});
    const store = new SettingsStore(join(dir, "settings.json"));
    await store.load();
    expect(store.disabled.size).toBe(0);
    expect(store.isEnabled("stocks")).toBe(true);
  });

  test("disabling persists, re-enabling forgets, and neither leaves a temp file", async () => {
    const { dir } = await makeRoot({});
    const path = join(dir, "settings.json");
    const store = new SettingsStore(path);
    await store.load();

    await store.setEnabled("stocks", false);
    expect(await Bun.file(path).json()).toEqual({ disabled: ["stocks"] });
    // The write is temp-then-rename; a leftover .tmp would mean it wasn't.
    expect((await readdir(dir)).filter((f) => f.endsWith(".tmp"))).toEqual([]);

    const reread = new SettingsStore(path);
    await reread.load();
    expect(reread.isEnabled("stocks")).toBe(false);

    await reread.setEnabled("stocks", true);
    expect(await Bun.file(path).json()).toEqual({ disabled: [] });
  });

  test("quick changes serialize without losing either toggle", async () => {
    const { dir } = await makeRoot({});
    const path = join(dir, "settings.json");
    const store = new SettingsStore(path);
    await store.load();

    await Promise.all([
      store.setEnabled("alpha", false),
      store.setEnabled("beta", false),
    ]);

    expect(await Bun.file(path).json()).toEqual({ disabled: ["alpha", "beta"] });
    expect([...store.disabled].sort()).toEqual(["alpha", "beta"]);
    expect((await readdir(dir)).filter((file) => file.endsWith(".tmp"))).toEqual([]);
  });

  test("no id is exempt — the file is a plain list of ids", async () => {
    // The inverse of the test that used to be here. `settings` was forced back
    // on however it was asked, because the Settings app was the only way to undo
    // a switch and a file naming it would have locked the user out of their own
    // switches. Settings is a native macOS window in the shell now (spec §8):
    // it is not an app, nothing in this file can turn it off, and an exemption
    // for an id no app claims is a special case that only ever misleads.
    const { dir } = await makeRoot({});
    const path = join(dir, "settings.json");
    const store = new SettingsStore(path);
    await store.load();
    await store.setEnabled("settings", false);
    expect(await Bun.file(path).json()).toEqual({ disabled: ["settings"] });

    await writeFile(path, JSON.stringify({ disabled: ["settings", "music"] }));
    const reread = new SettingsStore(path);
    await reread.load();
    expect(reread.isEnabled("settings")).toBe(false);
    expect(reread.isEnabled("music")).toBe(false);
  });

  test("a settings file that will not parse means everything runs", async () => {
    const { dir } = await makeRoot({});
    const path = join(dir, "settings.json");
    await writeFile(path, "{ this is not json");
    const store = new SettingsStore(path);
    await store.load();
    // Refusing to boot would strand the user with no way in to fix it.
    expect(store.disabled.size).toBe(0);
  });

  test("the settings file sits beside the apps root, never inside it", () => {
    expect(SettingsStore.pathFor("/Users/x/.ledge/apps")).toBe("/Users/x/.ledge/settings.json");
  });
});

// --- the registry ------------------------------------------------------------

describe("scanApps reports enabled from the settings file", () => {
  test("a disabled id comes back enabled: false; everything else is on", async () => {
    const { appsRoot } = await makeRoot({ alpha: PLAIN_APP("Alpha"), beta: PLAIN_APP("Beta") });
    const all = await scanApps(appsRoot);
    expect(all.map((app) => app.enabled)).toEqual([true, true]);

    const some = await scanApps(appsRoot, new Set(["beta"]));
    expect(some.map((app) => [app.id, app.enabled])).toEqual([
      ["alpha", true],
      ["beta", false],
    ]);
  });
});

// --- the bridge --------------------------------------------------------------

describe("ctx.platform enable/disable (spec §8), answered by the host", () => {
  test("a disabled app never spawns, and says so in the catalog", async () => {
    const { dir, appsRoot } = await makeRoot({
      settings: PRIVILEGED_APP,
      alpha: PLAIN_APP("Alpha"),
      beta: PLAIN_APP("Beta"),
    });
    await writeFile(join(dir, "settings.json"), JSON.stringify({ disabled: ["beta"] }));

    const session = new RecordingSession();
    const router = new Router({ appsRoot, settingsPath: join(dir, "settings.json"), watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("alpha", "commit").length >= 1);

    expect(router.hasApp("alpha")).toBe(true);
    expect(router.hasApp("beta")).toBe(false);
    // Not "started then stopped" — never started at all.
    expect(session.envelopesFor("beta", "app")).toEqual([]);
    expect(session.envelopesFor("beta", "commit")).toEqual([]);
    expect(session.lastCatalog.find((app) => app.id === "beta")?.enabled).toBe(false);
  }, 30000);

  test("disabling stops the worker, rewrites the file, and re-publishes the catalog", async () => {
    const { dir, appsRoot } = await makeRoot({
      settings: PRIVILEGED_APP,
      alpha: PLAIN_APP("Alpha"),
    });
    const settingsPath = join(dir, "settings.json");
    const log: string[] = [];
    const session = new RecordingSession();
    const router = new Router({
      appsRoot,
      settingsPath,
      watch: false,
      log: (line) => log.push(line),
    });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("alpha", "commit").length >= 1);

    toggle(router, session, "alpha", false);
    await waitFor(() => log.some((line) => line.includes("ok: alpha -> false")));

    expect(router.hasApp("alpha")).toBe(false);
    expect(await Bun.file(settingsPath).json()).toEqual({ disabled: ["alpha"] });
    // §3.2 `stopped` reaches the shell, and the §3.6 snapshot that follows it
    // is a FULL catalog with the row flipped — no diffs.
    expect(session.envelopesFor("alpha", "app").at(-1)?.payload.state).toBe("stopped");
    expect(session.lastCatalog.find((app) => app.id === "alpha")).toMatchObject({
      id: "alpha",
      // The name the app declared survives the stop: a disabled row should not
      // fall back to its directory name just because its worker is gone.
      name: "Alpha",
      enabled: false,
      running: false,
    });

    // …and back on: a fresh worker, a fresh mount, an empty settings file.
    const commitsBefore = session.envelopesFor("alpha", "commit").length;
    toggle(router, session, "alpha", true);
    await waitFor(() => log.some((line) => line.includes("ok: alpha -> true")));
    await waitFor(() => session.envelopesFor("alpha", "commit").length > commitsBefore);
    expect(router.hasApp("alpha")).toBe(true);
    expect(await Bun.file(settingsPath).json()).toEqual({ disabled: [] });
    expect(session.lastCatalog.find((app) => app.id === "alpha")?.enabled).toBe(true);
  }, 30000);

  test("appControl stops and starts an app, and leaves it installed either way", async () => {
    // flow.md, "The strip": "the only ✕ in the product lives here". It arrives
    // as `appControl` (spec §4.3) — a control-plane frame from the shell, not a
    // worker's request — and lands on exactly the enable/disable machinery the
    // privileged bridge uses, so "is this app running" has one answer.
    //
    // `start` is the same envelope with the other verb, and it is what the
    // native Settings window sends: with no privileged app there is no worker
    // left to call `ctx.platform.enable` from, so the ✕ needs a way back that
    // does not depend on an app being running.
    const { dir, appsRoot } = await makeRoot({
      settings: PRIVILEGED_APP,
      alpha: PLAIN_APP("Alpha"),
    });
    const settingsPath = join(dir, "settings.json");
    const log: string[] = [];
    const session = new RecordingSession();
    const router = new Router({ appsRoot, settingsPath, watch: false, log: (line) => log.push(line) });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("alpha", "commit").length >= 1);

    router.onEnvelope(session, envelope("", "appControl", { app: "alpha", action: "stop" }));
    await waitFor(() => !router.hasApp("alpha"));

    expect(session.envelopesFor("alpha", "app").at(-1)?.payload.state).toBe("stopped");
    // Installed, and off: the folder is untouched and the catalog still names it.
    expect(await Bun.file(settingsPath).json()).toEqual({ disabled: ["alpha"] });
    expect(session.lastCatalog.find((app) => app.id === "alpha")).toMatchObject({
      id: "alpha",
      name: "Alpha",
      enabled: false,
      running: false,
    });
    expect((await readdir(appsRoot)).includes("alpha")).toBe(true);

    // …and back on, over the same envelope: a fresh worker, a fresh mount, and
    // a settings file that has forgotten the whole thing.
    const commitsBefore = session.envelopesFor("alpha", "commit").length;
    router.onEnvelope(session, envelope("", "appControl", { app: "alpha", action: "start" }));
    await waitFor(() => session.envelopesFor("alpha", "commit").length > commitsBefore);
    expect(router.hasApp("alpha")).toBe(true);
    expect(await Bun.file(settingsPath).json()).toEqual({ disabled: [] });
    expect(session.lastCatalog.find((app) => app.id === "alpha")?.enabled).toBe(true);

    // Nothing else is an action: an unknown verb, or a nameless one, is ignored
    // rather than guessed at.
    router.onEnvelope(session, envelope("", "appControl", { app: "settings", action: "burn" }));
    router.onEnvelope(session, envelope("", "appControl", { action: "stop" }));
    expect(router.hasApp("settings")).toBe(true);
    expect(router.hasApp("alpha")).toBe(true);
  }, 30000);

  test("a privileged worker reads the host's catalog through ctx.platform.stats()", async () => {
    // The other half of the privileged surface: `enable`/`disable` write the
    // host's state, `stats()` reads it, and a shape mismatch between the two
    // shows up here and nowhere else.
    //
    // This used to mount `protocol/demo-apps/settings/app.jsx` and read rows out
    // of its commits. That was an app test wearing a wire test's clothes, and
    // the app is archived (`protocol/demo-apps-archive/settings-app`) now that
    // Settings is a native macOS window. The fixture asks the same question of
    // the same bridge, through a real worker, without an app to maintain.
    const { dir, appsRoot } = await makeRoot({
      settings: PRIVILEGED_APP,
      alpha: PLAIN_APP("Alpha"),
      beta: PLAIN_APP("Beta"),
    });
    await writeFile(join(dir, "settings.json"), JSON.stringify({ disabled: ["beta"] }));

    const log: string[] = [];
    const session = new RecordingSession();
    const router = new Router({
      appsRoot,
      settingsPath: join(dir, "settings.json"),
      watch: false,
      log: (line) => log.push(line),
    });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => log.some((line) => line.includes("catalog: ")));
    const catalog = log.find((line) => line.includes("catalog: "))!;
    // Every installed app, running or not, with the settings file's answer on
    // each — a disabled app is absent from the process table but present here.
    expect(catalog).toContain("alpha=true");
    expect(catalog).toContain("beta=false");
    expect(catalog).toContain("settings=true");
    // …and the worker never crashed on the way.
    expect(session.envelopesFor("settings", "app").map((e) => e.payload.state)).toEqual(["started"]);
  }, 30000);


  test("quit is Settings-only, like the rest of the management surface", async () => {
    const { dir, appsRoot } = await makeRoot({
      settings: PRIVILEGED_APP,
      alpha: PLAIN_APP("Alpha"),
    });
    const session = new RecordingSession();
    const router = new Router({
      appsRoot,
      settingsPath: join(dir, "settings.json"),
      watch: false,
    });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("alpha", "commit").length >= 1);

    // An ordinary app cannot even see `quit` on its ctx; if one arrived anyway
    // it must not reach the shell, because there is no undo for it.
    router.platform("alpha", 42, { kind: "quit" });
    await Bun.sleep(50);
    expect(session.envelopesFor("alpha", "platform")).toEqual([]);
  }, 30000);

  test("app management is Settings-only, and never reaches the shell", async () => {
    const { dir, appsRoot } = await makeRoot({
      settings: PRIVILEGED_APP,
      alpha: PLAIN_APP("Alpha"),
    });
    const session = new RecordingSession();
    const router = new Router({
      appsRoot,
      settingsPath: join(dir, "settings.json"),
      watch: false,
    });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("alpha", "commit").length >= 1);

    // The ctx surface already hides these from an ordinary app (worker/ctx.ts);
    // this is the host refusing the same call arriving anyway.
    router.platform("alpha", 999, { kind: "disable", app: "settings" });
    await Bun.sleep(50);
    expect(session.envelopesFor("alpha", "platform")).toEqual([]);
    expect(router.hasApp("settings")).toBe(true);
  }, 30000);
});
