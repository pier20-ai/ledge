import { describe, expect, test } from "bun:test";
import { readdir } from "node:fs/promises";
import { join } from "node:path";
import type { Mutation } from "../src/render/mutations";
import {
  EnvelopeError,
  SeqAllocator,
  SeqTracker,
  parseEnvelope,
} from "../src/protocol/envelope";

const FIXTURES = join(import.meta.dir, "..", "..", "protocol", "fixtures");

/** Parses a commit fixture through the real envelope parser and hands back its
 * §3.1 mutation list. Both sides replay this corpus, so the assertions below are
 * on the actual contents — a fixture that merely parses proves nothing. */
async function commitMutations(file: string): Promise<Mutation[]> {
  const envelope = parseEnvelope(await Bun.file(join(FIXTURES, file)).json());
  expect(envelope.type).toBe("commit");
  const mutations = (envelope.payload as { mutations: Mutation[] }).mutations;
  expect(Array.isArray(mutations)).toBe(true);
  return mutations;
}

function creates(mutations: Mutation[]): Extract<Mutation, { op: "create" }>[] {
  return mutations.filter(
    (m): m is Extract<Mutation, { op: "create" }> => m.op === "create",
  );
}

function propsById(mutations: Mutation[], id: number): Record<string, unknown> {
  const mutation = mutations.find(
    (m) => (m.op === "create" || m.op === "update") && m.id === id,
  );
  if (!mutation) throw new Error(`no create/update for id ${id}`);
  return (mutation as { props: Record<string, unknown> }).props;
}

describe("golden fixtures", () => {
  test("every fixture parses as a valid envelope", async () => {
    const files = (await readdir(FIXTURES)).filter((f) => f.endsWith(".json"));
    expect(files.length).toBeGreaterThan(5);
    for (const file of files) {
      const raw = await Bun.file(join(FIXTURES, file)).json();
      const envelope = parseEnvelope(raw);
      expect(envelope.v).toBe(1);
      expect(envelope.type.length).toBeGreaterThan(0);
    }
  });

  test("builder stream fixture parses line by line", async () => {
    const text = await Bun.file(join(FIXTURES, "builder-stream.jsonl")).text();
    const lines = text.trim().split("\n");
    expect(lines.length).toBe(4);
    for (const line of lines) {
      const envelope = parseEnvelope(JSON.parse(line));
      expect(envelope.type).toBe("builder");
      expect(envelope.app).toBe("");
    }
  });
});

const NEW_KINDS = ["toggle", "segment", "stepper", "progress", "spinner", "pill"];

