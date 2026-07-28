// A standalone driver for `codex app-server` (spec §8 groundwork).
//
// Deliberately isolated and deliberately a CLI: the builder's hard part is not
// the socket, it is knowing which of ~40 notification types matter and what a
// real conversation actually emits. Learning that inside the shell, behind a
// WebView, with a worker in the middle, is the expensive way. So this drives a
// real Codex from a terminal, prints the **mapped** events, and is thrown at the
// wall until a conversation works.
//
// It prints spec §3.6 `builder` events, not raw JSON-RPC, so lifting this into
// the host is moving `CodexClient` and deleting `main` — the mapping will
// already have been proven against a real model.
//
//   bun scripts/codex-harness.ts <appDir> "<prompt>" [--resume <threadId>] [--raw]
//
// NOTE: this spends the user's own Codex quota. Nothing in `bun test` runs it.

import { resolve } from "node:path";

// ---------------------------------------------------------------- JSON-RPC

type Json = Record<string, unknown>;

interface Pending {
  resolve: (value: Json) => void;
  reject: (error: Error) => void;
}

/**
 * The smallest client that can hold a conversation: initialize, start or resume
 * a thread, run turns, and route notifications. Everything Codex offers beyond
 * that (goals, compaction, plugins, realtime, the fs/* and process/* surfaces)
 * is deliberately absent — the app-server API is ~510 types and Ledge needs
 * about eight of them.
 */
export class CodexClient {
  private readonly proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private readonly pending = new Map<number, Pending>();
  private nextId = 1;
  private buffer = "";

  /** Called for every server→client notification. */
  onNotification: (method: string, params: Json) => void = () => {};
  /** Called for every server→client *request*; the return value is the reply. */
  onRequest: (method: string, params: Json) => Json = () => ({});

  constructor(command = "codex", args = ["app-server"]) {
    this.proc = Bun.spawn([command, ...args], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      // Explicitly, not implicitly: Codex reads ~/.codex/auth.json and the
      // user's own credentials live in the environment they started us with.
      env: process.env,
    }) as Bun.Subprocess<"pipe", "pipe", "pipe">;
    void this.readLoop();
  }

  private async readLoop(): Promise<void> {
    const reader = this.proc.stdout.getReader();
    const decoder = new TextDecoder();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      this.buffer += decoder.decode(value, { stream: true });
      // Newline-delimited JSON: a frame is a line, and a partial line waits.
      let newline: number;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline).trim();
        this.buffer = this.buffer.slice(newline + 1);
        if (line) this.dispatch(line);
      }
    }
    // The child died: fail everything still waiting rather than hang.
    for (const [, entry] of this.pending) entry.reject(new Error("app-server exited"));
    this.pending.clear();
  }

  private dispatch(line: string): void {
    let message: Json;
    try {
      message = JSON.parse(line) as Json;
    } catch {
      // Codex writes human-readable lines to stderr, not stdout; anything here
      // that is not JSON is a protocol violation worth seeing.
      console.error(`[harness] non-JSON on stdout: ${line.slice(0, 200)}`);
      return;
    }

    const id = message.id as number | undefined;
    const method = message.method as string | undefined;

    if (id !== undefined && method === undefined) {
      // A reply to something we sent.
      const entry = this.pending.get(id);
      if (!entry) return;
      this.pending.delete(id);
      if (message.error) {
        const error = message.error as { message?: string };
        entry.reject(new Error(error.message ?? JSON.stringify(message.error)));
      } else {
        entry.resolve((message.result ?? {}) as Json);
      }
      return;
    }

    if (id !== undefined && method !== undefined) {
      // A server→client REQUEST — approvals arrive this way, and one that never
      // gets answered wedges the turn silently.
      const result = this.onRequest(method, (message.params ?? {}) as Json);
      this.write({ jsonrpc: "2.0", id, result });
      return;
    }

    if (method) this.onNotification(method, (message.params ?? {}) as Json);
  }

  private write(message: Json): void {
    this.proc.stdin.write(`${JSON.stringify(message)}\n`);
    this.proc.stdin.flush();
  }

  /** Send a request and await its reply. */
  request(method: string, params: Json = {}): Promise<Json> {
    const id = this.nextId++;
    const promise = new Promise<Json>((res, rej) => this.pending.set(id, { resolve: res, reject: rej }));
    this.write({ jsonrpc: "2.0", id, method, params });
    return promise;
  }

  notify(method: string, params: Json = {}): void {
    this.write({ jsonrpc: "2.0", method, params });
  }

  async initialize(): Promise<Json> {
    const result = await this.request("initialize", {
      clientInfo: { name: "ledge", title: "Ledge", version: "0.4.0" },
      capabilities: null,
    });
    this.notify("initialized", {});
    return result;
  }

  /**
   * A thread rooted in one app's folder.
   *
   * `approvalPolicy: "never"` + `sandbox: "workspace-write"` is the trust model
   * Ledge already has (spec §6: apps are local code the user owns), scoped to
   * the folder the agent is editing. Asking would mean a modal in a notch.
   */
  async startThread(cwd: string): Promise<string> {
    const result = await this.request("thread/start", {
      cwd,
      approvalPolicy: "never",
      sandbox: "workspace-write",
    });
    const thread = result.thread as { id?: string } | undefined;
    const id = thread?.id;
    if (!id) throw new Error(`thread/start returned no thread id: ${JSON.stringify(result)}`);
    return id;
  }

  async resumeThread(threadId: string, cwd: string): Promise<string> {
    const result = await this.request("thread/resume", {
      threadId,
      cwd,
      approvalPolicy: "never",
      sandbox: "workspace-write",
    });
    const thread = result.thread as { id?: string } | undefined;
    return thread?.id ?? threadId;
  }

  startTurn(threadId: string, text: string): Promise<Json> {
    return this.request("turn/start", {
      threadId,
      // `text_elements` is required even when empty — omitting it is a decode
      // error on the far side, with no useful message.
      input: [{ type: "text", text, text_elements: [] }],
    });
  }

  interrupt(threadId: string): void {
    this.notify("turn/interrupt", { threadId });
  }

  async stderr(): Promise<string> {
    return new Response(this.proc.stderr).text();
  }

  kill(): void {
    this.proc.kill();
  }
}

