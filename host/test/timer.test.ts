import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import type { Mutation } from "../src/render/mutations";
import { Router } from "../src/router";
// The grammar is a pure function; pin it directly. (@ts-expect-error: the
// app is JSX without declarations — the suite wants its runtime, not types.)
// @ts-expect-error -- untyped demo app module
import { parseAlarm } from "../../protocol/demo-apps/timer/app.jsx";

// **Alarms is a list you talk to** (G2.12). The local grammar handles the
// common shapes; everything else would go to a model this suite never calls
// (no OPENAI_API_KEY here, deliberately). The worker half is driven the way
// the shell drives it: an input's Enter is an `event` envelope named
// `change`, and the row's controls are ghost buttons.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");
const DEMO_APPS = join(HOST_DIR, "..", "protocol", "demo-apps");

describe("the grammar", () => {
  const noon = new Date("2026-08-20T12:00:00").getTime();

  test("clock times land on the next occurrence", () => {
    expect(parseAlarm("7:30 pm", noon)!.note).toBe("7:30 pm");
    expect(new Date(parseAlarm("7:30 pm", noon)!.fireAt).getHours()).toBe(19);
    // Bare hours pick the NEXT face of the clock: "7" at noon is 7 tonight…
    expect(new Date(parseAlarm("7", noon)!.fireAt).getHours()).toBe(19);
    // …and 24h readings are taken literally.
    expect(new Date(parseAlarm("19:45", noon)!.fireAt).getHours()).toBe(19);
    // Tomorrow is tomorrow, even when the time would fit today.
    const tomorrow = parseAlarm("tomorrow 9am", noon)!.fireAt;
    expect(new Date(tomorrow).getDate()).toBe(21);
    expect(new Date(tomorrow).getHours()).toBe(9);
  });

  test("durations sum their parts and label themselves honestly", () => {
    expect(parseAlarm("in 20 min", noon)).toEqual({ fireAt: noon + 20 * 60_000, note: "20 min" });
    expect(parseAlarm("1h 30m", noon)!.note).toBe("1 h 30 min");
    expect(parseAlarm("90 seconds", noon)!.fireAt).toBe(noon + 90_000);
    expect(parseAlarm("90 seconds", noon)!.note).toBe("90 s");
  });

  test("what it cannot read whole, it refuses whole", () => {
    // Half-parsing "sunset over the marina" into a 6:00 alarm would be worse
    // than refusing: ambiguity is the model's job.
    expect(parseAlarm("sunset over the marina", noon)).toBeNull();
    expect(parseAlarm("ping me at sunset", noon)).toBeNull();
    expect(parseAlarm("25:99", noon)).toBeNull();
    expect(parseAlarm("", noon)).toBeNull();
  });
});

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
  wings(app: string): Array<Record<string, unknown> | null> {
    return this.envelopesFor(app, "chrome")
      .filter((e) => e.payload.request === "wing")
      .map((e) => (e.payload.wing ?? null) as Record<string, unknown> | null);
  }
  peeks(app: string) {
    return this.envelopesFor(app, "chrome").filter((e) => e.payload.request === "peek");
  }
}

let roots: string[] = [];
let openRouter: Router | null = null;

async function appsRootWith(appId: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), `ledge-${appId}-`));
  roots.push(root);
  await symlink(NODE_MODULES, join(root, "node_modules"));
  const source = join(DEMO_APPS, appId);
  await mkdir(join(root, appId), { recursive: true });
  for (const entry of await readdir(source)) {
    if (entry === "console.log" || entry === "alarms.json") continue;
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

describe("alarms, driven the way the shell drives them", () => {
  test("type, pause, ring, stop: the whole life of an alarm", async () => {
    delete process.env.OPENAI_API_KEY; // the model is never part of a suite

    const root = await appsRootWith("timer");
    // `import.meta.url` resolves through the symlink, so without this the
    // app's store would land in the repo and runs would haunt each other.
    process.env.LEDGE_ALARM_STORE = join(root, "timer", "alarms.json");
    const session = new RecordingSession();
    const router = new Router({ appsRoot: root, settingsPath: join(root, "settings.json"), watch: false });
    openRouter = router;
    await router.bindSession(session);
    await waitFor(() => session.envelopesFor("timer", "commit").length >= 1);

    const mutations = () =>
      session.envelopesFor("timer", "commit").flatMap((e) => e.payload.mutations as Mutation[]);
    const creates = () =>
      mutations().filter((m): m is Extract<Mutation, { op: "create" }> => m.op === "create");

    // Rows are re-created on structural renders and their props move by
    // in-place updates, so a control is found the way the shell holds it: the
    // shadow tree — creates with every later update folded over them, and the
    // parent chain up to the newest row that holds the note's text.
    function control(note: string, icon: string): number {
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
      const noteId = ids
        .filter((id) => kindOf.get(id) === "text" && propsOf.get(id)!.content === note)
        .at(-1)!;
      const row = parentOf.get(parentOf.get(noteId)!)!; // text → column → row
      return ids
        .filter(
          (id) =>
            kindOf.get(id) === "button" &&
            propsOf.get(id)!.icon === icon &&
            parentOf.get(id) === row,
        )
        .at(-1)!;
    }

    const input = creates().find((m) => m.kind === "input")!;
    expect(input.props.onChange).toBe(true);
    const type = (value: string) =>
      router.onEnvelope(session, envelope("timer", "event", { id: input.id, name: "change", data: { value } }));
    const click = (id: number) =>
      router.onEnvelope(session, envelope("timer", "event", { id, name: "click", data: {} }));

    // A clock alarm: the row appears with its note, and the wing goes up
    // with the shell's meter form.
    type("7:30 pm");
    await waitFor(() => creates().some((m) => m.kind === "text" && m.props.content === "7:30 pm"));
    await waitFor(() => session.wings("timer").length >= 1);
    expect(session.wings("timer")[0]).toHaveProperty("meter");

    // Pause the row: nothing is due any more, so the wing is handed back.
    click(control("7:30 pm", "sf:pause"));
    await waitFor(() => session.wings("timer").at(-1) === null);

    // Resume: the wing re-claims.
    click(control("7:30 pm", "sf:play"));
    await waitFor(() => {
      const last = session.wings("timer").at(-1);
      return last !== null && last !== undefined;
    });

    // A near alarm rings: alert-class peek; Stop is the alert's one action.
    type("in 1 s");
    await waitFor(() => session.peeks("timer").length >= 1, 20000);
    expect(session.peeks("timer")[0]!.payload.class).toBe("alert");

    const stop = creates().find((m) => m.kind === "button" && m.props.label === "Stop")!;
    click(stop.id);
    // Stopping removes the rung alarm; the 7:30 alarm remains and the wing
    // stays claimed — the list is the state, not the ring.
    await waitFor(() => {
      const last = session.wings("timer").at(-1);
      return last !== null && last !== undefined && typeof last.text === "string";
    });

    // Deleting the last row empties the list and hands the wing back.
    click(control("7:30 pm", "sf:xmark"));
    await waitFor(() => session.wings("timer").at(-1) === null, 20000);
  }, 45000);
});
