# Ledge protocol fixtures

Golden frames shared by the Swift shell tests and the Bun host tests. Both
sides replay the same corpus so they agree on the wire format by construction
(spec: `docs/design/spec.md`).

## Framing (spec §1)

`uint32` little-endian byte length, then exactly that many bytes of UTF-8
JSON. Max frame 8 MiB. Read loop: buffer bytes; while buffer ≥ 4 and ≥ 4+len,
extract one frame. Byte-level cases (split writes, coalesced writes, oversize
length, truncated stream, invalid JSON) are constructed in each side's test
code from these payloads — the fixtures here are the JSON payloads only.

## Files

Each `.json` file is one envelope (spec §2) exactly as it would appear inside
a frame. Files prefixed `invalid-` must be **rejected** by the receiver with
the behavior named in the file's `_expect` key (that key appears only in
invalid fixtures; valid envelopes never carry underscore keys). For commit
fixtures, `_expect: "resyncRequest"` means the receiver discards the whole
commit and asks for a fresh one.

- `hello-host.json` / `hello-shell.json` — the opening exchange (§3.6/§4.3).
- `catalog.json` — full app list snapshot (§3.6). One entry (`chess`) carries the
  optional `panel` an app declares in its `meta`; the others do not, so both the
  present and absent cases are covered by every replay.
- `draw-frame.json` — one imperative canvas frame (§3.4), carrying an `image` op
  with a source rect (the spritesheet case, proposed below) and ending in an op
  the shell has never heard of: unknown ops must decode and then be skipped at
  draw time, which is what lets the op vocabulary grow without a version bump.
  The `image` op's path is illustrative — no fixture replay opens it; the host
  forwards ops verbatim and the shell's own tests generate a real sheet.
- `chrome-expand.json` — a worker-requested presentation change (§3.3).
- `chrome-wing.json` / `chrome-wing-width.json` / `chrome-wing-clear.json` — the
  first three **collapsed**-wing shapes (§3.3 extension, proposed below):
  content, bare width, and release. Not to be confused with `commit-wing.json`
  — see "Two things called a wing" below.
- `chrome-wing-meter.json` / `chrome-wing-meter-clamp.json` — the fourth: the
  shell-drawn **meter**, and a `value` deliberately outside `0…1`. The clamp
  fixture is the interesting one — the host clamps on the way out and the shell
  clamps again on the way in, and a fixture is the only place both halves of
  that can be proved from the same bytes.
- `commit-wing.json` / `commit-wing-update.json` — a **panel** wing (§5 `wing`):
  a left-zone node mounted as a direct child of the root, and an update on its
  children. The pair proves a wing is an ordinary container on the wire — where
  its view goes is the shell's business.
- `commit-app-controls.json` / `commit-app-controls-update.json` — the app tier
  (proposed below): `variant="ghost"` on two glyph buttons, a `variant="bead"`
  an app must *not* get, and `image.stroke` on a file bitmap and on an SF
  Symbol. The update moves a variant in each direction across the tier line and
  both deletes and adds a stroke, which is what pins the props as resolved from
  the merged set rather than create-only. It also swaps the **symbol node's own
  `src`** (`sf:waveform` → `sf:waveform.badge.mic`): an `sf:` image is an
  ordinary node and updates in place, which the shell used to get wrong — it
  re-applied `src` only on the file-image kind, so a symbol that changed mid-life
  kept the first glyph until the app forced a remount.
- `lifecycle-reduce-motion.json` — the §4.2 envelope carrying `reduceMotion`
  beside the phase. Its pair is `lifecycle-expanded.json`, which deliberately
  carries no such key: absent is "unchanged", not "motion is fine".
- `commit-align.json` / `commit-align-update.json` — `stack.align` (§5) in the
  spec's own words: a centred column, a row aligned on its (vertical) cross
  axis, a nested column left flush, and a `divider` riding along as the child
  that spans the column whatever the alignment says. The update re-aligns two
  of them in place — `center → leading` and `leading → trailing`.
- `commit-rate.json` / `commit-rate-update.json` — `slider.rate` and
  `progress.rate`, with a third control that never mentions the prop (which is
  how every app that has never heard of it looks on the wire), then pausing with
  `rate: 0` and deleting the key with `null`.
- `invalid-commit-right-wing.json` — `wing side="right"`, the shell's own zone.
- `invalid-commit-nested-wing.json` — a wing that is not a direct child of the
  root.
- `platform-observe.json` / `platform-unobserve.json` — `ctx.platform.observe`
  and its opposite (§6 extension).
- `platform-result.json` / `platform-result-error.json` — the shell's
  acknowledgement. A success carries no `error` key at all, not a null one.
- `event-platform.json` — an observed notification arriving as the id-0 app
  event, with its `userInfo` already reduced to scalars.
- `platform-observe-workspace.json` / `-pasteboard` / `-power` / `-reachability`
  / `-audio` / `-focus` — one request per ratified observe kind (§6 extension, proposed
  below). Between them and `platform-observe.json` every `kind` on the wire has
  a golden example, and the names are the *translated* vocabulary
  (`screenLocked`, not `com.apple.screenIsLocked`).
- `event-platform-workspace.json` / `-pasteboard` / `-power` / `-reachability` /
  `-audio` / `-focus` — the event each kind produces. All are ordinary §4.1 events at
  id 0 with a scalar-only payload; the pasteboard one is the privacy line made
  concrete — a change count, the readable UTIs, and never the contents.
- `platform-calendar.json`, `platform-workspace.json`, `platform-location.json`,
  `platform-spotlight.json`, `platform-audio.json`, `platform-set-volume.json`,
  `platform-speak.json` — one request per `ctx.platform` **call**, each with a
  `-result` and a `-error` sibling. The results carry their answer in `data`;
  `platform-speak-result.json` has no `data` key at all, because a call with no
  answer omits it rather than sending a null. `platform-set-volume.json` asks for
  `1.4` and its result reports `1`: the clamp is visible on the wire, which is
  why `setVolume` answers with a value at all.
- `commit-mount.json` — first commit: create a small tree, `setRoot`.
- `commit-update.json` — partial prop update + one remove.
- `commit-new-kinds.json` / `commit-new-kinds-update.json` — one tree containing
  all six kinds added below (`toggle`, `segment`, `stepper`, `progress`,
  `spinner`, `pill`), then an update touching **every** node in it. The pair is
  what proves the new kinds update in place rather than remounting; a remount
  would drop a toggle's knob animation on every render and no mount-only fixture
  would notice.
- `commit-control-props.json` / `commit-control-props-update.json` — the new
  props on kinds that already existed: `button.size`/`disabled`, `slider.step`
  with a real `min`/`max`, `text.maxLines`/`truncate`. The default `size` appears
  as an *absent* key, because that is how an app that never heard of the ramp
  looks on the wire.
- `invalid-commit-unknown-parent.json` — insert under a nonexistent id.
- `invalid-commit-duplicate-create.json` — id created twice.
- `invalid-commit-bad-props.json` — `text` with a non-string `content`.
- `event-click.json` — Swift → host click on a button id (§4.1).
- `commit-gradient.json` / `draw-gradient.json` — the two gradient shapes (§5,
  §3.4, proposed below): container `gradient` tokens (one beside a `fill`, one
  naming a token this shell does not know, which must degrade to no wash), and
  the free-form canvas op with and without `angle`/`radius`.
- `commit-canvas-drag.json` / `event-drag.json` — the drag pair (§4.1, proposed
  below): a scrubber canvas that declared `onDrag` next to one that did not, and
  one `move` phase on the wire. The second canvas is the point of the pair —
  `onDrag` is what makes the shell emit at all, so "absent" has to be a golden
  case too.
- `lifecycle-expanded.json` — Swift → host panel state (§4.2).
- `selection-app.json` — Swift → host strip selection (§4.3).
- `resync-request.json` — Swift → host per-app resync (§4.3).
- `builder-stream.jsonl` — one line per `builder` event of a single turn (§3.6).
- `apple-script.json` / `apple-shortcut.json` — host → shell `ctx.apple`
  requests (§6, proposed below): the two kinds, with a Shortcut's input.
- `apple-result.json` / `apple-result-error.json` — the shell's answers. A
  success carries `value` and **no** `error` key at all, not a null one.
- `notify.json` — host → shell notification with a title and two action buttons.
- `notify-action.json` — Swift → host: the user pressed one.
- `capture.json` / `capture-result.json` — `ctx.capture` and the path of the
  shell-owned PNG it wrote.
- `event-drop.json` — Swift → host drop-shelf event. It is an ordinary §4.1
  `event` at **id 0**, which is the app-level convention (below), so the drop
  shelf costs the protocol no new envelope type at all.
- `event-swipe.json` — Swift → host: a horizontal swipe across the collapsed
  pill, addressed to the app that owns the wing. Also an id-0 event, for the
  same reason — there is no node under a gesture made on the pill.

Envelope `seq` values in fixtures are deliberately arbitrary; tests that
exercise seq/gen scoping construct their own sequences.

## Demo apps (`demo-apps/`)

One folder per app, `app.jsx` as the entry — the §6 layout, but in the repo
rather than in `~/.ledge/apps`, so `scripts/e2e-smoke.sh` and
`scripts/snapshot-demos.sh` can point a host at `--apps-root protocol/demo-apps`
without touching the user's real installation.

There are three, and their job is to make the interaction machine (flow.md)
**feel-testable on device** — every surface the shell can raise is held by one
of them. They are written against `docs/design/principles.md`; read that before
copying their taste.

- **`timer`** — the summary and the alert. Declares `<summary>`, so a rested
  pointer shows a line instead of opening it; holds a wing **meter** (a
  `<canvas>` node drawn once and mirrored into the right wing); at zero it
  raises an **alert-class** `ctx.peek` whose `<mini>` carries one action, and an
  alert does not auto-retract.
- **`radio`** — the other half of the same law: it declares **no** `<summary>`,
  so the same rested pointer must open the visit directly. Holds a wing
  **canvas** animating at ~8 fps off `ctx.draw`, released the moment it stops.
