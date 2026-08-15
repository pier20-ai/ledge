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
  test("play / next / play drives props, the meter and the wing", async () => {
    const root = await appsRootWith("radio");
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, settingsPath: join(root, "settings.json"), watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("radio", "commit").length >= 1);

    // The mount batch is also the list of what the user could have pressed
    // (`onClick: true` is how a handler crosses the wire, spec §5).
    const mount = session.envelopesFor("radio", "commit")[0]!.payload.mutations as Mutation[];
    const buttons = mount.filter(
      (m): m is Extract<Mutation, { op: "create" }> => m.op === "create" && m.kind === "button",
    );
    expect(buttons).toHaveLength(2);
    const [play, next] = buttons;
    expect(play!.props.onClick).toBe(true);
    expect(play!.props.variant).toBe("ghost");

    // The shell sends explicit lifecycle alongside a visit; the app paints on it.
    router.onEnvelope(session, envelope("radio", "lifecycle", { phase: "expanded", reduceMotion: false }));
    await waitFor(() => session.envelopesFor("radio", "draw").length >= 1);

    // At rest: stopped, and the notch is bare — this app is quiet by default.
    expect(session.propsOf("radio", play!.id).icon).toBe("sf:play");
    expect(session.wings("radio")).toHaveLength(0);
    const restingDraws = session.envelopesFor("radio", "draw").length;

    // ---------------------------------------------------------------- play
    router.onEnvelope(session, envelope("radio", "event", { id: play!.id, name: "click", data: {} }));

    await waitFor(() => session.propsOf("radio", play!.id).icon === "sf:pause");
    await waitFor(() => session.wings("radio").length >= 1);
    const claim = session.wings("radio")[0]!;
    expect(claim).not.toBeNull();
    // The wing mirrors the app's own panel canvas — one `ctx.draw`, two places.
    const canvas = mount.find((m) => m.op === "create" && m.kind === "canvas");
    expect((claim.canvas as { id: number }).id).toBe((canvas as { id: number }).id);
    const firstTitle = claim.text as string;
    expect(firstTitle.length).toBeGreaterThan(0);

    // The meter is breathing: a stopped radio draws one still frame, a playing
    // one draws at ~8 fps.
    await waitFor(() => session.envelopesFor("radio", "draw").length > restingDraws + 3);

    // ---------------------------------------------------------------- next
    router.onEnvelope(session, envelope("radio", "event", { id: next!.id, name: "click", data: {} }));
    await waitFor(() => session.wings("radio").length >= 2);
    const rotated = session.wings("radio")[1]!;
    expect(rotated).not.toBeNull();
    expect(rotated.text).not.toBe(firstTitle);
    // In place. A track change is not a release — the notch must not blink.
    expect(session.wings("radio").some((wing) => wing === null)).toBe(false);
    // …and the panel's title moved with it.
    const title = mount.find(
      (m) => m.op === "create" && m.kind === "text" && m.props.size === "l",
    ) as Extract<Mutation, { op: "create" }>;
    expect(session.propsOf("radio", title.id).content).toBe(rotated.text);

    // ---------------------------------------------------------------- stop
    router.onEnvelope(session, envelope("radio", "event", { id: play!.id, name: "click", data: {} }));
    await waitFor(() => session.propsOf("radio", play!.id).icon === "sf:play");
    await waitFor(() => session.wings("radio").at(-1) === null);
  }, 40000);
});
