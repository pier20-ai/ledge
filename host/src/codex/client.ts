// A minimal JSON-RPC client for `codex app-server` (spec §8).
//
// The app-server surface is ~510 generated types; Ledge needs about eight of
// them. Everything else Codex offers — goals, compaction, plugins, realtime, the
// fs/* and process/* families — is deliberately absent, because an adapter that
// grows to match its counterpart stops being an adapter.
//
// Transport is stdio, newline-delimited JSON. `spawn` is injectable so tests can
// drive a fake app-server and no test ever spends the user's quota.

import { existsSync } from "node:fs";
import { resolve } from "node:path";
import type { Json } from "./events";

/**
 * The directory holding the `ledge` shim, or null when there isn't one.
 *
 * Installed, it sits at `Contents/Resources/ledge`. This file is three levels
 * below that — `Resources/host/src/codex/client.ts` — and the count is checked
 * against the real bundle in the tests, because getting it wrong returns null
 * and the whole thing silently does nothing. In a checkout there is no shim, and
 * the answer is honestly nothing.
 */
export function ledgeBinDir(from = import.meta.dir): string | null {
  const resources = resolve(from, "..", "..", "..");
  return existsSync(resolve(resources, "ledge")) ? resources : null;
}

/**
 * `PATH` for the agent, with `ledge` on it.
 *
 * AGENTS.md tells the agent to run `ledge logs` and `ledge shot` — the only two
 * ways it can see what it just built. In a real transcript it ran `which ledge`
 * and got "ledge not found", because the shim lives inside the .app and nothing
 * puts it on a PATH. Symlinking into /usr/local/bin needs a privilege this app
 * does not have and should not ask for, so the agent's own child process is
 * given the directory instead: it is the process that needs it, and it costs
 * the user nothing.
 */
export function agentPath(env: Record<string, string | undefined>, binDir = ledgeBinDir()): string {
  const current = env.PATH ?? "";
  if (!binDir) return current;
  const already = current.split(":").includes(binDir);
  return already || current === "" ? current || binDir : `${binDir}:${current}`;
}

interface Pending {
  resolve: (value: Json) => void;
  reject: (error: Error) => void;
}

/** The subprocess surface the client needs — injectable for tests. */
export interface CodexProcess {
  write(line: string): void;
  /** Resolves when the process ends. Lines arrive via `onLine`. */
  onLine(handler: (line: string) => void): void;
  onExit(handler: (code: number) => void): void;
  kill(): void;
}

/** Spawn a real `codex app-server`. */
export function spawnCodex(command = "codex"): CodexProcess {
  const proc = Bun.spawn([command, "app-server"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    // Explicitly, not implicitly: Codex reads the user's own ~/.codex/auth.json,
    // and Bun's implicit environment is a snapshot from process start — an agent
    // whose credentials were set after boot would silently not see them.
    env: { ...process.env, PATH: agentPath(process.env) },
  });

  let onLine: (line: string) => void = () => {};
  let buffer = "";
  void (async () => {
    const reader = proc.stdout.getReader();
    const decoder = new TextDecoder();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) onLine(line);
      }
    }
  })();

  return {
    write: (line) => {
      proc.stdin.write(line);
      proc.stdin.flush();
    },
    onLine: (handler) => {
      onLine = handler;
    },
    onExit: (handler) => {
      void proc.exited.then((code) => handler(code));
    },
    kill: () => proc.kill(),
  };
}

export interface CodexClientOptions {
  spawn?: () => CodexProcess;
  log?: (line: string) => void;
}

export class CodexClient {
  private readonly proc: CodexProcess;
  private readonly log: (line: string) => void;
  private readonly pending = new Map<number, Pending>();
  private nextId = 1;
  private exited = false;

  /** Called for every server→client notification. */
  onNotification: (method: string, params: Json) => void = () => {};
  /**
   * Called for every server→client *request*. Approvals arrive this way, and a
   * request that never gets answered wedges the turn silently — so there is a
   * default rather than an optional hook.
   */
  onRequest: (method: string, params: Json) => Json = () => ({ decision: "approved" });

