import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  AppSupervisor,
  type AppState,
  type RestartScheduler,
  type SupervisorSink,
} from "../src/supervisor";
import type { WorkerFactory, WorkerHandle, WorkerHooks } from "../src/worker-factory";
import type { Mutation } from "../src/render/mutations";
import type {
  AppMeta,
  ChromeRequest,
  HostToWorker,
  NotifyRequest,
  WingSpec,
  WorkerBoot,
} from "../src/worker/messages";

// AppSupervisor in isolation (spec §6 rule 2, §7): a FAKE worker (no thread) and
// a FAKE scheduler (no real sleeps) make the crash → crash.log → backoff respawn
// policy fully deterministic. The transpile check is stubbed unless a test wants
// to exercise a real parse error.

// --- Fakes -------------------------------------------------------------------

class FakeScheduler implements RestartScheduler {
  time = 0;
  private pending: Array<{ at: number; ms: number; cb: () => void; cancelled: boolean }> = [];

  now(): number {
    return this.time;
  }
  schedule(ms: number, cb: () => void): () => void {
    const entry = { at: this.time + ms, ms, cb, cancelled: false };
    this.pending.push(entry);
    return () => {
      entry.cancelled = true;
    };
  }
  /** Delays currently scheduled (for asserting the backoff curve). */
  get delays(): number[] {
    return this.pending.filter((e) => !e.cancelled).map((e) => e.ms);
  }
  /** Fire the earliest live timer, advancing the clock to its due time. */
  fireNext(): number {
    const entry = this.pending.filter((e) => !e.cancelled).sort((a, b) => a.at - b.at)[0];
    if (!entry) throw new Error("no pending timer");
    this.time = entry.at;
    entry.cancelled = true;
    entry.cb();
    return entry.ms;
  }
  hasPending(): boolean {
    return this.pending.some((e) => !e.cancelled);
  }
}

class FakeWorker {
  posts: HostToWorker[] = [];
  terminated = false;
  readonly hooks: WorkerHooks;
  readonly handle: WorkerHandle;
  constructor(hooks: WorkerHooks) {
    this.hooks = hooks;
    this.handle = {
      post: (msg) => this.posts.push(msg),
      terminate: () => {
        this.terminated = true;
      },
    };
  }
}

function fakeFactory(): {
  factory: WorkerFactory;
  instances: FakeWorker[];
  boots: WorkerBoot[];
} {
  const instances: FakeWorker[] = [];
  const boots: WorkerBoot[] = [];
  const factory: WorkerFactory = (boot, hooks) => {
    boots.push(boot);
    const worker = new FakeWorker(hooks);
    instances.push(worker);
    return worker.handle;
  };
  return { factory, instances, boots };
}

class RecordingSink implements SupervisorSink {
  commits: Array<{ app: string; mutations: Mutation[] }> = [];
  metas: Array<{ app: string; meta: AppMeta }> = [];
  draws: Array<{ app: string; id: number; ops: unknown[] }> = [];
  wingRequests: Array<{ app: string; wing: WingSpec | null }> = [];
  chromes: Array<{ app: string; request: ChromeRequest }> = [];
  notifies: Array<{ app: string; text: string; attention: boolean }> = [];
  attentions: string[] = [];
  apples: Array<{ app: string; id: number }> = [];
  platforms: Array<{ app: string; id: number }> = [];
  lifecycles: Array<{ app: string; state: AppState; error?: { message: string } }> = [];
  captures: Array<{ app: string; id: number }> = [];
  agents: Array<{ app: string; id: number }> = [];
  logs: string[] = [];

  commit(app: string, mutations: Mutation[]): void {
    this.commits.push({ app, mutations });
  }
  meta(app: string, meta: AppMeta): void {
    this.metas.push({ app, meta });
  }
  draw(app: string, id: number, ops: unknown[]): void {
    this.draws.push({ app, id, ops });
  }
  wing(app: string, wing: WingSpec | null): void {
    this.wingRequests.push({ app, wing });
  }
  chrome(app: string, request: ChromeRequest): void {
    this.chromes.push({ app, request });
  }
  notify(app: string, notification: NotifyRequest): void {
    this.notifies.push({ app, text: notification.text, attention: notification.attention });
  }
  attention(app: string): void {
    this.attentions.push(app);
  }
  apple(app: string, id: number): void {
    this.apples.push({ app, id });
  }
  capture(app: string, id: number): void {
    this.captures.push({ app, id });
  }
  agent(app: string, id: number): void {
    this.agents.push({ app, id });
  }
  platform(app: string, id: number): void {
    this.platforms.push({ app, id });
  }
  lifecycle(app: string, state: AppState, error?: { message: string }): void {
    this.lifecycles.push({ app, state, error });
  }
  log(app: string, line: string): void {
    this.logs.push(`${app}: ${line}`);
  }
}

