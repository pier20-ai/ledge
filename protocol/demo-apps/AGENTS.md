# Writing Ledge apps

You are editing an app that lives in the macOS notch. A **Ledge app is one
folder**; `app.jsx` is its entry; the folder's name is the app's id. Save the
file and it hot-reloads in about 300 ms — the loop is files, so edit and look.

This document describes what the platform **actually does today**. Where it
disagrees with `docs/design/spec.md`, this file is right and the spec is behind.

---

## The smallest app

```jsx
/** @jsxImportSource react */
export const meta = { name: "Flights", icon: "sf:airplane" };

export default function App({ status = "—" }) {
  return (
    <stack axis="v" pad={14} gap={8}>
      <text content={status} size="l" weight="bold" />
    </stack>
  );
}
```

That is a complete, working app.

## Five rules that will break your app if you miss them

1. **`/** @jsxImportSource react */` on line 1 of every `.jsx` file.** Without
   it the JSX does not compile.
2. **Never put raw text inside an element.** `<button>Save</button>` is a hard
   error. Text is always `<text content="Save" />`, and buttons take
   `label="Save"`.
3. **Never add `react` to an app's own `node_modules`.** Both your app and the
   renderer must resolve the *same* React instance from the apps root; a second
   copy means every `useState` throws `dispatcher.useState of null`.
4. **`<wing side="left">` only.** The right side of the panel's top row is
   reserved by the shell.
5. **You cannot set the panel's width from JSX.** Ask via `meta.panel`.

## Exports the host looks for

| export | signature | purpose |
|---|---|---|
| `default` | `App(props)` | The view. Re-rendered whenever `ctx.update()` merges new props. |
| `meta` | `{ name?, icon?, panel? }` | Catalog identity. `icon` is an SF Symbol as `"sf:name"`. `panel` is `{ width?, maxHeight? }` in points. |
| `monitor` | `async monitor(ctx)` | Background work. Called in a loop — see below. |
| `onLifecycle` | `(phase, ctx)` | `"expanded" \| "collapsed" \| "hidden" \| "visible"`. Use it to stop animating while collapsed. |
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

A throw from `monitor` is an app crash: the worker restarts with backoff
(1 s → 2 min), and the stack lands in `crash.log` next to `app.jsx`. **Read
`crash.log` when something stops working** — it is written for you.

## Components

Every element maps to a real AppKit view. Layout is stacks only — no absolute
positioning, no CSS.

| element | required props | optional props |
|---|---|---|
| `stack` | — | `axis` `"h"\|"v"`, `gap`, `pad`, `align` `"leading"\|"center"\|"trailing"`, `distribute` `"fill"\|"equal"`, `flex`, `scroll`, `fill`, `stroke`, `radius` |
| `text` | `content` | `size` `xs\|s\|m\|l\|xl`, `weight` `regular\|medium\|semibold\|bold`, `color`, `mono`, `maxLines`, `truncate` |
| `button` | — | `label`, `icon`, `variant` `plain\|glass\|accent`, `size` `s\|m\|l`, `disabled`, `onClick` |
| `image` | `src` | `w`, `h`, `radius` |
| `spacer` | — | `min` |
| `chart` | `points: number[]` | `color`, `fill` |
| `slider` | `value` | `min`, `max`, `step`, `rate`, `onChange({value})` |
| `input` | — | `value`, `placeholder`, `onChange({value})`, `onSubmit({value})` |
| `canvas` | `w`, `h` | `focusable`, `onKey({key,down})` — pixels come from `ctx.draw` |
| `toggle` | `on` | `disabled`, `onChange({on})` |
| `segment` | `options`, `value` | `onChange({value})` |
| `stepper` | `value` | `min`, `max`, `step`, `format`, `onChange({value})` |
| `progress` | `value` | `rate` — read-only; never fake a slider with it |
| `spinner` | — | — |
| `pill` | `label` | `tone` |
| `wing` | `side="left"` | children — mounts into the panel's top-left zone |
| `mini` | — | children — the small surface below the notch, shown by `ctx.peek()`. Must be a direct child of the root. |

