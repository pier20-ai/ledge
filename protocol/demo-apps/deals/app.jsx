/** @jsxImportSource react */
// Deal Watch — a live price tracker over books.toscrape.com, a site that exists
// to be scraped (stable markup, no ToS to breach, no rate limit to respect).
// Four watched titles with a target price each; the monitor re-parses the
// category page every ten minutes and a row that falls under target turns green,
// gains a HIT tag, and — the first time it does — fires a notification.
//
// The tinted "hit" row is the reason `stack` grew `fill`/`stroke`
// (protocol/README.md): a tinted, outlined row is the whole visual language of
// an alert, and §5 previously had no way to say it without a bespoke component.
//
// **The monitor never throws.** A throw is an app crash with backoff (spec §6
// rule 2). A scrape is the flakiest thing an app can do, so every failure path
// here ends in last-known rows plus an "offline" marker in the header.

import { rename } from "node:fs/promises";
import * as cheerio from "cheerio";

export const meta = { name: "Deal Watch", icon: "sf:tag" };

// ---------------------------------------------------------------- the watchlist

// One category page holds all four, so a pass is a single request. The titles are
// verbatim from the site's `h3 > a[title]`, which is the full title — the link
// *text* is truncated with an ellipsis, so it is the attribute or nothing.
const SOURCE_URL = "https://books.toscrape.com/catalogue/category/books/mystery_3/index.html";
const SOURCE_LABEL = "books.toscrape.com";

const WATCH = [
  { title: "Sharp Objects", icon: "sf:book.closed", target: 50 },
  { title: "In a Dark, Dark Wood", icon: "sf:moon.stars", target: 18 },
  { title: "The Past Never Ends", icon: "sf:clock.arrow.circlepath", target: 60 },
  { title: "A Murder in Time", icon: "sf:hourglass", target: 15 },
];

const REFRESH_MS = 10 * 60_000;
const REQUEST_TIMEOUT_MS = 10_000;

const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// App-owned persistence in the app's own folder (spec §6). Holds last-known
// prices so a cold start after a network outage still shows real numbers, and
// which titles were already hit so a restart doesn't re-notify.
const CACHE_PATH = `${import.meta.dir}/prices.json`;

// ---------------------------------------------------------------- scrape

/** Parse `£47.82` (the site prefixes a stray Â from its own mis-encoded £). */
function parsePrice(raw) {
  const match = /([\d]+(?:\.[\d]+)?)/.exec(raw ?? "");
  return match ? Number(match[1]) : undefined;
}

/** title → price for every book on the page. Throws if the page parses to
 * nothing, which is how a challenge page or a redesign becomes a failed pass
 * instead of a grid of blanks. */
