/** @jsxImportSource react */
// Paper Trader — the agent-proposes / human-approves showcase
// (docs/design/app-ideas.md, agentic wave).
//
// ┌──────────────────────────────────────────────────────────────────────────┐
// │  PAPER ONLY. THIS APP CANNOT TRADE.                                      │
// │                                                                          │
// │  Every fill in here is a row this file writes into its own SQLite file.  │
// │  There is no broker, no API key, no order endpoint, no `fetch` to        │
// │  anything but a public quote feed, and no code path — none — that moves  │
// │  a real share or a real dollar. The name says "Paper Trader" in the app  │
// │  strip for the same reason this comment is at the top of the file: the   │
// │  one thing a trading UI must never be is ambiguous about which it is.    │
// │  Fills are simulated at the quote the proposal was made on, with no      │
// │  slippage, no spread, no commission and no partial fills, which is       │
// │  exactly why nothing here is investment advice or a backtest.            │
// └──────────────────────────────────────────────────────────────────────────┘
//
// The loop it exists to demonstrate: **sense → decide → ask → act → report.**
//
//   sense   the monitor pulls a small watchlist off Yahoo Finance's keyless
//           chart endpoint (the same endpoint and the same degrade rules as the
//           `stocks` demo — see protocol/README.md).
//   decide  a deliberately small strategy (fast/slow intraday SMA momentum,
//           plus a mean-reversion dip and two exits) produces at most a few
//           proposals a day.
//   ask     ONE proposal at a time becomes `ctx.notify(…, { actions:
//           [Execute, Skip] })` plus `ctx.expand()` — the banner and the panel
//           are two views of the same pending decision, and either can answer
//           it. The notification button comes back as the app-level
//           `notification` event at id 0 (protocol/README.md), which is what
//           `onEvent` below is for.
//   act     approval writes a paper fill into `ledger.sqlite` (bun:sqlite, a
//           Bun builtin — no dependency).
//   report  the panel shows positions / cash / P&L; the collapsed notch shows
//           "▲ $412 paper" (spec §3.3 extension).
//
// **The monitor never throws** (spec §6 rule 2): a flaky quote feed leaves the
// last-known portfolio on screen with an "offline" marker, never a crash loop.
//
// The ledger is opened lazily, inside the monitor, rather than at module scope:
// `scripts/dump-commits.ts` imports this file to render the mount tree, and an
// import that creates a SQLite file as a side effect would make the snapshot
// pipeline write into the repo.

import { Database } from "bun:sqlite";

export const meta = { name: "Paper Trader", icon: "sf:chart.bar" };

// ---------------------------------------------------------------- constants

/** Opening paper cash. Changing it only matters on a fresh ledger — the
 * balance after that is a replay of the trades table. */
const SEED_CASH = 100_000;

const WATCHLIST = ["NVDA", "AAPL", "MSFT", "AMD", "TSLA"];

const REFRESH_MS = 60_000;
const REQUEST_TIMEOUT_MS = 8_000;
const DB_PATH = `${import.meta.dir}/ledger.sqlite`;

// query1/query2 are the same service behind two names; when one edge
// rate-limits, the other usually still answers (see the stocks demo).
const HOSTS = ["https://query1.finance.yahoo.com", "https://query2.finance.yahoo.com"];
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// ---------------------------------------------------------------- strategy
//
// Thresholds are DEMO-FRIENDLY on purpose and say so. A real momentum filter
// would use a wider band and a longer window; these are tuned so that a market
// with any life in it produces a proposal inside a few minutes, because an
// approval-loop demo that never asks for approval demonstrates nothing.

/** Fast window: 6 five-minute bars ≈ 30 minutes. */
const FAST_BARS = 6;
/** Slow window: 24 five-minute bars ≈ 2 hours. */
const SLOW_BARS = 24;
/** Momentum band: fast SMA this far above/below the slow SMA is a signal. */
const MOMENTUM_BAND = 0.0015; // 0.15 %
/** Mean reversion: this far under the previous close is a dip worth buying. */
const DIP_THRESHOLD = -0.015; // −1.5 %
/** Exits on an open position. */
const TAKE_PROFIT = 0.03; // +3 %
const STOP_LOSS = -0.02; // −2 %

