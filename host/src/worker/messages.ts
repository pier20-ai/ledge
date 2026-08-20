// Worker ⇄ host message contract (spec §6). A worker is one app's React +
// user code running in a Bun Worker; it talks to the host thread ONLY through
// `postMessage` — transport (the UDS, framing, envelopes in src/protocol and
// src/connection) is the host thread's job, never the worker's. These types
// are the boundary: the host thread translates them to/from wire envelopes
// (§2–§4), and the wiring agent consumes this contract next.
//
// Discriminant is `type`. These objects are structured-clone payloads over the
// Worker boundary, so every field must be plain-serializable — no functions,
// no class instances (the reconciler already reduced the view tree to plain
// Mutation objects, and event handlers stay worker-side keyed by (id, name)).

import type { Mutation } from "../render/mutations";
import type { AppMeta, SettingValue } from "./meta";
import type { WingSpec } from "./wing";

export type { AppMeta, PanelSpec, SettingSpec, SettingType, SettingValue } from "./meta";
export type { WingCanvas, WingMeter, WingSpec } from "./wing";

export type ConsoleLevel = "log" | "info" | "warn" | "error" | "debug";

/** The presentation an app may ask the shell for (spec §3.3). `attention` is
 * not here: it has its own message because it is a ping, not a state request. */
/**
 * `permissions` raises the shell's own permission surface. Settings-only, and
 * gated on BOTH sides: an app that could put an official-looking consent panel
 * on screen at a moment of its choosing is the ambush that surface exists to
 * prevent. It is chrome rather than a platform call because nothing comes back
 * — the shell either shows it or does not.
 *
 * `peek` is the third presentation rung, between the collapsed wing and the
 * full panel: show the app's `<mini>` subtree just below the notch for a few
 * seconds, then put it away. A track change, an alarm firing, your turn in
 * chess — moments that deserve more than a wing and less than the panel.
 */
export type ChromeRequest = "expand" | "collapse" | "peek" | "permissions";

/**
 * A notification's priority class (spec §3.3, flow.md's Ti knob).
 *
 * `ambient` retracts on its dwell; `alert` **holds** until it is acted on or
 * dismissed, because the one thing an alarm must not do is time out while the
 * user is looking away. Absent is ambient — an app that says nothing is not
 * raising an alarm.
 */
export type NotificationClass = "ambient" | "alert";

/** Which side of the shared app health state threw (spec §6 rule 2, §7): the
 * monitor loop, or a React render (initial mount / event / ctx.update). */
export type CrashPhase = "render" | "monitor";

/** The one bridge into AppleScript / Shortcuts — executed by the shell, never
 * the worker (workers can't own TCC prompts; macOS handles consent). Spec §6. */
export type AppleRequest =
  | { kind: "script"; source: string }
  | { kind: "shortcut"; name: string; input?: unknown };

/** One button on a notification (spec §6, `ctx.notify` extension). `id` is the
 * app's own token: it comes back verbatim as the `notification` event's
 * `action`, so an app matches on a string it chose rather than an index. */
export interface NotifyAction {
  id: string;
  label: string;
}

/** `ctx.notify` as it crosses the worker boundary. `id` is per worker (it only
 * has to distinguish this app's live notifications); `attention` is the §3.3
 * notch glow, unchanged from the four-bridge era. */
export interface NotifyRequest {
  id: number;
  text: string;
  attention: boolean;
  title?: string;
  actions?: NotifyAction[];
}

/** `ctx.capture()` — an interactive screenshot taken BY THE SHELL (it owns the
 * Screen Recording consent, spec §6 reasoning for ctx.apple applies verbatim).
 * `interactive` selects a region; false grabs the whole screen. */
export interface CaptureRequest {
  interactive: boolean;
}

/**
 * `ctx.agent(prompt, options)` — one headless turn of the **user's own agent
 * CLI** (spec §8: Ledge never calls a model API; adapters are the only
 * agent-specific code). Executed by the host thread, not the shell: it is a
 * subprocess, not a TCC-owning UI action, and nothing about it needs pixels.
 *
 * - `files`   paths appended to the prompt for the agent to read itself — the
 *             agent already has file tools, so shipping contents would be a
 *             worse version of what it does natively.
 * - `schema`  a JSON schema the reply must match; the host appends the
 *             instruction, strips code fences, parses, and retries once.
 * - `timeoutMs` per-call override of the 60 s default.
 */
