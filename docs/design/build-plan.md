# Ledge build plan — the reset system

Supersedes the v2-era plan. Spec: `principles.md` + `flow.md` + `design.html`
+ `app-ideas.md`. Built by Opus agents phase by phase; Manu feel-tests at the
gates. Written to be picked up in a fresh session.

## Conventions that bind this repo (carried, hard-won)

- **Protocol changes are fixture-first.** Add to `protocol/fixtures/` and make
  both suites replay the same corpus before writing renderer code.
- **The apps root is authoritative for React resolution.** Absolutise at the
  edge; two React copies is a silent crash outside the tested path.
- **New apps require a host restart** — the registry scans at `bindSession`.
- **Any view whose size the shell asks for must be pinned on all four edges.**
- **`@MainActor` classes handing callbacks to system frameworks must mark them
  `@Sendable`** — traps only appear in the bundled `.app`.
- Host tests run per-file (`bun run test`, `scripts/test-stable.sh`); Bun
  1.3.9 segfaults ~50% on full single-process runs.

## Already landed in the working tree (verified 2026-08-14, uncommitted)

Canvas drag (`ProtocolCanvasView.swift:82-150`), gradient fills (wash +
canvas op), notchless pill (`NotchMetrics.isSynthesized`, `NotchScreen`),
swipe gestures (`SwipeRecognizer` + routing), focus observe
(`PlatformSystemSources.swift:436+`). All fixture-backed. Weather's platform
prerequisites are therefore complete. Commit before Phase F lands on top.

---

## Phase F — foundation (chrome + infra, no app code)

### F1 · Token consolidation — **DONE 2026-08-15** (one Opus run with F2; 392 shell tests green; shadow ramp named swell/panel/window; panel shadow numbers deliberately changed to the ramp — flag at G1)
**What:** one source for every chrome value. Theme gains: shadow ramp
(`mini/panel/window`, replacing the three literals at
`ShellSurfaceView.swift:979-982`), motion tokens (springs `pop`/`settle` +
durations fast .18 / move .38 / travel .56 — re-expressing the private spring
set at `ShellSurfaceView.swift:252-260`; keep today's feel, change the
source), bead material (fill gradient stops + edge shadows, consumed in F2).
Type ramp moves out of `ProtocolRenderer.font` (`:851-874`) into Metrics and
gains `display` 36 / `hero` 48 / `weight: light` / `caps` (+6% tracking) —
protocol addition, so: spec §5 row + fixture + both suites first.
**Done:** no shadow/spring/type literal outside Theme/Metrics; new ramp
renders; all tests green; zero visual change except the new sizes existing.
**Risk:** low.

### F2 · Beads & control restyle — **DONE 2026-08-15** (landed with F1: bead/ghost variants, LedgeRowView, LedgeEmptyState, generic error card wired to a real `HostProcess.restart()`; wing control pair itself lands with F3/F4)
**What:** the two-tier control law. `LedgeButton` gains a `bead` variant
(convex: top specular, under-shadow, brighten on hover, sink on press);
ghost treatment for app-content glyph buttons (pure white, larger, capsule
only under cursor); the wing control pair (glass toggle + `‹|›`) as a
reusable component; `ErrorCardView` becomes the generic card — glyph,
"Something broke.", one bead **Reload Ledge** that restarts the host; never
a stack trace.
**Done:** component gallery renders beads/ghosts per design.html §06; error
card matches §10; tests pin the bead metrics.
**Risk:** low-medium (LedgeButton has many call sites).

### F3+F4 · The state machine, chrome, strip & settings — **IN PROGRESS 2026-08-15** (one Opus run)
**What:** the six-state machine ratified in `flow.md` §Transitions (this
supersedes the earlier "click-only visit" wording):
1. **States** Resting / Ambient / **Summary** / Interruption / Visit (+ a
   seam for Parked). Knobs beside `LedgeMotion`: Th .35 s, Ti 6 s
   (alert-class holds), Ta holder-declared, Texit 2.5 s. Hover < Th =
   promissory swell only; ≥ Th = the session's declared **summary** (new §5
   node, fixture-first, shell-drawn ⌄ affordance) or straight to Visit if
   none. Visit closes by click-outside / Esc / pointer-away > Texit with
   hard suspensions (keyboard focus, drag, editor showing). `HoverPolicy`
   delays/grace/slop and `hoverBumpWidth` deleted.
