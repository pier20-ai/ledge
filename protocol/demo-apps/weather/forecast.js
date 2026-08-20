// The data half: where you are, what the sky is going to do, and the one line
// the panel is allowed to say about it.
//
// Two keyless endpoints, both cached next to `app.jsx` so a cold launch draws a
// real sky before the network answers and an offline launch draws the last one:
//
//   ip-api.com      latitude / longitude / country, once (it barely changes)
//   open-meteo.com  48 hours of hourly weather, re-asked every ~15 minutes
//
// Everything the pane draws comes out of `weatherAt(t)`, which interpolates
// between hourly samples — the scene has to be a *continuous* function of t or
// the scrubber would step through the day in one-hour jerks.

import { readFileSync, renameSync, writeFileSync } from "node:fs";

const OPEN_METEO = "https://api.open-meteo.com/v1/forecast";
const IP_API = "http://ip-api.com/json/?fields=status,lat,lon,countryCode";
const HOURLY = [
  "temperature_2m",
  "precipitation",
  "snowfall",
  "cloud_cover",
  "wind_speed_10m",
  "wind_direction_10m",
  "weather_code",
  "relative_humidity_2m",
].join(",");

/** The last countries on earth that still read the weather in Fahrenheit. A
 * sky app that tells a Floridian it is 31° is broken, not international. */
const FAHRENHEIT = new Set(["US", "BS", "BZ", "KY", "LR", "PW", "FM", "MH"]);

/** Below this an hour is dry: Open-Meteo reports a stray 0.01 mm for humidity
 * condensing on a leaf, and that is not rain. */
export const WET_MM = 0.05;

const HOUR = 3_600_000;

// ---------------------------------------------------------------- the network

/** Where the machine is, by IP. Coarse — city-scale — which is all a sky needs. */
export async function fetchPlace() {
  const response = await fetch(IP_API, { signal: AbortSignal.timeout(8000) });
  const json = await response.json();
  if (json?.status !== "success") throw new Error("ip-api: no fix");
  return {
    lat: Number(json.lat),
    lon: Number(json.lon),
    unit: FAHRENHEIT.has(json.countryCode) ? "fahrenheit" : "celsius",
  };
}

/** 48 hours of hourly weather for one place, parsed. */
export async function fetchForecast(place) {
  const url =
    `${OPEN_METEO}?latitude=${place.lat.toFixed(4)}&longitude=${place.lon.toFixed(4)}` +
    `&hourly=${HOURLY}&forecast_days=3&timezone=auto&temperature_unit=${place.unit}`;
  const response = await fetch(url, { signal: AbortSignal.timeout(12_000) });
  if (!response.ok) throw new Error(`open-meteo: ${response.status}`);
  return parseForecast(await response.json(), place.unit);
}

/**
 * Open-Meteo's column-per-variable JSON, turned into the row-per-hour shape the
 * rest of the app reads.
 *
 * The times are **naive local** strings with the offset carried separately, so
 * they are parsed as UTC and shifted — `Date.parse` on a bare `2026-08-15T04:00`
 * uses *this machine's* zone, which is the wrong one whenever the user is
 * travelling or the host is not where the IP says.
 */
export function parseForecast(json, unit = "celsius") {
  const hourly = json?.hourly;
  if (!hourly?.time?.length) throw new Error("open-meteo: no hourly block");
  const offset = Number(json.utc_offset_seconds ?? 0) * 1000;
  const hours = hourly.time.map((iso, i) => ({
    t: Date.parse(`${iso}:00Z`) - offset,
    temp: hourly.temperature_2m[i],
    precip: hourly.precipitation[i] ?? 0,
    snow: hourly.snowfall[i] ?? 0,
    cloud: hourly.cloud_cover[i] ?? 0,
    wind: hourly.wind_speed_10m[i] ?? 0,
    dir: hourly.wind_direction_10m[i] ?? 0,
    code: hourly.weather_code[i] ?? 0,
    rh: hourly.relative_humidity_2m[i] ?? 60,
  }));
  return {
    lat: Number(json.latitude),
    lon: Number(json.longitude),
    offset,
    unit,
    hours,
  };
}