- **`beacon`** — the notification exerciser: an **ambient** peek (glyph, one
  line, no action, retracts on Ti) and an **alert** peek (one action, holds),
  both armed on a delay so you can watch them arrive while collapsed. The three
  clicks on a swell — the action, elsewhere → visit, and nothing — are all
  reachable from it.
There was a fourth, `settings`. Settings is a **native macOS window** in the
shell now (spec §8) and drives enable/disable over the `appControl` envelope, so
the app was retired from the strip; it is kept, unloaded, at
`protocol/demo-apps-archive/settings-app` as the only worked example of the
privileged `ctx.platform.*` surface the host still gates to that app id.

The apps that used to live here otherwise predate the design reset and were
moved to `protocol/demo-apps-archive/` — reference only. That folder is not an
apps root: nothing scans it, and its dependencies (`cheerio`, `chess.js`,
`stockfish`) were dropped from the apps root's `package.json` with them.

Two rules worth copying into any app that touches the network: **a `monitor`
must never throw** (a throw is an app crash with backoff, spec §6 rule 2 — a
flaky network would take the UI down with it), so every failure path ends in
cached-or-placeholder data plus an "offline" marker; and the **mount render must
be meaningful without a monitor**, because `scripts/snapshot-demos.sh` dumps
exactly that state and never runs one. Persist next to `app.jsx`
(write-temp-then-`rename`, spec §6); the watcher only reloads on source files,
so writing there is free.

**Frame rate is not the monitor's job.** The monitor loop has a 1 s spin floor
(spec §6 rule 1), so anything that has to move — `radio`'s meter, `timer`'s
clock, `beacon`'s one-second delay — owns its own `setInterval`/`setTimeout` and
the monitor parks on `await new Promise(() => {})`.

Each renders the whole panel between the cutout exclusion row and the app strip
— the shell draws the notch shape, the strip and the two panel-wing zones, the
app draws its content (see `shell/README.md`). None of them has a title row: the
shell names the app in the left zone, and the middle of a title row is the
camera housing. Status that has to be on the panel goes in a
`<wing side="left">`.

