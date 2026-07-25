// The monitor loop (spec §6, "Monitor lifecycle — deterministic rules"):
//
//   1. Invoke monitor(ctx), AWAIT its return, invoke again. Calls never
//      overlap. Pacing lives inside the app via Bun.sleep; if a call returns in
//      under 1 s, the host inserts the difference before the next call (a spin
//      floor, so a monitor that forgot to sleep can't peg a core).
//   2. A thrown exception is an app crash: report it and STOP the loop. Restart
//      policy (backoff, attempt caps) is the host thread's decision — NOT this
//      loop's; here we just surface the crash and stop cleanly.
//   3. Termination (reload/disable) is worker.terminate() from the host, which
//      cancels the in-flight call, timers, and bridges at once — nothing this
//      loop does.
//
// The clock is injectable so tests exercise the spin floor without sleeping
// real seconds; production passes the real Bun clock.

/** The spin floor (spec §6 rule 1): a monitor call plus its trailing sleep is
 * at least this long. */
export const SPIN_FLOOR_MS = 1000;

export interface MonitorClock {
  /** Monotonic milliseconds. */
  now(): number;
  /** Resolve after `ms`. */
  sleep(ms: number): Promise<void>;
}

/** The real Bun clock: `performance.now()` + `Bun.sleep`. */
export const realClock: MonitorClock = {
  now: () => performance.now(),
  sleep: (ms) => Bun.sleep(ms),
};

export interface MonitorLoopOptions {
  /** The app's `monitor` export. May be sync or async; return value ignored. */
  monitor: (ctx: unknown) => unknown | Promise<unknown>;
  /** The ctx handed to each call. */
  ctx: unknown;
  /** Called once with the thrown value when a call crashes; the loop then stops.
   * The host turns this into an `app:crashed` and decides restart policy. */
  onCrash: (error: unknown) => void;
  /** Injectable clock; defaults to the real Bun clock. */
  clock?: MonitorClock;
  /** Spin floor override (default {@link SPIN_FLOOR_MS}). */
  spinFloorMs?: number;
  /** Checked before every invocation; return false to stop. Defaults to always
   * true (run until crash or worker termination). Tests use it to bound runs. */
  shouldContinue?: () => boolean;
}

/**
 * Runs the monitor loop until a crash (rule 2), a false `shouldContinue`, or —
 * in production — worker termination (rule 3, which kills the whole worker so
 * this promise never resolves). Resolves cleanly on crash/stop.
 */
export async function runMonitorLoop(options: MonitorLoopOptions): Promise<void> {
  const clock = options.clock ?? realClock;
  const floor = options.spinFloorMs ?? SPIN_FLOOR_MS;
  const shouldContinue = options.shouldContinue ?? (() => true);

  while (shouldContinue()) {
    const started = clock.now();
    try {
      // Await the return before the next call — calls never overlap (rule 1).
      await options.monitor(options.ctx);
    } catch (error) {
      // A throw is shared-fate app death (rule 2): surface and stop. The host
      // owns restart; the loop does not retry.
      options.onCrash(error);
      return;
    }
    const elapsed = clock.now() - started;
    if (elapsed < floor) {
      // Spin floor: insert the remainder before the next call (rule 1).
      await clock.sleep(floor - elapsed);
    }
  }
}
