import { describe, expect, test } from "bun:test";
import { InMemorySink, type Mutation } from "../src/render/mutations";
import { createAppSession } from "../src/render/session";
import { createCtx, type PrivilegedCtx } from "../src/worker/ctx";
import type { WorkerToHost } from "../src/worker/messages";

/** Collect posted worker→host messages. */
function recorder() {
  const posts: WorkerToHost[] = [];
  return { posts, post: (msg: WorkerToHost) => posts.push(msg) };
}

describe("ctx bridges", () => {
  test("notify and attention post the shell messages", () => {
    const { posts, post } = recorder();
    const { ctx } = createCtx({ post, update: () => {} });

    const first = ctx.notify("AAPL crossed $214", { attention: true });
    const second = ctx.notify("quiet one");
    ctx.attention();

    // Every notification gets its own id, returned to the app — that id is how
    // an app tells its own notifications apart when an action comes back.
    expect(first).not.toBe(second);
    expect(posts).toEqual([
      { type: "notify", id: first, text: "AAPL crossed $214", attention: true },
      { type: "notify", id: second, text: "quiet one", attention: false },
      { type: "attention" },
    ]);
  });

  test("notify carries a title and action buttons when asked (spec §6 extension)", () => {
    const { posts, post } = recorder();
    const { ctx } = createCtx({ post, update: () => {} });

    const id = ctx.notify("Sony WH-1000XM5 is $278", {
      title: "Deal Watch",
      actions: [
        { id: "open", label: "Open listing" },
        { id: "snooze", label: "Snooze" },
      ],
    });

    expect(posts[0]).toEqual({
      type: "notify",
      id,
      text: "Sony WH-1000XM5 is $278",
      attention: false,
      title: "Deal Watch",
      actions: [
        { id: "open", label: "Open listing" },
        { id: "snooze", label: "Snooze" },
      ],
    });
  });

  test("malformed actions are dropped at the boundary, not sent to the shell", () => {
    const { posts, post } = recorder();
    const { ctx } = createCtx({ post, update: () => {} });

    ctx.notify("careful", {
      // A bad entry would fail the shell's envelope decode and take the whole
      // notification with it — so it is dropped here, like a malformed wing.
      actions: [
        { id: "ok", label: "OK" },
        { id: 7, label: "seven" },
        { id: "no-label" },
        { id: "a", label: "A" },
        { id: "b", label: "B" },
        { id: "c", label: "C" },
        { id: "d", label: "D" },
      ] as never,
      title: 12 as never,
    });

    const sent = posts[0] as Extract<WorkerToHost, { type: "notify" }>;
    expect(sent.title).toBeUndefined();
    expect(sent.actions).toEqual([
      { id: "ok", label: "OK" },
      { id: "a", label: "A" },
      { id: "b", label: "B" },
      { id: "c", label: "C" },
    ]);
  });

  test("capture requests the shell-side screenshot and resolves with its path", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const promise = ctx.capture();
    const req = posts[0] as Extract<WorkerToHost, { type: "capture" }>;
    expect(req.type).toBe("capture");
    expect(req.request).toEqual({ interactive: true });

    settle({ type: "reply", id: req.id, ok: true, value: "/tmp/ledge-capture-1.png" });
    expect(await promise).toBe("/tmp/ledge-capture-1.png");
  });

  test("a cancelled capture rejects, like ctx.apple", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const promise = ctx.capture({ interactive: false });
    const req = posts[0] as Extract<WorkerToHost, { type: "capture" }>;
    expect(req.request).toEqual({ interactive: false });
    settle({ type: "reply", id: req.id, ok: false, error: "capture cancelled" });
    await expect(promise).rejects.toThrow("capture cancelled");
  });

  test("agent posts one turn and resolves with the host's AgentResult (never rejects)", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const promise = ctx.agent("classify this", { files: ["/tmp/pass.pdf"], schema: { kind: "string" } });
    const req = posts[0] as Extract<WorkerToHost, { type: "agent" }>;
    expect(req.request).toEqual({
      prompt: "classify this",
      files: ["/tmp/pass.pdf"],
      schema: { kind: "string" },
    });

    settle({ type: "reply", id: req.id, ok: true, value: { ok: false, error: "no agent CLI found" } });
    // A failed turn is a value, not a throw: a monitor that throws is an app
    // crash (spec §6 rule 2), which "the CLI isn't installed" must never cause.
    expect(await promise).toEqual({ ok: false, error: "no agent CLI found" });
  });

  test("apple.script posts a request and the reply resolves its promise", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const promise = ctx.apple.script("return 7");
    expect(posts).toHaveLength(1);
    const req = posts[0]!;
    expect(req).toMatchObject({ type: "apple", request: { kind: "script", source: "return 7" } });
    const id = (req as Extract<WorkerToHost, { type: "apple" }>).id;

    settle({ type: "reply", id, ok: true, value: 7 });
    expect(await promise).toBe(7);
  });

  test("apple.shortcut carries name + input; a failed reply rejects", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const promise = ctx.apple.shortcut("Log", { note: "hi" });
    const req = posts[0] as Extract<WorkerToHost, { type: "apple" }>;
    expect(req.request).toEqual({ kind: "shortcut", name: "Log", input: { note: "hi" } });

    settle({ type: "reply", id: req.id, ok: false, error: "not found" });
    await expect(promise).rejects.toThrow("not found");
  });

  test("a stale/unknown reply id is ignored", () => {
    const { post } = recorder();
    const { settle } = createCtx({ post, update: () => {} });
    expect(() => settle({ type: "reply", id: 999, ok: true, value: 1 })).not.toThrow();
  });

  test("every app can observe; only Settings can manage apps", () => {
    // The split matters: watching an OS broadcast is every monitor's problem
    // (Music's three-second track-change latency is the motivating case), while
    // enable/disable/reorder change *other* apps and stay Settings-only. An
    // ordinary app should not even be able to see the calls it may not make.
    const plain = createCtx({ post: () => {}, update: () => {} });
    expect(typeof plain.ctx.platform.observe).toBe("function");
    expect(typeof plain.ctx.platform.unobserve).toBe("function");
    expect((plain.ctx.platform as PrivilegedCtx["platform"]).enable).toBeUndefined();

    const privileged = createCtx({ post: () => {}, update: () => {} }, { privileged: true });
    expect(typeof (privileged.ctx as PrivilegedCtx).platform.enable).toBe("function");
    expect(typeof (privileged.ctx as PrivilegedCtx).platform.observe).toBe("function");
  });

  test("observe/unobserve round-trip through the bridge (spec §6 extension)", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const observing = ctx.platform.observe(
      "distributedNotification",
      "com.apple.Music.playerInfo",
    );
    void ctx.platform.unobserve("distributedNotification", "com.spotify.client.PlaybackStateChanged");

    expect(posts.map((m) => (m as Extract<WorkerToHost, { type: "platform" }>).request)).toEqual([
      {
        kind: "observe",
        source: "distributedNotification",
        name: "com.apple.Music.playerInfo",
      },
      {
        kind: "unobserve",
        source: "distributedNotification",
        name: "com.spotify.client.PlaybackStateChanged",
      },
    ]);

    // Registration is an acknowledgement, not a value: the app awaited "am I
    // watching this now", and the answer has no payload.
    const request = posts[0] as Extract<WorkerToHost, { type: "platform" }>;
    settle({ type: "reply", id: request.id, ok: true, value: undefined });
    expect(await observing).toBeUndefined();
  });

  test("a refused observe rejects rather than resolving quietly", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });
    const observing = ctx.platform.observe("distributedNotification", "n");
    const request = posts[0] as Extract<WorkerToHost, { type: "platform" }>;
    settle({ type: "reply", id: request.id, ok: false, error: "unsupported observe kind" });
    // An app that thinks it is watching something it is not would wait forever
    // for an event that can never arrive.
    await expect(observing).rejects.toThrow("unsupported observe kind");
  });

  test("every platform call posts its own wire request (Tier 1 + Tier 2)", () => {
    const { posts, post } = recorder();
    const { ctx } = createCtx({ post, update: () => {} });
    const platform = ctx.platform;

    void platform.calendar({ from: "2026-07-25T09:00:00Z", to: "2026-07-26T09:00:00Z" });
    void platform.calendar();
    void platform.workspace();
    void platform.location();
    void platform.spotlight({ query: 'kMDItemContentType == "com.adobe.pdf"' });
    void platform.spotlight({ query: "x", scopes: ["/tmp"] });
    void platform.audio();
    void platform.setVolume(0.4);
    void platform.speak("Standup in five minutes.");
    void platform.speak("Louder", { voice: "en-US", rate: 0.6 });

    expect(posts.map((m) => (m as Extract<WorkerToHost, { type: "platform" }>).request)).toEqual([
      { kind: "calendar", from: "2026-07-25T09:00:00Z", to: "2026-07-26T09:00:00Z" },
      // Absent, not null: the shell owns the default range, and a null would
      // have to be re-read as "absent" at every layer in between.
      { kind: "calendar" },
      { kind: "workspace" },
      { kind: "location" },
      { kind: "spotlight", query: 'kMDItemContentType == "com.adobe.pdf"' },
      { kind: "spotlight", query: "x", scopes: ["/tmp"] },
      { kind: "audio" },
      { kind: "setVolume", value: 0.4 },
      { kind: "speak", text: "Standup in five minutes." },
      { kind: "speak", text: "Louder", voice: "en-US", rate: 0.6 },
    ]);
    // Each call is its own in-flight request: the host keys replies by id, so
    // two calendar reads outstanding at once must not collide.
    const ids = posts.map((m) => (m as Extract<WorkerToHost, { type: "platform" }>).id);
    expect(new Set(ids).size).toBe(posts.length);
  });

  test("call results arrive as the resolved value of the Promise", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const events = ctx.platform.calendar();
    const where = ctx.platform.location();
    const hits = ctx.platform.spotlight({ query: "x" });
    const device = ctx.platform.audio();
    const ids = posts.map((m) => (m as Extract<WorkerToHost, { type: "platform" }>).id);

    settle({
      type: "reply",
      id: ids[0]!,
      ok: true,
      value: [
        { title: "Standup", start: "a", end: "b", allDay: false, calendar: "Work" },
      ],
    });
    settle({
      type: "reply",
      id: ids[1]!,
      ok: true,
      value: { lat: 37.77, lon: -122.41, accuracyMeters: 1200, timestamp: "t" },
    });
    settle({ type: "reply", id: ids[2]!, ok: true, value: [] });
    settle({
      type: "reply",
      id: ids[3]!,
      ok: true,
      value: { deviceName: "AirPods Pro", volume: 0.42, muted: false, transportType: "bluetooth" },
    });

    expect((await events)[0]!.title).toBe("Standup");
    expect((await where).lat).toBe(37.77);
    expect(await hits).toEqual([]);
    expect((await device).deviceName).toBe("AirPods Pro");
  });

  test("setVolume resolves with the value the shell actually applied", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const applied = ctx.platform.setVolume(1.4);
    const request = posts[0] as Extract<WorkerToHost, { type: "platform" }>;
    // The ask goes out unclamped — clamping is the shell's, next to the device
    // that knows what its range is — and comes back as what was set, so the app
    // learns it was clamped rather than believing it got 1.4.
    expect(request.request).toEqual({ kind: "setVolume", value: 1.4 });
    settle({ type: "reply", id: request.id, ok: true, value: { volume: 1 } });
    expect(await applied).toBe(1);
  });

  test("speak resolves with nothing — it is the utterance finishing, not a value", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });
    const spoken = ctx.platform.speak("done");
    const request = posts[0] as Extract<WorkerToHost, { type: "platform" }>;
    settle({ type: "reply", id: request.id, ok: true, value: undefined });
    expect(await spoken).toBeUndefined();
  });

  test("a refused call rejects, one message per failure mode", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} });

    const denied = ctx.platform.calendar();
    const timedOut = ctx.platform.location();
    const malformed = ctx.platform.spotlight({ query: "kMDItem ==== nonsense" });
    const tooLong = ctx.platform.speak("x".repeat(600));
    const ids = posts.map((m) => (m as Extract<WorkerToHost, { type: "platform" }>).id);

    // Every one of these is an ordinary outcome an app should branch on: a
    // denial is not a crash, and a Promise that never settles is worse than any
    // of them.
    settle({ type: "reply", id: ids[0]!, ok: false, error: "calendar access was refused" });
    settle({ type: "reply", id: ids[1]!, ok: false, error: "location timed out after 8 s" });
    settle({
      type: "reply",
      id: ids[2]!,
      ok: false,
      error: "spotlight query is not a valid metadata predicate",
    });
    settle({ type: "reply", id: ids[3]!, ok: false, error: "speak text is 600 characters; the limit is 500" });

    await expect(denied).rejects.toThrow("refused");
    await expect(timedOut).rejects.toThrow("timed out");
    await expect(malformed).rejects.toThrow("predicate");
    await expect(tooLong).rejects.toThrow("the limit is 500");
  });

  test("the new observe kinds go down the same bridge as the original", () => {
    const { posts, post } = recorder();
    const { ctx } = createCtx({ post, update: () => {} });

    void ctx.platform.observe("workspace", "screenLocked");
    void ctx.platform.observe("pasteboard", "changed");
    void ctx.platform.observe("power", "changed");
    void ctx.platform.observe("reachability", "changed");
    void ctx.platform.observe("audio", "changed");
    void ctx.platform.unobserve("power", "changed");

    expect(posts.map((m) => (m as Extract<WorkerToHost, { type: "platform" }>).request)).toEqual([
      { kind: "observe", source: "workspace", name: "screenLocked" },
      { kind: "observe", source: "pasteboard", name: "changed" },
      { kind: "observe", source: "power", name: "changed" },
      { kind: "observe", source: "reachability", name: "changed" },
      { kind: "observe", source: "audio", name: "changed" },
      { kind: "unobserve", source: "power", name: "changed" },
    ]);
  });

  test("the Settings-only calls still round-trip", async () => {
    const { posts, post } = recorder();
    const { ctx, settle } = createCtx({ post, update: () => {} }, { privileged: true });
    const platform = (ctx as PrivilegedCtx).platform;

    void platform.enable("stocks");
    void platform.reorder(["music", "stocks"]);
    const statsPromise = platform.stats();

    expect(posts.map((m) => (m as Extract<WorkerToHost, { type: "platform" }>).request)).toEqual([
      { kind: "enable", app: "stocks" },
      { kind: "reorder", order: ["music", "stocks"] },
      { kind: "stats" },
    ]);

    const statsReq = posts[2] as Extract<WorkerToHost, { type: "platform" }>;
    settle({ type: "reply", id: statsReq.id, ok: true, value: { apps: [] } });
    expect(await statsPromise).toEqual({ apps: [] });
  });
});

describe("ctx.update", () => {
  test("a fake monitor's updates shallow-merge and re-render", () => {
    const sink = new InMemorySink();
    const session = createAppSession(
      ({ price = "—", label = "AAPL" }) => (
        <stack axis="v">
          <text content={String(label)} />
          <text content={String(price)} />
        </stack>
      ),
      sink,
    );
    const { ctx } = createCtx({ post: () => {}, update: (patch) => session.update(patch) });

    // Simulate two monitor passes.
    ctx.update({ price: "$214.62" });
    ctx.update({ label: "AAPL Inc" });

    expect(session.props).toEqual({ price: "$214.62", label: "AAPL Inc" });

    // The last commit is a single partial update to the label text node.
    const last = sink.commits.at(-1)!;
    expect(last.map((m) => m.op)).toEqual(["update"]);
    expect((last[0] as Extract<Mutation, { op: "update" }>).props).toEqual({ content: "AAPL Inc" });
  });
});
