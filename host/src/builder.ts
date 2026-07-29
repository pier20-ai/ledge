// The builder (spec §8): `builderInput` in, `builder` events out.
//
// One Codex app-server child for the whole host, one **thread per app**. The
// thread id is pinned in that app's `.builder.json`, so the notch chat always
// resumes the right conversation and never scrolls past your other projects.
// Codex owns the transcript in its own storage; Ledge owns only the pointer.
//
// The client is started lazily, on the first `builderInput`. A user who never
// opens the editor never pays for a Codex process, and a user with no Codex
// installed only finds out when they ask for something — at which point the
// error is about the thing they just did.

import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { CodexClient, type CodexClientOptions } from "./codex/client";
import { toBuilderEvent, type BuilderEvent, type Json } from "./codex/events";
import { scaffoldFromPrompt } from "./scaffold";

/** `.builder.json` — the session pointer (spec §6, §8). */
interface BuilderPointer {
  agent: string;
  threadId: string;
}

export interface BuilderSink {
  /** Emit one builder event for an app (spec §3.6). */
  builder(app: string, turn: number, event: BuilderEvent): void;
  log(line: string): void;
  /** An app folder just appeared because the user asked for it in the [+]
   * surface. Optional: the watcher notices it anyway, this only removes the
   * lag between "the shell is now showing this app" and "the catalog has heard
   * of it". */
  created?(app: string): void;
}

export interface BuilderOptions {
  appsRoot: string;
  sink: BuilderSink;
  /** Injected in tests so nothing ever spawns a real Codex. */
  client?: CodexClientOptions;
}

export class Builder {
  private readonly appsRoot: string;
  private readonly sink: BuilderSink;
  private readonly clientOptions: CodexClientOptions;

  private client: CodexClient | null = null;
  private starting: Promise<CodexClient> | null = null;
  /** app → thread id, for threads this process has already opened. */
  private readonly threads = new Map<string, string>();
  /** thread id → app, for routing notifications back (they name the thread). */
  private readonly appsByThread = new Map<string, string>();
  /** Apps with a turn in flight. One turn per app: a second `builderInput`
   * while the first is running is a steer, not a queue — and until steering is
   * wired, it is refused rather than silently dropped. */
  private readonly busy = new Set<string>();
  /** Monotonic per-app turn counter (spec §3.6 events carry `turn`). */
  private readonly turnCounts = new Map<string, number>();

  constructor(options: BuilderOptions) {
    this.appsRoot = options.appsRoot;
    this.sink = options.sink;
    this.clientOptions = options.client ?? {};
  }

  /**
   * The user typed into an app's chat, or asked to stop.
   *
   * `app` is `""` when the message came from the notch's [+] surface, which by
   * definition has no app behind it (spec §4.3). That is not an error to reject:
   * it is a request to make one. The host scaffolds first and *then* starts the
   * session, so the agent opens onto a folder that already renders something —
   * which is both the fastest way for it to learn the platform (AGENTS.md is
   * next to it) and the difference between "your app appeared, now watch it
   * change" and a minute of nothing.
   */
  async handleInput(appId: string, input: { text?: string; cancel?: boolean }): Promise<void> {
    if (input.cancel) return this.cancel(appId);
    const text = input.text?.trim();
    if (!text) return;

    let app = appId;
    if (app === "") {
      try {
        app = await scaffoldFromPrompt(this.appsRoot, text);
      } catch (error) {
        // Reported against `""`, the only id the shell knows at this point —
        // its editor is still on the [+] surface, and an error tagged with an
        // app that was never created would be dropped by the bridge.
        this.emit("", { event: "error", message: `could not create the app: ${describe(error)}` });
        this.emit("", { event: "done", status: "failed" });
        return;
      }
      this.sink.log(`[ledge-host] scaffolded '${app}' from the [+] surface`);
      this.sink.created?.(app);
      // Before the turn, so the shell has moved its editor onto the new app by
      // the time the first `text` event arrives — the bridge drops events for
      // apps it is not focused on, and the [+] surface is focused on `""`.
      this.emit(app, { event: "created" });
    }

    if (this.busy.has(app)) {
      // Refused, not queued: a queue here would spend the user's tokens on
      // something they may have typed by accident while waiting.
      this.emit(app, { event: "status", text: "still working on the last request" });
      return;
    }

    this.busy.add(app);
    const turn = (this.turnCounts.get(app) ?? 0) + 1;
    this.turnCounts.set(app, turn);

    try {
      const client = await this.ensureClient();
      const threadId = await this.ensureThread(client, app);
      await client.startTurn(threadId, text);
      // The turn is now running; `turn/completed` clears `busy` (see onEvent).
    } catch (error) {
      this.busy.delete(app);
      // Verbatim (spec §3.6): "not installed", "auth expired" and "rate limited"
      // are all things the user can act on, and paraphrasing them helps nobody.
      this.emit(app, { event: "error", message: describe(error) });
      this.emit(app, { event: "done", status: "failed" });
    }
  }

