// A fake `codex app-server` (spec §8), in the spirit of fakes/fake-shell.ts.
//
// Every builder test drives this instead of a real Codex. Two reasons, and the
// second is the one that matters: a real turn costs the user money and takes
// tens of seconds, and — more importantly — a model is not deterministic, so a
// suite built on one tests the model rather than the adapter.
//
// It speaks the subset the adapter uses, with the shapes measured from a real
// conversation (see src/codex/events.ts for which of those are surprising).

import type { CodexProcess } from "../codex/client";

export interface FakeCodexOptions {
  /** Fail `initialize` — what "codex is not installed / not logged in" looks
   * like from the client's side. */
  failInitialize?: string;
  /** Fail `thread/resume`, as a pointer that outlived its thread does. */
  failResume?: string;
  /** Exit the process as soon as it is started. */
  dieImmediately?: boolean;
}

/** A scripted app-server. Drive turns by hand with `emit`. */
export class FakeCodex {
  /** Every request the client sent, in order — the assertion surface. */
  readonly requests: Array<{ method: string; params: Record<string, unknown> }> = [];
  private line: (line: string) => void = () => {};
  private exit: (code: number) => void = () => {};
  private threadSeq = 0;
  private turnSeq = 0;
  /** The turn id handed out by the last `turn/start`, so tests can assert that
   * `turn/interrupt` carries the right one. */
  lastTurnId = "";

  constructor(private readonly options: FakeCodexOptions = {}) {}

  /** The `CodexProcess` the client talks to. */
  get process(): CodexProcess {
    return {
      write: (line) => this.receive(line),
      onLine: (handler) => {
        this.line = handler;
      },
      onExit: (handler) => {
        this.exit = handler;
        if (this.options.dieImmediately) queueMicrotask(() => handler(1));
      },
      kill: () => this.exit(0),
    };
  }

  /** Push a notification to the client, as a real app-server would. */
  emit(method: string, params: Record<string, unknown>): void {
    this.line(JSON.stringify({ jsonrpc: "2.0", method, params }));
  }

  /** The usual streamed reply: some text, then a turn that ended `status`. */
  emitTurn(threadId: string, text: string, status = "completed"): void {
    this.emit("item/agentMessage/delta", { threadId, delta: text });
    this.emit("turn/completed", { threadId, turn: { id: this.lastTurnId, status } });
  }

  /** End the process after it has accepted work. */
  stop(code = 1): void {
    this.exit(code);
  }

  private receive(raw: string): void {
    const message = JSON.parse(raw.trim()) as {
      id?: number;
      method?: string;
      params?: Record<string, unknown>;
    };
    if (message.method === undefined) return;
    this.requests.push({ method: message.method, params: message.params ?? {} });
    if (message.id === undefined) return; // a notification; nothing to answer

    const reply = (result: Record<string, unknown>) =>
      this.line(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
    const fail = (msg: string) =>
      this.line(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { message: msg } }));

    switch (message.method) {
      case "initialize":
        if (this.options.failInitialize) return fail(this.options.failInitialize);
        return reply({ userAgent: "fake-codex/0" });
      case "thread/start":
        this.threadSeq += 1;
        return reply({ thread: { id: `thread-${this.threadSeq}` } });
      case "thread/resume":
        if (this.options.failResume) return fail(this.options.failResume);
        return reply({ thread: { id: String(message.params?.threadId ?? "") } });
      case "turn/start": {
        this.turnSeq += 1;
        this.lastTurnId = `turn-${this.turnSeq}`;
        return reply({ turn: { id: this.lastTurnId, status: "inProgress" } });
      }
      case "turn/interrupt":
        return reply({});
      default:
        return reply({});
    }
  }
}
