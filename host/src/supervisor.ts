// Per-app worker supervision (spec §6 rule 2, §7): spawn one worker per app,
// route its messages to the sink, and enforce the crash policy — exponential
// backoff restart (1 s → 2 min, max 5 attempts, counter reset after 10 min
// healthy). Hot reload and per-app resync are a terminate + respawn (a fresh
// worker re-mounts, which IS the fresh full commit). Timing is injectable so
// tests exercise backoff with a fake clock and no real sleeps.

import { join } from "node:path";
import { ConsoleLog } from "./console-log";
import { pathToFileURL } from "node:url";
import type {
  AgentRequest,
  AppMeta,
  AppleRequest,
  CaptureRequest,
  ChromeRequest,
  NotificationClass,
  CrashPhase,
  HostToWorker,
  NotifyRequest,
  PlatformRequest,
  ReactPaths,
  WingSpec,
  WorkerToHost,
} from "./worker/messages";
import type { Mutation } from "./render/mutations";
import {
  realWorkerFactory,
  transpileCheck,
  type TranspileError,
  type WorkerFactory,
  type WorkerHandle,
} from "./worker-factory";

/** The lifecycle states the host reports to the shell (spec §3.2). */
export type AppState = "started" | "reloaded" | "crashed" | "stopped";

/** Injectable clock + timer for backoff, so tests advance time without sleeping. */
export interface RestartScheduler {
  /** Monotonic-enough milliseconds (Date.now in production). */
  now(): number;
  /** Run `cb` after `ms`; returns a cancel function. */
  schedule(ms: number, cb: () => void): () => void;
}

export const realScheduler: RestartScheduler = {
  now: () => Date.now(),
  schedule: (ms, cb) => {
    const timer = setTimeout(cb, ms);
    return () => clearTimeout(timer);
  },
};

/** Restart policy constants (spec §6 rule 2). */
export interface BackoffPolicy {
  minMs: number;
  maxMs: number;
  maxAttempts: number;
  healthyResetMs: number;
}

export const DEFAULT_BACKOFF: BackoffPolicy = {
  minMs: 1_000,
  maxMs: 120_000,
  maxAttempts: 5,
  healthyResetMs: 600_000,
};

/** Where a supervisor sends everything it produces. The router (src/router.ts)
 * implements this, translating to wire envelopes and osascript. */
export interface SupervisorSink {
  /** A React commit batch for this app (spec §3.1). */
  commit(app: string, mutations: Mutation[]): void;
  /** The app's declared `meta`, extracted by its worker at import (spec §6);
   * the router merges it into the catalog snapshot (§3.6). */
  meta(app: string, meta: AppMeta): void;
  /** One imperative canvas frame (spec §3.4). */
  draw(app: string, id: number, ops: unknown[]): void;
  /** ctx.wing — the collapsed-notch surface this app wants, or null (§3.3). */
  wing(app: string, wing: WingSpec | null): void;
  /** ctx.expand/ctx.collapse — a presentation request (spec §3.3). */
  /** `ms` is the peek dwell; absent for every other request. */
  chrome(
    app: string,
    request: ChromeRequest,
    ms?: number,
    cls?: NotificationClass,
  ): void;
  /** ctx.notify (spec §6): a shell-posted notification + optional glow. */
  notify(app: string, notification: NotifyRequest): void;
  /** ctx.attention (spec §6, chrome §3.3): notch glow, no notification. */
  attention(app: string): void;
  /** A ctx.apple.* request awaiting a host reply (matched by id). */
  apple(app: string, id: number, request: AppleRequest): void;
  /** A ctx.capture request awaiting a host reply (matched by id). */
  capture(app: string, id: number, request: CaptureRequest): void;
  /** A ctx.agent turn awaiting a host reply (matched by id). */
  agent(app: string, id: number, request: AgentRequest): void;
  /** A ctx.platform.* request awaiting a host reply (Settings only). */
  platform(app: string, id: number, request: PlatformRequest): void;
  /** App lifecycle envelope (spec §3.2); `error` only on `crashed`. */
  lifecycle(app: string, state: AppState, error?: TranspileError): void;
  /** A line for the app's host-side log (captured console + supervisor notes). */
  log(app: string, line: string): void;
}

export interface AppSupervisorOptions {
  appId: string;
  /** The app's folder (contains app.jsx + crash.log). */
  appDir: string;
  /** Where the worker resolves `react` from — normally the apps root, so the
   * reconciler walks up to the very same node_modules the app does (one React
   * instance, or hooks break; see render/runtime.ts). Defaults to the app's own
   * folder, which resolves identically for a repo checkout. */
  modulesRoot?: string;
  /** Resolved once by the host and handed to every worker (see ReactPaths). */
  reactPaths?: ReactPaths;
  /** Grants ctx.platform — Settings only (spec §8). */
  privileged?: boolean;
  sink: SupervisorSink;
  factory?: WorkerFactory;
  scheduler?: RestartScheduler;
  transpile?: (modulePath: string) => Promise<TranspileError | null>;
  backoff?: Partial<BackoffPolicy>;
  /** How many captured console lines to keep for crash.log (spec §7). */
  consoleRingSize?: number;
}

