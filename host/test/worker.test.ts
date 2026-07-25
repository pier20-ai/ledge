import { afterEach, describe, expect, test } from "bun:test";
import { Worker } from "node:worker_threads";
import type { Mutation } from "../src/render/mutations";
import type { HostToWorker, WorkerToHost } from "../src/worker/messages";

// Real Bun Worker round-trips: boot the entry as a genuine worker over
// node:worker_threads (matching the design validated for Bun 1.3.9), exchange
// postMessage, and assert the worker↔host contract end to end.

const entryUrl = new URL("../src/worker/entry.ts", import.meta.url);
const fixture = (name: string) => new URL(`./fixtures/${name}`, import.meta.url).href;

/** A tiny async queue over the worker's messages: `take` yields them in arrival
 * order; `until` drains until one matches (discarding earlier ones). */
function bootWorker(modulePath: string, opts: { privileged?: boolean } = {}) {
  const worker = new Worker(entryUrl, {
    workerData: { modulePath, privileged: opts.privileged },
  });
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
    take,
    async until(match: (msg: WorkerToHost) => boolean): Promise<WorkerToHost> {
      for (;;) {
        const msg = await take();
        if (match(msg)) return msg;
      }
    },
    close: () => worker.terminate(),
  };
}

type Session = ReturnType<typeof bootWorker>;
type Commit = Extract<WorkerToHost, { type: "commit" }>;
type Update = Extract<Mutation, { op: "update" }>;
type Create = Extract<Mutation, { op: "create" }>;

const isCommit = (m: WorkerToHost): m is Commit => m.type === "commit";

let open: Session | null = null;
afterEach(async () => {
  if (open) {
    await open.close();
    open = null;
  }
});

describe("worker round trip", () => {
  test("boot mounts a tree: creates before inserts, setRoot last", async () => {
    open = bootWorker(fixture("counter.jsx"));
    const commit = (await open.until(isCommit)) as Commit;
    const batch = commit.mutations;

    const created = new Set<number>();
    for (const mutation of batch) {
      if (mutation.op === "create") created.add(mutation.id);
      if (mutation.op === "insert") {
        expect(created.has(mutation.id)).toBe(true);
        expect(created.has(mutation.parent)).toBe(true);
      }
    }
    expect(batch.at(-1)!.op).toBe("setRoot");

    const kinds = batch
      .filter((m): m is Create => m.op === "create")
      .map((m) => m.kind)
      .sort();
    expect(kinds).toEqual(["button", "stack", "text"]);
  }, 15000);

  test("a host event dispatches to the handler and yields a new commit", async () => {
    open = bootWorker(fixture("counter.jsx"));
    const mount = (await open.until(isCommit)) as Commit;

    const button = mount.mutations.find(
      (m): m is Create => m.op === "create" && m.kind === "button",
    )!;
    const text = mount.mutations.find(
      (m): m is Create => m.op === "create" && m.kind === "text",
    )!;
    expect(button.props.onClick).toBe(true); // handler serialized as true (§5)
    expect(text.props.content).toBe("count 0");

    open.send({ type: "event", id: button.id, name: "click", data: {} });

    const next = (await open.until(isCommit)) as Commit;
    const update = next.mutations.find((m): m is Update => m.op === "update")!;
    expect(update.id).toBe(text.id);
    expect(update.props).toEqual({ content: "count 1" });
  }, 15000);

  test("console output is captured and forwarded to the host", async () => {
    open = bootWorker(fixture("logger.jsx"));
    const log = await open.until((m) => m.type === "console");
    expect(log).toEqual({ type: "console", level: "log", text: "boot log 7" });
  }, 15000);

  test("an apple bridge request round-trips through a host reply", async () => {
    open = bootWorker(fixture("apple.jsx"));

    // Monitor calls ctx.apple.script → an `apple` request with an id.
    const req = (await open.until((m) => m.type === "apple")) as Extract<
      WorkerToHost,
      { type: "apple" }
    >;
    expect(req.request).toEqual({ kind: "script", source: "return 7" });

    open.send({ type: "reply", id: req.id, ok: true, value: 7 });

    // Resolution flows into ctx.update → a commit updating the result text.
    const commit = (await open.until(
      (m) => isCommit(m) && m.mutations.some((x) => x.op === "update" && x.props.content === "result 7"),
    )) as Commit;
    expect(commit.mutations.some((m) => m.op === "update")).toBe(true);
  }, 15000);

  test("a monitor throw becomes a crash message and stops the loop", async () => {
    open = bootWorker(fixture("crasher.jsx"));
    const crash = (await open.until((m) => m.type === "crash")) as Extract<
      WorkerToHost,
      { type: "crash" }
    >;
    expect(crash.phase).toBe("monitor");
    expect(crash.message).toBe("kaboom");
    expect(crash.stack).toContain("kaboom");
  }, 15000);
});
