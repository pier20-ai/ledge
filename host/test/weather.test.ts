import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Weather's maths (protocol/demo-apps/weather): the sun, the forecast, the
// words, and the pane.
//
// The app itself cannot be tested by looking at it — the snapshot harness
// replays an app's *mount tree* and the one canvas it puts in its wing, and
// never a canvas in the panel, so Weather's entire signature is invisible to
// `snapshot-demos.sh`. What *is* checkable is everything the picture is a
// function of, and the two properties the design depends on:
//
//   * `paneOps` is **pure** — the live clock and the scrubber call the same
//     renderer, so the frame at +6 h must be the same frame however you got
//     there;
//   * Reduce Motion is a **still**, not a slower loop — the frame must stop
//     changing between ticks while the data underneath keeps moving.
//
// The Open-Meteo fixture is a real recorded response, and it carries its own
// oracle: the `daily.sunrise`/`sunset` the API computed for the same place and
// day, which `solar.js` has to reproduce from first principles.

const APP = join(import.meta.dir, "..", "..", "protocol", "demo-apps", "weather");

const { parseForecast, weatherAt, conditionLine, summaryLine, snowDepthAt, kindOf } =
  await import(join(APP, "forecast.js"));
const { solarPosition, sunOnPane } = await import(join(APP, "solar.js"));
const { paneOps } = await import(join(APP, "pane.js"));
const { rulerOps } = await import(join(APP, "ruler.js"));

const RAW = JSON.parse(readFileSync(join(APP, "fixture", "open-meteo.json"), "utf8"));
const FORECAST = parseForecast(RAW, "celsius");
const HOUR = 3_600_000;

/** Epoch ms for one of the fixture's naive-local timestamps. */
const localMs = (iso: string) => Date.parse(`${iso}:00Z`) - FORECAST.offset;

// ---------------------------------------------------------------- the data

describe("forecast parsing", () => {
  test("the recorded response becomes rows, in real epoch time", () => {
    expect(FORECAST.hours).toHaveLength(RAW.hourly.time.length);
    expect(FORECAST.offset).toBe(RAW.utc_offset_seconds * 1000);
    // The times are naive local with the offset carried separately; parsing
    // them with `Date.parse` alone would use *this machine's* zone.
    expect(FORECAST.hours[0].t).toBe(localMs(RAW.hourly.time[0]));
    expect(FORECAST.hours[1].t - FORECAST.hours[0].t).toBe(HOUR);
    expect(FORECAST.hours[0].temp).toBe(RAW.hourly.temperature_2m[0]);
    expect(FORECAST.hours[0].cloud).toBe(RAW.hourly.cloud_cover[0]);
  });

  test("a response with no hourly block is a throw, not an empty sky", () => {
    expect(() => parseForecast({ hourly: {} })).toThrow(/hourly/);
  });

  test("WMO codes collapse to the five things the pane can draw", () => {
    expect(kindOf(0)).toBe("sky");
    expect(kindOf(3)).toBe("sky");
    expect(kindOf(45)).toBe("fog");
    expect(kindOf(65)).toBe("rain");
    expect(kindOf(80)).toBe("rain");
    expect(kindOf(73)).toBe("snow");
    expect(kindOf(86)).toBe("snow");
    expect(kindOf(99)).toBe("storm");
  });
});