**Tokens.** `color`: `primary` `secondary` `tertiary` `green` `red` `accent`
`cyan` `violet`. `fill`: `raised` `raisedHover` `accentTint` `greenTint`
`redTint` `violetTint` `black`. `stroke`: `hairline` `accent` `green` `red`
`violet`. `pill` `tone`: `accent` `green` `red` `violet` `cyan` `neutral`.

Use the tokens, never a hex string — the shell owns the palette.

**`rate` on `slider`/`progress`** lets the shell advance the value itself
between updates (units per second). A progress bar for a known-duration task
should set `rate` rather than being driven by a timer.

### Three sizes of attention

An app can be on screen at three scales, and choosing the right one is most of
what makes it feel native:

| surface | how | when |
|---|---|---|
| **wing** | `ctx.wing({ text })` | Always-on and glanceable, inside the collapsed pill. A timer counting down, a live price. |
| **mini** | `<mini>…</mini>` + `ctx.peek(ms)` | A moment worth interrupting for, briefly. A track change, an alarm firing, your turn. |
| **panel** | the default export | Everything. Shown when the user hovers or clicks. |

`<mini>` goes **inside** your root stack — like `<wing>`, it is a direct child
of the root, not a sibling of it. Returning a fragment with `<mini>` next to
your panel gives the renderer two roots, and the shell rejects the whole commit.

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
always has it ready, so a peek appears instantly and a hover promotes straight
to the full panel. `ctx.peek()` only says *when*. Peeks are clamped to
0.5–20 s (default 4 s) — it is a glance, not a way to hold the notch open. Use
`ctx.expand()` when you genuinely want the panel.

### Layout and size

The root is a fixed width (440 pt by default; ask for more with
`meta.panel.width`). Height is measured from your tree and clamped. Content past
the clamp **clips** — there is no implicit scrolling; opt in with
`<stack scroll>`.

The panel reserves a row at the top for the camera housing, and a 42 pt app
strip at the bottom. You cannot draw in either. Do not render your own title
row: the shell already shows the app's name.

## `ctx`

Passed to `monitor`, `onLifecycle`, and `onEvent`. It contains **only** things
the platform cannot do — everything else is just Bun.

```
ctx.update(patch)                    merge into App's props + re-render
ctx.notify(text, { attention?, title?, actions? })
ctx.attention()                      notch glow, no notification
ctx.peek(ms?)                        show <mini> below the notch briefly (default 4 s)
ctx.expand() / ctx.collapse()        open or close the panel
ctx.wing(spec | null)                collapsed-notch live activity: { text?, width?, canvas? }
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
`reachability`, `audio`. Observations arrive at `onEvent`.

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

Ops: `clear`, `rect`, `line`, `text`, `image`. Frames arriving faster than the
display refreshes are coalesced — only the latest survives, so there is no point
drawing faster than ~60 Hz. **Stop drawing when `onLifecycle` reports
`"collapsed"`**; a game that renders into a closed notch is just burning battery.

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

`react`, `cheerio`, `chess.js`, and `stockfish` are already installed at the
apps root and can be imported bare. Prefer Bun's built-ins over a package — HTTP
is `fetch`, SQLite is `bun:sqlite`, shelling out is `Bun.$`.

## Splitting a large app

`app.jsx` is the entry, but not the limit — import siblings freely:

```jsx
import { evaluate } from "./engine.js";
```

Every source file in the folder is watched, so edits to any of them reload.

## When something breaks

1. `crash.log` in the app's folder — the stack from the last crash, plus recent
   console output.
2. A syntax error never starts a worker; it is reported as a crash with the
   parse error.
3. A crash loop backs off (1 s → 2 min, 5 attempts) and then stops. Fix the
   file and save — a save always restarts it.