describe("new-kinds fixtures (design D6)", () => {
  test("commit-new-kinds mounts every one of the six ratified kinds", async () => {
    const mutations = await commitMutations("commit-new-kinds.json");
    const kinds = creates(mutations).map((m) => m.kind);
    for (const kind of NEW_KINDS) expect(kinds).toContain(kind);

    // Structural invariants the shell's shadow-tree validation enforces (§3.1):
    // create before the insert that names it, exactly one setRoot, last.
    const seen = new Set<number>();
    for (const mutation of mutations) {
      if (mutation.op === "create") {
        expect(seen.has(mutation.id)).toBe(false);
        seen.add(mutation.id);
      }
      if (mutation.op === "insert") {
        expect(seen.has(mutation.id)).toBe(true);
        expect(seen.has(mutation.parent)).toBe(true);
      }
    }
    expect(mutations.filter((m) => m.op === "setRoot")).toHaveLength(1);
    expect(mutations.at(-1)!.op).toBe("setRoot");

    // The scrolling vertical stack is the container upgrade from the same wave.
    expect(propsById(mutations, 1)).toMatchObject({ axis: "v", scroll: true });
    // Handlers are on the wire as `true`, never as a function or a name.
    expect(propsById(mutations, 2)).toEqual({ on: true, onChange: true });
    expect(propsById(mutations, 3)).toEqual({
      on: false,
      disabled: true,
      onChange: true,
    });
    expect(propsById(mutations, 4).options).toEqual([
      { id: "1d", label: "1D" },
      { id: "1w", label: "1W" },
      { id: "1m", label: "1M" },
    ]);
    expect(propsById(mutations, 4).value).toBe("1w");
    expect(propsById(mutations, 5)).toMatchObject({ value: 7, min: 0, max: 23, step: 1 });
    // stepper.format is the app-supplied display string, shown instead of 450.
    expect(propsById(mutations, 6)).toMatchObject({ value: 450, step: 5, format: "07:30" });
    expect(propsById(mutations, 7)).toEqual({ value: 0.64 });
    expect(propsById(mutations, 8)).toEqual({});
    expect(propsById(mutations, 9)).toEqual({ label: "PAPER", tone: "accent" });
    expect(propsById(mutations, 10)).toEqual({ label: "DRAFT", tone: "neutral" });
  });

  test("progress and spinner carry no handler props at all", async () => {
    const mutations = await commitMutations("commit-new-kinds.json");
    for (const create of creates(mutations)) {
      if (create.kind !== "progress" && create.kind !== "spinner") continue;
      for (const key of Object.keys(create.props)) {
        expect(key.startsWith("on")).toBe(false);
      }
    }
  });

  test("commit-new-kinds-update updates every mounted node in place", async () => {
    const mount = await commitMutations("commit-new-kinds.json");
    const update = await commitMutations("commit-new-kinds-update.json");

    // In-place means updates only — no create and no remove in the second frame.
    expect([...new Set(update.map((m) => m.op))]).toEqual(["update"]);

    // Every non-root node from the mount gets an update, so each of the six
    // kinds is exercised on the update path too.
    const updated = new Set(update.map((m) => (m as { id: number }).id));
    for (const create of creates(mount)) {
      if (create.kind === "stack") continue;
      expect(updated.has(create.id)).toBe(true);
    }
    // …and every updated id was actually created (no unknown-id updates).
    const mounted = new Set(creates(mount).map((m) => m.id));
    for (const id of updated) expect(mounted.has(id)).toBe(true);

    expect(propsById(update, 2)).toEqual({ on: false });
    // A dropped prop is deleted with null, per §3.1 partial updates.
    expect(propsById(update, 3)).toEqual({ disabled: null, on: true });
    expect(propsById(update, 4)).toEqual({ value: "1m" });
    expect(propsById(update, 6)).toEqual({ value: 465, format: "07:45" });
    expect(propsById(update, 9)).toEqual({ label: "LIVE", tone: "green" });
  });
});

describe("control-props fixtures (design D8)", () => {
  test("commit-control-props carries the new props on existing kinds", async () => {
    const mutations = await commitMutations("commit-control-props.json");

    // Button size ramp — s/l explicit, and the default m expressed by omission.
    const buttons = creates(mutations).filter((m) => m.kind === "button");
    expect(buttons.map((m) => m.props.size)).toEqual([
      "s",
      undefined,
      "l",
      undefined,
      undefined,
    ]);
    expect(buttons.some((m) => m.props.disabled === true)).toBe(true);
    // Icon-only: an empty label contributes zero width (law L2), so it is "" and
    // not a missing key — the shell must be able to tell them apart.
    expect(buttons.some((m) => m.props.label === "" && m.props.icon === "sf:play.fill"))
      .toBe(true);

    // Slider min/max/step: value lives in min…max space, no longer 0…1.
    expect(propsById(mutations, 7)).toMatchObject({
      value: 90,
      min: 60,
      max: 200,
      step: 5,
    });

    // text: multi-line is opt-in, and truncate=false clips without an ellipsis.
    expect(propsById(mutations, 8).maxLines).toBe(3);
    expect(propsById(mutations, 9).truncate).toBe(false);
  });

  test("commit-control-props-update moves size, disabled, value and truncation", async () => {
    const mutations = await commitMutations("commit-control-props-update.json");
    expect([...new Set(mutations.map((m) => m.op))]).toEqual(["update"]);

    expect(propsById(mutations, 2)).toEqual({ size: "l" });
    expect(propsById(mutations, 4)).toEqual({ size: "s" });
    // Re-enabling deletes the key rather than sending `disabled: false`.
    expect(propsById(mutations, 6)).toEqual({ disabled: null });
    expect(propsById(mutations, 7)).toEqual({ value: 145 });
    expect(propsById(mutations, 8)).toEqual({ maxLines: 1 });
    expect(propsById(mutations, 9)).toEqual({ truncate: true });

    // Every id addressed here exists in the mount frame it follows.
    const mounted = new Set(
      creates(await commitMutations("commit-control-props.json")).map((m) => m.id),
    );
    for (const mutation of mutations) {
      expect(mounted.has((mutation as { id: number }).id)).toBe(true);
    }
  });

  test("the two fixture pairs form one ordered app scope", async () => {
    const seqs: number[] = [];
    for (const file of [
      "commit-new-kinds.json",
      "commit-new-kinds-update.json",
      "commit-control-props.json",
      "commit-control-props-update.json",
    ]) {
      const envelope = parseEnvelope(await Bun.file(join(FIXTURES, file)).json());
      expect(envelope.app).toBe("gallery");
      seqs.push(envelope.seq);
    }
    const tracker = new SeqTracker();
    for (const seq of seqs) {
      expect(
        tracker.accept(
          parseEnvelope({ v: 1, app: "gallery", seq, type: "commit", payload: {} }),
        ),
      ).toBe(true);
    }
  });
});