/** At most a few a day, one pending at a time, and never two in a row inside
 * the cooldown — the governor is what keeps "the notch asks you things" from
 * becoming "the notch nags you". */
const MAX_PROPOSALS_PER_DAY = 4;
const PROPOSAL_COOLDOWN_MS = 10 * 60_000;

/** Position size: a tenth of the cash pile, capped, at least one share. */
const POSITION_FRACTION = 0.1;
const POSITION_CAP = 12_000;

// ---------------------------------------------------------------- quotes
// The stocks demo's fetch, trimmed to what a strategy needs: the last price,
// the previous close, and the intraday closes the SMAs run over.

function parseChart(body) {
  const result = body?.chart?.result?.[0];
  if (!result) throw new Error(body?.chart?.error?.description ?? "no result in payload");

  const info = result.meta ?? {};
  // `close` is sparse — Yahoo emits a null for every interval with no trade,
  // and a null in the middle of a moving average is a hole, not a zero.
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

  return { price, previous, closes: closes.length > 0 ? closes : [price] };
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

const mean = (values) =>
  values.length === 0 ? 0 : values.reduce((sum, value) => sum + value, 0) / values.length;

/** fast/slow SMA momentum as a fraction. Short series fall back to whatever
 * they have, so a symbol that just opened still produces a number. */
function momentumOf(closes) {
  const fast = mean(closes.slice(-FAST_BARS));
  const slow = mean(closes.slice(-SLOW_BARS));
  if (slow === 0) return 0;
  return fast / slow - 1;
}

// ---------------------------------------------------------------- the ledger
//
// bun:sqlite, a Bun builtin (spec §6: persistence is the app's own business and
// the platform already has it). Trades are the source of truth: cash and every
// position are a replay of that table, so there is exactly one thing to keep
// consistent and it is append-only.

let db = null;

function openLedger() {
  if (db) return db;
  db = new Database(DB_PATH, { create: true });
  // WAL, per AGENTS.md's persistence guidance for anything append-heavy.
  db.run("pragma journal_mode = wal");
  db.run(`
    create table if not exists trades (
      id      integer primary key autoincrement,
      at      integer not null,
      symbol  text    not null,
      side    text    not null,
      qty     integer not null,
      price   real    not null,
      reason  text    not null
    )
  `);
  return db;
}

/** Replay the trades table into cash + positions. Average-cost basis, which is
 * the only basis a paper ledger with no tax lot tracking can honestly claim. */
function replayLedger() {
  const rows = openLedger()
    .query("select at, symbol, side, qty, price from trades order by id asc")
    .all();

  let cash = SEED_CASH;
  let realized = 0;
  const positions = new Map();

  for (const row of rows) {
    const held = positions.get(row.symbol) ?? { qty: 0, cost: 0 };
    if (row.side === "buy") {
      cash -= row.qty * row.price;
      positions.set(row.symbol, { qty: held.qty + row.qty, cost: held.cost + row.qty * row.price });
    } else {
      const qty = Math.min(row.qty, held.qty);
      const basis = held.qty > 0 ? (held.cost / held.qty) * qty : 0;
      cash += qty * row.price;
      realized += qty * row.price - basis;
      const remaining = held.qty - qty;
      if (remaining > 0) positions.set(row.symbol, { qty: remaining, cost: held.cost - basis });
      else positions.delete(row.symbol);
    }
  }
  return { cash, realized, positions, count: rows.length };
}

/** The one write path. A paper fill, and nothing else, ever. */
function recordTrade(trade) {
  openLedger().run(
    "insert into trades (at, symbol, side, qty, price, reason) values (?, ?, ?, ?, ?, ?)",
    [trade.at, trade.symbol, trade.side, trade.qty, trade.price, trade.reason],
  );
}

// ---------------------------------------------------------------- state

let ctxRef = null;
let book = { cash: SEED_CASH, realized: 0, positions: new Map(), count: 0 };
let loaded = false;

/** Last known quote per symbol, so a failed pass still prices the portfolio. */
const quotes = new Map();
let status = "starting";

/** The one decision waiting for a human, or null. `id` is the notification id
 * `ctx.notify` returned, which is how a pressed button routes back here. */
let pending = null;
let proposalsToday = 0;
let proposalDay = "";
let lastProposalAt = 0;
/** The startup kicker fires once per worker life — see `propose`. */
let openingDone = false;

let lastSignature = "";
let lastWing = "";

const money = (value) =>
  `$${Math.abs(value).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const signed = (value) => `${value >= 0 ? "+" : "−"}${money(value)}`;

const dayOf = (at) => new Date(at).toISOString().slice(0, 10);

// ---------------------------------------------------------------- strategy

/**
 * One symbol's signal, or null. Order matters: exits are checked before entries
 * so a position that hit its stop is closed rather than doubled down on.
 */
function signalFor(symbol, quote) {
  const held = book.positions.get(symbol);
  const momentum = momentumOf(quote.closes);
  const fromPrevious = quote.previous > 0 ? quote.price / quote.previous - 1 : 0;

  if (held && held.qty > 0) {
    const basis = held.cost / held.qty;
    const unrealized = basis > 0 ? quote.price / basis - 1 : 0;
    if (unrealized >= TAKE_PROFIT) {
      return { side: "sell", qty: held.qty, reason: `take profit · ${pct(unrealized)} on the position` };
    }
    if (unrealized <= STOP_LOSS) {
      return { side: "sell", qty: held.qty, reason: `stop loss · ${pct(unrealized)} on the position` };
    }
    if (momentum <= -MOMENTUM_BAND) {
      return { side: "sell", qty: held.qty, reason: `momentum faded · 30m SMA ${pct(momentum)} vs 2h` };
    }
    return null;
  }

  if (momentum >= MOMENTUM_BAND) {
    return { side: "buy", reason: `momentum · 30m SMA ${pct(momentum)} vs 2h`, score: momentum };
  }
  if (fromPrevious <= DIP_THRESHOLD) {
    return {
      side: "buy",
      reason: `mean reversion · ${pct(fromPrevious)} under yesterday's close`,
      score: -fromPrevious,
    };
  }
  return null;
}

