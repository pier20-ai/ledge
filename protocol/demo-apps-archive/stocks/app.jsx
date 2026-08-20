/** @jsxImportSource react */
// Stocks — a scrolling watchlist that opens into a per-ticker history page
// (docs/design/app-ideas.md, wave 1). Ten symbols, each a row with a coloured
// %-change pill; the monitor refreshes all of them once a minute from Yahoo
// Finance's keyless chart endpoint, and tapping a row swaps the panel for that
// ticker's detail page — price, range switch, sparkline, and the four numbers
// that describe the series being shown.
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
// **Two pages, no router.** Which page the panel shows is `useState` in this
// component and nothing else: the protocol has no notion of a page, a route or a
// stack, and the tree the app returns is simply a different tree. That is
// deliberate — see protocol/README.md, "Pages are app state".
//
// **The monitor never throws.** A throw is an app crash with backoff (spec §6
// rule 2), so a flaky network would take the whole app down rather than show a
// stale number. Every failure path here ends in cached-or-placeholder rows and
// an "offline"/"partial" marker in the wing instead.

import { useState } from "react";
import { rename } from "node:fs/promises";

export const meta = { name: "Stocks", icon: "sf:chart.line.uptrend.xyaxis" };

// ---------------------------------------------------------------- the watchlist

// Long enough to overflow the panel, which is the point: the list is a
// `stack scroll` and a list that fits proves nothing about it.
const SYMBOLS = [
  { symbol: "AAPL", label: "AAPL", name: "Apple" },
  { symbol: "NVDA", label: "NVDA", name: "NVIDIA" },
  { symbol: "MSFT", label: "MSFT", name: "Microsoft" },
  { symbol: "GOOG", label: "GOOG", name: "Alphabet" },
  { symbol: "AMZN", label: "AMZN", name: "Amazon" },
  { symbol: "META", label: "META", name: "Meta Platforms" },
  { symbol: "TSLA", label: "TSLA", name: "Tesla" },
  { symbol: "ENPH", label: "ENPH", name: "Enphase Energy" },
  // Crypto rides the same endpoint — the pair symbol is all that differs.
  { symbol: "BTC-USD", label: "BTC", name: "Bitcoin" },
  { symbol: "ETH-USD", label: "ETH", name: "Ethereum" },
];

const REFRESH_MS = 60_000;
const REQUEST_TIMEOUT_MS = 8_000;
const SPARK_POINTS = 24;
// The detail chart is the full panel width rather than a row's worth, so it can
// carry more shape without turning into noise.
const HISTORY_POINTS = 72;

// The ranges the detail page offers. `1d` is whatever the monitor already
// fetched — the watchlist and the default detail view are the same series, so
// opening a row costs no request at all. The other two are fetched on demand and
// cached for the life of the worker.
const RANGES = [
  { id: "1d", label: "1D", range: "1d", interval: "5m" },
  { id: "1m", label: "1M", range: "1mo", interval: "1d" },
  { id: "6m", label: "6M", range: "6mo", interval: "1d" },
];
const RANGE_OPTIONS = RANGES.map(({ id, label }) => ({ id, label }));

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
function parseChart(body, count) {
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
    points: sample(closes.length > 1 ? closes : [price, price], count),
  };
}

