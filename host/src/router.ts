// The multiplexer (spec §§3–4): routes worker commit batches out to the shell as
// per-app `commit` envelopes, shell events/lifecycle in to the right worker,
// selection to the presented-app decision, and the app lifecycle envelopes that
// keep the shell's shadow tree in sync across (re)spawns. It owns one
// AppSupervisor per enabled app and the file watcher. The shell connection is
// injected via `bindSession`/`clearSession` so the router is fully testable
// against the FakeShell (or a recording session) with no real socket.

import { join, resolve } from "node:path";
import { AgentRunner } from "./agent";
import { Builder } from "./builder";
import type { BuilderEvent } from "./codex/events";
import type { ShellSession } from "./connection";
import type { Envelope } from "./protocol/envelope";
import type { Mutation } from "./render/mutations";
import { resolveReactPaths, type ReactPaths } from "./render/runtime";
import { applyMeta, scanApps, type CatalogApp } from "./registry";
import { SettingsStore } from "./settings";
import {
  AppSupervisor,
  realScheduler,
  type AppState,
  type BackoffPolicy,
  type RestartScheduler,
  type SupervisorSink,
} from "./supervisor";
import type { TranspileError, WorkerFactory } from "./worker-factory";
import { transpileCheck } from "./worker-factory";
import { watchApps } from "./watcher";
import type {
  AgentRequest,
  AppMeta,
  AppleRequest,
  CaptureRequest,
  ChromeRequest,
  NotificationClass,
  HostToWorker,
  LifecyclePhase,
  NotifyRequest,
  PlatformRequest,
  ScreenInfo,
  WingSpec,
} from "./worker/messages";

/**
 * How long the host waits for the shell to settle a capability request before
 * telling the app it failed.
 *
 * AppleScript gets 10 s: an Apple event to a running app answers in
 * milliseconds, and one that hasn't in ten seconds is a hung target — an app
 * waiting forever on it would look like an app that stopped working. Capture
 * gets two minutes, because the thing it is waiting for is a **person**
 * dragging out a region.
 *
 * Both are host-side and one-way: after the deadline the request is forgotten,
 * so a late result is dropped rather than resolving a Promise the app has
 * already been told about.
 */
export const APPLE_TIMEOUT_MS = 10_000;
export const CAPTURE_TIMEOUT_MS = 120_000;
/** `ctx.platform.observe` is a registration, not work: the shell answers in
 * microseconds or is not there at all. It shares AppleScript's deadline because
 * "the shell stopped answering" is the only way it can fail slowly. The same
 * deadline covers the bounded calls — spotlight caps itself at 5 s and location
 * at 8 s shell-side, so this only ever fires when the shell has gone away. */
export const PLATFORM_TIMEOUT_MS = 10_000;
/** The three calls whose first use raises a **TCC prompt** (calendar, location,
 * and starting a recording): the thing they are waiting for is a person reading
 * a modal, which is `ctx.capture`'s reasoning verbatim. Once granted they answer
 * in milliseconds. */
export const PLATFORM_GRANT_TIMEOUT_MS = 120_000;
/** `speak` resolves when the utterance *finishes*, and 500 characters at a slow
 * rate is minutes of speech. Timing it out at ten seconds would reject a Promise
 * for a sentence that is still being read aloud. */
export const PLATFORM_SPEAK_TIMEOUT_MS = 300_000;

/** One capability request awaiting a shell result, keyed by (app, id). */
interface PendingBridge {
  app: string;
  id: number;
  what: string;
  cancelTimeout(): void;
}
export interface RouterOptions {
  appsRoot: string;
  /** The host's own settings file (src/settings.ts). Defaults to
   * `SettingsStore.pathFor(appsRoot)` — `~/.ledge/settings.json` for a real
   * install. Tests point it at a temp path; nothing in production overrides it. */
  settingsPath?: string;
  factory?: WorkerFactory;
  scheduler?: RestartScheduler;
  transpile?: (modulePath: string) => Promise<TranspileError | null>;
  /** Runs `ctx.agent` turns (spec §8). Injected in tests so no test ever
   * invokes a real agent CLI. */
  agentRunner?: AgentRunner;
  /** Injected in tests so nothing ever spawns a real Codex (spec §8). */
  builder?: Builder;
  /** Overrides the capability deadlines above. Tests shorten them; nothing in
   * production does. */
  timeouts?: {
    apple?: number;
    capture?: number;
    platform?: number;
    /** The TCC-prompting calls (calendar, location). */
    platformGrant?: number;
    platformSpeak?: number;
  };
  backoff?: Partial<BackoffPolicy>;
  /** Enable the app.jsx file watcher (default true). Tests disable it. */
  watch?: boolean;
  /** Host-log sink (default console.log). */
  log?: (line: string) => void;
}

export class Router implements SupervisorSink {
  private readonly appsRoot: string;
  private readonly factory?: WorkerFactory;
  private readonly scheduler: RestartScheduler;
  private readonly transpile: (modulePath: string) => Promise<TranspileError | null>;
  private readonly agentRunner: AgentRunner;
  private readonly builder: Builder;
  private readonly appleTimeoutMs: number;
  private readonly captureTimeoutMs: number;
  private readonly platformTimeoutMs: number;
  private readonly platformGrantTimeoutMs: number;
  private readonly platformSpeakTimeoutMs: number;
  private readonly backoff?: Partial<BackoffPolicy>;
  private readonly watchEnabled: boolean;
  private readonly hostLog: (line: string) => void;