const settle = () => Bun.sleep(5); // let an async handleCrash/spawn finish

// --- Fixtures on disk --------------------------------------------------------

let dirs: string[] = [];
async function appDir(source = "export default function(){}"): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "ledge-sup-"));
  await writeFile(join(dir, "app.jsx"), source);
  dirs.push(dir);
  return dir;
}

afterEach(async () => {
  for (const dir of dirs) await rm(dir, { recursive: true, force: true });
  dirs = [];
});

// --- Tests -------------------------------------------------------------------

describe("AppSupervisor", () => {
  test("start emits `started` before any commit and spawns one worker", async () => {
    const dir = await appDir();
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    const sup = new AppSupervisor({
      appId: "x",
      appDir: dir,
      sink,
      factory,
      scheduler: new FakeScheduler(),
      transpile: async () => null,
    });
    await sup.start();

    expect(instances.length).toBe(1);
    expect(sink.lifecycles).toEqual([{ app: "x", state: "started", error: undefined }]);
    sup.stop();
  });

  test("worker messages route to the sink; apple/platform get not-implemented replies", async () => {
    const dir = await appDir();
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    // The router is the sink; here we assert the supervisor forwards faithfully.
    const sup = new AppSupervisor({ appId: "x", appDir: dir, sink, factory, transpile: async () => null });
    await sup.start();
    const worker = instances[0]!;

    worker.hooks.onMessage({ type: "commit", mutations: [{ op: "setRoot", id: 1 }] });
    worker.hooks.onMessage({ type: "notify", id: 1, text: "hi", attention: true });
    worker.hooks.onMessage({ type: "attention" });
    worker.hooks.onMessage({ type: "console", level: "log", text: "line one" });

    expect(sink.commits.length).toBe(1);
    expect(sink.notifies).toEqual([{ app: "x", text: "hi", attention: true }]);
    expect(sink.attentions).toEqual(["x"]);
    expect(sink.logs.some((l) => l.includes("line one"))).toBe(true);
    sup.stop();
  });

  test("a transpile error crashes without spawning and writes crash.log (spec §7)", async () => {
    const dir = await appDir("export default function(){ return <text ; }"); // bad JSX
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    const sched = new FakeScheduler();
    const sup = new AppSupervisor({ appId: "x", appDir: dir, sink, factory, scheduler: sched });
    await sup.start();

    expect(instances.length).toBe(0); // never spawned
    expect(sink.lifecycles.some((l) => l.state === "crashed")).toBe(true);
    const log = await Bun.file(join(dir, "crash.log")).text();
    expect(log).toContain("crash");
    expect(sched.hasPending()).toBe(true); // a backoff restart is queued
    sup.stop();
  });

  test("crash → crash.log (with console ring) → crashed lifecycle → backoff respawn", async () => {
    const dir = await appDir();
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    const sched = new FakeScheduler();
    const sup = new AppSupervisor({
      appId: "stocks",
      appDir: dir,
      sink,
      factory,
      scheduler: sched,
      transpile: async () => null,
    });
    await sup.start();
    const first = instances[0]!;

    // A console line lands in the ring, then the monitor throws.
    first.hooks.onMessage({ type: "console", level: "error", text: "about to boom" });
    first.hooks.onMessage({ type: "crash", phase: "monitor", message: "kaboom", stack: "Error: kaboom\n  at app.jsx:3" });
    await settle();

    expect(first.terminated).toBe(true);
    const crashed = sink.lifecycles.find((l) => l.state === "crashed");
    expect(crashed?.error?.message).toBe("kaboom");

    const log = await Bun.file(join(dir, "crash.log")).text();
    expect(log).toContain("kaboom");
    expect(log).toContain("at app.jsx:3");
    expect(log).toContain("about to boom"); // ring buffer captured

    // First backoff is 1 s; nothing respawned until it fires.
    expect(sched.delays).toEqual([1000]);
    expect(instances.length).toBe(1);
    sched.fireNext();
    await settle();
    expect(instances.length).toBe(2); // respawned
    expect(sink.lifecycles.filter((l) => l.state === "started").length).toBe(2);
    sup.stop();
  });

  test("backoff grows exponentially and gives up after the attempt cap (spec §6 rule 2)", async () => {
    const dir = await appDir();
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    const sched = new FakeScheduler();
    const sup = new AppSupervisor({
      appId: "x",
      appDir: dir,
      sink,
      factory,
      scheduler: sched,
      transpile: async () => null,
      backoff: { minMs: 1000, maxMs: 120_000, maxAttempts: 5, healthyResetMs: 600_000 },
    });
    await sup.start();

    const crash = () => instances.at(-1)!.hooks.onMessage({ type: "crash", phase: "monitor", message: "x", stack: null });
    const seen: number[] = [];

    // Crash immediately each time (well under healthyResetMs), so attempts escalate.
    for (let i = 0; i < 5; i += 1) {
      crash();
      await settle();
      seen.push(sched.fireNext()); // fire the scheduled backoff, spawning the next worker
      await settle();
    }
    // The 6th crash exceeds maxAttempts → give up, no further timer.
    crash();
    await settle();

    expect(seen).toEqual([1000, 2000, 4000, 8000, 16000]);
    expect(sched.hasPending()).toBe(false);
    expect(sink.logs.some((l) => l.includes("giving up"))).toBe(true);
    sup.stop();
  });

  test("a healthy run (>= reset window) resets the backoff counter", async () => {
    const dir = await appDir();
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    const sched = new FakeScheduler();
    const sup = new AppSupervisor({
      appId: "x",
      appDir: dir,
      sink,
      factory,
      scheduler: sched,
      transpile: async () => null,
      backoff: { minMs: 1000, maxMs: 120_000, maxAttempts: 5, healthyResetMs: 600_000 },
    });
    await sup.start();

    // Crash once (attempt → 1), fire its 1 s backoff.
    instances[0]!.hooks.onMessage({ type: "crash", phase: "monitor", message: "x", stack: null });
    await settle();
    expect(sched.delays).toEqual([1000]);
    sched.fireNext();
    await settle();

    // The respawned worker runs healthily for 11 minutes, then crashes.
    sched.time += 11 * 60_000;
    instances.at(-1)!.hooks.onMessage({ type: "crash", phase: "monitor", message: "x", stack: null });
    await settle();
    // Counter reset by the healthy run → back to the 1 s floor, not 2 s.
    expect(sched.delays).toEqual([1000]);
    sup.stop();
  });

  test("reload terminates the old worker and respawns with `reloaded`", async () => {
    const dir = await appDir();
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    const sup = new AppSupervisor({ appId: "x", appDir: dir, sink, factory, transpile: async () => null });
    await sup.start();
    const first = instances[0]!;

    await sup.reload();
    expect(first.terminated).toBe(true);
    expect(instances.length).toBe(2);
    expect(sink.lifecycles.map((l) => l.state)).toEqual(["started", "reloaded"]);
    sup.stop();
  });

  test("stop terminates and reports `stopped`; no further restarts", async () => {
    const dir = await appDir();
    const sink = new RecordingSink();
    const { factory, instances } = fakeFactory();
    const sched = new FakeScheduler();
    const sup = new AppSupervisor({ appId: "x", appDir: dir, sink, factory, scheduler: sched, transpile: async () => null });
    await sup.start();

    sup.stop();
    expect(instances[0]!.terminated).toBe(true);
    expect(sink.lifecycles.at(-1)).toEqual({ app: "x", state: "stopped", error: undefined });

    // A late crash after stop must not schedule a restart.
    instances[0]!.hooks.onMessage({ type: "crash", phase: "monitor", message: "late", stack: null });
    await settle();
    expect(sched.hasPending()).toBe(false);
  });

  // Where React lives is resolved ONCE, on the host thread, and handed to every
  // worker (src/render/runtime.ts, ReactPaths). A worker that resolves it itself
  // walks node_modules through a process-global cache, and several doing that at
  // once segfaults Bun 1.3.9. The invariant is boring and easy to lose in a
  // refactor, so it is asserted where the boot is actually built.
  test("every boot carries the react paths it was given, including after a reload", async () => {
    const dir = await appDir();
    const { factory, boots } = fakeFactory();
    const sink = new RecordingSink();
    const reactPaths = {
      react: "/apps/node_modules/react/index.js",
      reconciler: "/apps/node_modules/react-reconciler/index.js",
      constants: "/apps/node_modules/react-reconciler/constants.js",
    };
    const sup = new AppSupervisor({
      appId: "x",
      appDir: dir,
      sink,
      factory,
      reactPaths,
      transpile: async () => null,
    });
    await sup.start();
    await sup.reload();
    expect(boots).toHaveLength(2);
    expect(boots.every((boot) => boot.reactPaths === reactPaths)).toBe(true);
  });
});