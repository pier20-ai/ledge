# Ledge Shell

The Swift half of the platform (`docs/design/spec.md`): the notch surface, the
protocol client, and the AppKit renderer. There is no scripted demo mode left —
**every panel below the cutout exclusion row is a host-rendered tree**, or one
of the shell's own built-in cards.

## Run

```sh
cd /Users/admin/workspace/ledge/shell
swift run LedgeShell
```

Plain launch binds `~/.ledge/ledge.sock` and listens; the Bun host connects
(spec §1). `--socket <path>` overrides it — always use that for tests, or a run
will fight (and on exit unlink) the socket of whatever Ledge you already have
running.

With no host connected, the shell is fully usable: the collapsed pill, the
promissory swell, click-to-open, `‹|›`, and a quiet **"Waiting for host…"** card
in place of an app's tree.

## What the shell draws, and what apps draw

- **Shell chrome:** the notch shape and its fillets, the **cutout exclusion row**
  and the two controls in it (the glass toggle and `‹|›`), the chat pane's
  glass, the **[+]** surface, the crash card (§7), and the waiting-for-host
  card. Chrome surfaces always draw at the shell's own default width, even when
  the app behind them asked for another one.

### Chat mode (§8, flow.md "Visit modes")

`.chat(app:)` is the transcript pane **over the session's live stage**, not
another page. Three layers, and each one is where it is for a reason:

- **The stage stays mounted.** `ChatSurfaceView` keeps the app's own composite —
  the same view stage mode shows — in a well at the top of the pane, dimmed to
  .92 and scaled to .96, still rendering and still hot-reloading.
- **The pane arrests every event.** The stage is inert, period: collapsing the
  transcript (⌄) only clears the view to *watch*; Done is the way back to
  touching it. The transcript's web view covers the whole pane, and the well
  refuses hit tests on its own account, so the arrest survives a layout change.
- **The glass is the panel body.** Chat runs opaque under the notch to nearly
  clear at the pill (`ShellSurfaceView.BodyMaterial.chatGlass`, the values in
  `LedgeGlass.chat`), painted into the silhouette the surface already owns so
  the fillets and the bottom radius fade with it. The shadow gets an inverse
  mask in that mode — a shadow visible *through* the body would make the clear
  end read as dirty.
- The transcript covers the whole pane rather than a box below the stage, and
  is told how much room the stage takes (`{ event: "stage", inset }`). That is
  what lets history slide *under* the stage's bottom edge as it scrolls away.

- The page is built from `editor/` at the repo root by `scripts/build-editor.sh`
  into `Sources/LedgeShell/Resources/editor/` and loaded with `loadFileURL` +
  a read-access directory. Strict CSP, no network at runtime.
- **One web view, reused across sessions.** There is one panel, so there is one
  conversation; switching sessions is a `thread` message on the bridge.
- The bridge (`EditorBridge.swift`) is a separate type from the view because
  everything worth asserting about it — normalisation, queueing, app filtering —
  cannot be tested through a live `WKWebView` in `swift test`. See
  `Tests/LedgeShellTests/EditorBridgeTests.swift` and `editor/README.md`.
- **Chat is the second place the shell takes key focus** (the first is a
  focusable canvas), and in chat the keyboard is *always* in the pill — a
  focusable canvas behind the pane is never given first responder. The panel is
  a non-activating `NSPanel`, so taking key steals the user's insertion point;
  `NotchPanelController` gives it back on close, deliberately and reversibly.
- **Esc is one step**: it closes the visit, exactly as flow.md's Transitions
  table says, because chat is a mode of the visit and not a sheet over it. The
  page forwards it explicitly (`{type:"escape"}`) rather than trusting WebKit's
  responder chain, and keeps one exception — while a turn is running, Esc
  interrupts the turn and never reaches the shell.
- The `chat` and `newApp` snapshots show the **native** half only (the glass and
  the reduced stage): a web view has nothing to draw until its content process
  has painted, which never happens in a synchronous headless render. Use
  `scripts/snapshot-editor.swift --stage N --size WxH` for the transcript layer.

- **App content:** everything else. The mockups' headers are app-specific
  (`Now Playing` / `Spotify`, `Deal Watch` / `3 tracked`) and nothing on the wire
  carries them, so they are part of the app's tree — but they no longer live at
  the top of the panel, because the top of the panel is the camera. Panel height
  is the tree's fitting height plus the 42 pt strip **plus the exclusion row**,
  clamped to `maxPanelHeight`.
