import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { applyMeta, fallbackIdentity, parseCatalogApp, type CatalogApp } from "../src/registry";
import { coerceSettingValue, defaultSettingValue, sanitizeAppMeta } from "../src/worker/meta";
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

// `meta.settings` (spec §1) — an app declaring native controls. This is the
// COMPATIBILITY SURFACE: the same rules run in the worker, on the host thread,
// and are mirrored in Swift, so every one of them is pinned here. The rule
// underneath the rules is an asymmetry — a LABEL is display and is cut to fit,
// a VALUE is data and is dropped when it is not what it claims to be, because a
// repaired value would make `settings.format === "aac"` false for a format the
// user picked.

/** The declared controls, or `[]` — a reading helper, so the pins below say
 * what they are about rather than re-stating `.settings ?? []` each time. */
const settingsOf = (raw: unknown) => sanitizeAppMeta(raw).settings ?? [];
const one = (setting: Record<string, unknown>) => settingsOf({ settings: [setting] });

describe("meta.settings (spec §1)", () => {
  test("all four control types survive a well-formed declaration verbatim", () => {
    expect(
      settingsOf({
        settings: [
          { key: "dial-size", label: "Stations on the dial", type: "number", min: 6, max: 36, step: 6, default: 24 },
          {
            key: "clicks",
            label: "Report listens to the directory",
            type: "toggle",
            default: true,
            hint: "Radio Browser counts a tune-in when this is on.",
          },
          { key: "format", label: "Recording format", type: "choice", options: ["aac", "wav"], default: "aac" },
          { key: "model", label: "Model", type: "text", default: "gpt-5.6-luna" },
        ],
      }),
    ).toEqual([
      { key: "dial-size", label: "Stations on the dial", type: "number", min: 6, max: 36, step: 6, default: 24 },
      {
        key: "clicks",
        label: "Report listens to the directory",
        type: "toggle",
        default: true,
        hint: "Radio Browser counts a tune-in when this is on.",
      },
      { key: "format", label: "Recording format", type: "choice", options: ["aac", "wav"], default: "aac" },
      { key: "model", label: "Model", type: "text", default: "gpt-5.6-luna" },
    ]);
  });

  test("an app that declares nothing usable carries no settings field at all", () => {
    // Absent, not empty: the Settings window draws a section for a row that has
    // one and nothing for a row that does not (spec §3).
    expect(sanitizeAppMeta({ name: "Radio" }).settings).toBeUndefined();
    expect(sanitizeAppMeta({ settings: [] }).settings).toBeUndefined();
    expect(sanitizeAppMeta({ settings: "loud" }).settings).toBeUndefined();
    expect(sanitizeAppMeta({ settings: { key: "x" } }).settings).toBeUndefined();
    expect(sanitizeAppMeta({ settings: [{ label: "Nameless", type: "toggle" }] }).settings).toBeUndefined();
  });

  test("the key is the identity, so an unreadable one drops the whole entry", () => {
    expect(one({ key: "a", label: "A", type: "toggle" })).toHaveLength(1);
    expect(one({ key: "dial-size-2", label: "A", type: "toggle" })).toHaveLength(1);
    expect(one({ key: "a".repeat(32), label: "A", type: "toggle" })).toHaveLength(1);
    for (const key of ["", "A", "1st", "-lead", "with space", "under_score", "a".repeat(33), 7, null]) {
      expect(one({ key, label: "A", type: "toggle" })).toEqual([]);
    }
  });

  test("a duplicate key loses to the one already on the surface", () => {
    // The first declaration wins, because a later one would silently decide
    // which of two controls the user is actually looking at.
    const settings = settingsOf({
      settings: [
        { key: "format", label: "Recording format", type: "choice", options: ["aac", "wav"] },
        { key: "format", label: "Something else", type: "toggle" },
      ],
    });
    expect(settings).toHaveLength(1);
    expect(settings[0]!.label).toBe("Recording format");
  });

  test("labels are trimmed and cut to fit; a label of nothing is not a control", () => {
    expect(one({ key: "a", label: "  Model  ", type: "text" })[0]!.label).toBe("Model");
    expect(one({ key: "a", label: "x".repeat(90), type: "text" })[0]!.label.length).toBe(48);
    expect(one({ key: "a", label: "   ", type: "text" })).toEqual([]);
    expect(one({ key: "a", label: 42, type: "text" })).toEqual([]);
  });

  test("hints are optional on every type, capped, and never invented", () => {
    expect(one({ key: "a", label: "A", type: "number", hint: "  why  " })[0]!.hint).toBe("why");
    expect(one({ key: "a", label: "A", type: "toggle", hint: "y".repeat(200) })[0]!.hint!.length).toBe(80);
    expect(one({ key: "a", label: "A", type: "toggle", hint: 7 })[0]!.hint).toBeUndefined();
  });

  test("the type vocabulary is closed", () => {
    for (const type of ["toggle", "text", "number"]) {
      expect(one({ key: "a", label: "A", type })).toHaveLength(1);
    }
    for (const type of ["slider", "TOGGLE", "", undefined, 3]) {
      expect(one({ key: "a", label: "A", type })).toEqual([]);
    }
  });

  test("a choice needs two real options, deduped, and each of them short", () => {
    expect(one({ key: "a", label: "A", type: "choice", options: ["aac", "wav"] })[0]!.options).toEqual([
      "aac",
      "wav",
    ]);
    // Deduped, and the junk between the survivors dropped rather than counted.
    expect(
      one({ key: "a", label: "A", type: "choice", options: ["aac", "aac", 7, "", "wav"] })[0]!.options,
    ).toEqual(["aac", "wav"]);
    expect(one({ key: "a", label: "A", type: "choice", options: Array.from({ length: 20 }, (_, i) => `o${i}`) })[0]!
      .options).toHaveLength(12);
    // An option is a VALUE, so an over-long one is dropped, never shortened —
    // a truncated option is a value the app will never match against.
    expect(
      one({ key: "a", label: "A", type: "choice", options: ["aac", "x".repeat(33)] }),
    ).toEqual([]);
    // Fewer than two is not a choice; the entry goes with it.
    expect(one({ key: "a", label: "A", type: "choice", options: ["aac"] })).toEqual([]);
    expect(one({ key: "a", label: "A", type: "choice" })).toEqual([]);
  });

  test("min/max/step belong to number alone, and an inverted range is no range", () => {
    expect(one({ key: "a", label: "A", type: "number", min: 6, max: 36, step: 6 })[0]).toMatchObject({
      min: 6,
      max: 36,
      step: 6,
    });
    // One end on its own is fine — "at least 1", with no ceiling.
    expect(one({ key: "a", label: "A", type: "number", min: 1 })[0]!.min).toBe(1);
    // Both ends, inverted: both go, and what is left is still a usable field.
    const inverted = one({ key: "a", label: "A", type: "number", min: 36, max: 6, step: 2 })[0]!;
    expect(inverted.min).toBeUndefined();
    expect(inverted.max).toBeUndefined();
    expect(inverted.step).toBe(2);
    // Not a position on a slider.
    const wild = one({ key: "a", label: "A", type: "number", min: NaN, max: Infinity, step: "6" })[0]!;
    expect(wild).toEqual({ key: "a", label: "A", type: "number" });
    // A toggle with a range is a toggle.
    expect(one({ key: "a", label: "A", type: "toggle", min: 1, max: 2, options: ["x", "y"] })[0]).toEqual({
      key: "a",
      label: "A",
      type: "toggle",
    });
  });

  test("a default that is not of its own type is dropped, not coerced", () => {
    expect(one({ key: "a", label: "A", type: "toggle", default: "yes" })[0]!.default).toBeUndefined();
    expect(one({ key: "a", label: "A", type: "text", default: 5 })[0]!.default).toBeUndefined();
    expect(one({ key: "a", label: "A", type: "number", default: "24" })[0]!.default).toBeUndefined();
    // For a choice, the options ARE the type.
    expect(
      one({ key: "a", label: "A", type: "choice", options: ["aac", "wav"], default: "flac" })[0]!.default,
    ).toBeUndefined();
    // A number's default is clamped into its own range rather than dropped —
    // the range is the slider, and its end is where the app was reaching.
    expect(one({ key: "a", label: "A", type: "number", min: 6, max: 36, default: 100 })[0]!.default).toBe(36);
  });

  test("a missing default means the type's own zero", () => {
    // Spec §1: toggle false, text "", choice options[0], number min ?? 0.
    expect(defaultSettingValue({ key: "a", label: "A", type: "toggle" })).toBe(false);
    expect(defaultSettingValue({ key: "a", label: "A", type: "text" })).toBe("");
    expect(defaultSettingValue({ key: "a", label: "A", type: "choice", options: ["aac", "wav"] })).toBe("aac");
    expect(defaultSettingValue({ key: "a", label: "A", type: "number", min: 6 })).toBe(6);
    expect(defaultSettingValue({ key: "a", label: "A", type: "number" })).toBe(0);
    // …and a declared one is simply itself.
    expect(defaultSettingValue({ key: "a", label: "A", type: "text", default: "luna" })).toBe("luna");
  });

  test("sixteen controls is the surface; a bad row costs only itself", () => {
    const many = Array.from({ length: 30 }, (_, i) => ({
      key: `k${i}`,
      label: `K${i}`,
      type: "toggle",
    }));
    expect(settingsOf({ settings: many })).toHaveLength(16);

    const withOneBad = [
      ...Array.from({ length: 8 }, (_, i) => ({ key: `a${i}`, label: `A${i}`, type: "toggle" })),
      { key: "OOPS", label: "Bad", type: "toggle" },
      ...Array.from({ length: 7 }, (_, i) => ({ key: `b${i}`, label: `B${i}`, type: "text" })),
    ];
    expect(settingsOf({ settings: withOneBad })).toHaveLength(15);
  });

  test("nothing in a declaration can throw — that is the point of sanitizing", () => {
    for (const entry of [null, undefined, "toggle", 7, [], () => {}]) {
      expect(() => settingsOf({ settings: [entry] })).not.toThrow();
      expect(settingsOf({ settings: [entry] })).toEqual([]);
    }
  });
});

