// The `ctx` object passed to `monitor(ctx)` (spec §6). Deliberately tiny — ONLY
// bridges into the shell, i.e. the things the Bun platform cannot itself
// provide. Everything else an app needs (fetch, bun:sqlite, Bun.sleep, timers,
// import.meta.dir, console) is the platform, used directly. Apps import nothing
// from Ledge; ctx arrives as the monitor's argument.
//
//   ctx.update(patch)                    monitor → UI bridge (§6)
//   ctx.notify(text, { attention,        notification (+ action buttons) posted
//              title, actions })         by the shell; returns its id (§6)
//   ctx.attention()                      notch glow, no notification (§6)
//   ctx.apple.script / .shortcut         AppleScript / Shortcuts via the shell
//   ctx.draw(id, ops)                    imperative canvas frames (§3.4)
//   ctx.wing(spec | null)                own/release the collapsed notch (§3.3)
//   ctx.expand() / ctx.collapse()        presentation requests (§3.3)
//   ctx.capture({ interactive })         shell-side screenshot → a file path
//   ctx.agent(prompt, { files, schema }) one headless turn of the USER's agent
//   ctx.platform.observe(kind, name)     push invalidation: the shell watches an
//   ctx.platform.unobserve(kind, name)   OS signal and wakes the app (§6 ext)
//   ctx.platform.calendar({from, to})    EventKit, in the shell (TCC)
//   ctx.platform.workspace()             frontmost app, idle seconds, lock state
//   ctx.platform.location()              one reduced-accuracy fix (TCC)
//   ctx.platform.spotlight({query})      NSMetadataQuery, capped and bounded
//   ctx.platform.audio() / .setVolume(v) the default output device
//   ctx.platform.speak(text, {voice})    AVSpeechSynthesizer, one at a time
//
// The agentic three (`apple` made real, `capture`, `agent`) are the same
// principle as the rest: `ctx` carries only what the app's own process cannot
// do. AppleScript and screen capture need the shell because macOS attributes
// consent to the process with the UI; `ctx.agent` needs the host because it
// spawns a subprocess in the app's folder — and Ledge still never calls a model
// API itself (spec §8), it runs the agent the user already has.
// They are still "things the platform cannot provide": every one of them is a
// message to the shell and nothing else. `ctx` is the monitor's argument, but
// the object is stable for the worker's whole life, so an app that wants to draw
// from an event handler keeps the reference its monitor was handed — that is the
// documented pattern for a game loop.
//
// Settings (the reference app, §8) additionally gets a privileged `ctx.platform`
// — typed here but only wired when the host boots the worker `privileged`.

import type {
  AgentRequest,
  AgentResult,
  AudioInfo,
  BridgeReply,
  CalendarEvent,
  LocationFix,
  NotifyAction,
  PlatformObserveSource,
  SpotlightHit,
  WorkerToHost,
  WorkspaceInfo,
} from "./messages";
import { sanitizeWing, type WingSpec } from "./wing";

/** AppleScript / Shortcuts, run in the shell process; each call resolves when
 * the host replies (spec §6). Result shape is whatever the shell returns. */
export interface AppleBridge {
  script(source: string): Promise<unknown>;
  shortcut(name: string, input?: unknown): Promise<unknown>;
}

/**
 * Push invalidation (spec §6 extension). Available to **every** app, because
 * the problem it solves is every monitor's problem: a poll is the right way to
 * establish the truth and the wrong way to notice a change. `observe` asks the
 * shell to watch an OS broadcast and push an id-0 `platform` event back the
 * moment it fires, so an app can keep its slow authoritative poll *and* react
 * instantly.
 *
 *     await ctx.platform.observe("distributedNotification", "com.apple.Music.playerInfo");
 *     export function onEvent(name, data, ctx) { if (name === "platform") poll(); }
 *
 * Registration is keyed shell-side by (app, kind, name) and is **idempotent** —
 * re-declaring on every monitor pass is fine and is the obvious way to write it.
 * Observers are released for an app on every lifecycle transition, exactly like
 * its wing: they belong to a live worker.
 *
 * `userInfo` on the event is reduced to strings, numbers and booleans; anything
 * else is dropped. The event's job is to say *when*, not *what* — for "what",
 * the app already has `ctx.apple` and a real query.
 */
