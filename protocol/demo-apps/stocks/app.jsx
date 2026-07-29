/** @jsxImportSource react */
// Stocks — a 2×3 grid of live cards (docs/design/app-ideas.md, wave 1). Six
// symbols, each a raised card with a coloured %-change pill, a sparkline, and
// the price; the monitor refreshes all six once a minute from Yahoo Finance's
// keyless chart endpoint.
//
// This is NOT installed in the user's real ~/.ledge/apps; it lives in the repo so
// the host can be pointed at --apps-root protocol/demo-apps. It renders the whole
// panel above the app strip, header row included: the shell draws the notch shape
// and the strip, the app draws its content (see shell/README.md).
//
// Like the fixtures, it imports nothing from Ledge: JSX is transpiled by Bun's
// automatic runtime (the pragma on line 1 pins React regardless of the surrounding
// tsconfig), and ctx arrives as the monitor's argument. React resolves from a
// shared node_modules at the apps root — the analogue of ~/.ledge/node_modules
// (spec §6).
//
// **The monitor never throws.** A throw is an app crash with backoff (spec §6
// rule 2), so a flaky network would take the whole app down rather than show a
// stale number. Every failure path here ends in cached-or-placeholder cards and
// an "offline"/"partial" marker in the header instead.

import { rename } from "node:fs/promises";

export const meta = { name: "Stocks", icon: "sf:chart.line.uptrend.xyaxis" };

// ---------------------------------------------------------------- the watchlist

const SYMBOLS = [
  { symbol: "ENPH", label: "ENPH" },
  { symbol: "NVDA", label: "NVDA" },
  { symbol: "GOOG", label: "GOOG" },
  { symbol: "MSFT", label: "MSFT" },
  // Crypto rides the same endpoint — the pair symbol is all that differs.
  { symbol: "BTC-USD", label: "BTC" },
  { symbol: "ETH-USD", label: "ETH" },
];

const REFRESH_MS = 60_000;
const REQUEST_TIMEOUT_MS = 8_000;
const SPARK_POINTS = 24;

// query1/query2 are the same service behind two names; when one edge rate-limits
// (HTTP 429 is Yahoo's habitual answer to an unfamiliar client) the other often
// still answers, so a single flaky POP isn't an outage.
const HOSTS = ["https://query1.finance.yahoo.com", "https://query2.finance.yahoo.com"];

// Yahoo serves a challenge page to obviously-scripted clients; a browser-ish
// agent is the difference between JSON and HTML.
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// Last good prices, so a restart shows real numbers rather than dashes. App-owned
// persistence in the app's own folder (spec §6); the watcher only reloads on
// app.jsx, so writing here never restarts us.
const CACHE_PATH = `${import.meta.dir}/prices.json`;

// ---------------------------------------------------------------- fetch + parse

/** Evenly downsample a series to at most `count` points and round them: the
 * sparkline is ~100 pt wide, so 78 five-minute closes is more resolution than
 * pixels, and `324.67999267578125` is 18 bytes of wire for a value the shell
 * normalizes to a y-coordinate anyway. */
function sample(values, count) {
  const round = (value) => Math.round(value * 100) / 100;
  if (values.length <= count) return values.map(round);
  const step = (values.length - 1) / (count - 1);
  return Array.from({ length: count }, (_, i) => round(values[Math.round(i * step)]));
}

/** Pull price / previous close / sparkline out of one chart response. Throws on
 * anything unexpected — the caller isolates it per symbol. */
function parseChart(body) {
  const result = body?.chart?.result?.[0];
  if (!result) throw new Error(body?.chart?.error?.description ?? "no result in payload");

  const info = result.meta ?? {};
  // `close` is a sparse array: Yahoo emits a null for every interval with no
  // trade, and a null in the middle of a sparkline is a hole, not a zero.
  const closes = (result.indicators?.quote?.[0]?.close ?? []).filter(
    (value) => typeof value === "number" && Number.isFinite(value),
  );

  const price =
    typeof info.regularMarketPrice === "number" ? info.regularMarketPrice : closes.at(-1);
  if (typeof price !== "number" || !Number.isFinite(price)) throw new Error("no price");

  const previous =
    typeof info.chartPreviousClose === "number"
      ? info.chartPreviousClose
      : typeof info.previousClose === "number"
        ? info.previousClose
        : (closes[0] ?? price);

  return {
    price,
    previous,
    points: sample(closes.length > 1 ? closes : [price, price], SPARK_POINTS),
  };
}