- **The header row is gone; the exclusion row replaced it.** The expanded panel
  reserves a row as tall as the hardware cutout and mounts the app's tree below
  it, so an app that renders a top row can no longer draw under the camera. The
  shell fills the left zone with the app's catalog name and the right zone with
  the *Edit with AI* affordance; an app may take the **left** zone with a
  `<wing side="left">` node (spec §5 — see protocol/README.md, "panel wings",
  and keep it separate from the §3.3 collapsed wings, which are a different
  surface with a different owner).
- **The ✦ chat toggle** lives in that right zone now, as a real toggle: *Edit*
  (wand) is transparent while the app's tree is on screen, and *Preview* (eye)
  now the **glass toggle** — a `bead` in the cutout row's left zone reading
  **Apps** while the stage is up and **Done** while the editor is. A genuine
  build outcome pulses the panel once in green or red without turning a
  permanent control into a status light.
- **There is no bottom app strip.** flow.md has no bar in it, so `AppBarView`
  is gone and the two entry points its death orphaned have new homes: **[+]** is
  the strip's blank slot, and Settings is a right-click on any Ledge glass.

## Presentation state (`LedgeShellCore/ShellState.swift`)

```swift
enum ShellPresentation {
    case collapsed              // the idle pill over the hardware notch
    case expanded(app: String?) // an app's tree; nil → the built-in placeholder
    case chat(app: String)      // that app's chat surface (§8) — shell chrome
    case newApp                 // the strip's blank slot   — shell chrome
    case mini(app: String)      // the notification swell (wire name; §5 `mini`)
    case summary(app: String)   // the hover's summary swell (§5 `summary`)
    case permissions            // the first-run permission card
    case overview               // the ledge: the strip as slabs on a shelf
}
```

`ShellState` adds exactly one piece of memory: `lastPresentedApp`, so clicking
the collapsed pill reopens the app you were last using. App ids are runtime
strings (a directory name, spec §2) — the shell has no built-in app list, and the
**session strip** (`LedgeShellCore/SessionStrip.swift`) is built from the host's
`catalog` snapshot and nothing else (§3.6): `enabled` filters, `order` sorts, and
one blank slot sits at the end of the ring so walking past either end lands on
the same one. Settings is no longer pinned; it is a session like any other.

## Interaction

The whole model is flow.md's six-state Transitions table, implemented as a pure
value type in `Sources/LedgeShell/InteractionMachine.swift`. The panel controller
owns the timers and turns the machine's effects into presentations; nothing else
decides what a gesture means.

- **Hover below Th** (0.35 s) swells the notch a few points and ticks the
  trackpad — a promise, not a surface.
- **Hover past Th** shows the session's `<summary>` if it declared one, and opens
  the visit directly if it did not (principle 8: a heavy visit owes a summary; a
  light one is its own summary).
- **Click** — the pill, a wing, a summary, or a notification anywhere but its
  action — opens the visit. Hover never opens the panel.
- **Close** on a click outside, Esc, or 2.5 s of the pointer fully away. That
  timer **never runs** while anything holds the keyboard, while a drag is in
  flight, or while the editor is up (`ExitInhibitor`).