export interface AgentRequest {
  prompt: string;
  files?: string[];
  schema?: unknown;
  timeoutMs?: number;
}

/**
 * What `ctx.agent` resolves with. It **never rejects**: a turn that fails (no
 * agent installed, a timeout, an unparseable reply) is an ordinary outcome an
 * app should branch on, and a throw inside `monitor` is an app crash with
 * backoff (spec §6 rule 2) — far too big a hammer for "the CLI wasn't there".
 */
export interface AgentResult {
  ok: boolean;
  /** The agent's reply text (always present on success). */
  text?: string;
  /** Parsed JSON, only when `schema` was requested and parsing succeeded. */
  json?: unknown;
  error?: string;
}

/**
 * What `ctx.platform.observe` can watch.
 *
 * Each source is one shared OS resource in the shell, refcounted across apps: a
 * pasteboard poll timer, an `NWPathMonitor`, an IOKit run-loop source, a pair of
 * CoreAudio property listeners. It exists exactly while at least one app is
 * watching it and is torn down at zero — which is why an app that forgets to
 * unobserve still costs nothing once its worker dies (observers are released per
 * app on every §3.2 lifecycle transition).
 */
export type PlatformObserveSource =
  | "distributedNotification"
  | "workspace"
  | "pasteboard"
  | "power"
  | "reachability"
  | "audio"
  | "focus";

/**
 * The signal names each source accepts.
 *
 * Only `distributedNotification` has an open vocabulary — those names belong to
 * whoever posts them. Everything else is a **translated** name: an app writes
 * `observe("workspace", "screenLocked")`, never `"com.apple.screenIsLocked"`,
 * because the raw names are split across two different notification centers and
 * are Apple's to rename. A name outside the vocabulary is refused with the list
 * of the ones that exist, rather than registering nothing and looking like it
 * worked.
 *
 * The state-shaped sources (`pasteboard`, `power`, `reachability`, `audio`) have
 * a single name, `changed`, and put *what* changed in the payload — one
 * registration gets an app everything about that resource.
 */
export type WorkspaceSignal =
  | "didActivateApplication"
  | "willSleep"
  | "didWake"
  | "screensDidSleep"
  | "screensDidWake"
  | "screenLocked"
  | "screenUnlocked";

/** The payload of an id-0 `platform` event, per kind. Scalars only, always —
 * the same reduction rule `distributedNotification` has always had. */
export interface WorkspaceEventData {
  /** `didActivateApplication` only. */
  bundleId?: string;
  localizedName?: string;
}

export interface PasteboardEventData {
  changeCount: number;
  /** Readable UTIs, e.g. `public.utf8-plain-text`. NEVER the contents. */
  types: string[];
  hasStrings: boolean;
}

export interface PowerEventData {
  /** 0…1. Absent on a machine with no battery. */
  level?: number;
  charging: boolean;
  onAC: boolean;
  lowPowerMode: boolean;
}

export interface ReachabilityEventData {
  satisfied: boolean;
  expensive: boolean;
  constrained: boolean;
  interface: "wifi" | "wired" | "cellular" | "other";
}

export interface AudioEventData {
  deviceName: string;
  volume: number;
  muted: boolean;
  transportType: string;
  batteryPercent?: number;
  /** `device` (the default output changed), `volume`, or `current` (the
   * immediate fire at registration). */
  reason: "device" | "volume" | "current";
}

/**
 * Do Not Disturb / Focus. Read from the user's own Focus database — a file, not
 * a private framework — so it is **silent rather than wrong** when it cannot be
 * read: an undocumented format that shifts, or a Ledge without Full Disk
 * Access, produces no events at all rather than a confident `active: false`.
 *
 * `modeName` is the user's own name for the mode ("Work") when the database
 * says so, and the mode identifier's last component when it does not.
 */
export interface FocusEventData {
  active: boolean;
  modeName?: string;
}

/** One event from `ctx.platform.calendar()`. Times are ISO-8601 strings. */
export interface CalendarEvent {
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  calendar: string;
  location?: string;
}