export interface PlatformBridge {
  /**
   * Watch an OS signal. `kind` is the source, `name` is the signal within it:
   *
   * - `"distributedNotification"` — any broadcast name, verbatim
   *   (`"com.apple.Music.playerInfo"`). Payload: the sender's `userInfo`,
   *   reduced to scalars.
   * - `"workspace"` — `"didActivateApplication"` (payload `{bundleId,
   *   localizedName}`), `"willSleep"`, `"didWake"`, `"screensDidSleep"`,
   *   `"screensDidWake"`, `"screenLocked"`, `"screenUnlocked"`. Translated
   *   names, not raw notification names.
   * - `"pasteboard"` — `"changed"`. Payload `{changeCount, types, hasStrings}`.
   *   **Never the contents**; this is the invalidation signal, and an app that
   *   truly wants the clipboard shells out to `pbpaste` in its own source.
   * - `"power"` — `"changed"`. Payload `{level, charging, onAC, lowPowerMode}`.
   * - `"reachability"` — `"changed"`. Payload `{satisfied, expensive,
   *   constrained, interface}`.
   * - `"audio"` — `"changed"`. Payload `{deviceName, volume, muted,
   *   transportType, batteryPercent?, reason}`.
   *
   * `power`, `reachability` and `audio` describe a *state*, so registering also
   * delivers the current one immediately — an app never has to make a separate
   * read call for the thing it just subscribed to.
   */
  observe(kind: PlatformObserveSource, name: string): Promise<void>;
  unobserve(kind: PlatformObserveSource, name: string): Promise<void>;

  /**
   * Calendar events overlapping a range (EventKit, in the shell).
   *
   * `from`/`to` are ISO-8601 strings; the default range is now → +24 h and the
   * range is capped at 14 days (a longer ask is clamped, not refused). Resolves
   * with `[{title, start, end, allDay, calendar, location?}]`, sorted by start.
   *
   * First use raises the system's Calendars prompt, attributed to Ledge. A
   * denial **rejects** with a sentence naming the Settings pane — never a hang
   * and never a crash.
   */
  calendar(range?: { from?: string; to?: string }): Promise<CalendarEvent[]>;

  /** Who is in front and how idle the machine is:
   * `{frontmost?: {bundleId, localizedName}, idleSeconds, screenLocked?}`.
   * `screenLocked` is omitted when the shell cannot know it cheaply. No prompt:
   * every field is an in-process read. */
  workspace(): Promise<WorkspaceInfo>;

  /**
   * One reduced-accuracy location fix: `{lat, lon, accuracyMeters, timestamp}`.
   *
   * First use raises the system's Location Services prompt (WhenInUse),
   * attributed to Ledge; a denial rejects. **Times out after 8 s** rather than
   * hanging — "the user never answered the prompt" and "the radios never got a
   * fix" are indistinguishable from here. The fix is cached for 60 s, so a
   * weather app polling on a timer does not spin the radios once per poll.
   */
  location(): Promise<LocationFix>;

  /**
   * A Spotlight query. `query` is an **NSPredicate metadata-query string**
   * (`kMDItemContentType == "public.pdf"`), and `scopes` defaults to the user's
   * home directory. Capped at 50 results and 5 seconds.
   *
   * A malformed predicate rejects with an error; it never reaches the ObjC
   * parser that would raise an uncatchable exception, so one app's typo cannot
   * take the shell down.
   */
  spotlight(options: { query: string; scopes?: string[] }): Promise<SpotlightHit[]>;

  /** The default output device: `{deviceName, volume, muted, transportType,
   * batteryPercent?}`. `batteryPercent` appears only for Bluetooth devices that
   * publish one (AirPods do; most do not). */
  audio(): Promise<AudioInfo>;

  /** Set the default output device's volume, clamped to 0…1. Resolves with the
   * value actually applied, so an app learns it was clamped. */
  setVolume(value: number): Promise<number>;

  /**
   * Speak text through the shell's synthesizer. **One utterance at a time**: a
   * second `speak` while speaking replaces the first rather than queueing behind
   * it, because notch announcements are status and status that queues is status
   * that lies. The replaced call's Promise **resolves** — it was superseded, not
   * failed — so nobody awaits a sentence that will never be spoken.
   *
   * Capped at 500 characters; longer rejects.
   */
  speak(text: string, options?: { voice?: string; rate?: number }): Promise<void>;
}

/** Privileged Settings-only bridge (spec §8). enable/disable/reorder resolve
 * once applied; stats resolves with the host's worker/catalog snapshot. */
