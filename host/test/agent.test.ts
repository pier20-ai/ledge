import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  AgentRunner,
  buildPrompt,
  extractText,
  parseCommand,
  stripFences,
} from "../src/agent";

// `ctx.agent` (spec §8) end to end against a FAKE agent CLI reached through
// LEDGE_AGENT_CMD. Nothing here runs a real agent: Ledge never calls a model
// API, and a test suite that spent the user's tokens would be a poor way to
// demonstrate that.

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const FAKE_AGENT = join(TEST_DIR, "fixtures", "fake-agent.ts");
const FAKE_COMMAND = ["bun", FAKE_AGENT];

let dirs: string[] = [];

async function workDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "ledge-agent-"));
  dirs.push(dir);
  return dir;
}

/** Set env for one run and restore it, so tests never leak into each other. */
async function withEnv<T>(vars: Record<string, string>, body: () => Promise<T>): Promise<T> {
  const previous = new Map(Object.keys(vars).map((key) => [key, process.env[key]]));
  Object.assign(process.env, vars);
  try {
    return await body();
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

afterEach(async () => {
  for (const dir of dirs) await rm(dir, { recursive: true, force: true });
  dirs = [];
});

describe("adapter plumbing", () => {
  test("LEDGE_AGENT_CMD overrides detection, and {prompt} is substituted in place", () => {
    const runner = new AgentRunner({ env: { LEDGE_AGENT_CMD: 'my-agent --json "{prompt}"' } });
    expect(runner.resolveCommand()).toEqual(["my-agent", "--json", "{prompt}"]);
  });

  test("with no override, `claude` on PATH is the adapter — and its absence is an error, not a crash", () => {
    const withClaude = new AgentRunner({ env: {}, which: () => "/usr/local/bin/claude" });
    expect(withClaude.resolveCommand()).toEqual([
      "claude",
      "-p",
      "{prompt}",
      "--output-format",
      "json",
    ]);
    const without = new AgentRunner({ env: {}, which: () => null });
    expect(without.resolveCommand()).toBeNull();
  });

  test("no agent installed resolves to ok:false rather than throwing", async () => {
    const runner = new AgentRunner({ env: {}, which: () => null });
    const result = await runner.run(await workDir(), { prompt: "hi" });
    expect(result.ok).toBe(false);
    expect(result.error).toContain("no agent CLI found");
  });

  test("parseCommand groups quoted arguments and never invokes a shell", () => {
    expect(parseCommand(`bun "/tmp/my agent.ts" --flag`)).toEqual([
      "bun",
      "/tmp/my agent.ts",
      "--flag",
    ]);
    expect(parseCommand("  spaced   out  ")).toEqual(["spaced", "out"]);
  });

  test("extractText reads claude's json envelope, and plain output verbatim", () => {
    expect(extractText('{"type":"result","result":"forty two"}')).toBe("forty two");
    expect(extractText("just prose\n")).toBe("just prose");
    expect(extractText("")).toBe("");
  });

  test("stripFences unwraps the code fence agents add about half the time", () => {
    expect(stripFences('```json\n{"a":1}\n```')).toBe('{"a":1}');
    expect(stripFences('{"a":1}')).toBe('{"a":1}');
  });

  test("files are named in the prompt, not inlined — the agent reads them itself", () => {
    const prompt = buildPrompt({
      prompt: "what flight is this?",
      files: ["/tmp/pass.pdf", "/tmp/note.txt"],
      schema: { flight: "string" },
    });
    expect(prompt).toContain("what flight is this?");
    expect(prompt).toContain("- /tmp/pass.pdf");
    expect(prompt).toContain('Respond ONLY with JSON matching this schema: {"flight":"string"}');
  });
});

describe("one turn of the user's agent", () => {
  test("a plain turn returns the agent's text", async () => {
    const runner = new AgentRunner({ command: FAKE_COMMAND });
    const result = await runner.run(await workDir(), { prompt: "summarize the log" });
    expect(result).toEqual({ ok: true, text: "echo: summarize the log" });
  });

  test("LEDGE_AGENT_CMD is honoured from the real environment", async () => {
    await withEnv({ LEDGE_AGENT_CMD: `bun ${FAKE_AGENT}`, FAKE_AGENT_REPLY: "from env" }, async () => {
      const runner = new AgentRunner();
      const result = await runner.run(await workDir(), { prompt: "anything" });
      expect(result.text).toBe("from env");
    });
  });

  test("schema: the reply is parsed into `json`, fences and all", async () => {
    await withEnv({ FAKE_AGENT_REPLY: '```json\n{"flight":"BA286","delayed":true}\n```' }, async () => {
      const runner = new AgentRunner({ command: FAKE_COMMAND });
      const result = await runner.run(await workDir(), {
        prompt: "extract the flight",
        schema: { flight: "string", delayed: "boolean" },
      });
      expect(result.ok).toBe(true);
      expect(result.json).toEqual({ flight: "BA286", delayed: true });
    });
  });

  test("schema: an unparseable first reply is retried exactly once, and the retry counts", async () => {
    const dir = await workDir();
    await withEnv(
      { FAKE_AGENT_FLAKY: "1", FAKE_AGENT_REPLY: '{"ok":true}' },
      async () => {
        const runner = new AgentRunner({ command: FAKE_COMMAND });
        const result = await runner.run(dir, { prompt: "extract", schema: { ok: "boolean" } });
        expect(result.json).toEqual({ ok: true });
      },
    );
    // Two invocations, no more: the retry is a one-shot, not a loop.
    expect(await Bun.file(join(dir, ".fake-agent-calls")).text()).toBe("2");
  });

  test("schema: a reply that is never JSON fails with the text kept for the app to log", async () => {
    await withEnv({ FAKE_AGENT_REPLY: "I would rather write you a poem." }, async () => {
      const runner = new AgentRunner({ command: FAKE_COMMAND });
      const result = await runner.run(await workDir(), { prompt: "extract", schema: {} });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("agent reply was not valid JSON");
      expect(result.text).toBe("I would rather write you a poem.");
    });
  });

  test("a nonzero exit surfaces the CLI's own message", async () => {
    await withEnv({ FAKE_AGENT_EXIT: "2", FAKE_AGENT_REPLY: "auth expired" }, async () => {
      const runner = new AgentRunner({ command: FAKE_COMMAND });
      const result = await runner.run(await workDir(), { prompt: "hi" });
      expect(result).toEqual({ ok: false, error: "auth expired" });
    });
  });

  test("a hung agent is killed at the deadline and reported as a timeout", async () => {
    await withEnv({ FAKE_AGENT_HANG_MS: "5000" }, async () => {
      const runner = new AgentRunner({ command: FAKE_COMMAND });
      const result = await runner.run(await workDir(), { prompt: "hi", timeoutMs: 1000 });
      expect(result.ok).toBe(false);
      expect(result.error).toContain("timed out");
    });
  }, 15000);

  test("the turn runs in the app's own folder (spec §8: one app, one folder)", async () => {
    const dir = await workDir();
    await withEnv({ FAKE_AGENT_FLAKY: "1", FAKE_AGENT_REPLY: "x" }, async () => {
      const runner = new AgentRunner({ command: FAKE_COMMAND });
      await runner.run(dir, { prompt: "hi" });
    });
    // The fake writes its counter into cwd; finding it here IS the assertion.
    expect(await Bun.file(join(dir, ".fake-agent-calls")).exists()).toBe(true);
  });
});
