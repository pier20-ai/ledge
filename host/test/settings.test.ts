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
import { InMemorySink, type Mutation } from "../src/render/mutations";
import { createAppSession } from "../src/render/session";
import { loadReactRuntime } from "../src/render/runtime";

// Settings, the enable/disable half (spec §3.6 `enabled`, §8): the file that
// remembers it, the registry flag it produces, the privileged host-side bridge
// that flips it, and the shipped app that renders it.
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

/** A Settings stand-in: reads the catalog once, then waits to be told what to
 * toggle. The id-0 event is the app-level convention (§4.1), which is the
 * cheapest way for a test to press a switch without owning a node id. */
const SETTINGS_APP = `/** @jsxImportSource react */
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

  test("Settings cannot be disabled, however it is asked", async () => {
    const { dir } = await makeRoot({});
    const path = join(dir, "settings.json");
    const store = new SettingsStore(path);
    await store.load();
    expect(store.setEnabled("settings", false)).rejects.toThrow(/cannot be disabled/);

    // Nor by editing the file: it is the only way back from everything else on
    // that panel, so a hand-written entry is dropped rather than honoured.
    await writeFile(path, JSON.stringify({ disabled: ["settings", "music"] }));
    const reread = new SettingsStore(path);
    await reread.load();
    expect(reread.isEnabled("settings")).toBe(true);
    expect(reread.isEnabled("music")).toBe(false);
  });

  test("a settings file that will not parse means everything runs", async () => {
    const { dir } = await makeRoot({});
    const path = join(dir, "settings.json");
    await writeFile(path, "{ this is not json");
    const store = new SettingsStore(path);
    await store.load();
    // Refusing to boot would strand the user with no Settings app to fix it from.
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
      settings: SETTINGS_APP,
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
      settings: SETTINGS_APP,
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

  test("Settings refuses to disable itself, and says why", async () => {
    const { dir, appsRoot } = await makeRoot({ settings: SETTINGS_APP });
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
    await waitFor(() => session.envelopesFor("settings", "commit").length >= 1);

    toggle(router, session, "settings", false);
    await waitFor(() => log.some((line) => line.includes("refused:")));
    expect(log.find((line) => line.includes("refused:"))).toContain("cannot be disabled");
    expect(router.hasApp("settings")).toBe(true);
  }, 30000);

  test("the SHIPPED Settings app, in a real privileged worker, renders the real catalog", async () => {
    // The fixture above proves the bridge; this proves the app that ships on top
    // of it — same file, real worker, real monitor, real `ctx.platform.stats()`.
    const source = await Bun.file(
      join(HOST_DIR, "..", "protocol", "demo-apps", "settings", "app.jsx"),
    ).text();
    const { dir, appsRoot } = await makeRoot({
      settings: source,
      alpha: PLAIN_APP("Alpha"),
      beta: PLAIN_APP("Beta"),
    });
    await writeFile(join(dir, "settings.json"), JSON.stringify({ disabled: ["beta"] }));

    const session = new RecordingSession();
    const router = new Router({
      appsRoot,
      settingsPath: join(dir, "settings.json"),
      watch: false,
    });
    openRouter = router;
    await router.bindSession(session);

    // The mount frame is the placeholder; the frame after the first `stats()`
    // is the one with rows in it.
    const rowText = () =>
      session
        .envelopesFor("settings", "commit")
        .flatMap((e) => e.payload.mutations as Mutation[])
        .filter((m) => m.op === "create" || m.op === "update")
        .map((m) => (m as { props: Record<string, unknown> }).props.content);
    await waitFor(() => rowText().includes("Alpha"));

    const text = rowText();
    expect(text).toContain("Beta");
    // Two of the three are on, and the app said so without being told twice.
    expect(text).toContain("2 of 3 on");
    // …and it never crashed on the way (a mismatched stats() shape would show
    // up here and nowhere else).
    expect(session.envelopesFor("settings", "app").map((e) => e.payload.state)).toEqual(["started"]);
  }, 30000);

  test("the shipped Permissions button raises shell permission chrome", async () => {
    const source = await Bun.file(
      join(HOST_DIR, "..", "protocol", "demo-apps", "settings", "app.jsx"),
    ).text();
    const { dir, appsRoot } = await makeRoot({ settings: source });
    const session = new RecordingSession();
    const router = new Router({
      appsRoot,
      settingsPath: join(dir, "settings.json"),
      watch: false,
    });
    openRouter = router;
    await router.bindSession(session);

    const buttonId = (): number | undefined => {
      for (const commit of session.envelopesFor("settings", "commit")) {
        for (const mutation of commit.payload.mutations as Mutation[]) {
          if (
            mutation.op === "create"
            && mutation.kind === "button"
            && mutation.props.label === "Permissions…"
          ) {
            return mutation.id;
          }
        }
      }
      return undefined;
    };

    await waitFor(() => buttonId() !== undefined);
    router.onEnvelope(
      session,
      envelope("settings", "event", { id: buttonId()!, name: "click", data: {} }),
    );
    await waitFor(() => session.envelopesFor("settings", "chrome").length >= 1);
    expect(session.envelopesFor("settings", "chrome").at(-1)?.payload).toEqual({
      request: "permissions",
    });
  }, 30000);

  test("the Quit button, pressed twice, puts a quit call on the wire", async () => {
    // The whole chain on this side of the socket: the shipped app.jsx in a real
    // privileged worker, real clicks routed to real handlers, and the envelope
    // the SHELL will act on. Ledge has no menu-bar item and no Dock icon, so
    // this is the only quit there is — worth testing as a path, not a shape.
    const source = await Bun.file(
      join(HOST_DIR, "..", "protocol", "demo-apps", "settings", "app.jsx"),
    ).text();
    const { dir, appsRoot } = await makeRoot({ settings: source });
    const session = new RecordingSession();
    const router = new Router({
      appsRoot,
      settingsPath: join(dir, "settings.json"),
      watch: false,
    });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("settings", "commit").length >= 1);

    /**
     * Which node currently carries this button label.
     *
     * Updates count, not just creates: the reconciler re-uses a node and swaps
     * its `label` when a row's shape changes, so the idle "Quit" becomes the
     * armed "Cancel" in place. Reading creates only made this test pass or fail
     * on whether React happened to re-use a node — which is not what it is for.
     */
    const buttonId = (label: string): number | undefined => {
      const labels = new Map<number, unknown>();
      for (const commit of session.envelopesFor("settings", "commit")) {
        for (const mutation of commit.payload.mutations as Mutation[]) {
          if (mutation.op === "create" && mutation.kind === "button") {
            labels.set(mutation.id, mutation.props.label);
          } else if (mutation.op === "update" && labels.has(mutation.id) && "label" in mutation.props) {
            labels.set(mutation.id, mutation.props.label);
          } else if (mutation.op === "remove") {
            labels.delete(mutation.id);
          }
        }
      }
      for (const [id, current] of labels) if (current === label) return id;
      return undefined;
    };
    const click = (id: number) =>
      router.onEnvelope(session, envelope("settings", "event", { id, name: "click", data: {} }));

    // Press one: arm. Nothing goes out — an accidental brush of the panel must
    // not take the notch away, and there is no Dock icon to get it back from.
    const quit = await waitFor(() => buttonId("Quit") !== undefined).then(() => buttonId("Quit")!);
    click(quit);
    await waitFor(() => buttonId("Cancel") !== undefined);
    expect(session.envelopesFor("settings", "platform")).toEqual([]);

    // Press two. The reconciler re-uses the node and swaps the handler, so this
    // is the same id carrying a different meaning — which is exactly why the
    // first press must not have sent anything.
    click(buttonId("Quit")!);
    await waitFor(() => session.envelopesFor("settings", "platform").length >= 1);

    const call = session.envelopesFor("settings", "platform")[0]!.payload;
    expect(call.call).toBe("quit");
    expect(Number.isInteger(call.id)).toBe(true);
    // Forwarded, not answered here: only the shell can end the process.
    expect(Object.keys(call).sort()).toEqual(["call", "id"]);
  }, 30000);

  test("quit is Settings-only, like the rest of the management surface", async () => {
    const { dir, appsRoot } = await makeRoot({
      settings: SETTINGS_APP,
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
      settings: SETTINGS_APP,
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

// --- the app -----------------------------------------------------------------

const DEMO_APPS = join(HOST_DIR, "..", "protocol", "demo-apps");
const settingsUrl = new URL("../../protocol/demo-apps/settings/app.jsx", import.meta.url).href;

/**
 * Mount the shipped app in-process, against the React the APPS ROOT resolves —
 * not the host's own. They are two installed copies of the same version, and
 * hooks live in module-level state, so mounting a hook-using app through the
 * host's copy is `dispatcher.useState of null` (the rule in AGENTS.md, seen
 * from the other side). A worker gets this right for free: the host resolves
 * one runtime and hands it down.
 */
async function mountSettings(sink: InMemorySink) {
  const module = await import(settingsUrl);
  const runtime = await loadReactRuntime(DEMO_APPS);
  return createAppSession(module.default as never, sink, runtime);
}

/** Everything the shipped Settings panel is allowed to be made of (spec §5). */
const ALLOWED_KINDS = new Set([
  "stack",
  "text",
  "image",
  "toggle",
  "button",
  "spacer",
  "divider",
  "wing",
]);

type Create = Extract<Mutation, { op: "create" }>;

describe("the shipped Settings app", () => {
  test("renders one row per installed app, with a real switch on each", async () => {
    const sink = new InMemorySink();
    const session = await mountSettings(sink);
    session.update({
      ready: true,
      apps: [
        { id: "stocks", name: "Stocks", icon: "sf:chart.line.uptrend.xyaxis", enabled: true },
        { id: "music", name: "Music", icon: "sf:music.note", enabled: false },
        { id: "settings", name: "Settings", icon: "sf:slider.horizontal.3", enabled: true },
      ],
      onToggle: () => {},
    });

    const creates = sink.all.filter((m): m is Create => m.op === "create");
    for (const kind of creates.map((m) => m.kind)) {
      expect(ALLOWED_KINDS.has(kind)).toBe(true);
    }

    const toggles = creates.filter((m) => m.kind === "toggle");
    expect(toggles.map((m) => m.props.on)).toEqual([true, false, true]);
    // Every switch carries a handler — the whole complaint about the mockup was
    // three switches that moved and meant nothing.
    expect(toggles.every((m) => m.props.onChange === true)).toBe(true);
    // …except Settings' own, which is on and dead (spec §8: it can't be disabled).
    expect(toggles.map((m) => m.props.disabled)).toEqual([false, false, true]);

    // One icon per row, and the real names, not the mockup's three.
    expect(creates.filter((m) => m.kind === "image").length).toBe(3);
    const content = creates.filter((m) => m.kind === "text").map((m) => m.props.content);
    expect(content).toContain("Stocks");
    expect(content).toContain("Music");
    // The wing carries the count the deleted title row used to (spec §5). It is
    // an `update`, not a `create`: the wing's text node was mounted with the
    // placeholder and re-used, which is the reconciler doing its job.
    const contents = sink.all
      .filter((m) => m.op === "create" || m.op === "update")
      .map((m) => (m as { props: Record<string, unknown> }).props.content);
    expect(contents).toContain("2 of 3 on");
  });

  test("before the first catalog arrives it says so, rather than showing nothing", async () => {
    const sink = new InMemorySink();
    await mountSettings(sink);

    // The mount frame — the one `ledge shot` renders — runs before `monitor`
    // has said anything. An empty panel there would read as a broken app.
    const content = sink.all
      .filter((m): m is Create => m.op === "create" && m.kind === "text")
      .map((m) => m.props.content);
    expect(content).toContain("Reading the catalog…");
  });
});
