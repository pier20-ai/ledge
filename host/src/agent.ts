// `ctx.agent` — one headless turn of the USER'S OWN agent CLI (spec §8).
//
// The rule this file exists to honour: **Ledge never calls a model API.** There
// is no key, no SDK, no endpoint here. There is a subprocess — whatever agent
// the user already installed and already pays for — run inside the app's own
// folder, exactly as `AGENTS.md` and the builder chat do it. An adapter is the
// only agent-specific code in Ledge, and this is the smallest possible one: a
// command line, and how to read what came back.
//
// Execution is host-side, not shell-side. The shell owns capabilities that need
// a TCC prompt attributed to a visible process (`ctx.apple`, `ctx.capture`);
// spawning a CLI in a directory is not one of those, and routing it through the
// socket would buy nothing but latency.

import type { AgentRequest, AgentResult } from "./worker/messages";

/** Default per-turn budget. An agent turn is a model call plus tool use; 60 s
 * is roomy for the "classify this" turns apps make and short enough that a
 * wedged CLI never becomes a permanently busy app. */
export const DEFAULT_AGENT_TIMEOUT_MS = 60_000;
const MIN_AGENT_TIMEOUT_MS = 1_000;
const MAX_AGENT_TIMEOUT_MS = 10 * 60_000;

/** The result of running the CLI once. `timedOut` is separate from a nonzero
 * exit because the message an app sees should say which happened. */
export interface AgentRun {
  code: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export interface AgentSpawn {
  (argv: string[], options: { cwd: string; timeoutMs: number }): Promise<AgentRun>;
}

export interface AgentRunnerOptions {
  /** Argv template. `{prompt}` is substituted; without it the prompt is
   * appended as the final argument. Defaults to `LEDGE_AGENT_CMD`, else the
   * detected `claude` invocation. */
  command?: string[];
  /** Overrides `LEDGE_AGENT_CMD` lookup (tests). */
  env?: Record<string, string | undefined>;
  /** PATH lookup, injectable so tests never touch the real CLI. */
  which?: (bin: string) => string | null;
  spawn?: AgentSpawn;
  defaultTimeoutMs?: number;
  log?: (line: string) => void;
}

/** Real subprocess execution with a hard timeout (SIGKILL, then report). */
export const bunSpawn: AgentSpawn = async (argv, { cwd, timeoutMs }) => {
  const [command, ...args] = argv;
  if (!command) return { code: -1, stdout: "", stderr: "empty agent command", timedOut: false };
  const proc = Bun.spawn([command, ...args], {
    cwd,
    // Explicitly, not by default: Bun's implicit environment is a snapshot from
    // process start, so an agent whose credentials (or LEDGE_AGENT_CMD) were set
    // after boot would silently not see them.
    env: process.env,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, timeoutMs);
  try {
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    const code = await proc.exited;
    return { code, stdout, stderr, timedOut };
  } finally {
    clearTimeout(timer);
  }
};

/**
 * Split a command string into argv the way a person means it: whitespace
 * separates, quotes group. Deliberately NOT a shell — no globbing, no
 * substitution, no `&&`. `LEDGE_AGENT_CMD` names a program to run, and giving
 * it shell semantics would turn an env var into an injection surface for
 * nothing anyone needs.
 */
export function parseCommand(command: string): string[] {
  const argv: string[] = [];
  let current = "";
  let quote: '"' | "'" | null = null;
  let started = false;
  for (const char of command) {
    if (quote) {
      if (char === quote) quote = null;
      else current += char;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      started = true;
      continue;
    }
    if (/\s/.test(char)) {
      if (started) argv.push(current);
      current = "";
      started = false;
      continue;
    }
    current += char;
    started = true;
  }
  if (started) argv.push(current);
  return argv;
}

/** Strip the code fence an agent wraps JSON in about half the time. */
export function stripFences(text: string): string {
  const trimmed = text.trim();
  const fenced = /^```(?:json)?\s*\n([\s\S]*?)\n?```$/.exec(trimmed);
  return (fenced?.[1] ?? trimmed).trim();
}

/**
 * Pull the assistant's reply out of whatever the CLI printed. `claude
 * --output-format json` yields an object with a `result` field; a bare script
 * (the test fake, or a user's own wrapper) may just print text. Both are
 * supported, because "the user's own agent" means the shape is not ours to fix.
 */
export function extractText(stdout: string): string {
  const trimmed = stdout.trim();
  if (!trimmed) return "";
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (parsed && typeof parsed === "object") {
      const record = parsed as Record<string, unknown>;
      if (typeof record.result === "string") return record.result;
      if (typeof record.text === "string") return record.text;
    }
  } catch {
    // Not JSON: the CLI printed prose, which is a perfectly good answer.
  }
  return trimmed;
}

export class AgentRunner {
  private readonly options: AgentRunnerOptions;
  private readonly spawn: AgentSpawn;
  private readonly defaultTimeoutMs: number;