describe("panel-wing fixtures (spec §5)", () => {
  test("commit-wing mounts a left wing as a direct child of the root", async () => {
    const mutations = await commitMutations("commit-wing.json");
    const wing = creates(mutations).find((m) => m.kind === "wing")!;
    expect(wing.props).toEqual({ side: "left" });

    const root = mutations.find((m) => m.op === "setRoot") as { id: number };
    const inserts = mutations.filter(
      (m): m is Extract<Mutation, { op: "insert" }> => m.op === "insert",
    );
    // The placement rule: a wing hangs off the root, never off a card. The
    // shell enforces it (§3.1) because a wing nested deeper would render into a
    // zone its parent cannot see.
    expect(inserts.find((m) => m.id === wing.id)!.parent).toBe(root.id);
    // Its children are ordinary nodes; nothing about the wire says "chrome".
    expect(inserts.filter((m) => m.parent === wing.id)).toHaveLength(2);
  });

  test("commit-wing-update updates the wing's children in place", async () => {
    const mount = await commitMutations("commit-wing.json");
    const update = await commitMutations("commit-wing-update.json");
    expect([...new Set(update.map((m) => m.op))]).toEqual(["update"]);

    const wing = creates(mount).find((m) => m.kind === "wing")!;
    const wingChildren = new Set(
      mount
        .filter((m) => m.op === "insert" && m.parent === wing.id)
        .map((m) => (m as { id: number }).id),
    );
    for (const mutation of update) {
      expect(wingChildren.has((mutation as { id: number }).id)).toBe(true);
    }
    expect(propsById(update, 4)).toEqual({ content: "5 workers · 41 MB" });
  });

  test("the invalid wing fixtures both ask for a resync", async () => {
    for (const file of ["invalid-commit-right-wing.json", "invalid-commit-nested-wing.json"]) {
      const raw = (await Bun.file(join(FIXTURES, file)).json()) as { _expect: string };
      expect(raw._expect).toBe("resyncRequest");
    }
    // `side: "right"` is the shell's own zone — the app name and the Edit
    // affordance. An app that could claim it could take away the one control
    // that is supposed to always be there, so it is a validation error rather
    // than a request the shell declines.
    const rejected = await commitMutations("invalid-commit-right-wing.json");
    expect(creates(rejected).find((m) => m.kind === "wing")!.props).toEqual({ side: "right" });
  });
});

describe("rate fixtures (spec §5)", () => {
  test("commit-rate carries rate on slider and progress, absent where static", async () => {
    const mutations = await commitMutations("commit-rate.json");
    // A scrubber in seconds rather than 0…1: min/max are the track's own scale
    // and rate is one second of value per second of clock.
    expect(propsById(mutations, 2)).toMatchObject({ value: 64, min: 0, max: 224, rate: 1 });
    expect((propsById(mutations, 3).rate as number) > 0).toBe(true);
    // An app that never heard of `rate` looks exactly as it did before.
    expect("rate" in propsById(mutations, 4)).toBe(false);
  });

  test("commit-rate-update pauses with 0 and deletes with null", async () => {
    const mutations = await commitMutations("commit-rate-update.json");
    expect([...new Set(mutations.map((m) => m.op))]).toEqual(["update"]);
    expect(propsById(mutations, 2)).toEqual({ value: 67, rate: 0 });
    // Both forms mean "static" — `null` is §3.1's canonical delete.
    expect(propsById(mutations, 3)).toEqual({ rate: null });
  });
});