const pct = (fraction) =>
  `${fraction >= 0 ? "+" : "−"}${(Math.abs(fraction) * 100).toFixed(2)}%`;

/** Shares to buy at `price`, or 0 when the cash pile cannot carry one. */
function sizeFor(price) {
  if (!(price > 0)) return 0;
  const notional = Math.min(book.cash * POSITION_FRACTION, POSITION_CAP);
  const qty = Math.floor(notional / price);
  return qty >= 1 && qty * price <= book.cash ? qty : 0;
}

/** The governor. Everything that says "not now" lives here, so the strategy
 * above only has to say what it thinks. */
function mayPropose(now) {
  if (pending) return false;
  const day = dayOf(now);
  if (day !== proposalDay) {
    proposalDay = day;
    proposalsToday = 0;
  }
  if (proposalsToday >= MAX_PROPOSALS_PER_DAY) return false;
  return now - lastProposalAt >= PROPOSAL_COOLDOWN_MS;
}

/**
 * Turn the best available signal into the one pending decision. The startup
 * kicker is deliberate and labelled: with a flat book and no signal in band,
 * the highest-momentum name is proposed anyway, once per worker life, so a live
 * demo always has something to approve. It is still a proposal — nothing is
 * filled without a human — which is what makes a demo affordance honest.
 */
