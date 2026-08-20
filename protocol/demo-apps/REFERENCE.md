# The Ledge API

Everything the platform offers, in the order you need it. `AGENTS.md` next to
this file is the short version — what an app is, the rules that break one, and
how to look at what you built. This is the lookup: every export, every
component, every prop, every `ctx` call.

It describes what the platform **actually does today**. Where it disagrees with
`docs/design/spec.md`, this file is right and the spec is behind. If something
is not here, it does not exist — the shell's Swift source is not on this
machine, and searching for it finds nothing, slowly.

---

## The apps in this folder

Seven, and each one is here to be *felt* on the notch — every surface in this
document is exercised by at least one of them. `nowplaying` and `weather` are
**default apps** (they ship); `timer`, `radio`, `beacon`, `chess` and `tetris`
are exercise apps. (`focus` retired to the archive at G2.9 — "not useful"; a
pranayama app takes its launch slot once its proposal is ratified.)
Read them as syntax; read `docs/design/principles.md` before you copy their
taste.

| app | what it exercises |
|---|---|
| `nowplaying` | the resting pill's owner: a **live-activity wing** (ticker + animated canvas) held while music plays and released when it stops · `ctx.apple` transport against Music.app and Spotify **without ever launching them** · `ctx.platform.observe("distributedNotification", …)` as a latency fix over a slow poll · `progress` with `rate` · a file-path `<image>` well · **no `<mini>`** — and an empty state that is one glyph and one line |
| `weather` | the **canvas app**: one `<canvas>` redrawn at ~11 fps from `ctx.draw`, whose frame is a *pure function of (t, weather(t))* — so a second canvas with `onDrag` (§4.1 `drag`, phases down/move/up) scrubs that same renderer through the next 24 h and eases home on release · the `gradient` op doing real work (sky, droplet lenses, a solved-alpha bloom, fog strips) · an **ambient** wing that is one ticker and never a live activity · Reduce Motion as a *still* that the scrub still moves · `fetch` against Open-Meteo + ip-api, cached beside `app.jsx` so a cold or offline launch still has a sky · **no `<mini>`** — weather never interrupts |
| `timer` | a wing **meter** (`meter: { value }` — the shell draws the bar) · an **alert-class** `ctx.peek` that holds until acted on, with one action in `<mini>` · `display` numerals, `caps` eyebrow, ghost icon buttons · a `setInterval` clock with a parked monitor |
| `radio` | a wing **canvas** animating at ~8 fps off `ctx.draw`, the same node drawn in the panel · a wing held as live activity and released when it stops |
| `beacon` | both notification classes back to back: **ambient** (glyph, one line, no action, retracts on Ti) and **alert** (one action, holds) · the three clicks on a swell — the action, elsewhere → visit, and nothing · `hero` numeral, `disabled` controls |
| `chess` | the **big well**: `meta.panel.width` asked *up* to 482 pt because a board is worth it (§09 — a true well may take the panel) · a `<canvas>` of ~120 ops per position, `image` ops naming this app's own sprite files, and one `onClick` turned into a square by two divisions · the grandfathered flat-vector sprite style (principle 11), and the one place raw hex is legal: draw ops are pixels, so a palette token here draws white · `Bun.spawn`ing Stockfish as a **UCI subprocess per move** (it cannot be `require`d under Bun — the header explains why) with a 2-ply built-in fallback · the whole panel is a well, one line and two ghosts — **no wing, no `<mini>`, no card, no label** |
| `tetris` | principle 5's worked example: **a score is a number**, so a 36 pt `display` numeral sits directly on the glass with `lv 6` beside it and nothing around either — the `SCORE`/`LINES`/`LEVEL` boxes are what the design reset was about · a `focusable` `<canvas>` with `onKey`, driven by a `setInterval` game loop and parked `monitor` · the next piece drawn *inside* the well rather than in a second framed canvas · a commit signature so a soft-drop point does not re-reconcile the panel · one ghost that starts, pauses, resumes and restarts · Reduce Motion audited and found to have nothing to switch off — every moving pixel is gameplay |

