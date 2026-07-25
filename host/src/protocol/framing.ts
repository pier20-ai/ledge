// Wire framing (spec §1): uint32 little-endian byte length, then exactly that
// many bytes of UTF-8 JSON. A stream socket may split or coalesce writes
// arbitrarily, so decoding buffers bytes and extracts complete frames only.

export const MAX_FRAME_BYTES = 8 * 1024 * 1024;

/** A framing violation means the stream can no longer be trusted byte-aligned;
 * the owner of the connection must close it (spec: no in-band recovery). */
export class FramingError extends Error {}

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function encodeFrame(payload: unknown): Uint8Array {
  const body = encoder.encode(JSON.stringify(payload));
  if (body.byteLength > MAX_FRAME_BYTES) {
    throw new FramingError(`frame of ${body.byteLength} bytes exceeds 8 MiB cap`);
  }
  const frame = new Uint8Array(4 + body.byteLength);
  new DataView(frame.buffer).setUint32(0, body.byteLength, true);
  frame.set(body, 4);
  return frame;
}

export class FrameDecoder {
  private buffer = new Uint8Array(0);

  /** Feed received bytes; returns every complete frame's parsed JSON payload.
   * Throws FramingError on an oversize declared length or unparseable payload. */
  push(data: Uint8Array): unknown[] {
    if (data.byteLength > 0) {
      const merged = new Uint8Array(this.buffer.byteLength + data.byteLength);
      merged.set(this.buffer, 0);
      merged.set(data, this.buffer.byteLength);
      this.buffer = merged;
    }

    const frames: unknown[] = [];
    while (this.buffer.byteLength >= 4) {
      const length = new DataView(
        this.buffer.buffer,
        this.buffer.byteOffset,
        4,
      ).getUint32(0, true);
      if (length > MAX_FRAME_BYTES) {
        throw new FramingError(`declared frame length ${length} exceeds 8 MiB cap`);
      }
      if (this.buffer.byteLength < 4 + length) {
        break;
      }
      const body = this.buffer.subarray(4, 4 + length);
      this.buffer = this.buffer.slice(4 + length);
      let text: string;
      try {
        text = decoder.decode(body);
      } catch {
        throw new FramingError("frame payload is not valid UTF-8");
      }
      try {
        frames.push(JSON.parse(text));
      } catch {
        throw new FramingError("frame payload is not valid JSON");
      }
    }
    return frames;
  }

  /** Bytes waiting for a complete frame (diagnostics + incomplete-frame timeout). */
  get pending(): number {
    return this.buffer.byteLength;
  }
}