/** `ctx.platform.workspace()` — who is in front and how idle the machine is. */
export interface WorkspaceInfo {
  /** Absent when nothing is frontmost (rare, but real during login). */
  frontmost?: { bundleId: string; localizedName: string };
  idleSeconds: number;
  /** Omitted when the shell cannot know it cheaply. */
  screenLocked?: boolean;
}

/** `ctx.platform.location()` — one reduced-accuracy fix. */
export interface LocationFix {
  lat: number;
  lon: number;
  accuracyMeters: number;
  /** ISO-8601. */
  timestamp: string;
}

/** One `ctx.platform.spotlight()` result. */
export interface SpotlightHit {
  path: string;
  name: string;
  contentType: string;
  /** ISO-8601; absent when the index has no modification date. */
  modified?: string;
}

/** `ctx.platform.audio()` — the default output device. */
export interface AudioInfo {
  deviceName: string;
  volume: number;
  muted: boolean;
  /** `builtIn` | `usb` | `bluetooth` | `hdmi` | `airplay` | … */
  transportType: string;
  /** Bluetooth only, best effort: AirPods publish it, most devices do not. */
  batteryPercent?: number;
}

/**
 * One live recording, as both `ctx.record.start()` and a `status` reply describe
 * it. Sessions are **per app**: `dir` is `<recordings root>/<appId>/<id>/`, so
 * two apps that record on different days never share a folder.
 *
 * `startedAt` is an ISO-8601 string, like every other time on this bridge.
 * `sources` is the subset of `"mic"`/`"system"` actually being captured — an app
 * that asked for both on a machine that can only do one learns it here rather
 * than from a silent file.
 */
export interface RecordSession {
  id: string;
  dir: string;
  startedAt: string;
  sources: string[];
  /** `"aac"` (`.m4a`) or `"wav"` (PCM). */
  format: string;
}

/**
 * `ctx.record.status()` — the whole recorder in one answer.
 *
 * The hardware is global, so there is **one** recording at a time across all
 * apps: `recording` says the machine is busy and `mine` says it is busy with
 * *this* app's session. An app that finds `recording && !mine` is being told to
 * keep its hands off, and one that finds `recording && mine` has just come back
 * from a worker restart with its own session still running (the shell keeps
 * recording across those) — which is an adoption, not a new take.
 *
 * `root` is this app's own recordings directory. It may not exist yet; a reader
 * that lists it must treat ENOENT as "no sessions", not as an error.
 */
export interface RecordStatus {
  available: boolean;
  /** Why not, when `available` is false — a sentence, for the panel. */
  reason?: string;
  recording: boolean;
  mine: boolean;
  root: string;
  /** Present only while a recording is live AND owned by the asking app. */
  session?: RecordSession;
  /** Speech-to-text over the finished files, when the OS can do it at all. */
  transcription: { available: boolean; reason?: string };
}

/** What `ctx.record.stop()` resolves with. `files` holds **absolute** paths and
 * a source that was never requested has no key at all. The shell also leaves a
 * `meta.json` in `dir` describing the same session, with basenames instead. */
export interface RecordStopResult {
  id: string;
  dir: string;
  seconds: number;
  files: { mic?: string; system?: string };
}

/** `ctx.record.levels()` — 0…1 RMS per source being captured, plus how long the
 * session has been running. A source not in the session has no key, which is
 * what makes an absent needle different from a silent one. */
export interface RecordLevels {
  mic?: number;
  system?: number;
  seconds: number;
}

/**
 * `ctx.platform.*`.
 *
 * Three groups with different audiences, deliberately in one type because they
 * go down one bridge.
 *
 * - `observe`/`unobserve` are for **every** app: watching an OS signal is the
 *   invalidation half of a polling monitor, and every monitor app has the same
 *   three-second-latency problem Music does.
 * - `calendar`/`workspace`/`location`/`spotlight`/`audio`/`setVolume`/`speak`
 *   and the four `record*` calls are also for every app: each asks the shell one
 *   question the worker process structurally cannot answer, because the answer
 *   needs a TCC prompt attributed to the process with the UI, or a per-process
 *   framework registration. Recording is both — the microphone prompt is TCC and
 *   the capture engine is one per process, which is also why only one app may
 *   record at a time.
 * - `enable`/`disable`/`reorder`/`stats`/`quit` remain Settings-only (spec §8) —
 *   they change *other* apps, or end everything.
 *
 * `quit` sits with the management calls by audience and with the shell calls by
 * routing: only the shell process can end itself (the host is its child and a
 * worker is a thread inside that child), so it is the one Settings-only call
 * that goes out on the wire.
 */
