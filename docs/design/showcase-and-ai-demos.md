# Ledge showcase apps and Codex demos

This document defines the first-party apps that demonstrate why Ledge is enjoyable to keep running, followed by four live Codex demonstrations that show why Ledge is a platform rather than a fixed collection of widgets.

The showcase and the Codex demos have different jobs. Showcase apps should remain useful and rewarding after months of use. Codex demos are short, legible stories in which a specific request becomes durable software in front of the audience. The generated result should look like an ordinary Ledge app, not an “AI app.”

## The product bar

Every showcase app needs all five qualities:

1. **A recurring job.** It helps with something the user already does or cares about.
2. **A signature interaction.** It contains one device people can remember and describe.
3. **Accumulation or variation.** Another visit reveals history, mastery, growth, or a new performance.
4. **Background value.** It can notice an important change while another app is active and publish a bounded mini notification.
5. **A quiet default.** Delight cannot compromise legibility, trust, energy use, or the underlying task.

The eight apps below are the showcase set. They do not all need to be installed or enabled by default.

## 1. Now Playing — a generative performance

### Core job

Control the active Music or Spotify session and make track, artist, artwork, playback state, and position immediately available.

### Signature

Every track becomes a generative performance. The artwork supplies a stable **track genome** derived from its palette, luminance topology, edge direction, visual density, symmetry, and salient shapes. Every play supplies a new **performance seed**, so the song retains a recognizable visual identity while producing different textures and movement.

The performance follows four acts tied to playback position:

1. **Emergence:** forms and color fields establish the track's visual grammar.
2. **Development:** structures accumulate, interact, and become more complex.
3. **Disruption:** one rule changes near the musical middle or late passage.
4. **Resolution:** motion thins, converges, settles, or dissolves as the track ends.

Curl fields, branching paths, cellular growth, particles, Voronoi regions, and soft geometric masses are possible techniques, not effects to stack indiscriminately. A track should choose a small coherent grammar. Until Ledge has real audio features, the narrative must use playback position and duration rather than pretending to react to beats.

Artwork and metadata sit above the scene. Transport, volume, and scrub controls live in one translucent frosted dock with a uniform texture. Controls remain readable over every generated frame.

### Return loop

The same track produces a related but distinct performance on another listen. Albums and artists gradually become visually recognizable without repeating an exact animation.

### Background behavior

A mini may announce a new track, a newly available device, or a completed queue action. Ordinary progress updates stay in the wing and do not generate notifications.

## 2. Weatherglass — a window through time

### Core job

Show current conditions and make the hourly forecast understandable through direct manipulation.

### Signature

The panel is a wall containing three physical elements:

- A large window renders sky, light, cloud layers, precipitation, visibility, and shadows.
- A thermostat shows the temperature for the selected time, with the actual current temperature retained beneath it as `NOW 22°`.
- A prominent clock handle sits on a sunrise-to-midnight track beneath the window.

The user drags the clock, not the sky. Moving it changes the world outside and the selected forecast together. The handle protrudes from its track, the adjacent hour ghost-peeks on first open, and a temporary “drag time” label disappears after the first successful scrub. Releasing snaps to an hourly forecast. Clicking `NOW` returns to the present.

### Return loop

The window changes with real weather, daylight, season, and location. Scrubbing becomes a fast daily ritual rather than a hidden novelty gesture.

### Background behavior

Minis are reserved for useful transitions: rain starting, snow beginning, temperature crossing a chosen threshold, dangerous wind, or an unexpectedly clear evening. Routine hourly changes remain silent.

## 3. Departures — when should I leave?

### Core job

Turn departures, walking time, preferred station, direction, platform, disruptions, and the user's usual buffer into one actionable journey.

### Signature

Routes physically advance toward the notch as their leave time approaches. The wing shows the next useful instruction rather than a raw timetable. The panel explains the recommended journey, alternatives, and the reason for any change.

### Return loop

Saved stations and habitual routes make the app faster and calmer over time. It becomes a dependable part of leaving home or work.

### Background behavior

Publish a mini only when the answer changes: leave now, platform changed, service cancelled, connection at risk, or a substantially better route appeared. Minis should coalesce repeated provider updates into one human event.

## 4. Night Sky — the world above the notch

### Core job

Show the Sun, Moon, visible planets, twilight, rise and set times, and noteworthy conjunctions for the user's date and optional location.

### Signature

The notch is the horizon. Scrubbing time moves celestial objects across it, making the relationship between clock time and the visible sky tangible.

