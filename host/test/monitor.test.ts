import { describe, expect, test } from "bun:test";
import { runMonitorLoop, type MonitorClock } from "../src/worker/monitor";

/** A virtual clock: `sleep` advances time instantly and records the request, so
 * the spin floor is observable without waiting real seconds. Tests simulate a
 * monitor call's duration by advancing the clock from inside the monitor fn. */
function fakeClock() {
  let t = 0;
  const sleeps: number[] = [];
  const clock: MonitorClock = {
    now: () => t,
    sleep: async (ms) => {
      sleeps.push(ms);
      t += ms;
    },
  };
  return { clock, sleeps, advance: (ms: number) => (t += ms) };
}

describe("monitor loop", () => {
  test("invokes sequentially, awaiting each return before the next", async () => {
    const { clock } = fakeClock();
    const order: number[] = [];
    let calls = 0;
    let running = false;

    await runMonitorLoop({
      ctx: {},
      clock,
      shouldContinue: () => calls < 3,
      onCrash: () => {},
      monitor: async () => {
        expect(running).toBe(false); // never re-entered while in flight
        running = true;
        order.push(calls);
        await Promise.resolve();
        running = false;
        calls++;
      },
    });

    expect(calls).toBe(3);
    expect(order).toEqual([0, 1, 2]);
  });

  test("spin floor: a sub-1s call sleeps the remainder before the next", async () => {
    const { clock, sleeps, advance } = fakeClock();
    let calls = 0;

    await runMonitorLoop({
      ctx: {},
      clock,
      shouldContinue: () => calls < 3,
      onCrash: () => {},
      monitor: () => {
        calls++;
        advance(300); // the call "took" 300 ms
      },
    });

    expect(sleeps).toEqual([700, 700, 700]); // floor 1000 − 300
  });

  test("a call at/over the floor inserts no sleep", async () => {
    const { clock, sleeps, advance } = fakeClock();
    let calls = 0;

    await runMonitorLoop({
      ctx: {},
      clock,
      shouldContinue: () => calls < 2,
      onCrash: () => {},
      monitor: () => {
        calls++;
        advance(1500); // already past the spin floor
      },
    });

    expect(sleeps).toEqual([]);
  });

  test("a throw reports one crash and stops the loop", async () => {
    const { clock } = fakeClock();
    const crashes: unknown[] = [];
    let calls = 0;
    const boom = new Error("monitor blew up");

    await runMonitorLoop({
      ctx: {},
      clock,
      onCrash: (error) => crashes.push(error),
      monitor: () => {
        calls++;
        if (calls === 2) throw boom;
      },
    });

    expect(calls).toBe(2); // stopped after the throwing call
    expect(crashes).toEqual([boom]); // reported exactly once, with the real error
  });
});