function propose(now) {
  const candidates = [];
  for (const symbol of WATCHLIST) {
    const quote = quotes.get(symbol);
    if (!quote) continue;
    const signal = signalFor(symbol, quote);
    if (signal) candidates.push({ symbol, quote, ...signal });
  }

  // Exits first, then the strongest entry: closing a losing position is more
  // urgent than opening a new one, and only one thing can be pending.
  candidates.sort((a, b) => {
    if (a.side !== b.side) return a.side === "sell" ? -1 : 1;
    return (b.score ?? 0) - (a.score ?? 0);
  });

  let best = candidates[0];

  if (!best && !openingDone && book.positions.size === 0) {
    const ranked = WATCHLIST.map((symbol) => ({ symbol, quote: quotes.get(symbol) }))
      .filter((entry) => entry.quote)
      .sort((a, b) => momentumOf(b.quote.closes) - momentumOf(a.quote.closes));
    const top = ranked[0];
    if (top) {
      best = {
        symbol: top.symbol,
        quote: top.quote,
        side: "buy",
        reason: `opening position · strongest of ${ranked.length} on 30m/2h momentum`,
      };
    }
  }
  if (!best) return;
  openingDone = true;

  const price = best.quote.price;
  const qty = best.side === "buy" ? sizeFor(price) : best.qty;
  if (!(qty >= 1)) return;

  const label = `${best.side.toUpperCase()} ${qty} ${best.symbol} @ ${price.toFixed(2)}`;
  pending = {
    id: 0,
    symbol: best.symbol,
    side: best.side,
    qty,
    price,
    reason: best.reason,
    label,
    at: now,
  };
  proposalsToday += 1;
  lastProposalAt = now;

  // The banner and the panel are two views of one decision; either answers it.
  pending.id = ctxRef.notify(label, {
    title: "Paper Trader",
    attention: true,
    actions: [
      { id: "execute", label: "Execute" },
      { id: "skip", label: "Skip" },
    ],
  });
  publish();
  ctxRef.expand();
  console.log(`PROPOSAL #${pending.id}: ${label} — ${best.reason}`);
}

// ---------------------------------------------------------------- decisions
//
// Both approval paths land here: the notification button (via onEvent, id 0)
// and the panel's own buttons (via ordinary onClick props). There is one
// implementation because there is one decision.

function execute() {
  if (!pending) return;
  const decision = pending;
  pending = null;

  // Simulated fill at the proposal's quote — no slippage, no spread, no
  // commission. Stated here as well as in the header because this line is the
  // one a reader will check.
  recordTrade({
    at: Date.now(),
    symbol: decision.symbol,
    side: decision.side,
    qty: decision.qty,
    price: decision.price,
    reason: decision.reason,
  });
  book = replayLedger();
  console.log(`EXECUTED (paper): ${decision.label} — cash now ${money(book.cash)}`);
  publish();
  publishWing();
}

function skip() {
  if (!pending) return;
  console.log(`SKIPPED: ${pending.label}`);
  pending = null;
  publish();
}

/** App-level events (protocol/README.md — id 0). The only one this app cares
 * about is a pressed notification button; `default` (a click on the banner
 * body) opens the panel rather than deciding for the user, because opening a
 * notification is not the same gesture as approving it. */
export function onEvent(name, data, ctx) {
  if (name !== "notification") return;
  const id = Number(data?.id);
  const action = String(data?.action ?? "");
  if (!pending || pending.id !== id) {
    console.log(`notification #${id} ${action} — no matching pending proposal`);
    return;
  }
  console.log(`notification #${id} -> ${action}`);
  if (action === "execute") execute();
  else if (action === "skip") skip();
  else ctx.expand();
}

// ---------------------------------------------------------------- publishing

function portfolio() {
  const rows = [];
  let marketValue = 0;
  let unrealized = 0;
  for (const [symbol, held] of book.positions) {
    const quote = quotes.get(symbol);
    const basis = held.qty > 0 ? held.cost / held.qty : 0;
    const last = quote?.price ?? basis;
    const value = held.qty * last;
    marketValue += value;
    unrealized += value - held.cost;
    rows.push({
      symbol,
      qty: held.qty,
      basis,
      last,
      value,
      pnl: value - held.cost,
      percent: basis > 0 ? last / basis - 1 : 0,
    });
  }
  rows.sort((a, b) => b.value - a.value);
  const equity = book.cash + marketValue;
  return { rows, marketValue, unrealized, equity, total: equity - SEED_CASH };
}

function viewProps() {
  const view = portfolio();
  return {
    positions: view.rows,
    cash: book.cash,
    equity: view.equity,
    pnl: view.total,
    unrealized: view.unrealized,
    realized: book.realized,
    trades: book.count,
    status,
    proposal: pending
      ? {
          label: pending.label,
          symbol: pending.symbol,
          side: pending.side,
          qty: pending.qty,
          price: pending.price,
          reason: pending.reason,
          notional: pending.qty * pending.price,
        }
      : null,
    onExecute: execute,
    onSkip: skip,
  };
}

function signature(props) {
  return JSON.stringify([
    props.positions.map((row) => [row.symbol, row.qty, row.last.toFixed(2), row.pnl.toFixed(2)]),
    props.cash.toFixed(2),
    props.pnl.toFixed(2),
    props.status,
    props.proposal,
    props.trades,
  ]);
}