// ------------------------------------------------- notification → builder

/** The spec §3.6 builder event stream, as the shell will receive it. */
export type BuilderEvent =
  | { event: "text"; delta: string }
  | { event: "tool"; name: string; detail: string; state: "started" | "completed" }
  | { event: "status"; text: string }
  | { event: "done" }
  | { event: "error"; message: string };

/**
 * Map one Codex notification to a builder event, or null to ignore it.
 *
 * The ignore list is the point. Codex emits reasoning traces, token counts,
 * plan updates and thread bookkeeping continuously; a builder that forwarded
 * all of it would be a debug log wearing a chat's clothes. Ledge shows what the
 * agent *said* and what it *did*.
 */
export function toBuilderEvent(method: string, params: Json): BuilderEvent | null {
  switch (method) {
    case "item/agentMessage/delta":
      return { event: "text", delta: String(params.delta ?? "") };

    case "item/started":
    case "item/completed": {
      const item = params.item as
        | { type?: string; command?: string; changes?: Array<{ path?: string }> }
        | undefined;
      if (!item) return null;
      const state = method === "item/started" ? "started" : "completed";
      if (item.type === "commandExecution") {
        return { event: "tool", name: "run", detail: String(item.command ?? ""), state };
      }
      if (item.type === "fileChange") {
        // `changes: [{ path, kind }]`, NOT `path` — measured against a real
        // turn, where assuming `item.path` produced a tool chip with no file
        // name on it and nothing to say it was wrong.
        const paths = (item.changes ?? []).map((change) => change.path).filter(Boolean);
        return { event: "tool", name: "edit", detail: paths.join(", "), state };
      }
      // Ignored on purpose: `userMessage` (we sent it), and `reasoning`, which
      // Codex emits around every step. Forwarding those would make the builder
      // a debug log rather than a conversation.
      return null;
    }

    case "turn/completed":
      return { event: "done" };

    case "error":
      return { event: "error", message: String(params.message ?? "unknown error") };

    default:
      return null;
  }
}

// ---------------------------------------------------------------- the CLI

async function main(): Promise<number> {
  const argv = Bun.argv.slice(2);
  const raw = argv.includes("--raw");
  const resumeAt = argv.indexOf("--resume");
  const resumeId = resumeAt >= 0 ? argv[resumeAt + 1] : undefined;
  const positional = argv.filter(
    (arg, index) => !arg.startsWith("--") && argv[index - 1] !== "--resume",
  );
  const [appDir, prompt] = positional;

  if (!appDir || !prompt) {
    console.error(
      'usage: bun scripts/codex-harness.ts <appDir> "<prompt>" [--resume <threadId>] [--raw]',
    );
    return 1;
  }

  const cwd = resolve(appDir);
  const client = new CodexClient();
  let finished = false;

  client.onRequest = (method, params) => {
    // With approvalPolicy "never" these should not arrive. If one does, say so
    // loudly and approve — a silently unanswered request wedges the turn, and
    // guessing quietly would hide a wrong trust model.
    console.error(`[harness] server request: ${method} ${JSON.stringify(params).slice(0, 200)}`);
    return { decision: "approved" };
  };

  client.onNotification = (method, params) => {
    if (raw) console.error(`[raw] ${method} ${JSON.stringify(params).slice(0, 300)}`);
    const event = toBuilderEvent(method, params);
    if (!event) return;
    if (event.event === "text") process.stdout.write(event.delta);
    else console.log(`\n[${event.event}] ${JSON.stringify(event)}`);
    if (event.event === "done") finished = true;
  };

  const info = await client.initialize();
  console.error(`[harness] connected: ${String(info.userAgent ?? "?")}`);

  const threadId = resumeId
    ? await client.resumeThread(resumeId, cwd)
    : await client.startThread(cwd);
  console.error(`[harness] thread ${threadId} in ${cwd}`);
  console.error(`[harness] resume with: --resume ${threadId}\n`);

  process.on("SIGINT", () => {
    console.error("\n[harness] interrupting…");
    client.interrupt(threadId);
    setTimeout(() => process.exit(130), 500);
  });

  await client.startTurn(threadId, prompt);

  // turn/start returns when the turn is accepted, not when it ends; the stream
  // is what says it is over.
  const deadline = Date.now() + 10 * 60_000;
  while (!finished && Date.now() < deadline) await Bun.sleep(50);
  console.log();
  client.kill();
  return finished ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