async function scrapePrices() {
  const response = await fetch(SOURCE_URL, {
    headers: { "User-Agent": USER_AGENT, Accept: "text/html" },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);

  const $ = cheerio.load(await response.text());
  const prices = new Map();
  $("article.product_pod").each((_, element) => {
    const card = $(element);
    const title = card.find("h3 a").attr("title")?.trim();
    const price = parsePrice(card.find(".price_color").first().text());
    if (title && typeof price === "number") prices.set(title, price);
  });

  if (prices.size === 0) throw new Error("no product_pod entries — page shape changed?");
  return prices;
}

// ---------------------------------------------------------------- monitor state

const prices = new Map(); // title → last known price
const hit = new Set(); // titles already announced, so a re-check doesn't re-notify
let loadedCache = false;

async function loadCache() {
  loadedCache = true;
  try {
    const saved = await Bun.file(CACHE_PATH).json();
    for (const [title, price] of Object.entries(saved?.prices ?? {})) {
      if (typeof price === "number") prices.set(title, price);
    }
    for (const title of saved?.hit ?? []) hit.add(title);
    if (prices.size > 0) console.log(`restored ${prices.size} cached prices`);
  } catch {
    // No cache yet (first run) or an unreadable one — either way, dashes.
  }
}

/** Write-temp-then-rename, per spec §6: a half-written prices.json must never be
 * what the next start reads back. */
async function saveCache() {
  const temporary = `${CACHE_PATH}.tmp`;
  try {
    await Bun.write(
      temporary,
      JSON.stringify({ at: Date.now(), prices: Object.fromEntries(prices), hit: [...hit] }),
    );
    await rename(temporary, CACHE_PATH);
  } catch (error) {
    console.log(`cache write failed: ${error?.message ?? error}`);
  }
}

function toRow(entry, price, live) {
  return {
    ...entry,
    price,
    live,
    hit: typeof price === "number" && price <= entry.target,
  };
}

export async function monitor(ctx) {
  try {
    if (!loadedCache) await loadCache();

    let scraped;
    try {
      scraped = await scrapePrices();
    } catch (error) {
      console.log(`scrape failed: ${error?.message ?? error}`);
    }

    if (scraped) {
      for (const entry of WATCH) {
        const price = scraped.get(entry.title);
        if (typeof price === "number") prices.set(entry.title, price);
        else console.log(`not on the page: ${entry.title}`);
      }
    }

    const rows = WATCH.map((entry) => toRow(entry, prices.get(entry.title), Boolean(scraped)));

    // Notify only on a *new* hit, and only off a live pass — announcing a deal
    // read back from the cache would fire on every restart.
    if (scraped) {
      for (const row of rows) {
        if (row.hit && !hit.has(row.title)) {
          hit.add(row.title);
          ctx.notify(`${row.title} is £${row.price.toFixed(2)} — under your £${row.target} target`, {
            attention: true,
          });
          console.log(`new hit: ${row.title} at £${row.price}`);
        } else if (!row.hit) {
          hit.delete(row.title);
        }
      }
      await saveCache();
    }

    ctx.update({
      rows,
      status: scraped ? "live" : prices.size > 0 ? "cached" : "offline",
    });
  } catch (error) {
    // Belt and braces: nothing above should throw, and if it ever does it must
    // still not become a crash-and-backoff loop (spec §6 rule 2).
    console.log(`monitor pass failed: ${error?.stack ?? error}`);
    ctx.update({
      rows: WATCH.map((entry) => toRow(entry, prices.get(entry.title), false)),
      status: "offline",
    });
  }
  await Bun.sleep(REFRESH_MS);
}

// ---------------------------------------------------------------- the panel

const STATUS = {
  starting: { dot: "secondary", text: "starting…" },
  live: { dot: "green", text: `${WATCH.length} tracked` },
  cached: { dot: "secondary", text: "offline · cached" },
  offline: { dot: "secondary", text: "offline" },
};

function Deal({ row }) {
  const price = typeof row.price === "number" ? `£${row.price.toFixed(2)}` : "—";
  return (
    <stack
      axis="h"
      gap={10}
      pad={8}
      fill={row.hit ? "greenTint" : "raised"}
      stroke={row.hit ? "green" : "hairline"}
      radius={10}
    >
      <stack pad={5} radius={7} fill="raisedHover">
        <image src={row.icon} w={18} h={18} />
      </stack>
      <stack axis="v" gap={2}>
        <text content={row.title} size="m" weight="semibold" truncate />
        <text
          content={`${SOURCE_LABEL} · target £${row.target}`}
          size="xs"
          weight="medium"
          color="secondary"
        />
      </stack>
      <spacer />
      <stack axis="v" gap={2} align="end">
        <text content={price} size="m" weight="semibold" color={row.hit ? "green" : "primary"} />
        <text
          content={row.live ? "live" : typeof row.price === "number" ? "cached" : "no data"}
          size="xs"
          weight="medium"
          color="secondary"
        />
      </stack>
      {row.hit ? (
        <stack pad={5} radius={5} fill="greenTint">
          <text content="HIT" size="xs" weight="bold" color="green" mono />
        </stack>
      ) : null}
    </stack>
  );
}

// Mount state (what scripts/snapshot-demos.sh dumps — the monitor never runs
// there): the watched titles with their targets and no price yet.
const PLACEHOLDER = WATCH.map((entry) => toRow(entry, undefined, false));

export default function Deals({ rows = PLACEHOLDER, status = "starting" }) {
  const badge = STATUS[status] ?? STATUS.offline;
  // "starting" is the only status the monitor never publishes, so it is exactly
  // "the first scrape has not landed yet" — the one state a spinner is honest
  // about (D6: spinner, not an indeterminate progress bar). Every later status,
  // including a failed pass, has real or cached prices behind it and gets the
  // status dot back.
  const loading = status === "starting";
  return (
    <stack axis="v" pad={16} gap={6}>
      {/* No title row — the shell names the app in the panel's left wing, which
          is also the only place at the top of the panel the camera does not
          cover. */}
      <wing side="left">
        {loading ? <spinner /> : <text content="●" size="xs" color={badge.dot} />}
        <text content={badge.text} size="s" weight="semibold" color="secondary" />
      </wing>

      {rows.map((row) => (
        <Deal key={row.title} row={row} />
      ))}
    </stack>
  );
}
