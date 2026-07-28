// Worker spawning + the pre-spawn transpile check (spec §6, §7). The supervisor
// (src/supervisor.ts) uses these seams; both are injectable so tests can drive a
// fake worker with no real thread and assert crash/backoff behaviour deterministically.

import { Worker } from "node:worker_threads";
import type { HostToWorker, WorkerBoot, WorkerToHost } from "./worker/messages";

/** A spawned app worker, abstracted so the supervisor never touches
 * node:worker_threads directly (and tests can substitute a fake). */
export interface WorkerHandle {
  /** Send a host→worker message (spec §4). */
  post(msg: HostToWorker): void;
  /** Terminate the worker — cancels the in-flight monitor call, timers, and
   * pending bridges at once (spec §6 rule 3). */
  terminate(): void;
}

/** The three events the supervisor cares about from a worker. */
export interface WorkerHooks {
  onMessage(msg: WorkerToHost): void;
  onError(error: Error): void;
  onExit(code: number): void;
}

export type WorkerFactory = (boot: WorkerBoot, hooks: WorkerHooks) => WorkerHandle;

/** True when running inside a `bun build --compile` binary (modules live in the
 * virtual `$bunfs` filesystem rather than on disk). */
const isCompiled = import.meta.url.includes("/$bunfs/");

/**
 * The worker entrypoint (see src/worker-entry.ts for the full why). Compiled
 * binaries embed extra entrypoints at the bundle root **as .js**; on disk the
 * source is .ts. Same basename either way, so only the extension moves.
 */
const entryUrl = new URL(`./worker-entry.${isCompiled ? "js" : "ts"}`, import.meta.url);

/** The production factory: a real Bun Worker over node:worker_threads booting
 * `src/worker/entry.ts` with `boot` as `workerData` (matches worker.test.ts). */
export const realWorkerFactory: WorkerFactory = (boot, hooks) => {
  const worker = new Worker(entryUrl, { workerData: boot });
  worker.on("message", (msg: WorkerToHost) => hooks.onMessage(msg));
  worker.on("error", (error: Error) => hooks.onError(error));
  worker.on("exit", (code: number) => hooks.onExit(code));
  return {
    post: (msg) => worker.postMessage(msg),
    terminate: () => void worker.terminate(),
  };
};

/** A transpile/parse failure, shaped like a crash so it flows through the same
 * crash-report + crash.log path (spec §7). */
export interface TranspileError {
  message: string;
  stack: string | null;
}

function toTranspileError(error: unknown): TranspileError {
  const err = error instanceof Error ? error : new Error(String(error));
  return { message: err.message, stack: err.stack ?? null };
}

/**
 * Syntax-check `app.jsx` with `Bun.Transpiler` BEFORE spawning (spec §6, §7).
 * Bun natively transpiles the .jsx on import, but running the transpiler first
 * turns a parse error into a crash report + crash.log without ever starting a
 * worker (an unparseable module would otherwise crash-loop on import). Returns
 * `null` when the file parses, or the error when it does not (including a
 * missing/unreadable file).
 */
export async function transpileCheck(modulePath: string): Promise<TranspileError | null> {
  let source: string;
  try {
    source = await Bun.file(modulePath).text();
  } catch (error) {
    return toTranspileError(error);
  }
  try {
    new Bun.Transpiler({ loader: "jsx" }).transformSync(source);
    return null;
  } catch (error) {
    return toTranspileError(error);
  }
}
