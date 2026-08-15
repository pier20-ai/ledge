import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { applyMeta, fallbackIdentity, parseCatalogApp, type CatalogApp } from "../src/registry";
import { sanitizeAppMeta } from "../src/worker/meta";
import { sanitizeWing } from "../src/worker/wing";
import { parseEnvelope } from "../src/protocol/envelope";

// The app-declared surface (spec §6 `meta`, §3.3 wings) and the catalog schema
// it feeds (§3.6). Both sanitizers run inside the worker AND on the host thread,
// so "what an app may say" has exactly one definition per side of the wire — and
// the golden fixtures are replayed here against the same decoder the Swift shell
// replays them against.

const FIXTURES = join(import.meta.dir, "..", "..", "protocol", "fixtures");

describe("sanitizeAppMeta (spec §6)", () => {
  test("a well-formed meta survives intact", () => {
    expect(
      sanitizeAppMeta({
        name: "Chess",
        icon: "sf:crown",
        panel: { width: 520, maxHeight: 560 },
      }),
    ).toEqual({ name: "Chess", icon: "sf:crown", panel: { width: 520, maxHeight: 560 } });
  });

  test("absent, partial and nonsense metas all coerce to something usable", () => {
    // An app that declares nothing at all is the common case, not an error.
    expect(sanitizeAppMeta(undefined)).toEqual({});
    expect(sanitizeAppMeta(null)).toEqual({});
    expect(sanitizeAppMeta("Chess")).toEqual({});
    expect(sanitizeAppMeta(["Chess"])).toEqual({});
    expect(sanitizeAppMeta(() => {})).toEqual({});

    // Partial: only what was declared comes through.
    expect(sanitizeAppMeta({ icon: "sf:tag" })).toEqual({ icon: "sf:tag" });
    expect(sanitizeAppMeta({ name: "  Deal Watch  " })).toEqual({ name: "Deal Watch" });

    // Wrong types are dropped, never coerced into a lie.
    expect(sanitizeAppMeta({ name: 42, icon: {}, panel: "big" })).toEqual({});
    expect(sanitizeAppMeta({ name: "" })).toEqual({});
  });

  test("panel numbers must be finite and positive; a panel of nothing is no panel", () => {
    expect(sanitizeAppMeta({ panel: { width: 520 } }).panel).toEqual({ width: 520 });
    expect(sanitizeAppMeta({ panel: { maxHeight: 600 } }).panel).toEqual({ maxHeight: 600 });
    expect(sanitizeAppMeta({ panel: { width: 520.4 } }).panel).toEqual({ width: 520 });
    expect(sanitizeAppMeta({ panel: { width: 0 } }).panel).toBeUndefined();
    expect(sanitizeAppMeta({ panel: { width: -10 } }).panel).toBeUndefined();
    expect(sanitizeAppMeta({ panel: { width: Infinity } }).panel).toBeUndefined();
    expect(sanitizeAppMeta({ panel: { width: NaN } }).panel).toBeUndefined();
    expect(sanitizeAppMeta({ panel: {} }).panel).toBeUndefined();
  });

  test("an absurd width is NOT clamped here — sizing policy belongs to the shell", () => {
    expect(sanitizeAppMeta({ panel: { width: 4000 } }).panel).toEqual({ width: 4000 });
  });

  test("runaway strings are capped so one app can't bloat a catalog frame", () => {
    const meta = sanitizeAppMeta({ name: "x".repeat(500), icon: "sf:" + "y".repeat(500) });
    expect(meta.name!.length).toBe(64);
    expect(meta.icon!.length).toBe(128);
  });
});

describe("applyMeta → catalog entry (spec §3.6)", () => {
  const base: CatalogApp = {
    id: "chess",
    ...fallbackIdentity("chess"),
    order: 0,
    enabled: true,
    running: true,
  };

  test("the dirname fallback survives for an app that declares nothing", () => {
    expect(base.name).toBe("Chess");
    expect(applyMeta(base, {})).toEqual(base);
    expect(applyMeta(base, undefined)).toEqual(base);
  });

  test("declared fields win, undeclared ones keep the fallback", () => {
    const merged = applyMeta(base, { icon: "sf:crown", panel: { width: 520 } });
    expect(merged.icon).toBe("sf:crown");
    expect(merged.name).toBe("Chess");       // still the dirname fallback
    expect(merged.panel).toEqual({ width: 520 });
    expect(base.icon).toBe("sf:square.dashed"); // and the input is untouched
  });
});