describe("platform fixtures (spec §6 extension)", () => {
  test("observe and unobserve carry a verb, a source and a name", async () => {
    const observe = parseEnvelope(
      await Bun.file(join(FIXTURES, "platform-observe.json")).json(),
    );
    expect(observe.type).toBe("platform");
    expect(observe.payload).toEqual({
      id: 5,
      call: "observe",
      kind: "distributedNotification",
      name: "com.apple.Music.playerInfo",
    });

    const unobserve = parseEnvelope(
      await Bun.file(join(FIXTURES, "platform-unobserve.json")).json(),
    );
    expect(unobserve.payload.call).toBe("unobserve");
  });

  test("the result is an acknowledgement; a success carries no error key", async () => {
    const ok = parseEnvelope(await Bun.file(join(FIXTURES, "platform-result.json")).json());
    expect(ok.type).toBe("platformResult");
    expect(ok.payload).toEqual({ id: 5, ok: true });

    const failed = parseEnvelope(
      await Bun.file(join(FIXTURES, "platform-result-error.json")).json(),
    );
    expect(failed.payload.ok).toBe(false);
    expect(typeof failed.payload.error).toBe("string");
  });

  test("every ratified observe kind has a request fixture with a translated name", async () => {
    const expected: Array<[string, string, string]> = [
      ["platform-observe-workspace.json", "workspace", "didActivateApplication"],
      ["platform-observe-pasteboard.json", "pasteboard", "changed"],
      ["platform-observe-power.json", "power", "changed"],
      ["platform-observe-reachability.json", "reachability", "changed"],
      ["platform-observe-audio.json", "audio", "changed"],
    ];
    for (const [file, kind, name] of expected) {
      const envelope = parseEnvelope(await Bun.file(join(FIXTURES, file)).json());
      expect(envelope.type).toBe("platform");
      expect(envelope.payload.call).toBe("observe");
      expect(envelope.payload.kind).toBe(kind);
      // Never a raw notification name: `screenLocked`, not
      // `com.apple.screenIsLocked`. The raw names are split across two
      // different notification centers and are Apple's to rename.
      expect(envelope.payload.name).toBe(name);
    }
  });

  test("every new call has a request, a result and an error fixture", async () => {
    const calls: Array<[string, string]> = [
      ["calendar", "platform-calendar"],
      ["workspace", "platform-workspace"],
      ["location", "platform-location"],
      ["spotlight", "platform-spotlight"],
      ["audio", "platform-audio"],
      ["setVolume", "platform-set-volume"],
      ["speak", "platform-speak"],
    ];
    for (const [call, stem] of calls) {
      const request = parseEnvelope(await Bun.file(join(FIXTURES, `${stem}.json`)).json());
      expect(request.type).toBe("platform");
      expect(request.payload.call).toBe(call);
      expect(Number.isInteger(request.payload.id)).toBe(true);

      const ok = parseEnvelope(await Bun.file(join(FIXTURES, `${stem}-result.json`)).json());
      expect(ok.type).toBe("platformResult");
      expect(ok.payload.ok).toBe(true);
      expect(ok.payload.error).toBeUndefined();

      const failed = parseEnvelope(await Bun.file(join(FIXTURES, `${stem}-error.json`)).json());
      expect(failed.payload.ok).toBe(false);
      expect(typeof failed.payload.error).toBe("string");
      // A failure never carries a half-answer alongside the reason.
      expect(failed.payload.data).toBeUndefined();
    }
  });

  test("call results carry their answer in `data`; a call with no answer omits it", async () => {
    const events = (
      await Bun.file(join(FIXTURES, "platform-calendar-result.json")).json()
    ).payload.data as Array<Record<string, unknown>>;
    expect(events).toHaveLength(2);
    expect(events[0]!.title).toBe("Standup");
    // An absent optional is an absent key, not a null — so an app can use `in`.
    expect("location" in events[0]!).toBe(false);
    expect(events[1]!.location).toBe("Studio");

    const fix = (await Bun.file(join(FIXTURES, "platform-location-result.json")).json()).payload
      .data as Record<string, number>;
    expect(fix).toEqual({
      lat: 37.7749,
      lon: -122.4194,
      accuracyMeters: 1200,
      timestamp: "2026-07-25T09:14:03Z" as unknown as number,
    });

    // The request asks for 1.4 and the result reports 1: the clamp is visible on
    // the wire, which is why setVolume answers with a value at all.
    const asked = (await Bun.file(join(FIXTURES, "platform-set-volume.json")).json()).payload.value;
    const applied = (await Bun.file(join(FIXTURES, "platform-set-volume-result.json")).json())
      .payload.data as { volume: number };
    expect(asked).toBe(1.4);
    expect(applied.volume).toBe(1);

    // `speak` finishes; it does not answer.
    const spoke = parseEnvelope(await Bun.file(join(FIXTURES, "platform-speak-result.json")).json());
    expect(spoke.payload).toEqual({ id: 27, ok: true });
  });

  test("one event fixture per new kind, and the pasteboard one carries no contents", async () => {
    const files = [
      "event-platform-workspace.json",
      "event-platform-pasteboard.json",
      "event-platform-power.json",
      "event-platform-reachability.json",
      "event-platform-audio.json",
    ];
    for (const file of files) {
      const envelope = parseEnvelope(await Bun.file(join(FIXTURES, file)).json());
      expect(envelope.type).toBe("event");
      expect(envelope.payload.id).toBe(0);
      expect(envelope.payload.name).toBe("platform");
      const info = (envelope.payload.data as Record<string, unknown>).userInfo as Record<
        string,
        unknown
      >;
      for (const value of Object.values(info)) {
        // Scalars, or an array of them (the pasteboard's type list). Nothing
        // nested: the reduction rule binds every kind, not just the first one.
        if (Array.isArray(value)) {
          expect(value.every((entry) => typeof entry === "string")).toBe(true);
        } else {
          expect(["string", "number", "boolean"]).toContain(typeof value);
        }
      }
    }

    const clipboard = (
      await Bun.file(join(FIXTURES, "event-platform-pasteboard.json")).json()
    ).payload.data.userInfo as Record<string, unknown>;
    expect(clipboard.changeCount).toBe(4821);
    expect(clipboard.hasStrings).toBe(true);
    // The privacy line, made concrete: the event says the pasteboard changed and
    // what shape it now has, never what is on it.
    expect(Object.keys(clipboard).sort()).toEqual(["changeCount", "hasStrings", "types"]);
  });

  test("the event is an ordinary id-0 app event with a scalar-only userInfo", async () => {
    const event = parseEnvelope(await Bun.file(join(FIXTURES, "event-platform.json")).json());
    expect(event.type).toBe("event");
    // No new envelope type: push invalidation reuses §4.1's app-level id 0, the
    // same convention `drop` and `notification` use.
    expect(event.payload.id).toBe(0);
    expect(event.payload.name).toBe("platform");
    const data = event.payload.data as Record<string, unknown>;
    expect(data.kind).toBe("distributedNotification");
    const info = data.userInfo as Record<string, unknown>;
    // The shell reduces userInfo at the boundary: an arbitrary plist would put
    // an unbounded blob on a socket whose failure mode is losing the connection.
    for (const value of Object.values(info)) {
      expect(["string", "number", "boolean"]).toContain(typeof value);
    }
  });
});