There is no `settings` app any more: Settings is a **native macOS window** drawn
by the shell (spec §8), and it turns apps on and off over the `appControl`
envelope rather than through a worker. The app that used to do that job is kept
at `protocol/demo-apps-archive/settings-app`, because it is still the only
worked example of the privileged `ctx.platform.*` surface described below.

`protocol/demo-apps-archive/` is **not** an apps root: nothing scans it, nothing
installs its dependencies, and nothing in it is a model for new work. Most of it
predates the design reset — `chess` and `tetris` were rebuilt *out* of it in
D4, engines copied verbatim and everything around them rewritten, and their
pre-reset originals stay there on purpose, because each new file's header cites
the old one line by line for what was cut.

## Exports the host looks for

| export | signature | purpose |
|---|---|---|
| `default` | `App(props)` | The view. Re-rendered whenever `ctx.update()` merges new props. |
| `meta` | `{ name?, icon?, panel? }` | Catalog identity. `icon` is an SF Symbol as `"sf:name"`. `panel` is `{ width?, maxHeight? }` in points. |
| `monitor` | `async monitor(ctx)` | Background work. Called in a loop — see below. |
| `onLifecycle` | `(phase, ctx)` | `"expanded" \| "collapsed" \| "hidden" \| "visible"`. Use it to stop animating while collapsed — and to notice a change in `ctx.reduceMotion`, which rides the same message. |
| `onEvent` | `(name, data, ctx)` | App-level events with no node behind them: `"drop"`, `"notification"`, platform observations. |

All except `default` are optional.

### The monitor loop

The host calls `monitor(ctx)`, **awaits it, then calls it again** — calls never
overlap. Pace it yourself:

```jsx
export async function monitor(ctx) {
  const quote = await (await fetch("https://api.example.com/AAPL")).json();
  ctx.update({ price: quote.c });           // merges into App's props, re-renders
  await Bun.sleep(60_000);                  // the pacing is yours
}
```

**The loop has a 1 s floor, and it is the trap in this API.** A pass that
returns faster than a second is topped up to one before the next call — the host
will not spin a worker. So `monitor` is a *poller*, and it cannot be a clock, a
frame loop, or a delay: a countdown written as `await Bun.sleep(250)` ticks
somewhere between 0.25 s and 1 s and visibly stutters, and "fire this in one
second" written as a short pass lands anywhere in two. Every app in this folder
hit it first and fixed it the same way.

**The fix: own the clock with a timer, and park the monitor.** Timers are
ordinary Bun — they run in the worker and die with it on reload or crash, which
is the right lifetime for anything you have not shown the user yet.

```jsx
let ctxRef = null;

export async function monitor(ctx) {
  ctxRef = ctx;
  commit();                                 // the first frame, immediately
  setInterval(tick, 250);                   // 4 Hz — the clock is yours now
  await new Promise(() => {});              // park: never resolves, never spins
}
```

The parked promise is the whole idiom: `monitor` is the only thing the host
awaits, so a promise that never resolves means it is called exactly once and the
timer owns the pacing from then on. Use it for anything sub-second (a countdown,
a meter, an animation) and for anything event-driven (`beacon` arms a
`setTimeout` from a button and parks with nothing to poll at all). Keep the real
polling shape — `await`, then `Bun.sleep` — for what it is for: fetching.

A throw from `monitor` is an app crash: the worker restarts with backoff
(1 s → 2 min), and the stack lands in `crash.log` next to `app.jsx`. **Read
`crash.log` when something stops working** — it is written for you. A throw
inside a `setInterval` callback is a crash too, so the parked-loop shape does not
lose you the error report.

## Components

Every element maps to a real AppKit view. Layout is stacks only — no absolute
positioning, no CSS.