The app should calculate its core state locally from astronomical ephemerides instead of depending on a live tracking service. This preserves the wonder of the earlier Above concept without making the experience hostage to aircraft coverage or an unstable API.

### Return loop

The sky changes every night and becomes more meaningful as the user learns what is visible from their location. Saved events and a simple observation history can create continuity without turning the app into an astronomy database.

### Background behavior

Minis announce events that are both visible and timely: the Moon and Venus together after sunset, Jupiter clearing the horizon, the start of a lunar eclipse, or an unusually good viewing window. The user chooses which classes of event deserve interruption.

## 5. Focus Garden — accumulated procedural ecology

### Core job

Run focus sessions and turn completed work into a persistent place the user owns.

### Signature

The landscape begins as barren procedural terrain and grows through ecological succession. It is generated from the session ledger rather than saved as a collection of placed sprites:

- Domain-warped noise creates elevation, soil, and drainage.
- Cellular succession spreads moss, grass, and ground cover.
- Poisson-disc sampling gives plants believable spacing.
- Space-colonization or L-system growth creates shrubs and trees.
- Session duration and cadence supply growth energy, density, and structural complexity.

The ledger is the source of truth, so the landscape can regenerate deterministically. Real seasons may influence palette and growth behavior, but missed days never kill plants or erase progress.

### Return loop

Every session leaves a legible trace. Long sessions create structural growth; repeated shorter sessions create richness and density. Two users should never converge on the same landscape.

### Background behavior

The wing may show the active session. A mini appears when a user-controlled session ends or when a deliberately chosen break finishes. The garden never demands attention merely to protect a streak.

## 6. Chess — a living orthodox board

### Core job

Provide excellent local chess with clocks, legal move affordances, PGN import and export, daily positions, and optional post-move analysis.

### Signature

The rules remain orthodox. Character comes from physical response and memory:

- Captured pieces collect around the board.
- The previous move leaves a fading path.
- Check sends one restrained pulse through the surface.
- Player clocks can occupy the wings while the game is active.
- A compact post-game ribbon replays the shape of the game.

Engine assistance is opt-in and appears after a move or after the game. The default board does not continuously tell the user what to do.

### Return loop

Daily positions, saved games, local records, and replay make it worth returning without changing chess itself.

### Background behavior

In correspondence or asynchronous play, a mini can announce that it is the user's move. A local game produces no background notifications after the panel closes.

## 7. Tetris — intact mechanics, native physicality

### Core job

Provide a responsive keyboard-first Tetris implementation with Guideline movement, scoring, hold, preview, deterministic daily seeds, replays, and local records.

### Signature

The blocks remain immediately readable. Ledge supplies physicality around the game:

- Hold and next pieces occupy architectural bays beside the well.
- A hard drop creates a restrained compression response.
- A line clear ripples through the notch silhouette.
- A procedural background field evolves with level and stack pressure without obscuring the grid.

Effects confirm state; they never change timing, hide occupied cells, or modify piece behavior.

### Return loop

Daily seeds, personal records, and replay ghosts create durable competition while preserving the original loop.

### Background behavior

Tetris does not need background notifications. It demonstrates that the same platform can support a precise 60 Hz game without forcing every app into a monitor-and-mini pattern.

## 8. Shelf — a programmable physical filing system

### Core job

Watch user-selected folders and make recurring file operations visible, programmable, reversible, and trustworthy.

### Signature

Shelf is deliberately skeuomorphic:

- New files land on an inbox counter.
- Drawers represent destinations.
- Buckets collect related items.
- Trays hold pending decisions.
- Chutes perform transformations.

A file visibly travels through the rule that handled it. Opening a container reveals its matcher, action chain, history, receipts, failures, and undo.

Rules can match file name, type, source, size, date, or extracted metadata, then rename, unzip, convert, OCR, tag, route, archive, open, share, or expire the file. “Always do this” converts a completed manual action into a proposed rule. Intelligence may suggest a matcher or transformation chain, but the user reviews it before activation.

Ambiguous files remain on the counter. Destructive actions require approval. Destination collisions are previewed and resolved without silent overwrites. Undo should pull an item visibly back to the counter whenever recovery is possible.

### Return loop

The shelf becomes a personal machine assembled over time. Its layout is both useful state and an expressive portrait of how the user works.

### Background behavior

Minis appear when a rule needs a decision, fails, or completes something substantial. Routine successful filing stays quiet and accumulates in the container's receipt history.

## Rediscover — permissioned first-party lab

Rediscover remains outside the flagship eight until its trust model is as polished as its surprise loop.