  /** Which apps the user has turned off, and the file that remembers it. The
   * host is its only writer (spec §8: enable/disable is Settings asking the
   * host, never an app editing state itself). */
  private readonly settings: SettingsStore;

  private readonly supervisors = new Map<string, AppSupervisor>();
  /** Last `meta` each app's worker posted (spec §6). Replaced wholesale, never
   * merged: an app that drops `meta.name` on reload must fall back to its
   * directory name, which only works if the previous name is forgotten. */
  private readonly appMeta = new Map<string, AppMeta>();
  /** Last registry scan, so a `meta` message can re-publish the FULL catalog
   * snapshot (spec §3.6 — no diffs) without re-hitting the filesystem. */
  private catalogApps: CatalogApp[] = [];
  /** Which apps currently hold a wing, so lifecycle transitions know whether
   * there is anything to release (spec §3.3 extension). */
  private readonly wings = new Map<string, WingSpec>();
  /** Capability requests in flight to the shell, keyed `app#id` (worker request
   * ids are per app, so the app has to be part of the key). */
  private readonly pending = new Map<string, PendingBridge>();
  /** Apps with a `ctx.agent` turn running. One at a time, per app: agent turns
   * spend the user's tokens, so a monitor that fires them faster than they
   * finish must be told "busy", not silently queued into a backlog. */
  private readonly agentBusy = new Set<string>();
  private session: ShellSession | null = null;
  private presentedApp: string | null = null;
  private closeWatcher: (() => void) | null = null;
  private reactPaths: ReactPaths | undefined;

  constructor(options: RouterOptions) {
    // Absolute from here down. `--apps-root ../protocol/demo-apps` is the
    // natural way to run the host from the repo, and a relative root leaks into
    // module resolution as "relative to the process cwd" (see
    // render/runtime.ts). Normalising once, at the edge, means nothing
    // downstream — app dirs, crash.log paths, log lines — has to think about it.
    this.appsRoot = resolve(options.appsRoot);
    this.settings = new SettingsStore(options.settingsPath ?? SettingsStore.pathFor(this.appsRoot));
    this.factory = options.factory;
    this.scheduler = options.scheduler ?? realScheduler;
    this.transpile = options.transpile ?? transpileCheck;
    this.agentRunner = options.agentRunner ?? new AgentRunner({ log: (line) => this.hostLog(line) });
    this.builder =
      options.builder ??
      new Builder({
        appsRoot: this.appsRoot,
        sink: {
          builder: (app, turn, event) => this.sendBuilder(app, turn, event),
          log: (line) => this.hostLog(line),
          // A brand new app should be in the strip by the time its first turn
          // starts talking, not whenever the watcher's debounce elapses: the
          // shell switches its editor to the new id the moment it hears
          // `created`, and an id the catalog has never mentioned would show up
          // there with no name and no icon.
          created: () => void this.rescanApps(),
        },
      });
    this.appleTimeoutMs = options.timeouts?.apple ?? APPLE_TIMEOUT_MS;
    this.captureTimeoutMs = options.timeouts?.capture ?? CAPTURE_TIMEOUT_MS;
    this.platformTimeoutMs = options.timeouts?.platform ?? PLATFORM_TIMEOUT_MS;
    this.platformGrantTimeoutMs = options.timeouts?.platformGrant ?? PLATFORM_GRANT_TIMEOUT_MS;
    this.platformSpeakTimeoutMs = options.timeouts?.platformSpeak ?? PLATFORM_SPEAK_TIMEOUT_MS;
    this.backoff = options.backoff;
    this.watchEnabled = options.watch ?? true;
    this.hostLog = options.log ?? ((line) => console.log(line));
  }

  /** `resolveReactPaths` for this apps root, computed at most once.
   *
   * A failure is not cached as a failure: seeding may still be in flight on a
   * first launch, and the next spawn should try again rather than inherit a
   * verdict from a moment when the folder was half-written. The worker still
   * resolves for itself if this comes back undefined, which is what keeps a
   * missing react an app-level crash with a real message (spec §7) instead of a
   * host that will not start.
   */
  private reactPathsOnce(): ReactPaths | undefined {
    if (!this.reactPaths) {
      try {
        this.reactPaths = resolveReactPaths(this.appsRoot);
      } catch (error) {
        this.hostLog(`[ledge-host] react not resolvable yet: ${String(error)}`);
        return undefined;
      }
    }
    return this.reactPaths;
  }

  // MARK: - Connection lifecycle

  /**
   * Bind a live shell session (spec §1: after `hello`, send `catalog`, then a
   * full commit per running app). On the first connection each enabled app is
   * started; on reconnect the shell has discarded all view state for the dead
   * generation, so each running app is reloaded to produce a fresh full commit.
   */
  async bindSession(session: ShellSession): Promise<void> {
    const reconnect = this.supervisors.size > 0;
    this.session = session;

    // Read who is turned off before the scan that reports it: an app disabled
    // in a previous session must never spawn, not even for the instant between
    // binding and the first rescan.
    await this.settings.load();
    const apps = await scanApps(this.appsRoot, this.settings.disabled);
    this.catalogApps = apps;
    this.sendCatalog();

    // Before anything is typed. A user whose first contact with Ledge is a chat
    // box that swallows a sentence and then says "could not start codex" has
    // been told the same thing, later and worse.
    this.sendBuilder("", 0, this.builder.agentStatus());

    for (const app of apps) {
      if (!app.enabled) continue;
      const existing = this.supervisors.get(app.id);
      if (!existing) {
        const supervisor = this.makeSupervisor(app.id);
        this.supervisors.set(app.id, supervisor);
        await supervisor.start();
      } else if (reconnect) {
        await existing.reload();
      }
    }

    this.ensureWatcher(apps.filter((app) => app.enabled).map((app) => app.id));
  }