  constructor(options: AgentRunnerOptions = {}) {
    this.options = options;
    this.spawn = options.spawn ?? bunSpawn;
    this.defaultTimeoutMs = options.defaultTimeoutMs ?? DEFAULT_AGENT_TIMEOUT_MS;
  }

  /**
   * The argv template for this machine, or null when no agent is installed.
   *
   * 1. `options.command` (tests, explicit configuration).
   * 2. `LEDGE_AGENT_CMD` — a command template; this is also the seam every test
   *    uses, so no test ever invokes a real agent.
   * 3. `claude` on PATH → `claude -p <prompt> --output-format json`.
   */
  resolveCommand(): string[] | null {
    if (this.options.command) return this.options.command;
    const env = this.options.env ?? (process.env as Record<string, string | undefined>);
    const configured = env.LEDGE_AGENT_CMD?.trim();
    if (configured) {
      const argv = parseCommand(configured);
      if (argv.length > 0) return argv;
    }
    const which = this.options.which ?? ((bin: string) => Bun.which(bin));
    if (which("claude")) return ["claude", "-p", "{prompt}", "--output-format", "json"];
    return null;
  }

  /** Run one turn in `cwd` (the app's own folder — the agent's working set is
   * the app, which is what makes the notch chat and `ctx.agent` the same idea). */
  async run(cwd: string, request: AgentRequest): Promise<AgentResult> {
    const argv = this.resolveCommand();
    if (!argv) {
      return {
        ok: false,
        error:
          "no agent CLI found — install `claude` (or set LEDGE_AGENT_CMD). Ledge runs your agent; it never calls a model API itself.",
      };
    }
    const timeoutMs = clampTimeout(request.timeoutMs ?? this.defaultTimeoutMs);
    const basePrompt = buildPrompt(request);

    const first = await this.turn(argv, cwd, basePrompt, timeoutMs);
    if (!first.ok || request.schema === undefined) return first;

    const parsed = tryParse(first.text ?? "");
    if (parsed.ok) return { ...first, json: parsed.value };

    // One retry, and only one: the failure mode this fixes is an agent that
    // prefaced its JSON with a sentence. An agent that cannot follow the schema
    // twice will not follow it a third time, and every attempt costs the user.
    this.options.log?.("[ledge-host] agent reply was not JSON — retrying once");
    const retry = await this.turn(
      argv,
      cwd,
      `${basePrompt}\n\nYour previous reply could not be parsed as JSON. Reply with the raw JSON object only — no prose, no code fences.`,
      timeoutMs,
    );
    if (!retry.ok) return retry;
    const second = tryParse(retry.text ?? "");
    return second.ok
      ? { ...retry, json: second.value }
      : { ok: false, text: retry.text, error: "agent reply was not valid JSON" };
  }

  private async turn(
    argv: string[],
    cwd: string,
    prompt: string,
    timeoutMs: number,
  ): Promise<AgentResult> {
    const hasPlaceholder = argv.some((arg) => arg.includes("{prompt}"));
    const resolved = hasPlaceholder
      ? argv.map((arg) => arg.replaceAll("{prompt}", prompt))
      : [...argv, prompt];

    let run: AgentRun;
    try {
      run = await this.spawn(resolved, { cwd, timeoutMs });
    } catch (error) {
      return { ok: false, error: `could not run the agent: ${String(error)}` };
    }
    if (run.timedOut) return { ok: false, error: `agent turn timed out after ${timeoutMs} ms` };
    if (run.code !== 0) {
      const detail = run.stderr.trim() || run.stdout.trim();
      return { ok: false, error: detail || `agent exited with code ${run.code}` };
    }
    return { ok: true, text: extractText(run.stdout) };
  }
}

function clampTimeout(ms: number): number {
  if (!Number.isFinite(ms)) return DEFAULT_AGENT_TIMEOUT_MS;
  return Math.min(Math.max(ms, MIN_AGENT_TIMEOUT_MS), MAX_AGENT_TIMEOUT_MS);
}

/**
 * The prompt as the agent sees it: the app's text, then the files it should
 * read, then the schema it must answer in. Files are named, not inlined — the
 * agent has file tools and a large context is not free; naming a path lets it
 * read only what it needs (and read a 40 MB PDF at all).
 */
export function buildPrompt(request: AgentRequest): string {
  const parts = [request.prompt];
  if (request.files && request.files.length > 0) {
    parts.push(`Files to read:\n${request.files.map((file) => `- ${file}`).join("\n")}`);
  }
  if (request.schema !== undefined) {
    parts.push(
      `Respond ONLY with JSON matching this schema: ${JSON.stringify(request.schema)}`,
    );
  }
  return parts.join("\n\n");
}

function tryParse(text: string): { ok: true; value: unknown } | { ok: false } {
  const source = stripFences(text);
  if (!source) return { ok: false };
  try {
    return { ok: true, value: JSON.parse(source) };
  } catch {
    return { ok: false };
  }
}
