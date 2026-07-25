import Foundation

/// Length-prefixed framing (spec §1): `uint32` little-endian byte length, then
/// exactly that many bytes of UTF-8 JSON. Max frame 8 MiB.
public enum FrameCodec {
    /// Maximum frame payload, in bytes.
    public static let maxFrameSize = 8 * 1024 * 1024

    /// Prefix `payload` with its little-endian length.
    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }
}

/// A declared length above the cap means the stream can no longer be trusted
/// byte-aligned — the caller must close the connection. There is no in-band
/// recovery (§1).
public struct FrameOversizeError: Error, Equatable {
    public let declaredLength: Int
}

/// Buffered read loop (spec §1). Feed it whatever bytes the socket delivers —
/// split across writes or several frames coalesced — and it yields complete
/// payloads in order. Partial frames simply wait in the buffer.
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    /// Bytes still buffered awaiting completion (a truncated frame lingers here).
    public var pending: Int { buffer.count }

    /// Append received bytes and drain every complete frame now available.
    /// Throws `FrameOversizeError` if any frame declares a length over the cap,
    /// at which point the connection must be closed.
    public mutating func push(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while true {
            guard buffer.count >= 4 else { break }
            let length = readLength()
            if length > FrameCodec.maxFrameSize {
                throw FrameOversizeError(declaredLength: length)
            }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            let end = start + length
            frames.append(Data(buffer[start..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return frames
    }

    private func readLength() -> Int {
        // Little-endian uint32 from the front of the buffer.
        let base = buffer.startIndex
        let b0 = UInt32(buffer[base])
        let b1 = UInt32(buffer[base + 1])
        let b2 = UInt32(buffer[base + 2])
        let b3 = UInt32(buffer[base + 3])
        return Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    }
}