export type PlatformRequest =
  | { kind: "enable"; app: string }
  | { kind: "disable"; app: string }
  | { kind: "reorder"; order: string[] }
  | { kind: "stats" }
  | { kind: "quit" }
  | { kind: "observe"; source: PlatformObserveSource; name: string }
  | { kind: "unobserve"; source: PlatformObserveSource; name: string }
  | { kind: "calendar"; from?: string; to?: string }
  | { kind: "workspace" }
  | { kind: "location" }
  | { kind: "spotlight"; query: string; scopes?: string[] }
  | { kind: "audio" }
  | { kind: "setVolume"; value: number }
  | { kind: "speak"; text: string; voice?: string; rate?: number }
  | { kind: "recordStatus" }
  // `sources` is a subset of "mic"/"system" and `format` is "aac" or "wav";
  // both are absent when the app did not choose, and the shell defaults them
  // (both sources, AAC) rather than the worker guessing on its behalf.
  | { kind: "recordStart"; sources?: string[]; format?: string }
  | { kind: "recordStop" }
  | { kind: "recordLevels" };

/**
 * Worker → host. Everything the app runtime pushes up.
 *
 * - `commit`     one React commit batch from the renderer sink (spec §3.1).
 * - `meta`       the app's `export const meta`, extracted right after import and
 *                already sanitized (spec §6); the host merges it into the
 *                catalog and re-sends the full snapshot (§3.6).
 * - `draw`       one imperative frame for one of this app's canvas nodes
 *                (spec §3.4) — bypasses the reconciler so a game can run at
 *                frame rate. `id` is the canvas' node id in the app's own tree.
 * - `wing`       the collapsed-notch surface this app wants (§3.3 extension), or
 *                null to release it.
 * - `chrome`     expand/collapse request (§3.3); the shell may deny silently.
 * - `notify`     ctx.notify — a notification posted by the SHELL (§6), with an
 *                `id` so a pressed action button can come back to this app, and
 *                optional `title`/`actions`. `attention` keeps its old meaning.
 * - `attention`  ctx.attention — notch glow, no notification (§6, chrome §3.3).
 * - `apple`      ctx.apple.* — request; host replies by `id` (see BridgeReply).
 * - `capture`    ctx.capture — shell-side screenshot; host replies by `id`.
 * - `agent`      ctx.agent — one headless turn of the user's agent CLI (§8);
 *                host replies by `id` with an AgentResult.
 * - `platform`   ctx.platform.* and ctx.record.* — one shell capability call;
 *                host replies by `id`. Both surfaces ride this one message
 *                because they are the same thing on the wire: a `kind`, some
 *                fields, one reply.
 * - `console`    captured console.* output; the host folds it into the app log
 *                and crash.log (spec §6, §7).
 * - `crash`      an uncaught throw; the host decides restart policy (§6 rule 2,
 *                §7) — NOT the worker's call. `stack` is null when unavailable.
 */
export type WorkerToHost =
  | { type: "commit"; mutations: Mutation[] }
  | { type: "meta"; meta: AppMeta }
  | { type: "draw"; id: number; ops: unknown[] }
  | { type: "wing"; wing: WingSpec | null }
  // `ms` and `cls` apply to `peek` only: how long the swell stays up before the
  // shell retracts it, and which priority class it belongs to. Absent `ms`
  // means the shell's default dwell; absent `cls` means ambient. Named `cls`
  // here and `class` on the wire, because `class` is a reserved word in the one
  // language and merely awkward in the other.
  | { type: "chrome"; request: ChromeRequest; ms?: number; cls?: NotificationClass }
  | ({ type: "notify" } & NotifyRequest)
  | { type: "attention" }
  | { type: "apple"; id: number; request: AppleRequest }
  | { type: "capture"; id: number; request: CaptureRequest }
  | { type: "agent"; id: number; request: AgentRequest }
  | { type: "platform"; id: number; request: PlatformRequest }
  | { type: "console"; level: ConsoleLevel; text: string }
  | { type: "crash"; phase: CrashPhase; message: string; stack: string | null };

