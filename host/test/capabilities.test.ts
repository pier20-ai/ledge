import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { AgentRunner } from "../src/agent";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import { Router } from "../src/router";

// The agentic capability layer, host side, driven by REAL Bun workers: a real
// app.jsx calls ctx.apple / ctx.capture / ctx.agent, the router turns each into
// the wire shape the shell answers, and the answer lands back in the app's
// props. The shell itself is a RecordingSession here — its half is covered by
// the Swift engine tests and by the AppleScript round trip in
// LedgeShellCoreTests.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");
const FAKE_AGENT = join(HOST_DIR, "test", "fixtures", "fake-agent.ts");

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
}

/** An app whose monitor awaits one bridge call and shows whatever came back. */
const APPLE_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  try {
    const value = await ctx.apple.script("return 1 + 2");
    ctx.update({ label: "apple " + value });
  } catch (error) {
    ctx.update({ label: "apple failed: " + error.message });
  }
  await new Promise(() => {});
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

const CAPTURE_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  try {
    ctx.update({ label: "shot " + (await ctx.capture()) });
  } catch (error) {
    ctx.update({ label: "capture failed: " + error.message });
  }
  await new Promise(() => {});
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

const AGENT_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  const result = await ctx.agent("what is this?", { files: ["/tmp/a.pdf"] });
  ctx.update({ label: result.ok ? result.text : "failed: " + result.error });
  await new Promise(() => {});
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