| element | required props | optional props |
|---|---|---|
| `stack` | — | `axis` `"h"\|"v"`, `gap`, `pad`, `align` `"leading"\|"center"\|"trailing"`, `distribute` `"fill"\|"equal"`, `flex`, `scroll`, `fill`, `stroke`, `radius`, `gradient` |
| `text` | `content` | `size` `xs\|s\|m\|l\|xl\|display\|hero`, `weight` `light\|regular\|medium\|semibold\|bold`, `color`, `mono`, `maxLines`, `truncate`, `caps` |
| `button` | — | `label` **or a child**, `icon`, `variant` `plain\|glass\|accent\|ghost`, `size` `s\|m\|l`, `disabled`, `onClick` |
| `image` | `src` | `w`, `h`, `radius`, `stroke` |
| `spacer` | — | `min` |
| `divider` | — | — |
| `chart` | `points: number[]` | `color`, `fill` |
| `slider` | `value` | `min`, `max`, `step`, `rate`, `onChange({value})` |
| `input` | — | `value`, `placeholder`, `onChange({value})`, `onSubmit({value})` |
| `canvas` | `w`, `h` | `focusable`, `onKey({key,down})`, `onClick({x,y})`, `onDrag({phase,x,y})` — pixels come from `ctx.draw` |
| `toggle` | `on` | `disabled`, `onChange({on})` |
| `segment` | `options`, `value` | `onChange({value})` |
| `stepper` | `value` | `min`, `max`, `step`, `format`, `onChange({value})` |
| `progress` | `value` | `rate`, `color` — read-only; never fake a slider with it |
| `spinner` | — | — |
| `pill` | `label` | `tone` |
| `wing` | `side="left"` | children — mounts into the panel's top-left zone |
| `mini` | — | children — one row in the notch's swell, shown by `ctx.peek()`: **the notification**. Must be a direct child of the root. |

**Tokens.** `color`: `primary` `secondary` `tertiary` `green` `red` `accent`
`cyan` `violet`. `fill`: `raised` `raisedHover` `accentTint` `greenTint`
`redTint` `violetTint` `black`. `stroke`: `hairline` `accent` `green` `red`
`violet`. `gradient`: `accent` `green` `red` `violet` `cyan`. `pill` `tone`:
`accent` `green` `red` `violet` `cyan` `neutral`.

`progress` `color`: `accent` `green` `red` `violet` `cyan` — **default is ink,
and ink is usually right.** A meter takes a hue when the moment it is measuring
is the point of the panel (Focus's running session, which is what design.html
§01 draws in accent); a panel where every bar is coloured has told you nothing.

Use the tokens, never a hex string — the shell owns the palette.

**A row keeps its children together — you do not need a trailing spacer.** A
row (`axis="h"`) that a column stretched puts its children side by side at its
leading edge and leaves the rest of the width over. It used to fling them to
opposite ends, so `<text size="display">27°</text>` beside a phrase read as two
unrelated facts, and apps ended every such row with a `<spacer />` to stop it.
That is no longer needed. A row that *does* hold a `<spacer />` — or anything
else with no width of its own: a divider, chart, slider, progress or input —
still fills, which is what makes `label · spacer · value` put the value hard
against the right-hand edge. `distribute="equal"` still shares the width evenly.

**`align` centres things — you do not need a spacer.** A column with no `align`
stretches every child to its width, which is how rows, cards and charts span the
panel. `align="center"` (or `"trailing"`) **places** them instead: a `<text>` is
sized to its own words and put where you said, and a `<button>` wrapping one is
the size of the thing it wraps rather than a panel-wide press target. Anything
too wide is capped at the column and truncates, so a long line stays inside the
panel. The words are `leading` · `center` · `trailing` — in a row they mean
top/middle/bottom, because `align` is always the **cross** axis. A `<divider />`
(and a chart, slider, progress or input) spans the column whatever the alignment
says: those have no width of their own.

