// Worker entry (spec §6, §7): the code that runs inside one app's Bun Worker.
// It imports the (Bun-transpiled) app module, wires its default export into a
// render session whose sink posts commit batches to the host, builds `ctx` for
// the monitor, dispatches inbound host messages, and captures console output.
//
// The worker talks to the host ONLY via postMessage — it never touches the UDS,
// framing, or envelopes (that is the host thread's half). It imports nothing
// from src/protocol or src/connection.
//
// `runWorker` is the testable core (drive it with a fake WorkerIO in-process).
// The bottom of the file auto-runs it under a real Worker via node:worker_threads,
// reading boot config from `workerData`. Importing this module on the main
// thread (e.g. a test importing `runWorker`) does not auto-run.

import { isMainThread, parentPort, workerData } from "node:worker_threads";
import { createAppSession } from "../render/session";
import type { MutationSink } from "../render/mutations";
import { loadReactRuntime, type ReactRuntime } from "../render/runtime";
import { createCtx } from "./ctx";
import { sanitizeAppMeta } from "./meta";
import { runMonitorLoop, type MonitorClock } from "./monitor";
import type {
  ConsoleLevel,
  CrashPhase,
  HostToWorker,
  WorkerBoot,
  WorkerToHost,
} from "./messages";

/** The worker's two-way channel to the host, abstracted so tests can drive it
 * without a real Worker. */
export interface WorkerIO {
  post(msg: WorkerToHost): void;
  onMessage(handler: (msg: HostToWorker) => void): void;
}

export interface RunWorkerOptions {
  /** Injectable clock for the monitor loop (tests); defaults to the real one. */
  clock?: MonitorClock;
}

const CONSOLE_LEVELS: ConsoleLevel[] = ["log", "info", "warn", "error", "debug"];

/** Format console arguments to a single line the way the host stores them
 * (strings verbatim, everything else via Bun.inspect). */
function formatConsole(args: unknown[]): string {
  return args.map((arg) => (typeof arg === "string" ? arg : Bun.inspect(arg))).join(" ");
}

/** Mirror console.* to the host as `console` messages while still writing to the
 * worker's own stdout/stderr. Returns a restore fn (used in tests). */
function captureConsole(post: (msg: WorkerToHost) => void): () => void {
  const originals = new Map<ConsoleLevel, (...args: unknown[]) => void>();
  for (const level of CONSOLE_LEVELS) {
    const original = console[level].bind(console) as (...args: unknown[]) => void;
    originals.set(level, console[level] as (...args: unknown[]) => void);
    console[level] = (...args: unknown[]) => {
      original(...args);
      post({ type: "console", level, text: formatConsole(args) });
    };
  }
  return () => {
    for (const level of CONSOLE_LEVELS) {
      const original = originals.get(level);
      if (original) console[level] = original as typeof console.log;
    }
  };
}

function toCrash(phase: CrashPhase, error: unknown): WorkerToHost {
  const err = error instanceof Error ? error : new Error(String(error));
  return { type: "crash", phase, message: err.message, stack: err.stack ?? null };
}

/**
 * Boot one app worker. Captures console, imports the app module, mounts it into
 * a render session backed by a commit-posting sink, wires ctx + inbound events,
 * and runs the monitor loop (if the app exports one). Render throws before/at
 * mount and inbound-event render throws become `crash` messages (phase
 * "render"); monitor throws become `crash` (phase "monitor").
 *
 * Resolves when the monitor loop stops (crash) or immediately when the app has
 * no monitor — in both cases the inbound listener stays attached so the worker
 * keeps handling events until the host terminates it (spec §6 rule 3).
 */