describe("weatherAt", () => {
  const a = FORECAST.hours[10];
  const b = FORECAST.hours[11];

  test("is continuous between samples — the scrubber is not a slideshow", () => {
    const mid = weatherAt(FORECAST, a.t + HOUR / 2);
    expect(mid.temp).toBeCloseTo((a.temp + b.temp) / 2, 6);
    const quarter = weatherAt(FORECAST, a.t + HOUR / 4);
    expect(quarter.temp).toBeCloseTo(a.temp + (b.temp - a.temp) * 0.25, 6);
  });

  test("wind direction turns the short way round", () => {
    const spun = {
      ...FORECAST,
      hours: [
        { ...a, t: 0, dir: 350 },
        { ...b, t: HOUR, dir: 10 },
      ],
    };
    // 350 → 10 is twenty degrees of veer, not three hundred and forty.
    expect(weatherAt(spun, HOUR / 2).dir).toBeCloseTo(0, 6);
  });

  test("clamps outside the window instead of running off the end", () => {
    const last = FORECAST.hours[FORECAST.hours.length - 1];
    expect(weatherAt(FORECAST, last.t + 10 * HOUR).temp).toBe(last.temp);
    expect(weatherAt(FORECAST, FORECAST.hours[0].t - 10 * HOUR).temp).toBe(
      FORECAST.hours[0].temp,
    );
  });

  test("the snow rim is continuous in t", () => {
    const t = FORECAST.hours[24].t;
    const step = 60_000;
    for (let i = -3; i <= 3; i += 1) {
      const d = Math.abs(snowDepthAt(FORECAST, t + i * step) - snowDepthAt(FORECAST, t));
      expect(d).toBeLessThan(0.05);
    }
  });
});

// ---------------------------------------------------------------- the sun

describe("solar position", () => {
  test("reproduces the fixture's own sunrise and sunset", () => {
    // The API computed these for the same place and day; solar.js has to land
    // on them from first principles. Sunrise is defined at −0.833° (refraction
    // plus the sun's own radius), and one minute of scan resolution is the
    // most this can be asked for.
    const day = localMs(`${RAW.daily.time[0]}T00:00`);
    const crossings: number[] = [];
    let previous = solarPosition(day, FORECAST.lat, FORECAST.lon).elevation;
    for (let t = day + 60_000; t <= day + 24 * HOUR; t += 60_000) {
      const elevation = solarPosition(t, FORECAST.lat, FORECAST.lon).elevation;
      if (previous < -0.833 !== elevation < -0.833) crossings.push(t);
      previous = elevation;
    }
    const [rise, set] = crossings;
    expect(crossings).toHaveLength(2);
    expect(Math.abs(rise! - localMs(RAW.daily.sunrise[0]))).toBeLessThan(2 * 60_000);
    expect(Math.abs(set! - localMs(RAW.daily.sunset[0]))).toBeLessThan(2 * 60_000);
  });

  /** True solar noon at a longitude: local apparent noon, not clock noon. */
  const solarNoon = (lon: number) =>
    Date.parse(`${RAW.daily.time[0]}T12:00:00Z`) - (lon / 15) * HOUR;

  test("the arc crosses the pane once a day, in both hemispheres", () => {
    const noon = solarNoon(FORECAST.lon);
    const north = sunOnPane(noon, 52.5, FORECAST.lon);
    expect(north.across).toBeCloseTo(0.5, 1);
    expect(north.up).toBeGreaterThan(0.3);
    // Morning is one edge, evening the other — and the other way round south of
    // the equator, where the sun tracks across a poleward window in reverse.
    expect(sunOnPane(noon - 5 * HOUR, 52.5, FORECAST.lon).across).toBeLessThan(0.25);
    expect(sunOnPane(noon + 5 * HOUR, 52.5, FORECAST.lon).across).toBeGreaterThan(0.75);
    expect(sunOnPane(noon - 5 * HOUR, -33.9, FORECAST.lon).across).toBeGreaterThan(0.75);
  });

  test("a tropical summer noon stays on the pane", () => {
    // Bengaluru in August: the sun passes within a degree of the zenith, where
    // azimuth is numerically meaningless and the naive "a northern window faces
    // south" rule throws the light off the side of the pane. The hour angle is
    // well conditioned there, which is the whole reason `across` is built on it.
    const noon = solarNoon(FORECAST.lon);
    const sun = sunOnPane(noon, FORECAST.lat, FORECAST.lon);
    expect(sun.elevation).toBeGreaterThan(88);
    expect(sun.across).toBeGreaterThan(0.45);
    expect(sun.across).toBeLessThan(0.55);
  });
});

// ---------------------------------------------------------------- the words