```jsx
<stack axis="v" pad={16} gap={8} align="center">
  <text content="FOCUS" size="xs" caps />
  <text content="25:00" size="display" />
</stack>
```

**`gradient` is a wash, not a fill.** You name the hue family; the shell paints
it at the top of the container and fades it out by 60% of the height, behind the
children. Every app's wash is the same material, which is what keeps panels
looking related — so there is no angle, no stops and no second colour. It
composes with `fill` (background) and `stroke`. For a gradient you control,
draw one in a `canvas`.

**`rate` on `slider`/`progress`** lets the shell advance the value itself
between updates (units per second). A progress bar for a known-duration task
should set `rate` rather than being driven by a timer.

### Three sizes of attention

An app can be on screen at three scales, and choosing the right one is most of
what makes it feel native:

| surface | how | when |
|---|---|---|
| **wing** | `ctx.wing({ text })` | Always-on and glanceable, inside the collapsed pill. A timer counting down, a live price. |
| **notification** | `<mini>…</mini>` + `ctx.peek(ms)` | A moment worth interrupting for, briefly. A track change, an alarm firing, your turn. |
| **panel** | the default export | Everything. Shown when the user clicks. |

A rested pointer on the notch opens the panel directly.

`<mini>` goes **inside** your root stack — like `<wing>`, it is a
direct child of the root, not a sibling of it. Returning a fragment with one next
to your panel gives the renderer two roots, and the shell rejects the whole
commit. Nesting one inside a card is the same rejection: it would render into a
surface its parent cannot see.

```jsx
const NOTHING_PLAYING = { title: "—", artist: "", art: "sf:music.note" };

export default function App({ track = NOTHING_PLAYING }) {
  return (
    <stack axis="v" pad={14} gap={8}>
      <mini>
        <stack axis="h" gap={8}>
          <image src={track.art} w={28} h={28} radius={4} />
          <text content={track.title} weight="semibold" />
          <text content={track.artist} color="secondary" />
        </stack>
      </mini>

      {/* …the rest is the full panel */}
      <text content={track.title} size="l" weight="bold" />
    </stack>
  );
}

// …and elsewhere, when something actually happens:
export function onEvent(name, data, ctx) {
  if (name === "trackChanged") ctx.peek(4000);
}
```

`<mini>` is **declarative**: keep it rendering the current state and the shell
always has it ready, so a swell appears instantly and a click promotes straight
to the panel. `ctx.peek()` only says *when*. Peeks are clamped to 0.5–20 s (default 4 s) — it is a
glance, not a way to hold the notch open. Use `ctx.expand()` when you genuinely
want the panel.

`ctx.peek(ms, { class })` picks the priority class. `"ambient"` (the default)
retracts on its dwell; `"alert"` **holds** until the user acts on it or dismisses
it — for an alarm going off, not for a track change. Urgency is ink, never
geometry: an alert is the same shape, it just does not leave.

**A notification's action is just a `<button>` in the `<mini>`.** There is no
actions API and no "dismiss" call: put one button in the row, give it your
ordinary `onClick`, and the shell retracts the swell itself the moment the event
comes back — that is what makes an alert-class swell leave. So the handler only
does the app's own work:

```jsx
<mini>
  <stack axis="h" gap={10}>
    <image src="sf:bell.fill" w={18} h={18} />
    <text content="Alarm" size="s" weight="semibold" color="red" />
    <spacer />
    <button label="Stop" variant="plain" size="s" onClick={() => stop()} />
  </stack>
</mini>
```

**Do not call `ctx.collapse()` in that handler.** It is the obvious wrong guess
and it is wrong twice: the swell is not the panel, so `collapse` is not
addressed to it, and the shell has already retracted by the time your worker
sees the click. One action, at most — a swell with two decisions on it is a
dialog, and a dialog is what the panel is for.