The app resurfaces one forgotten photo or document at a chosen cadence and explains why it selected it: the same month in another year, a place revisited, an unfinished draft, or a project that disappeared from view. The user can keep, snooze, exclude, reveal in Finder or Photos, or remove the source from future consideration.

Photos and Documents must be separate capabilities. Prefer limited-library access and user-selected folders; index on-device; show exactly which sources and how many items are indexed; support exclusions and complete index deletion; and remain useful when only one capability is granted. Rediscover can join the showcase after Ledge proves those permission and deletion flows.

## Four Codex demos

### What the demos must prove

These are live or recorded demonstrations of Codex authoring for Ledge. They are not bundled AI products.

Every demo follows the same five beats:

1. The user states a concrete, personal desire.
2. Codex inspects one real source, command, file, or API.
3. The source changes visibly while the audience watches.
4. Ledge hot-reloads the result across the panel, wing, and mini where appropriate.
5. After a time jump, the generated app continues working in the background while another app is active.

A second natural-language edit should demonstrate that the app remains understandable and malleable. Avoid fake agent narration, generic chat interfaces, and ornamental AI badges. Runtime inference belongs in the result only when the task itself needs inference.

### Demo 1. One URL becomes a live app

#### Prompt

“Watch this source and tell me when this condition becomes true.”

#### Build

The user supplies a real JSON endpoint, feed, webpage, or local command. Codex inspects its shape, identifies the relevant value, and builds:

- A wing for the one ambient value worth seeing continuously.
- A panel with current state, history, source attribution, and threshold controls.
- A keyed mini for the condition the user described.
- A background monitor with an appropriate cadence and failure state.

#### Reveal

Change the source between recordings—a live match, product availability, sensor, public event, or local process—to prove that the integration was generated rather than prebuilt.

#### Platform proof

Arbitrary data source, settings, visualization, background execution, wing ownership, notification coalescing, and hot reload.

### Demo 2. Sunlight on my desk

#### Prompt

“When will direct sunlight reach this window, and will clouds block it?”

#### Build

The user supplies location and window orientation. Codex combines local solar geometry with hourly cloud cover and builds a small personal instrument:

- A diagram of the window, solar arc, and moving light patch.
- The next predicted direct-light interval.
- Controls for orientation, obstruction angle, and notification lead time.
- A future mini when the predicted interval becomes actionable.

#### Reveal

Change the window orientation and watch the prediction, diagram, and notification schedule update immediately.

#### Platform proof

Composition of unrelated data, procedural visualization, settings, local computation, and an outcome too personal for a conventional product roadmap.

### Demo 3. Teach Shelf once

#### Prompt

After completing a real file operation, the user says: “Always do this for client delivery zips.”

#### Build

Codex turns the example into a Shelf container with:

- An inspectable matcher.
- An unzip, rename, preview-generation, and filing chain.
- Destination and collision previews.
- A pending-decision tray for ambiguous inputs.
- Receipts, failure behavior, and undo.

#### Reveal

A second real file arrives while Chess is active. Shelf processes it in the background and publishes its independent mini without replacing Chess or borrowing its wings.

#### Platform proof

Scoped folder access, persistent rules, background execution, safe filesystem mutation, independent mini roots, and visible recovery.

### Demo 4. Make my desk ready

#### Prompt

“Make one control that gets my desk ready for a call.”

#### Build

Codex inspects the available local device or automation APIs and creates a reversible scene that can adjust examples such as lights, Focus mode, audio output, a timer, or another prepared device. The app contains:

- One primary `Start call` action.
- A clear preview of the operations it will perform.
- Live state for every controlled system.
- A complementary `Restore desk` action.
- Confirmation for anything disruptive or difficult to reverse.

#### Reveal

The audience watches the real environment change, then sees the control update from requested state to observed state. A follow-up request adds or removes one operation and hot-reloads the app.

#### Platform proof

Discovery of a local API, safe actions, real-world effects, reversible state, custom controls, and iterative authoring.

### What these four cover

| Demo | Primary capability | Why it matters |
| --- | --- | --- |
| One URL becomes a live app | Observe | Any changing source can become ambient software. |
| Sunlight on my desk | Synthesize | Codex can create software for needs too specific to package in advance. |
| Teach Shelf once | Automate | A demonstrated behavior can become a durable, inspectable standing order. |
| Make my desk ready | Control | Ledge can safely act on the user's world as well as display it. |

Together they demonstrate observation, synthesis, automation, and control. The recurring protagonist is the platform: Codex writes a small application, Ledge makes it immediate, and the result keeps working after the demo ends.