describe("the one line", () => {
  const at = (over: Record<string, unknown>) => {
    const hours = Array.from({ length: 24 }, (_, i) => ({
      t: i * HOUR,
      temp: 12,
      precip: 0,
      snow: 0,
      cloud: 10,
      wind: 8,
      dir: 200,
      code: 0,
      rh: 60,
      ...(typeof over[i] === "object" ? (over[i] as object) : {}),
    }));
    return { lat: 52.5, lon: 13.4, offset: 0, unit: "celsius", hours };
  };

  test("is one sentence, sentence case, and never ends in a full stop", () => {
    for (const t of [0, 3 * HOUR, 9 * HOUR]) {
      const line = conditionLine(at({}), t);
      expect(line).toMatch(/^[A-Z]/);
      expect(line).not.toMatch(/[.!]$/);
      expect(line.split(" ").length).toBeLessThanOrEqual(6);
    }
  });

  test("raining now says how long, not that it is raining", () => {
    // Wet now, dry by the next sample: the curve crosses back inside the hour.
    const wet = at({ 0: { precip: 1.4, code: 63 } });
    expect(conditionLine(wet, 0)).toBe("Rain for the next hour");
    // …and a longer band names the hour it lets up instead.
    const long = at(Object.fromEntries([0, 1, 2, 3].map((i) => [i, { precip: 1.4, code: 63 }])));
    expect(conditionLine(long, 0)).toBe("Rain until 4");
  });

  test("dry now names when it starts, to the minute inside the hour", () => {
    const soon = at({ 0: { precip: 0 }, 1: { precip: 1.2, code: 63 } });
    expect(conditionLine(soon, 0)).toMatch(/^Rain in \d+ minutes$/);
    expect(conditionLine(soon, 0)).not.toBe("Rain in 60 minutes");
  });

  test("nothing coming describes the sky", () => {
    expect(conditionLine(at({}), 0)).toMatch(/^Clear /);
    const grey = Object.fromEntries(
      Array.from({ length: 24 }, (_, i) => [i, { cloud: 100, code: 3 }]),
    );
    expect(conditionLine(at(grey), 0)).toMatch(/^Overcast /);
  });

  test("the summary is temp and the next hour, and shorter than the panel's", () => {
    const soon = at({ 0: { precip: 0, temp: 18 }, 1: { precip: 1.2, code: 63 } });
    const glance = summaryLine(soon, 0);
    expect(glance).toMatch(/^18° · rain in \d+m$/);
    expect(glance.length).toBeLessThan(conditionLine(soon, 0).length + 6);
  });
});

// ---------------------------------------------------------------- the pane

const PANE = { w: 412, h: 188 };
const PLACE = { lat: 52.5, lon: 13.4 };
const RAIN = {
  temp: 15,
  precip: 4.2,
  snow: 0,
  cloud: 96,
  wind: 34,
  dir: 250,
  rh: 95,
  code: 65,
  kind: "rain",
};
const SNOW = { ...RAIN, temp: -3, precip: 0.6, snow: 0.9, code: 73, kind: "snow" };
const CLEAR = { ...RAIN, temp: 22, precip: 0, cloud: 8, wind: 9, rh: 50, code: 0, kind: "sky" };
const STORM = { ...RAIN, precip: 6.5, code: 95, kind: "storm" };

const frame = (t: number, weather: object, extra: object = {}) =>
  paneOps({ ...PANE, t, weather, place: PLACE, ...extra });