**The `class` and the `<mini>` are two separate things, and keeping them in sync
is yours.** `<mini>` is *what* the row says and is declarative — it renders
whatever your current props say, always, whether or not a swell is up.
`ctx.peek(ms, { class })` is only *when*, plus how insistent. Nothing links
them: peeking `"alert"` does not turn the row red, and rendering a red row does
not make it hold. Set the state first, then ask — the worker→host channel is
FIFO, so a synchronous `ctx.update()` lands ahead of the peek that follows it:

```jsx
kind = "alert";
commit();                          // <mini> is now the alarm row…
ctx.peek(6000, { class: kind });   // …and only then is it raised
```

Peek first and the user gets one frame of the previous notification — the
track that just ended, the alarm you already cleared.

### The collapsed notch, in detail

`ctx.wing(spec)` owns the collapsed pill until you release it with
`ctx.wing(null)`. The spec is four optional fields, and each is a different
kind of presence:

```js
ctx.wing({ text: "3:41", width: 220, canvas: { id: artCanvasId, w: 30 } })
ctx.wing({ text: "12:04", meter: { value: 0.42 } })     // the stock bar
```

- **`text`** — a short label in the **left** wing (48 chars, then it is cut).
- **`canvas`** — a drawable strip in the **right** wing, `{ id, w }`. `id` is a
  canvas node's id, the same id you pass to `ctx.draw` — so a canvas in your
  panel and a wing canvas can be **the same node, drawn in two places**. Height
  is the notch's; `w` is a request the shell clamps (~160 pt).
- **`meter`** — `{ value }`, `0…1`: a bar in the **right** wing that the *shell*
  draws. Reach for this before a canvas whenever the answer is "how far along is
  it" — it costs one number per update and no draw loop, and every app's meter
  is then the same object (64 × 3 pt, capsule, ink — never a hue). Out-of-range
  values clamp, so a fraction that briefly computes 1.02 is a full bar rather
  than a glitch. A `canvas` in the same spec wins the wing: those are your
  pixels, this is the shell's shape.
- **`width`** — the total pill width. On its own, with no text and no canvas, it
  is a bare shape request: the notch simply grows.

A wing is **glanceable, not interactive**: the only gesture on the collapsed pill
is the click that opens you. The `"swipe"` event this used to deliver is
withdrawn — a horizontal swipe now walks the user's session strip, everywhere,
and belongs to the shell.

To draw artwork in the notch, render a `<canvas>` anywhere in your tree, keep
its id, and draw an `image` op into it:

```jsx
const art = useRef(null);
// …in the panel, or offscreen inside <mini> — it only has to exist:
<canvas ref={art} w={30} h={30} />

// then, whenever the track changes:
ctx.draw(art.current.id, [
  { op: "clear" },
  { op: "image", src: `${import.meta.dir}/art.jpg`, x: 0, y: 0, w: 30, h: 30 },
]);
ctx.wing({ text: track.title, canvas: { id: art.current.id, w: 30 } });
```

A wing survives until the app stops, crashes or reloads — the host releases it
for you then, so a reload never leaves a dead app's label in the notch. The
latest app to ask wins.

