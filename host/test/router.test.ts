import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import { Router } from "../src/router";
import type { RestartScheduler } from "../src/supervisor";
import type { Mutation } from "../src/render/mutations";

// Router + REAL Bun workers against a recording ShellSession (spec §§3–4). This is
// the host-side end-to-end: a genuine worker mounts through the supervisor, the
// router translates commit batches to envelopes, an injected shell event drives a
// follow-up commit, and a hot reload respawns with a fresh mount. Backoff timing
// is on an injected fake clock so the crash test never sleeps for real.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");

class RecordingSession implements ShellSession {
  gen = 7;
  screen = { notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480 };
  sent: Array<{ app: string; type: string; payload: Record<string, unknown> }> = [];
  send(app: string, type: string, payload: Record<string, unknown>): void {
    this.sent.push({ app, type, payload });
  }
  envelopesFor(app: string, type: string) {
    return this.sent.filter((e) => e.app === app && e.type === type);
  }
}

class FakeScheduler implements RestartScheduler {
  time = 0;
  private pending: Array<{ at: number; cb: () => void; cancelled: boolean }> = [];
  now(): number {
    return this.time;
  }
  schedule(ms: number, cb: () => void): () => void {
    const entry = { at: this.time + ms, cb, cancelled: false };
    this.pending.push(entry);
    return () => {
      entry.cancelled = true;
    };
  }
  fireNext(): void {
    const entry = this.pending.filter((e) => !e.cancelled).sort((a, b) => a.at - b.at)[0];
    if (!entry) throw new Error("no pending timer");
    this.time = entry.at;
    entry.cancelled = true;
    entry.cb();
  }
  hasPending(): boolean {
    return this.pending.some((e) => !e.cancelled);
  }
}

const COUNTER = (start: number) => `/** @jsxImportSource react */
import { useState } from "react";
export default function Counter() {
  const [n, setN] = useState(${start});
  return (
    <stack axis="v" pad={12} gap={6}>
      <text content={\`count \${n}\`} />
      <button label="+" variant="glass" onClick={() => setN((c) => c + 1)} />
    </stack>
  );
}
`;

const CRASHER = `/** @jsxImportSource react */
export async function monitor() {
  throw new Error("kaboom");
}
export default function Crasher() {
  return <text content="crash" />;
}
`;

let roots: string[] = [];
async function makeAppsRoot(apps: Record<string, string>): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ledge-router-"));
  roots.push(root);
  // Shared node_modules at the apps root — the analogue of ~/.ledge/node_modules
  // (spec §6) — so an app's `import "react"` resolves.
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

const createOfKind = (mutations: Mutation[], kind: string) =>
  mutations.find((m): m is Extract<Mutation, { op: "create" }> => m.op === "create" && m.kind === kind);

const eventEnvelope = (app: string, id: number): Envelope => ({
  v: 1,
  app,
  seq: 1,
  type: "event",
  payload: { id, name: "click", data: {} },
});

let openRouter: Router | null = null;
afterEach(async () => {
  openRouter?.shutdown();
  openRouter = null;
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
  await Bun.sleep(10); // let terminated workers unwind
});