function publish() {
  if (!ctxRef) return;
  const props = viewProps();
  const next = signature(props);
  if (next === lastSignature) return;
  lastSignature = next;
  ctxRef.update(props);
}

/** "▲ $412 paper" on the collapsed notch. The word `paper` is not decoration:
 * it is the one place a glanceable number could be mistaken for a real one. */
function publishWing() {
  if (!ctxRef) return;
  const view = portfolio();
  // Flat *and* level get the neutral marker: a "▲" over $0.00 is a triangle
  // pointing at nothing, and the wing is a glance, not a report.
  const flat = Math.abs(view.total) < 0.005;
  const text = flat
    ? "◦ $0 paper"
    : `${view.total > 0 ? "▲" : "▼"} ${money(view.total)} paper`;
  if (text === lastWing) return;
  lastWing = text;
  ctxRef.wing({ text });
}

// ---------------------------------------------------------------- monitor

export async function monitor(ctx) {
  try {
    ctxRef = ctx;
    if (!loaded) {
      loaded = true;
      book = replayLedger();
      console.log(`ledger: ${book.count} paper trades, cash ${money(book.cash)}`);
      publish();
      publishWing();
    }

    // All symbols in parallel, each isolated: one dead symbol costs one quote,
    // not the pass (the stocks demo's rule).
    const settled = await Promise.allSettled(WATCHLIST.map((symbol) => fetchQuote(symbol)));
    let live = 0;
    settled.forEach((outcome, index) => {
      const symbol = WATCHLIST[index];
      if (outcome.status === "fulfilled") {
        live += 1;
        quotes.set(symbol, outcome.value);
      } else {
        console.log(`${symbol}: ${outcome.reason?.message ?? outcome.reason}`);
      }
    });
    status = live === WATCHLIST.length ? "live" : live > 0 ? "partial" : quotes.size > 0 ? "cached" : "offline";

    const now = Date.now();
    if (live > 0 && mayPropose(now)) propose(now);

    publish();
    publishWing();
  } catch (error) {
    // Belt and braces (spec §6 rule 2): the portfolio stays on screen.
    console.log(`monitor pass failed: ${error?.stack ?? error}`);
    status = "offline";
    publish();
  }
  await Bun.sleep(REFRESH_MS);
}

// ---------------------------------------------------------------- the panel

const STATUS = {
  starting: { dot: "secondary", text: "starting…" },
  live: { dot: "green", text: "60s" },
  partial: { dot: "accent", text: "partial" },
  cached: { dot: "secondary", text: "offline · cached" },
  offline: { dot: "secondary", text: "offline" },
};

/** The status line, now a **panel wing** (spec §5) rather than a title row: the
 * shell already names the app in that zone, and the row this replaces put its
 * status under the camera housing. Both trees mount one, and because a wing is
 * a direct child of the root it is declared where the root is. */
function Header({ status: state, right, rightColor = "secondary" }) {
  const badge = STATUS[state] ?? STATUS.offline;
  return (
    <wing side="left">
      <text content="●" size="xs" color={badge.dot} />
      <text content={right ?? badge.text} size="s" weight="semibold" color={rightColor} />
    </wing>
  );
}

/** The pending decision. Deliberately the whole panel: a proposal is a question,
 * and a question sharing the screen with a portfolio table is a question that
 * gets ignored. */
