import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import type { Mutation } from "../src/render/mutations";
import { Router } from "../src/router";

// **Radio has to exercise.** It is the demo app whose entire job is to be
// pressed: no summary, no mini, two ghost buttons and a wing it takes and gives
// back. G2 reported it as "non-functional on device — clicking around it does
// nothing", and nothing in the suite would have noticed, because every other
// test that touches a button uses a three-line app written for the test.
//
// So this one drives the **real** `protocol/demo-apps/radio/app.jsx` through the
// real Router and a real worker, and presses the buttons the way the shell does
// — an `event` envelope naming a node id from the app's own mount batch. What it
// asserts is the whole exercise:
//
//   press play  → the glyph becomes pause, the meter starts drawing, the notch
//                 is claimed;
//   press next  → the title changes and the wing's ticker changes **with it, in
//                 place** — no release, no re-claim, no blink;
//   press play  → the glyph goes back and the wing is handed in.
//
// It is deliberately not a unit test of `toggle()`: the defect it exists to
// catch is a click that never arrives, and the only way to be sure one arrives
// is to send it the way the shell sends it.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");
const DEMO_APPS = join(HOST_DIR, "..", "protocol", "demo-apps");

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
  /** Every wing this app asked for, in order. `null` is a release. */
  wings(app: string): Array<Record<string, unknown> | null> {
    return this.envelopesFor(app, "chrome")
      .filter((e) => e.payload.request === "wing")
      .map((e) => (e.payload.wing ?? null) as Record<string, unknown> | null);
  }
  /** The merged prop state of one node, as the shell's shadow tree would hold
   * it: the `create` props with every later `update` folded over them. */
  propsOf(app: string, id: number): Record<string, unknown> {
    const props: Record<string, unknown> = {};
    for (const commit of this.envelopesFor(app, "commit")) {
      for (const mutation of commit.payload.mutations as Mutation[]) {
        if (mutation.op === "create" && mutation.id === id) Object.assign(props, mutation.props);
        if (mutation.op === "update" && mutation.id === id) Object.assign(props, mutation.props);
      }
    }
    return props;
  }
}

let roots: string[] = [];
let openRouter: Router | null = null;

/**
 * A temp apps root holding one real demo app, by symlink per file.
 *
 * Per file rather than per folder because `scanApps` looks for directories, and
 * a symlinked folder is not one — and by symlink rather than by copy so the test
 * is reading the app that ships. The app's own writes (its `console.log`, any
 * cache it keeps) land in the temp directory, never in the repo.
 */
async function appsRootWith(appId: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), `ledge-${appId}-`));
  roots.push(root);
  await symlink(NODE_MODULES, join(root, "node_modules"));
  const source = join(DEMO_APPS, appId);
  await mkdir(join(root, appId), { recursive: true });
  for (const entry of await readdir(source)) {
    if (entry === "console.log") continue; // the worker makes its own
    await symlink(join(source, entry), join(root, appId, entry));
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

describe("radio, pressed the way the shell presses it", () => {
  test("tune / retune / stop drives props, the meter and the wing", async () => {
    // The seams: a fixture dial (no public internet in a suite) and no audio
    // process (a test run must be silent). Everything else is the real app.
    process.env.LEDGE_RADIO_STATIONS = JSON.stringify([
      { uuid: "u1", name: "Dial One", url: "http://example.test/1", country: "DE" },
      { uuid: "u2", name: "Dial Two", url: "http://example.test/2", country: "US" },
      { uuid: "u3", name: "Dial Three", url: "http://example.test/3", country: "FR" },
    ]);
    process.env.LEDGE_RADIO_MUTE = "1";

    const root = await appsRootWith("radio");
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, settingsPath: join(root, "settings.json"), watch: false });
    openRouter = router;
    await router.bindSession(session);

    // The stations arrive from the monitor, so the rows land in a later commit
    // than the mount: wait for the four buttons — three station rows (child
    // form, no icon) and the one ghost transport.
    const creates = () =>
      session
        .envelopesFor("radio", "commit")
        .flatMap((e) => e.payload.mutations as Mutation[])
        .filter((m): m is Extract<Mutation, { op: "create" }> => m.op === "create");
    await waitFor(() => creates().filter((m) => m.kind === "button").length >= 4);

    const buttons = creates().filter((m) => m.kind === "button");
    const rows = buttons.filter((m) => !m.props.icon);
    const transport = buttons.find((m) => m.props.icon)!;
    expect(rows).toHaveLength(3);
    expect(transport.props.variant).toBe("ghost");
    expect(transport.props.onClick).toBe(true);
    for (const row of rows) expect(row.props.onClick).toBe(true);

    // The shell sends explicit lifecycle alongside a visit; the app paints on it.
    router.onEnvelope(session, envelope("radio", "lifecycle", { phase: "expanded", reduceMotion: false }));
    await waitFor(() => session.envelopesFor("radio", "draw").length >= 1);

    // At rest: stopped, and the notch is bare — this app is quiet by default.
    expect(session.propsOf("radio", transport.id).icon).toBe("sf:play");
    expect(session.wings("radio")).toHaveLength(0);
    const restingDraws = session.envelopesFor("radio", "draw").length;

    // ---------------------------------------------------------------- play
    router.onEnvelope(session, envelope("radio", "event", { id: transport.id, name: "click", data: {} }));

    await waitFor(() => session.propsOf("radio", transport.id).icon === "sf:pause");
    await waitFor(() => session.wings("radio").length >= 1);
    const claim = session.wings("radio")[0]!;
    expect(claim).not.toBeNull();
    expect(claim.text).toBe("Dial One");
    // The wing mirrors the app's own panel canvas — one `ctx.draw`, two places.
    const canvas = creates().find((m) => m.kind === "canvas")!;
    expect((claim.canvas as { id: number }).id).toBe(canvas.id);

    // The meter is breathing: a stopped radio draws one still frame, a playing
    // one draws at ~8 fps.
    await waitFor(() => session.envelopesFor("radio", "draw").length > restingDraws + 3);

    // ---------------------------------------------------------------- retune
    // Click the second station's row: the dial turns, the wing's ticker turns
    // with it **in place** — no release, no re-claim, no blink.
    router.onEnvelope(session, envelope("radio", "event", { id: rows[1]!.id, name: "click", data: {} }));
    await waitFor(() => session.wings("radio").length >= 2);
    const retuned = session.wings("radio").at(-1)!;
    expect(retuned).not.toBeNull();
    expect(retuned.text).toBe("Dial Two");
    expect(session.wings("radio").some((wing) => wing === null)).toBe(false);
    // …and the tuned row moved with it: the second row's name is primary now.
    const names = creates().filter((m) => m.kind === "text" && m.props.size === "m");
    expect(names).toHaveLength(3);
    expect(session.propsOf("radio", names[1]!.id).color).toBe("primary");
    expect(session.propsOf("radio", names[0]!.id).color).toBe("tertiary");

    // ---------------------------------------------------------------- stop
    router.onEnvelope(session, envelope("radio", "event", { id: transport.id, name: "click", data: {} }));
    await waitFor(() => session.propsOf("radio", transport.id).icon === "sf:play");
    await waitFor(() => session.wings("radio").at(-1) === null);
  }, 40000);
});