describe("coerceSettingValue — one reading of a value, for every side (spec §4)", () => {
  const spec = (extra: Record<string, unknown>) => one({ key: "a", label: "A", ...extra })[0]!;

  test("each type accepts only itself", () => {
    expect(coerceSettingValue(spec({ type: "toggle" }), false)).toBe(false);
    expect(coerceSettingValue(spec({ type: "toggle" }), "false")).toBeUndefined();
    expect(coerceSettingValue(spec({ type: "text" }), "luna")).toBe("luna");
    expect(coerceSettingValue(spec({ type: "text" }), 5)).toBeUndefined();
    expect(coerceSettingValue(spec({ type: "number" }), 12)).toBe(12);
    expect(coerceSettingValue(spec({ type: "number" }), NaN)).toBeUndefined();
    const choice = spec({ type: "choice", options: ["aac", "wav"] });
    expect(coerceSettingValue(choice, "wav")).toBe("wav");
    expect(coerceSettingValue(choice, "flac")).toBeUndefined();
  });

  test("a number out of range is clamped, never refused", () => {
    // A control the user dragged to the end is a control at its end; refusing
    // it would leave the slider showing a value the host does not hold.
    const bounded = spec({ type: "number", min: 6, max: 36 });
    expect(coerceSettingValue(bounded, 100)).toBe(36);
    expect(coerceSettingValue(bounded, 0)).toBe(6);
    expect(coerceSettingValue(bounded, 12)).toBe(12);
  });

  test("a runaway text value is cut rather than shipped whole", () => {
    // The value rides the catalog to the shell on every snapshot; MAX_NAME's
    // reasoning applies to it verbatim.
    expect(coerceSettingValue(spec({ type: "text" }), "x".repeat(500))).toHaveLength(200);
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