/**
 * Supervises one app's worker. All state transitions funnel through `spawn`,
 * `killWorker`, and `handleCrash`; stale events from a replaced worker are
 * dropped by identity (`this.worker !== handle`), so a respawn during an
 * in-flight crash can't cross wires.
 */
export class AppSupervisor {
  private readonly appId: string;
  private readonly appDir: string;
  private readonly modulePath: string;
  private readonly modulesRoot: string;
  private readonly reactPaths?: ReactPaths;
  private readonly privileged: boolean;
  private readonly sink: SupervisorSink;
  private readonly factory: WorkerFactory;
  private readonly scheduler: RestartScheduler;
  private readonly transpile: (modulePath: string) => Promise<TranspileError | null>;
  private readonly backoff: BackoffPolicy;
  private readonly consoleRingSize: number;

  private worker: WorkerHandle | null = null;
  private attempts = 0;
  private spawnAt = 0;
  private cancelRestart: (() => void) | null = null;
  private consoleRing: string[] = [];
  /** The same lines, on disk and unbounded by a crash — see console-log.ts. */
  private readonly consoleFile: ConsoleLog;
  /** Set once the app is disabled/removed — no further restarts. */
  private stopped = false;

  constructor(options: AppSupervisorOptions) {
    this.appId = options.appId;
    this.appDir = options.appDir;
    this.modulePath = join(options.appDir, "app.jsx");
    this.modulesRoot = options.modulesRoot ?? options.appDir;
    this.reactPaths = options.reactPaths;
    this.privileged = options.privileged ?? false;
    this.sink = options.sink;
    this.factory = options.factory ?? realWorkerFactory;
    this.scheduler = options.scheduler ?? realScheduler;
    this.transpile = options.transpile ?? transpileCheck;
    this.backoff = { ...DEFAULT_BACKOFF, ...options.backoff };
    this.consoleRingSize = options.consoleRingSize ?? 100;
    this.consoleFile = new ConsoleLog({
      path: join(this.appDir, "console.log"),
      onError: (error) => this.sink.log(this.appId, `could not write console.log: ${String(error)}`),
    });
  }

  /** The app's folder — the working directory for anything run on its behalf
   * (`ctx.agent`'s turn, spec §8: one app, one folder, one session). */
  get directory(): string {
    return this.appDir;
  }

  /** First spawn (spec §3.2 `started`). */
  async start(): Promise<void> {
    await this.spawn("started");
  }

  /** Hot reload (spec §7): terminate + respawn with a fresh mount. A user- or
   * watcher-driven reload is a clean restart, so the crash backoff counter is
   * reset. */
  async reload(): Promise<void> {
    await this.respawn("reloaded", { resetAttempts: true });
  }

  /** Per-app resync (spec §4.3): the shell detected inconsistency; a fresh
   * worker re-mounts, which IS the fresh full commit. Unlike a reload this is
   * not a health event, so the backoff counter is left untouched. */
  async resync(): Promise<void> {
    await this.respawn("reloaded", { resetAttempts: false });
  }

  /** Graceful stop (disable/remove): terminate and report `stopped` (spec §3.2). */
  stop(): void {
    this.stopped = true;
    this.cancelPendingRestart();
    this.killWorker();
    this.sink.lifecycle(this.appId, "stopped");
  }

  /** Forward a host→worker message (events, lifecycle, bridge replies). */
  post(msg: HostToWorker): void {
    this.worker?.post(msg);
  }

  // MARK: - Internals

  private async respawn(state: AppState, opts: { resetAttempts: boolean }): Promise<void> {
    if (this.stopped) return;
    this.cancelPendingRestart();
    this.killWorker();
    if (opts.resetAttempts) this.attempts = 0;
    await this.spawn(state);
  }

  private async spawn(state: AppState): Promise<void> {
    if (this.stopped) return;
    this.consoleRing = []; // crash.log reflects this run's console only
    // The FILE keeps its history and gets a boundary instead: "did my change do
    // anything" is a question about what happened after the reload, and an agent
    // reading the tail needs to see where that was.
    this.consoleFile.mark(`${state} ${new Date().toISOString()}`);

    // Syntax-check first: a parse error is a crash report + crash.log, no spawn.
    const parseError = await this.transpile(this.modulePath);
    if (parseError) {
      await this.handleCrash({ phase: "render", ...parseError });
      return;
    }

    const boot = {
      modulePath: pathToFileURL(this.modulePath).href,
      modulesRoot: this.modulesRoot,
      reactPaths: this.reactPaths,
      privileged: this.privileged,
    };
    const handle = this.factory(boot, {
      onMessage: (msg) => this.onMessage(handle, msg),
      onError: (error) => {
        if (this.worker !== handle) return;
        void this.handleCrash({ phase: "render", message: error.message, stack: error.stack ?? null });
      },
      onExit: (code) => {
        if (this.worker !== handle) return; // we replaced/killed it — expected
        // A mounted worker keeps its message listener alive, so a self-exit is
        // unexpected; a nonzero code is a crash. (Intentional terminations set
        // this.worker = null first, so this guard drops their exit event.)
        if (code !== 0) {
          void this.handleCrash({
            phase: "monitor",
            message: `worker exited with code ${code}`,
            stack: null,
          });
        }
      },
    });
    this.worker = handle;
    this.spawnAt = this.scheduler.now();

    // Emit the lifecycle BEFORE the worker's mount commit can arrive (postMessage
    // is async): the shell resets this app's shadow tree on started/reloaded so
    // the fresh ids-from-1 mount validates instead of colliding (spec §3.1/§3.2).
    this.sink.lifecycle(this.appId, state);
  }