  /** The turn currently running per thread, so it can be interrupted. */
  private readonly activeTurns = new Map<string, string>();

  constructor(options: CodexClientOptions = {}) {
    this.log = options.log ?? (() => {});
    this.proc = (options.spawn ?? (() => spawnCodex()))();
    this.proc.onLine((line) => this.dispatch(line));
    this.proc.onExit((code) => {
      this.exited = true;
      this.log(`[ledge-host] codex app-server exited (${code})`);
      // Fail everything still waiting rather than let an app hang forever.
      for (const [, entry] of this.pending) entry.reject(new Error("codex app-server exited"));
      this.pending.clear();
      this.activeTurns.clear();
    });
  }

  get isRunning(): boolean {
    return !this.exited;
  }

  private dispatch(line: string): void {
    let message: Json;
    try {
      message = JSON.parse(line) as Json;
    } catch {
      // Codex writes prose to stderr, not stdout; anything unparseable here is a
      // protocol violation worth seeing rather than swallowing.
      this.log(`[ledge-host] codex sent non-JSON: ${line.slice(0, 200)}`);
      return;
    }

    const id = message.id as number | undefined;
    const method = message.method as string | undefined;

    if (id !== undefined && method === undefined) {
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
      const result = this.onRequest(method, (message.params ?? {}) as Json);
      this.write({ jsonrpc: "2.0", id, result });
      return;
    }

    if (!method) return;
    // Track the active turn wherever it is first seen: `turn/started` can arrive
    // before the `turn/start` reply does.
    const params = (message.params ?? {}) as Json;
    if (method === "turn/started") {
      const threadId = params.threadId as string | undefined;
      const turn = params.turn as { id?: string } | undefined;
      if (threadId && turn?.id) this.activeTurns.set(threadId, turn.id);
    } else if (method === "turn/completed") {
      const threadId = params.threadId as string | undefined;
      if (threadId) this.activeTurns.delete(threadId);
    }
    this.onNotification(method, params);
  }

  private write(message: Json): void {
    this.proc.write(`${JSON.stringify(message)}\n`);
  }

  request(method: string, params: Json = {}): Promise<Json> {
    if (this.exited) return Promise.reject(new Error("codex app-server is not running"));
    const id = this.nextId++;
    const promise = new Promise<Json>((res, rej) =>
      this.pending.set(id, { resolve: res, reject: rej }),
    );
    this.write({ jsonrpc: "2.0", id, method, params });
    return promise;
  }

  notify(method: string, params: Json = {}): void {
    if (!this.exited) this.write({ jsonrpc: "2.0", method, params });
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
   * the folder being edited. Measured: a tool-using turn then runs commands and
   * writes files with no approval round-trip at all — which is what the notch
   * needs, because there is nowhere good to put a modal.
   */
  async startThread(cwd: string): Promise<string> {
    const result = await this.request("thread/start", {
      cwd,
      approvalPolicy: "never",
      sandbox: "workspace-write",
    });
    const thread = result.thread as { id?: string } | undefined;
    if (!thread?.id) throw new Error(`thread/start returned no thread id`);
    return thread.id;
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

  async startTurn(threadId: string, text: string): Promise<string> {
    const result = await this.request("turn/start", {
      threadId,
      // `text_elements` is required even when empty — omitting it is a decode
      // error on the far side, with no useful message.
      input: [{ type: "text", text, text_elements: [] }],
    });
    const turn = result.turn as { id?: string } | undefined;
    if (turn?.id) this.activeTurns.set(threadId, turn.id);
    return turn?.id ?? "";
  }

  /**
   * Stop the running turn.
   *
   * A **request**, not a notification, and it needs the **turnId** as well as
   * the thread. Both were wrong first time round, and the symptom was the worst
   * kind: sent as a notification it is accepted by the transport, answered by
   * nothing, and the turn simply keeps going — a Stop button that does nothing,
   * silently.
   */
  async interrupt(threadId: string): Promise<void> {
    const turnId = this.activeTurns.get(threadId);
    if (!turnId) return;
    await this.request("turn/interrupt", { threadId, turnId });
  }

  kill(): void {
    this.proc.kill();
  }
}
