# Ledge Shell

The Swift half of the platform (`docs/design/spec.md`): the notch surface, the
protocol client, and the AppKit renderer. There is no scripted demo mode left —
**every panel above the app strip is a host-rendered tree**, or one of the
shell's own built-in cards.

## Run

```sh
cd /Users/admin/workspace/ledge/shell
swift run LedgeShell
```

Plain launch binds `~/.ledge/ledge.sock` and listens; the Bun host connects
(spec §1). `--socket <path>` overrides it — always use that for tests, or a run
will fight (and on exit unlink) the socket of whatever Ledge you already have
running.

With no host connected, the shell is fully usable: the collapsed pill, hover
open/close, the strip, and a quiet **"Waiting for host…"** card in place of an
app's tree.

## What the shell draws, and what apps draw

- **Shell chrome:** the notch shape and its fillets, the 42 pt app strip (spec
  §8), the **cutout exclusion row** and its two panel-wing zones, the chat
  surface, the **[+]** surface, the crash card (§7), and the waiting-for-host
  card. Chrome surfaces always draw at the shell's own default width, even when
  the app behind them asked for another one.
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
- **The ✦ chat toggle** lives in that right zone now, as *Edit*. It is also
  still a gesture: **clicking the presented app's icon in the strip toggles its
  chat**, and the icon stays lit while the chat is open (§8).
- **The app strip scrolls.** Ten demo apps already overrun a 440 pt panel, and
  the first two controls an overflowing row pushes off the end are exactly the
  two you want when a strip has overflowed — **[+]** (how you add app eleven) and
  Settings (how you turn app ten off). So the icons live in an overlay-scroller
  `NSScrollView` and those two are its siblings, with a fixed safe gap between
  them. The scroll area only takes the width it needs, so a strip that fits is
  laid out point-for-point as it was before the scroller existed.

## Presentation state (`LedgeShellCore/ShellState.swift`)

```swift
enum ShellPresentation {
    case collapsed              // the idle pill over the hardware notch
    case expanded(app: String?) // an app's tree; nil → the built-in placeholder
    case chat(app: String)      // that app's chat surface (§8) — shell chrome
    case newApp                 // the [+] surface (§8)     — shell chrome
}
```

`ShellState` adds exactly one piece of memory: `lastPresentedApp`, so hovering
the collapsed pill reopens the app you were last using. App ids are runtime
strings (a directory name, spec §2) — the shell has no built-in app list, and
the strip is built from the host's `catalog` snapshot and nothing else (§3.6):
`enabled` filters, `order` sorts, `sf:` prefixes are stripped off icons, and the
app id `settings` is pinned to the far right rather than shown among the others.

## Interaction

- **Hover** the notch for 0.20 s (or click it) to open the last app; the
  collapsed pill grows slightly and ticks the trackpad on hover so it reads as
  alive before it opens.
- **Move away** from the open panel and it closes after a 0.40 s debounce, so
  overshooting the edge doesn't cost you the panel; Esc closes immediately.
  Clicks outside the black shape pass through to whatever is beneath.
- **The strip** switches apps — the panel morphs between heights *and widths* in
  one gesture — and re-clicking the current app opens its chat.
- The menu-bar item has exactly two commands: toggle expansion, and quit.
- **Keyboard** goes to a `canvas` that asked to be `focusable` (spec §5): when
  the presented app has one, the shell hands it first responder so §4.1 `key`
  events flow the moment the panel opens. That is the *only* case where the notch
  takes key focus — a panel with no game never steals the user's insertion point.

Feel tunables live at the top of `Sources/LedgeShell/ShellSurfaceView.swift`:
`HoverPolicy` (open/close delays, hover slop) and `Spring` (open/close/morph
response + damping). The window itself never animates — it is a fixed transparent
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
them. Panel *height* is still measured, never declared — the tree's fitting
height plus the 42 pt strip, clamped to the app's `maxHeight`.

## Wings (spec §3.3 extension, §8)

The collapsed pill is a surface an app can own. A `chrome` request with a `wing`
puts a label in the left wing, a canvas strip in the right one, or simply asks
for a total width (see `protocol/README.md` for the wire shape). Geometry lives
in `ShellSurfaceView.wingExtents`; it is the same shape morphing on the same
`.morph` spring the panel uses, and the hover bump stays additive on top, so a
pacer updating width at 10 Hz and a cursor arriving at the notch never fight.

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
including the winged pill, whose strip is painted by real §3.4 draw ops (`wings`
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
  stationary cursor (which the panel does constantly, as it morphs), so hover is
  always resolved against the live `NSEvent.mouseLocation`, never against the
  event that woke us (`syncHover`, `evaluateHover`).
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