  /** The connection dropped. Workers keep running (monitors don't stop, spec
   * §4.2); outbound sends are simply dropped until the next `bindSession`.
   * Wings die with the connection — the shell discards all presentation state
   * for a dead generation (spec §1), and every worker is reloaded on reconnect,
   * which re-declares whatever wing it still wants. */
  clearSession(): void {
    this.session = null;
    this.wings.clear();
    // Nothing can settle a shell-executed request now, and the next connection
    // is a new generation (spec §1) — so fail them rather than let them sit.
    for (const [key, entry] of this.pending) {
      entry.cancelTimeout();
      this.pending.delete(key);
      this.supervisors.get(entry.app)?.post({
        type: "reply",
        id: entry.id,
        ok: false,
        error: `ctx.${entry.what}: the shell disconnected`,
      });
    }
  }

  /** The app currently shown in the notch panel (from `selection`, §4.3). */
  get presented(): string | null {
    return this.presentedApp;
  }

  /** Handle one inbound envelope from the shell (spec §4). */
  onEnvelope(_session: ShellSession, envelope: Envelope): void {
    switch (envelope.type) {
      case "event": {
        const id = Number(envelope.payload.id);
        if (!Number.isInteger(id)) break;
        const name = String(envelope.payload.name ?? "");
        const data = (envelope.payload.data as Record<string, unknown> | undefined) ?? {};
        this.supervisors.get(envelope.app)?.post({ type: "event", id, name, data });
        break;
      }
      case "lifecycle": {
        const phase = String(envelope.payload.phase ?? "") as LifecyclePhase;
        const screen = envelope.payload.screen as ScreenInfo | undefined;
        // Reduce Motion rides the lifecycle envelope (spec §4.2). Forwarded only
        // when the shell actually said something: a shell that predates the flag
        // must not read as "motion is fine" on every phase change.
        const reduceMotion = envelope.payload.reduceMotion;
        this.supervisors.get(envelope.app)?.post({
          type: "lifecycle",
          phase,
          screen,
          ...(typeof reduceMotion === "boolean" ? { reduceMotion } : {}),
        });
        break;
      }
      case "selection": {
        // The gesture originates in Swift; the host is the source of truth for
        // what "selected" means (spec §4.3). The shell sends explicit §4.2
        // lifecycle envelopes alongside selection (see HostSession), which we
        // forward above, so here we only track which app is presented rather
        // than re-deriving lifecycle (which would double-deliver to the worker).
        const app = envelope.payload.app;
        this.presentedApp = typeof app === "string" ? app : null;
        break;
      }
      case "appControl": {
        // **The ledge's ✕, and Settings' switch** (flow.md, "The strip": "the
        // only ✕ in the product lives here"; spec §4.3). A CONTROL-PLANE frame
        // like `selection` and `builderInput`: the envelope's own `app` is `""`
        // and the target is in the payload, because the shell is speaking
        // *about* an app rather than for one.
        //
        // Both directions ride this one envelope because Settings is a native
        // macOS window in the shell now (spec §8) rather than an app with a
        // privileged `ctx.platform`. There is no worker left to call
        // `enable`/`disable` from, so `start` is how an app that was switched
        // off comes back, and the two actions have to be symmetric or the ✕
        // would be a one-way door.
        //
        // Both land on `setAppEnabled` — the enable/disable path, not a stop of
        // its own: the worker goes or comes, the app stays installed either way,
        // and "is this app running" keeps having one answer in one place (the
        // settings file).
        const payload = envelope.payload as { app?: string; action?: string };
        const app = String(payload.app ?? "");
        const action = String(payload.action ?? "");
        // Anything else is ignored rather than guessed at: a nameless target, or
        // a verb this host does not know, is a shell speaking a dialect we have
        // no safe reading of.
        if (app === "" || (action !== "stop" && action !== "start")) break;
        this.hostLog(`[ledge-host] ${action} '${app}' <- the ledge`);
        void this.setAppEnabled(app, action === "start").catch((error: unknown) => {
          this.hostLog(`[ledge-host] ${action} '${app}' failed: ${String(error)}`);
        });
        break;
      }
      case "resyncRequest": {
        const app = String(envelope.payload.app ?? "");
        if (app === "") {
          // Shell-level resync: re-send the catalog (spec §4.3).
          void scanApps(this.appsRoot, this.settings.disabled).then((apps) => {
            this.catalogApps = apps;
            this.sendCatalog();
          });
        } else {
          void this.supervisors.get(app)?.resync();
        }
        break;
      }
      case "appleResult": {
        // The shell executed it (spec §6). ok:true carries `value`, ok:false an
        // `error`; either way the app's Promise settles here.
        const id = Number(envelope.payload.id);
        if (!Number.isInteger(id)) break;
        const ok = envelope.payload.ok === true;
        this.settleBridge(
          envelope.app,
          id,
          ok
            ? { type: "reply", id, ok: true, value: envelope.payload.value }
            : { type: "reply", id, ok: false, error: String(envelope.payload.error ?? "apple failed") },
        );
        break;
      }
      case "captureResult": {
        const id = Number(envelope.payload.id);
        if (!Number.isInteger(id)) break;
        const ok = envelope.payload.ok === true && typeof envelope.payload.path === "string";
        this.settleBridge(
          envelope.app,
          id,
          ok
            ? { type: "reply", id, ok: true, value: envelope.payload.path }
            : {
                type: "reply",
                id,
                ok: false,
                error: String(envelope.payload.error ?? "capture failed"),
              },
        );
        break;
      }
      case "platformResult": {
        // One `platform` request settled (spec §6 extension). `data` is absent
        // for the registration verbs — the app awaited "am I watching this
        // now", and it is — and carries the answer for the calls that have one.
        const id = Number(envelope.payload.id);
        if (!Number.isInteger(id)) break;
        const ok = envelope.payload.ok === true;
        this.settleBridge(
          envelope.app,
          id,
          ok
            ? { type: "reply", id, ok: true, value: envelope.payload.data }
            : {
                type: "reply",
                id,
                ok: false,
                error: String(envelope.payload.error ?? "platform request failed"),
              },
        );
        break;
      }
      case "notifyAction": {
        // A pressed notification button (spec §6 extension) is an APP-LEVEL
        // event: it belongs to the app, not to any node in its tree, so it
        // arrives at id 0 — the same convention the drop shelf uses.
        const id = Number(envelope.payload.id);
        const action = String(envelope.payload.action ?? "");
        if (!Number.isInteger(id) || action === "") break;
        this.hostLog(`[ledge-host] notifyAction <- ${envelope.app} #${id} ${action}`);
        this.supervisors.get(envelope.app)?.post({
          type: "event",
          id: 0,
          name: "notification",
          data: { id, action },
        });
        break;
      }
      case "builderInput": {
        // The user typed into an app's chat, or asked to stop (spec §4.3).
        //
        // A CONTROL-PLANE frame, like `selection` and `resyncRequest` above: the
        // envelope's own `app` is `""` and the target is in the PAYLOAD. Reading
        // `envelope.app` here (as this did) meant every message the user ever
        // typed was addressed to the app named `""` — Codex was started in the
        // apps root, and its events came back tagged with an app the editor was
        // not showing, so the panel sat there doing nothing while a real turn
        // ran somewhere else entirely. Nothing in the host could see it: both
        // halves worked, they just disagreed about where the id lived.
        const payload = envelope.payload as { app?: string; text?: string; cancel?: boolean };
        // `""` is meaningful here, not missing: it is the [+] surface asking for
        // an app that does not exist yet (spec §4.3, §8).
        void this.builder.handleInput(String(payload.app ?? ""), payload);
        break;
      }
      default:
        this.hostLog(`[ledge-host] unhandled envelope type ${envelope.type}`);
    }
  }