2. **Renames:** mini → **notification** (wire keeps `mini`); notification +
   summary are the **swell** family — continuous silhouette, down-and-out,
   cutout exclusion, pop/settle, `LedgeShadow.swell`. Swipe-to-dismiss and
   pill-swipe-app-events removed (principle 9: click + strip-swipe +
   park-drag only).
3. **Chrome:** bottom `AppBarView` deleted; `PanelWingBarView` becomes the
   bead control pair — left "Apps/Done" toggling editor↔stage (interim glass
   toggle), right `‹|›` walking the strip (installed apps + one blank slot →
   `.newApp` editor). Right-click any Ledge glass → native NSMenu
   (Settings…, Quit Ledge); ⌘, in visit. Settings unpinned from the strip.
**Done:** transitions-table test walks every row; both suites green; no
pointer-exit collapse outside Texit; no bottom bar.
**Risk:** high — survey risks #1, #3, #5. 

**Gate G1 (after F3/F4): Manu feel-tests on the real notch** — hover
promise → summary → visit ladder, Texit feel, swell springs, strip walking,
the changed panel shadow. Screenshots lie about exactly these. Also the
commit decision for the whole tree.

**Gate G1 verdict (2026-08-15):** hover promise + shadow good; strip beads
work. Defects → **F2.1** (in progress): swipe-walk dead in visit; right-click
menu dead; `‹|›` must be ONE split bead, not two buttons; bar gets a constant
width with controls at its OUTER edges (they hugged the cutout — felt wrong
live; design.html §01 was right all along). Root confusion: no demo app
declares `<summary>`, so the no-summary→visit rule fired on every hover and
read as "click is broken." **NO COMMITS until Manu regains confidence — his
explicit ruling.** Next feel test only after C+D.

## Phase S — the split (revised per G1)

**S1 (done):** archive ALL of `protocol/demo-apps` →
`protocol/demo-apps-archive` (settings stays — privileged + menu target);
write three new exercise apps against the new laws: **timer** (summary +
wing meter + alert w/ action), **radio** (no-summary→visit case + wing
canvas), **beacon** (both notification classes, Ti vs alert-holds).
Fixtures promotion and cleanup happen later, after C+D, when the keepers are
known. A summary is declared by RENDERING `<summary>` in the app tree —
presence is the declaration; it is a component, not meta config, because a
summary is live content.

### F2.2 · Platform fixes surfaced by writing the exercise apps (S1 report) — **DONE 2026-08-15** (461 shell tests; `commit-align` + `chrome-wing-meter` fixture pairs replayed by both suites; `Center` helpers deleted from all three apps; timer's wing is `meter: { value }`)

Queued after F2.1 lands (same files). Principle 16: every app was paying
these individually.

1. **`align` vocabulary mismatch — silent bug.** `applyAlign` switches on
   `start/center/end`; spec §5 and the JSX types say
   `leading/center/trailing`, which silently no-op. Accept the spec words
   (keep the old ones as aliases), fixture it.
2. **`align="center"` is a no-op for text in v-stacks** — `syncFillWidths`
   stretches non-hugging children, so all three exercise apps grew identical
   `Center` helpers (spacer/text/spacer). Make text obey stack alignment.
3. **Wing meter has no wire form** — flow.md enumerates
   glyph/ticker/meter/canvas but `WingSpec` is `{text,width,canvas}`; every
   meter is hand-drawn differently. Add `meter: {value}` to the wing.
4. **Docs:** monitor's 1 Hz spin floor is the API's biggest trap (all three
   apps fell into it) — REFERENCE.md monitor section must say so, with the
   `setInterval` + parked-promise pattern; also document that a
   notification's action is just a `<button>` in the `<mini>` and the shell
   retracts the swell itself (the obvious wrong guess is calling
   `ctx.collapse()`); and that the peek `class` and the mini's content are
   two things the app keeps in sync.

### F2.3 · Platform fixes surfaced by building Now Playing (D1 report) — **DONE 2026-08-15** (481 shell tests; ghost on wire + adopted by nowplaying/timer/radio; image stroke; `ctx.reduceMotion` on lifecycle w/ re-send on change + on start; snapshot `--props`/`--wing`; sweep clean. The G3 leftover — ghost glyphs brighter but not BIGGER — is closed: `iconOnlyPointSize` is per-variant now, 18 for a ghost and 14 for chrome.)

Before/with D2–D4 — each remaining app pays these otherwise.

1. **Ghost variant on the wire — the biggest Phase D gap.** §06's app-control
   law is unreachable: `LedgeButtonVariant.ghost` exists but
   `ProtocolRenderer.variant` maps no wire string to it. Add
   `variant="ghost"` (fixture-first); bead stays shell-only.
