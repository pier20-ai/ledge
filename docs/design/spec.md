# Ledge — Notch App Platform Protocol Spec

**v0.4.** Three processes: the **Swift shell** (rendering surface, AppKit), the **Bun host** (router, transpiler, file watcher), and one **Worker per app** (React + user code, Bun runtime). Division of state: **the host owns durable truth** (the intended view tree, the catalog); **Swift owns transient presentation** (live NSView instances, focus, hover, animation progress, text composition, canvas buffers, expansion state); **apps own their own persistence** (files in their own folder). Nothing round-trips another's half: on doubt, the host re-renders and Swift rebuilds.

*v0.4: the notch chat UI ships, but as a frontend over the user's own agent in headless mode (Claude Code / Codex) — Ledge never calls a model API directly; per-app session pointers; builder event stream in the control plane.*

*v0.3: Bun runtime (native JSX transpile, `bun:sqlite`, `Bun.sleep`, `$` shell), everything under `~/.ledge/`, ctx shrunk to four calls (platform APIs used directly — `fetch`, `import.meta.dir`, timers), apps own persistence, permission plumbing removed (macOS TCC covers Automation), `AGENTS.md` + `ledge` CLI, §9 resolved.*

```
┌─ app.jsx (worker) ─┐      ┌─ Bun host ──┐        ┌─ Swift shell ─┐
│ React reconciler   │──────▶ multiplexer  │──UDS──▶ NSView tree    │
│ monitor() loop     │◀──────  per-app tag │◀──────  events, lifecycle
└────────────────────┘      └─────────────┘        └───────────────┘
```

---

## 1. Transport

- **Unix domain socket** at `~/.ledge/ledge.sock`. Swift listens; the Bun host connects. One connection, all apps multiplexed.
- **Framing:** `uint32` little-endian byte length, then exactly that many bytes of UTF-8 JSON. A stream socket may split or coalesce writes arbitrarily, so both ends run the same read loop: append received bytes to a buffer; while the buffer holds ≥4 bytes and ≥(4 + length) bytes, extract one frame; repeat. Partial frames simply wait in the buffer.
- **Max frame size: 8 MiB.** A declared length above the cap, a length the sender never completes within 30 s, or a payload that fails to parse as JSON means the stream can no longer be trusted byte-aligned — the receiver closes the connection. There is no in-band recovery from a malformed frame.
- **Connection generations.** Swift keeps a monotonic `gen`, incremented per accepted connection, exchanged in `hello` (§3.6/§4.3). All `seq` counters are scoped to `(gen, app, sender)` and start at 1 — reconnect resets them by construction, so no "stale seq after reconnect" ambiguity exists.
- **Reconnect:** on drop, the host retries with backoff (250 ms → 5 s). After `hello`, it sends `catalog`, then a fresh full `commit` per running app; Swift has already discarded all view state for dead generations.
- **Resync:** either side that detects per-app inconsistency (failed commit validation, missing view id) sends `resyncRequest` for that app instead of guessing; the host responds with a fresh full commit. Resync is per-app; connection close is the whole-stream escape hatch.

## 2. Message envelope

Every frame, both directions:

```json
{ "v": 1, "app": "stocks", "seq": 412, "type": "commit", "payload": { } }
```

- `v` — protocol version. Mismatch → receiver logs and drops.
- `app` — app id = **its directory name** under `~/.ledge/apps/` (canonical; see §6). Empty string for shell-level messages (§3.6, §4.3).
- `seq` — monotonic counter scoped to `(gen, app, sender)`. Receiver ignores stale (`<= last`) seq for that scope.
- `type` + `payload` — below.

## 3. Node → Swift

### 3.1 `commit`
One frame per React commit. Mutations apply **in array order, all-or-nothing**. `CATransaction` only batches visuals — it can't roll back — so Swift gets atomicity by **validating the full mutation list against a shadow tree first**: a lightweight `id → (kind, parent, children)` map mirroring the real views. Every op is checked (ids exist, no duplicate create, parent is attachable, props type-check for the kind) and applied to the shadow copy; only if the entire list validates does Swift touch NSViews, inside one `CATransaction`. On any validation failure the whole commit is discarded, the shadow tree reverts, and Swift sends `resyncRequest` for that app.