export interface PrivilegedPlatformBridge extends PlatformBridge {
  enable(app: string): Promise<void>;
  disable(app: string): Promise<void>;
  reorder(order: string[]): Promise<void>;
  stats(): Promise<unknown>;
  /**
   * End Ledge — the shell, the host it parents, and every worker with it.
   *
   * Unlike the rest of this interface it is executed by the **shell**: it is the
   * only process that can terminate itself, and the host is its child. It
   * resolves just before the process goes, so an app can `await` it, but only
   * because the shell answers first and terminates on the next turn — nothing
   * after the await is guaranteed to run.
   *
   * Ledge is `LSUIElement`: no Dock icon, and no menu-bar item since the status
   * menu was removed. This is the user's only quit.
   */
  quit(): Promise<void>;
}

export interface Ctx {
  /** Shallow-merge `patch` into the props object passed to the default export
   * and schedule a render. In-memory only; the sole monitor → UI bridge (§6). */
  update(patch: Record<string, unknown>): void;
  /**
   * A user notification, posted by the shell, plus the optional notch glow (§6).
   *
   * `actions` puts buttons on it — the whole point of moving notifications out
   * of the host: "[Execute] [Skip]" in the banner is the agentic approval loop.
   * A pressed button arrives back as the app-level `notification` event
   * (`onEvent("notification", { id, action })`), which is why this returns the
   * notification's **id**: it is how an app tells its own notifications apart.
   * Buttons need a bundled shell; unbundled, the text still shows (see
   * shell/README.md), so an app must not depend on a button being pressable.
   */
  notify(
    text: string,
    options?: { attention?: boolean; title?: string; actions?: NotifyAction[] },
  ): number;
  /** Notch glow without a notification (§6). */
  attention(): void;
  apple: AppleBridge;
  /** Push one imperative frame to a `canvas` node of this app's own tree
   * (spec §3.4). `id` is that node's id — the one the reconciler allocated for
   * the `<canvas>` element, which an app reads back from its `onKey`/`onClick`
   * handlers or (more usually) pins with a ref-like prop. Frames bypass the
   * reconciler entirely, so a game can draw faster than it re-renders; the shell
   * keeps only the latest frame per canvas per display tick. */
  draw(id: number, ops: unknown[]): void;
  /** Own the collapsed notch as a live-activity surface, or release it with
   * `null` (spec §3.3 extension). Latest wing across all apps wins; this app's
   * wing is released for it on stop, crash, and reload. */
  wing(spec: WingSpec | null): void;
  /** Ask the shell to present this app (spec §3.3). May be denied silently. */
  /**
   * Show this app's `<mini>` subtree below the notch for `ms`, then let it go
   * (spec §3.3 extension). The middle rung between a wing and the panel: enough
   * room for "[art] Title — Artist", gone before it becomes clutter.
   *
   * What is shown is declarative — whatever `<mini>` currently renders — so a
   * peek never round-trips to ask the app what to draw, and a hover during one
   * promotes to the full panel instantly. This call only says *when*.
   *
   * Latest asker wins, as with wings. Denied silently if the app has no
   * `<mini>` in its tree.
   */
  peek(ms?: number): void;
  expand(): void;
  /** Ask the shell to put this app away (spec §3.3). Ignored unless this app is
   * the one currently presented. */
  collapse(): void;
  /**
   * Take a screenshot, executed by the shell (spec §6 extension). Resolves with
   * the path of a PNG in the shell's temp directory — the app may read, copy or
   * move it; nobody deletes it behind the app's back.
   *
   * Interactive by default (the user drags out a region). **Rejects** when the
   * user cancels, matching `ctx.apple`: a capture the user refused is a
   * genuinely exceptional path for the code that asked for one. First use
   * raises the system's Screen Recording prompt, attributed to Ledge.
   */
  capture(options?: { interactive?: boolean }): Promise<string>;
  /**
   * One headless turn of the **user's own agent CLI** (spec §8). Ledge never
   * calls a model API; this spawns whatever agent the user already has
   * (`claude` today, `LEDGE_AGENT_CMD` to override) in the app's own folder.
   *
   * Never rejects — see `AgentResult`. One call per app at a time: a second
   * call while one is in flight comes back `{ ok: false, error: "…busy…" }`
   * rather than queueing, so an app cannot build an unbounded backlog of turns
   * that each spend the user's tokens.
   */
  agent(prompt: string, options?: Omit<AgentRequest, "prompt">): Promise<AgentResult>;
  /** The OS surface — see `PlatformBridge`. Every app gets observe/unobserve and
   * the seven request/reply calls; only Settings gets the app-management calls,
   * because those change *other* apps. */
  platform: PlatformBridge;
}

/** Settings' ctx (spec §8): everything above, plus app management. */
export interface PrivilegedCtx extends Ctx {
  platform: PrivilegedPlatformBridge;
}

