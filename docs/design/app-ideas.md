# Ledge apps — launch & later

The idea inbox. Two lists; add freely to Later, promote deliberately to Launch.
Tags: **APPLE** (`ctx.apple`) · **AGENT** (`ctx.agent`) · **DRAW** (§3.4 frames) ·
**WING** / **MINI** (ambient surfaces) · none = plain HTTP, timers, `Bun.$`.
No sprites anywhere except chess's grandfathered set (principle 12). The old
demo apps were archived to `protocol/demo-apps-archive/` in the design reset —
they predate it and are reference only. `protocol/demo-apps` now holds three
small **exercise** apps (timer, radio, beacon) plus Settings, whose whole job is
to make the interaction machine feel-testable on device; carrying one of the
archived apps forward means rewriting it against the principles, not restoring
the folder.

## Launch

### Ships in the app

| app | job | signature | needs |
|---|---|---|---|
| **Chess** | carried over | the sprite set (grandfathered) · big-panel proof | DRAW |
| **Tetris** | carried over | frame-rate draw + keyboard proof · score is a bare number | DRAW |
| **Now Playing** | what's playing; skip/pause without switching apps · owns the resting pill | the live waveform in the wing | APPLE, WING |
| **Weather** | the sky, glanceable; drag the ruler to time-travel | the pane: drops that refract the scene, fog that wipes clear, light that swings with the real sun | DRAW, canvas drag (0001-A1), Open-Meteo |
| **Focus** | timers and gentle alarms; calm by construction | the display numeral + the mini swell — the design doc's own specimen | WING, MINI, notify |

Weather pane notes (the "how it feels real"): simulate the glass, not the
weather. Droplets are lenses — sharp, inverted, squeezed copy of the blurred
scene inside each, specular dot, merge-and-run with shed micro-drops; cold +
humid fogs the pane and runs wipe clear tracks; sun is directional light
computed from real time + location (the scrubber's payoff); snow sticks,
melts, and accumulates along the well's bottom edge; lightning is a full-pane
flash. Scene is a pure function of `(t, weather(t))`; scrub eases back to now.

### Built live on X

| app | job / hook | signature | needs |
|---|---|---|---|
| **Breath** | mindfulness: Box, 4-7-8, Nadi Shodhana; gentle break pings on your cadence | the notch is the pacer — pill swells at breath pace; Nadi Shodhana tints the mini's left/right half for the held nostril | WING (width), MINI |
| **Overhead** | real aircraft above you cross the wings at true heading/speed; click for callsign | "wait, it's *real*?" — bare triangles + trails | DRAW, WING · adsb.lol / airplanes.live (keyless), OpenSky fallback |
| **Screen-time coach** | frontmost app + idle time → quiet nudges | the wing ticker everyone feels attacked by: "Slack · 47m" | WING · `Bun.$` osascript/ioreg |
| **Departures** | your day as a split-flap board — theatre is the job in this tier | staggered per-character flips, type only, amber data · Reduce Motion swaps flips for fades | DRAW or text, APPLE (calendar read) |
| **CI medic** | red run → agent diagnoses → mini offers Rerun | the alert system + agent story on stream | AGENT, MINI, notify · demo mode polls a big OSS repo unauthenticated (`oven-sh/bun` — on brand; 60 req/hr is plenty); real users connect `gh` |

## Later

**The bell genre** — a bell for a thing you care about, rung as a mini.
Reliable feeds only; Elon Bell itself is parked (X read API is paywalled,
scraping is ToS-hostile and brittle):

- **Launch bell** — rocket launches: T−minus wing during countdown, liftoff
  mini with stream link (Launch Library 2, free). The Elon-adjacent one.
- **Quake bell** — USGS GeoJSON feed; the notch literally shakes with
  magnitude (Reduce Motion: red pulse instead).
- **HN bell** — your keyword/story hits the front page (Algolia HN API, free).
- **Whale bell** — outsized on-chain moves (blockchain.com websocket, free).

**Kept from the old backlog** (changed where noted):

- **Status board** — GitHub / Claude API / OpenAI status via their Statuspage
  JSON (keyless). A wing dot that is only visible when something is red.
  Natural swap-in for CI medic on stream week if wanted.
- **Paper trader** — bench alternate for the five; approval-tree drama,
  paper-only by design.
- **Package tracker via clipboard** — `pbpaste` poll; quiet parcel wing
  (loudly opt-in: it reads the clipboard).
- **Download janitor** — fs.watch ~/Downloads → classify → one-tap moves.
- **Dependency sentinel** — releases/CVEs for your lockfile → "[bump + test]".
- **Moon ledge** — too sparse for promo, the right size for real life.
- **World clock** — city rows; its scrubber idea moved to Weather.
- **Teleprompter** — paste text, it scrolls through the wings at reading pace.
- **The Hourly Contraption** — a Rube Goldberg run on the hour; expensive,
  gloriously pointless.
- **Inbox tide** — the notch fills with unread mail; needs Mail access
  posture first.
- **Calendar peek** — calendar returns someday as a *peek*, never a ticking
  countdown (Next Up retired for anxiety).
- **Inbox triager / Meeting shepherd** — APPLE+AGENT; parked with calendar.
- **Flight tracker from a boarding pass** — parked on the drop/INTAKE design.
- **Pigeon post** — PEER, someday; still the app that would sell the peer API
  by itself.

**Retired with the sprite direction:** Shelf, Focus Garden, Night Sky, Ledge
Cat, Landlord, Merge-conflict boxing, The Overseer (too weird — ruled
2026-08-14). Aviary remains as a fixture only.
