// Shell connection (spec §1, §3.6): Swift listens on the UDS; the host
// connects, exchanges hellos, then flows envelopes. On drop, reconnect with
// backoff (250 ms → 5 s); each accepted connection is a new generation, so
// all seq bookkeeping is rebuilt per connect.

import type { Socket } from "bun";
import { FrameDecoder, FramingError, encodeFrame } from "./protocol/framing";
import { FrameWriter } from "./protocol/frame-writer";
import {
  type Envelope,
  PROTOCOL_VERSION,
  SeqAllocator,
  SeqTracker,
  makeEnvelope,
  parseEnvelope,
} from "./protocol/envelope";

export interface ShellScreen {
  notchWidth: number;
  menubarHeight: number;
  scale: number;
  maxPanelHeight: number;
}

export interface ShellSession {
  gen: number;
  screen: ShellScreen;
  send(app: string, type: string, payload: Record<string, unknown>): void;
}

export interface ShellConnectionDelegate {
  /** Both hellos exchanged; the session is live. Send `catalog` first. */
  onReady(session: ShellSession): void;
  /** A valid, non-stale envelope arrived after the hello exchange. */
  onEnvelope(session: ShellSession, envelope: Envelope): void;
  /** The connection dropped (or was closed on protocol violation). */
  onClose(reason: string): void;
}

export interface ShellConnectionOptions {
  socketPath: string;
  hostVersion: string;
  reconnect?: boolean;
  minBackoffMs?: number;
  maxBackoffMs?: number;
}

export class ShellConnection {
  private readonly options: Required<ShellConnectionOptions>;
  private readonly delegate: ShellConnectionDelegate;
  private backoffMs: number;
  private stopped = false;

  constructor(options: ShellConnectionOptions, delegate: ShellConnectionDelegate) {
    this.options = {
      reconnect: true,
      minBackoffMs: 250,
      maxBackoffMs: 5000,
      ...options,
    };
    this.delegate = delegate;
    this.backoffMs = this.options.minBackoffMs;
  }

  start(): void {
    void this.connectOnce();
  }

  stop(): void {
    this.stopped = true;
  }

  private async connectOnce(): Promise<void> {
    if (this.stopped) return;

    const decoder = new FrameDecoder();
    const inbound = new SeqTracker();
    const outbound = new SeqAllocator();
    let session: ShellSession | null = null;
    let closed = false;

    const close = (socket: Socket, reason: string) => {
      if (closed) return;
      closed = true;
      socket.end();
      this.delegate.onClose(reason);
      this.scheduleReconnect();
    };

    // All outbound bytes go through a FrameWriter: a unix socket takes ~8 KiB
    // per write() and a dropped remainder shears the stream mid-frame, which
    // costs the whole connection (spec §1).
    let writer: FrameWriter | null = null;

    try {
      const socket = await Bun.connect({
        unix: this.options.socketPath,
        socket: {
          open: (socket) => {
            writer = new FrameWriter(socket);
            // First frame after connect is the host hello (spec §3.6);
            // nothing else flows until the shell's hello arrives.
            writer.write(
              encodeFrame({
                v: PROTOCOL_VERSION,
                app: "",
                seq: outbound.allocate(""),
                type: "hello",
                payload: { v: PROTOCOL_VERSION, host: this.options.hostVersion },
              }),
            );
          },
          drain: () => {
            writer?.drain();
          },
          data: (socket, data) => {
            let payloads: unknown[];
            try {
              payloads = decoder.push(data);
            } catch (error) {
              if (error instanceof FramingError) {
                close(socket, `framing violation: ${error.message}`);
                return;
              }
              throw error;
            }
            for (const payload of payloads) {
              let envelope: Envelope;
              try {
                envelope = parseEnvelope(payload);
              } catch (error) {
                close(socket, `envelope violation: ${String(error)}`);
                return;
              }
              if (envelope.v !== PROTOCOL_VERSION) {
                // Version mismatch → log and drop the frame (spec §2).
                console.warn(`[ledge-host] dropping frame with v=${envelope.v}`);
                continue;
              }
              if (!inbound.accept(envelope)) {
                continue;
              }
              if (session === null) {
                if (envelope.type !== "hello" || envelope.app !== "") {
                  close(socket, "first shell frame was not hello");
                  return;
                }
                const gen = Number(envelope.payload.gen);
                const screen = envelope.payload.screen as ShellScreen;
                session = {
                  gen,
                  screen,
                  send: (app, type, payload) => {
                    writer?.write(
                      encodeFrame(makeEnvelope(app, type, payload, outbound)),
                    );
                  },
                };
                this.backoffMs = this.options.minBackoffMs;
                this.delegate.onReady(session);
                continue;
              }
              this.delegate.onEnvelope(session, envelope);
            }
          },
          close: (socket) => {
            close(socket, "connection closed");
          },
          error: (socket, error) => {
            close(socket, `socket error: ${String(error)}`);
          },
        },
      });
      void socket;
    } catch (error) {
      this.delegate.onClose(`connect failed: ${String(error)}`);
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (this.stopped || !this.options.reconnect) return;
    const delay = this.backoffMs;
    this.backoffMs = Math.min(this.backoffMs * 2, this.options.maxBackoffMs);
    setTimeout(() => void this.connectOnce(), delay);
  }
}
