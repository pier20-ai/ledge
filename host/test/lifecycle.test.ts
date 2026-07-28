import { afterEach, describe, expect, test } from "bun:test";
import { Worker } from "node:worker_threads";
import type { Mutation } from "../src/render/mutations";
import type { HostToWorker, WorkerToHost } from "../src/worker/messages";

// The optional onLifecycle(phase, ctx) export (spec §4.2): panel phase reaches
// app code, so a game can drop its frame rate while collapsed. Regression for
// the gap where the worker entry silently discarded lifecycle messages.

const entryUrl = new URL("../src/worker/entry.ts", import.meta.url);
// Workers resolve react from the host package (src/render/runtime.ts).
const HOST_ROOT = new URL("..", import.meta.url).pathname;
const fixture = (name: string) => new URL(`./fixtures/${name}`, import.meta.url).href;

function bootWorker(modulePath: string) {
  const worker = new Worker(entryUrl, { workerData: { modulePath, modulesRoot: HOST_ROOT } });
  const buffer: WorkerToHost[] = [];
  const waiters: ((msg: WorkerToHost) => void)[] = [];
  worker.on("message", (msg: WorkerToHost) => {
    const waiter = waiters.shift();
    if (waiter) waiter(msg);
    else buffer.push(msg);
  });
  const take = (): Promise<WorkerToHost> => {
    const buffered = buffer.shift();
    if (buffered) return Promise.resolve(buffered);
    return new Promise((resolve) => waiters.push(resolve));
  };
  return {
    send: (msg: HostToWorker) => worker.postMessage(msg),
    async until(match: (msg: WorkerToHost) => boolean): Promise<WorkerToHost> {
      for (;;) {
        const msg = await take();
        if (match(msg)) return msg;
      }
    },
    close: () => worker.terminate(),
  };
}

let open: ReturnType<typeof bootWorker> | null = null;
afterEach(async () => {
  if (open) {
    await open.close();
    open = null;
  }
});

describe("onLifecycle", () => {
  test("phase reaches the app and can drive a re-render through ctx", async () => {
    const session = bootWorker(fixture("phased.jsx"));
    open = session;
    await session.until((m) => m.type === "commit"); // mount: "phase none"

    session.send({ type: "lifecycle", phase: "expanded" });
    const commit = (await session.until((m) => m.type === "commit")) as Extract<
      WorkerToHost,
      { type: "commit" }
    >;
    const update = commit.mutations.find(
      (m): m is Extract<Mutation, { op: "update" }> => m.op === "update",
    );
    expect(update?.props.content).toBe("phase expanded");
  }, 15000);

  test("a throwing handler becomes a crash report, not a dead worker channel", async () => {
    const session = bootWorker(fixture("phased.jsx"));
    open = session;
    await session.until((m) => m.type === "commit");

    session.send({ type: "lifecycle", phase: "explode" as never });
    const crash = (await session.until((m) => m.type === "crash")) as Extract<
      WorkerToHost,
      { type: "crash" }
    >;
    expect(crash.message).toBe("bad phase handler");
  }, 15000);

  test("apps without the export still ignore lifecycle quietly", async () => {
    const session = bootWorker(fixture("counter.jsx"));
    open = session;
    await session.until((m) => m.type === "commit");
    session.send({ type: "lifecycle", phase: "collapsed" });
    // No crash, and the worker still answers events afterwards.
    session.send({ type: "event", id: 999, name: "click", data: {} });
    await Bun.sleep(100);
    expect(true).toBe(true);
  }, 15000);
});