**The apps root is a real package.** `protocol/demo-apps/package.json` +
`bun.lock` (committed, per §6's "always ship the lockfile") are the repo
analogue of the shared `~/.ledge/node_modules`: `react` and `react-reconciler`
are there for apps to import bare, and nothing else is — every entry is paid for
in the .app bundle. `bun install` in that folder is all a fresh checkout needs; both scripts do it for you if `node_modules` is
missing. It replaces the old convention where the scripts symlinked
`host/node_modules` in and deleted it on exit — a convention that quietly did
one more thing than it looked like, which is the next paragraph.

**React is linked, not pinned.** The apps root's `react` dependency is
`file:../../host/node_modules/react`, deliberately. React's hooks live in
module-level state (`ReactCurrentDispatcher`), and the reconciler that renders
an app runs inside the worker out of `host/src/render/` — so the app's `react`
and the reconciler's `react` must be the **same module instance**. Two identical
copies of 18.3.1 is not "fine", it is `dispatcher.useState of null` on the app's
first `useState`. The old symlink satisfied this by accident; the `file:` link
states it. (`stockfish`'s postinstall script stays blocked by Bun's default
trust policy — nothing in this phase needs it to have run.)

## Proposal: the type ramp grows two sizes, a weight, and `caps` (spec §5)

The ramp stopped at `xl`/30, and `xl` is already spoken for — §3.1's own example
is a headline price at that size. So the genre this platform exists for (a
temperature, a score, a clock, one numeral owning the well) had no size to ask
for, and `weight` bottomed out at `regular`, which at 40-odd points is a wall
rather than a numeral. Four additions, no version bump — **implemented**:

| prop | added | means |
|------|-------|-------|
| `size` | `display` · 36 | a single number that *is* the content |
| `size` | `hero` · 48 | the largest thing Ledge draws; one per surface |
| `weight` | `light` | the display tier's natural weight (design.html draws every big numeral at 300) |
| `caps` | `true` | uppercase **and** +6% tracking, together |

```jsx
<text size="hero" weight="light">72°</text>
<text size="xs" weight="semibold" color="secondary" caps>Feels like</text>
```

- **`xs..xl` are untouched.** 10 · 11.5 · 12.5 · 15 · 30, exactly as before;
  every existing fixture renders identically. The ramp itself moved out of
  `ProtocolRenderer.font` into `LedgeMetrics.TypeSize`/`TypeWeight`, so the
  shell's own chrome and an app's `text` node now read the same numbers — the
  point of principle 15, not a behaviour change.
- **`caps` is one prop, not two.** Uppercase at natural letter spacing is a jam,
  so an app that could ask for the uppercasing without the tracking would ship
  the half that looks wrong. +6% of the point size is design.html's own eyebrow
  tracking (`.sec-eyebrow`, `.mark`).
- **The raw string survives.** `caps` is a presentation: the accessibility label
  and a later `caps: false` both read the content as the app wrote it, so
  dropping the prop restores the original casing rather than leaving a shouted
  label behind.
- **Degrades like every other token.** An older shell that has never heard of
  `hero` resolves it to the default `m` (the same fallback `xs..xl` always had),
  and `caps` is an unknown bool it ignores — no error, no resync.

Fixtures: `commit-type-ramp.json` (mount, all four additions plus an unchanged
`xl`/`bold` price) and `commit-type-ramp-update.json` (drops `caps` on one node,
adds it to another, and moves `display` → `hero`), replayed by both suites.

## Proposal: container styling on `stack` (spec §5)

Every mockup leans on three things §5 cannot express: raised rounded boxes,
tinted alert rows, and hairline strokes. Without them an app that wants a
"deal is under target" row has to ask for a bespoke component, which is how
component vocabularies stop being small. Three additive props on `stack` cover
all of it — **implemented**, and proposed for §5 proper:

| prop     | type   | values |
|----------|--------|--------|
| `fill`   | token  | `raised`, `raisedHover`, `accentTint`, `greenTint`, `redTint`, `violetTint`, `black` |
| `stroke` | token  | `hairline`, `accent`, `green`, `red`, `violet` (always a 1 pt hairline) |
| `radius` | number | corner radius in points |

`canvas` additionally emits `click` events carrying canvas-local `{x, y}`
(same y-down space as draw ops), and `button` props (`label`, `variant`,
`icon`) update in place per §3.1 partial updates — a chessboard's pieces are
button labels.

Companion proposals from the same recreation work: `text.color` grows
`tertiary`, `cyan`, `violet` (the mockups use all three); `button` gains an
`icon` prop (`"sf:<name>"`, drawn leading the label) — without it every
icon-bearing button needs a bespoke child layout.

```jsx
<stack axis="h" pad={8} gap={10} fill="greenTint" stroke="green" radius={10}>
  <text content="Sony WH-1000XM5" size="m" weight="semibold" />
  <spacer />
  <text content="HIT" size="xs" weight="bold" color="green" mono />
</stack>
```

**Tokens only — never a raw color.** This is the same rule §5 already applies to
`text.color`: the shell owns the palette, so a theme change is a change in the
shell and nowhere else, and an app cannot strand itself on `#1B1B1B`. An
unrecognized token is not an error and not a guess — it renders as no styling,
so a future token degrades to "plain box" on an older shell.

No envelope or version change: they are ordinary props on an existing kind, and
§3.1 validation already ignores unknown props (`fill`/`stroke` type-check as
strings, `radius` as a number).

Two behaviors the same work pinned down, both consequences of "layout is
stack-based only" rather than new vocabulary:

- **A vertical stack stretches its children to its own width.** That is what
  makes rows, boxes, charts and sliders span the panel without every app
  repeating a width; anything narrower belongs in an h-stack beside a `spacer`.
- **`spacer`s in one stack split the leftover space equally**, so a group with a
  spacer on each side is centered. `distribute="equal"` (already in §5) is now
  implemented and gives a row of chips or buttons an even share.

## Proposal: six controls apps were already faking (spec §5)

§5 is small on purpose, and the discipline held for a year — but "small" only
pays off while the missing pieces are genuinely unnecessary, and six of them
stopped being unnecessary the moment real apps shipped. Settings builds toggles
out of two buttons and a filled stack. Alarm hand-rolled a 24-hour time picker
from `−`/`+` buttons plus a monospaced label, and its am/pm switch out of two
more buttons that have to agree about which one looks selected. Music draws its
position bar as a 4-pt stack inside a 4-pt stack. Stocks and deals both fake a
spinner by animating a text label. Every app in the repo builds `LIVE` / `PAPER`
/ `−2.4%` badges out of a stack with a fill, a stroke and a text child, and gets
the triple subtly wrong in a different way each time.

That is the signal worth acting on: the vocabulary isn't small any more once six
apps have each re-implemented the same control, it is just *undeclared*, and
undeclared means every app pays for it and every app's version drifts. Six
additive kinds — **implemented**, ratified in `docs/design/design.html` D6/D8 —
collapse all of it. None of them takes children (`stack` and `button` remain the
only attachable kinds), so none of them can grow into a layout system.

| kind       | props                                                            | event |
|------------|------------------------------------------------------------------|-------|
| `toggle`   | `on` (bool), `disabled?`                                          | `change` `{on}` |
| `segment`  | `options` (`{id,label}[]`), `value` (an option's `id`)             | `change` `{value}` |
| `stepper`  | `value`, `min?`, `max?`, `step?` (1), `format?` (string)           | `change` `{value}` |
| `progress` | `value` (0…1), `color?` (a hue family: `accent`, `green`, `red`, `violet`, `cyan` — default ink) | — |
| `spinner`  | —                                                                 | — |
| `pill`     | `label`, `tone?` (`accent`, `green`, `red`, `violet`, `cyan`, `neutral`) | — |

```jsx
<stack axis="v" gap={8} pad={12} scroll>
  <segment options={ranges} value={range} onChange={({ value }) => setRange(value)} />
  <stepper value={minutes} min={0} max={1439} step={5} format={clock(minutes)}
           onChange={({ value }) => setMinutes(value)} />
  <toggle on={armed} onChange={({ on }) => setArmed(on)} />
  <stack axis="h" gap={6}>
    <pill label="PAPER" tone="accent" />
    {loading ? <spinner /> : <progress value={done} />}
  </stack>
</stack>
```

```json
{ "op": "create", "id": 4, "kind": "segment",
  "props": { "options": [{ "id": "1d", "label": "1D" }, { "id": "1w", "label": "1W" }],
             "value": "1w", "onChange": true } }
{ "op": "create", "id": 6, "kind": "stepper",
  "props": { "value": 450, "min": 0, "max": 1439, "step": 5, "format": "07:30",
             "onChange": true } }
```

Four things the shapes above are deliberately *not*:

- **Nothing is self-driving.** A `toggle` does not flip itself and a `segment`
  does not move its own selection; both report the gesture and re-render from the
  prop the app sends back. That is the same contract `input` and `slider` already
  have, and it is what keeps the shell's shadow tree (§3.1) a pure function of
  the app's state instead of a second, divergent copy of it.
- **`stepper.format` is a string the app computed**, not a format *specifier*.
  `07:30` is 450 minutes, `3 cups` is 3 — the shell cannot know the unit, and a
  `"%02d:%02d"` prop would be a small language embedded in the protocol. The raw
  `value` still travels, because that is what `min`/`max`/`step` and the +/− keys
  operate on; `format` only decides what is drawn.
- **`progress` has no `onChange`, ever.** A progress bar that accepts input is a
  `slider`, and the two looking alike is exactly why the distinction has to live
  in the kind rather than in whether the app happened to pass a handler.
  Indeterminate work is `spinner`, not `progress` without a `value`.
- **`progress.color` names a hue family too, and defaults to ink.** Same five
  words as `pill.tone` minus `neutral` (`accent`, `green`, `red`, `violet`,
  `cyan`), never a hex string — the shell owns the exact ink, so two apps'
  accent meters are the same accent. Absent, unknown, and the ink shades
  (`primary`/`secondary`/`tertiary`, which are *type* colours) all resolve to
  the default, so an older shell and a future token both degrade to a quiet
  bar. It exists because design.html §01 draws Focus's session meter in accent:
  the working moment is the one thing on that panel, and a meter is the only
  control that could carry it. **Quiet unless asked** is still the rule — a
  panel where every bar is coloured has told you nothing.

- **`pill.tone` names a hue *family*, not a color.** The shell derives the
  tint + stroke + ink triple from it, which is the whole reason the kind exists:
  an app that assembles those three itself can pick two of them from one family
  and the third from another, and six apps did.

## Pages are app state, and a list needs two pieces of furniture

The exercise: give stocks a detail page you reach by tapping a ticker, and make
the watchlist scroll. The question underneath it: does "a view change" want
protocol surface — a `nav`, a route, a page stack — or is app state enough?

**App state is enough, and the evidence is that nothing had to be invented.**
Navigation is one `useState` in `stocks/app.jsx`; the commit it produces is a
remove and an insert under the same root, which is what the reconciler emits for
any conditional subtree. The shell never learns that a page changed, and it does
not need to: it re-measures after every commit anyway, so the panel resizes from
the watchlist's ten rows to the detail page's five without a word being said
about pages. The `wing` stays put across the swap because it is a zone rather
than part of the tree's layout, which is exactly the behaviour a nav bar would
have needed a primitive for.

The three things a page primitive would buy — a back gesture, a transition, and
state that survives — are each worse as protocol. A back *button* is a `button`
and reads better than a swipe in a 440 pt panel. A transition would have to be
the shell's, and the panel already morphs its height on the standard spring. And
"state that survives" is the honest limitation: `useState` lives in the worker,
so a crash or a hot reload puts the user back on the list. That is a real cost,
and it is the same cost every app already pays for every other piece of local
state — solving it for pages alone would be a second, privileged kind of state.

Two components *were* missing, both of them furniture rather than mechanism:

| kind | props | why |
|------|-------|-----|
| `divider` | — | The rule between rows, and the one shape the container vocabulary genuinely could not express: a `stack` with a `stroke` outlines what it contains, and a stack containing nothing is zero points tall. Horizontal only, on the same grounds `stack scroll` is vertical only — in a row, separation is already `gap` and `spacer`. |
| `button` + child | — | Not new: §5 has said "`label` or child" since the beginning, `ShadowTree` has always accepted it, and the JSX types have always declared `children`. It simply did not render — the button measured its empty label, collapsed to a 34 pt icon-only circle, and pinned the child to a centre that had nothing to do with its size. A list row is the case that needs it; a chevron at the row's right-hand end makes the other 90% of the row a dead zone. |

Nothing else was reached for. A per-row `onClick` on `stack` would have done the
same job as the child button and given every container a second, quieter way to
be a control; a `nav` would have been a router nobody asked for.

Two bugs surfaced on the way, both of them the kind only pixels find:

- **One `segment` collapsed an entire page from 440 pt to 163.** A vertical
  stack fills its children to its own width with an equality at priority 500, and
  a `segment` hugs at 751 so it can keep its measured width. The hugging did win —
  but an equality pulls in *both* directions, so the stack was dragged down to the
  segment's width and every sibling neatly filled a column that had quietly
  shrunk. Children that hug harder than the fill are now skipped, which is what
  their 751 was declaring in the first place.
- **A label swallowed the press meant for its row.** `NSTextField` is an
  `NSControl` and hit-tests to itself, so the ticker was the one part of a
  tappable row that did nothing. `LedgeText` is transparent to hit testing now: it
  is never editable, never selectable and has no action, so every press that lands
  on one is meant for something behind it.

### The same wave, on kinds that already exist

These are ordinary props, so they behave like every other §5 prop — additive,
partial-updatable, ignorable:

| kind     | prop                | meaning |
|----------|---------------------|---------|
| `button` | `size` (`s`/`m`/`l`) | 28 / 34 / 40 pt, default `m`. A string ramp rather than a number: the design ruled three heights, and a free `height` prop is how you end up with the 31-pt button nobody meant to ship. |
| `button` | `disabled`          | Content at .35 alpha, no hover, no press — **and no `click` event**, so a disabled button is inert on both sides of the wire. A trader's *Execute* whose proposal went stale needs this; hiding the button instead makes the panel jump. |
| `slider` | `step`              | Snap increment. `min`/`max` were in §5 from the start and were **silently ignored** — the shell always worked in 0…1 — so every app scaled by hand into a range the prop already described. `value` is now in `min`…`max` space, snapped to `step`. |
| `text`   | `maxLines`          | Wrap up to N lines, then tail-truncate. Absent (or 1) is one line, because silent wrapping is what the single-line rule was protecting against; multi-line stays opt-in. |
| `text`   | `truncate`          | Default `true` = tail ellipsis. `false` clips instead, for values where an ellipsis reads as part of the content — a clock, a ticker. (In §5 since the beginning, real as of this wave.) |
| `stack`  | `scroll`            | Vertical stacks only: an `NSScrollView` wrapper, height capped by the panel limit. §5 already promised it ("a `stack` can opt in with `scroll: true`"); deals lists and chess's move list have been clipping instead. |

```json
{ "op": "create", "id": 6, "kind": "button",
  "props": { "label": "Execute", "variant": "accent", "disabled": true, "onClick": true } }
{ "op": "update", "id": 6, "props": { "disabled": null } }
```

Re-enabling **deletes** the key (`null`, per §3.1 partial updates) rather than
sending `disabled: false`; absent and false mean the same thing, and having one
canonical form on the wire is what lets the fixtures assert on exact prop
objects.

### Compatibility: honest about the asymmetry

The proposals above this one all end in "no envelope change, and an older shell
ignores it". Half of that is true here and half of it isn't, and the difference
is worth stating plainly:

- **The new props are safe.** §3.1 validation type-checks the props it knows and
  ignores the rest, so `size`, `disabled`, `step`, `maxLines` and `scroll` reach
  an older shell as unknown keys and degrade to today's rendering — a 34-pt
  button, a 0…1 slider, one line of text, a clipping stack. Nothing breaks.
- **The new kinds are not.** An unknown *kind* is a validation failure, not an
  unknown prop: §3.1 checks that props type-check **for the kind**, so a shell
  with no `toggle` cannot validate one. The whole commit is discarded and the
  shell sends `resyncRequest` — and since the host will honestly re-send the same
  tree, that is a loop, not a graceful degradation. An app using `toggle` against
  an old shell renders nothing at all.

That is acceptable here, and only here, because the shell and the host ship as
one artifact from one repo — there is no wild population of old shells to
degrade for, which is also why this needs no version bump. It is worth being
explicit rather than tidy about it: the reason `draw` ops (§3.4) and props can
grow freely is that both sides made *skipping the unknown* the defined behavior,
and the kind vocabulary deliberately did not. Adding a kind is therefore a
coordinated change, and `commit-new-kinds.json` is the fixture that makes the
two sides prove they made it together.

## Proposal: file images, and an `image` draw op (spec §5, §3.4)

§5 gives `image` a `src` that is "a host-fetched URL or `sf:play.fill`", and only
the second half was ever real — anything that wasn't an SF Symbol drew a
placeholder. But every app already has a folder full of its own files, and the
one thing an app cannot express is "show me *this* picture". Two additions, both
of them things §5 and §3.4 already leave room for:

**`image.src` accepts an absolute file path** (`.png` / `.jpg` — whatever
`NSImage` reads), alongside the existing `sf:<symbol>`:

```jsx
<image src={`${import.meta.dir}/artwork.png`} w={54} h={54} radius={10} />
```

Paths arrive **absolute**, because that is what apps have: `import.meta.dir`
(spec §6) is the app's own folder, and it is how an app names its own files for
`bun:sqlite` and `fs` already. A relative path is refused rather than guessed at
— it would resolve against the *shell's* working directory, which is nowhere
near the app. The picture **aspect-fills** the `w × h` box and `radius` clips the
corners: a tile with letterbox bars baked into it is not a tile. A path that does
not resolve draws a quiet raised box, the same shape the picture would have
occupied — a half-written app should look unfinished, not broken.

**A new `image` draw op** (§3.4 — ops may be added without a version bump, and an
older shell skips the ones it doesn't know):

```json
{ "op": "image", "src": "/…/sprites.png", "x": 8, "y": 4, "w": 16, "h": 16,
  "sx": 16, "sy": 0, "sw": 16, "sh": 16 }
```

`src` is an absolute path, as above. `x/y/w/h` is the destination in the canvas'
own y-down op space, like every other op. `sx/sy/sw/sh` select a **source rect in
image pixels, origin top-left** — one cell of a spritesheet; omit `sw`/`sh` and
the whole image is drawn. That is the entire spritesheet story: a sheet is one
file, a frame is four numbers, and an animation is an app changing them per
frame. It works identically on a panel canvas and on the **notch wing's strip**,
because they are the same canvas — an app's `ctx.draw` frames already feed both.

Two rendering rules the shell owns, not the app:

- **Magnified sprites are not smoothed.** A destination bigger than its source
  is pixel art being blown up, and interpolating it is just blur; a destination
  smaller than its source is a picture being scaled down, where *not*
  interpolating is aliasing. The direction of the scale decides.
- **One decode per path.** Decoded images are cached shell-side, shared by every
  canvas and every `image` node, keyed by path and bounded (oldest evicted). A
  file that changes on disk is picked up — entries are revalidated against the
  file's modification time, at most once a second per path — so regenerating a
  spritesheet does not need a restart, and a 60 Hz blit does not need a decode.

No envelope change either way: `src` is an existing prop on an existing kind, and
`image` is an ordinary §3.4 op.

## Proposal: gradients — a container wash and a canvas op (spec §5, §3.4)

Flat fills were the platform's whole material vocabulary, and the soft wash half
this genre leans on (album-art bloom, a sky behind a world clock, a weather
ramp) was unexpressible. Two additive pieces, and they answer the same question
in deliberately opposite directions — **implemented**:

| where | shape | colors |
|-------|-------|--------|
| `stack.gradient` | a **standardized wash**: hue at the top, transparent by 60% of the height, behind the children | a token: `accent`, `green`, `red`, `violet`, `cyan` |
| `{ "op": "gradient" }` | an axial ramp filling one rect, `x`/`y`/`w`/`h`, optional `angle` and `radius` | `from`/`to`, hex |

```jsx
<stack axis="v" pad={14} gradient="violet">      // the wash behind the track
  <stack axis="h" gap={8} fill="raised" radius={12} gradient="cyan">…</stack>
</stack>
```
```json
{ "op": "gradient", "x": 0, "y": 0, "w": 416, "h": 60,
  "from": "#0B1B3A", "to": "#F4A24C", "angle": 0, "radius": 8 }
```

- **A container names a hue; the shell owns the recipe.** One alpha, one stop,
  one direction, for every app. A prop that took two colors, an angle and two
  stops would let each app invent its own material, and a row of panels would
  stop reading as one system by the second app. It is the same "tokens only,
  never a raw color" rule `fill`, `stroke` and `text.color` already have, and an
  unrecognized token degrades the same way: no wash, not an error.
- **A canvas names real colors.** Pixels are the app's — a palette token inside
  a draw op would silently draw white, which is the rule the op vocabulary has
  always had. `angle` is degrees clockwise from top-to-bottom, so it counts the
  way the y-down op space does; `radius` rounds the rect like `rect`.
- **A wash composes with a fill**, because they are different materials: the
  fill is the background, the wash is a layer behind the children. That is also
  why it is a separate prop rather than a `fill` token — `fill="violetWash"`
  would have made the two mutually exclusive for no reason.

No envelope change and no version bump either way: `gradient` is an ordinary
prop on an existing kind (§3.1 type-checks it as a string), and the op joins
`image` under §3.4's "unknown ops are skipped" rule — an older shell draws the
rest of the frame and leaves the wash out.

## Proposal: `canvas` drag — press, move, release (spec §4.1, §5)

A `canvas` could be clicked and typed into, and that was all: `mouseDown` became
a §4.1 `click` with a local point, and press-drag-release was invisible. Every
scrub, knob and sketch interaction in this genre is that gesture — a world
clock's time ruler, a seek bar drawn as pixels, a dial — so each of them was
unbuildable with the shipped vocabulary. One additive prop and one event name
fix it — **implemented**:

| prop     | type | event |
|----------|------|-------|
| `onDrag` | bool | `drag` `{ phase: "down" \| "move" \| "up", x, y }` |

```jsx
<canvas w={416} h={44} onDrag={({ phase, x }) => {
  if (phase === "down") setScrubbing(true);
  if (phase === "up") { setScrubbing(false); commit(timeAt(x)); }
  setPreview(timeAt(x));
}} />
```

Four decisions, all of them about where the policy lives:

- **`move` is throttled in the shell (~30 Hz), `down` and `up` never are.** A
  trackpad emits moves faster than the panel redraws, and each one would be a
  frame on the socket. The phases an app builds a state machine out of are the
  two ends, so those are exact; the middle is a sampling of a continuous
  gesture and coalescing it changes nothing an app can perceive.
- **`up` carries the final position.** That is what makes coalescing safe: a
  dropped `move` can never be the last word on where the user let go.
- **The point is not clamped to the canvas.** A knob dragged past the edge keeps
  reporting, so the app can decide whether its own track saturates or wraps. A
  shell that clamped would silently make every scrubber sticky at both ends.
- **`click` and `drag` are independent.** A canvas that declares both gets both
  on press; neither is synthesized from the other, because the movement
  threshold that separates a tap from a drag is app policy, not shell policy.

`onDrag` is what makes the shell emit at all — a canvas that never declared it
costs nothing per mouse-moved event, which is the same "unknown props are
forward-compatible" rule §3.1 already has, read from the other side. Round-trip
per point is UDS → worker render → commit, a few milliseconds; an app that needs
better than that is what the `"use native"` transducer path (§3.5) is for.

## Proposal: app-declared panel size (spec §5, §3.6)

§5 fixes the expanded panel at 440 pt and says "apps don't choose widths", with
a `maxPanelHeight` the shell computes and reports in `hello`. That holds right up
until an app is a chessboard: a board plus a move list wants more than 440, and a
one-line pacer wants far less. The fix is not to move the constant — it is to let
an app *ask*, and keep the deciding where it already lives.

`meta` grows an optional `panel`, and the catalog entry carries it:

```jsx
export const meta = {
  name: "Chess",
  icon: "sf:crown",
  panel: { width: 520, maxHeight: 560 },
};
```

```json
{ "id": "chess", "name": "Chess", "icon": "sf:crown", "order": 2,
  "enabled": true, "running": true,
  "panel": { "width": 520, "maxHeight": 560 } }
```

Both fields optional, both a *request*. The shell clamps: **width to
[320, screen max]**, defaulting to 440 when undeclared; **maxHeight to the
screen-derived cap**, which is also what `hello.screen.maxPanelHeight` now
reports (§5's 480 pt was a placeholder — the real cap is ~70 % of the usable
screen height, so a 16" display gets a much taller panel than a 13" one). An app
that declares nothing behaves exactly as it did before this proposal.

**Where `meta` comes from.** The host thread must never import app code, so the
name and icon §3.6 has always promised were a directory-name fallback in
practice. They come from the only process that legitimately evaluates an app: its
own worker posts its `meta` right after import, before the mount commit, and the
host merges it into the catalog and re-sends the **full snapshot** (§3.6 — no
diffs). Merging is per-field and the stored meta is replaced wholesale on each
(re)start, so dropping `meta.name` from a file restores the dirname fallback on
the next reload rather than leaving a ghost.

No envelope change: `panel` is an optional field on an existing `catalog` entry,
and a shell that has never heard of it ignores it and draws 440.

## Proposal: worker draw frames (spec §3.4)

§3.4 defines the `draw` envelope host → shell, but nothing on the worker side
ever produced one — the imperative path existed only for the native transducer
(§3.5). `ctx` gains the missing half:

```js
ctx.draw(id, ops)      // → { type: "draw", id, ops } → the §3.4 envelope
```

`id` is the canvas' **node id in the app's own tree**. An app learns it the
ordinary React way — a ref on the element yields the node instance, whose `id`
is exactly what the reconciler allocated:

```jsx
let canvas = null;
<canvas ref={(node) => { canvas = node; }} w={200} h={320} focusable onKey={step} />
// …later, at frame rate:
ctx.draw(canvas.id, [{ op: "clear" }, { op: "rect", x, y, w: 8, h: 8, fill: "#30D158" }]);
```

`ctx` is the monitor's argument, but the object lives as long as the worker, so a
game loop keeps the reference its `monitor` was handed and draws from event
handlers too. That is the whole pattern; there is no second API.

**Draw frames are scoped by app, not by canvas id.** Node ids are allocated per
app and restart at 1 in every worker (§3.1), so two running apps routinely both
own a node 12. The coalescer and the shell's canvas lookup are therefore keyed on
`(app, id)`; keying on the id alone put one app's frames on another app's canvas.
Pending frames for an app are dropped when its tree is (reload, stop, resync).

**Key input closes the loop.** §5's `focusable` + `onKey` and §4.1's `key` event
were both implemented but never met: nothing ever gave a canvas first responder,
so `onKey` only fired if the user happened to click it. The shell now focuses the
presented app's first focusable canvas — and only then does the notch panel take
key focus, so a panel without a game never steals the user's insertion point.

## Proposal: collapsed wings — the notch as an app surface (spec §3.3, §8)

> These are the **collapsed** wings: the live-activity areas on the pill, owned
> by one app at a time. The *panel* wings — the zones beside the cutout inside an
> open panel, addressed with a `<wing>` node — are a different surface with a
> different owner; see "Two things called a wing" below.


§8 describes "live-activity wings up to 340 × 34" as chrome the shell draws, and
§3.3 gives apps `expand`/`collapse`/`attention` and nothing else. So the most
distinctive surface in the product — the pill you actually look at all day — was
the one surface an app could not address. This adds a fourth `chrome` request:

```json
{ "request": "wing", "wing": { "text": "AAPL ▲ 1.2%", "canvas": { "id": 12, "w": 64 } } }
{ "request": "wing", "wing": { "text": "12:04", "meter": { "value": 0.42 } } }
{ "request": "wing", "wing": { "width": 286 } }
{ "request": "wing", "wing": null }
```

```js
ctx.wing({ text, width, canvas: { id, w }, meter: { value } })   // own the notch
ctx.wing(null)                                                   // give it back
```

- **`text`** renders as a left-aligned label in the **left** wing.
- **`canvas`** names a drawable strip in the **right** wing: `id` is a canvas
  node id in the app's own tree and `w` its requested width (clamped to ~160 pt);
  its height is the notch height, so an app's §3.4 ops need no scale factor. The
  frames arrive through the ordinary `ctx.draw` path — the shell mirrors that
  node's frames into the wing, so a canvas can be drawn collapsed and expanded
  from one call.
- **`meter`** is the right wing's **stock bar** — flow.md enumerates the wing
  forms as glyph / ticker / meter / canvas, and this is the third of them made a
  wire form. `value` is a fraction of the whole, `0…1`, clamped at both ends of
  the wire rather than rejected: a progress dividing by a total it just changed
  reads 1.02 for one frame, and that is a full bar, not a wing that blinks out.
  Every other number belongs to the shell — 64 × 3 pt, capsule ends, track plus
  an `ink-2` fill (design.html §02), never the accent, because a meter is the
  state of a thing rather than a thing worth interrupting for. That split is the
  point: before it, every app hand-drew a bar into a canvas and no two of them
  matched. `canvas` and `meter` both claim the right wing; the canvas wins,
  because those are the app's own pixels and this is a shape the shell can
  always draw somewhere else.
- **`width`** is the **total** collapsed pill width in points, clamped to
  [notch width, notch width + 2 × 160]. With content, it is a floor: any surplus
  over what the content needs is split evenly between the wings. Alone — no text,
  no canvas — it is a bare shape request, pure geometry with nothing in it, which
  is the entire UI of a breathing pacer.

An empty wing object (`{}`) carries no instruction and is treated as a release,
so the shell never has to render "a wing that shows nothing".

**Arbitration: one notch, one wing, latest wins.** The newest app to ask takes
the notch. A release only lands if it comes from the app that currently holds it,
so a background app tidying up its own wing cannot blank the wing of whichever
app took over. An app's wing is released *for* it by the host on every lifecycle
transition — `started`, `reloaded`, `crashed`, `stopped` — because a wing belongs
to a live worker and the fresh one re-declares whatever it still wants. On host
disconnect the shell drops the wing with everything else scoped to the dead
generation (§1); nothing is replayed onto the next connection.

**Feel.** The winged pill is the same shape morphing on the same spring the panel
uses; the hover bump stays additive on top and is never fought over. Repeated
width updates at 2–10 Hz coalesce by construction — each request re-springs from
wherever the previous animation had reached, so "latest wins" needs no queue.

## Proposal: panel wings — the cutout exclusion row (spec §5)

### Two things called a wing

The word now names two different surfaces, and keeping them apart is most of
understanding either:

| | **collapsed wings** (§3.3, above) | **panel wings** (§5, here) |
|---|---|---|
| where | the pill, either side of the cutout | the *expanded panel*, either side of the cutout |
| when | while the panel is **closed** | while the panel is **open** |
| who owns it | one app at a time, latest asker wins | the app whose panel is on screen |
| how an app asks | `ctx.wing({ text, canvas, width })` | a `<wing side="left">` node in its tree |
| lifetime | until released or the worker dies | as long as the app's tree has one |

They share a cause — the camera housing is in the middle of both — and nothing
else. A collapsed wing is a *live activity*: it is up when you are not looking at
the app. A panel wing is part of the app's own panel.

### The defect

The expanded panel's content container started at the top of the panel, so the
top-centre of every app's tree was drawn **behind the hardware cutout**. Eleven
apps had all independently opened with a title row — `● Chess · stockfish`,
`↑ rotate space drop p pause`, `Settings · 4 workers · 38 MB` — and on a notched
Mac the middle third of each of those rows was simply invisible.

"Don't render anything at the top centre" is not a rule a component vocabulary
can express, and asking eleven apps to remember it is a rule that gets broken by
app twelve. So the panel reserves the row instead:

```
┌───────────────────────────────────────────────┐
│ left zone   │   ▓▓ cutout ▓▓   │   right zone  │  ← reserved, cutout height
├───────────────────────────────────────────────┤
│                                               │
│              the app's §5 tree                │
```

- The row is **the cutout's own height** (`NotchMetrics`) — on a screen with no
  cutout, the measured menu-bar height, which is the same measurement.
- The dead centre is the cutout plus a small margin each side. Nothing is ever
  drawn there.
- The zones are what is left, inset from the panel edges. They **clamp**: as the
  panel narrows toward the cutout they shrink to zero and their content
  ellipsizes inside them, exactly the discipline the collapsed wings learned the
  hard way. They never go negative and never overlap the dead centre.
- The app's tree mounts **below** the row, so an app that renders a top row can
  no longer collide with the camera. The panel's height is its measured content
  plus the strip plus this row.

### What the zones hold

**The right zone is the shell's, always.** It carries a compact *Edit with AI*
affordance — a size-`s` glass capsule, `sf:wand.and.stars` + "Edit" — which
presents that app's chat surface (spec §8). It is chrome like the app strip, and
it is deliberately not something an app can take away: there has to be one place
the user can always ask for a change, and a place an app can claim is not one.

**The left zone defaults to the app's catalog display name** (11.5 semibold,
secondary ink, leading-aligned, ellipsized). That default is why apps should now
**delete their title rows**: the shell already says what the app is.

**An app may take the left zone** with a new §5 kind:

```jsx
<stack axis="v" pad={14} gap={8}>
  <wing side="left">
    <text content="●" size="xs" color="green" />
    <text content="4 workers · 38 MB" size="xs" weight="medium" color="secondary" />
  </wing>
  {/* …the rest of the panel… */}
</stack>
```

```json
{ "op": "create", "id": 2, "kind": "wing", "props": { "side": "left" } }
{ "op": "insert", "parent": 1, "id": 2, "before": null }
```

| prop   | type | values |
|--------|------|--------|
| `side` | enum | `"left"` — and nothing else |

Four rules, all of them enforced rather than documented:

- **`side="right"` is a validation error**, not a request the shell declines.
  This is the only §5 prop checked by *value* rather than by type: a wrong value
  means a tree the protocol cannot express, so §3.1 discards the whole commit and
  the shell sends `resyncRequest` — the same all-or-nothing treatment a
  mistyped prop gets.
- **A wing must be a direct child of the root.** A wing nested inside a card
  would render into a zone its parent cannot see, which is a worse answer than
  refusing the commit. Checked once at the end of a batch, because `setRoot` is
  conventionally the last mutation in a mount.
- **Its content is a horizontal group**, vertically centred in the row and
  clipped to the zone. Children are ordinary nodes and update in place.
- **It replaces the name, not the Edit affordance.** Removing the wing node
  reverts the zone to the app's name; switching apps reverts it to the new app's.

`wing` is an *attachable* kind (like `stack` and `button`) but it is not a layout
container in disguise: it has one prop, exactly one valid value for it, and one
place it may be attached.

**Compatibility:** the same asymmetry the six new kinds have, for the same reason
(see "Compatibility: honest about the asymmetry"). An unknown *kind* cannot be
validated, so a `wing` against an older shell would loop on resync — which is
acceptable only because the shell and the host ship as one artifact from one repo.

## Proposal: `rate` — controls that advance themselves (spec §5)

A monitor polls. Music's asks the player what is playing every three seconds,
which is the right number of Apple events to send and the wrong number of times
to move a scrub bar: the position jumped in three-second steps, and a track
change took up to three seconds to appear at all.

The app's alternatives were both bad. Commit sixty times a second — a full
React reconcile, a wire frame and a shadow-tree validation per frame, for one
number — or accept the steps. `rate` is the third option: the app states the one
thing it actually knows, and the shell does the arithmetic where the pixels are.

| kind | prop | meaning |
|------|------|---------|
| `slider` | `rate` | value units per second of shell-side self-advance |
| `progress` | `rate` | fraction per second, same rule |

```jsx
<slider value={track.position} min={0} max={track.duration}
        rate={track.playing ? 1 : 0}
        onChange={({ value }) => seek(value)} />
```

- **`0` or absent is exactly today's behavior.** Every existing app is unchanged
  on the wire and on screen.
- **It only runs in a window.** A control in a collapsed panel is not animating
  a layer nobody can see (the same rule `spinner` follows), and the tick stops
  when `rate` returns to 0.
- **A new `value` re-anchors it.** Within one second of self-advance the
  difference is poll jitter and is ignored — snapping to it would twitch the knob
  backwards every three seconds for the whole track. Beyond that the app is
  telling us something (a seek, a new track) and the control jumps.
- **A drag suspends it** until mouse-up, and the emitted `change` still carries
  the dragged value. While the user is holding the thumb, they are the authority
  on where it is.
- Advancing is clamped at `max` (or 1 for `progress`).

No envelope change: `rate` is an ordinary prop on an existing kind, and an older
shell ignores it and renders a static control.

## Proposal: `ctx.platform.observe` — push invalidation (spec §6)

`rate` fixes the *scrubber*; it does nothing for the three seconds between a
track changing and the panel noticing. The general shape of that problem is that
**a poll is the right way to establish the truth and the wrong way to notice a
change**, and every monitor app has it.

macOS already broadcasts the change. `ctx.platform` grows two calls — available
to **every** app, unlike the Settings-only app-management calls that share the
bridge:

```js
await ctx.platform.observe("distributedNotification", "com.apple.Music.playerInfo");
await ctx.platform.unobserve("distributedNotification", "com.apple.Music.playerInfo");

export function onEvent(name, data, ctx) {
  if (name === "platform") pollNow();     // debounced; the poll is still the truth
}
```

```json
{ "type": "platform", "app": "music",
  "payload": { "id": 5, "call": "observe", "kind": "distributedNotification",
               "name": "com.apple.Music.playerInfo" } }
{ "type": "platformResult", "app": "music", "payload": { "id": 5, "ok": true } }
{ "type": "event", "app": "music",
  "payload": { "id": 0, "name": "platform",
               "data": { "kind": "distributedNotification",
                         "name": "com.apple.Music.playerInfo",
                         "userInfo": { "Player State": "Playing" } } } }
```

- **`call` is the verb, `kind` is the source.** Two axes, so they are two fields.
  `distributedNotification` is the only source implemented; the field exists from
  the start so a second one (a file, a defaults key) is a value rather than a new
  envelope.
- **It runs in the shell**, for the reason `ctx.apple` does: a
  `DistributedNotificationCenter` registration is per *process*, and the process
  the system knows is the one with the UI.
- **`platformResult` is an acknowledgement, not a value.** Registration is
  instant — but it can *fail* (an unknown kind, no capability host), and an app
  that believed it was watching something it is not would wait forever for an
  event that cannot arrive. So it is always answered, never dropped.
- **Registration is keyed by (app, kind, name) and is idempotent.** Re-declaring
  on every monitor pass is fine and is the obvious way to write it; without
  idempotence that would stack a handler per pass.
- **Observers are released for an app on every lifecycle transition** — the same
  point, and the same reasoning, as its wing: they belong to a live worker, and
  the fresh one re-declares what it still wants. A new connection generation
  drops all of them (§1).
- **`userInfo` is reduced to strings, numbers and booleans; everything else is
  dropped.** A distributed notification's payload is arbitrary and some senders
  carry data blobs; helpfully stringifying one would put an unbounded,
  unparseable value on a socket whose frame budget is 8 MiB and whose failure
  mode is losing the connection (§1). The event's job is to say *when*. For
  *what*, the app already has `ctx.apple` and a real query.
- **No new event type.** It arrives as §4.1's app-level id 0, the same convention
  `drop` and `notification` use.

Observing is passive: the notification is a broadcast the OS makes anyway, so it
never launches the app being watched — which matters, because the demo Music app
goes to some length never to start Music.app or Spotify.

## Proposal: the rest of `ctx.platform` — five more observe kinds, seven calls (spec §6)

`distributedNotification` proved the *shape*; it is a poor answer to most of the
questions apps actually have. Nothing broadcasts "the pasteboard changed". The
battery does not post a notification an app can name. "Am I online" is not an
edge at all, it is a state. And a calendar app cannot read the calendar from a
worker thread no matter how many notifications it subscribes to.

So the same envelope grows two things, and no third one: **more `kind`s** for
`observe`, and **seven `call`s** that produce a value.

```js
// observe — the same two calls, five more sources
await ctx.platform.observe("workspace",    "screenLocked");
await ctx.platform.observe("pasteboard",   "changed");
await ctx.platform.observe("power",        "changed");
await ctx.platform.observe("reachability", "changed");
await ctx.platform.observe("audio",        "changed");
await ctx.platform.observe("focus",        "changed");   // do not disturb

// call — request/reply, every one a Promise
const events = await ctx.platform.calendar({ from, to });     // ISO strings
const who    = await ctx.platform.workspace();
const here   = await ctx.platform.location();
const hits   = await ctx.platform.spotlight({ query, scopes });
const out    = await ctx.platform.audio();
const set    = await ctx.platform.setVolume(0.4);
await ctx.platform.speak("Standup in five minutes.", { voice, rate });
```

```json
{ "type": "platform", "app": "agenda",
  "payload": { "id": 21, "call": "calendar",
               "from": "2026-07-25T09:00:00Z", "to": "2026-07-26T09:00:00Z" } }
{ "type": "platformResult", "app": "agenda",
  "payload": { "id": 21, "ok": true, "data": [
    { "title": "Standup", "start": "2026-07-25T10:00:00Z", "end": "2026-07-25T10:15:00Z",
      "allDay": false, "calendar": "Work" } ] } }
```

### One envelope, two families

`call` is the verb, and each verb reads the fields it needs and ignores the rest
— so a new call is a new `call` value plus optional fields, never a new envelope
type, and an older shell answers `ok: false` for a verb it has never heard of
rather than leaving the app's Promise hanging.

- **Registry verbs** (`observe`, `unobserve`) are answered *synchronously*.
  Registration either happened or it didn't; there is nothing to wait for.
- **Calls** produce a value on a later turn — the `apple`/`capture` shape — and
  carry it in **`platformResult.data`**. A call with no answer (`speak`) omits
  `data` entirely rather than sending a null, the same rule `appleResult`
  follows, so a golden fixture can assert an exact object.

### The new observe kinds

| kind | names | payload |
| --- | --- | --- |
| `workspace` | `didActivateApplication`, `willSleep`, `didWake`, `screensDidSleep`, `screensDidWake`, `screenLocked`, `screenUnlocked` | `{bundleId, localizedName}` for activation, empty otherwise |
| `pasteboard` | `changed` | `{changeCount, types: [UTI], hasStrings}` |
| `power` | `changed` | `{level: 0…1, charging, onAC, lowPowerMode}` |
| `reachability` | `changed` | `{satisfied, expensive, constrained, interface}` |
| `audio` | `changed` | `{deviceName, volume, muted, transportType, batteryPercent?, reason}` |
| `focus` | `changed` | `{active, modeName?}` |

- **The name vocabulary is translated, not passed through.** An app writes
  `observe("workspace", "screenLocked")`, never `"com.apple.screenIsLocked"`.
  Those raw names are split across two *different* notification centers — app
  activation and sleep live on `NSWorkspace`'s, lock and unlock are undocumented
  distributed notifications — which an app has no way to know and no business
  knowing, and they are Apple's to rename. A name outside the vocabulary is
  refused **with the list of the ones that exist**, rather than registering
  something that can never fire. `distributedNotification` keeps its open
  vocabulary, because there the names genuinely belong to whoever posts them.
- **One name per state-shaped kind.** `pasteboard`, `power`, `reachability` and
  `audio` all use `changed` and put *what* changed in the payload (`audio` adds
  a `reason`). An app that cares about the volume nearly always also cares about
  the headphones being unplugged; making it register twice for one concept would
  be a worse API than one scalar it can branch on.
- **Shared OS resources are refcounted.** Each kind is *one* resource in the
  shell — a poll timer, an `NWPathMonitor`, an IOKit run-loop source, a pair of
  CoreAudio property listeners — created when the first observer arrives and torn
  down at zero. Six apps watching the battery cost one run-loop source. The
  teardown direction is the one that matters: a pasteboard poll left running is a
  timer firing twice a second, forever, for nobody.
- **State kinds fire immediately on registration.** `power`, `reachability`,
  `audio` and `focus` describe a state, and an app that had to wait for the *next* change to
  learn the current one would show a blank battery until the machine happened to
  cross a percent — which on AC power is never. So registering delivers the
  current value, and no app needs a separate read call for what it just
  subscribed to.
- **`pasteboard` is polled, because nothing broadcasts it.** `changeCount` at
  2 Hz, and *only* while somebody is watching — which is precisely why the
  refcount exists. The event carries the change count, the readable UTIs and
  whether there is text, and **never the contents**. That is a deliberate
  privacy line: the pasteboard holds passwords roughly as often as it holds
  anything else, and a push event nobody asked for is the wrong place for them.
  An app that genuinely wants the clipboard shells out to `pbpaste`, which is a
  visible, greppable act in that app's own source. This event is the
  *invalidation signal*, which is the job it does for every other kind too.
- **`focus` is a file read, and it is quiet rather than wrong.** macOS
  broadcasts nothing when Do Not Disturb changes and offers no public API to ask
  — but the user's own Focus database at `~/.../DoNotDisturb/DB` is a JSON file,
  which is the mechanism every third-party menu-bar tool already uses and
  specifically *not* a private framework. Two things can go wrong with that: the
  undocumented format can shift under a macOS update, and the path is
  TCC-protected so a Ledge without Full Disk Access reads nothing. Both produce
  **no events at all**, never `active: false` — a wrong state is acted on, a
  missing one is not. (The shell searches the decoded JSON for the keys it needs
  rather than walking a fixed path, so a re-nesting is survivable; and it
  watches the *directory*, because the file is replaced rather than edited.)
  Payloads are deduped: that file is rewritten for more than mode changes.
- **Scalars only, still.** The §6 reduction rule binds every kind, not just the
  first: strings, numbers, bools (and, for `pasteboard.types`, an array of
  strings). Nothing nested, so no app has to guess and no frame is unbounded.

### The seven calls

| call | payload out | `data` back |
| --- | --- | --- |
| `calendar` | `{from?, to?}` ISO-8601 | `[{title, start, end, allDay, calendar, location?}]` |
| `workspace` | — | `{frontmost?: {bundleId, localizedName}, idleSeconds, screenLocked?}` |
| `location` | — | `{lat, lon, accuracyMeters, timestamp}` |
| `spotlight` | `{query, scopes?}` | `[{path, name, contentType, modified?}]` |
| `audio` | — | `{deviceName, volume, muted, transportType, batteryPercent?}` |
| `setVolume` | `{value}` | `{volume}` — the value actually applied |
| `speak` | `{text, voice?, rate?}` | *(none)* |

Every one of them is bounded, and the bounds are the interesting part:

- **`calendar`** defaults to now → +24 h and is **capped at 14 days**. A longer
  ask is *clamped*, not refused — "the next month" is a reasonable thing to want
  and an error there would be pedantry — but a year of a busy calendar in one
  socket frame is not something one app gets to do.
- **`spotlight`** takes an **NSPredicate metadata-query string**, defaults its
  scope to the user's home, and caps at 50 results and 5 seconds. A malformed
  predicate is an error *result*: `NSPredicate(format:)` raises an ObjC
  exception, which Swift cannot catch, so the shell parses with the failable
  metadata-string parser instead. One app's typo must not take down every other
  app's panel.
- **`location`** is reduced-accuracy, **times out at 8 s**, and the fix is
  **cached for 60 s**. A weather app polling on a timer would otherwise spin the
  radios once per poll for an answer that has not moved.
- **`setVolume`** clamps to 0…1 — `1.2` from an app doing arithmetic means "as
  loud as it goes" — and answers with what it applied, so the app learns it was
  clamped rather than believing it got 1.2. Clamping lives shell-side, next to
  the device that knows its own range.
- **`speak`** is capped at 500 characters and is **one utterance at a time**: a
  second `speak` while speaking *replaces* the first. Notch announcements are
  status, and status that queues is status that lies — an app announcing every
  price tick would build a backlog and still be reading out numbers from four
  minutes ago. The replaced call's Promise **resolves**: it was superseded, not
  failed, and nobody should be left awaiting a sentence that will never be
  spoken.
- **`audio`** reports `batteryPercent` only when the device publishes one (AirPods
  do via the IORegistry; most Bluetooth outputs do not). Absent means "this device
  does not say", which is not the same as zero.
- **`workspace`** omits `screenLocked` when the shell cannot know it cheaply, and
  `frontmost` when nothing is. A `false` where we do not know would be a worse
  answer than no key at all. It is the one call here with no permission story:
  every field is an in-process read.

### TCC, and what a refusal looks like

`calendar` and `location` are the two that raise a **TCC prompt**. Per §6's trust
model that is unchanged and deliberate: apps are trusted local code, macOS is the
consent layer, and the prompt is attributed to **the shell** — the process the
user recognizes — exactly as it already is for AppleScript and Screen Recording.
There is no Ledge-side grant UI, because adding one would only duplicate a prompt
the OS already shows better.

What that buys has to be paid for honestly:

- A denial is an ordinary `platformResult` with `ok: false` and a sentence naming
  the Settings pane. It **rejects** the app's Promise. It is never a crash, and a
  calendar app on a machine where the user said no should say so rather than
  disappear behind an error card.
- **Nothing ever blocks on a grant.** The prompt is a modal a person has to read;
  the notch keeps animating while they do. Host-side those two calls get a
  two-minute deadline for the same reason `ctx.capture` does — the thing they are
  waiting for is a person — and `location` additionally bounds itself at 8 s once
  authorized, because "the user never answered" and "the radios never got a fix"
  are indistinguishable from inside the app.
- Every other failure — no default output device, a device that refuses a volume
  write, a query that never finishes gathering, a shell built without a facade —
  is the same shape: answered, with a reason, never dropped.

### Why the shell and not the worker

The same argument `ctx.apple` runs on, in six shapes. `NSWorkspace`, CoreAudio's
property listeners, the IOKit power run-loop source and `NWPathMonitor` are all
per-*process* registrations, and the process the system knows is the one with the
UI. EventKit and CoreLocation attribute their consent prompts to the process that
asked, and a Bun worker is a faceless thread the user has no way to recognize or
approve. `AVSpeechSynthesizer` is an audio session the shell owns. None of this
is a wrapper over something a worker could do for itself — which is still the
whole rule for what `ctx` is allowed to carry.

## Proposal: worker-requested expand / collapse (spec §3.3)

§3.3 already defines `expand` and `collapse` host → shell; this is the worker
half, so an alarm can put itself on screen when it goes off:

```js
ctx.expand()      // → { type: "chrome", request: "expand" }
ctx.collapse()
```

Denial stays silent, per §3.3, and there is exactly one genuine reason to deny an
`expand`: the app has no tree yet, so opening would show the placeholder card
instead of the app — worse than not opening. `collapse` is honored only for the
app that is actually presented; anything else would let a background app close
the panel out from under the user.

`attention` (§3.3, already on the wire via `ctx.notify`/`ctx.attention`) now
draws something: a short accent glow stroked around the notch shape, additive,
touching neither the shape nor any hover state.

## Proposal: `ctx` is ten calls, not four (spec §6)

§6 calls `ctx` "deliberately tiny — only the four bridges". The four became
eight — `update`, `notify`, `attention`, `apple`, plus `draw`, `wing`, `expand`,
`collapse` — the agentic wave added `capture` and `agent`, and
`platform.observe`/`unobserve` made it eleven, with `apple`
finally doing what §6 always said it did. The Apple-platform wave adds seven more
under `ctx.platform` (calendar, workspace, location, spotlight, audio, setVolume,
speak), and counting is no longer the useful way to describe this.

The *principle* is unchanged and is what should be read as the rule: **`ctx`
carries only what the app's own process cannot do.** Every one of the eighteen
passes it. AppleScript, notifications, screen capture, EventKit and CoreLocation
need the shell, because macOS attributes consent to the process with the UI;
`NSWorkspace`, CoreAudio, the power run-loop source and `NWPathMonitor` need it
because those registrations are per-process; `ctx.agent` needs the host, because
it spawns the user's own agent CLI in the app's folder (and Ledge still never
calls a model API — §8). No wrapper over `fetch`, no persistence helper, no
timer: everything an app can do for itself, it still does for itself, and the
day one of these becomes possible from a worker is the day it should leave `ctx`.

## Proposal: app-level events — id 0 (spec §4.1)

§4.1 addresses every event to a node id, which is right for `click`, `change`,
`hover` and `key` — they happen *to* a view. The agentic layer produces events
that happen to the **app**: a file dropped on the panel, a notification button
pressed. There is no node to name, and inventing one would mean an app has to
mount an invisible view to be reachable.

Node ids are allocated by the reconciler and start at 1 (§3.1), so **0 is free**
and means exactly this:

```json
{ "id": 0, "name": "drop",         "data": { "paths": ["/Users/you/x.pdf"] } }
{ "id": 0, "name": "notification", "data": { "id": 7, "action": "execute" } }
{ "id": 0, "name": "swipe",        "data": { "direction": "left" } }
{ "id": 0, "name": "platform",     "data": { "kind": "distributedNotification",
                                             "name": "com.apple.Music.playerInfo",
                                             "userInfo": { … } } }
```

The host routes them like any other event; the worker dispatches id 0 to the
app's optional **`onEvent(name, data, ctx)`** export instead of to a prop
handler, the same shape and the same "no export, quietly ignored" contract as
`onLifecycle`. No envelope change, no version bump: a shell that never sends one
and an app that never exports the handler both behave exactly as before.

### `swipe` — withdrawn (Phase F2)

A horizontal flick used to mean two things: an id-0 `swipe` event addressed to
whichever app owned the wing, and "put this peek away" on a mini. Both are gone.

Principle 9 gives the whole product three gestures — a click, a horizontal swipe
that **walks the session strip**, and a drag that parks the panel — and all
three are the shell's. An app-defined swipe made a fixed vocabulary
app-extensible; a swipe that dismissed a notification taught a gesture nothing
else in the product has, in the one place a user is least able to experiment.

So: a horizontal flick across the **visit** walks the strip, which is the same
code path `‹|›` uses. A flick across the collapsed pill or a swell does nothing.
`SwipeRecognizer`'s policy is unchanged — 28 pt of travel, at least 1.5× more
horizontal than vertical, once per gesture, momentum ignored — only its
destination is. Apps that still export a `swipe` handler never hear from it; the
event is simply no longer emitted, so nothing breaks and nothing fires.

## Proposal: `summary` — the hover's glance surface (spec §5, §3.3)

flow.md gives the notch two swells, not one. The **notification** is the app
interrupting (`ctx.peek`, the `mini` node); the **summary** is the user asking —
a hover that rests on the notch past **Th** — and it needs its own node.

```json
{ "op": "create", "id": 2, "kind": "summary", "props": {} }
{ "op": "insert", "parent": 1, "id": 2, "before": null }
```

Everything about the shape is `mini`'s, deliberately: a root-level zone, one row
tall, children only, no props, rejected by §3.1 validation if it is nested
anywhere but the root (`invalid-commit-nested-summary.json`). The two swells
share a geometry, so a summary that could measure itself differently would make
the notch grow to two different heights for the same one line.

**A sibling node rather than a prop on `mini`,** because the difference between
the two is *who raises the surface*, and that is entirely the shell's decision.
An app cannot ask for a summary and cannot refuse one; it can only declare what
one would say. Declaring one is what makes a session **heavy**: hover ≥ Th shows
it. A session that declares none is its own summary (principle 8) and the same
hover opens the visit directly — which is why this is a node and not a flag, as
"has content" and "wants the behaviour" must not be able to disagree.

**The chevron is not the app's.** flow.md: "The summary always shows a quiet open
affordance — it must be obvious that a click opens the full thing." The shell
draws it, outside the app's node, in `ink-3`, and pays for it out of the
surface's own width so the app's content never shrinks to make room for
something it did not ask for. An affordance an app could forget to draw is an
affordance half the sessions would not have.

Fixtures: `commit-summary.json` (mount), `commit-summary-update.json` (an
ordinary in-place update of a summary child), `invalid-commit-nested-summary.json`.

## Proposal: `variant="ghost"` and `image.stroke` — the app tier (spec §5)

Two small additions, both surfaced by building Now Playing (F2.3), and both the
same shape of gap: a rule design.html states that no app could obey.

**`variant="ghost"`.** §06 gives Ledge two control tiers — the shell's convex
**beads** on the wing bar, and, among app content, **bare pure-white glyphs**
with no background at all and a capsule only under the cursor. The shell had
`LedgeButtonVariant.ghost` from F2; the wire did not, so `ProtocolRenderer`
mapped no string to it and every app's transport pair came out as a plain chip.

```json
{ "op": "create", "id": 5, "kind": "button",
  "props": { "icon": "sf:play.fill", "variant": "ghost", "onClick": true } }
```

The wire vocabulary becomes four words: `plain`, `glass`, `accent`, `ghost`.
**`bead` stays shell-only** — an unknown variant falls back to `plain`, and
`bead` is deliberately left unknown, because an app that could name it would
make its own buttons indistinguishable from Ledge's controls. That is a ruling
about *meaning*, so it lives in the renderer rather than in `ShadowTree`: the
wire's job is types, and `"bead"` is a perfectly good string.

**`image.stroke`.** The same hairline token set as `stack.stroke` (`hairline`,
`accent`, `green`, `red`, `violet`), drawn as a 1 pt ring on the image view
itself. Artwork letterboxes — an album sleeve is square, an artist photo is not —
and a well whose frame disappeared the moment the bitmap failed to fill it is
not a well. The alternative an app has today is wrapping the picture in a
stroked `stack`, which double-frames it whenever a bitmap *does* fill the box.
It applies to both kinds of `image`: a file bitmap and an SF Symbol.

Both are **resolved from the merged prop set** rather than read as optional, so
`stroke: null` really does take the ring away (§3.1) instead of reading as
"unchanged" — the create-only-prop bug that `button.disabled` already paid for.

Fixtures: `commit-app-controls.json` (two ghosts, a `bead` an app should not
get, a stroked file image, a stroked symbol, an unframed image) and
`commit-app-controls-update.json` (bead → ghost, ghost → plain, a stroke deleted
and a stroke added, all in place).

## Proposal: Reduce Motion on `lifecycle` (spec §4.2)

Principle 10 was unobeyable from a worker. `accessibilityDisplayShouldReduceMotion`
is an AppKit preference; a Bun process cannot read it, and every animating app in
the demo set — two level meters and a progress bar — animated regardless of what
the user had asked for.

It rides the existing envelope rather than getting one of its own:

```json
{ "phase": "collapsed", "reduceMotion": true,
  "screen": { "notchWidth": 189, "menubarHeight": 32, "scale": 2 } }
```

**Why `lifecycle` and not a new envelope, or a `platform` observe kind.** It is
the same *kind* of fact `phase` is: an instruction about how hard to work,
delivered on the channel an app already reads to decide exactly that. An app
that honours "stop animating while collapsed" and an app that honours "stop
animating because the user asked" are the same three lines in the same function.
A `platform` observe kind would have made it opt-in, and an accessibility
preference that an app must remember to subscribe to is one most apps will not.

**Absent means unchanged, not false.** A shell that predates the flag must not
read as "motion is fine" on every phase change.

**Two deliveries, so the value is always current.** The shell re-sends a
`lifecycle` — same phase, new flag — to every running app the moment the setting
changes; and it sends one to each app as it *starts*, which is §4.2's "once on
connect" finally implemented, on the side that actually knows the phase.

On the host it lands as **`ctx.reduceMotion`**: a plain read-only boolean,
updated in place *before* `onLifecycle(phase, ctx)` is called. A property rather
than a callback argument because the code that has to obey it is a draw loop —
`if (ctx.reduceMotion) return;` inside a `setInterval` is the shape apps
actually need, and a flag captured once at boot is a flag that goes stale the
first time the user flips the switch.

The law, in REFERENCE.md's words: *a canvas that animates must go still when
this is true.* Still — not slower, and not blank.

Fixture: `lifecycle-reduce-motion.json`. `lifecycle-expanded.json` keeps no such
key on purpose, so both suites replay the absent case too.

## Proposal: `class` on `peek` — ambient and alert (spec §3.3)

```json
{ "v": 1, "app": "alarm", "seq": 13, "type": "chrome",
  "payload": { "request": "peek", "class": "alert" } }
```

flow.md's Ti knob has two halves: "**Ti** ≈ 6 s for ambient-class, alert-class
holds". One field carries the whole of it. An **ambient** notification retracts
on its dwell; an **alert** holds until it is acted on or dismissed, because the
one thing an alarm must not do is time out while the user is looking away.

Absent is ambient, and so is any value the shell has not heard of — a
forward-compatible wire must never be able to produce a swell that never goes
away. Urgency stays *ink*, never geometry (flow.md, Edges): an alert and an
ambient notification are the same silhouette for the same duration of arrival,
and only the retract differs.

Fixture: `chrome-peek-alert.json`.

## Proposal: `apple` — AppleScript and Shortcuts, executed by the shell (spec §6)

§6 has always said `ctx.apple` is "executed by the shell process (workers can't
own TCC prompts; macOS handles consent natively)" — but there was no envelope
for it, so the host replied *not implemented*. Two envelopes close it:

```json
{ "type": "apple", "app": "meeting",
  "payload": { "id": 3, "kind": "script", "source": "return 1 + 2" } }
{ "type": "apple", "app": "inbox",
  "payload": { "id": 4, "kind": "shortcut", "name": "Log Note", "input": { … } } }
```

```json
{ "type": "appleResult", "app": "meeting", "payload": { "id": 3, "ok": true, "value": 3 } }
{ "type": "appleResult", "app": "inbox",   "payload": { "id": 4, "ok": false, "error": "…" } }
```

- **`id` is the worker's request id**, and worker ids restart at 1 in every
  worker (§3.1) — so a result is matched on **(app, id)**, never on id alone.
- **`kind` is validated before execution.** An unknown kind, or a `script`
  without a `source`, is answered `ok: false` rather than dropped: the app is
  awaiting a Promise, and a silent drop just moves the failure to a timeout.
- **`value` is best-effort JSON.** AppleScript's type system is larger than
  JSON's, so booleans, numbers and lists keep their shape and everything else
  arrives as the string AppleScript itself would print. An app that wants
  structure builds a string in the script — the same thing it would do in a
  terminal.
- **The shell runs both off the main queue** (an Apple event to another app can
  block for seconds) and serially (two concurrent `NSAppleScript` executions
  fail with OSA −1751; the notch keeps animating either way).
- **10 s host-side timeout.** On expiry the host forgets the request and answers
  the app; a result arriving later is **dropped**, never delivered to a Promise
  the app has already seen settle. Requests are also forgotten on every
  lifecycle transition (§6 rule 3: nothing lands after death) and on disconnect.

Consent stays where §6 put it: macOS TCC, prompting for the *shell*, which is
the process the user can recognize. Ledge adds no grant UI of its own — apps are
trusted local code (§6 trust model), and a second consent dialog in front of the
system's own would only teach people to click through both.

## Proposal: `notify` — notifications with actions, posted by the shell (spec §6)

`ctx.notify` used to be `osascript -e 'display notification'` from the host, a
documented interim. It moves to the shell for one reason worth the envelope:
**buttons**. "[Execute] [Skip]" in the banner is the entire agentic approval
loop, and only `UNUserNotificationCenter` — i.e. only a bundled app — can draw
them.

```json
{ "type": "notify", "app": "deals",
  "payload": { "id": 7, "text": "…under your $300 target", "title": "Deal Watch",
               "actions": [{ "id": "open", "label": "Open listing" },
                           { "id": "snooze", "label": "Snooze a week" }] } }
{ "type": "notifyAction", "app": "deals", "payload": { "id": 7, "action": "open" } }
```

- **Fire and forget.** There is no `notifyResult`: `ctx.notify` awaits nothing,
  and an ack would make every app pay a round trip none of them use.
- **`id` comes back**, so an app tells its own notifications apart —
  `ctx.notify` therefore *returns* the id it allocated.
- **`attention` is not in the payload.** The notch glow is still its own §3.3
  `chrome` request, so a notification with a glow is two envelopes and either
  can arrive alone. Nothing about the old behavior changed.
- **A click on the body reports the action `opened`** — and the shell opens the
  notch at the posting app. The app hears `{ id, action: "opened" }` on the id-0
  `notification` event *and* finds itself presented, so it can render
  because-of-a-notification UI (the ringing alarm jumping straight to its
  dismiss card, say). Button presses do **not** auto-open — the app decides
  (`ctx.expand`). A dismissal reports nothing, because declining to engage is
  not a decision an app should act on.
- **`UNUserNotificationCenter` only — there is no fallback.** Unbundled
  (`swift run`, the test harness), `ctx.notify` is a logged drop:
  `UNUserNotificationCenter.current()` traps with no bundle id, and a
  notification that cannot answer "what happens when the user clicks it?" is
  not a notification. Run the bundled shell (`Ledge.app`) for the real thing.

## Proposal: `capture` — a shell-owned screenshot (spec §6)

Same shape, same reasoning, one more permission: Screen Recording is granted per
process, and the process the user recognizes is the one with the notch.

```json
{ "type": "capture",       "app": "flights", "payload": { "id": 2, "interactive": true } }
{ "type": "captureResult", "app": "flights",
  "payload": { "id": 2, "ok": true, "path": "/var/folders/T/ledge-capture-9F3A.png" } }
```

- `interactive` (default **true**) is `screencapture -i`: the user drags out a
  region. Cancelling is `ok: false`, not an empty file.
- The PNG lives in the shell's temp directory and **is never deleted by Ledge** —
  an app that captured a boarding pass may still be reading it a minute later,
  and temp cleanup is the OS's job.
- The host timeout is **120 s**, because what it is waiting for is a person.
- **First use raises the Screen Recording prompt, attributed to Ledge.** That is
  the point of executing it shell-side, not a side effect to be worked around.

## Proposal: `ctx.agent` — one turn of the user's own agent (spec §8)

**No envelope.** `ctx.agent(prompt, { files, schema, timeoutMs })` runs
host-side, because it is a subprocess in the app's own folder and nothing about
it needs pixels or a TCC prompt. It is listed here so the capability set is in
one place, and because the rule it obeys is a protocol-level one: **Ledge never
calls a model API** (§8). There is no key and no endpoint anywhere in the host —
there is the agent the user already installed, run headless, exactly as the
builder chat runs it.

- **Adapter:** `claude` on PATH → `claude -p <prompt> --output-format json`, and
  the `result` field is the reply. `LEDGE_AGENT_CMD` overrides it with a command
  template (`{prompt}` is substituted, else the prompt is appended) — that is
  also the seam every test uses, so no test ever spends a token.
- **`files` are named in the prompt, not inlined.** The agent has file tools; a
  path lets it read only what it needs, and lets it read a 40 MB PDF at all.
- **`schema` appends "Respond ONLY with JSON matching this schema: …"**, strips
  the code fence agents add about half the time, parses, and retries **once**.
  An agent that ignores the schema twice will ignore it a third time, and every
  attempt costs the user.
- **One turn per app at a time.** A second concurrent call is refused
  (`{ ok: false, error: "agent busy…" }`), not queued: turns spend real money, so
  an app whose monitor outruns the agent should learn immediately rather than
  build a backlog it works through for an hour.
- **It never rejects.** A failed turn is `{ ok: false, error }`, because a throw
  inside `monitor` is an app crash with backoff (§6 rule 2) — far too big a
  hammer for "the CLI isn't installed".

## Proposal: the drop shelf (spec §4.1, §8)

Files dragged onto the **expanded** panel arrive as the id-0 `drop` event above.
The shell registers the notch surface as a dragging destination for file URLs,
and accepts only while expanded **and** with an app actually on screen — with no
addressee, refusing is the honest answer and leaves the drag's own feedback
truthful. The affordance is the panel's existing accent stroke around its own
outline, faded in for the duration of a valid drag; no new chrome, no new
palette entry. The collapsed pill is 210 pt of hardware notch, far too small a
target to be worth aiming at, so it is not a drop zone.
