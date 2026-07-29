import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { main } from "../src/cli";

// The `ledge` CLI (spec §8). Its first user is an agent, not a person: `new`
// scaffolds what the builder then edits, and `logs` is how it finds out why the
// thing it wrote stopped working. So the contract worth pinning is that the
// commands are honest about failure and never destroy anything.

let roots: string[] = [];
afterEach(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
});

async function makeRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ledge-cli-"));
  roots.push(root);
  return root;
}

/** Run a command, capturing what it printed. */
async function run(argv: string[]): Promise<{ code: number; out: string; err: string }> {
  const out: string[] = [];
  const err: string[] = [];
  const code = await main(
    argv,
    (line) => out.push(String(line)),
    (line) => err.push(String(line)),
  );
  return { code, out: out.join("\n"), err: err.join("\n") };
}

describe("ledge CLI", () => {
  test("new scaffolds an app that actually renders", async () => {
    const root = await makeRoot();
    const { code } = await run(["new", "flights", "--apps-root", root]);
    expect(code).toBe(0);

    const source = await Bun.file(join(root, "flights", "app.jsx")).text();
    // The scaffold has to satisfy the platform's own hard rules (AGENTS.md), or
    // the first thing an agent sees is a crash it did not cause.
    expect(source).toContain("@jsxImportSource react");
    expect(source).toContain("export default function App");
    expect(source).toContain("export const meta");

    // And it must be a real app to the registry, not just a file on disk.
    const { out } = await run(["status", "--apps-root", root]);
    expect(JSON.parse(out).map((app: { id: string }) => app.id)).toEqual(["flights"]);
  });

  test("new refuses ids that cannot be a directory name", async () => {
    const root = await makeRoot();
    // The id IS the folder name (spec §6) and travels in every envelope, so a
    // path separator here is not a naming quibble.
    for (const bad of ["../escape", "Has Spaces", "UPPER", ""]) {
      const { code } = await run(["new", bad, "--apps-root", root]);
      expect(code).toBe(1);
    }
  });

  test("new never overwrites an existing app", async () => {
    const root = await makeRoot();
    await mkdir(join(root, "flights"), { recursive: true });
    await writeFile(join(root, "flights", "app.jsx"), "// my work\n");

    const { code, err } = await run(["new", "flights", "--apps-root", root]);
    expect(code).toBe(1);
    expect(err).toContain("already exists");
    // The point of the refusal.
    expect(await Bun.file(join(root, "flights", "app.jsx")).text()).toBe("// my work\n");
  });

  test("reload touches the entry point without rewriting it", async () => {
    const root = await makeRoot();
    await mkdir(join(root, "flights"), { recursive: true });
    const entry = join(root, "flights", "app.jsx");
    await writeFile(entry, "// original\n");
    // Backdate so the touch is unambiguous.
    const before = new Date(Date.now() - 60_000);
    await (await import("node:fs/promises")).utimes(entry, before, before);

    const { code } = await run(["reload", "flights", "--apps-root", root]);
    expect(code).toBe(0);

    // The watcher keys on mtime (spec §7) — and the contents are the user's.
    expect((await stat(entry)).mtimeMs).toBeGreaterThan(before.getTime());
    expect(await Bun.file(entry).text()).toBe("// original\n");
  });

  test("reload on a missing app fails rather than creating one", async () => {
    const root = await makeRoot();
    const { code, err } = await run(["reload", "ghost", "--apps-root", root]);
    expect(code).toBe(1);
    expect(err).toContain("no app.jsx");
    expect(await Bun.file(join(root, "ghost", "app.jsx")).exists()).toBe(false);
  });

  test("logs prints the crash, and says so plainly when there is none", async () => {
    const root = await makeRoot();
    await mkdir(join(root, "flights"), { recursive: true });

    const quiet = await run(["logs", "flights", "--apps-root", root]);
    expect(quiet.code).toBe(0);
    // Not an error: "it has printed nothing" is the answer, not a failure — and
    // it says what to do about it, because the reader is usually an agent that
    // just made a change and is trying to find out whether it did anything.
    expect(quiet.out).toContain("has printed nothing");
    expect(quiet.out).toContain("ledge reload flights");

    await writeFile(join(root, "flights", "crash.log"), "# boom\nTypeError: nope\n");
    const loud = await run(["logs", "flights", "--apps-root", root]);
    expect(loud.out).toContain("TypeError: nope");
  });

  test("logs prints what the app printed, crash or no crash", async () => {
    // The failure this exists for: an agent finishes a change, runs `ledge logs`
    // on a perfectly healthy app, is told it has not crashed, and goes hunting
    // through `find` and `ps aux` for output that was being thrown away.
    const root = await makeRoot();
    await mkdir(join(root, "flights"), { recursive: true });
    await writeFile(
      join(root, "flights", "console.log"),
      "--- started ---\nlog: fetched 12 flights\nerror: BA117 has no gate\n",
    );

    const { code, out } = await run(["logs", "flights", "--apps-root", root]);
    expect(code).toBe(0);
    expect(out).toContain("fetched 12 flights");
    expect(out).toContain("BA117 has no gate");
    expect(out).not.toContain("has printed nothing");
  });

  test("logs shows the tail of a long console, and says how much it hid", async () => {
    const root = await makeRoot();
    await mkdir(join(root, "flights"), { recursive: true });
    const lines = Array.from({ length: 500 }, (_, i) => `log: line ${i}`);
    await writeFile(join(root, "flights", "console.log"), `${lines.join("\n")}\n`);

    const { out } = await run(["logs", "flights", "--apps-root", root, "--lines", "5"]);
    expect(out).toContain("line 499");
    expect(out).not.toContain("line 494");
    // Silent truncation would read as "that is all there was".
    expect(out).toContain("495 earlier lines");
  });

  test("logs on an app that does not exist is an error, not an empty answer", async () => {
    const root = await makeRoot();
    const { code, err } = await run(["logs", "ghost", "--apps-root", root]);
    expect(code).toBe(1);
    expect(err).toContain("no app 'ghost'");
  });

  test("an unknown command explains itself and exits nonzero", async () => {
    const { code, err } = await run(["frobnicate"]);
    expect(code).toBe(1);
    expect(err).toContain("unknown command");
    expect(err).toContain("ledge new");
  });
});
