import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConsoleLog, KEEP_BYTES, MAX_BYTES } from "../src/console-log";

// The app-owned `console.log` (src/console-log.ts). Two properties: it must not
// grow without bound, and it must not be able to break the app that is writing
// to it.

let dirs: string[] = [];
afterEach(async () => {
  for (const dir of dirs) await rm(dir, { recursive: true, force: true });
  dirs = [];
});

async function logPath(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "ledge-console-"));
  dirs.push(dir);
  return join(dir, "console.log");
}

describe("console.log on disk", () => {
  test("batched writes arrive in order", async () => {
    const path = await logPath();
    const log = new ConsoleLog({ path, schedule: (fn) => fn() });
    log.mark("started");
    log.write("log: one");
    log.write("log: two");
    await log.flush();

    expect(await readFile(path, "utf8")).toBe("--- started ---\nlog: one\nlog: two\n");
  });

  test("a second run appends rather than replacing the first", async () => {
    const path = await logPath();
    const first = new ConsoleLog({ path, schedule: (fn) => fn() });
    first.write("log: before");
    await first.flush();

    const second = new ConsoleLog({ path, schedule: (fn) => fn() });
    second.mark("reloaded");
    second.write("log: after");
    await second.flush();

    const text = await readFile(path, "utf8");
    expect(text.indexOf("before")).toBeLessThan(text.indexOf("reloaded"));
    expect(text).toContain("log: after");
  });

  test("it stays bounded, and never leaves half a line at the top", async () => {
    const path = await logPath();
    // Start over the cap: a monitor logging every second for a week.
    await writeFile(path, `${"x".repeat(MAX_BYTES)}\nlog: recent\n`);
    const log = new ConsoleLog({ path, schedule: (fn) => fn() });
    log.write("log: newest");
    await log.flush();

    const size = (await stat(path)).size;
    expect(size).toBeLessThanOrEqual(KEEP_BYTES + 64);
    const text = await readFile(path, "utf8");
    expect(text.startsWith("[…earlier output trimmed]\n")).toBe(true);
    // The tail is what anyone reads, so the tail is what survives.
    expect(text).toContain("log: newest");
  });

  test("a write that cannot land is reported, not thrown", async () => {
    // A path through a file: the app kept running, which is the whole point.
    const path = await logPath();
    await writeFile(path.replace("console.log", "blocked"), "not a directory\n");
    const errors: unknown[] = [];
    const log = new ConsoleLog({
      path: join(path.replace("console.log", "blocked"), "console.log"),
      schedule: (fn) => fn(),
      onError: (error) => errors.push(error),
    });
    log.write("log: into the void");
    await log.flush();

    expect(errors).toHaveLength(1);
  });
});