**Say it again, even when nothing changed.** The shell takes an idle wing back
after about ninety seconds (flow.md: *"Ambient | holder idle > Ta, or released |
Resting"*), and every `ctx.wing` call from the holder re-arms that clock — the
request is how an app says it is still alive, not only what it wants shown. So
the obvious shape:

```js
if (spec === lastSpec) return;      // ← this alone is a bug
ctx.wing(spec);
```

is a claim an app can make exactly once. A ticker that happens not to change for
two minutes — a five-minute track, a temperature, a radio station between songs
— loses the notch mid-session and can never get it back, because its own gate
says it has already asked for this. Keep the change check *and* a heartbeat:

```js
const stale = Date.now() - sentAt > 45_000;
if (spec === lastSpec && !stale) return;
lastSpec = spec; sentAt = Date.now();
ctx.wing(spec);
```

And in the other direction: **a live activity should describe the session, not
the sample.** A player between two tracks answers "nothing playing" for a beat;
releasing the wing on that reading and re-claiming it a second later makes the
notch blink once per song. Hold through a gap, change the ticker in place, and
let the *canvas* show the pause (nowplaying's wave eases to the floor and swells
back) — the surface should never leave.

### Layout and size

The root is a fixed width (440 pt by default; ask for more with
`meta.panel.width`). Height is measured from your tree and clamped. Content past
the clamp **clips** — there is no implicit scrolling; opt in with
`<stack scroll>`.

The panel reserves a row at the top for the camera housing, and a 42 pt app
strip at the bottom. You cannot draw in either. Do not render your own title
row: the shell already shows the app's name.

### Lists, rows and pages

Three things that keep coming up, none of which needs anything the vocabulary
does not already have.

**A row is a `button` with a child.** `label` is for a control; a list row is a
ticker, a name, a price and a pill, and the whole row should be pressable — a
chevron parked at the right-hand end makes the other 90% of it a dead zone. Put
the row inside the button and let `variant="plain"` supply the hover and the
press. `label`, `icon` and `size` describe the other form of the control and are
ignored while a child is present.

```jsx
<button variant="plain" onClick={() => open(card.symbol)}>
  <stack axis="h" gap={10} pad={10}>
    <text content={card.label} size="s" weight="bold" />
    <spacer />
    <pill label={card.change} tone="green" />
  </stack>
</button>
```

**`<divider />` is the rule between them.** No props: where it goes is yours,
what it looks like is the shell's. It is horizontal — in a row, the separation is
already `gap` and `spacer`.

**Pages are your own state.** There is no router, no `<nav>`, no route on the
wire. Which page the panel shows is `useState` in your component, and the shell
sees an ordinary commit that happens to replace most of the tree:

```jsx
const [focus, setFocus] = useState(null);
return focus
  ? <Detail symbol={focus} onBack={() => setFocus(null)} />
  : <List onOpen={setFocus} />;
```

Two consequences worth knowing. Resolve the detail page's data out of the props
you already render the list from, not out of what you captured at tap time — a
monitor pass landing while the page is open should update it in place. And
`useState` lives in the worker, so a crash or a reload puts the user back on the
first page; anything that must survive that belongs in `ctx.update` state or a
file.

**Reach for `variant="ghost"` before anything else.** Ledge has two control
tiers, and an app owns the lower one: a ghost is a **bare pure-white glyph** with
no background at all, and a capsule appears only under the cursor. Chips and
filled buttons belong to the shell's chrome; a transport pair, a dismiss, a
well's one action are all ghosts. (`variant="bead"` is the shell's own convex
control — an app that names it gets `plain`, deliberately.)

```jsx
<button icon="sf:pause.fill" variant="ghost" onClick={pause} />
```

**`image` takes a `stroke`.** Artwork letterboxes, and a sleeve that does not
fill its box would otherwise lose the frame the layout drew for it — so the
hairline goes on the picture, not on a wrapper:

```jsx
<image src={art} w={72} h={72} radius={14} stroke="hairline" />
```

Do not wrap the image in a stroked `<stack>` to get the same thing: that
double-frames it the moment a bitmap *does* fill the box.

**A long list scrolls with `<stack scroll>`,** and its ceiling is the *panel's*
whole content height. Every point a parent above it spends on `pad` is a point
the list asks for and cannot have, and the symptom is the last row hiding under
the app strip. Put the padding inside the scrolling stack instead — where it
scrolls away with the content, which is what a list wants anyway.

## `ctx`

Passed to `monitor`, `onLifecycle`, and `onEvent`. It contains **only** things
the platform cannot do — everything else is just Bun.