  private onMessage(handle: WorkerHandle, msg: WorkerToHost): void {
    if (this.worker !== handle) return; // stale message from a replaced worker
    switch (msg.type) {
      case "commit":
        this.sink.commit(this.appId, msg.mutations);
        break;
      case "meta":
        this.sink.meta(this.appId, msg.meta);
        break;
      case "draw":
        this.sink.draw(this.appId, msg.id, msg.ops);
        break;
      case "wing":
        this.sink.wing(this.appId, msg.wing);
        break;
      case "chrome":
        this.sink.chrome(this.appId, msg.request, msg.ms, msg.cls);
        break;
      case "notify": {
        const { type: _type, ...notification } = msg;
        this.sink.notify(this.appId, notification);
        break;
      }
      case "attention":
        this.sink.attention(this.appId);
        break;
      case "apple":
        this.sink.apple(this.appId, msg.id, msg.request);
        break;
      case "capture":
        this.sink.capture(this.appId, msg.id, msg.request);
        break;
      case "agent":
        this.sink.agent(this.appId, msg.id, msg.request);
        break;
      case "platform":
        this.sink.platform(this.appId, msg.id, msg.request);
        break;
      case "console": {
        const line = `${msg.level}: ${msg.text}`;
        this.pushConsole(line);
        this.consoleFile.write(line);
        this.sink.log(this.appId, line);
        break;
      }
      case "crash":
        void this.handleCrash({ phase: msg.phase, message: msg.message, stack: msg.stack });
        break;
    }
  }

  private async handleCrash(crash: {
    phase: CrashPhase;
    message: string;
    stack: string | null;
  }): Promise<void> {
    if (this.stopped) return;

    // Terminate first (spec §6 rule 3): kills the in-flight monitor call, timers,
    // and pending bridges so nothing lands after death.
    this.killWorker();
    await this.writeCrashLog(crash);
    this.sink.lifecycle(this.appId, "crashed", { message: crash.message, stack: crash.stack });

    // Reset the attempt counter after a healthy run (spec §6 rule 2).
    if (this.spawnAt > 0 && this.scheduler.now() - this.spawnAt >= this.backoff.healthyResetMs) {
      this.attempts = 0;
    }
    if (this.attempts >= this.backoff.maxAttempts) {
      this.sink.log(
        this.appId,
        `crashed ${this.attempts} times; giving up (spec §6 rule 2 attempt cap)`,
      );
      return;
    }

    const delay = Math.min(this.backoff.minMs * 2 ** this.attempts, this.backoff.maxMs);
    this.attempts += 1;
    this.sink.log(this.appId, `restarting in ${delay} ms (attempt ${this.attempts})`);
    this.cancelRestart = this.scheduler.schedule(delay, () => {
      this.cancelRestart = null;
      // A backoff restart is a fresh start (spec §3.2 `started`).
      void this.spawn("started");
    });
  }

  private async writeCrashLog(crash: {
    phase: CrashPhase;
    message: string;
    stack: string | null;
  }): Promise<void> {
    const lines = [
      `# ${this.appId} crash — ${new Date().toISOString()} (${crash.phase})`,
      crash.message,
      "",
      crash.stack ?? "(no stack)",
      "",
      "recent console output:",
      ...(this.consoleRing.length ? this.consoleRing : ["(none)"]),
      "",
    ];
    try {
      await Bun.write(join(this.appDir, "crash.log"), lines.join("\n"));
    } catch (error) {
      this.sink.log(this.appId, `could not write crash.log: ${String(error)}`);
    }
  }

  private pushConsole(line: string): void {
    this.consoleRing.push(line);
    if (this.consoleRing.length > this.consoleRingSize) {
      this.consoleRing.splice(0, this.consoleRing.length - this.consoleRingSize);
    }
  }

  private killWorker(): void {
    const handle = this.worker;
    this.worker = null; // identity guards now drop all further events from `handle`
    handle?.terminate();
  }

  private cancelPendingRestart(): void {
    this.cancelRestart?.();
    this.cancelRestart = null;
  }
}