async function fetchQuote(symbol) {
  const path = `/v8/finance/chart/${encodeURIComponent(symbol)}?range=1d&interval=5m`;
  let last;
  for (const host of HOSTS) {
    try {
      const response = await fetch(host + path, {
        headers: { "User-Agent": USER_AGENT, Accept: "application/json" },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return parseChart(await response.json());
    } catch (error) {
      last = error;
    }
  }
  throw last ?? new Error("no hosts tried");
}

// ---------------------------------------------------------------- presentation

/** Prices span $2 500 (ETH) to $63 000 (BTC) to typical equity prices in one grid; two
 * decimals below $1 000 and none above keeps every card the same visual weight. */
function formatPrice(price) {
  if (typeof price !== "number" || !Number.isFinite(price)) return "—";
  return price >= 1000
    ? `$${Math.round(price).toLocaleString("en-US")}`
    : `$${price.toFixed(2)}`;
}

function formatChange(percent) {
  if (typeof percent !== "number" || !Number.isFinite(percent)) return "—";
  // U+2212 MINUS, not a hyphen: it lines up with the plus at the same width.
  const sign = percent >= 0 ? "+" : "−";
  return `${sign}${Math.abs(percent).toFixed(2)}%`;
}

/** One card's props, from a quote or from nothing. `source` drives the labelling:
 * "live" this pass, "cached" from the last good pass (or disk), "none" never. */
function toCard(entry, quote, source) {
  if (!quote) return { ...entry, source: "none", points: [0.5, 0.5] };
  const percent =
    typeof quote.previous === "number" && quote.previous !== 0
      ? ((quote.price - quote.previous) / quote.previous) * 100
      : 0;
  return {
    ...entry,
    source,
    price: quote.price,
    percent,
    points: quote.points?.length > 1 ? quote.points : [quote.price, quote.price],
  };
}

// ---------------------------------------------------------------- monitor state

// Last good quote per symbol, keyed by symbol. Survives a failed pass; rebuilt
// from disk on the first pass after a restart.
const quotes = new Map();
let loadedCache = false;
let watchingNetwork = false;

async function loadCache() {
  loadedCache = true;
  try {
    const saved = await Bun.file(CACHE_PATH).json();
    for (const [symbol, quote] of Object.entries(saved?.quotes ?? {})) {
      if (typeof quote?.price === "number") quotes.set(symbol, quote);
    }
    if (quotes.size > 0) console.log(`restored ${quotes.size} cached quotes`);
  } catch {
    // No cache yet (first run) or an unreadable one — either way, placeholders.
  }
}

/** Write-temp-then-rename, per spec §6: a half-written prices.json must never be
 * what the next start reads back. */
async function saveCache() {
  const temporary = `${CACHE_PATH}.tmp`;
  try {
    await Bun.write(temporary, JSON.stringify({ at: Date.now(), quotes: Object.fromEntries(quotes) }));
    await rename(temporary, CACHE_PATH);
  } catch (error) {
    console.log(`cache write failed: ${error?.message ?? error}`);
  }
}

/**
 * Push invalidation for the degrade path (spec §6 extension).
 *
 * The fetch already degrades gracefully — that is the whole point of the
 * cached/offline statuses — but at a 60-second cadence it can take a full
 * minute to *notice* the Wi-Fi dropped, during which the header still says
 * "live" over numbers that are not. The shell tells us the instant the network
 * path changes, so the header flips at once. The poll stays the truth; this is
 * only the latency half.
 */
export function onEvent(name, data, ctx) {
  if (name !== "platform" || data?.kind !== "reachability") return;
  if (data.userInfo?.satisfied !== false) return;
  ctx.update({
    cards: SYMBOLS.map((entry) => toCard(entry, quotes.get(entry.symbol), "cached")),
    status: quotes.size > 0 ? "cached" : "offline",
  });
}

export async function monitor(ctx) {
  try {
    if (!loadedCache) await loadCache();
    if (!watchingNetwork) {
      watchingNetwork = true;
      // Registering also delivers the current path state immediately, so an app
      // launched with the Wi-Fi already off does not have to wait for a change.
      // Swallowed on failure: an older shell that has never heard of this kind
      // is a reason to lose the *optimization*, not the app (§6 rule 2).
      await ctx.platform.observe("reachability", "changed").catch(() => {});
    }

    // All six in parallel, each isolated: one dead symbol costs one card, not the
    // pass. allSettled is the isolation — no rejection escapes to the loop.
    const settled = await Promise.allSettled(SYMBOLS.map((entry) => fetchQuote(entry.symbol)));

    let live = 0;
    const cards = SYMBOLS.map((entry, index) => {
      const outcome = settled[index];
      if (outcome.status === "fulfilled") {
        live += 1;
        quotes.set(entry.symbol, outcome.value);
        return toCard(entry, outcome.value, "live");
      }
      console.log(`${entry.symbol}: ${outcome.reason?.message ?? outcome.reason}`);
      const cached = quotes.get(entry.symbol);
      return toCard(entry, cached, cached ? "cached" : "none");
    });

    const status =
      live === SYMBOLS.length ? "live" : live > 0 ? "partial" : quotes.size > 0 ? "cached" : "offline";
    ctx.update({ cards, status, at: Date.now() });
    if (live > 0) await saveCache();
  } catch (error) {
    // Belt and braces: nothing above should throw, and if it ever does it must
    // still not become a crash-and-backoff loop (spec §6 rule 2).
    console.log(`monitor pass failed: ${error?.stack ?? error}`);
    ctx.update({
      cards: SYMBOLS.map((entry) => toCard(entry, quotes.get(entry.symbol), "cached")),
      status: "offline",
    });
  }
  await Bun.sleep(REFRESH_MS);
}

// ---------------------------------------------------------------- the panel

// Header dot + label per status. "offline" is deliberately quiet — a red banner
// for "the network blipped" is worse than the number being one minute old.
const STATUS = {
  starting: { dot: "secondary", text: "starting…", color: "secondary" },
  live: { dot: "green", text: "60s", color: "secondary" },
  partial: { dot: "accent", text: "partial", color: "accent" },
  cached: { dot: "secondary", text: "offline · cached", color: "secondary" },
  offline: { dot: "secondary", text: "offline", color: "secondary" },
};

// Per-symbol provenance, on the card that owns it: `monitor` isolates every
// symbol's fetch, so one dead symbol shows "cached" under its own price while
// the other five keep saying "live". The header only summarizes.
const SOURCE = { live: "live", cached: "cached", none: "no data" };

function Card({ card }) {
  const known = typeof card.percent === "number";
  const up = known && card.percent >= 0;
  const tone = known ? (up ? "green" : "red") : "secondary";

  return (
    <stack axis="v" gap={4} pad={8} fill="raised" stroke="hairline" radius={10}>
      <stack axis="h" gap={6}>
        <text content={card.label} size="s" weight="bold" />
        <spacer />
        <stack pad={4} radius={5} fill={known ? (up ? "greenTint" : "redTint") : "raisedHover"}>
          {/* No `mono`: the shell's default face already uses monospaced digits,
              so a percentage stays column-stable without losing letterforms. */}
          <text content={formatChange(card.percent)} size="xs" weight="bold" color={tone} />
        </stack>
      </stack>

      <chart points={card.points ?? [0.5, 0.5]} color={known ? tone : "secondary"} fill />

      <stack axis="h" gap={6}>
        <text content={formatPrice(card.price)} size="m" weight="semibold" />
        <spacer />
        <text
          content={SOURCE[card.source] ?? ""}
          size="xs"
          weight="medium"
          color="secondary"
        />
      </stack>
    </stack>
  );
}

// Mount state (what scripts/snapshot-demos.sh dumps — the monitor never runs
// there): six labelled cards with dashes, so the grid is legible before the
// first fetch lands.
const PLACEHOLDER = SYMBOLS.map((entry) => ({ ...entry, source: "none", points: [0.5, 0.5] }));

export default function Stocks({ cards = PLACEHOLDER, status = "starting" }) {
  const badge = STATUS[status] ?? STATUS.offline;
  // "starting" is the only status the monitor never publishes, so it means the
  // genuinely empty first load: six dashes and no pass behind them yet. The
  // degrade path is untouched — "partial", "cached" and "offline" all have real
  // numbers on the cards, and a spinner over a price is a spinner that claims
  // the price is wrong (D6: spinner is for latency, not for staleness).
  const loading = status === "starting";
  // Two columns; `distribute="equal"` is what splits a row evenly (spec §5).
  const rows = [];
  for (let index = 0; index < cards.length; index += 2) rows.push(cards.slice(index, index + 2));

  return (
    <stack axis="v" pad={14} gap={8}>
      {/* No title row: the shell names the app in the panel's left wing, and the
          status this row carried used to land under the camera. */}
      <wing side="left">
        {loading ? <spinner /> : <text content="●" size="xs" color={badge.dot} />}
        <text content={badge.text} size="s" weight="semibold" color={badge.color} />
      </wing>

      {rows.map((row) => (
        <stack key={row[0].symbol} axis="h" gap={8} distribute="equal">
          {row.map((card) => (
            <Card key={card.symbol} card={card} />
          ))}
        </stack>
      ))}
    </stack>
  );
}