```json
{ "mutations": [
  { "op": "create",  "id": 7, "kind": "text", "props": { "content": "$214.62", "size": "xl", "weight": "bold" } },
  { "op": "insert",  "parent": 3, "id": 7, "before": 9 },
  { "op": "update",  "id": 7, "props": { "color": "green" } },
  { "op": "remove",  "id": 9 },
  { "op": "setRoot", "id": 1 }
] }
```

- `id` — integer, unique per app, allocated by the reconciler. Never reused within an app session.
- `create` — instantiates but does not attach. `props` is the full initial prop set.
- `insert` — attach under `parent`; `before` optional (null = append).
- `update` — **partial** props; only changed keys. `null` deletes a key.
- `remove` — detaches `id` and its entire subtree; Swift frees the views. Child ids are implicitly dead.
- `setRoot` — mounts a tree into the app's panel. Sent on first commit and after hot reload.

### 3.2 `app` (lifecycle, from host)
```json
{ "state": "started" | "reloaded" | "crashed" | "stopped",
  "error": { "message": "...", "stack": "..." } }
```
On `crashed`, Swift shows a built-in error card in that app's panel (spec §7) — no app cooperation required.

### 3.3 `chrome`
App-level presentation requests: `{ "request": "expand" | "collapse" | "attention" | "peek" | "wing" }`. `attention` = subtle glow on the notch wing (used by `monitor()` pings). Swift may deny `expand` (e.g. user is in a fullscreen game); denial is silent.

**`wing` — the collapsed notch.** `{ "request": "wing", "wing": { "text"?, "width"?, "canvas"?: { "id", "w" }, "meter"?: { "value" } } }`, and `"wing": null` releases it. One notch, one wing, latest asker wins (protocol/README.md, "collapsed wings"). The four fields are flow.md's four wing forms: **`text`** is the left wing's label (glyph or ticker); **`canvas`** is a drawable strip in the right wing, naming one of the app's own canvas nodes so its §3.4 frames land in both places; **`meter`** is the right wing's *stock* bar — `value` is `0…1` (clamped, both ends of the wire) and the shell owns its width, thickness, radius and ink, so two apps' meters are the same object rather than two hand-drawn rectangles; **`width`** is a total pill width, a floor when there is content and pure shape when there is not. `canvas` and `meter` both claim the right wing: the canvas wins, because those are the app's own pixels.

**`peek` — the notification.** `{ "request": "peek", "ms": 4000, "class": "ambient" | "alert" }` swells the notch with the app's `mini` node (§5), then retracts it. `class` is the priority class (flow.md): **ambient** retracts on its dwell (`ms`, or the shell's Ti ≈ 6 s), **alert** holds until it is acted on or dismissed. Absent is ambient — an app that says nothing is not raising an alarm, and an unknown value is read as ambient too, so a forward-compatible wire can never produce a swell that never goes away. This is the middle rung of three: a **wing** is always-on and glanceable inside the collapsed pill, a **peek** is a moment worth interrupting for, and the **panel** is everything. A track change, an alarm firing, your turn in a game.