async function fetchQuote(symbol, { range = "1d", interval = "5m", count = SPARK_POINTS } = {}) {
  const path =
    `/v8/finance/chart/${encodeURIComponent(symbol)}` +
    `?range=${range}&interval=${interval}`;
  let last;
  for (const host of HOSTS) {
    try {
      const response = await fetch(host + path, {
        headers: { "User-Agent": USER_AGENT, Accept: "application/json" },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return parseChart(await response.json(), count);
    } catch (error) {
      last = error;
    }
  }
  throw last ?? new Error("no hosts tried");
}

// ---------------------------------------------------------------- presentation

/** Prices span $2 500 (ETH) to $63 000 (BTC) to typical equity prices in one list; two
 * decimals below $1 000 and none above keeps every row the same visual weight. */
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

/** One row's props, from a quote or from nothing. `source` drives the labelling:
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
    previous: quote.previous,
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
// The monitor's ctx, kept for the detail page's on-demand history fetch. A click
// handler runs in the worker like everything else, so it can reach the same
// bridge the monitor uses — it just has to be handed it once.
let ctxRef = null;

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

// ---------------------------------------------------------------- history

// `${symbol}:${rangeId}` → { loading } | { points } | { failed }. Not persisted:
// a month of daily closes is cheap to re-fetch and expensive to keep correct.
const history = {};

/** Publish a fresh object so React sees a changed prop — mutating `history` in
 * place would re-render into an identical tree and commit nothing. */
function publishHistory() {
  ctxRef?.update({ history: { ...history } });
}

/**
 * Fetch one range for one symbol, at most once per outcome.
 *
 * Called from the detail page's range switch, which is a click handler and not
 * the monitor — so, like the monitor, it must never throw: an unhandled
 * rejection out here is still an app crash (spec §6 rule 2). Every failure lands
 * in `{ failed: true }`, which the page renders as "history unavailable" over
 * the price it already has.
 */
async function loadHistory(symbol, rangeId) {
  const spec = RANGES.find((range) => range.id === rangeId);
  if (!spec || !ctxRef) return;
  const key = `${symbol}:${rangeId}`;
  // A failed entry is retried when the user asks again; an in-flight or
  // already-loaded one is not.
  if (history[key]?.loading || history[key]?.points) return;

  history[key] = { loading: true };
  publishHistory();
  try {
    const quote = await fetchQuote(symbol, {
      range: spec.range,
      interval: spec.interval,
      count: HISTORY_POINTS,
    });
    history[key] = { points: quote.points };
  } catch (error) {
    console.log(`${key}: ${error?.message ?? error}`);
    history[key] = { failed: true };
  }
  publishHistory();
}

// ---------------------------------------------------------------- lifecycle

/**
 * Push invalidation for the degrade path (spec §6 extension).
 *
 * The fetch already degrades gracefully — that is the whole point of the
 * cached/offline statuses — but at a 60-second cadence it can take a full
 * minute to *notice* the Wi-Fi dropped, during which the wing still says
 * "live" over numbers that are not. The shell tells us the instant the network
 * path changes, so the label flips at once. The poll stays the truth; this is
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
    ctxRef = ctx;
    if (!loadedCache) await loadCache();
    if (!watchingNetwork) {
      watchingNetwork = true;
      // Registering also delivers the current path state immediately, so an app
      // launched with the Wi-Fi already off does not have to wait for a change.
      // Swallowed on failure: an older shell that has never heard of this kind
      // is a reason to lose the *optimization*, not the app (§6 rule 2).
      await ctx.platform.observe("reachability", "changed").catch(() => {});
    }

    // All ten in parallel, each isolated: one dead symbol costs one row, not the
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

// Wing dot + label per status. "offline" is deliberately quiet — a red banner
// for "the network blipped" is worse than the number being one minute old.
const STATUS = {
  starting: { dot: "secondary", text: "starting…", color: "secondary" },
  live: { dot: "green", text: "60s", color: "secondary" },
  partial: { dot: "accent", text: "partial", color: "accent" },
  cached: { dot: "secondary", text: "offline · cached", color: "secondary" },
  offline: { dot: "secondary", text: "offline", color: "secondary" },
};

/** The green/red/neutral triple every price in the app is coloured by. */
function toneOf(percent) {
  if (typeof percent !== "number" || !Number.isFinite(percent)) return null;
  return percent >= 0 ? "green" : "red";
}

// ---------------------------------------------------------------- the watchlist page

/**
 * One row of the watchlist, and the whole row is the tap target.
 *
 * `<button>` with a child rather than a `label` (spec §5): a row is a ticker, a
 * company name, a price and a pill, which no string could be, and a chevron
 * button parked at the right-hand end would make the other 90% of the row a
 * dead zone. `variant="plain"` is what supplies the hover wash and the press.
 */
function Row({ card, onOpen }) {
  const tone = toneOf(card.percent);
  return (
    <button variant="plain" onClick={() => onOpen(card.symbol)}>
      <stack axis="h" gap={10} pad={10}>
        <stack axis="v" gap={1}>
          <text content={card.label} size="s" weight="bold" />
          <text content={card.name} size="xs" color="secondary" />
        </stack>
        <spacer />
        <text content={formatPrice(card.price)} size="m" weight="semibold" />
        <pill label={formatChange(card.percent)} tone={tone ?? "neutral"} />
      </stack>
    </button>
  );
}

/**
 * The scrolling watchlist.
 *
 * The padding is *inside* the scrolling stack, not on the root. A scroller's
 * ceiling is the panel's whole content height, so every point a parent spends on
 * `pad` above it is a point the list asks for and cannot have — and the symptom
 * is the last row sitting under the app strip. Inside, the same padding scrolls
 * away with the content, which is what a list wants anyway.
 */
function Watchlist({ cards, onOpen }) {
  return (
    <stack axis="v" scroll pad={14} gap={0}>
      {cards.flatMap((card, index) => [
        index === 0 ? null : <divider key={`rule-${card.symbol}`} />,
        <Row key={card.symbol} card={card} onOpen={onOpen} />,
      ])}
    </stack>
  );
}

// ---------------------------------------------------------------- the detail page

/** One label/value line of the stats block. */
function Stat({ label, value, color }) {
  return (
    <stack axis="h" gap={8}>
      <text content={label} size="s" color="secondary" />
      <spacer />
      <text content={value} size="s" weight="semibold" color={color} />
    </stack>
  );
}

/** What the four stat lines say about the series currently on screen. Open, high
 * and low describe the *displayed* range; previous close is always today's, which
 * is what the header's percentage is measured against. */
function summarize(points, card) {
  const absolute =
    typeof card.price === "number" && typeof card.previous === "number"
      ? card.price - card.previous
      : null;
  return [
    { label: "Open", value: formatPrice(points[0]) },
    { label: "High", value: formatPrice(Math.max(...points)) },
    { label: "Low", value: formatPrice(Math.min(...points)) },
    {
      label: "Change today",
      value: absolute === null ? "—" : `${absolute >= 0 ? "+" : "−"}${formatPrice(Math.abs(absolute))}`,
      color: toneOf(card.percent) ?? "primary",
    },
  ];
}

function Detail({ card, range, series, onRange, onBack }) {
  const tone = toneOf(card.percent);
  // `source: "none"` is the pre-first-fetch placeholder, whose points are a flat
  // sentinel — charting it would draw a real-looking line over numbers nobody
  // has fetched yet.
  const points = card.source === "none" ? [] : (series?.points ?? []);
  const enough = points.length > 1;

  return (
    <stack axis="v" pad={14} gap={10}>
      {/* The way back, first thing in the reading order and first thing under
          the pointer. `glass` rather than `plain`: it is the only control on the
          page that has to be findable without looking for it. */}
      <stack axis="h" gap={8}>
        <button icon="sf:chevron.left" label="Watchlist" variant="glass" size="s" onClick={onBack} />
        <spacer />
        <pill label={formatChange(card.percent)} tone={tone ?? "neutral"} />
      </stack>

      <stack axis="v" gap={1}>
        <text content={card.name} size="s" color="secondary" />
        <text content={formatPrice(card.price)} size="xl" weight="bold" />
      </stack>

      <segment options={RANGE_OPTIONS} value={range} onChange={({ value }) => onRange(value)} />

      {series?.loading ? (
        // A spinner *here* rather than over the price: the price is current and
        // correct, it is the series that has not arrived (D6 — a spinner is for
        // latency, not for staleness).
        <stack axis="h" pad={12}>
          <spacer />
          <spinner />
          <spacer />
        </stack>
      ) : enough ? (
        <chart points={points} color={tone ?? "secondary"} fill />
      ) : (
        <stack axis="h" pad={12}>
          <spacer />
          <text
            content={series?.failed ? "history unavailable" : "no data yet"}
            size="s"
            color="secondary"
          />
          <spacer />
        </stack>
      )}

      {enough ? (
        <stack axis="v" gap={6} pad={10} fill="raised" stroke="hairline" radius={12}>
          {summarize(points, card).flatMap((stat, index) => [
            index === 0 ? null : <divider key={`rule-${stat.label}`} />,
            <Stat key={stat.label} {...stat} />,
          ])}
        </stack>
      ) : null}
    </stack>
  );
}

// ---------------------------------------------------------------- the app

// Mount state (what scripts/snapshot-demos.sh dumps — the monitor never runs
// there): ten labelled rows with dashes, so the list is legible before the
// first fetch lands.
const PLACEHOLDER = SYMBOLS.map((entry) => ({ ...entry, source: "none", points: [0.5, 0.5] }));

export default function Stocks({ cards = PLACEHOLDER, status = "starting", history: loaded = {} }) {
  // Navigation, in full. There is no route, no stack and no protocol surface
  // behind it: `focus` picks which subtree this function returns, and the shell
  // sees an ordinary commit that happens to replace most of the tree. `range` is
  // page-local state and lives in exactly the same place.
  const [focus, setFocus] = useState(null);
  const [range, setRange] = useState("1d");

  const badge = STATUS[status] ?? STATUS.offline;
  // "starting" is the only status the monitor never publishes, so it means the
  // genuinely empty first load: ten dashes and no pass behind them yet. The
  // degrade path is untouched — "partial", "cached" and "offline" all have real
  // numbers on the rows, and a spinner over a price is a spinner that claims
  // the price is wrong (D6: spinner is for latency, not for staleness).
  const loading = status === "starting";

  // Resolved from `cards` rather than captured at tap time, so a monitor pass
  // that lands while the detail page is open updates the page in place. A symbol
  // that vanishes from the watchlist falls back to the list, which is the only
  // page that can still be right.
  const card = focus ? cards.find((entry) => entry.symbol === focus) : null;

  const open = (symbol) => {
    setFocus(symbol);
    setRange("1d");
  };
  const pick = (next) => {
    setRange(next);
    if (card && next !== "1d") loadHistory(card.symbol, next);
  };

  return (
    <stack axis="v" gap={0}>
      {/* No title row: the shell names the app in the panel's right wing, and
          the status this row carried used to land under the camera. */}
      <wing side="left">
        {loading ? <spinner /> : <text content="●" size="xs" color={badge.dot} />}
        <text content={badge.text} size="s" weight="semibold" color={badge.color} />
      </wing>

      {card ? (
        <Detail
          card={card}
          range={range}
          // `1d` is the series the monitor already has; the others are fetched.
          series={range === "1d" ? { points: card.points } : loaded[`${card.symbol}:${range}`]}
          onRange={pick}
          onBack={() => setFocus(null)}
        />
      ) : (
        <Watchlist cards={cards} onOpen={open} />
      )}
    </stack>
  );
}