2. **`image` gets a `stroke`** — a letterboxed sleeve erases the well's
   frame; double-wrapping in a stroked stack double-frames it.
3. **Reduce Motion must reach apps** — principle 10 is unobeyable from a
   canvas app today; add it to `onLifecycle` (or an env/ctx flag) so meters
   and waveforms can go still.
4. **Snapshot harness**: `--props '<json>'` on dump-commits (every
   data-driven app pays a throwaway-preview ritual — D1 had to plot its
   waveform with PIL) and a `--wing` mode that replays the app's first
   `ctx.wing`/`ctx.draw` into the pill surface (D1's *signature* was
   unreviewable).
5. Sweep: D1 left `'data' declared but never read` in nowplaying/app.jsx and
   possibly an undeleted preview.jsx — remove at the G3 polish pass if not
   sooner.

## Phase D — default apps (one at a time, each screenshot-reviewed)

1. **Now Playing** — **DONE 2026-08-15** (`protocol/demo-apps/nowplaying`): wing
   waveform (7 eased bars, seeded per track) held as live activity and released
   on stop; guarded `ctx.apple` transport for Music.app/Spotify; no summary, no
   notification; empty state is one glyph and one line. Needs a live player at
   G2 — snapshots only prove layout.
2. **Weather** — **DONE 2026-08-15** (`protocol/demo-apps/weather`): the pane as
   a pure `paneOps(t, weather(t))` op list (sky from real solar position,
   droplet lenses, runners, snow rim, fog wipes, lightning), a drag-scrubbable
   24 h ruler that eases home on release, `<summary>`, an ambient temp wing, no
   notification; Open-Meteo + ip-api cached in the app folder. The snapshot
   harness cannot show a *panel* canvas (it replays wing draws only), so the
   pane itself needs a live look at G2.
3. **Focus** — **DONE 2026-08-15** (`protocol/demo-apps/focus`): §01's Stage
   panel at its own 336 pt — eyebrow, `display` numeral as its own preset
   control, two ghosts on that row, a shell-drawn `<progress rate>`; one
   alert-class peek serving both zero and a single daily alarm (one row that
   cycles 6:30 → 9:00 → Off); preset + alarm persisted beside `app.jsx`.
   Meter was ink where §01 shows accent — both reasons given at the time have
   since gone: `progress` has a semantic `color` (G3) and the meter is now
   `color="accent"`, and a panel canvas is no longer invisible to the snapshot
   harness (G3) either. Platform defect found here and fixed at G3: an `sf:`
   `<image>` ignored a `src` **update** — `ProtocolRenderer.configure`'s
   `.image` case only re-applied `LedgeFileImageView`, so a swapped glyph
   silently kept the old symbol, and the app worked around it with a React
   `key`. Both keys are gone.
4. **Chess + Tetris chrome diet** — **DONE 2026-08-15** (`protocol/demo-apps/{chess,tetris}`, rebuilt out of the archive; engines copied verbatim, every box around them cut): chess is a 482 pt board well, one line ("e4 · your move") and two ghosts (↺ new game, ↩ take back — flip has no job when you are always White), with the Stockfish `info score` now parsed out of the same search so `<summary>` can read "your move · +0.8"; tetris is the well, a bare 36 pt `display` numeral with `lv 6` beside it, one ghost, and the next piece drawn inside the well instead of in a second framed canvas. `chess.js` + `stockfish` are back at the apps root and the 239 MB → 7 MB stockfish prune is restored in `scripts/bundle-app.sh`. Reduce Motion audited in both: neither had any decorative motion to switch off (no piece slide, no clear flash), so neither reads `ctx.reduceMotion` — stated in the headers so the next reader does not have to re-derive it. The G3 `sf:`-src bug never bit either app (it was `<image>`-only, and a `<button icon>` has always updated in place via `button.apply(symbol:)`); it is fixed now regardless, and both headers say so.

**Gate G2: Manu tests each app as it lands.**

## Phase C — the conversation (after D; needs the agent adapter)

### C1 · Chat mode, the presentation — **DONE 2026-08-15** (481 shell tests, 326 host)