  private async cancel(app: string): Promise<void> {
    const threadId = this.threads.get(app);
    if (!this.client || !threadId || !this.busy.has(app)) return;
    try {
      await this.client.interrupt(threadId);
    } catch (error) {
      this.sink.log(`[ledge-host] interrupt failed for '${app}': ${describe(error)}`);
    }
  }

  /** Start the app-server on first use; every later caller shares it. */
  private ensureClient(): Promise<CodexClient> {
    if (this.client?.isRunning) return Promise.resolve(this.client);
    if (this.starting) return this.starting;

    this.starting = (async () => {
      const client = new CodexClient({
        ...this.clientOptions,
        log: this.clientOptions.log ?? ((line) => this.sink.log(line)),
      });
      client.onNotification = (method, params) => this.onNotification(method, params);
      try {
        const info = await client.initialize();
        this.sink.log(`[ledge-host] codex ready: ${String(info.userAgent ?? "app-server")}`);
      } catch (error) {
        client.kill();
        this.starting = null;
        throw new Error(
          `could not start codex — is it installed and logged in? (${describe(error)})`,
        );
      }
      this.client = client;
      this.starting = null;
      // Threads belong to a process; a restarted app-server knows none of ours.
      this.threads.clear();
      this.appsByThread.clear();
      return client;
    })();
    return this.starting;
  }

  /** Resume the app's pinned thread, or start one and pin it. */
  private async ensureThread(client: CodexClient, app: string): Promise<string> {
    const existing = this.threads.get(app);
    if (existing) return existing;

    const cwd = join(this.appsRoot, app);
    const pointer = await this.readPointer(app);
    let threadId: string;
    if (pointer?.threadId) {
      try {
        threadId = await client.resumeThread(pointer.threadId, cwd);
      } catch (error) {
        // A pointer can outlive its thread (Codex storage cleared, another
        // machine). Starting fresh is better than refusing to talk.
        this.sink.log(`[ledge-host] could not resume '${app}': ${describe(error)} — starting new`);
        threadId = await client.startThread(cwd);
      }
    } else {
      threadId = await client.startThread(cwd);
    }

    this.threads.set(app, threadId);
    this.appsByThread.set(threadId, app);
    if (threadId !== pointer?.threadId) await this.writePointer(app, threadId);
    return threadId;
  }

  private onNotification(method: string, params: Json): void {
    const threadId = params.threadId as string | undefined;
    // Notifications name a thread, not an app; anything we cannot attribute is
    // not ours to forward.
    const app = threadId ? this.appsByThread.get(threadId) : undefined;
    if (!app) return;

    const event = toBuilderEvent(method, params);
    if (!event) return;
    if (event.event === "done") this.busy.delete(app);
    this.emit(app, event);
  }

  private emit(app: string, event: BuilderEvent): void {
    this.sink.builder(app, this.turnCounts.get(app) ?? 0, event);
  }

  private pointerPath(app: string): string {
    return join(this.appsRoot, app, ".builder.json");
  }

  private async readPointer(app: string): Promise<BuilderPointer | null> {
    try {
      const parsed = JSON.parse(await readFile(this.pointerPath(app), "utf8")) as BuilderPointer;
      // Another agent's pointer is not ours to resume.
      if (parsed.agent !== "codex" || typeof parsed.threadId !== "string") return null;
      return parsed;
    } catch {
      return null;
    }
  }

  private async writePointer(app: string, threadId: string): Promise<void> {
    const pointer: BuilderPointer = { agent: "codex", threadId };
    try {
      await writeFile(this.pointerPath(app), `${JSON.stringify(pointer, null, 2)}\n`);
    } catch (error) {
      // Not fatal: the conversation works, it just will not resume next launch.
      this.sink.log(`[ledge-host] could not write .builder.json for '${app}': ${describe(error)}`);
    }
  }

  shutdown(): void {
    this.client?.kill();
    this.client = null;
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