- **The `|` between `‹` and `›` opens the ledge** — the strip zoomed out, one
  glass slab per session standing on a shelf hairline, the blank slot as a
  dashed slab (`OverviewSurfaceView`, design.html §04). Slabs rise toward the
  cursor on the mockup's own gaussian falloff; hovering one reveals the **only
  ✕ in the product**, which stops that session (an `appControl` envelope, spec
  §4.3, landing on the host's existing disable path — the app stays installed).
  The left wing reads **Back** while it is up, and Esc means Back before it
  means close. It is a *mode of the visit*, not a seventh state.
- **Dragging Ledge's own glass downward past 40 pt parks the surface**: the
  whole body tears off the notch into a borderless `ParkedWindow` under the
  pointer, the notch goes back to a bare pill, and wings pause. Everything keeps
  working inside the window — walking the strip, chat, the ledge — and
  notifications swell from *its* top edge instead of the notch's. The ⌃ at its
  top-right, or a click on the bare notch, flies it home on `LedgeMotion.travel`
  (a fade under Reduce Motion). Nothing passive takes it away: no walk-away
  timeout, no click-outside, no Esc.
- **`‹|›`, or a horizontal swipe across the visit**, walks the session strip.
  Same code path; the panel morphs between heights *and widths* in one gesture,
  and the two controls never move, because they are anchored to the cutout.
- **Right-click any Ledge glass** (not an app's content well) for Settings… and
  Quit Ledge; ⌘, does the same during a visit, when the panel holds key.
- **There is no menu-bar item.** Toggling expansion is what the notch itself is
  for, and quitting is a row at the bottom of Settings (`ctx.platform.quit()`,
  answered by this process). `LSUIElement` means no Dock icon either, so that
  row is the only quit there is — it arms on the first press and quits on the
  second.
- **Keyboard** goes to a `canvas` that asked to be `focusable` (spec §5): when
  the presented app has one, the shell hands it first responder so §4.1 `key`
  events flow the moment the panel opens. That is the *only* case where the notch
  takes key focus — a panel with no game never steals the user's insertion point.
- **Swipe** horizontally across a *collapsed* surface: on the pill it becomes an
  id-0 `swipe` event for the app that owns the wing (skip a track, dismiss a
  timer — the app decides), on a mini it puts the peek away, and an idle pill
  has no addressee so nothing happens. The expanded panel is untouched: it
  scrolls, and a shell that read those flicks as swipes would give every list a
  second meaning. Policy is in `SwipeRecognizer` (28 pt of travel, 1.5× more
  horizontal than vertical, once per gesture, momentum ignored); who a swipe is
  *for* is `NotchPanelController.handleSwipe`, because that is presentation.

## Displays without a notch

The surface is anchored to a cutout rect — so on an external monitor or a
pre-notch Mac, the shell **synthesizes** one rather than special-casing the
screen: 210 pt (a real notch's width, clamped on a narrow display) by the menu
bar's height, floored at 32 pt so a wing's content still fits, centred in the
menu bar. `NotchMetrics.isSynthesized` says which kind you have and the startup
log line names it; everything downstream — wing clamps, the mini's floor, the
panel's exclusion row — already took an arbitrary rect and needs no branch.

Which display gets the surface is `NotchScreen`: **a notched screen wins**, and
with none, the **primary** screen (index 0, the one that owns the menu bar).
Deliberately not `NSScreen.main`, which follows the key window — the window
frame only moves on screen-configuration changes, so a policy that depended on
where the user last clicked would relocate the whole shell for reasons they
could not see.

Feel tunables live in `Sources/LedgeShell/Theme.swift`: `LedgeInteraction`
(Th / Ti / Ta / Texit, and the promissory swell's few points) beside
`LedgeMotion` (the two spring characters and the four roles). The window itself never animates — it is a fixed transparent
panel and the black shape morphs inside it on springs, which is what keeps
open/close smooth. Its size is no longer the old fixed 520 × 440: it is computed
per screen from `PanelLimits` to hold the biggest shape the surface can morph
into (the widest panel the screen allows, the widest winged pill, the tallest
panel, plus shadow slack), and it is set only on screen-configuration change —
never during a gesture.

## Panel size (spec §5, extended)

440 pt is still the default width and an app that declares nothing is pixel-for-
pixel unchanged. An app *may* declare `meta.panel = { width, maxHeight }`, which
rides in the catalog (§3.6) and lands here as a **request**:

- **width** clamps to `[320, screen max]` — the screen max is
  `min(640, screen width − 160)`.
- **maxHeight** clamps to a screen-derived cap: ~70 % of the usable height. That
  cap is also what `hello.screen.maxPanelHeight` reports, replacing §5's flat
  480 pt placeholder — an app that reads the cap and asks for exactly it must
  actually get it.

`PanelLimits` (next to `NotchMetrics`, both measurements of the display rather
than preferences) owns all of it: the clamps, and the window size derived from
them. Panel *height* is still measured, never declared — **content fit**: the
tree's fitting height plus the cutout exclusion row and nothing else, clamped to
the app's `maxHeight`.

## Wings (spec §3.3 extension, §8)

The collapsed pill is a surface an app can own. A `chrome` request with a `wing`
puts a label in the left wing, a canvas strip in the right one, or simply asks
for a total width (see `protocol/README.md` for the wire shape). Geometry lives
in `ShellSurfaceView.wingExtents`; it is the same shape morphing on the same
`.morph` spring the panel uses, and the promissory swell stays additive on top,
so a pacer updating width at 10 Hz and a cursor arriving at the notch never
fight. In a *visit* the wings are Ledge's own controls instead (flow.md), and an
app has no say in either zone.

Three things worth knowing before editing wings:

- **The collapsed shape is anchored to the hardware cutout, not centred on its
  own width.** The cutout is a hole in the display: it does not move, and nothing
  drawn under it is ever seen. `WingBarView` therefore lays its content out as
  `[left wing | cutout | right wing]`, and `shapeRect` has to agree — a pill
  centred on itself sits off by `(left − right) / 2`, so a wing with a label and
  nothing beside it (an alarm's countdown: the everyday case, and the maximally
  asymmetric one) draws half the label behind the camera. That was a real bug;
  `WingGeometryTests` asserts the label and the strip stay on their own side of
  `hardwareCutoutRect`, and `wings-text.png` is the picture of it. The expanded
  panel *is* centred — it has no wings.
- **Wing bounds are hard, not hints.** The strip is the menu bar's height and its
  middle is opaque hardware, so content that overruns doesn't look wrong, it
  vanishes. `WingBarView.layout` clamps both wings to what is left beside the
  cutout and the label to the strip's height; a label wider than its wing
  truncates with an ellipsis rather than running on.
- **Arbitration is presentation state, so it is Swift's** (`NotchPanelController`).
  One notch, one wing: the newest app to ask takes it, and a release only counts
  from the app that holds it. The host releases an app's wing on every lifecycle
  transition; the shell drops the wing on disconnect with everything else scoped
  to the dead generation.
- **Wing content is decoration and must never eat the click that opens the
  panel.** The label and the canvas strip live in a container that returns `nil`
  from `hitTest`, which is the whole reason `WingBarView` exists.

## Images (spec §5 `image`, §3.4 `image` op)

An `image` node's `src` is either an SF Symbol (`sf:<name>`) or an **absolute
file path**, and canvases get an `image` draw op that can blit one cell of a
spritesheet (`sx/sy/sw/sh`, in image pixels from the top-left) — see
`protocol/README.md` for the wire shape. Both go through `LedgeImageStore`:

- **One decode per path, process-wide**, shared by every canvas and every node,
  bounded at `capacity` entries with the oldest evicted. A spritesheet is
  megabytes decoded, and the key is a string an app chooses.
- **Misses are cached too** — a path that doesn't resolve is the normal case for
  a half-written app, and re-`stat`ing it every frame costs what a hit costs.
- **A file that changes is picked up**, revalidated against its modification time
  at most once a second per path. Regenerating a spritesheet while the shell runs
  must not need a restart; a 60 Hz blit must not need a decode.

Magnified sprites are drawn with interpolation **off** and shrunk pictures with
it on — a blown-up pixel sprite that gets smoothed is just blur. Op space is
y-down (§3.4) but `CGContext.draw` is y-up, so `drawImage` flips about the
destination rect; getting that wrong is silently upside-down art, which is what
`ImageRenderingTests` generates a marked sheet to catch.

Per-app exit policy is gone with the preview catalog: every surface auto-closes
on hover-out. The `catalog` envelope carries no such field, and inventing one
client-side would have made the shell the source of truth for something the host
owns. A `meta`-declared policy can bring it back on the wire.

## Capabilities the shell executes (spec §6)

Three things an app cannot do from its own worker, because macOS attributes
consent to the process the user can *see* — which is this one. They arrive as
their own envelopes (`protocol/README.md`) and are handled by `CapabilityHost`, a
**separate delegate** from the renderer: none of it draws anything, and the
snapshot replay runs a real engine with no capability host at all (requests are
answered "unsupported" rather than left hanging).

- **AppleScript / Shortcuts** (`AppleExecutor`) — `NSAppleScript` on a serial,
  off-main queue. Off-main because an Apple event into another app can block for
  seconds and the notch must keep animating; **serial** because concurrent
  `NSAppleScript` execution fails with OSA −1751 (found by running the tests in
  parallel). Results convert best-effort to JSON: booleans, numbers and lists
  keep their shape, everything else arrives as the string AppleScript would
  print. Shortcuts run `/usr/bin/shortcuts run <name>`, with input piped through
  `-i -`.
- **Notifications** (`NotificationPresenter`) — `UNUserNotificationCenter` when
  running from a bundle, which is the only way to get **action buttons**
  ("[Execute] [Skip]" is the entire agentic approval loop). Unbundled — `swift
  run`, `swift test`, the smoke test — `UNUserNotificationCenter.current()` traps
  on a nil bundle identifier, so the presenter *detects* that and falls back to
  `osascript -e 'display notification …'`: text still shows, buttons don't exist.
  A pressed button goes back as `notifyAction`; a click on the body reports the
  action `default`; a dismissal reports nothing.
- **Screen capture** (`ScreenCaptureExecutor`) — `/usr/sbin/screencapture`,
  `-i` for interactive region select, into a PNG in the shell's temp directory.
  **The first capture raises the system's Screen Recording prompt, attributed to
  Ledge** — that is the reason it runs here rather than in the host. Cancelling
  is a failed result, not an empty file. Ledge never deletes the PNG: the app
  that asked may still be reading it.

There is no Ledge-side grant UI for any of this, deliberately (spec §6 trust
model): apps are trusted local code and TCC is the consent layer, so a second
dialog in front of the system's own would only teach people to click through
both.

## The drop shelf (INTAKE)

Files dragged onto the **expanded** panel become an app-level `drop` event —
an ordinary §4.1 event at id 0 — for the app on screen. `ShellSurfaceView`
registers itself for `.fileURL` drags; nothing inside it registers, so AppKit
walks up to the surface from whatever the cursor is over. A drag is accepted only
while expanded *and* with an app actually presented: with no addressee, refusing
keeps the Finder's own drop feedback honest. The affordance is the panel's
existing accent stroke around its own outline, faded in for the drag — no new
chrome. The collapsed pill is 210 pt of hardware notch, far too small a target to
aim at, so it is not a drop zone.

## Snapshots

`scripts/snapshot-demos.sh` renders every demo app plus the chrome surfaces —
including `overview` (the ledge, with the cursor planted on the second slab so
the rise is in the picture), `parked` (the torn-off window, with a real app's
tree inside it) and the winged pill, whose strip is painted by real §3.4 draw ops (`wings`
carries a label, a canvas strip and a spritesheet cell; `wings-text` is the
label-only shape) — to PNGs, end to end:

```
app.jsx --(bun, real reconciler)--> commit JSON --(swift, real engine+renderer)--> PNG
```

Nothing is scripted: `host/scripts/dump-commits.ts` renders an app once through
the reconciler and writes its §3.1 mount batch, and `LedgeShell --snapshots
<out> --commits <dir>` replays those batches through `ProtocolEngine` →
`ProtocolRenderer`. A snapshot that looks right is therefore evidence about the
protocol path, not about a mock.

## Verify

```sh
cd /Users/admin/workspace/ledge/shell
swift build && swift test
../scripts/e2e-smoke.sh          # three-process pipeline over a temp socket
../scripts/snapshot-demos.sh     # PNGs of every demo app + chrome surface
```

## AppKit traps this code is shaped around

Worth knowing before editing — each is a real bug that was hunted down:

- **Tracking areas go stale.** Enter/exit pairs lie when a view moves under a
  stationary cursor (which the panel does constantly, as it morphs), so the
  pointer is always resolved against the live `NSEvent.mouseLocation`, never
  against the event that woke us (`evaluatePointer`).
- **Implicit layer animations.** Anything touching a layer outside an intended
  animation runs inside `CATransaction.setDisableActions(true)` — otherwise a
  slider knob eases toward the pointer instead of tracking it, and every commit
  cross-fades.
- **Layer-backed views anchor at (0,0).** A bare scale transform collapses a
  button toward its corner; `setPressScale` translates first.
- **NSTextField top-aligns** whenever its frame is taller than its text, so
  every pill/badge routes through `CenteredTextBox`.
- **NSTextField under-reports its intrinsic width** for a truncating label, so a
  label sized to its own string renders "$214…". `LedgeText` measures the string
  itself, and clears the default bezel that eats a couple of points at draw
  time.
- **Setting `font` does not invalidate the cached intrinsic size**, so a node
  created at the default size and then configured to `xl` lays out at the old
  width — the renderer invalidates explicitly.
- **NSStackView's `.width` alignment ties with content hugging**, and the tie
  resolves to "intrinsic width, pinned to the *trailing* edge" — every bare
  label silently right-aligns. Vertical stacks use `.leading` plus explicit
  priority-500 width constraints instead.
- **`draw(_ dirtyRect:)` is not a clip.** Drawing code must respect `bounds`,
  not the dirty rect, or partial redraws lose content.