  /** Stop everything (host shutdown / tests): terminate workers, close watcher. */
  shutdown(): void {
    // The app-server is a child of this process; leaving one behind would hold
    // the user's Codex session open after Ledge is gone.
    this.builder.shutdown();
    this.closeWatcher?.();
    this.closeWatcher = null;
    for (const supervisor of this.supervisors.values()) supervisor.stop();
    this.supervisors.clear();
    this.session = null;
  }

  /** Trigger a hot reload for one app (used by the watcher and tests). */
  reloadApp(appId: string): void {
    void this.supervisors.get(appId)?.reload();
  }

  /** Test/inspection accessor. */
  hasApp(appId: string): boolean {
    return this.supervisors.has(appId);
  }

  // MARK: - SupervisorSink (worker → shell)

  commit(app: string, mutations: Mutation[]): void {
    this.hostLog(`[ledge-host] commit -> ${app} (${mutations.length} mutations)`);
    this.session?.send(app, "commit", { mutations });
  }

  /**
   * An app declared its `meta` (spec §6). Merge it into that app's catalog entry
   * and re-send the WHOLE catalog — spec §3.6 is full snapshots, no diffs, and
   * the strip is built from this envelope and nothing else, so this is what puts
   * an app's real name and `sf:` icon in front of the user.
   */
  meta(app: string, meta: AppMeta): void {
    this.appMeta.set(app, meta);
    this.hostLog(
      `[ledge-host] meta <- ${app} ${JSON.stringify({ name: meta.name, icon: meta.icon, panel: meta.panel })}`,
    );
    this.sendCatalog();
  }

  draw(app: string, id: number, ops: unknown[]): void {
    // No log line: draws run at frame rate (spec §3.4) and one line per frame
    // would drown the host log.
    this.session?.send(app, "draw", { id, ops });
  }

  /**
   * ctx.wing (spec §3.3 extension). Forwarded verbatim as a `chrome` request;
   * arbitration between apps is the shell's — it owns one collapsed notch, so
   * "latest wing wins" can only be decided where the pixels are.
   */
  wing(app: string, wing: WingSpec | null): void {
    if (wing) this.wings.set(app, wing);
    else this.wings.delete(app);
    this.session?.send(app, "chrome", { request: "wing", wing });
  }

  /**
   * One `builder` event to the shell (spec §3.6). `turn` groups events into the
   * exchange that produced them, so the editor can collapse a finished turn
   * without the shell having to infer boundaries from the stream.
   */
  private sendBuilder(app: string, turn: number, event: BuilderEvent): void {
    // Text deltas are the bulk of the stream and arrive token by token; logging
    // each one would bury everything else in the host log.
    if (event.event !== "text") {
      this.hostLog(`[ledge-host] builder -> ${app} ${event.event}`);
    }
    // A CONTROL PLANE frame: `builder` lives in spec §3.6, whose envelopes carry
    // `app: ""` and name the app inside the payload. Sending it as a per-app
    // envelope instead type-checks on both sides and decodes on neither — the
    // shell's `guard … else { return }` drops it, so the whole stream vanishes
    // with no error anywhere. Found by decoding a real host frame in a Swift
    // test rather than by reading either implementation.
    this.session?.send("", "builder", { app, turn, ...event });
  }