```
ctx.reduceMotion                     boolean — the user asked for less motion
ctx.update(patch)                    merge into App's props + re-render
ctx.notify(text, { attention?, title?, actions? })
ctx.attention()                      notch glow, no notification
ctx.peek(ms?, { class? })            swell the notch with <mini> briefly (default 4 s; class: ambient | alert)
ctx.expand() / ctx.collapse()        open or close the panel
ctx.wing(spec | null)                collapsed-notch live activity: { text?, width?, canvas?, meter? }
ctx.draw(id, ops)                    imperative canvas drawing, bypasses React
ctx.capture({ interactive? })        screenshot → file path
ctx.agent(prompt, { schema?, files?, timeoutMs? })   one turn of the user's agent CLI
ctx.apple.script(source)             AppleScript
ctx.apple.shortcut(name, input?)     Shortcuts
ctx.platform.calendar({ from?, to? })
ctx.platform.workspace()             frontmost app / open windows
ctx.platform.location()
ctx.platform.spotlight({ query, scopes? })
ctx.platform.audio() / ctx.platform.setVolume(v)
ctx.platform.speak(text, { voice?, rate? })
ctx.platform.observe(kind, name) / unobserve(kind, name)
```

`observe` kinds: `distributedNotification`, `workspace`, `pasteboard`, `power`,
`reachability`, `audio`, `focus`. Observations arrive at `onEvent`.

`focus` — `{ active, modeName? }` — is Do Not Disturb and the named Focus modes.
It is read from the user's Focus database, so it is **silent when it cannot be
read**: no Full Disk Access (or a format change in some future macOS) means no
events, never a false `active: false`. Write the app so "no focus event yet"
looks like "we don't know", not like "focus is off".

**Settings-only.** Five more calls exist, and only the app whose folder is
`settings` may make them — anything else is refused with a reason, by the host
and again by the shell. No shipped app claims that folder name today (Settings
is a native window), so read this as the shape of the privileged surface rather
than as something to reach for; the worked example is
`protocol/demo-apps-archive/settings-app`:

```
ctx.platform.stats()                 the catalog the strip is drawing
ctx.platform.enable(id) / disable(id)
ctx.platform.reorder(ids)            not implemented yet
ctx.platform.quit()                  end Ledge (there is no menu bar and no Dock icon)
ctx.platform.permissions()           raise the shell's permission surface
```

The gate is not bureaucracy: an app that could raise an official-looking consent
panel, or quit the shell, at a moment of its own choosing is exactly the ambush
those surfaces exist to prevent.

Everything else is the platform directly: `fetch`, `bun:sqlite`, `Bun.sleep`,
`Bun.$`, `fs`, timers, `import.meta.dir`, `console.*` (captured into the app's
log). Do not look for a Ledge wrapper — there isn't one, by design.

### Canvas and games

For anything animating faster than React should commit, render a `<canvas>` and
push ops imperatively. Get the node id with a ref:

```jsx
const board = useRef(null);
<canvas ref={board} w={240} h={480} focusable onKey={onKey} />
// then, per frame:
ctx.draw(board.current.id, [
  { op: "clear" },
  { op: "rect", x: 8, y: 8, w: 20, h: 20, fill: "#30D158", radius: 2 },
]);
```

| op | fields |
|---|---|
| `clear` | — (the whole canvas) |
| `rect` | `x`, `y`, `w`, `h`, `fill`, `radius` — filled, not stroked |
| `line` | `points: [[x,y], …]`, `stroke`, `width` |
| `text` | `x`, `y`, `content`, `size`, `color` |
| `image` | `src` (an absolute file path), `x`, `y`, `w`, `h`, and `sx`/`sy`/`sw`/`sh` to draw one cell of a spritesheet, in image pixels from the top-left |
| `gradient` | `x`, `y`, `w`, `h`, `from`, `to`, `angle` (degrees clockwise from top-to-bottom, default 0), `radius` |