function Proposal({ proposal, onExecute, onSkip }) {
  const buying = proposal.side === "buy";
  return (
    <stack axis="v" pad={14} gap={10}>
      <Header status="live" right="PAPER · needs approval" rightColor="accent" />

      <stack
        axis="v"
        gap={8}
        pad={12}
        fill={buying ? "greenTint" : "redTint"}
        stroke={buying ? "green" : "red"}
        radius={12}
      >
        <stack axis="h" gap={8}>
          <text
            content={buying ? "BUY" : "SELL"}
            size="s"
            weight="bold"
            color={buying ? "green" : "red"}
            mono
          />
          <text content={proposal.symbol} size="l" weight="bold" />
          <spacer />
          <text content={`${proposal.qty} sh`} size="s" weight="semibold" color="secondary" mono />
        </stack>

        <text content={proposal.reason} size="s" color="secondary" />

        <stack axis="h" gap={8}>
          <text content={`@ $${proposal.price.toFixed(2)}`} size="m" weight="semibold" mono />
          <spacer />
          <text
            content={`${buying ? "−" : "+"}${money(proposal.notional)}`}
            size="m"
            weight="semibold"
            color={buying ? "red" : "green"}
            mono
          />
        </stack>
      </stack>

      <stack axis="h" gap={8} distribute="equal">
        <button label="Skip" icon="sf:xmark" variant="glass" onClick={() => onSkip?.()} />
        <button label="Execute" icon="sf:checkmark" variant="accent" onClick={() => onExecute?.()} />
      </stack>

      <stack axis="h">
        <spacer />
        <text
          content="simulated fill · no broker, no real order"
          size="xs"
          weight="medium"
          color="tertiary"
        />
        <spacer />
      </stack>
    </stack>
  );
}

function PositionRow({ row }) {
  const up = row.pnl >= 0;
  return (
    <stack axis="h" gap={8} pad={8} fill="raised" stroke="hairline" radius={10}>
      <text content={row.symbol} size="s" weight="bold" mono />
      <text content={`${row.qty}`} size="xs" weight="medium" color="tertiary" mono />
      <spacer />
      <stack axis="v" gap={2}>
        <text content={`$${row.last.toFixed(2)}`} size="s" weight="semibold" mono />
        <text
          content={`from $${row.basis.toFixed(2)}`}
          size="xs"
          weight="medium"
          color="tertiary"
          mono
        />
      </stack>
      {/* §5's `pill` (D6 "New kinds") — the tint + stroke + hue-ink triple this
          row used to build out of a padded `stack`, and the ±% case the ruling
          names. The tone is the sign, which is app logic; the values are the
          shell's (law L9). */}
      <pill label={signed(row.pnl)} tone={up ? "green" : "red"} />
    </stack>
  );
}

// Mount state (what scripts/snapshot-demos.sh dumps — the monitor never runs
// there, and the ledger is opened lazily so importing this file touches no
// disk): the opening book, flat, with the paper rule on screen.
export default function PaperTrader({
  positions = [],
  cash = SEED_CASH,
  equity = SEED_CASH,
  pnl = 0,
  realized = 0,
  trades = 0,
  status: state = "starting",
  proposal = null,
  onExecute,
  onSkip,
}) {
  if (proposal) return <Proposal proposal={proposal} onExecute={onExecute} onSkip={onSkip} />;

  const up = pnl >= 0;
  return (
    <stack axis="v" pad={14} gap={8}>
      <Header status={state} />

      <stack axis="h" gap={8} pad={12} fill="raised" stroke="hairline" radius={12}>
        <stack axis="v" gap={3}>
          <text content="Equity" size="xs" weight="medium" color="secondary" />
          <text content={money(equity)} size="l" weight="bold" mono />
        </stack>
        <spacer />
        <stack axis="v" gap={3}>
          <text content="P&L" size="xs" weight="medium" color="secondary" />
          <text
            content={signed(pnl)}
            size="l"
            weight="bold"
            color={up ? "green" : "red"}
            mono
          />
        </stack>
      </stack>

      <stack axis="h" gap={8}>
        <text content={`cash ${money(cash)}`} size="xs" weight="medium" color="tertiary" mono />
        <spacer />
        <text
          content={`realized ${signed(realized)} · ${trades} fills`}
          size="xs"
          weight="medium"
          color="tertiary"
          mono
        />
      </stack>

      {positions.length === 0 ? (
        <stack axis="h" pad={12} fill="raised" stroke="hairline" radius={10}>
          <spacer />
          <text content="No positions — flat" size="s" weight="medium" color="secondary" />
          <spacer />
        </stack>
      ) : (
        positions.map((row) => <PositionRow key={row.symbol} row={row} />)
      )}

      {/* The PAPER badge, now the real `pill` kind. Accent, and the only accent
          on this panel (law L9): of everything on screen, the sentence that says
          none of it is real is the one that has earned the hue. */}
      <stack axis="h">
        <spacer />
        <pill label="PAPER ONLY · simulated fills, no brokerage" tone="accent" />
        <spacer />
      </stack>
    </stack>
  );
}