export async function runWorker(
  io: WorkerIO,
  boot: WorkerBoot,
  options: RunWorkerOptions = {},
): Promise<void> {
  captureConsole(io.post);

  // Before the app module, so a missing/mis-seeded node_modules is reported as
  // this app's crash rather than surfacing later as a null hooks dispatcher.
  let runtime: ReactRuntime;
  try {
    runtime = await loadReactRuntime(boot.modulesRoot, boot.reactPaths);
  } catch (error) {
    io.post(toCrash("render", error));
    return;
  }

  let module: Record<string, unknown>;
  try {
    module = (await import(boot.modulePath)) as Record<string, unknown>;
  } catch (error) {
    // A module that won't import is an app crash (spec §7); nothing to mount.
    io.post(toCrash("render", error));
    return;
  }

  // The app's `export const meta` (spec §6) — extracted here because this is the
  // only process that ever evaluates app code (the host thread must not import
  // an app module). Posted before the mount commit so the catalog carries the
  // app's real name and icon by the time its panel can be shown; sanitized here
  // so a bogus `meta` costs nothing downstream.
  io.post({ type: "meta", meta: sanitizeAppMeta(module.meta) });

  const App = module.default;
  if (typeof App !== "function") {
    io.post(toCrash("render", new Error(`app ${boot.modulePath} has no default export`)));
    return;
  }
  const monitor = module.monitor;
  // Optional export (spec §4.2): apps that pace work by panel phase — a game
  // dropping its frame rate while collapsed — export `onLifecycle(phase, ctx)`.
  const onLifecycle = module.onLifecycle;
  // Optional export: app-level events (§4.1 with id 0) — a file dropped on the
  // panel, a pressed notification button. They belong to the app rather than to
  // any node in its tree, so there is no prop handler to dispatch them to.
  const onEvent = module.onEvent;

  const sink: MutationSink = {
    commit: (mutations) => io.post({ type: "commit", mutations }),
  };

  let session;
  try {
    session = createAppSession(App as Parameters<typeof createAppSession>[0], sink, runtime);
  } catch (error) {
    // Initial render threw — the tree never mounted (spec §7).
    io.post(toCrash("render", error));
    return;
  }

  const { ctx, settle } = createCtx(
    {
      post: io.post,
      update: (patch) => session.update(patch),
    },
    { privileged: boot.privileged },
  );

  io.onMessage((msg) => {
    switch (msg.type) {
      case "event":
        // A handler may setState → synchronous re-render → commit; a throw
        // there is a render crash (spec §7).
        try {
          if (msg.id === 0) {
            // App-level (see HostToWorker): node ids start at 1, so 0 addresses
            // the app itself. An app without the export ignores these quietly —
            // the same contract `onLifecycle` has.
            if (typeof onEvent === "function") {
              (onEvent as (name: string, data: unknown, ctx: unknown) => void)(
                msg.name,
                msg.data,
                ctx,
              );
            }
          } else {
            session.dispatchEvent(msg.id, msg.name, msg.data);
          }
        } catch (error) {
          io.post(toCrash("render", error));
        }
        break;
      case "lifecycle":
        // The monitor runs regardless (spec §4.2); apps that care about panel
        // phase handle it in their optional onLifecycle export.
        if (typeof onLifecycle === "function") {
          try {
            onLifecycle(msg.phase, ctx);
          } catch (error) {
            io.post(toCrash("render", error));
          }
        }
        break;
      case "reply":
        settle(msg);
        break;
    }
  });

  if (typeof monitor === "function") {
    await runMonitorLoop({
      monitor: monitor as (ctx: unknown) => unknown,
      ctx,
      clock: options.clock,
      onCrash: (error) => io.post(toCrash("monitor", error)),
    });
  }
}

// Auto-run under a real Worker (node:worker_threads). isMainThread is false only
// inside a spawned worker, so importing this module on the main thread is inert.
if (!isMainThread && parentPort) {
  const port = parentPort;
  void runWorker(
    {
      post: (msg) => port.postMessage(msg),
      onMessage: (handler) => port.on("message", handler),
    },
    workerData as WorkerBoot,
  );
}