describe("the pane", () => {
  const t = Date.parse("2026-08-15T13:10:00Z");

  test("is a pure function of (t, weather(t))", () => {
    // The scrubber's whole contract: arriving at an instant by dragging must
    // produce the identical picture as arriving at it by waiting.
    expect(frame(t, RAIN)).toEqual(frame(t, RAIN));
    expect(frame(t + 6 * HOUR, RAIN)).toEqual(frame(t + 6 * HOUR, RAIN));
    expect(frame(t, RAIN)).not.toEqual(frame(t + 900, RAIN));
  });

  test("stays inside the op budget in the worst case", () => {
    for (const weather of [CLEAR, RAIN, SNOW, STORM]) {
      const ops = frame(t, weather, { snowDepth: 2.4 });
      expect(ops.length).toBeLessThan(400);
      expect(ops[0]).toEqual({ op: "clear" });
    }
  });

  test("emits only real ops, and only hex colours", () => {
    const KINDS = new Set(["clear", "rect", "line", "gradient", "text", "image"]);
    const HEX = /^#[0-9a-fA-F]{3,8}$/;
    for (const weather of [CLEAR, RAIN, SNOW, STORM]) {
      for (const op of frame(t, weather, { snowDepth: 2.4 }) as Record<string, unknown>[]) {
        expect(KINDS.has(op.op as string)).toBe(true);
        for (const key of ["fill", "stroke", "from", "to"]) {
          if (op[key] !== undefined) expect(op[key] as string).toMatch(HEX);
        }
        // Quantised to the half point: the backing store is 2×, and anything
        // finer is a blur the app pays for and cannot see.
        for (const key of ["x", "y", "w", "h"]) {
          const v = op[key];
          if (typeof v === "number") expect(Math.abs(v * 2 - Math.round(v * 2))).toBeLessThan(1e-9);
        }
      }
    }
  });

  test("the sun moves the light across the glass over a day", () => {
    const morning = frame(Date.parse("2026-08-15T06:00:00Z"), CLEAR);
    const evening = frame(Date.parse("2026-08-15T17:00:00Z"), CLEAR);
    const disc = (ops: Record<string, number>[]) =>
      ops.filter((op) => op.radius && op.w === op.h).reduce((a, op) => Math.min(a, op.x ?? 1e9), 1e9);
    expect(disc(morning as never)).toBeLessThan(disc(evening as never));
  });

  test("Reduce Motion is a still, and the scrub still moves it", () => {
    const still = (at: number) => frame(at, RAIN, { reduceMotion: true });
    // Nothing changes between ticks…
    expect(still(t)).toEqual(still(t + 3000));
    // …the flash never fires…
    const flash = (ops: Record<string, unknown>[]) =>
      ops.some((op) => op.op === "rect" && op.x === 0 && op.y === 0 && op.w === PANE.w);
    for (let i = 0; i < 40; i += 1) {
      expect(flash(frame(t + i * 1000, STORM, { reduceMotion: true }) as never)).toBe(false);
    }
    // …but scrubbing to another hour is a different picture, because scrubbing
    // is the user moving something, not the app.
    expect(still(t)).not.toEqual(still(t + 2 * HOUR));
  });

  test("no rain, no droplets; no snow, no rim", () => {
    expect(frame(t, CLEAR).length).toBeLessThan(frame(t, RAIN).length / 2);
    const dry = frame(t, CLEAR, { snowDepth: 0 });
    const banked = frame(t, SNOW, { snowDepth: 3 });
    expect(banked.length).toBeGreaterThan(dry.length);
  });
});

// ---------------------------------------------------------------- legibility
//
// The first version of the pane passed every test above and was still wrong: on
// device, overcast was "a fuzzy gray blob — can't make anything out". The tests
// were about *correctness* — purity, budget, op kinds — and the defect was about
// **structure and value**, which nothing asserted, so it survived a rewrite and
// shipped.
//
// These are the properties that failure had. They are deliberately crude: they
// cannot tell a good sky from a bad one, but they can tell a picture that has
// something in it from a wash, and that is the whole of what went wrong.

/** Rec. 601 luma of a `#RRGGBB[AA]` fill, ignoring alpha. */
function luma(hex: string): number {
  const n = Number.parseInt(hex.slice(1, 7), 16);
  return 0.3 * ((n >> 16) & 255) + 0.59 * ((n >> 8) & 255) + 0.11 * (n & 255);
}

/** The values the scene is actually *built* out of: the fill of every op that
 * covers real area and is opaque enough to be seen through nothing. */
function structuralValues(ops: Record<string, unknown>[]): number[] {
  const values: number[] = [];
  for (const op of ops) {
    const fill = (op.fill ?? op.to) as string | undefined;
    if (typeof fill !== "string") continue;
    if (fill.length > 7 && Number.parseInt(fill.slice(7, 9), 16) < 0xd0) continue;
    const w = Number(op.w ?? 0);
    const h = Number(op.h ?? 0);
    if (w * h < 400) continue;
    values.push(luma(fill));
  }
  return values.sort((a, b) => a - b);
}

/** How many values in the list are at least `gap` apart from one another —
 * "three distinguishable greys" made countable. */
