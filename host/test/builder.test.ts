import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Builder } from "../src/builder";
import type { BuilderEvent } from "../src/codex/events";
import { FakeCodex } from "../src/fakes/fake-codex";

// The builder (spec §8): `builderInput` in, `builder` events out, one thread per
// app pinned in `.builder.json`.
//
// Everything here runs against `FakeCodex`. A real Codex costs the user money,
// takes tens of seconds, and — the real reason — is not deterministic, so a
// suite built on one would be testing the model rather than the adapter. The
// adapter's behaviour against a REAL Codex is established by hand, with
// scripts/codex-harness.ts.

let roots: string[] = [];
afterEach(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
});

async function makeApp(id = "stocks"): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ledge-builder-"));
  roots.push(root);
  await mkdir(join(root, id), { recursive: true });
  return root;
}

function harness(appsRoot: string, fake: FakeCodex) {
  const events: Array<{ app: string; turn: number; event: BuilderEvent }> = [];
  const logs: string[] = [];
  const builder = new Builder({
    appsRoot,
    sink: {
      builder: (app, turn, event) => events.push({ app, turn, event }),
      log: (line) => logs.push(line),
    },
    client: { spawn: () => fake.process },
  });
  return { builder, events, logs };
}

const settle = () => Bun.sleep(30);

