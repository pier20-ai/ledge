import { describe, expect, test } from "bun:test";
import {
  FrameDecoder,
  FramingError,
  MAX_FRAME_BYTES,
  encodeFrame,
} from "../src/protocol/framing";

describe("framing", () => {
  test("roundtrips a payload", () => {
    const decoder = new FrameDecoder();
    const frames = decoder.push(encodeFrame({ hello: "world", n: 42 }));
    expect(frames).toEqual([{ hello: "world", n: 42 }]);
    expect(decoder.pending).toBe(0);
  });

  test("reassembles a frame split at every possible boundary", () => {
    const frame = encodeFrame({ type: "commit", payload: { list: [1, 2, 3] } });
    for (let split = 1; split < frame.byteLength; split++) {
      const decoder = new FrameDecoder();
      expect(decoder.push(frame.subarray(0, split))).toEqual([]);
      const frames = decoder.push(frame.subarray(split));
      expect(frames).toHaveLength(1);
    }
  });

  test("extracts multiple coalesced frames from one chunk", () => {
    const a = encodeFrame({ i: 1 });
    const b = encodeFrame({ i: 2 });
    const c = encodeFrame({ i: 3 });
    const merged = new Uint8Array(a.byteLength + b.byteLength + c.byteLength);
    merged.set(a, 0);
    merged.set(b, a.byteLength);
    merged.set(c, a.byteLength + b.byteLength);

    const decoder = new FrameDecoder();
    expect(decoder.push(merged)).toEqual([{ i: 1 }, { i: 2 }, { i: 3 }]);
  });

  test("rejects a declared length above the 8 MiB cap", () => {
    const oversize = new Uint8Array(4);
    new DataView(oversize.buffer).setUint32(0, MAX_FRAME_BYTES + 1, true);
    const decoder = new FrameDecoder();
    expect(() => decoder.push(oversize)).toThrow(FramingError);
  });

  test("rejects a payload that is not JSON", () => {
    const body = new TextEncoder().encode("not json {{{");
    const frame = new Uint8Array(4 + body.byteLength);
    new DataView(frame.buffer).setUint32(0, body.byteLength, true);
    frame.set(body, 4);
    const decoder = new FrameDecoder();
    expect(() => decoder.push(frame)).toThrow(FramingError);
  });

  test("rejects encoding a frame above the cap", () => {
    expect(() => encodeFrame({ blob: "x".repeat(MAX_FRAME_BYTES) })).toThrow(
      FramingError,
    );
  });

  test("holds partial frames across pushes without emitting", () => {
    const frame = encodeFrame({ patient: true });
    const decoder = new FrameDecoder();
    expect(decoder.push(frame.subarray(0, 2))).toEqual([]);
    expect(decoder.push(new Uint8Array(0))).toEqual([]);
    expect(decoder.pending).toBe(2);
    expect(decoder.push(frame.subarray(2))).toEqual([{ patient: true }]);
  });
});
