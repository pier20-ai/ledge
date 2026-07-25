# Ledge app backlog

Demo and showcase apps, each tagged with the platform APIs it exercises.
API legend: **META** (meta extraction + `panel{width,maxHeight}`), **DRAW**
(worker→shell draw frames, §3.4), **WING** (live-activity wings: text /
canvas / width, §3.3 extension), **CHROME** (worker-requested
expand/collapse, §3.3), **PEER** (`ctx.peer`, deferred). "none" = buildable
on today's platform (HTTP, timers, `Bun.$` for system signals, notify,
persistence in the app folder are all already available to workers).

## Agentic apps — sense → decide → act → report

The notch is the ideal "agent proposes, human approves in one glance"
surface: interruptions are cheap, glanceable, dismissible. Monitors already
run 24/7; what agentic apps add is hands, senses, and (optionally) the
user's own agent as a brain — Ledge itself never calls a model API.

Capability legend — **all four now exist** (wire shapes in
`protocol/README.md`): **APPLE** (shell-executed `ctx.apple` — sense and hand in
one), **NOTIFY+** (shell-side notifications with action buttons; buttons need a
bundled shell, text always works), **AGENT** (`ctx.agent(prompt, {files?,
schema?})` — one headless turn of the user's own agent CLI, §8 adapters reused;
one turn per app at a time), **INTAKE** (drop-onto-notch shelf events as id-0
app events + `ctx.capture()` shell-owned interactive screenshot).

| app | loop | needs |
|---|---|---|
| Paper trader | strategy over live quotes → SQLite ledger → "[Execute] [Skip]" approval tree → wings P&L (paper only, by design) | none |
| CI medic | red GitHub run → pull log → agent diagnoses → "[Rerun] [Open PR]" via `gh` | none (better with AGENT, NOTIFY+) |
| Download janitor | fs.watch ~/Downloads → classify → propose moves → one-tap approve | none (better with AGENT) |
| Package tracker via clipboard | `pbpaste` poll → tracking number detected anywhere → quiet parcel wing (loudly opt-in: clipboard) | none |
| Dependency sentinel | releases/CVEs for your lockfile → agent changelog summary → "[bump + test]" branch | none (better with AGENT) |
| Flight tracker | drop/capture a boarding pass → agent extracts flight → OpenSky live position → delay pings | INTAKE, AGENT |
| Inbox triager | mail source → agent classifies → only real interruptions surface → drafts reply for approval | AGENT, APPLE (send), NOTIFY+ |
| Meeting shepherd | calendar sense → pre-meeting brief → auto-join at T-0 → nudge for notes after | APPLE |
| Screen-time coach | frontmost app + idle time → gentle wing nudges ("Slack: 47 min") | APPLE (or `Bun.$` osascript) |
| **"Point the notch at anything"** | the generalization: drop/capture any artifact → agent turns it into a monitor (boarding pass → flight, receipt → package, listing → price watch) | INTAKE, AGENT |

Capability build order (each unblocked the next tier): APPLE + NOTIFY+
(existing spec debt) → AGENT → INTAKE. **No grant UI**, by decision: apps are
trusted local code (spec §6) and macOS TCC already prompts — attributed to the
shell, which is the process the user recognizes. The token question AGENT raises
is answered by shape rather than by a dialog: one turn per app at a time, refused
rather than queued while busy, so a runaway monitor cannot quietly spend in a
loop.

## Wave 1 — committed

| app | what it proves | APIs |
|---|---|---|
| Chess (stockfish.js, fallback engine) | big panel, interactivity, background compute | META |
| Stocks grid (2×3 live cards, keyless API) | live HTTP, charts | none |
| Tetris | imperative draw at frame rate, keyboard | DRAW |
| Alarm | multi-state views, notifications, self-expand | WING, CHROME |
| Deals live (scrapes books.toscrape.com) | cheerio scraping, notify-on-hit | none |
| Ledge Aviary 🐦 (boids perch on the notch, scatter on attention) | wings + draw + attention as pure delight | WING, DRAW |

## Wave 2 — living things & tiny theatre

| app | notes | APIs |
|---|---|---|
| The Ledge Cat 🐈 | sleeps on the warm notch; pupils/tail track CPU load (`Bun.$ sysctl`/`top`), stretches on idle (`ioreg` HIDIdleTime), stares at you in hour three | WING (canvas) |
| The Landlord | tiny resident hangs signs off the ledge: "disk 92% full", "4 PRs need review" | WING (canvas), DRAW |
| The Overseer 👁 | a usually-closed eye where the camera lives; pupil dilates with CPU, squints on low battery; unsettling on purpose | WING (canvas) |
| Merge-Conflict Boxing 🥊 | stick figures brawl on the notch while CI is red / PR has conflicts; stops when you fix it | WING (canvas), DRAW |

## Wave 2 — the real world, mapped onto the ledge

| app | notes | APIs |
|---|---|---|
| Overhead ✈️ | real aircraft above you (OpenSky anonymous + IP geolocation) cross the wings at true heading/speed; hover for callsign + destination | WING (canvas), DRAW |
| Weather diorama | actual rain falls in the notch when it rains outside; snow accumulates on the ledge; pill flashes on nearby lightning (Open-Meteo, keyless) | WING (canvas), DRAW |
| Moon ledge 🌙 | tonight's real moon phase as a sliver at the pill's edge; nearly nothing, exactly enough | WING (canvas) |

## Wave 2 — body & time

| app | notes | APIs |
|---|---|---|
| Breathing ledge | box-breathing pacer: the pill itself swells/contracts at breathing pace; no UI, peripheral-vision sync; doubles as a spring-system torture test | WING (width) |
| Departures 🚉 | calendar as a Solari split-flap board, letters flipping mechanically; missed meetings clack to DEPARTED | DRAW |
| The Hourly Contraption | a Rube Goldberg run plays across the notch on the hour; a cuckoo clock for people who ship software | DRAW |
| Inbox tide 🌊 | the notch fills with water as unread mail accumulates; clearing it drains the tide (IMAP count or mailbox file) | WING (canvas), DRAW |

## Someday — needs `ctx.peer`

| app | notes | APIs |
|---|---|---|
| Pigeon post 🕊 | a pigeon flies across a friend's screen into their notch carrying your note; the reply comes back the same way; would sell the peer API by itself | PEER, WING, DRAW |

## Stretch utilities

| app | notes | APIs |
|---|---|---|
| Teleprompter | paste text, it scrolls at reading pace through the wings while you present | WING (text) |
