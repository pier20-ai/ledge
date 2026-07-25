// Partial-write-safe frame writing. A macOS unix socket accepts at most one
// buffer's worth (~8 KiB) per write() call; Bun returns the count actually
// taken and the rest is OUR problem. Dropping it shears the stream mid-frame:
// the peer reads the next frame's length out of body bytes, sees garbage, and
// closes the connection (spec §1 — no in-band recovery). So every socket write
// in the host goes through this: queue what didn't fit, flush on `drain`.

import type { Socket } from "bun";

export class FrameWriter {
  private queue: Uint8Array[] = [];

  constructor(private readonly socket: Socket) {}

  /** Bytes queued awaiting socket capacity (diagnostics/tests). */
  get pending(): number {
    return this.queue.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  }

  write(frame: Uint8Array): void {
    if (this.queue.length > 0) {
      // Order matters: never let a new frame jump the queue.
      this.queue.push(frame);
      return;
    }
    const written = this.socket.write(frame);
    if (written < frame.byteLength) {
      this.queue.push(frame.subarray(Math.max(written, 0)));
    }
  }

  /** Wire this to the socket's `drain` handler. */
  drain(): void {
    while (this.queue.length > 0) {
      const head = this.queue[0]!;
      const written = this.socket.write(head);
      if (written < head.byteLength) {
        this.queue[0] = head.subarray(Math.max(written, 0));
        return;
      }
      this.queue.shift();
    }
  }
}