  chrome(
    app: string,
    request: ChromeRequest,
    ms?: number,
    cls?: NotificationClass,
  ): void {
    // The shell gates this too, and deliberately: two locks on a door that
    // opens onto a permission dialog. Refused here rather than forwarded so the
    // reason lands in the host log, where an app author will look for it.
    if (request === "permissions" && app !== SETTINGS_APP_ID) {
      this.hostLog(`[ledge-host] chrome <- ${app} permissions REFUSED (Settings-only)`);
      return;
    }
    this.hostLog(
      `[ledge-host] chrome <- ${app} ${request}` +
        `${ms === undefined ? "" : ` ${ms}ms`}${cls === undefined ? "" : ` ${cls}`}`,
    );
    // `ms` and `class` ride along only for `peek`; the shell reads what its verb
    // names. `class` on the wire, `cls` in the worker message — see messages.ts.
    this.session?.send(app, "chrome", {
      request,
      ...(ms === undefined ? {} : { ms }),
      ...(cls === undefined ? {} : { class: cls }),
    });
  }

  /**
   * ctx.notify (spec §6). The notification is posted by the **shell**: it is the
   * bundle notification authorization belongs to, and the only side that can
   * put action buttons on a banner. The host's old `osascript` interim is gone —
   * an unbundled shell falls back to it there, where the fact can be detected
   * (see shell/README.md), rather than here where it can only be assumed.
   *
   * `attention` is unchanged: the notch glow is a separate §3.3 chrome request,
   * so a notification with a glow is still two envelopes and either can arrive
   * on its own.
   */
  notify(app: string, notification: NotifyRequest): void {
    const { attention, ...payload } = notification;
    if (!this.session) {
      this.hostLog(`[ledge-host] notify from '${app}' dropped (no shell connected)`);
    } else {
      this.hostLog(`[ledge-host] notify -> ${app} #${payload.id}`);
      this.session.send(app, "notify", { ...payload });
    }
    if (attention) this.session?.send(app, "chrome", { request: "attention" });
  }

  attention(app: string): void {
    this.session?.send(app, "chrome", { request: "attention" });
  }

  /** ctx.apple (spec §6): shipped to the shell, which owns the TCC prompt. */
  apple(app: string, id: number, request: AppleRequest): void {
    this.sendBridge(app, id, "apple", "apple", { id, ...request }, this.appleTimeoutMs);
  }

  /** ctx.capture (spec §6 extension): the shell owns the Screen Recording
   * permission, and the temp file it writes. */
  capture(app: string, id: number, request: CaptureRequest): void {
    this.sendBridge(app, id, "capture", "capture", { id, ...request }, this.captureTimeoutMs);
  }

  /**
   * ctx.agent (spec §8): one headless turn of the user's own agent CLI, run by
   * the **host** in the app's folder. Never the shell — no TCC prompt, no
   * pixels, nothing the shell is for.
   *
   * Serialized per app, rejected (not queued) while busy: every turn spends the
   * user's tokens, so an app whose monitor calls faster than the agent answers
   * should learn that immediately rather than accumulate a backlog it will
   * still be working through an hour later. The reply is always `ok: true` at
   * the bridge level — failure lives inside the AgentResult, because a monitor
   * that throws is an app crash (spec §6 rule 2).
   */
  agent(app: string, id: number, request: AgentRequest): void {
    const supervisor = this.supervisors.get(app);
    if (!supervisor) return;
    if (this.agentBusy.has(app)) {
      supervisor.post({
        type: "reply",
        id,
        ok: true,
        value: { ok: false, error: "agent busy: this app already has a turn in flight" },
      });
      return;
    }
    this.agentBusy.add(app);
    this.hostLog(`[ledge-host] agent turn <- ${app} #${id}`);
    void this.agentRunner
      .run(supervisor.directory, request)
      .catch((error: unknown) => ({ ok: false, error: String(error) }))
      .then((result) => {
        this.agentBusy.delete(app);
        this.hostLog(`[ledge-host] agent turn -> ${app} #${id} ${result.ok ? "ok" : `failed: ${result.error}`}`);
        // `supervisors.get` again: the worker may have been replaced while the
        // turn ran, and posting to the dead one would be posting into a void.
        this.supervisors.get(app)?.post({ type: "reply", id, ok: true, value: result });
      });
  }