**Scrubbing a canvas.** `onDrag` reports the whole gesture — `phase` is
`"down"`, `"move"` or `"up"`, with the point in the same y-down space as the
ops:

```jsx
<canvas w={416} h={44} onDrag={({ phase, x }) => {
  setPreview(timeAt(x));            // `move` arrives throttled to ~30 Hz
  if (phase === "up") commit(timeAt(x));   // …and `up` is the exact final point
}} />
```

The point is **not clamped** to the canvas — drag past the edge and `x` goes
negative or past `w`, so your track decides whether it saturates or wraps.
`click` and `drag` are independent: declare both and you get both on press.

Draw ops take **hex colours** (`#30D158`, `#FFF`, `#30D158CC`), not the palette
tokens — a canvas is pixels, not a view, and a token here silently draws white. Frames arriving faster than the display refreshes are coalesced — only the latest survives, so there is no point
drawing faster than ~60 Hz. **Stop drawing when `onLifecycle` reports
`"collapsed"`**; a game that renders into a closed notch is just burning battery.

### Reduce Motion — `ctx.reduceMotion`

**A canvas that animates must go still when this is true.** It is the system's
Reduce Motion switch (macOS Settings → Accessibility → Display), which a worker
cannot read for itself, so the shell reads it and puts it on `ctx`. It is always
current: it arrives with the `lifecycle` your app gets when it starts, and the
shell re-sends one to every running app the moment the user flips it.

Read it as a **property, inside the loop** — not from an argument, and not once
at boot: the switch can flip while your interval is running.

```jsx
function tick() {
  if (ctx.reduceMotion) return still();   // one frame per state, then nothing
  frame += 1;
  paint();
}

export function onLifecycle(phase, ctx) {
  paint();      // the flag may have just flipped; draw the frame it implies
}
```

Still, **not slower and not blank**. The meter keeps reading — it stops moving
between readings. In practice:

- a level meter or waveform → a fixed profile that still says "playing";
- a progress bar → quantise it (ten steps, not a creeping pixel);
- `<progress rate>` → send `rate: 0`, because the shell's self-advance between
  commits is an animation too;
- data that happens to change (a clock, a track title) → **keep changing it**.
  A radio that stopped rotating tracks would be broken, not accessible.

## Persistence

Apps own their own storage, in their own folder, via `import.meta.dir`:

```jsx
import { Database } from "bun:sqlite";
const db = new Database(`${import.meta.dir}/history.sqlite`);
```

Use **SQLite (WAL)** for anything append-heavy. For JSON, write a temp file and
`rename` it over the target — a half-written JSON file is a crash loop on next
boot, and `rename` is atomic.

Data files are yours and are never reloaded on. Only **source** files
(`.jsx` `.js` `.ts` `.tsx`) trigger a hot reload, so a monitor caching to
`prices.json` will not restart itself.

## Dependencies

`react` is already installed at the apps root and can be imported bare. Prefer
Bun's built-ins over a package — HTTP is `fetch`, SQLite is `bun:sqlite`,
shelling out is `Bun.$`. Anything else goes in the apps root's `package.json`
and is **paid for in the .app bundle**, so it needs a reason.

Two packages have one: `chess.js` (legality and SAN — 784 KB) and `stockfish`.
Stockfish is the cautionary tale. The package is 239 MB because it ships every
build it can make, and all but ~7 MB of that is builds no app loads;
`scripts/bundle-app.sh` prunes it to the single `lite-single` pair before the
seed is tarred, which is the pattern any heavy dependency has to follow. An app
that cannot degrade without its heavy dependency should not have one — chess
can, and falls back to a built-in search with no evaluation.

## Splitting a large app

`app.jsx` is the entry, but not the limit — import siblings freely:

```jsx
import { evaluate } from "./engine.js";
```

Every source file in the folder is watched, so edits to any of them reload.