describe("Router end-to-end (real workers)", () => {
  test("hello→catalog→started→mount, event→commit, hot reload→reloaded→remount", async () => {
    const root = await makeAppsRoot({ counter: COUNTER(0) });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, scheduler: new FakeScheduler(), watch: false });
    openRouter = router;

    await router.bindSession(session);

    // Catalog delivered first (spec §1).
    const catalog = session.envelopesFor("", "catalog");
    expect(catalog.length).toBe(1);
    expect((catalog[0]!.payload.apps as Array<{ id: string }>).map((a) => a.id)).toEqual(["counter"]);

    // `started` lifecycle, then the mount commit.
    await waitFor(() => session.envelopesFor("counter", "commit").length >= 1);
    expect(session.envelopesFor("counter", "app").some((e) => e.payload.state === "started")).toBe(true);

    const mount = session.envelopesFor("counter", "commit")[0]!.payload.mutations as Mutation[];
    expect(mount.at(-1)!.op).toBe("setRoot");
    const button = createOfKind(mount, "button")!;
    const text = createOfKind(mount, "text")!;
    expect(text.props.content).toBe("count 0");

    // Inject a shell click event → handler bumps state → follow-up commit.
    router.onEnvelope(session, eventEnvelope("counter", button.id));
    await waitFor(() =>
      session
        .envelopesFor("counter", "commit")
        .slice(1)
        .some((e) => (e.payload.mutations as Mutation[]).some((m) => m.op === "update")),
    );
    const update = session
      .envelopesFor("counter", "commit")
      .flatMap((e) => e.payload.mutations as Mutation[])
      .find((m): m is Extract<Mutation, { op: "update" }> => m.op === "update")!;
    expect(update.id).toBe(text.id);
    expect(update.props.content).toBe("count 1");

    // Hot reload: rewrite app.jsx, reload → `reloaded` lifecycle + fresh mount.
    await writeFile(join(root, "counter", "app.jsx"), COUNTER(100));
    const commitsBefore = session.envelopesFor("counter", "commit").length;
    router.reloadApp("counter");

    await waitFor(() => session.envelopesFor("counter", "app").some((e) => e.payload.state === "reloaded"));
    await waitFor(() => session.envelopesFor("counter", "commit").length > commitsBefore);
    const remount = session.envelopesFor("counter", "commit").at(-1)!.payload.mutations as Mutation[];
    // The respawned worker restarts its ids at 1 and re-reads the file.
    expect(createOfKind(remount, "text")!.props.content).toBe("count 100");
    expect(remount.at(-1)!.op).toBe("setRoot");
  }, 30000);

  test("event envelope with an unknown app is ignored (no throw)", async () => {
    const root = await makeAppsRoot({ counter: COUNTER(0) });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, scheduler: new FakeScheduler(), watch: false });
    openRouter = router;
    await router.bindSession(session);
    // Should be a silent no-op.
    router.onEnvelope(session, eventEnvelope("ghost", 1));
    expect(router.hasApp("ghost")).toBe(false);
  }, 20000);

  test("a crashing app → crashed lifecycle + crash.log + backoff respawn (fake clock)", async () => {
    const root = await makeAppsRoot({ crasher: CRASHER });
    const session = new RecordingSession();
    const scheduler = new FakeScheduler();
    const router = new Router({ appsRoot: root, scheduler, watch: false });
    openRouter = router;

    await router.bindSession(session);

    // The monitor throws on first call → crashed lifecycle with the error.
    await waitFor(() => session.envelopesFor("crasher", "app").some((e) => e.payload.state === "crashed"));
    const crashed = session.envelopesFor("crasher", "app").find((e) => e.payload.state === "crashed")!;
    expect((crashed.payload.error as { message: string }).message).toBe("kaboom");

    // crash.log written into the app folder (spec §7).
    const log = await Bun.file(join(root, "crasher", "crash.log")).text();
    expect(log).toContain("kaboom");

    // A backoff restart is queued on the fake clock; fire it → respawn → started.
    await waitFor(() => scheduler.hasPending());
    const startsBefore = session.envelopesFor("crasher", "app").filter((e) => e.payload.state === "started").length;
    scheduler.fireNext();
    await waitFor(
      () => session.envelopesFor("crasher", "app").filter((e) => e.payload.state === "started").length > startsBefore,
    );
  }, 30000);

  // The registry used to be read once, at bindSession, so an app created after
  // the host started was invisible until it restarted. That blocks the whole
  // builder flow: the agent scaffolds a folder and then has nothing to show.
  test("an app folder created after bind is scanned, published, and started", async () => {
    const root = await makeAppsRoot({ counter: COUNTER(0) });
    const session = new RecordingSession();
    // Real watcher here (watch: true) — the rescan is triggered by fs events,
    // so a fake would test everything except the part that was missing.
    const router = new Router({ appsRoot: root, scheduler: new FakeScheduler(), watch: true });
    openRouter = router;

    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("counter", "commit").length >= 1);
    // (More than one catalog by now is normal: the worker's `meta` re-publishes
    // the full snapshot, spec §3.6. What matters is that nothing names the app
    // that does not exist yet.)
    expect(
      session
        .envelopesFor("", "catalog")
        .some((e) => (e.payload.apps as Array<{ id: string }>).some((a) => a.id === "flights")),
    ).toBe(false);

    // What `ledge new` / an agent scaffolding an app does on disk.
    await mkdir(join(root, "flights"), { recursive: true });
    await writeFile(join(root, "flights", "app.jsx"), COUNTER(41));

    // A fresh catalog naming the new app…
    await waitFor(() =>
      session
        .envelopesFor("", "catalog")
        .some((e) => (e.payload.apps as Array<{ id: string }>).some((a) => a.id === "flights")),
    );
    // …and a worker that actually mounted it.
    await waitFor(() => session.envelopesFor("flights", "commit").length >= 1);
    const mount = session.envelopesFor("flights", "commit")[0]!.payload.mutations as Mutation[];
    expect(createOfKind(mount, "text")!.props.content).toBe("count 41");

    // The pre-existing app is untouched — a rescan must not restart the world.
    expect(session.envelopesFor("counter", "app").filter((e) => e.payload.state === "started").length).toBe(1);
  }, 30000);
});
