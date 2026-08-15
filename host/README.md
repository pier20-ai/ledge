# Ledge Bun host

The host side of the protocol (`docs/design/spec.md`): router, transpiler,
file watcher, worker supervision. Transport + control plane (step 2) and the
worker runtime (`src/worker/`) are now wired together by **worker supervision +
the router (step 4)** — one Bun Worker per app, crash/backoff, hot reload, and
full envelope multiplexing to a live shell.

Bun is pinned via `.bun-version` and `engines.bun` (1.3.9).

## What exists

- `src/protocol/framing.ts` — uint32-LE + JSON framing, 8 MiB cap, buffered
  split/coalesce-safe decode; a violation throws and the connection closes
  (spec §1).
- `src/protocol/envelope.ts` — envelope parse/validate, per-app inbound seq
  dropping stale frames, outbound seq allocation; both scoped to a connection
  generation by construction (spec §2).
- `src/connection.ts` — connect → hello exchange → session; reconnect with
  250 ms → 5 s backoff; nothing flows before both hellos (spec §1, §3.6).
- `src/registry.ts` — app discovery: one folder = one app, `app.jsx` is the
  entry, directory name is the id (spec §6) — plus the catalog schema and the
  `meta` merge. A scan produces the **dirname fallback** (capitalized folder
  name, placeholder icon); the app's real name/icon/`panel` arrive from its own
  worker (below) and `applyMeta` merges them per-field over the scan.
  `parseCatalogApp` validates a row off the wire, including the optional
  `panel: { width?, maxHeight? }`.
- `src/fakes/fake-shell.ts` — a UDS server impersonating the Swift shell
  (hello/gen, frame injection, envelope recording). Used by tests and as a
  dev harness: `bun run fake-shell [socket-path]`.
- `src/host.ts` — entry point: connects, and hands the session to the `Router`.
  CLI: `bun src/host.ts [socketPath] [--apps-root <path>]`.

Tests (`bun run test` — per-file processes; a full single-process `bun test`
intermittently segfaults in Bun 1.3.9 itself at 18-suite teardown scale, see
scripts/test-stable.sh; `bun run test:fast` keeps the one-shot mode) replay
the shared golden corpus in `../protocol/fixtures`
— the same files the Swift side replays — plus byte-level framing cases and a
live hello → catalog → inject → reconnect exchange over a temp socket.

## Worker runtime (`src/worker/`)

