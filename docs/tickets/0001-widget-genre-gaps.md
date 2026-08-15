# 0001 · Platform gaps: the widget genre (world-clock demo + Alcove parity)

**Status:** §A built (A1, A2, A3, A6, A7 — 2026-08-13); A4/A5/A8 parked as written below; §B awaiting Manu's go/no-go · **Created:** 2026-08-09 · **Source:** feature-mapping session against two reference apps — the Twitter world-clock notch widget and [Alcove](https://tryalcove.com) (v1.7, changelog reviewed 2026-08-09).

Everything both apps do that Ledge **cannot** do today, in two sections. §A is ordinary
platform/shell work on public APIs — schedule on merit. §B hinges on private APIs;
each item there needs Manu's explicit go/no-go before any code. Features *not* listed
here (calendar, weather, battery, reachability, Spotify/Music now-playing, peeks,
persistence, ticking clocks, circular icon buttons, ruler rendering via draw ops)
were verified buildable with the shipped vocabulary and are out of scope.

---

## §A — Public-API gaps (ordinary tickets, no ruling needed)

### A1. Canvas drag events — *unlocks the world-clock scrubber; highest reach* — **DONE**
`ProtocolCanvasView` handles `mouseDown` only: apps see a `click` with local x/y and
nothing else. Press-drag-release is invisible, so any scrub/knob/sketch interaction
is impossible.
- Emit `drag` events with phase (`down` / `move` / `up`) + local x/y, mirroring the
  click plumbing. Throttle `move` shell-side (~30 Hz) so a fast wiggle doesn't flood
  the socket.
- Fixture-first per protocol convention: new fixture pair in `protocol/fixtures`,
  replayed by both suites.
- Round-trip per point (UDS → worker render → commit) is a few ms — fine for scrub
  feel. If a future app needs better, that's what the stubbed `"use native"` path is
  for; don't build it for this.
- **Effort:** small (an afternoon incl. tests). **Proof app:** the world clock —
  everything else it needs already ships.
- **Shipped:** `onDrag` on `canvas` → §4.1 `drag` with `{phase, x, y}`, throttled
  to ~30 Hz shell-side; `down`/`up` exact, `up` carries the final point, points
  are not clamped to the canvas. Fixture pair `commit-canvas-drag.json` /
  `event-drag.json`, replayed by both suites. The proof app is still to build.

### A2. Swipe gestures on the collapsed pill / mini — **DONE**
Hover and click are the only gestures the shell recognizes. Alcove uses horizontal
swipes on the pill (skip track, dismiss). Same class of work as the hover machinery
in `ShellSurfaceView` (scroll-wheel deltas + gesture recognizers); semantics need a
small design pass — proposal: swipe on pill → app-level event (id 0, like
notification actions), swipe on mini → dismiss.
- **Effort:** small-medium. Watch the tracking-area gotchas already documented in
  memory (global `NSEvent.mouseLocation`, stale tracking areas).
- **Shipped:** the proposed semantics exactly — pill → id-0 `swipe`
  `{direction}` to the wing's owner, mini → dismiss, idle pill → nothing, and the
  expanded panel keeps its scrolling. Recognition (`SwipeRecognizer`) is 28 pt of
  travel, 1.5× more horizontal than vertical, once per gesture, momentum ignored.

### A3. Pill shape on notchless displays — **DONE**
The shell is notch-anchored; external displays and pre-notch Macs get nothing.
Alcove synthesizes a pill. Our fixed-window + layer-morph architecture doesn't care
where the cutout rect comes from — synthesize one (centered, menu-bar height) when
`safeAreaInsets` reports none. Wing clamps and mini floor math already take an
arbitrary cutout rect as input.
- **Effort:** medium (geometry is easy; multi-display policy — which screen owns the
  surface — is the real question).