describe("catalog fixture (golden, shared with the Swift shell)", () => {
  test("every row validates, and `panel` is optional per app", async () => {
    const raw = await Bun.file(join(FIXTURES, "catalog.json")).json();
    const envelope = parseEnvelope(raw);
    expect(envelope.type).toBe("catalog");
    const apps = (envelope.payload.apps as unknown[]).map(parseCatalogApp);

    expect(apps.map((a) => a.id)).toEqual(["stocks", "music", "chess", "deals"]);
    expect(apps.find((a) => a.id === "chess")!.panel).toEqual({ width: 520, maxHeight: 560 });
    expect(apps.find((a) => a.id === "stocks")!.panel).toBeUndefined();
  });

  test("a malformed row is rejected rather than silently half-read", () => {
    expect(() => parseCatalogApp({ id: "x" })).toThrow();
    expect(() => parseCatalogApp("x")).toThrow();
    expect(() =>
      parseCatalogApp({ id: "x", name: "X", icon: "", order: 0, enabled: true, running: true, panel: {} }),
    ).toThrow();
  });
});

describe("sanitizeWing (spec §3.3 extension)", () => {
  test("the four wing shapes round-trip", () => {
    expect(sanitizeWing({ text: "AAPL ▲ 1.2%", canvas: { id: 12, w: 64 } })).toEqual({
      text: "AAPL ▲ 1.2%",
      canvas: { id: 12, w: 64 },
    });
    expect(sanitizeWing({ width: 286 })).toEqual({ width: 286 });
    // The meter (flow.md's third wing form): the app names a fraction and the
    // shell owns every other number.
    expect(sanitizeWing({ text: "12:04", meter: { value: 0.42 } })).toEqual({
      text: "12:04",
      meter: { value: 0.42 },
    });
    expect(sanitizeWing({})).toEqual({});
  });

  test("a meter value is clamped to 0…1, never dropped for being out of range", () => {
    // A progress dividing by a total it just changed reads 1.02 for one frame;
    // that is a full bar, not a wing that blinks out.
    expect(sanitizeWing({ meter: { value: 1.8 } })).toEqual({ meter: { value: 1 } });
    expect(sanitizeWing({ meter: { value: -3 } })).toEqual({ meter: { value: 0 } });
    expect(sanitizeWing({ meter: { value: 0 } })).toEqual({ meter: { value: 0 } });
    // NaN is the one value with no reading at all, and a meter is not a wing on
    // its own account here — the whole field goes.
    expect(sanitizeWing({ meter: { value: NaN } })).toEqual({});
    expect(sanitizeWing({ meter: { value: "half" } })).toEqual({});
    expect(sanitizeWing({ meter: 0.5 })).toEqual({});
  });

  test("null and non-objects clear the wing", () => {
    expect(sanitizeWing(null)).toBeNull();
    expect(sanitizeWing(undefined)).toBeNull();
    expect(sanitizeWing("wing")).toBeNull();
    expect(sanitizeWing([])).toBeNull();
  });

  test("bad fields are dropped, not coerced", () => {
    expect(sanitizeWing({ text: 5, width: "wide", canvas: { id: "a", w: 4 } })).toEqual({});
    expect(sanitizeWing({ canvas: { id: 12 } })).toEqual({});          // no width, no strip
    expect(sanitizeWing({ canvas: { id: 0, w: 20 } })).toEqual({});    // node ids start at 1
    expect(sanitizeWing({ width: -3 })).toEqual({});
    expect(sanitizeWing({ text: "   " })).toEqual({});
    expect(sanitizeWing({ text: "w".repeat(200) })!.text!.length).toBe(48);
  });

  test("chrome wing fixtures decode to what the worker would have posted", async () => {
    for (const [file, expected] of [
      ["chrome-wing.json", { text: "AAPL ▲ 1.2%", canvas: { id: 12, w: 64 } }],
      ["chrome-wing-width.json", { width: 286 }],
      ["chrome-wing-clear.json", null],
      ["chrome-wing-meter.json", { text: "12:04", meter: { value: 0.42 } }],
      // The wire may carry an out-of-range value (a fixture proving the shell
      // clamps too); the host's own sanitizer never lets one past.
      ["chrome-wing-meter-clamp.json", { meter: { value: 1 } }],
    ] as const) {
      const envelope = parseEnvelope(await Bun.file(join(FIXTURES, file)).json());
      expect(envelope.type).toBe("chrome");
      expect(envelope.payload.request).toBe("wing");
      expect(sanitizeWing(envelope.payload.wing)).toEqual(expected);
    }
  });

  test("the draw fixture is a plain (id, ops) frame, unknown ops included", async () => {
    const envelope = parseEnvelope(await Bun.file(join(FIXTURES, "draw-frame.json")).json());
    expect(envelope.type).toBe("draw");
    expect(envelope.app).toBe("play");
    expect(envelope.payload.id).toBe(12);
    const ops = envelope.payload.ops as Array<{ op: string }>;
    // The host forwards ops verbatim — including `image`, whose `src` is an
    // absolute path the shell reads and the host never touches.
    expect(ops.map((o) => o.op)).toEqual(["clear", "rect", "line", "text", "image", "orbit"]);
  });
});