The **app-worker half** of spec §6: what runs inside one app's Bun Worker. A
worker talks to the host thread **only via `postMessage`** — it never touches
the socket, framing, or envelopes (that is the host thread's job), and imports
nothing from `src/protocol` or `src/connection`.

- `messages.ts` — the typed worker ⇄ host contract (the wiring agent consumes
  this). Worker → host: `commit` (one reconciler batch, §3.1), `meta` (the app's
  `export const meta`, §6), `draw` (one imperative canvas frame, §3.4), `wing`
  (the collapsed-notch surface, §3.3 extension), `chrome`
  (`expand`/`collapse`, §3.3), `notify`, `attention`, `apple`/`platform` bridge
  **requests** (each carries an `id`), `console` (captured logs), `crash`
  (`phase: "render" | "monitor"`, §7). Host → worker: `event` (§4.1),
  `lifecycle` (§4.2, informational), and `reply` (resolves an `apple`/`platform`
  request by `id`). Boot config (`{ modulePath, privileged }`) arrives
  out-of-band via `workerData`; termination is `worker.terminate()` — there is no
  terminate message (§6 rule 3).
- `meta.ts` / `wing.ts` — the two app-declared value types (`AppMeta`,
  `WingSpec`) and their sanitizers. Both modules are dependency-free and imported
  by the worker *and* the host thread, so "what an app may say" has one
  definition per side of the wire. They sanitize **types only** — a 4000 pt panel
  request survives untouched, because sizing policy belongs to the shell, which
  owns the screen. Neither ever throws: a malformed `meta` must not be the
  difference between an app that runs and an app that doesn't.
- `ctx.ts` — the monitor's `ctx`, now **eleven calls**: `update(patch)`,
  `notify(text, { attention, title, actions })`, `attention()`,
  `apple.script/apple.shortcut`, `draw(id, ops)` (§3.4), `wing(spec | null)`
  (§3.3 extension), `expand()`/`collapse()` (§3.3), `capture({ interactive })`,
  `agent(prompt, { files, schema, timeoutMs })`, and
  `platform.observe/unobserve(kind, name)` (§6 extension). The principle is
  unchanged: `ctx` carries only what the app's own process cannot do —
  AppleScript, notifications, screen capture and a distributed-notification
  registration need the shell (macOS attributes consent, and a registration, to
  the process with the UI), and `ctx.agent` needs the host (it spawns a
  subprocess in the app's folder). `apple`/`capture`/`agent`/`platform` calls
  return Promises settled by a host `reply`. Settings (§8) additionally gets the
  privileged half of `ctx.platform` (`enable`/`disable`/`stats` today,
  `reorder` still unimplemented), attached only when the worker is booted
  `privileged` and answered by the host itself; `observe`/`unobserve`
  are on every app's `ctx`, because "poll for truth, be woken for latency" is
  every monitor's problem and not a management operation on other apps.

  Two call-level contracts worth knowing before writing an app:

  - **`ctx.notify` returns the notification's id** and takes optional
    `title`/`actions`. A pressed button arrives back as the app-level
    `notification` event carrying `{ id, action }`; a click on the banner body
    reports the action `default`. Buttons need a bundled shell — unbundled, the
    shell falls back to `osascript` and the text still shows, so an app must not
    depend on a button being pressable.
  - **`ctx.agent` never rejects.** A failed turn is `{ ok: false, error }`,
    because a throw inside `monitor` is an app crash with backoff (§6 rule 2) —
    the wrong response to "the agent CLI isn't installed". `ctx.capture` and
    `ctx.apple` *do* reject, because a cancelled screenshot or a missing
    Shortcut is genuinely exceptional for the code that asked.

  `ctx` is the monitor's argument, but the object lives as long as the worker, so
  an app that draws at frame rate keeps the reference its `monitor` was handed
  and calls `ctx.draw` from event handlers too. The canvas id it passes is the
  node id from its own tree, read off a ref — `<canvas ref={n => canvas = n} />`
  yields the node instance, and `canvas.id` is exactly what the reconciler
  allocated. There is no second API for either.
- `monitor.ts` — the deterministic monitor loop (§6): invoke `monitor(ctx)`,
  await, re-invoke; a **1 s spin floor** fills a short call's remainder; a throw
  becomes one `crash` message and **stops** the loop (restart policy is the
  host's call, not the worker's). The clock is injectable so tests exercise the
  spin floor without real sleeps.
- Apps may also export **`onEvent(name, data, ctx)`** (optional): **app-level
  events**, which arrive as an ordinary §4.1 `event` at **id 0**. Node ids start
  at 1 (§3.1), so 0 can never be a node — it means the event happened to the app
  rather than to a view. Two exist: `drop` (`{ paths }`, the drop shelf) and
  `notification` (`{ id, action }`, a pressed button). An app without the export
  ignores them quietly, exactly like `onLifecycle`.
- Apps may also export **`onLifecycle(phase, ctx)`** (optional): the shell's
  §4.2 panel-phase envelopes (`expanded`/`collapsed`/…) are delivered to it, so
  a game can drop its frame rate while collapsed. A throw in the handler is a
  render crash; apps without the export ignore lifecycle quietly.
- `entry.ts` — the worker entrypoint. `runWorker(io, boot)` is the testable core
  (imports the app module, **posts its sanitized `meta`**, mounts its default
  export into a render session whose sink posts `commit` messages, builds `ctx`,
  dispatches inbound events, captures `console.*`, runs the monitor loop). The
  `meta` post sits between the import and the mount on purpose: the host thread
  must never import app code, so this worker is the only place `export const
  meta` can be read, and sending it before the first commit means the app strip
  has the real name and icon by the time that app's panel can be shown. The
  bottom auto-runs it under a real Worker via `node:worker_threads`
  (`workerData` → boot); importing the module on the main thread is inert
  (`isMainThread` guard).

### App JSX assumption

App files (`app.jsx`) **import nothing from Ledge** — `ctx` is the monitor's
argument, and the shell components (`<stack>`, `<text>`, …) are intrinsic
elements. JSX is transpiled by **Bun's default automatic runtime**; each
reference/fixture file carries a first-line `@jsxImportSource react` pragma so it
resolves React's runtime regardless of this repo's `@ledge/jsx`-flavoured
`tsconfig`. These `.jsx` files are invisible to `tsc` (no `allowJs`), so they
never see the `@ledge/jsx` JSX namespace. (Beware: Bun scans **all** comments for
`@jsxImportSource`, so prose must not repeat that token verbatim.)

## Settings (`../protocol/demo-apps/settings`, `src/settings.ts`)

The Settings app (spec §8) is an ordinary app that ships in the seed payload —
same worker, same §5 vocabulary, same monitor→props bridge. It differs in
exactly two ways, and both live in the host:

- **The router boots the worker whose folder is named `settings` `privileged`**,
  which is what attaches the app-management half of `ctx.platform`
  (`src/worker/ctx.ts`). An ordinary app cannot see those calls, and the router
  refuses them a second time if one arrives anyway.
- **It cannot be disabled** — it is the only way back from everything else on
  that panel, so `SettingsStore` refuses it whether the request comes from the
  app or from a hand-edited file.

`src/settings.ts` owns `~/.ledge/settings.json` — beside the apps root, never
inside an app's folder, because "may this app run" is the one fact about an app
the app itself must not edit. It records **disabled** ids, so an app installed
while Ledge is running starts without anybody having written its name down, and
a file that has never existed means "everything runs". Writes are
temp-then-rename. `scanApps` takes the set and reports `enabled` from it; the
router skips disabled apps when starting workers, so a disabled app never
spawns rather than starting and being stopped.

`enable`/`disable` are answered **by the host**, not forwarded to the shell like
the rest of `ctx.platform`: they mean starting or killing a worker and
re-publishing the catalog (§3.6, full snapshot), which is host state end to end.
`stats()` hands back that same snapshot, so the panel and the strip beneath it
are two renderings of one list. `reorder` is still unimplemented.

`quit()` is the exception that proves the split: it is Settings-only like the
rest of the family, but it goes **to the shell**, because only the shell can end
the process — the host is its child and a worker is a thread inside that child.
The shell answers `ok` and terminates on the next run-loop turn, so the reply
gets out before the socket does. With the status menu gone and `LSUIElement`
meaning no Dock icon, that button is the only quit the user has; the app arms it
on the first press and quits on the second.

## Supervision, routing & hot reload (`src/supervisor.ts`, `src/router.ts`, `src/watcher.ts`)

The host-thread half that consumes `src/worker/messages.ts` and drives the
socket. All timing is injectable so the crash policy is tested with fake clocks
(no real sleeps), and the worker factory is injectable so tests run with a fake
worker (no thread).

- `src/worker-factory.ts` — spawns a real Bun Worker booting `worker/entry.ts`
  via `workerData`, and `transpileCheck` — a `Bun.Transpiler` syntax pass **before**
  spawning, so an unparseable `app.jsx` becomes a crash report + `crash.log`
  without a crash-loop on import (spec §6, §7).
- `src/supervisor.ts` — `AppSupervisor`, one per app. Emits the `app` lifecycle
  envelope (`started`/`reloaded`/`crashed`/`stopped`, spec §3.2) at each moment,
  routes worker messages to the sink, captures console into a ring buffer, and on
  crash writes `<app>/crash.log` (stack + recent console, §7) then restarts with
  exponential backoff (1 s → 2 min, max 5 attempts, counter reset after 10 min
  healthy, §6 rule 2). Stale events from a replaced worker are dropped by
  identity. `reload()`/`resync()` are terminate + respawn (a fresh worker
  re-mounts = the fresh full commit).
- `src/router.ts` — `Router` (the multiplexer, spec §§3–4). Owns one supervisor
  per enabled app + the watcher. Worker→shell: `commit` batches → `commit`
  envelopes; `meta` → merged into the catalog and the **full** snapshot re-sent
  (§3.6, no diffs); `draw` → `draw` envelopes (unlogged — they run at frame rate);
  `wing` → a `chrome` request carrying the spec; `chrome` → `chrome`
  expand/collapse; `notify` → a `notify` envelope the **shell** posts (+
  `chrome:attention` if flagged); `attention` → `chrome:attention`;
  `apple`/`capture` → the shell-executed capability envelopes below; `agent` →
  a headless turn the host runs itself; `platform` requests → not-implemented
  replies. Shell→worker: `event` (including id-0 app-level events) and
  `lifecycle` forwarded to the app's worker; `appleResult`/`captureResult`
  settle the matching bridge request; `notifyAction` becomes an id-0
  `notification` event for that app;
  `selection` tracks the presented app; per-app `resyncRequest` → that supervisor
  respawns; shell-level → re-send `catalog`. `builderInput` is inert this phase
  (no AI/builder integration).

  Two pieces of state the router keeps beyond its supervisors: the last `meta`
  per app (**replaced** wholesale on each post, never merged, so an app that
  drops `meta.name` falls back to its directory name on the next reload rather
  than keeping a ghost), and which apps hold a wing. A wing belongs to a live
  worker, so the router releases an app's wing on **every** lifecycle transition
  — `started`, `reloaded`, `crashed`, `stopped`, emitted before the lifecycle
  envelope so the shell never sees a wing outlive its app — and drops all of them
  on disconnect. Which app *wins* the notch is the shell's call, not the
  router's: there is one collapsed notch, so arbitration can only live where the
  pixels are.
- `src/watcher.ts` — watches each app **folder** (not the file, so rename-replace
  saves survive) and reloads on `app.jsx` changes only, debounced (spec §7).

## Capability routing (`ctx.apple`, `ctx.capture`, `ctx.notify`)

The host is the **broker**, never the executor, for anything that needs a TCC
prompt: it turns a worker request into an envelope, remembers it by `(app, id)`,
and settles the worker's Promise when the shell answers. Wire shapes and the
reasoning live in `../protocol/README.md`.

- **Timeouts are host-side and one-way.** `apple` gets 10 s (an Apple event that
  hasn't answered in ten seconds is a hung target); `capture` gets 120 s (what it
  is waiting for is a *person* dragging out a region). On expiry the request is
  **forgotten** and the app is told — so a result arriving later is dropped, not
  delivered to a Promise the app has already seen settle.
- **Requests die with their worker.** Every lifecycle transition clears that
  app's pending requests (§6 rule 3: nothing lands after death), and so does a
  disconnect — with the difference that a disconnect *fails* them explicitly,
  since nothing can ever settle them now.
- **No shell, no hang.** With no session bound the app is answered immediately
  with an error it can catch, rather than waiting for a shell that may never
  launch.
- The old `osascript` notification interim is **gone**: notifications are posted
  by the shell, which owns the bundle and is the only side that can draw action
  buttons. (An *unbundled* shell falls back to `osascript` itself — see
  `../shell/README.md`.)

## The agent adapter (`src/agent.ts`)

`ctx.agent` runs **the user's own agent CLI**, headless, in the app's folder.
Ledge never calls a model API (spec §8) — there is no key and no endpoint in this
codebase, and the adapter is the only agent-specific code, as §8 requires.

- **Detection:** `LEDGE_AGENT_CMD` (a command template — `{prompt}` is
  substituted, else the prompt is appended) wins; otherwise `claude` on PATH is
  invoked as `claude -p <prompt> --output-format json` and its `result` field is
  the reply. A CLI that just prints text works too: "the user's own agent" means
  the output shape is not ours to dictate. Nothing installed → `{ ok: false }`
  with a message, never a crash.
- **`files`** are named in the prompt for the agent to read itself; **`schema`**
  appends the JSON instruction, strips code fences, parses, and retries exactly
  once.
- **Serialization:** one turn per app, in flight at a time. A second concurrent
  call is refused as busy rather than queued — every turn spends the user's
  tokens, and a monitor that outruns the agent should learn that immediately.
- **60 s default timeout** (`timeoutMs` overrides, clamped to 1 s…10 min); a hung
  CLI is killed and reported.
- **Tests never invoke a real agent.** `test/fixtures/fake-agent.ts` stands in via
  `LEDGE_AGENT_CMD`/an injected command, and covers the schema round trip, the
  one-shot retry, nonzero exits, and the timeout.

## Demo apps + end-to-end smoke (`../protocol/demo-apps`, `../scripts/e2e-smoke.sh`)

`protocol/demo-apps/` holds the hand-written apps: `timer`, `radio`, `beacon`
and `settings`. The first three are **exercise** apps — between them they hold
every surface the shell can raise (summary, no-summary, wing meter, wing canvas,
ambient and alert notifications), so the interaction machine can be felt on a
real notch. `settings` is the privileged one. They are **not** installed in
`~/.ledge`; they live in the repo so the host can be pointed at them. See
`../protocol/README.md` for what each proves. The pre-design-reset set was moved
to `protocol/demo-apps-archive/` — reference only, never scanned.

The apps root is a **real package**: `protocol/demo-apps/package.json` plus a
committed `bun.lock` (spec §6: always ship the lockfile), holding what apps
import bare — `react` and `react-reconciler`, and nothing else. It is the repo analogue of the
shared `~/.ledge/node_modules`, and it replaces the old convention where the
scripts symlinked `host/node_modules` in and deleted it on exit. Both scripts run
`bun install --frozen-lockfile` there if `node_modules` is missing. (Test files
that build their **own** temp apps root still symlink `host/node_modules` into
it — those roots are throwaway and have no package of their own.)

**One React, not one version.** The apps root's `react` is
`file:../../host/node_modules/react` on purpose. Hooks live in module-level
state, and the reconciler that renders an app runs inside the worker out of
`src/render/` — so an app's `react` and the reconciler's `react` must be the
**same module instance**. Two separately-installed copies of 18.3.1 is
`dispatcher.useState of null` on the app's first `useState`, which is exactly
what happened the first time the apps root pinned React by version. Install the
host's dependencies before the apps root's.

`scripts/e2e-smoke.sh` builds the shell, runs `LedgeShell --socket <tmp sock>`
(the shell binds `~/.ledge/ledge.sock` by default, so the override is what keeps
a test run away from the user's own instance), runs the host with `--apps-root
protocol/demo-apps` against that socket, and asserts from the logs that the
hello was exchanged, the catalog delivered, the mount commit routed, and the
commit **applied by the shell** — then cleans up every process/artifact it
created (temp socket + PIDs only; never `~/.ledge`).

## Snapshot dump (`scripts/dump-commits.ts`)

`bun scripts/dump-commits.ts <app.jsx> <out.json> [--order N]` renders an app
once through the real reconciler into an `InMemorySink` and writes its spec §3.1
mount batch, plus the app's `meta` name/icon/`panel` run through the same
sanitizer the worker uses, to JSON. `LedgeShell --snapshots <out>
--commits <dir>` replays those batches through the Swift engine and renderer to
produce PNGs; `scripts/snapshot-demos.sh` runs both halves for every demo app.
The monitor is never started — only the default export is mounted, with its
default props — so the dump is deterministic.
