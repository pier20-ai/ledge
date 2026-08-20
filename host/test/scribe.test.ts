import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import type { Mutation } from "../src/render/mutations";
import { Router } from "../src/router";

// **Scribe is the first app with honest levels** (G3), and the capability under
// it — `ctx.record` — is the first that owns a *session* rather than answering a
// question. So this suite drives the real `protocol/demo-apps/scribe/app.jsx`
// through the real Router and a real worker, and presses it the way the shell
// does: `event` envelopes naming node ids out of the app's own mount batch.
//
// The recorder itself is the app's own `LEDGE_RECORD_FAKE` seam — a test run
// must not open the microphone, and there is no shell here to open it — but
// everything the fake produces is real: it makes directories, writes a
// `meta.json`, and the app reads its session list back off the disk. The whole
// life of a take:
//
//   mount        → the record glyph, and a bare notch;
//   record       → the wing is claimed with the ticker and the dot, and frames
//                  flow (two needles and a pulse);
//   jot          → a row appears and `jots.json` is on disk, stamped;
//   stop         → the wing is handed back, `meta.json` is written, and the
//                  session joins the list with its date and its jot count;
//   ✕            → the folder is gone and the empty state is back.

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
  /** The merged prop state of one node, as the shell's shadow tree holds it. */
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

/** A temp apps root holding one real demo app, by symlink per file — `scanApps`
 * looks for directories, so a symlinked folder would not be found. */