describe("builder", () => {
  test("a first message starts a thread, runs a turn, and streams it back", async () => {
    const root = await makeApp();
    const fake = new FakeCodex();
    const { builder, events } = harness(root, fake);

    await builder.handleInput("stocks", { text: "make the price green when it's up" });
    fake.emitTurn("thread-1", "Making the price track the delta…");
    await settle();

    // The thread is rooted in the APP's folder, not the apps root — the agent's
    // working set is the app, which is what makes the notch chat focused.
    const start = fake.requests.find((r) => r.method === "thread/start");
    expect(start?.params.cwd).toBe(join(root, "stocks"));
    // Auto-approve, scoped to that folder (spec §6 trust model).
    expect(start?.params.approvalPolicy).toBe("never");
    expect(start?.params.sandbox).toBe("workspace-write");

    expect(events.map((e) => e.event.event)).toEqual(["text", "done"]);
    expect(events[0]!.event).toEqual({ event: "text", delta: "Making the price track the delta…" });
    // Events carry the turn they belong to, so the editor can group them.
    expect(events.every((e) => e.turn === 1 && e.app === "stocks")).toBe(true);
  });

  test("the thread id is pinned so the next launch resumes the same conversation", async () => {
    const root = await makeApp();
    const fake = new FakeCodex();
    const { builder } = harness(root, fake);

    await builder.handleInput("stocks", { text: "hello" });
    fake.emitTurn("thread-1", "hi");
    await settle();

    const pointer = JSON.parse(await readFile(join(root, "stocks", ".builder.json"), "utf8"));
    expect(pointer).toEqual({ agent: "codex", threadId: "thread-1" });

    // A fresh host, same folder: resume rather than start.
    const fake2 = new FakeCodex();
    const second = harness(root, fake2);
    await second.builder.handleInput("stocks", { text: "again" });
    fake2.emitTurn("thread-1", "ok");
    await settle();

    expect(fake2.requests.some((r) => r.method === "thread/start")).toBe(false);
    expect(fake2.requests.find((r) => r.method === "thread/resume")?.params.threadId).toBe("thread-1");
  });

  test("a pointer that outlived its thread starts fresh instead of refusing", async () => {
    const root = await makeApp();
    await writeFile(
      join(root, "stocks", ".builder.json"),
      JSON.stringify({ agent: "codex", threadId: "gone" }),
    );
    // Codex storage cleared, or the pointer came from another machine.
    const fake = new FakeCodex({ failResume: "no such thread" });
    const { builder, events } = harness(root, fake);

    await builder.handleInput("stocks", { text: "hello" });
    fake.emitTurn("thread-1", "hi");
    await settle();

    expect(fake.requests.some((r) => r.method === "thread/start")).toBe(true);
    expect(events.some((e) => e.event.event === "error")).toBe(false);
    // …and the pointer is rewritten to the thread that actually exists.
    const pointer = JSON.parse(await readFile(join(root, "stocks", ".builder.json"), "utf8"));
    expect(pointer.threadId).toBe("thread-1");
  });

  test("another agent's pointer is not resumed", async () => {
    const root = await makeApp();
    await writeFile(
      join(root, "stocks", ".builder.json"),
      JSON.stringify({ agent: "claude", sessionId: "abc" }),
    );
    const fake = new FakeCodex();
    const { builder } = harness(root, fake);
    await builder.handleInput("stocks", { text: "hello" });
    await settle();
    expect(fake.requests.some((r) => r.method === "thread/resume")).toBe(false);
  });

  test("two apps get two threads, and events route by thread", async () => {
    const root = await makeApp("stocks");
    await mkdir(join(root, "music"), { recursive: true });
    const fake = new FakeCodex();
    const { builder, events } = harness(root, fake);

    await builder.handleInput("stocks", { text: "one" });
    await builder.handleInput("music", { text: "two" });
    await settle();

    // A notification names a THREAD; the builder has to map it back to the app,
    // or one app's chat would show another's output.
    fake.emit("item/agentMessage/delta", { threadId: "thread-2", delta: "for music" });
    await settle();

    const forMusic = events.filter((e) => e.app === "music" && e.event.event === "text");
    expect(forMusic).toHaveLength(1);
    expect(events.some((e) => e.app === "stocks" && e.event.event === "text")).toBe(false);
  });

  test("a notification for an unknown thread is dropped, not misrouted", async () => {
    const root = await makeApp();
    const fake = new FakeCodex();
    const { builder, events } = harness(root, fake);
    await builder.handleInput("stocks", { text: "hello" });
    await settle();

    fake.emit("item/agentMessage/delta", { threadId: "someone-elses-thread", delta: "nope" });
    await settle();
    expect(events.some((e) => (e.event as { delta?: string }).delta === "nope")).toBe(false);
  });

  test("a second message while a turn runs is refused, not queued", async () => {
    const root = await makeApp();
    const fake = new FakeCodex();
    const { builder, events } = harness(root, fake);

    await builder.handleInput("stocks", { text: "one" });
    await builder.handleInput("stocks", { text: "two" });
    await settle();

    // Queueing would spend the user's tokens on something they typed while
    // waiting and may not have meant.
    expect(events.some((e) => e.event.event === "status")).toBe(true);
    expect(fake.requests.filter((r) => r.method === "turn/start")).toHaveLength(1);

    // Once the turn ends, the next message goes through.
    fake.emitTurn("thread-1", "done");
    await settle();
    await builder.handleInput("stocks", { text: "three" });
    await settle();
    expect(fake.requests.filter((r) => r.method === "turn/start")).toHaveLength(2);
  });

  test("cancel interrupts the running turn, carrying its turn id", async () => {
    const root = await makeApp();
    const fake = new FakeCodex();
    const { builder, events } = harness(root, fake);

    await builder.handleInput("stocks", { text: "count to a thousand" });
    await settle();
    await builder.handleInput("stocks", { cancel: true });
    await settle();

    // turn/interrupt is a REQUEST needing BOTH ids — sent as a notification, or
    // without the turn id, it is silently ignored and Stop does nothing.
    const interrupt = fake.requests.find((r) => r.method === "turn/interrupt");
    expect(interrupt?.params).toEqual({ threadId: "thread-1", turnId: fake.lastTurnId });

    // An interrupted turn still completes — and the status has to say so.
    fake.emit("turn/completed", { threadId: "thread-1", turn: { status: "interrupted" } });
    await settle();
    expect(events.at(-1)!.event).toEqual({ event: "done", status: "interrupted" });
  });

  test("cancel with nothing running is a no-op", async () => {
    const root = await makeApp();
    const fake = new FakeCodex();
    const { builder } = harness(root, fake);
    await builder.handleInput("stocks", { cancel: true });
    await settle();
    expect(fake.requests).toHaveLength(0);
  });

  test("codex missing or logged out is reported verbatim, and ends the turn", async () => {
    const root = await makeApp();
    const fake = new FakeCodex({ failInitialize: "not logged in" });
    const { builder, events } = harness(root, fake);

    await builder.handleInput("stocks", { text: "hello" });
    await settle();

    const error = events.find((e) => e.event.event === "error")!.event as { message: string };
    // Verbatim (spec §3.6): the real reason is the only actionable thing here.
    expect(error.message).toContain("not logged in");
    // And the editor must not be left spinning.
    expect(events.at(-1)!.event).toEqual({ event: "done", status: "failed" });
  });

  test("empty input is ignored rather than spending a turn", async () => {
    const root = await makeApp();
    const fake = new FakeCodex();
    const { builder } = harness(root, fake);
    await builder.handleInput("stocks", { text: "   " });
    await builder.handleInput("stocks", {});
    await settle();
    expect(fake.requests).toHaveLength(0);
  });

  // The [+] surface (spec §4.3: "`app` may name a not-yet-existing id"; §8: the
  // host scaffolds first, then starts the session).
  describe("creating an app from the [+] surface", () => {
    test("an empty app scaffolds one, announces it, and runs the turn there", async () => {
      const root = await makeApp();
      const fake = new FakeCodex();
      const { builder, events } = harness(root, fake);

      await builder.handleInput("", { text: "a pomodoro timer that dings" });
      await settle();

      // The folder exists BEFORE the agent is asked for anything: it opens onto
      // something that already renders, next to AGENTS.md.
      const source = await readFile(join(root, "pomodoro-timer", "app.jsx"), "utf8");
      expect(source).toContain('"Pomodoro Timer"');

      // `created` is the only way the shell learns the id it must switch to, so
      // it has to come first — the bridge drops events for apps it is not
      // focused on, and the [+] surface is focused on "".
      expect(events[0]!.app).toBe("pomodoro-timer");
      expect(events[0]!.event).toEqual({ event: "created" });

      const start = fake.requests.find((r) => r.method === "thread/start");
      expect(start?.params.cwd).toBe(join(root, "pomodoro-timer"));

      fake.emitTurn("thread-1", "Building it now…");
      await settle();
      // Everything after `created` belongs to the new app, on turn 1.
      const turn = events.slice(1);
      expect(turn.every((e) => e.app === "pomodoro-timer" && e.turn === 1)).toBe(true);
      expect(turn.map((e) => e.event.event)).toEqual(["text", "done"]);
    });

    test("the created app is a real app id, and a second one does not collide", async () => {
      const root = await makeApp();
      const fake = new FakeCodex();
      const { builder, events } = harness(root, fake);

      await builder.handleInput("", { text: "a pomodoro timer" });
      await settle();
      fake.emitTurn("thread-1", "done");
      await settle();
      await builder.handleInput("", { text: "a pomodoro timer" });
      await settle();

      const created = events.filter((e) => e.event.event === "created").map((e) => e.app);
      expect(created).toEqual(["pomodoro-timer", "pomodoro-timer-2"]);
    });

    test("a failed scaffold is reported against the surface that asked, not a phantom app", async () => {
      const root = await makeApp();
      const fake = new FakeCodex();
      // An apps root that cannot hold a directory (here: a path THROUGH a file;
      // in the wild, a volume that went away or a permissions change). The error
      // has to arrive tagged "" — the editor is still on the [+] surface, and an
      // error for an app that was never created would be dropped by the bridge.
      await writeFile(join(root, "blocked"), "not a directory\n");
      const { builder, events } = harness(join(root, "blocked", "apps"), fake);
      await builder.handleInput("", { text: "a pomodoro timer" });
      await settle();

      expect(events.map((e) => e.app)).toEqual(["", ""]);
      expect((events[0]!.event as { message: string }).message).toContain("could not create the app");
      expect(events[1]!.event).toEqual({ event: "done", status: "failed" });
      // And nothing was asked of the agent.
      expect(fake.requests).toHaveLength(0);
    });

    test("cancel from the [+] surface, before an app exists, does nothing", async () => {
      const root = await makeApp();
      const fake = new FakeCodex();
      const { builder, events } = harness(root, fake);
      await builder.handleInput("", { cancel: true });
      await settle();
      expect(events).toHaveLength(0);
      expect(fake.requests).toHaveLength(0);
    });
  });
});