// ---------------------------------------------------------------- the cache

/** Last-known sky, on disk. Data, not source — the watcher ignores JSON, so
 * writing it does not reload the app (REFERENCE.md, "Persistence"). */
export function readCache(dir) {
  try {
    const cache = JSON.parse(readFileSync(`${dir}/cache.json`, "utf8"));
    return cache?.forecast?.hours?.length ? cache : null;
  } catch {
    return null; // no cache is the empty state, not an error
  }
}

export function writeCache(dir, cache) {
  // Temp-then-rename: a half-written cache read at next boot is a crash loop.
  const tmp = `${dir}/cache.json.tmp`;
  writeFileSync(tmp, JSON.stringify(cache));
  renameSync(tmp, `${dir}/cache.json`);
}

// ---------------------------------------------------------------- reading it

/** WMO code → the five things the pane knows how to draw. */
export function kindOf(code) {
  if (code >= 95) return "storm";
  if (code >= 85 || (code >= 71 && code <= 77) || code === 56 || code === 57) return "snow";
  if (code >= 80 || (code >= 51 && code <= 67)) return "rain";
  if (code === 45 || code === 48) return "fog";
  return "sky";
}

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const lerp = (a, b, k) => a + (b - a) * k;

/**
 * The weather at any instant, interpolated. Continuous in `t` for everything
 * that has to be — a temperature that stepped once an hour would make the
 * scrubber feel like a slideshow — and nearest-neighbour for the code, which is
 * a label and does not average.
 */
export function weatherAt(forecast, t) {
  const { hours } = forecast;
  const span = (t - hours[0].t) / HOUR;
  const i = Math.max(0, Math.min(hours.length - 1, Math.floor(span)));
  const j = Math.min(hours.length - 1, i + 1);
  const k = clamp01(span - i);
  const a = hours[i];
  const b = hours[j];
  // Wind direction is a compass bearing: interpolating 350° → 10° the short way
  // round is the difference between a breeze veering and one spinning 340°.
  const turn = ((b.dir - a.dir + 540) % 360) - 180;
  return {
    temp: lerp(a.temp, b.temp, k),
    precip: lerp(a.precip, b.precip, k),
    snow: lerp(a.snow, b.snow, k),
    cloud: lerp(a.cloud, b.cloud, k),
    wind: lerp(a.wind, b.wind, k),
    dir: (a.dir + turn * k + 360) % 360,
    rh: lerp(a.rh, b.rh, k),
    code: k < 0.5 ? a.code : b.code,
    kind: kindOf(k < 0.5 ? a.code : b.code),
  };
}

/** Snow that has fallen in the six hours before `t`, in cm — what the rim along
 * the sill is made of. */
export function snowDepthAt(forecast, t) {
  let total = 0;
  for (const hour of forecast.hours) {
    const age = (t - hour.t) / HOUR;
    if (age < 0 || age > 6) continue;
    // Continuous at both ends: the newest hour is still falling, the oldest
    // fades out of the window rather than dropping off it — a rim that jumped a
    // point every hour would flicker under the scrubber.
    total += hour.snow * clamp01(age) * clamp01((6 - age) / 2);
  }
  return total;
}

// ---------------------------------------------------------------- the words

const localHour = (forecast, t) => new Date(t + forecast.offset).getUTCHours();

/** A bare clock hour, 12-hour and unsuffixed: "4". Words are the scarcest
 * resource, and nobody reads "Rain until 4" as four in the morning. */
const clock = (forecast, t) => String(localHour(forecast, t) % 12 || 12);