/** Reply to an `apple`/`capture`/`agent`/`platform` request, matched by `id`.
 * The host thread produces these from the shell's execution result (or, for
 * `agent`, from the CLI it ran itself). */
export type BridgeReply =
  | { type: "reply"; id: number; ok: true; value: unknown }
  | { type: "reply"; id: number; ok: false; error: string };

/** Lifecycle phase (spec §4.2). Informational to the worker — the monitor keeps
 * running regardless; there is no ctx hook for it (ctx is the four bridges). */
export type LifecyclePhase = "expanded" | "collapsed" | "hidden" | "visible";

export interface ScreenInfo {
  notchWidth: number;
  menubarHeight: number;
  scale: number;
}

/**
 * Host → worker. Everything the worker consumes.
 *
 * - `event`      a shell event (spec §4.1); dispatched to the (id, name) prop
 *                handler the reconciler kept worker-side. **`id: 0` is the
 *                app-level convention**: node ids start at 1 (§3.1), so 0 can
 *                never be a node, and an event addressed to it belongs to the
 *                app itself (`drop`, `notification`, `platform`). Those go to
 *                the app's optional `onEvent(name, data, ctx)` export.
 * - `lifecycle`  panel phase change (spec §4.2); informational. Also carries the
 *                system's Reduce Motion state, which lands on `ctx.reduceMotion`
 *                before `onLifecycle` is called.
 * - `settings`   the app's declared controls, as the user has them set — the
 *                complete effective map, never a patch. Sent once as the worker
 *                comes up and again on every accepted change; it lands on
 *                `ctx.settings` first and then, from the second delivery on,
 *                arrives at `onEvent("settings", values, ctx)`.
 * - `reply`      resolves a pending bridge request Promise by id.
 *
 * Termination is out-of-band: the host calls `worker.terminate()`, which
 * cancels the in-flight monitor call, timers, and pending bridges at once
 * (spec §6 rule 3) — there is no "terminate" message.
 */
export type HostToWorker =
  | { type: "event"; id: number; name: string; data: Record<string, unknown> }
  | {
      type: "lifecycle";
      phase: LifecyclePhase;
      screen?: ScreenInfo;
      /** The system's Reduce Motion preference (spec §4.2). Absent = unchanged,
       * which is what a shell that predates the flag looks like. */
      reduceMotion?: boolean;
    }
  | { type: "settings"; values: Record<string, SettingValue> }
  | BridgeReply;

/**
 * Boot config handed to the worker out-of-band via `workerData` (spec §6, §7):
 * the path of the (Bun-transpiled) app module, and whether this worker gets the
 * privileged `ctx.platform` API (Settings only, spec §8).
 */
export interface ReactPaths {
  react: string;
  reconciler: string;
  constants: string;
}

export interface WorkerBoot {
  /** Absolute path or file: URL of the app module to import. */
  modulePath: string;
  /** Directory to resolve `react` from — the one the APPS resolve against
   * (`~/.ledge`, or the apps root in the repo). The reconciler and the app must
   * share one React instance or hooks break; see render/runtime.ts. */
  modulesRoot: string;
  /** Where React and the reconciler actually are, resolved by the HOST thread.
   * Absent only in tests that boot a worker directly; see ReactPaths for why
   * the worker must not resolve them itself. */
  reactPaths?: ReactPaths;
  /** Grants ctx.platform. Set by the host only for the Settings app. */
  privileged?: boolean;
  /**
   * What the host has STORED for this app's settings — the raw settings.json
   * map, not an effective one (spec §2).
   *
   * Raw, because only the worker can know the declaration: `meta.settings`
   * lives inside the module, and the module is imported here. The worker lays
   * these over its own declared defaults the moment it has both, which is what
   * makes `ctx.settings` right on the monitor's FIRST line rather than one
   * message later — a `settings` message is still posted (§5), but it is a
   * message, and a monitor that reads a setting before the queue drains would
   * otherwise see an empty map and act on it.
   */
  settings?: Record<string, SettingValue>;
}