The pane over an inert, hot-reloading stage: `ChatSurfaceView` (native stage
well at .92/.96 + the transcript web view over the whole pane + the hit-test
arrest), `ShellSurfaceView.BodyMaterial.chatGlass` (the §01 `.glasspanel`
gradient, painted into the body's own silhouette so the fillets and the bottom
radius fade with it), and the page rebuilt to §08 — violet/cyan bubbles,
ephemeral shimmer, three pill states, top-fade scrollback with jump-to-latest,
recede-on-scrollback driven over the bridge. **Esc is one step** (flow.md's
table has one row for it); the page keeps the running-turn interrupt. Evidence:
`chat.png` / `newApp.png` in a snapshot run, plus `scripts/snapshot-editor.swift
--stage N --size WxH --transparent|--draft|--collapsed` for the transcript
layer. Still stubbed: whatever the bridge's backend is — C1 is presentation only.

Friction it left:

1. **Token sync across the file:// boundary.** `editor/src/editor.css` restates
   design.html's product tokens by hand — the page cannot import them (no
   fetch under the CSP, and a bridge round trip in front of first paint is
   worse than the duplication). Two constants now have to agree in *three*
   places: the pane's 14 pt top pad (`ChatSurfaceView.topPad` ↔ `.pane`
   padding) and the pill's 62 pt room (`ChatSurfaceView.pillRoom` ↔ the pill's
   margin + height + padding). Worth a generated `tokens.css` emitted by
   `scripts/build-editor.sh` from a single source at G3.
2. **No backdrop blur behind the clear glass.** design.html's `.glasspanel`
   carries `backdrop-filter: blur(12px)`; the panel body does not. It needs an
   `NSVisualEffectView` masked to the body gradient, and a masked vibrancy view
   under a non-activating panel is a combination that has to be judged on
   device, not in a headless render. Until then the bottom of the pane shows
   the desktop unblurred.
3. **⊕ attach is shape without behaviour** — intake is deferred by decision, so
   the control is drawn and disabled. It should not ship enabled-and-inert.
4. ~~**`AccentIconButton` is now orphaned**~~ — **deleted at G3**, along with
   `LedgeMetrics.sendDisc`, its only metric. Its one caller, the hand-drawn
   `NewAppContentView`, went with the rest of the mock chat.

### C2 · The rest

Session-first keying in the controller (risk #2); the ledge overview (slabs,
magnify, the only ✕); per-session width in the strip.
Depends on the Claude Code / Codex headless adapter (§8) — not yet built.
Parked (drag-to-park + the torn-off window + fly-home) also lands in this
phase, alongside the overview — all three share the surface-reparenting work.