describe("parseEnvelope", () => {
  test.each([
    ["not an object", "hi"],
    ["missing v", { app: "", seq: 1, type: "x", payload: {} }],
    ["zero seq", { v: 1, app: "", seq: 0, type: "x", payload: {} }],
    ["fractional seq", { v: 1, app: "", seq: 1.5, type: "x", payload: {} }],
    ["empty type", { v: 1, app: "", seq: 1, type: "", payload: {} }],
    ["array payload", { v: 1, app: "", seq: 1, type: "x", payload: [] }],
  ])("rejects %s", (_name, value) => {
    expect(() => parseEnvelope(value)).toThrow(EnvelopeError);
  });
});

describe("seq scoping", () => {
  test("drops stale seq per app, tracks apps independently", () => {
    const tracker = new SeqTracker();
    expect(tracker.accept(parseEnvelope({ v: 1, app: "stocks", seq: 1, type: "commit", payload: {} }))).toBe(true);
    expect(tracker.accept(parseEnvelope({ v: 1, app: "stocks", seq: 3, type: "commit", payload: {} }))).toBe(true);
    expect(tracker.accept(parseEnvelope({ v: 1, app: "stocks", seq: 3, type: "commit", payload: {} }))).toBe(false);
    expect(tracker.accept(parseEnvelope({ v: 1, app: "stocks", seq: 2, type: "commit", payload: {} }))).toBe(false);
    expect(tracker.accept(parseEnvelope({ v: 1, app: "music", seq: 1, type: "commit", payload: {} }))).toBe(true);
  });

  test("a fresh tracker restarts scoping (new generation)", () => {
    const first = new SeqTracker();
    first.accept(parseEnvelope({ v: 1, app: "stocks", seq: 9, type: "commit", payload: {} }));
    const second = new SeqTracker();
    expect(second.accept(parseEnvelope({ v: 1, app: "stocks", seq: 1, type: "commit", payload: {} }))).toBe(true);
  });

  test("allocator starts each app scope at 1", () => {
    const allocator = new SeqAllocator();
    expect(allocator.allocate("")).toBe(1);
    expect(allocator.allocate("")).toBe(2);
    expect(allocator.allocate("stocks")).toBe(1);
  });
});
