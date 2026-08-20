# Ledge interface flow

Five states, one body of glass. Companion to `principles.md`.

## States

Six states, five surfaces: the wing (ambient), the **notification** (the
interruption's swell), the **summary** (the hover's swell), the panel (visit),
the window (parked).

- **Resting** — the bare notch.
- **Ambient** — an app holds a wing: glyph, ticker, meter, or fixed-slot
  canvas. Nothing interactive beyond click-to-visit.
- **Summary** — *deferred by ruling (2026-08-15): implemented in the shell
  but dormant — no app declares one, so hover ≥ Th always opens the Visit.
  The UX confused more than it glanced; revisit later.* The design as
  ratified: the hover's glance surface — the notch swells and shows the
  focused session's declared summary. App-declared and optional; always
  shows a quiet open affordance; fixed geometry; retracts on pointer exit.
- **Interruption** — the notification: the notch swells downward and outward.
  The cutout is an exclusion zone — nothing renders behind it; the payload
  sits below it. One row — glyph, one line, at most one action.
  Auto-retracts. Alerts queue; never two notifications.
- **Visit** — the expanded surface. Below.
- **Parked** — the whole surface torn off as a floating window, fixed size.
  The notch sits bare; clicking it, or the window's ⌃, flies the surface home.
  Notifications swell from the parked window's top edge; wings pause.

## Transitions

| from | on | to |
|---|---|---|
| Resting | wing granted | Ambient |
| Resting / Ambient | notification arrives | Interruption |
| Resting / Ambient | hover < Th | a small promissory swell, nothing more |
| Resting / Ambient | hover ≥ Th | Summary (Visit if the session declares none) |
| Resting / Ambient | click | Visit |
| Ambient | holder idle > Ta, or released | Resting |
| Summary | click anywhere | Visit |
| Summary | pointer exit | whence it came |
| Interruption | click the action | the action runs |
| Interruption | click elsewhere | Visit (owning session) |
| Interruption | timeout Ti (alert-class holds until acted) | whence it came |
| Visit | `<\|>` or horizontal swipe | walks the strip |
| Visit | drag the panel down off the notch | Parked |
| Visit | click outside, or Esc | Resting |
| Visit | pointer away > Texit | Resting |
| Parked | ⌃, or click the bare notch | Visit (flies home) |

**⌃⌥Space** is the keyboard's pill click, and the one way in that needs no
pointer: it opens the visit from anywhere, over a full-screen app, from any
state above. It lands on the session holding a live recording when there is
one and on whatever you were last in when there is not — a preference, not an
order. Pressed again it closes, because a key that only opens strands exactly
the user it exists for; the one exception is a visit of *another* session while
a recording runs, where the key is a jump to the recorder rather than a way
out. Parked, it flies the window home instead of opening a second surface — the
window may be on another desktop, and the strongest reading of the key is "put
Ledge in front of me". A visit opened this way has the pointer nowhere near it,
so **Texit waits for the pointer to arrive once** before its absence may close
anything; until then Esc, a click outside, and the key again are the ways out,
and all three are deliberate.

Knobs, feel-tuned on device: **Th** ≈ 0.1 s (below it, the notch swells a
breath — a promise, not a surface) · **Ti** ≈ 6 s for ambient-class,
alert-class holds · **Ta** holder-declared · **Texit** ≈ 0.3 s of pointer
fully away, and the timer never runs while the pill or the app holds the
keyboard, during a drag, or while a tool is running. Closing does not lose
the visit: reopening restores the session *and* its mode — a walked-away
chat comes back as that chat.

## The strip

- The visit surface is a strip of **sessions**. An app is what a session may
  put on stage; a session with no stage is just a conversation.
- The right wing `<|>` walks the strip; a horizontal swipe does the same.
  Walking past either end lands on the blank slot — at most one blank exists,
  and it IS the end: walking outward from it bounces in place instead of
  wrapping (G2.7). An **overflow bead** `⋯` sits beside `<|>`, popping a
  native menu: Pop Out · Settings… · Quit Ledge. It replaced the bare
  tear-off bead at G4 — the shell grew three chrome verbs and a bead per verb
  would have crowded the wing, while a menu holds them without widening it.
  Pop Out is still the park drag's clickable invitation; the drag itself also
  starts from any island, and the parked window hides the bead (a window
  cannot pop out of itself).