function partOfDay(forecast, t) {
  const h = localHour(forecast, t);
  if (h < 5) return "night";
  if (h < 12) return "morning";
  if (h < 17) return "afternoon";
  if (h < 21) return "evening";
  return "night";
}

const NOUN = { rain: "Rain", snow: "Snow", storm: "Thunder", fog: "Fog", sky: "Rain" };

/** When the wet/dry state next flips, by interpolation rather than by hour, so
 * "in 40 minutes" is an estimate off the curve and not a rounded-up hour. */
function crossing(forecast, t, wanted, limitHours = 12) {
  const step = 5 * 60_000;
  const last = t + limitHours * HOUR;
  for (let probe = t; probe <= last; probe += step) {
    if (weatherAt(forecast, probe).precip >= WET_MM === Boolean(wanted)) return probe;
  }
  return null;
}

/**
 * The one line the panel is allowed (principle 4: a sentence is a design failure
 * everywhere except an empty state — this is the ONE permitted line, and it is
 * data, not prose). Sentence case, no label, never a period.
 */
export function conditionLine(forecast, t) {
  const now = weatherAt(forecast, t);
  const noun = NOUN[now.kind === "sky" ? "rain" : now.kind];

  if (now.precip >= WET_MM || now.kind === "storm") {
    const ends = crossing(forecast, t, false);
    if (!ends) return `${noun} all ${partOfDay(forecast, t)}`;
    const gap = ends - t;
    if (gap < 75 * 60_000) return `${noun} for the next hour`;
    if (partOfDay(forecast, ends) !== partOfDay(forecast, t)) {
      return `${noun} all ${partOfDay(forecast, t)}`;
    }
    return `${noun} until ${clock(forecast, ends)}`;
  }

  const starts = crossing(forecast, t, true);
  if (starts) {
    const gap = starts - t;
    const soon = weatherAt(forecast, starts);
    const word = NOUN[soon.kind === "sky" ? "rain" : soon.kind];
    if (gap < 75 * 60_000) {
      const minutes = Math.max(5, Math.round(gap / 300_000) * 5);
      return `${word} in ${minutes} minutes`;
    }
    return `${word} from ${clock(forecast, starts)}`;
  }

  if (now.kind === "fog") return `Fog ${throughPhrase(forecast, t)}`;
  const sky =
    now.cloud < 25 ? "Clear" : now.cloud < 55 ? "Mostly clear" : now.cloud < 85 ? "Cloudy" : "Overcast";
  return `${sky} ${throughPhrase(forecast, t)}`;
}

function throughPhrase(forecast, t) {
  const part = partOfDay(forecast, t);
  return part === "night" ? "until morning" : `through the ${part}`;
}

/** The hover's line (flow.md: "temp and the next hour"). The same facts as the
 * panel, compressed to a glance: `18° · rain in 40m`. Shorter than the panel's
 * line on purpose — a swell is read in passing, not studied. */
export function summaryLine(forecast, t) {
  const now = weatherAt(forecast, t);
  const temp = `${Math.round(now.temp)}°`;
  const wet = now.precip >= WET_MM || now.kind === "storm";
  const noun = (kind) => (NOUN[kind === "sky" ? "rain" : kind] ?? "Rain").toLowerCase();

  if (wet) return `${temp} · ${noun(now.kind)} now`;
  const starts = crossing(forecast, t, true);
  if (starts) {
    const word = noun(weatherAt(forecast, starts).kind);
    const gap = starts - t;
    return gap < 75 * 60_000
      ? `${temp} · ${word} in ${Math.max(5, Math.round(gap / 300_000) * 5)}m`
      : `${temp} · ${word} from ${clock(forecast, starts)}`;
  }
  if (now.kind === "fog") return `${temp} · fog`;
  return `${temp} · ${now.cloud < 25 ? "clear" : now.cloud < 55 ? "mostly clear" : now.cloud < 85 ? "cloudy" : "overcast"}`;
}