  /**
   * ctx.platform.* (spec §8, §6 extension).
   *
   * Everything except the app-management calls goes to the shell, for one
   * reason repeated in six shapes: each of these is either a per-*process*
   * registration (the notification daemon, NSWorkspace, CoreAudio, the network
   * path monitor) or a TCC-gated framework whose consent prompt macOS attributes
   * to the process with the UI. A Bun worker is a faceless thread; the shell is
   * the process with the icon. Same reasoning as `ctx.apple`, and it is why the
   * host does not try to answer any of them itself.
   *
   * The app-management calls go the other way and are answered HERE, by the
   * host, for the mirror-image reason: enabling an app means starting a worker
   * and re-publishing the catalog, and disabling one means killing a worker.
   * Both are the host's own state; the shell has no part in either and could
   * only forward the answer back. They are also refused for anyone but Settings
   * — the ctx surface already hides them from ordinary apps (worker/ctx.ts), so
   * this is the second lock on the same door rather than the only one.
   */
  platform(app: string, id: number, request: PlatformRequest): void {
    // One gate for the whole Settings-only family, before the routing split:
    // `quit` is executed by the shell and the other four by the host, but who
    // may ask is the same question for all of them.
    if (SETTINGS_ONLY_CALLS.has(request.kind) && app !== SETTINGS_APP_ID) {
      this.supervisors.get(app)?.post({
        type: "reply",
        id,
        ok: false,
        error: `ctx.platform.${request.kind} is Settings-only`,
      });
      return;
    }
    switch (request.kind) {
      case "enable":
      case "disable":
      case "stats":
        this.appManagement(app, id, request);
        return;
      default:
        break;
    }
    const payload = platformWirePayload(id, request);
    if (payload) {
      this.sendBridge(app, id, "platform", "platform", payload, this.platformTimeout(request));
      return;
    }
    this.supervisors.get(app)?.post({
      type: "reply",
      id,
      ok: false,
      error: "ctx.platform bridge is not implemented in this phase",
    });
  }

  /**
   * The Settings-only half of `ctx.platform` (spec §8), answered host-side.
   *
   * `stats` hands back the same rows `catalog` carries, so the panel the user is
   * looking at and the strip beneath it are two renderings of one snapshot — not
   * two lists that agree until they don't.
   */
  private appManagement(
    app: string,
    id: number,
    request: Extract<PlatformRequest, { kind: "enable" | "disable" | "stats" }>,
  ): void {
    const reply = (result: HostToWorker): void => {
      // Re-fetch: the enable path awaits a worker spawn, and the app that asked
      // may have been replaced in the meantime (spec §6 rule 3).
      this.supervisors.get(app)?.post(result);
    };
    if (!this.supervisors.has(app)) return;
    if (request.kind === "stats") {
      reply({ type: "reply", id, ok: true, value: { apps: this.catalogSnapshot() } });
      return;
    }
    const enabled = request.kind === "enable";
    this.hostLog(`[ledge-host] ${request.kind} '${request.app}' <- settings`);
    void this.setAppEnabled(request.app, enabled).then(
      () => reply({ type: "reply", id, ok: true, value: undefined }),
      // The message, not `String(error)`: the worker wraps whatever arrives in
      // a fresh Error, so passing the stringified one through gives the app an
      // "Error: Error: …" to print.
      (error: unknown) =>
        reply({
          type: "reply",
          id,
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        }),
    );
  }

  /**
   * Turn an app on or off: persist it, then make the running system match.
   *
   * Persist FIRST, so a host that dies here comes back to what the user asked
   * for rather than to what it managed to do. Then the worker, then the catalog:
   * a disabled app's worker is gone before the shell is told it is gone, so the
   * shell can never receive a commit for a row it has just dropped.
   */
  private async setAppEnabled(appId: string, enabled: boolean): Promise<void> {
    const entry = this.catalogApps.find((candidate) => candidate.id === appId);
    if (!entry) throw new Error(`no app named '${appId}' is installed`);
    await this.settings.setEnabled(appId, enabled);
    if (entry.enabled === enabled) return;
    entry.enabled = enabled;

    if (enabled) {
      if (!this.supervisors.has(appId)) {
        const supervisor = this.makeSupervisor(appId);
        this.supervisors.set(appId, supervisor);
        await supervisor.start();
      }
    } else {
      const supervisor = this.supervisors.get(appId);
      this.supervisors.delete(appId);
      // `stop()` reports `stopped` (spec §3.2), which is what tells the shell to
      // drop this app's shadow tree. The app's own `meta` is deliberately kept:
      // a disabled row should still show the name and icon the app declared,
      // and a stopped worker will never declare it again.
      supervisor?.stop();
    }

    this.sendCatalog();
    // The watcher only holds handles for enabled apps, so a re-enabled app has
    // to be re-armed or it silently stops hot-reloading.
    this.ensureWatcher(this.catalogApps.filter((candidate) => candidate.enabled).map((c) => c.id));
  }

  lifecycle(app: string, state: AppState, error?: TranspileError): void {
    this.hostLog(`[ledge-host] app '${app}' -> ${state}`);
    // A wing belongs to a live worker. Every lifecycle transition replaces or
    // ends that worker (started = a backoff respawn, reloaded = a hot reload,
    // crashed/stopped = gone), so the wing it was holding is released here — the
    // fresh worker re-declares one if it still wants the notch. This runs before
    // the lifecycle envelope so the shell never sees a wing outlive its app.
    this.releaseWing(app);
    // Same reasoning for in-flight capability requests: the worker awaiting
    // them no longer exists (spec §6 rule 3).
    this.clearPending(app);
    const payload: Record<string, unknown> = { state };
    if (error) payload.error = { message: error.message, stack: error.stack };
    this.session?.send(app, "app", payload);
  }

  log(app: string, line: string): void {
    this.hostLog(`[ledge-host] [${app}] ${line}`);
  }

  // MARK: - Helpers

  /** How long the host waits for the shell to settle one platform call. Most of
   * them bound themselves shell-side (spotlight 5 s, location 8 s), so the
   * default only ever fires when the shell has stopped answering at all. */
  private platformTimeout(request: PlatformRequest): number {
    switch (request.kind) {
      case "calendar":
      case "location":
      // The microphone prompt blocks the start call until the user answers it,
      // so this deadline is a person's reading speed, not the shell's.
      case "recordStart":
        return this.platformGrantTimeoutMs;
      case "speak":
        return this.platformSpeakTimeoutMs;
      default:
        return this.platformTimeoutMs;
    }
  }