- **Shipped:** `NotchMetrics.synthesized` (210 pt × menu-bar height, floored at 32 so
  a wing's content still fits, clamped on a narrow screen) with an `isSynthesized`
  flag the startup log names. Multi-display answer: **a notched screen wins, else the
  primary screen** (`NotchScreen`) — deliberately not `NSScreen.main`, which follows
  the key window and would relocate the whole shell on the next reconfiguration.

### A4. Multiple simultaneous live activities ("Duo mode")
Our presentation model is deliberately one mini at a time ("an interruption is not a
visit"). Alcove shows two compact activities side-by-side (e.g. music + timer). This
is a design question for the wing/mini layer, not a technical wall: the wing already
does always-on left/right; a "two half-width minis" mode would need arbitration
(who yields when a third asks?) and a width policy.
- **Effort:** medium, mostly design. Recommend deferring until a real app pair wants
  it — we have no second always-on app yet.

### A5. Volume/brightness HUD *display* (not suppression)
The `audio` observe kind already reports volume changes + reason. A HUD app that
peeks a volume bar on change is buildable **today** — except it would show alongside
Apple's bezel, which is silly. Display is app-land; *suppression* is B2. Park this
until B2 is ruled on.
- **Effort:** trivial app work, blocked on the B2 decision.

### A6. Focus-mode observe kind — **DONE**
No `focus` observe kind exists. Public-ish path: watch
`~/Library/DoNotDisturb/DB/Assertions.json` (the mechanism most third-party menu-bar
tools use — file format is undocumented but stable for years, and it's a file read,
not a private framework). Fits the existing observe-kind pattern (translated
vocabulary, signal + scalar payload: `{active, modeName?}`).
- **Effort:** small. Degrade gracefully if the plist format shifts (observe just goes
  quiet — same posture as the Yahoo-429 path).
- **Shipped:** `observe("focus", "changed")` → `{active, modeName?}`, fired
  immediately on registration and deduped after (that file is rewritten for more than
  mode changes). Two things found while building: the path is **TCC-protected**, so a
  Ledge without Full Disk Access reads nothing — handled exactly like a format shift,
  by emitting *nothing* rather than a false `active: false`; and the keys are searched
  for anywhere in the decoded JSON rather than walked to, so a re-nesting survives.
  Open question for later: whether Full Disk Access earns a row on the permission
  surface, which today lists only the five TCC kinds Ledge itself prompts for.

### A7. Gradient fills — **DONE**
Already on the known-deltas list (music album-art gradient). Two shapes: a `gradient`
token on stack/box fills, and/or a `gradient` canvas op. Unblocks the soft-wash look
half this genre leans on (Alcove's progressive-blur aesthetic approximated without
private CAFilter).
- **Effort:** small-medium. Spec §5 addition → fixture → renderer.
- **Shipped:** both shapes, split on who owns the recipe. `stack.gradient` is a
  **token** (`accent`/`green`/`red`/`violet`/`cyan`) rendering one standardized
  wash — hue at the top, transparent by 60% of the height, behind the children,
  composing with `fill` — so panels stay siblings; the `gradient` **draw op**
  (`x,y,w,h,from,to,angle?,radius?`, hex colours) is free-form, because canvas
  pixels are the app's. Note this deliberately does **not** implement design
  v0.3's D3 (`wash` taking a raw hex, dominant-artwork colour, `meta.accent`) —
  that wave is unratified, and its Q3 is exactly this token-vs-free-form call.

### A8. Canvas hover + scroll wheel (nice-to-have)
Tooltips/highlights over custom-drawn regions, and wheel-zoom on timelines. No app
blocked on either yet. Log-only: do not build until an app asks.

---

## §B — Private-API features (Manu's call required per item)

Alcove's own FAQ: *"relies on private APIs… could be modified or removed without an
alternative… sold as-is."* They eat that risk as their core product bet. For Ledge,
each item below should be an **isolated, degradable adapter** if adopted — never
load-bearing, feature vanishes cleanly if Apple moves. None of these should start
without an explicit go from Manu.

### B1. System-wide Now Playing (any app's media, not just Spotify/Music)
**Private surface:** `MediaRemote.framework`. Apple actively restricted it in
Sonoma 14.4; the ecosystem (boring.notch et al.) survives on workaround shims
(spawning an entitled helper). **Risk:** medium-high, actively contested by Apple.
**Value:** highest of the four — it's the difference between "a Spotify widget" and
"the Mac's now-playing surface." If any B item is worth it, it's this one.
**Shape if adopted:** a helper-process adapter behind the existing music-app
capability; our AppleScript path stays as the degradation floor.

### B2. System HUD suppression (volume/brightness bezel replacement)
**Private surface:** hijacking/killing `OSDUIHelper` so Apple's bezel never shows,
then A5 renders ours. **Risk:** medium (long-stable hack, but it's fragile
process-meddling and competes with anything else doing the same trick).
**Value:** high polish, pure cosmetics. **Note:** brightness *observation* also has
no public API on Apple Silicon (DisplayServices private calls) — volume-only HUD is
the honest public-API fallback.

### B3. Notification interception (mirroring system notifications into the notch)
**Private surface:** there is no read access to the notification stream; options are
the private usernoted database or accessibility-API scraping of banner windows.
**Risk:** high, plus a genuine privacy posture change (Ledge would read every app's
notifications — squarely against our "signal-only, never contents" pasteboard
precedent). **Value:** medium. **Recommendation as noted in session:** likely a
deliberate non-goal; our outbound UN notifications + app-level peeks cover the
Ledge-native equivalent.

### B4. Lock Screen widgets
**Private surface:** drawing above the lock UI requires elevated window levels and
lock-state detection that Apple does not offer; even Alcove's version is best-effort.
**Risk:** high. **Value:** low for Ledge (our surfaces are about the working session).
**Recommendation:** skip.

---

## Suggested order

1. **A1** (canvas drag) — small, unblocks the world-clock app end-to-end as proof.
2. **A7** (gradients) — small, pays rent across every app's look.
3. **A6** (focus observe) + **A2** (swipes) — rounds out Alcove parity in app-land.
4. **A3** (notchless pill) — when an external-display user shows up (or Manu's setup).
5. **§B** — a sit-down with this ticket and a coffee; B1 is the only one I'd argue for.

**Where it stands (2026-08-13).** 1–4 are built, in that order, each fixture-first
and covered by both suites. What is left, and deliberately so: A4 and A5 are parked
on their own terms (no second always-on app; blocked on the B2 ruling), A8 stays
log-only until an app asks, and §B still needs Manu. Two things the work surfaced
that are somebody's call rather than an implementation detail: **Full Disk Access**
for A6's focus reads (see above), and whether the world clock — A1's proof app —
gets built now or with the v0.3 design wave.