function separable(values: number[], gap: number): number {
  let count = 0;
  let last = -Infinity;
  for (const value of values) {
    if (value - last < gap) continue;
    count += 1;
    last = value;
  }
  return count;
}

describe("legible at 1×", () => {
  const t = Date.parse("2026-08-15T13:10:00Z");
  const OVERCAST = { ...CLEAR, temp: 15, cloud: 100, code: 3, rh: 72, wind: 16 };
  const DRIZZLE = { ...RAIN, temp: 12, precip: 0.35, cloud: 95, code: 51, wind: 12 };
  const FOG = { ...CLEAR, temp: 6, cloud: 90, rh: 99, wind: 4, code: 45, kind: "fog" };
  const NIGHT = { ...CLEAR, temp: 12, cloud: 10 };
  const midnight = Date.parse("2026-08-15T01:10:00Z");

  const scenes: Array<[string, number, object]> = [
    ["clear", t, CLEAR],
    ["overcast", t, OVERCAST],
    ["drizzle", t, DRIZZLE],
    ["rain", t, RAIN],
    ["storm", t, STORM],
    ["fog", t, FOG],
    ["snow", t, SNOW],
    ["night", midnight, NIGHT],
    ["night overcast", midnight, OVERCAST],
  ];

  test("every condition is built from at least three separable values", () => {
    for (const [name, at, weather] of scenes) {
      const values = structuralValues(frame(at, weather, { snowDepth: 2 }) as never);
      expect(`${name}: ${separable(values, 14)}`).toBe(
        `${name}: ${Math.max(3, separable(values, 14))}`,
      );
    }
  });

  test("every condition has a horizon under it", () => {
    // The silhouette band: wide, short, dark, and sitting in the bottom fifth.
    // It is what gives the pane depth and scale, and it is the reason rain has
    // something to streak against — see `buildSkyline`.
    for (const [name, at, weather] of scenes) {
      const ops = frame(at, weather) as Record<string, number | string>[];
      const ground = ops.filter(
        (op) =>
          op.op === "rect" &&
          typeof op.fill === "string" &&
          luma(op.fill) < 60 &&
          Number(op.y) > PANE.h * 0.78 &&
          Number(op.w) > 8,
      );
      expect(`${name}: ${ground.length >= 4}`).toBe(`${name}: true`);
    }
  });

  test("a shut sky is layered, not one grey", () => {
    // Three depth layers with distinct values (`LAYERS`), which is the whole
    // difference between "overcast" and "the app failed to draw anything".
    const values = structuralValues(frame(t, OVERCAST) as never);
    expect(separable(values, 18)).toBeGreaterThanOrEqual(3);
    // …and the range is a real range, not two neighbouring greys.
    expect(values[values.length - 1]! - values[0]!).toBeGreaterThan(90);
  });
});

// ---------------------------------------------------------------- the ruler

describe("the ruler", () => {
  const now = Date.parse("2026-08-15T13:10:00Z");
  const strip = (offset: number) =>
    rulerOps({ w: 412, h: 38, span: 24, offset, now, tz: 2 * HOUR }) as Record<string, string>[];

  test("at rest there is no accent anywhere — the hue has a job or it is absent", () => {
    for (const op of strip(0)) {
      for (const key of ["fill", "from", "to", "color"]) {
        if (op[key]) expect(op[key].toUpperCase()).not.toContain("FFB454");
      }
    }
    expect(strip(0).some((op) => op.content?.startsWith("+"))).toBe(false);
  });

  test("scrubbed, the travelled region is amber and the offset is named once", () => {
    const scrubbed = strip(6 * HOUR);
    expect(scrubbed.some((op) => op.from?.toUpperCase().includes("FFB454"))).toBe(true);
    const labels = scrubbed.filter((op) => op.content?.startsWith("+"));
    expect(labels).toHaveLength(1);
    expect(labels[0]!.content).toBe("+6h");
  });

  test("under an hour it counts in minutes", () => {
    expect(strip(25 * 60_000).filter((op) => op.content?.startsWith("+"))[0]!.content).toBe("+25m");
  });
});