/** Fires two turns at once — the second must be told the app is busy. */
const AGENT_RACE_APP = `/** @jsxImportSource react */
export async function monitor(ctx) {
  const [first, second] = await Promise.all([ctx.agent("one"), ctx.agent("two")]);
  ctx.update({ label: [first, second].map((r) => (r.ok ? "ok" : r.error)).join(" | ") });
  await new Promise(() => {});
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

/** Receives app-level (id 0) events — the drop shelf's addressee. */
const DROP_APP = `/** @jsxImportSource react */
export function onEvent(name, data, ctx) {
  if (name === "drop") ctx.update({ label: "dropped " + data.paths.join(",") });
}
export default function App({ label = "waiting" }) {
  return <text content={label} />;
}
`;

let roots: string[] = [];
let openRouter: Router | null = null;

async function makeAppsRoot(apps: Record<string, string>): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ledge-caps-"));
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

/** Every text content the app has committed so far, newest last. */
function labels(session: RecordingSession, app: string): string[] {
  return session
    .envelopesFor(app, "commit")
    .flatMap((e) => e.payload.mutations as Array<Record<string, unknown>>)
    .map((m) => (m.props as Record<string, unknown> | undefined)?.content)
    .filter((content): content is string => typeof content === "string");
}

const seenLabel = (session: RecordingSession, app: string, needle: string) => () =>
  labels(session, app).some((label) => label.includes(needle));

afterEach(async () => {
  openRouter?.shutdown();
  openRouter = null;
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
  await Bun.sleep(10);
});

describe("ctx.apple over the wire (spec §6)", () => {
  test("the request becomes an `apple` envelope and the shell's result resolves the app's Promise", async () => {
    const root = await makeAppsRoot({ meeting: APPLE_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("meeting", "apple").length >= 1);
    const request = session.envelopesFor("meeting", "apple")[0]!.payload;
    expect(request).toMatchObject({ kind: "script", source: "return 1 + 2" });
    expect(typeof request.id).toBe("number");

    router.onEnvelope(
      session,
      envelope("meeting", "appleResult", { id: request.id, ok: true, value: 3 }),
    );
    await waitFor(seenLabel(session, "meeting", "apple 3"));
  }, 30000);

  test("an error result rejects the app's Promise with the shell's own message", async () => {
    const root = await makeAppsRoot({ meeting: APPLE_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("meeting", "apple").length >= 1);
    const id = session.envelopesFor("meeting", "apple")[0]!.payload.id;
    router.onEnvelope(
      session,
      envelope("meeting", "appleResult", { id, ok: false, error: "Automation not permitted" }),
    );
    await waitFor(seenLabel(session, "meeting", "Automation not permitted"));
  }, 30000);

  test("a silent shell times out host-side, and the late result is then dropped", async () => {
    const root = await makeAppsRoot({ meeting: APPLE_APP });
    const session = new RecordingSession();
    const logs: string[] = [];
    const router = new Router({
      appsRoot: root,
      watch: false,
      timeouts: { apple: 150 },
      log: (line) => logs.push(line),
    });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("meeting", "apple").length >= 1);
    const id = session.envelopesFor("meeting", "apple")[0]!.payload.id;
    await waitFor(seenLabel(session, "meeting", "timed out"));

    // The shell answering afterwards must not settle anything: the app has
    // already been told how this ended.
    router.onEnvelope(session, envelope("meeting", "appleResult", { id, ok: true, value: 3 }));
    await Bun.sleep(150);
    expect(labels(session, "meeting").some((l) => l.includes("apple 3"))).toBe(false);
    expect(logs.some((l) => l.includes("dropping unmatched result"))).toBe(true);
  }, 30000);

  test("with no shell connected the app is told immediately instead of hanging", async () => {
    const root = await makeAppsRoot({ meeting: APPLE_APP });
    const session = new RecordingSession();
    const logs: string[] = [];
    const router = new Router({ appsRoot: root, watch: false, log: (line) => logs.push(line) });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("meeting", "apple").length >= 1);

    router.clearSession();
    // Reload so the monitor asks again, now with nothing to execute it. (The
    // worker's reply and the commit it triggers stay worker-side: with no
    // session there is no wire to observe them on — which is exactly the state
    // under test, so the assertion is the host's own decision.)
    router.reloadApp("meeting");
    await waitFor(() => logs.some((l) => l.includes("answered locally (no shell connected)")));
    // …and nothing was written to a wire that isn't there.
    expect(session.envelopesFor("meeting", "apple")).toHaveLength(1);
  }, 30000);
});

describe("ctx.capture over the wire (spec §6 extension)", () => {
  test("a capture request round-trips a shell-owned path", async () => {
    const root = await makeAppsRoot({ flights: CAPTURE_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("flights", "capture").length >= 1);
    const request = session.envelopesFor("flights", "capture")[0]!.payload;
    expect(request.interactive).toBe(true);

    router.onEnvelope(
      session,
      envelope("flights", "captureResult", {
        id: request.id,
        ok: true,
        path: "/tmp/ledge-capture-1.png",
      }),
    );
    await waitFor(seenLabel(session, "flights", "shot /tmp/ledge-capture-1.png"));
  }, 30000);

  test("a cancelled capture is an error the app can catch", async () => {
    const root = await makeAppsRoot({ flights: CAPTURE_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(() => session.envelopesFor("flights", "capture").length >= 1);
    const id = session.envelopesFor("flights", "capture")[0]!.payload.id;
    router.onEnvelope(
      session,
      envelope("flights", "captureResult", { id, ok: false, error: "capture cancelled" }),
    );
    await waitFor(seenLabel(session, "flights", "capture failed: capture cancelled"));
  }, 30000);
});

describe("the drop shelf's app-level event (INTAKE)", () => {
  test("an id-0 `drop` event reaches the app's onEvent export", async () => {
    const root = await makeAppsRoot({ flights: DROP_APP });
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("flights", "commit").length >= 1);

    router.onEnvelope(
      session,
      envelope("flights", "event", {
        id: 0,
        name: "drop",
        data: { paths: ["/Users/you/Downloads/pass.pdf"] },
      }),
    );
    await waitFor(seenLabel(session, "flights", "dropped /Users/you/Downloads/pass.pdf"));
  }, 30000);
});

describe("ctx.agent through the router (spec §8)", () => {
  test("a turn runs the configured CLI and its text lands in the app's props", async () => {
    const root = await makeAppsRoot({ triage: AGENT_APP });
    const session = new RecordingSession();
    const router = new Router({
      appsRoot: root,
      watch: false,
      agentRunner: new AgentRunner({ command: ["bun", FAKE_AGENT] }),
    });
    openRouter = router;
    await router.bindSession(session);

    // The prompt the fake echoes proves `files` rode along in the prompt.
    await waitFor(seenLabel(session, "triage", "what is this?"), 20000);
    await waitFor(seenLabel(session, "triage", "/tmp/a.pdf"), 20000);
    // Nothing went to the shell: ctx.agent is host-side by design.
    expect(session.envelopesFor("triage", "agent")).toHaveLength(0);
  }, 40000);

  test("a second concurrent turn is refused as busy, not queued", async () => {
    const root = await makeAppsRoot({ triage: AGENT_RACE_APP });
    const session = new RecordingSession();
    const router = new Router({
      appsRoot: root,
      watch: false,
      agentRunner: new AgentRunner({ command: ["bun", FAKE_AGENT] }),
    });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(seenLabel(session, "triage", "agent busy"), 20000);
    const label = labels(session, "triage").find((l) => l.includes("agent busy"))!;
    // One of the two succeeded; exactly one was refused.
    expect(label.includes("ok")).toBe(true);
  }, 40000);

  test("no agent installed is an ok:false result, never a crash", async () => {
    const root = await makeAppsRoot({ triage: AGENT_APP });
    const session = new RecordingSession();
    const router = new Router({
      appsRoot: root,
      watch: false,
      agentRunner: new AgentRunner({ env: {}, which: () => null }),
    });
    openRouter = router;
    await router.bindSession(session);

    await waitFor(seenLabel(session, "triage", "failed: no agent CLI found"), 20000);
    // A crash would have produced an `app` envelope with state "crashed".
    expect(
      session.envelopesFor("triage", "app").some((e) => e.payload.state === "crashed"),
    ).toBe(false);
  }, 40000);
});