export interface CtxIO {
  /** Send a worker→host message. */
  post(msg: WorkerToHost): void;
  /** Apply a props patch to the live render session (session.update). */
  update(patch: Record<string, unknown>): void;
}

export interface CtxHandle {
  ctx: Ctx;
  /** Resolve/reject a pending apple/platform request from a host reply. Unknown
   * ids are ignored (the request was already settled, or the worker was
   * rebuilt). Called by the worker entry when a `reply` message arrives. */
  settle(reply: BridgeReply): void;
}

interface Pending {
  resolve(value: unknown): void;
  reject(error: unknown): void;
}

/** How many buttons a notification may carry. macOS shows two on the banner and
 * folds the rest into its menu; past four it is a menu, not a decision. */
const MAX_NOTIFY_ACTIONS = 4;

/**
 * Type-check the buttons at the boundary, the same way `sanitizeWing` does for
 * a wing: a malformed action would fail the shell's envelope decode and take the
 * whole notification with it. Bad entries are dropped, never guessed at.
 */
function sanitizeActions(actions: NotifyAction[] | undefined): NotifyAction[] {
  if (!Array.isArray(actions)) return [];
  return actions
    .filter(
      (action): action is NotifyAction =>
        typeof action?.id === "string" &&
        action.id.length > 0 &&
        typeof action.label === "string",
    )
    .slice(0, MAX_NOTIFY_ACTIONS)
    .map((action) => ({ id: action.id, label: action.label }));
}

/**
 * Builds the `ctx` for one worker session. `options.privileged` attaches the
 * Settings-only `ctx.platform` (spec §8) — omit it for ordinary apps so the
 * surface stays exactly the four documented bridges.
 */
/** Default dwell for `ctx.peek()` — long enough to read a title and an artist,
 * short enough that a missed one costs nothing. */
export const DEFAULT_PEEK_MS = 4_000;
const MIN_PEEK_MS = 500;
const MAX_PEEK_MS = 20_000;

/** Clamp a requested peek to something that stays a *glance*. A peek is not a
 * way to open the panel; `ctx.expand()` is, and it is the one the user can
 * dismiss. */
export function clampPeek(ms: number | undefined): number {
  if (ms === undefined || !Number.isFinite(ms)) return DEFAULT_PEEK_MS;
  return Math.min(Math.max(Math.round(ms), MIN_PEEK_MS), MAX_PEEK_MS);
}