  private makeSupervisor(appId: string): AppSupervisor {
    return new AppSupervisor({
      appId,
      appDir: join(this.appsRoot, appId),
      // The apps root, not the app folder: node resolution walks up from here to
      // the shared node_modules, which is exactly the copy the app's own
      // `import "react"` finds (render/runtime.ts).
      modulesRoot: this.appsRoot,
      // Resolved ONCE, on this thread, and handed down: a worker that resolves
      // `react` itself walks node_modules through a process-global cache, and
      // several workers doing that at once segfaults Bun (see ReactPaths).
      // Lazy and cached, because a host with no apps installed should not fail
      // to start over a react it never needed.
      reactPaths: this.reactPathsOnce(),
      // The one special case in the whole host (spec §8): the privileged id
      // gets the app-management half of ctx.platform. Keyed on the folder name,
      // which IS the app id (§2, §6) — there is nothing else to key it on. No
      // shipped app claims it any more (see SETTINGS_APP_ID); this is what an
      // app installed under that name would be granted.
      privileged: appId === SETTINGS_APP_ID,
      sink: this,
      factory: this.factory,
      scheduler: this.scheduler,
      transpile: this.transpile,
      backoff: this.backoff,
    });
  }

  /**
   * Send one capability request to the shell and remember it until the matching
   * result comes back — or until the deadline, whichever is first.
   *
   * With no shell connected there is nothing to execute the request, so the app
   * is told immediately: a Promise that hangs until the user happens to launch
   * the shell is worse than an error it can catch.
   */
  private sendBridge(
    app: string,
    id: number,
    what: string,
    type: string,
    payload: Record<string, unknown>,
    timeoutMs: number,
  ): void {
    const supervisor = this.supervisors.get(app);
    if (!supervisor) return;
    if (!this.session) {
      this.hostLog(`[ledge-host] ${what} #${id} for '${app}' answered locally (no shell connected)`);
      supervisor.post({ type: "reply", id, ok: false, error: `ctx.${what}: the shell is not connected` });
      return;
    }
    const key = bridgeKey(app, id);
    const timer = setTimeout(() => {
      // Forget it first: a result arriving after this must be dropped, not
      // delivered to a Promise the app has already seen rejected.
      this.pending.delete(key);
      this.hostLog(`[ledge-host] ${what} #${id} for '${app}' timed out after ${timeoutMs} ms`);
      this.supervisors
        .get(app)
        ?.post({ type: "reply", id, ok: false, error: `ctx.${what} timed out after ${timeoutMs} ms` });
    }, timeoutMs);
    this.pending.set(key, { app, id, what, cancelTimeout: () => clearTimeout(timer) });
    this.session.send(app, type, payload);
  }

  /** Deliver a shell result to the worker that asked, if it is still waiting. */
  private settleBridge(app: string, id: number, reply: HostToWorker): void {
    const key = bridgeKey(app, id);
    const entry = this.pending.get(key);
    if (!entry) {
      // Late (timed out) or foreign (a worker replaced since) — dropped by
      // design; the app has already been told how this ended.
      this.hostLog(`[ledge-host] dropping unmatched result for '${app}' #${id}`);
      return;
    }
    this.pending.delete(key);
    entry.cancelTimeout();
    this.supervisors.get(app)?.post(reply);
  }

  /** Forget every capability request for one app. Called on each lifecycle
   * transition: the worker that asked is gone, and its request ids restart at 1
   * in the fresh one, so keeping the entries would misroute the next app's
   * results (spec §6 rule 3 — nothing lands after death). */
  private clearPending(app: string): void {
    for (const [key, entry] of this.pending) {
      if (entry.app !== app) continue;
      entry.cancelTimeout();
      this.pending.delete(key);
    }
    this.agentBusy.delete(app);
  }

  /** Release `app`'s wing if it holds one, telling the shell so the collapsed
   * notch can fall back to the idle pill. */
  private releaseWing(app: string): void {
    if (!this.wings.delete(app)) return;
    this.session?.send(app, "chrome", { request: "wing", wing: null });
  }

  /** The full catalog snapshot (spec §3.6): the registry scan with each app's
   * declared `meta` merged over it. Enabled apps are (about to be) running;
   * reflect that in the snapshot. */
  private catalogSnapshot(): CatalogApp[] {
    return this.catalogApps.map((app) => ({
      ...applyMeta(app, this.appMeta.get(app.id)),
      running: app.enabled,
    }));
  }

  /** Publish it. Full snapshots, no diffs — spec §3.6. */
  private sendCatalog(): void {
    const catalog = this.catalogSnapshot();
    this.hostLog(`[ledge-host] catalog -> ${catalog.length} apps`);
    this.session?.send("", "catalog", { apps: catalog });
  }

  private ensureWatcher(appIds: string[]): void {
    if (!this.watchEnabled) return;
    this.closeWatcher?.();
    this.closeWatcher = watchApps({
      appsRoot: this.appsRoot,
      apps: appIds,
      onReload: (appId) => {
        this.hostLog(`[ledge-host] source changed -> reloading '${appId}'`);
        this.reloadApp(appId);
      },
      onAppsChanged: () => {
        void this.rescanApps();
      },
      onError: (appId, error) => this.hostLog(`[ledge-host] watch '${appId}' failed: ${String(error)}`),
    });
  }

