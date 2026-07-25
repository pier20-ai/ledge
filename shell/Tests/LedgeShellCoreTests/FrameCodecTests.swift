import Foundation
import Testing
@testable import LedgeShellCore

@Suite("Frame codec (spec §1)")
struct FrameCodecTests {
    @Test("Encode/decode roundtrip")
    func roundtrip() throws {
        let payload = Data(#"{"v":1,"app":"stocks","seq":1,"type":"commit","payload":{}}"#.utf8)
        var decoder = FrameDecoder()
        let frames = try decoder.push(FrameCodec.encode(payload))
        #expect(frames.count == 1)
        #expect(frames[0] == payload)
        #expect(decoder.pending == 0)
    }

    @Test("A frame split across arbitrary chunk boundaries reassembles")
    func splitFrame() throws {
        let payload = Data("hello world, a longer payload".utf8)
        let frame = FrameCodec.encode(payload)
        var decoder = FrameDecoder()

        // Feed one byte at a time; no frame emerges until the last byte lands.
        var emitted: [Data] = []
        for index in frame.indices {
            let chunk = Data([frame[index]])
            emitted += try decoder.push(chunk)
        }
        #expect(emitted.count == 1)
        #expect(emitted[0] == payload)
    }

    @Test("Multiple frames coalesced in one chunk all decode")
    func coalescedFrames() throws {
        let a = Data("first".utf8)
        let b = Data("second".utf8)
        let c = Data("third".utf8)
        var blob = Data()
        blob.append(FrameCodec.encode(a))
        blob.append(FrameCodec.encode(b))
        blob.append(FrameCodec.encode(c))

        var decoder = FrameDecoder()
        let frames = try decoder.push(blob)
        #expect(frames == [a, b, c])
    }

    @Test("A partial trailing frame waits in the buffer")
    func partialTrailer() throws {
        let a = Data("complete".utf8)
        var blob = FrameCodec.encode(a)
        // Append a second frame's header + only part of its body.
        let b = Data("incomplete-body".utf8)
        let partial = FrameCodec.encode(b).prefix(6)
        blob.append(partial)

        var decoder = FrameDecoder()
        let frames = try decoder.push(blob)
        #expect(frames == [a])
        #expect(decoder.pending == partial.count)
    }

    @Test("An oversize declared length is rejected (connection must close)")
    func oversizeRejected() {
        var header = Data()
        let tooBig = UInt32(FrameCodec.maxFrameSize + 1).littleEndian
        withUnsafeBytes(of: tooBig) { header.append(contentsOf: $0) }
        header.append(contentsOf: [0x00, 0x00])           // a couple body bytes

        var decoder = FrameDecoder()
        #expect(throws: FrameOversizeError.self) {
            _ = try decoder.push(header)
        }
    }

    @Test("A well-framed but non-JSON payload fails envelope decode (close)")
    func invalidJSONPayload() throws {
        let garbage = Data("this is not json".utf8)
        var decoder = FrameDecoder()
        let frames = try decoder.push(FrameCodec.encode(garbage))
        #expect(frames.count == 1)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Envelope.self, from: frames[0])
        }
    }
}