export function createCtx(io: CtxIO, options: { privileged?: boolean } = {}): CtxHandle {
  // Request ids are per-session and monotonic; they only need to be unique
  // among this worker's in-flight bridge calls (the host keys replies by id).
  let nextRequestId = 1;
  const pending = new Map<number, Pending>();

  const request = (make: (id: number) => WorkerToHost): Promise<unknown> => {
    const id = nextRequestId++;
    return new Promise<unknown>((resolve, reject) => {
      pending.set(id, { resolve, reject });
      io.post(make(id));
    });
  };

  const apple: AppleBridge = {
    script: (source) =>
      request((id) => ({ type: "apple", id, request: { kind: "script", source } })),
    shortcut: (name, input) =>
      request((id) => ({ type: "apple", id, request: { kind: "shortcut", name, input } })),
  };

  const platform: PlatformBridge = {
    observe: (kind, name) =>
      request((id) => ({
        type: "platform",
        id,
        request: { kind: "observe", source: kind, name: String(name) },
      })) as Promise<void>,
    unobserve: (kind, name) =>
      request((id) => ({
        type: "platform",
        id,
        request: { kind: "unobserve", source: kind, name: String(name) },
      })) as Promise<void>,
    calendar: (range) =>
      request((id) => ({
        type: "platform",
        id,
        // Absent, not null: the shell defaults the range, and a null would have
        // to be re-interpreted as absent at every layer in between.
        request: {
          kind: "calendar",
          ...(typeof range?.from === "string" ? { from: range.from } : {}),
          ...(typeof range?.to === "string" ? { to: range.to } : {}),
        },
      })) as Promise<CalendarEvent[]>,
    workspace: () =>
      request((id) => ({ type: "platform", id, request: { kind: "workspace" } })) as Promise<WorkspaceInfo>,
    location: () =>
      request((id) => ({ type: "platform", id, request: { kind: "location" } })) as Promise<LocationFix>,
    spotlight: (options) =>
      request((id) => ({
        type: "platform",
        id,
        request: {
          kind: "spotlight",
          query: String(options?.query ?? ""),
          ...(Array.isArray(options?.scopes) ? { scopes: options.scopes.map(String) } : {}),
        },
      })) as Promise<SpotlightHit[]>,
    audio: () =>
      request((id) => ({ type: "platform", id, request: { kind: "audio" } })) as Promise<AudioInfo>,
    setVolume: (value) =>
      request((id) => ({ type: "platform", id, request: { kind: "setVolume", value: Number(value) } }))
        // The shell answers with the value it actually applied; unwrapping it
        // here keeps the app's call site `await ctx.platform.setVolume(0.4)`.
        .then((data) => Number((data as { volume?: number } | undefined)?.volume ?? value)),
    speak: (text, speakOptions) =>
      request((id) => ({
        type: "platform",
        id,
        request: {
          kind: "speak",
          text: String(text),
          ...(typeof speakOptions?.voice === "string" ? { voice: speakOptions.voice } : {}),
          ...(typeof speakOptions?.rate === "number" ? { rate: speakOptions.rate } : {}),
        },
      })) as Promise<void>,
  };

  /** The Settings-only half (spec §8), layered over the observe bridge every
   * app has. Split rather than gated inside each method: an ordinary app should
   * not be able to *see* a call it may not make. */
  const privilegedPlatform: PrivilegedPlatformBridge = {
    ...platform,
    enable: (app) =>
      request((id) => ({ type: "platform", id, request: { kind: "enable", app } })) as Promise<void>,
    disable: (app) =>
      request((id) => ({ type: "platform", id, request: { kind: "disable", app } })) as Promise<void>,
    reorder: (order) =>
      request((id) => ({ type: "platform", id, request: { kind: "reorder", order } })) as Promise<void>,
    stats: () => request((id) => ({ type: "platform", id, request: { kind: "stats" } })),
    quit: () =>
      request((id) => ({ type: "platform", id, request: { kind: "quit" } })) as Promise<void>,
  };

  const ctx: Ctx = {
    update: (patch) => io.update(patch),
    notify: (text, notifyOptions) => {
      // Notifications draw an id from the same counter as bridge requests: it
      // is not awaited, but it has to be unique among *this* worker's live
      // notifications so a pressed button routes back unambiguously.
      const id = nextRequestId++;
      const title = notifyOptions?.title;
      const actions = sanitizeActions(notifyOptions?.actions);
      io.post({
        type: "notify",
        id,
        text: String(text),
        attention: notifyOptions?.attention ?? false,
        ...(typeof title === "string" ? { title } : {}),
        ...(actions.length > 0 ? { actions } : {}),
      });
      return id;
    },
    attention: () => io.post({ type: "attention" }),
    apple,
    capture: (captureOptions) =>
      request((id) => ({
        type: "capture",
        id,
        request: { interactive: captureOptions?.interactive ?? true },
      })) as Promise<string>,
    agent: (prompt, agentOptions) =>
      request((id) => ({
        type: "agent",
        id,
        request: { prompt, ...(agentOptions ?? {}) },
      })).then(
        (value) => value as AgentResult,
        // The host only ever replies ok:true for agent turns, but a worker that
        // is torn down mid-flight must not surface a rejection into a monitor.
        (error) => ({ ok: false, error: String(error) }) as AgentResult,
      ),
    draw: (id, ops) => {
      // Type-guard at the boundary: a non-integer id or a non-array op list can
      // never reach the wire, where it would fail envelope validation and cost
      // the whole connection (spec §1) for one bad frame.
      if (!Number.isInteger(id) || !Array.isArray(ops)) return;
      io.post({ type: "draw", id, ops });
    },
    wing: (spec) => io.post({ type: "wing", wing: sanitizeWing(spec) }),
    // Clamped here rather than shell-side so an app cannot pin the notch open
    // with a peek measured in minutes — that is the panel's job, and the app has
    // ctx.expand() for it.
    peek: (ms) => io.post({ type: "chrome", request: "peek", ms: clampPeek(ms) }),
    expand: () => io.post({ type: "chrome", request: "expand" }),
    collapse: () => io.post({ type: "chrome", request: "collapse" }),
    platform,
  };
  if (options.privileged) {
    (ctx as PrivilegedCtx).platform = privilegedPlatform;
  }

  const settle = (reply: BridgeReply): void => {
    const entry = pending.get(reply.id);
    if (!entry) return;
    pending.delete(reply.id);
    if (reply.ok) entry.resolve(reply.value);
    else entry.reject(new Error(reply.error));
  };

  return { ctx, settle };
}