The split between the two halves is deliberate: `mini` is *what* (declarative, kept current by the app's ordinary renders) and `peek` is *when* (imperative, one moment). Because Swift already holds a live view of the mini, a peek costs no round trip — and hovering one promotes straight to the full panel, which is the gesture that has to feel immediate. A "which view am I in" prop would put a worker hop in that path instead.

Denied silently when the app has no `mini`, when the panel is already open, or when another app is presented: a peek is only ever an escalation from collapsed. Never an interruption of something the user is already reading. `ms` is clamped host-side (0.5–20 s); a peek is a glance, and an app that wants the panel has `expand`.

### 3.4 `draw`
Imperative drawing for one `canvas` instance — bypasses the reconciler so games can run at frame rate without React commits:

```json
{ "id": 12, "ops": [
  { "op": "clear" },
  { "op": "rect", "x": 40, "y": 8, "w": 10, "h": 10, "fill": "#30D158", "radius": 2 },
  { "op": "line", "points": [[0,20],[80,20]], "stroke": "#FFFFFF22", "width": 1 },
  { "op": "text", "x": 4, "y": 12, "content": "1200", "size": 9, "color": "#FFFFFF" }
] }
```

Swift double-buffers and blits on the next display link tick. Ops beyond these four (`arc`, `image`, `path`) can be added without a version bump — unknown ops are skipped. Coalescing rule: if frames arrive faster than the display refreshes, Swift keeps only the latest per canvas.

**`gradient`** — `{ "op": "gradient", "x", "y", "w", "h", "from", "to", "angle"?, "radius"? }` fills one rect with an axial ramp between two hex colors. `angle` is degrees **clockwise from top-to-bottom**, matching the y-down op space (0 washes downward, 90 to the right), and defaults to 0; `radius` rounds the rect exactly as it does for `rect`. Free-form colors here are deliberate and are the opposite of the container rule (§5 `gradient`): a canvas is pixels the app owns, so it names real colors — a palette token inside a draw op would silently draw white.

### 3.5 `native` — transducers executed in the shell

For hot loops (games), the bundler extracts any function marked `"use native"` and ships it to Swift, which runs it in an embedded QuickJS — no socket roundtrip per frame.

```json
{ "action": "install", "canvas": 12, "hash": "sha256:…",
  "code": "function step(state, input) { …; return [state2, output]; }",
  "initial": { "board": [], "score": 0 } }
```

**Contract:** the function must be a pure transducer `(state, input) → [state', output]`. Purity isn't trusted, it's enforced by construction — the QuickJS context has empty globals (no `Date`, no `Math.random`, no I/O). Randomness/time arrive as inputs.

- **Inputs** (Swift-generated, local): `{ "type": "tick", "dt": 16.6, "t": 1042 }` on the display link while expanded and focused; `{ "type": "key", "key": "ArrowLeft", "down": true }`; `{ "type": "seed", "value": 8231 }` on install.
- **Output** is `{ "draw": [ops per §3.4], "events": [{ "name": "gameOver", "data": { "score": 1200 } }] }`. Draw ops go straight to the canvas; events are forwarded to the app's worker as ordinary messages.
- **State sync:** Swift checkpoints `state` back to the host (`{ "action": "checkpoint", "canvas": 12, "state": … }`) at 1 Hz and on collapse, so `ctx.state` persistence remains Node's job.
- **Hot reload:** install with a new `hash`; the old checkpointed state is passed as `initial`. Deterministic transducers make this safe, and make bugs replayable from a recorded input log.
- **Limits:** a QuickJS interrupt handler suspends any tick exceeding ~5 ms wall clock; three consecutive over-budget ticks → transducer suspended, `app:crashed` with reason to the worker (and thus `crash.log`). No fuel accounting — a wall-clock watchdog is enough for a personal system.
- **Shape changes are the AI's job:** if an edit changes the state shape, migrating the checkpointed state is the agent's responsibility (stated in `AGENTS.md`) — these are personal apps, not deployments; there is no automatic migration machinery.

### 3.6 Control plane (shell-level, `app: ""`)

- **`hello`** — first frame after connect: `{ "v": 1, "host": "0.3.0" }`. Swift replies with its own `hello` (§4.3) carrying `gen`; nothing else flows until both hellos are exchanged.
- **`catalog`** — the full installed-app list; Swift renders the app strip and Settings rows from this and nothing else:
  ```json
  { "apps": [
    { "id": "stocks", "name": "Stocks", "icon": "sf:chart.line.uptrend.xyaxis",
      "order": 0, "enabled": true, "running": true }
  ] }
  ```
  Sent after `hello` and re-sent in full on any change (install, rename, toggle, reorder). Full snapshots, no diffs — the list is small and this kills a class of drift bugs. (No grants field: apps are trusted local code, and macOS TCC already prompts for Automation/notifications at the OS level — Ledge doesn't duplicate that UI.)
- **`builder`** — the event stream for an app's chat surface (§8), translated by the host from the headless agent's output:
  ```json
  { "app": "stocks", "turn": 3, "event": "text",   "delta": "Making the price track the delta…" }
  { "app": "stocks", "turn": 3, "event": "tool",   "name": "edit", "detail": "app.jsx", "state": "completed" }
  { "app": "stocks", "turn": 3, "event": "status", "text": "rate limited — retrying" }
  { "app": "stocks", "turn": 3, "event": "done",   "status": "completed" }
  { "app": "pomodoro-timer", "turn": 0, "event": "created" }
  ```
  `created` is the one builder event the host originates rather than translates: the **[+]** surface sends a `builderInput` with no app (§4.3), the host scaffolds one named after the prompt, and this says what it called it. It carries no fields — the envelope's `app` *is* the answer — and it is emitted **before** the turn starts, because the shell moves its editor onto that id and would otherwise drop everything the turn says.
  `done.status` is `completed` | `interrupted` | `failed` — **not a boolean**. Agents report a cancelled or failed turn as a *completed* turn with an outcome, and collapsing that to `ok` renders a failed build as a success, which is the one thing this surface must never do. `tool.detail` is truncated for display (a real turn produced a shell command several kilobytes long).
  Swift renders these as chat bubbles, diff chips, and status lines — it never sees or speaks the underlying agent's wire format. `event: "error"` carries agent failures (not installed, auth expired, crash) verbatim so the user sees the real reason.

## 4. Swift → Node

### 4.1 `event`
```json
{ "id": 7, "name": "click", "data": { } }
```
Names: `click`, `change` (`{ "value": ... }` for slider/input), `hover` (`{ "in": true }`), `key` (`{ "key": "ArrowLeft", "down": true }`) for a focused `canvas`, and `drag` (`{ "phase": "down" | "move" | "up", "x": 214.5, "y": 22 }`) for a `canvas` that declared `onDrag`. Host routes to the worker; reconciler dispatches to the prop handler (`onClick` etc.). Unknown `id` (stale after reload) → dropped silently.

**Id 0 is the app itself** — node ids start at 1 (§3.1), so an event addressed to 0 belongs to the running app rather than to any view in its tree, and the worker dispatches it to the app's optional `onEvent(name, data, ctx)` export: `drop` (`{ "paths": [...] }`), `notification` (`{ "id": 7, "action": "execute" }`), `platform` (§6 observe), and (historically) `swipe`. **`swipe` is no longer emitted.** Principle 9 leaves the product three gestures — click, a horizontal swipe that walks the session strip, and a drag that parks the panel — and all three belong to the shell. A horizontal flick across the visit walks the strip; one across the collapsed pill or a swell does nothing. Apps that still export a `swipe` handler simply never hear from it.

**`drag`** is the gesture press-drag-release, in the canvas-local y-down space `click` and the draw ops already use. Three rules make it a scrubber rather than a firehose: `move` is throttled **shell-side** (~30 Hz) so a fast wiggle cannot flood the socket; `down` and `up` are never throttled, and `up` carries the final position, so a coalesced `move` is never the last word on where the gesture ended; and the point is **not clamped to the canvas** — a knob dragged past the edge keeps tracking, and what an out-of-range x means is the app's decision. A canvas that declares both `onClick` and `onDrag` gets both on press; neither is synthesized from the other, because the threshold that separates a tap from a drag is app policy.

### 4.2 `lifecycle`
```json
{ "phase": "expanded" | "collapsed" | "hidden" | "visible",
  "reduceMotion": false,
  "screen": { "notchWidth": 210, "menubarHeight": 34, "scale": 2 } }
```
Sent per app when its panel state changes and once on connect. Workers use this to pause rendering work while collapsed (monitors keep running regardless).

**`reduceMotion`** is the system's `accessibilityDisplayShouldReduceMotion`, and it rides here rather than in its own envelope because it is the same kind of fact as `phase`: an instruction about how hard to work, delivered on the channel an app already reads to decide that. The shell re-sends `lifecycle` — same phase, new flag — to every running app when the setting changes, so the flag is always current without any app polling for it. Absent means `false`. On the host it lands as **`ctx.reduceMotion`**, a plain boolean an app can read from inside a draw loop (where a callback is no use), updated in place before `onLifecycle` is called. Principle 10 in one line: *a canvas that animates must go still when this is true.*

### 4.3 Control plane (shell-level, `app: ""`)

- **`hello`** — reply to Node's hello: `{ "v": 1, "gen": 7, "screen": { "notchWidth": 210, "menubarHeight": 34, "scale": 2, "maxPanelHeight": 480 } }`.
- **`selection`** — the user switched apps via the strip: `{ "app": "music" }`, or `{ "app": null, "surface": "settings" | "new" }`. The host is the source of truth for what "selected" *means* (which worker gets `expanded` lifecycle), but the gesture originates in Swift.
- **`builderInput`** — the user typed into an app's chat: `{ "app": "stocks", "text": "make the price green when it's up" }`, or `{ "app": "stocks", "cancel": true }` to interrupt the running turn. `app` may name a not-yet-existing id when coming from the **[+]** surface; the host scaffolds first, then starts the session.
- **`appControl`** — `{ "app": "stocks", "action": "stop" }`; the shell asking the host to stop a session. Sent by exactly one control — the ✕ on **the ledge**, the only ✕ in the product (flow.md, "The strip") — and handled by the host's existing enable/disable path (§8, `ctx.platform.disable`): the worker is torn down, the app stays installed, and Settings is the way back. A second *trigger* for one mechanism, deliberately, so "is this app running" keeps one answer in one place.
- **`resyncRequest`** — `{ "app": "stocks" }`; the host responds with a fresh full commit for that app (and a `catalog` if `app` is `""`).

## 5. Component vocabulary

Small on purpose. Everything maps to a native view; layout is stack-based only.

| kind     | AppKit                | props |
|----------|-----------------------|-------|
| `stack`  | NSStackView           | `axis` (`h`/`v`), `gap`, `pad`, `align`, `distribute`, `flex`, `fill`, `stroke`, `radius`, `gradient` (a hue family: `accent`, `green`, `red`, `violet`, `cyan` — the shell owns the wash's geometry, so every app's looks alike; composes with `fill`) |
| `text`   | NSTextField (label)   | `content`, `size` (`xs`·10, `s`·11.5, `m`·12.5, `l`·15, `xl`·30, `display`·36, `hero`·48), `weight` (`light`, `regular`, `medium`, `semibold`, `bold`), `color` (semantic: `primary`, `secondary`, `green`, `red`, `accent`), `mono`, `truncate`, `caps` (uppercases **and** tracks out +6% — one prop, because uppercase at natural spacing is a jam) |
| `button` | NSButton (custom)     | `label` **or child** — a child fills the button and brings its own size, which is how a list row becomes the tap target; `variant` (`plain`/`glass`/`accent`/`ghost`), `onClick` |
| `image`  | NSImageView           | `src` (host-fetched URL or `sf:play.fill` for SF Symbols), `w`, `h`, `radius`, `stroke` (the `stack` hairline vocabulary, drawn on the picture itself) |
| `spacer` | spacer view           | `min` |
| `divider`| hairline view         | — · a rule between rows. Propless: no container can express one (an empty `stack` is zero points tall, so `stroke` has no edge to draw), and horizontal only — in a row the separation is already `gap` and `spacer`. |
| `chart`  | custom sparkline view | `points` (number[]), `color`, `fill` |
| `slider` | NSSlider              | `value`, `min`, `max`, `onChange` |
| `input`  | NSTextField           | `value`, `placeholder`, `onChange`, `onSubmit` |
| `canvas` | custom CGContext view | `w`, `h`, `focusable`, `onKey`, `onClick`, `onDrag` (§4.1 `drag`) — pixels via `draw` frames (§3.4), for games and scrubbers |
| `mini`   | shell swell surface   | children — one row, shown in the notch's **swell** by `ctx.peek` (§3.3). A **direct child of the root**, like `wing`: it is a shell zone, not a box in the app's layout. The wire name is historical; the surface it fills is the *notification* (flow.md). |
| `summary`| shell swell surface   | children — one row, the session's **hover summary** (flow.md). Same shape and same placement rule as `mini`, and the same zone discipline; the difference is who raises it — a notification is the app interrupting, a summary is the user asking, and the shell decides both. Declaring one makes the session *heavy*: a hover past **Th** shows this. A session that declares none is its own summary and hovers straight into the visit. The shell draws a trailing chevron on it that the app cannot remove — the promise that another click opens the full thing. |

Event handler props (`onClick`, …) serialize as `true` over the wire; the reconciler keeps the function on the host side keyed by `(id, name)`.

**`button.variant` — the two-tier control law** (design.html §06). An app's controls live *among content*, so the wire's fourth word is **`ghost`**: a bare pure-white glyph, no background at all, a `raisedHover` capsule only under the cursor. It is the honest form for a transport pair or a well's one action, and it is what every app should reach for before `glass` or `accent`. The shell's own tier — the convex **bead** on the wing bar — is *not* on the wire: `variant="bead"` from an app resolves to `plain`, because an app that could dress its buttons as chrome would make Ledge's controls indistinguishable from its content's.

**`image.stroke`.** The same hairline token set as `stack.stroke` (`hairline`, `accent`, `green`, `red`, `violet`), drawn as a 1 pt ring on the image view. It exists because artwork letterboxes: a sleeve whose bitmap does not fill its box, or whose file has not landed yet, still has to keep the frame the layout drew for it — and wrapping the picture in a stroked `stack` to get one double-frames it the moment the bitmap *does* fill the box.

**`align` — the cross axis.** `leading` · `center` · `trailing`, and those are the words (`start`/`end` are accepted aliases and nothing else is: an unknown value falls back to the axis default). In a column they mean left/middle/right; in a row, top/middle/bottom. **A column that names an alignment places its children instead of stretching them:** a `text` is sized to its words and put where the alignment says, capped at the column's width so a long line truncates rather than overrunning the panel. Without an alignment a column still stretches every child to its width, which is what makes rows, cards and charts span it. The exception either way is a child with no width of its own — a `divider`, a `chart`, a `slider`, a `progress`, an `input` — which spans the column whatever the alignment says, because "centred" for a rule would resolve to nothing.

**Rows place their children too.** A row (`axis="h"`) whose width was imposed from outside — a column stretched it, which is the ordinary case — lays its children out **side by side at its leading edge and leaves the leftover width over**. It used to spread them: the first child pinned to the leading edge, the last to the trailing edge, and the slack given to whichever measured least, so `[27° · Overcast through the evening]` came out as a numeral stretched across two thirds of the panel with a phrase stranded at the far edge — two facts where the app wrote one sentence. The exception is the column rule's own exception, in the same words: **a row holding a child with no width of its own** — a `spacer`, `divider`, `chart`, `slider`, `progress` or `input` — keeps filling, because that child is where the slack is supposed to go. A `spacer` is how an app *says* so, and a row with a trailing value (`label · spacer · value`) is written exactly that way and behaves exactly as before. `distribute="equal"` is untouched. Rows that were never stretched in the first place — one placed by a centred column, or hosted by a `button` — are already the size of their contents and are untouched as well; `align` on a row still means the cross axis (top/middle/bottom) and nothing else.

**Layout & sizing.** The root view's width is fixed by the shell (440 pt expanded; apps don't choose widths). Panel height = the root's intrinsic fitting height + shell chrome (34 pt header + 42 pt app strip), clamped to `maxPanelHeight` from `hello` (default 480 pt, shell-computed from screen size). Content past the clamp **clips** — there is no implicit scrolling; a `stack` can opt in with `scroll: true`, which maps to an `NSScrollView` (non-flashing overlay scrollers). Height changes animate with the standard curve; Swift re-measures after every applied commit.

## 6. App file contract

One folder = one app; `app.jsx` is its entry. The host transpiles it with `Bun.Transpiler` on load (in-memory; a `.build/` cache in the app folder is permitted but optional). Apps run on **Bun** and use the platform directly: `fetch`, `bun:sqlite`, `Bun.sleep`, `Bun.$`, `fs`, timers, `import.meta.dir`. Nothing the platform already does gets wrapped.

```jsx
import { Database } from "bun:sqlite";

export const meta = { name: "Stocks", icon: "sf:chart.line.uptrend.xyaxis" };

const db = new Database(`${import.meta.dir}/stocks.sqlite`);
db.run("create table if not exists ticks (t integer, price real)");

// Invoked by the host in a sequential loop — see Monitor lifecycle below.
export async function monitor(ctx) {
  const { c } = await (await fetch("https://api.example.com/AAPL")).json();
  db.run("insert into ticks values (?, ?)", [Date.now(), c]);
  ctx.update({ price: c });
  if (c > 214) ctx.notify("AAPL crossed $214", { attention: true });
  await Bun.sleep(60_000);
}

// Re-rendered with the merged ctx.update object as props.
export default function App({ price = "—" }) {
  return <stack axis="v" pad={14} gap={8}>…</stack>;
}
```

**`ctx` is deliberately tiny** — only bridges into the shell, i.e. things the platform *cannot* provide:

- `ctx.update(patch)` — shallow-merges into an in-memory object passed to `App` as props and schedules a render. In-memory only, does not persist. This is the sole monitor→UI bridge.
- `ctx.notify(text, { attention })` — UserNotification + optional notch-wing glow.
- `ctx.apple.script(source)` / `ctx.apple.shortcut(name, input)` — AppleScript & Shortcuts, executed by the shell process (workers can't own TCC prompts; macOS handles consent natively).
- `ctx.attention()` — notch glow without a notification.
- `ctx.peek(ms)` — show the app's `mini` node below the notch for a moment (§3.3).

Everything else is the platform: HTTP is `fetch`, persistence is `bun:sqlite` or `fs` + `JSON` in `import.meta.dir`, pacing is `Bun.sleep`/`setInterval`, the app's path is `import.meta.dir`, logging is `console.*` (the host captures worker stdout/stderr into the app's log). Persistence guidance lives in `AGENTS.md`, not in API: SQLite (WAL) for anything append-heavy, write-temp-then-`rename` for JSON — atomicity is the app's job, and SQLite gives it for free.

**Monitor lifecycle — deterministic rules:**
1. The host invokes `monitor(ctx)`, **awaits its return**, then invokes it again. Calls never overlap. Pacing lives inside via `Bun.sleep`; if it returns in under 1 s, the host inserts the difference (spin floor).
2. A thrown exception is an **app crash** — monitor and UI share fate (one folder, one worker, one health state). Restart with exponential backoff (1 s → 2 min, max 5 attempts); the backoff counter resets after 10 minutes of healthy running.
3. On reload or disable, the worker is **terminated**, which cancels everything at once: the in-flight `monitor` call, timers, and pending shell bridges (`ctx.notify`/`ctx.apple` host-side halves are aborted — nothing lands after death). App-owned files are untouched; on restart, `monitor` re-reads its own persistence.

**Trust model.** Apps are trusted local code — the same standing as any script you run on your Mac. `ctx` being narrow is API design (it keeps AI-written code on greppable paths), not containment. Sandboxing is explicitly out of scope for this design.

**`"use native"`:** a function whose body begins with this directive is extracted at bundle time and executed in the shell per §3.5. It can only be a pure transducer; referencing anything outside its own scope is a bundle error.

**npm.** A fixed essential set ships preinstalled at `~/.ledge/node_modules` (shared): `zod`, `dayjs`, `cheerio`, `lodash-es` — Bun builtins cover HTTP, SQLite, shell, and transpile, so the list stays short. Always ship the lockfile. An app may declare extras via a `// deps: some-pkg` header; the host runs `bun install` in the app folder. If install fails, the host writes the error to `<app>/install-error.log` — the agent reads it and decides what to do (pin, replace, vendor).

**App identity.** An app is its folder:

```
~/.ledge/apps/
  AGENTS.md           # platform doc for coding agents (see §8)
  stocks/
    app.jsx           # the entry — the only file the host watches
    stocks.sqlite     # the app's own persistence, its own business
    .builder.json     # Ledge's session pointer: { "agent": "claude", "sessionId": "…" }
    .build/           # optional transpile cache (host-ignored)
    crash.log         # last crash stack + recent console output, written by the host
```

Transcripts are **not** Ledge's concern: the agent manages its own session storage in the place it knows. Ledge keeps only the *pointer* (`.builder.json`) so each app's chat always resumes the right session. `AGENTS.md` plus per-app logs are Ledge's contribution to provenance — the agent brings its own memory.

## 7. Hot reload & errors

1. Host watches `~/.ledge/apps/*/app.jsx` only (the directory name is the app id — §2, §6; app data files and `.build/` never trigger reloads). On change: `Bun.Transpiler` → terminate old worker (cancelling everything per Monitor lifecycle rule 3) → spawn fresh worker → new `setRoot` replaces the tree. Target < 300 ms. In-memory `ctx.update` props are rebuilt by the fresh `monitor`; on-disk app data is untouched.
2. Worker exception (render or monitor): host sends `app:crashed` with the stack; Swift renders the error card; the stack plus recent captured console output is written to `<app>/crash.log` for the agent. Restart per Monitor lifecycle rule 2.

## 8. Shell chrome (informative)

Collapsed 210×34 (hardware notch), live-activity wings up to 340×34, expanded panel up to 440×~350 (height is per-app), corner fillets where the panel meets the menubar. Panel material: black glass at ~88% opacity, 40 pt blur. Expand/collapse curve `cubic-bezier(0.32, 0.72, 0, 1)`, 450 ms.

**App strip.** Every expanded panel reserves a 42 pt strip at the bottom, drawn by Swift — apps render above it and can never cover it. Layout: installed apps at left (order = Settings order), then **[+]**, then Settings at far right. Active app gets a dot indicator; while an app's chat is open, its icon stays lit. Switching apps morphs the panel to the new app's height in the same gesture — one shape, no close/reopen. **[+]** opens the chat surface over a fresh folder (§ below).

**The chat UI ships; the intelligence doesn't.** Every app header carries a **✦** toggle that opens its chat below the live preview (per the mockups), and **[+]** opens the same surface over a fresh folder. But Ledge never calls a model API — the chat is a frontend over the **user's own agent in headless mode**:

- On `builderInput`, the host spawns one turn of the configured agent in that app's folder — e.g. `claude -p <text> --resume <sessionId> --output-format stream-json`, or the equivalent `codex exec` — and translates its streamed output into `builder` events (§3.6). A thin **adapter per agent** does the translation; adapters are the only agent-specific code in Ledge.
- **`.builder.json`** in each app folder pins `{ agent, sessionId }`. The agent owns the transcript in its own storage; Ledge owns the pointer. This is what makes the notch chat *focused*: one app, one session, no scrolling past your other projects, never wondering which chat belongs to which app.
- The agent works with what's already there: `AGENTS.md` for the contract, the file watcher for hot reload, `crash.log` for failures, the `ledge` CLI for control. The notch chat adds zero capabilities over a terminal — it adds *scope*.
- **The terminal path stays first-class by design.** An app is just a folder, so opening it in Claude Code's or Codex's own GUI/TUI works identically — same files, same AGENTS.md, same reload loop. `.builder.json` only tracks the notch-initiated session; sessions the user runs directly are theirs. Settings picks the default agent (host detects installed ones); no agent installed → the chat surface explains how to get one and offers `ledge new` + reveal-in-terminal as the fallback.

**`AGENTS.md`** at `~/.ledge/apps/` documents the platform for agents: the app contract, `ctx`'s four calls, the component vocabulary, persistence guidance (SQLite/atomic JSON in `import.meta.dir`), the `"use native"` transducer rules **including "if you change the transducer's state shape, you migrate the checkpointed data yourself,"** and the crash/reload loop.

**`ledge` CLI** — small, composable, used by agents and humans alike:
`ledge new <id>` (scaffold), `ledge reload <id>`, `ledge logs <id> [-f]` (captured console + crashes), `ledge status` (catalog as JSON), `ledge open <id>` (expand that panel — lets an agent literally show its work in the notch).

The **feedback loop is files** either way: the agent edits `app.jsx` → the watcher hot-reloads (§7) → success is visible in the notch, failure lands in `crash.log` → the agent reads it and fixes.

**Settings** ships with the host, written against the same worker + component API as user apps (it's the reference implementation). It differs in exactly two ways: it can't be disabled, and it gets a privileged `ctx.platform` API (enable/disable apps, reorder, worker stats). The protocol needs no special case for it.

## 9. Resolved & deferred

Formerly-open subsystems, settled in v0.3:

- **npm** — fixed essential set + lockfile always; install failures become agent context (`install-error.log`). Settled, §6.
- **Native transducers** — wall-clock watchdog instead of fuel accounting; state-shape migration is the agent's documented responsibility in `AGENTS.md`. These are personal apps, not deployments. Settled, §3.5.
- **Builder** — the notch chat ships as a frontend over the user's agent in headless mode (per-agent adapters, `.builder.json` session pointers); no direct model API usage. The terminal/GUI path is equally supported since an app is just a folder. Settled, §8.
- **Sandboxing** — out of scope for this design. Stated, §6.

Still deferred (nothing in §§1–8 depends on it):

- **`ctx.peer` / multiplayer** — signalling-server design, room lifecycle, relay limits. Revisit after the single-player platform is real.

**Build order:** transport + shadow-tree renderer → control plane + app strip → worker lifecycle + one hand-written app → `AGENTS.md` + `ledge` CLI (terminal path working end-to-end) → agent adapters + the notch chat surface → ask it for a flight tracker without leaving the notch.