**Gate G3: after D, a full visual-consistency + polish pass by the
orchestrator (Manu's standing request) before anything ships.**

**G3 fix batch — DONE 2026-08-15** (one Opus run; 527 shell tests, host
test-stable 29 files / 0 fail, full snapshot regeneration). Six of the queue's
items landed; the rest are marked below with why they did not.

- ~~**Shell bug:** `sf:` `<image>` ignores `src` updates.~~ **FIXED.**
  `LedgeSymbolView` gained the partial-update entry point its file-image twin
  always had (`apply(symbol:radius:)`) and `configure`'s `.image` case now
  branches on both kinds instead of `guard … as? LedgeFileImageView`. A src that
  changes *kind* is still a different component: a bare path arriving at a
  symbol node is ignored rather than drawn. Fixture: the existing
  `commit-app-controls` pair gained a symbol swap (`sf:waveform` →
  `sf:waveform.badge.mic`), replayed by both suites. Focus's two React `key`
  workarounds are gone, and chess's and tetris's "SF DEFECT" headers now say
  the opposite.
- ~~Ghost glyphs: brighter but not bigger.~~ **FIXED.** `iconOnlyPointSize` is
  per-variant: `LedgeMetrics.iconOnlyPointSize(variant:)` gives a ghost 18 and
  everything else 14. `LedgeButton.apply` had to learn that a *variant* change
  can change the glyph's size, not only the empty/non-empty label line — an
  icon-only ghost demoted to plain rebuilds at 14. Visible in focus/timer/radio
  PNGs beside the 36 pt numeral.
- ~~`<progress>` has no hue prop.~~ **DECIDED: give it one.** `progress.color`,
  semantic tokens only (`accent`/`green`/`red`/`violet`/`cyan`), default ink —
  the five hue families `gradient` already uses, and deliberately *not* the ink
  shades, which are type colours. Wired through ShadowTree type-check, renderer
  (`ProtocolRenderer.meterColor`), `LedgeProgress.applyColor`, the JSX types,
  protocol/README §5, REFERENCE.md, and the `commit-rate` fixture pair (which
  gained a second bar so both "asks for a hue" and "asks for nothing" are on
  the wire, and the update both deletes one and adds the other). Focus's meter
  is `color="accent"`, as design.html §01 draws it. §01 stands.
- Editor `tokens.css` generated by `build-editor.sh` (C1: tokens restated by
  hand in three places). **NOT DONE — no light-touch version exists.** The
  editor's tokens are already one `:root` block in `editor/src/editor.css`;
  splitting it into a generated `tokens.css` would make it two files, not one
  source. The duplication C1 actually named is Swift `Theme.swift` ⟷
  `design.html` ⟷ this CSS, and collapsing *that* means generating annotated
  Swift from a token file — a real codegen step with a real build order, not a
  cleanup. Also: the bundle must stay self-contained (an `@import` is a runtime
  fetch the CSP refuses), so the generated file would have to be concatenated
  in, and the dev loop would then read a different file from the build. Waiting
  for a reason bigger than tidiness.
- Swell has no snapshot surface — `<mini>`/`<summary>` reviewable only via
  commit JSON; extend SnapshotRenderer. **Still open** (the `draws` work below
  is the other half of the harness; this one was not in the G3 batch).
- REFERENCE.md monitor section: a float prop defeats commit dedupe — quantise
  to display resolution (D3's 4 Hz→1 Hz lesson).
- Backdrop blur behind chat glass: NSVisualEffectView masked to the body
  gradient — judge on device at the gate.
- Orphans/lint: ~~AccentIconButton unused~~ **deleted** (and `sendDisc`, its
  only metric, with it); ~~stray unused vars in app.jsx files~~ **swept** — a
  scan of every `app.jsx` and app module found exactly one, focus's
  `onLifecycle(phaseName, …)`, now `_phase`; `weather/console.log` is a
  gitignored runtime artifact and stays; weather/scenes.ts no longer exists.
  ⊕ attach stays visibly disabled until intake — **still open**.
- Stomp check: REFERENCE.md + snapshot-demos.sh after concurrent D2/D3/D4
  edits (D3 reports its merge with weather's rows coexists correctly —
  re-verify once D2 and D4 land).
- ~~**Harness (from D2, priority):** panel canvases are invisible to
  snapshots.~~ **FIXED, and it is the batch's biggest win.** `CommitDump` gained
  `draws` — every canvas the `--wing` capture window painted, keyed by node id
  — and `SnapshotRenderer` replays them as `draw` envelopes through the real
  engine + coalescer *after* the panel has been laid out (a canvas rasterises
  into a buffer the size of its own `bounds`, so a frame injected before the
  measure is dropped in silence). Two details earned their keep: the frames are
  matched against **every** commit rather than the mount batch, because a
  monitor that calls `ctx.update` re-renders the app and weather's pane only
  exists on the second render; and the later frame per canvas wins, which is
  the shell's own coalescing rule and gives a settled picture rather than a
  first paint. `snapshot-demos.sh` needed no new flag — it already passes
  `--wing` for every app. Evidence: with `draws` stripped, chess's board is a
  black square, weather's pane and ruler are absent entirely, timer's meter
  line and radio's equalizer are missing. The scratchpad rasteriser was
  **outside** the repo (a session scratchpad, not `scratchpad/paneshot.swift`
  in the tree) — deleted there; nothing in the repo referenced it.
- Canvas op vocabulary (from D2, platform proposals for after G3): panel
  canvases get a `chromeless` prop (the auto `sunken` mat makes two framed
  regions — §09 violation waiting to be visible); `text` op wants
  weight/mono/align; radial gradient + clip ops would halve Weather's op
  budget. Log-only until an app is blocked.
- ~~h-stack stretches children apart.~~ **FIXED, narrowly, and the rule is now
  in spec §5.** A row **places** its children — side by side at its leading
  edge, leftover width left over — under three conditions: it was *stretched by
  a column* (its width is imposed, so there is slack to mis-spend), it holds no
  `LedgeColumnFilling` child (spacer/divider/chart/slider/progress/input — the
  column rule's own exception, in the same words), and it did not ask for
  `distribute="equal"`. Mechanically it is `NSStackView.gravityAreas` instead
  of `.fill`; the row's *own* width never changes, so list rows, cards, washes
  and press targets are untouched.
  Two things were tried and rejected on evidence: making the row hug its own
  content (broke scrolling list rows, which must span their column —
  `PagesTests`), and applying `.gravityAreas` unconditionally (`.gravityAreas`
  does not give a stack a content-driven fitting width, so Radio's and
  Beacon's centred rows slid to the left of a suddenly panel-wide row). The
  third condition is what makes it safe. **Every other PNG in the snapshot set
  is byte-identical across the change** — no app in the tree depended on the
  stretch, because every row that would have been affected already carried the
  workaround spacer. Weather's is now removed and its row renders identically,
  which is the proof.
- Strays: ~~`weather/console.log`~~ — already gitignored (`.gitignore`,
  "Demo-app runtime artifacts"), left alone. Wing arbitration note from D2 —
  Weather re-asks only on degree change but "latest asker wins" still trades
  the pill with Now Playing; watch at the gate. **Still open.**
- **New, for the visual audit:** the ledge (`overview.png`) now overflows. Nine
  apps plus the blank slot no longer fit the shelf — the leftmost slab is
  clipped and the dashed `+` slot is off the right-hand edge. It appeared when
  chess and tetris landed (D4), not in this batch, and it is a real layout
  decision for the gate: scroll the shelf, shrink the slabs, or cap the strip.

## G6 · The panel has one width, and the islands hug its edges — **DONE 2026-09-08**

Manu, on device: the home/chat and ‹|› islands "look extremely weird" beside
the cutout — stationary, but anchored to nothing the eye can see. The finding
underneath it: the width was already frozen in practice. The visit bar floored
every session at cutout + 2 × 124, so on a 234 pt cutout every default app —
including the ones declaring 360 and 368 — rendered at 482, and the only thing
`meta.panel.width` could still do was go wider.

So the freeze is now stated (606 shell tests, 382 host):

- **`PanelLimits.defaultWidth` is 480 and is the panel width.** `width(requesting:)`
  clamps to `[480, screen max]`: an app may ask for *more* glass, never less.
  No default app declares a width; `chess`'s 482 became 480 by trimming its two
  coordinate gutters from 16 to 15, `blocks` and `nowplaying` simply dropped
  theirs (both were floored past them anyway).
- **The bar is the panel.** `visitBarRect` is the body's width, centred; the
  islands hug its ends at `panelWingPad` — the parked window's G2.9 layout is
  now the only layout, and `hugsEdges` is gone. The old constant reach survives
  as `visitFloorReach` (8 + 101 + 10 = 119): a floor that on every shipping Mac
  sits below 480 and never shows, kept so an unusually wide cutout widens the
  shape instead of colliding the islands.
- **Principle 8 rewritten**: "persistent controls stand still, because the
  panel has one width". The notch-anchoring was the *mechanism* for standing
  still; with one width the corners stand still too, and they frame the content.
- REFERENCE.md "Layout and size" and the `meta` row say 480 and call `width`
  the exception. Weather's pane grew from 412 to 452 (it was sized for the
  old 440).

Two parked-window defects surfaced on device the same day, both fixed with
tests (608 shell): the window was sized to the *panel's* height but spends
its own 6 pt top pad, so every parked app lost the bottom of its last line
(pre-existing — `ParkedSurfaceView.windowHeight(forPanelHeight:)` is now the
one sizing rule for both sizing sites and the snapshot renderer); and the
parked content host never clipped to the body (the chat pane's web view
paints an opaque square backdrop) — the host now carries the body's own
outline as a layer mask, the way the notch's `contentContainer` clips. That
was hygiene, not the corner defect Manu saw: **the window was exactly the
body's size, so the body's drop shadow was cut square at the window's edge**
— a hard grey block outside every rounded corner on any light desktop, there
since the first tear. Found by capturing the parked window through the
window server from a test and reading the corner's alpha (54: shadow, not
frost — the frost's mask is fine). The window now carries the notch window's
own `shadowMargin` (28) around the body: `ParkedSurfaceView.margin`,
`bodyRect`, `windowSize(forBody:)` / `bodyFrame(ofWindow:)`, and the
controller's every geometry question (the held corner, "at the notch",
settle, resize) is asked of the body frame. The margin hit-tests to nothing.
`SelfAdvanceTests.realTimerRuns` polls for the tick instead of sleeping a
fixed 150 ms (it failed ~1 in 3 under the parallel runner).

Watch at the next device pass: the open morph's arrival recipe (G2.4) was
tuned for islands arriving beside the cutout; from the corners it may want a
beat.

## Deferred by decision

Drop/intake design (last); Elon Bell (X API paywall); duo-mode wings;
`ctx.sprite.*` (rejected — image op + app-folder PNGs suffice).