async function appsRootWith(appId: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), `ledge-${appId}-`));
  roots.push(root);
  await symlink(NODE_MODULES, join(root, "node_modules"));
  const source = join(DEMO_APPS, appId);
  await mkdir(join(root, appId), { recursive: true });
  for (const entry of await readdir(source)) {
    if (entry === "console.log" || entry === "recordings") continue;
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

const EMPTY_LINE = "Nothing recorded yet — press record.";

describe("scribe, recorded the way the shell records", () => {
  test("record / jot / stop / discard drives the needles, the wing and the disk", async () => {
    const root = await appsRootWith("scribe");
    // The seam. `LEDGE_RECORD_ROOT` is not optional here: `import.meta.url`
    // resolves through the symlinks above, so the app's own fallback would put
    // this run's sessions in the repo.
    process.env.LEDGE_RECORD_FAKE = "1";
    const recordings = join(root, "recordings");
    process.env.LEDGE_RECORD_ROOT = recordings;

    const session = new RecordingSession();
    const router = new Router({
      appsRoot: root,
      settingsPath: join(root, "settings.json"),
      watch: false,
    });
    openRouter = router;
    await router.bindSession(session);

    const mutations = () =>
      session.envelopesFor("scribe", "commit").flatMap((e) => e.payload.mutations as Mutation[]);
    const creates = () =>
      mutations().filter((m): m is Extract<Mutation, { op: "create" }> => m.op === "create");
    const texts = () =>
      creates()
        .filter((m) => m.kind === "text")
        .map((m) => String(m.props.content ?? ""));
    /** Every frame pushed to one canvas node, in order — `ctx.draw` bypasses
     * the reconciler, so this is the only place the picture shows up. */
    type Op = Record<string, unknown>;
    const drawsFor = (id: number): Op[][] =>
      session
        .envelopesFor("scribe", "draw")
        .filter((e) => e.payload.id === id)
        .map((e) => e.payload.ops as Op[]);
    /** Where a needle is pointing, by the x of its far end. The needle is the
     * only 2 pt hot line on the face — the clipping ticks are 1 pt. */
    const needlesIn = (ops: Op[]): number[] =>
      ops
        .filter((op) => op.op === "line" && op.stroke === "#E8402A" && op.width === 2)
        .map((op) => (op.points as number[][])[1]![0]!);

    // Rows are re-created on structural renders and their props move by
    // in-place updates, so a control is found the way the shell holds it: the
    // shadow tree — creates with every later update folded over them, and the
    // parent chain up to the newest row that holds the label's text.
    function control(label: string, icon: string): number {
      const parentOf = new Map<number, number>();
      const kindOf = new Map<number, string>();
      const propsOf = new Map<number, Record<string, unknown>>();
      for (const m of mutations()) {
        if (m.op === "insert") parentOf.set(m.id, m.parent);
        if (m.op === "create") {
          kindOf.set(m.id, m.kind);
          propsOf.set(m.id, { ...m.props });
        }
        if (m.op === "update") Object.assign(propsOf.get(m.id) ?? {}, m.props);
      }
      const ids = [...kindOf.keys()];
      const labelId = ids
        .filter((id) => kindOf.get(id) === "text" && propsOf.get(id)!.content === label)
        .at(-1)!;
      const row = parentOf.get(parentOf.get(labelId)!)!; // text → column → row
      return ids
        .filter(
          (id) =>
            kindOf.get(id) === "button" &&
            propsOf.get(id)!.icon === icon &&
            parentOf.get(id) === row,
        )
        .at(-1)!;
    }

    // ---------------------------------------------------------------- idle
    await waitFor(
      () =>
        creates().some((m) => m.kind === "canvas" && m.props.w === 380) &&
        creates().some((m) => m.kind === "canvas" && m.props.w === 14) &&
        creates().some((m) => m.kind === "button" && m.props.icon),
    );
    const stage = creates().find((m) => m.kind === "canvas" && m.props.w === 380)!;
    const dot = creates().find((m) => m.kind === "canvas" && m.props.w === 14)!;
    const transport = creates().find((m) => m.kind === "button" && m.props.icon)!;
    // A meter is read, never pressed: the stage declares no gesture at all.
    expect(stage.props.onClick).toBeUndefined();
    expect(stage.props.onDrag).toBeUndefined();
    expect(transport.props.variant).toBe("ghost");
    expect(session.propsOf("scribe", transport.id).icon).toBe("sf:record.circle");

    // The shell sends explicit lifecycle alongside a visit; the app paints the
    // face on it, and the face is what this app is.
    router.onEnvelope(
      session,
      envelope("scribe", "lifecycle", { phase: "expanded", reduceMotion: false }),
    );
    await waitFor(() => drawsFor(stage.id).length >= 1);

    // The face is drawn and labelled, and both needles are cold: nothing is
    // recording, so nothing on it is red.
    const resting = drawsFor(stage.id).at(-1)!;
    expect(resting.some((op) => op.op === "text" && op.content === "MIC")).toBe(true);
    expect(resting.some((op) => op.op === "text" && op.content === "SYS")).toBe(true);
    expect(needlesIn(resting)).toHaveLength(0);
    // …and the wing's dot is blank rather than absent: a cleared canvas.
    expect(drawsFor(dot.id).at(-1)).toEqual([{ op: "clear" }]);

    // Nothing recorded and nothing recording: one glyph, one line, a bare
    // notch — and the honest word about transcription on this machine.
    await waitFor(() => texts().includes("transcription needs macOS 26"));
    expect(texts()).toContain(EMPTY_LINE);
    expect(session.wings("scribe")).toHaveLength(0);

    // ---------------------------------------------------------------- record
    const click = (id: number) =>
      router.onEnvelope(session, envelope("scribe", "event", { id, name: "click", data: {} }));
    click(transport.id);

    await waitFor(() => session.propsOf("scribe", transport.id).icon === "sf:stop.circle");
    await waitFor(() => session.wings("scribe").length >= 1);
    const claim = session.wings("scribe")[0]!;
    expect(claim).not.toBeNull();
    expect(claim.text).toMatch(/^\d\d:\d\d$/); // the ticker, mm:ss
    expect((claim.canvas as { id: number }).id).toBe(dot.id);

    // The frames are flowing, and they are honest ones. Both needles are hot
    // and each takes several distinct positions — this is the app's whole
    // claim: the face is reading `levels()`, not animating a sine of its own
    // invention. (The fake's levels ARE sines, but the app never sees that —
    // it sees numbers arriving 7 times a second.)
    await waitFor(() => {
      const swept = drawsFor(stage.id).map(needlesIn).filter((xs) => xs.length === 2);
      const mic = new Set(swept.map((xs) => Math.round(xs[0]!)));
      const sys = new Set(swept.map((xs) => Math.round(xs[1]!)));
      return mic.size >= 3 && sys.size >= 3;
    });
    // …and the dot is pulsing in the wing.
    await waitFor(
      () => drawsFor(dot.id).filter((ops) => ops.some((op) => op.fill === "#E8402A")).length >= 3,
    );

    // The fake opened a real session directory.
    const [dir] = await readdir(recordings);
    expect(dir).toBeString();

    // ---------------------------------------------------------------- jot
    // The shell's input fires `change` on Enter, and that IS the submit.
    await waitFor(() => creates().some((m) => m.kind === "input"));
    const input = creates().find((m) => m.kind === "input")!;
    expect(input.props.onChange).toBe(true);
    router.onEnvelope(
      session,
      envelope("scribe", "event", {
        id: input.id,
        name: "change",
        data: { value: "decided: ship Tuesday" },
      }),
    );
    await waitFor(() => texts().includes("decided: ship Tuesday"));
    // …and it is on disk, stamped: the row is the app's memory, the file is
    // the session's. The write follows the commit, so it is waited for.
    const jotsPath = join(recordings, dir!, "jots.json");
    let kept: Array<{ at: number; text: string }> | null = null;
    for (let attempt = 0; attempt < 100 && kept === null; attempt += 1) {
      try {
        kept = await Bun.file(jotsPath).json();
      } catch {
        await Bun.sleep(20);
      }
    }
    expect(kept).toHaveLength(1);
    expect(kept![0]!.text).toBe("decided: ship Tuesday");
    expect(kept![0]!.at).toBeGreaterThanOrEqual(0);

    // ---------------------------------------------------------------- stop
    click(transport.id);
    await waitFor(() => session.propsOf("scribe", transport.id).icon === "sf:record.circle");
    await waitFor(() => session.wings("scribe").at(-1) === null);

    const meta = await Bun.file(join(recordings, dir!, "meta.json")).json();
    expect(meta.app).toBe("scribe");
    expect(meta.seconds).toBeGreaterThan(0);
    expect(meta.sources).toEqual(["mic", "system"]);

    // The take is now a row: its moment, its length, and what was jotted in it.
    await waitFor(() => texts().some((content) => content.includes("1 jot")));
    const stamp = texts().find((content) => /·\s\d{2}:\d{2}$/.test(content))!;
    expect(stamp).toBeString();
    // A session row carries both trailing controls — reveal and discard.
    expect(control(stamp, "sf:folder")).toBeGreaterThan(0);

    // ---------------------------------------------------------------- discard
    const emptyStates = () => texts().filter((content) => content === EMPTY_LINE).length;
    const before = emptyStates();
    click(control(stamp, "sf:xmark"));
    await waitFor(() => emptyStates() > before);
    expect(await readdir(recordings)).toHaveLength(0);
  }, 45000);
});