  /**
   * Re-scan the apps root and reconcile: start workers for apps that appeared,
   * stop workers for apps that are gone, re-publish the catalog if the set
   * changed, and re-arm the watcher over the new id list.
   *
   * The registry used to be read exactly once, at `bindSession`, which made "the
   * app you just created is invisible until you restart the host" a permanent
   * fact of the system. That is survivable when apps are hand-written; it is not
   * survivable when an agent scaffolds one and then wants to show you.
   *
   * Diffing rather than blindly re-publishing matters because the watcher fires
   * on *any* root-level activity — including writes inside an app's own folder —
   * so most calls here find nothing changed and must do nothing at all.
   */
  private async rescanApps(): Promise<void> {
    if (!this.session) return;

    let apps: CatalogApp[];
    try {
      apps = await scanApps(this.appsRoot, this.settings.disabled);
    } catch (error) {
      this.hostLog(`[ledge-host] rescan failed: ${String(error)}`);
      return;
    }

    const before = new Set(this.catalogApps.map((app) => app.id));
    const after = new Set(apps.map((app) => app.id));
    const added = apps.filter((app) => !before.has(app.id));
    const removed = [...before].filter((id) => !after.has(id));
    if (added.length === 0 && removed.length === 0) return;

    // The scan is the fallback identity (dirname + placeholder icon); a started
    // worker replaces it via `meta`, exactly as at bind time. Merging the
    // previous catalog's meta forward keeps existing apps from flickering back
    // to their placeholder name for the moment between rescan and re-publish.
    const previous = new Map(this.catalogApps.map((app) => [app.id, app]));
    this.catalogApps = apps.map((app) => previous.get(app.id) ?? app);

    for (const app of removed) {
      this.hostLog(`[ledge-host] app '${app}' removed`);
      const supervisor = this.supervisors.get(app);
      this.supervisors.delete(app);
      supervisor?.stop();
    }

    this.sendCatalog();

    for (const app of added) {
      if (!app.enabled) continue;
      this.hostLog(`[ledge-host] app '${app.id}' appeared -> starting`);
      const supervisor = this.makeSupervisor(app.id);
      this.supervisors.set(app.id, supervisor);
      await supervisor.start();
    }

    // Re-arm over the new id set: the previous watcher has no handle on a folder
    // that did not exist when it was created.
    this.ensureWatcher(this.catalogApps.filter((app) => app.enabled).map((app) => app.id));
  }
}

/**
 * The one app id the host boots privileged (spec §8), and the only one the
 * management calls below will answer for.
 *
 * Nothing claims it today: Settings is a native macOS window in the shell, and
 * the app that used to hold this id is kept, unloaded, in
 * `protocol/demo-apps-archive/settings-app` as the worked example of the
 * privileged surface. The gate stays anyway, because the alternative to a gate
 * that currently matches nothing is app management reachable by *any* app, and
 * an apps root is a folder a user can drop anything into.
 */
const SETTINGS_APP_ID = "settings";

/** The calls only the privileged app may make (spec §8). Four are answered by
 * the host because they are its own state; `quit` goes to the shell because
 * only the shell can end the process — but "who may ask" is one question, so it
 * is asked in one place. */
const SETTINGS_ONLY_CALLS: ReadonlySet<PlatformRequest["kind"]> = new Set([
  "enable",
  "disable",
  "reorder",
  "stats",
  "quit",
]);

/** Capability requests are identified by (app, id): worker request ids restart
 * at 1 in every worker, so two apps routinely have a request 1 in flight. */
function bridgeKey(app: string, id: number): string {
  return `${app}#${id}`;
}

/**
 * The `platform` envelope payload for one worker request, or null for the calls
 * the shell has no business seeing — today just `reorder`, which is the last of
 * the Settings-only four still unimplemented (the other three are answered on
 * the host thread, above).
 *
 * `call` is the verb and `kind` is the *source* being watched — two axes, which
 * is why the worker's own discriminant (`request.kind`) is not what goes on the
 * wire. Each call contributes only the fields it needs; the shell reads the ones
 * its verb names and ignores the rest, so a new call is a new `call` value
 * rather than a new envelope type.
 */
function platformWirePayload(
  id: number,
  request: PlatformRequest,
): Record<string, unknown> | null {
  switch (request.kind) {
    case "observe":
    case "unobserve":
      return { id, call: request.kind, kind: request.source, name: request.name };
    case "calendar":
      return {
        id,
        call: "calendar",
        ...(request.from === undefined ? {} : { from: request.from }),
        ...(request.to === undefined ? {} : { to: request.to }),
      };
    case "workspace":
    case "location":
    case "audio":
    // `quit` takes no fields — the verb is the whole request.
    case "quit":
    // Nor do three of the four recording calls: which session they mean is the
    // shell's own state (there is only ever one), not something the app names.
    case "recordStatus":
    case "recordStop":
    case "recordLevels":
      return { id, call: request.kind };
    case "recordStart":
      return {
        id,
        call: "recordStart",
        ...(request.sources === undefined ? {} : { sources: request.sources }),
        ...(request.format === undefined ? {} : { format: request.format }),
      };
    case "spotlight":
      return {
        id,
        call: "spotlight",
        query: request.query,
        ...(request.scopes === undefined ? {} : { scopes: request.scopes }),
      };
    case "setVolume":
      return { id, call: "setVolume", value: request.value };
    case "speak":
      return {
        id,
        call: "speak",
        text: request.text,
        ...(request.voice === undefined ? {} : { voice: request.voice }),
        ...(request.rate === undefined ? {} : { rate: request.rate }),
      };
    default:
      return null;
  }
}
