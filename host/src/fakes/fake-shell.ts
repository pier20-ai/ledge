// A stand-in for the Swift shell: listens on a UDS, performs the shell side
// of the hello exchange (spec §3.6/§4.3), records everything it receives, and
// can inject arbitrary frames. Used by host tests and as a dev harness:
//
//   bun run fake-shell            # listens on ~/.ledge/ledge.sock
//   bun run fake-shell /tmp/x.sock

import type { Socket, UnixSocketListener } from "bun";
import { join } from "node:path";
import { FrameDecoder, encodeFrame } from "../protocol/framing";
import { FrameWriter } from "../protocol/frame-writer";
import {
  type Envelope,
  PROTOCOL_VERSION,
  SeqAllocator,
  parseEnvelope,
} from "../protocol/envelope";

export interface FakeShellOptions {
  socketPath: string;
  screen?: Record<string, unknown>;
  onEnvelope?: (envelope: Envelope) => void;
}

const DEFAULT_SCREEN = {
  notchWidth: 189,
  menubarHeight: 32,
  scale: 2,
  maxPanelHeight: 480,
};

export class FakeShell {
  readonly received: Envelope[] = [];
  private listener: UnixSocketListener<undefined> | null = null;
  private connection: Socket | null = null;
  private writer: FrameWriter | null = null;
  private gen = 0;
  private readonly outbound = new SeqAllocator();
  private readonly options: FakeShellOptions;
  private waiters: Array<() => void> = [];

  constructor(options: FakeShellOptions) {
    this.options = options;
  }

  start(): void {
    const decoder = { current: new FrameDecoder() };
    this.listener = Bun.listen({
      unix: this.options.socketPath,
      socket: {
        open: (socket) => {
          this.gen += 1;
          this.connection = socket;
          this.writer = new FrameWriter(socket);
          decoder.current = new FrameDecoder();
        },
        drain: () => {
          this.writer?.drain();
        },
        data: (socket, data) => {
          for (const payload of decoder.current.push(data)) {
            const envelope = parseEnvelope(payload);
            this.received.push(envelope);
            if (envelope.type === "hello" && envelope.app === "") {
              this.writer?.write(
                encodeFrame({
                  v: PROTOCOL_VERSION,
                  app: "",
                  seq: this.outbound.allocate(""),
                  type: "hello",
                  payload: {
                    v: PROTOCOL_VERSION,
                    gen: this.gen,
                    screen: this.options.screen ?? DEFAULT_SCREEN,
                  },
                }),
              );
            }
            this.options.onEnvelope?.(envelope);
            this.notifyWaiters();
          }
        },
        close: () => {
          this.connection = null;
        },
      },
    });
  }

  stop(): void {
    this.connection?.end();
    this.listener?.stop(true);
    this.listener = null;
  }

  /** Inject a frame toward the connected host, e.g. a resyncRequest. */
  send(app: string, type: string, payload: Record<string, unknown>): void {
    if (!this.connection || !this.writer) throw new Error("no host connected");
    this.writer.write(
      encodeFrame({
        v: PROTOCOL_VERSION,
        app,
        seq: this.outbound.allocate(app),
        type,
        payload,
      }),
    );
  }

  /** Drop the current connection without stopping the listener. */
  disconnect(): void {
    this.connection?.end();
    this.connection = null;
    this.writer = null;
  }

  /** Resolves once `predicate` matches any received envelope. */
  async waitFor(predicate: (envelope: Envelope) => boolean, timeoutMs = 2000): Promise<Envelope> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const match = this.received.find(predicate);
      if (match) return match;
      if (Date.now() > deadline) {
        throw new Error(
          `timed out; received: ${this.received.map((e) => e.type).join(", ") || "nothing"}`,
        );
      }
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 50);
      });
    }
  }

  private notifyWaiters(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const waiter of waiters) waiter();
  }
}

if (import.meta.main) {
  const socketPath =
    Bun.argv[2] ?? join(process.env.HOME ?? "~", ".ledge", "ledge.sock");
  const shell = new FakeShell({
    socketPath,
    onEnvelope: (envelope) => {
      console.log(`[fake-shell] ${envelope.type} app=${envelope.app || "(shell)"}`);
    },
  });
  shell.start();
  console.log(`[fake-shell] listening on ${socketPath}`);
}