- Zoom out to the overview — **the ledge**: sessions as a grid of square
  glass cards that swell toward the cursor; the blank slot is a dashed card,
  last. Click jumps; the only ✕ in the product lives here, riding the hovered
  card's corner. Trigger: the `|` divider, or ⌂. While the ledge — or the
  chat — is up, the left island is a single **‹ Back**: the exit from either
  full-panel surface is the app, and the control says so. (The shelf-of-slabs
  specimen retired at G2.5; the lit-zone split on chat/ledge at G2.6.)
- Width is per-session, floored at the islands' span; blank slots take the
  default. Wings never move.

## Visit modes

- **Stage** — the app full-size, opaque, interactive. The left wing lowers
  the glass.
- **Chat** — the transcript pane over the stage. The stage is always inert
  here: it hot-reloads in view, but the pane arrests every event. Collapsing
  the transcript (the pill's ⌄) only clears the view to watch; Done is the
  way to touch. Keyboard: in chat it is always in the pill; in stage mode and
  the parked window, the app holds it.
- The prompt pill: ⊕ attach · grows to three lines · ⌄/⌃ transcript toggle.
  It sits on the clearest glass.
- At rest only the last exchange lingers; scroll reaches everything older.
  Scrolled back, the stage recedes (dim, blur) and a jump-to-latest control
  appears.
- Tool activity is ephemeral — a shimmer while it runs, gone when it's done.
- A blank slot has no stage: chat only, no glass toggle. First launch opens
  here.
- General conversations never receive the Ledge apps directory as cwd; only
  a deliberate builder session does.

## Wings, minis, arbitration

- Below visit: any running session may request a wing or a notification; the
  shell grants. Priority: **alert > live activity > ambient**; ties go to the
  most recent request; a user pin beats all; a preempted holder is restored
  when the winner ends. One holder per wing; one notification at a time.
- In visit: wings are Ledge's controls only — left: glass toggle (Back while
  the overview shows; none on a blank slot), right: `<|>`.

## Edges

- **Alerts** — urgency is ink, never geometry: the holder's content turns red
  and pulses twice on arrival, then holds. Silhouettes never change.
- **Errors** — no raw error ever reaches the glass. One generic card,
  everywhere: a glyph, one line, one action — Reload — which restarts the
  entire host. Worst case is a fresh visit.
- **Settings** — a native macOS window; configuration doesn't belong on
  glass. Triggers: the wing's `⋯` bead; right-click any Ledge glass → native
  menu (Settings…, Quit Ledge); ⌘, during a visit.
  Shaped like the platform's own since G4: a **sidebar of pages**, not one
  scroll of rows. **General** (the hotkey, launch at login, and Quit — with
  no Dock icon and no menu-bar item there is nowhere else for it) ·
  **Apps** (every installed app and its switch) · **Onboarding** · then one
  page per app that declares `meta.settings`, drawn as real AppKit controls
  from the declaration alone. No control is optimistic anywhere in this
  window: a change goes to the host and the control moves when the catalog
  comes back, so Settings and the ledge can never disagree.
- **Onboarding** — the macOS permission rows, and a **page of the Settings
  window** rather than a surface on the notch (G4). First run opens the
  window on it, once ever, marked on presentation rather than on completion.
  The notch never grows a permission card: onboarding is furniture, and a
  window can hold a scroll bar, real focus and seven rows without negotiating
  with a ceiling. It is the shell's own surface either way — no app can raise
  it, and the request that asks is refused from every app, always.
- **Notchless displays** — the shell synthesizes the seat: centered,
  menu-bar height, notch-width. Every law applies unchanged, the exclusion
  zone included — one layout for every display.
- **Drop / intake** — deferred by decision (2026-08-14); designed last.

## Material

- Everything is the notch's black glass. The stage is opaque. The chat
  surface runs opaque at the top to clear at the bottom; the prompt pill sits
  where the glass is clearest. Bubbles float above all UI.
