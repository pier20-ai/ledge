import Darwin
import Foundation
import Testing
@testable import LedgeShellCore

/// A blocking Unix-socket client standing in for the Bun host, used to drive the
/// listener end to end.
final class FakeHost: @unchecked Sendable {
    private let fd: Int32
    private var decoder = FrameDecoder()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, maxLen) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        guard connected == 0 else { Darwin.close(fd); return nil }
    }

    func sendRaw(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n } else { break }
            }
        }
    }

    func send(_ envelope: Envelope) {
        guard let payload = try? JSONEncoder().encode(envelope) else { return }
        sendRaw(FrameCodec.encode(payload))
    }

    /// Read one frame, or nil on timeout.
    func recvFrame(timeout: TimeInterval = 2) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 50)
            if ready <= 0 { continue }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return nil }
            if let frames = try? decoder.push(Data(chunk[0..<n])), let first = frames.first {
                return first
            }
        }
        return nil
    }

    func close() { Darwin.close(fd) }
}

@Suite("Transport end-to-end (spec §1)")
struct TransportE2ETests {
    private func tempPath() -> String {
        let name = "ledge-test-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    /// Box for cross-thread results.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _done = false
        private var _hello: Envelope?
        private var _event: Envelope?
        var done: Bool { lock.withLock { _done } }
        var hello: Envelope? { lock.withLock { _hello } }
        var event: Envelope? { lock.withLock { _event } }
        func finish(hello: Envelope?, event: Envelope?) {
            lock.withLock { _hello = hello; _event = event; _done = true }
        }
    }

    /// Wire events pulled off the transport and drained on the test's own
    /// isolation, avoiding any dependency on the main runloop being pumped.
    enum Wire { case connected(Int); case frame(Data); case disconnected }
    final class EventQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Wire] = []
        func push(_ item: Wire) { lock.withLock { items.append(item) } }
        func drain() -> [Wire] { lock.withLock { let all = items; items = []; return all } }
    }

    @MainActor
    @Test("hello → catalog → commit → event round trip over a real UDS")
    func fullRoundTrip() throws {
        let path = tempPath()
        let delegate = RecordingDelegate()
        let outbound = OutboundRecorder()
        let queue = EventQueue()
        let screen = ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480)

        let callbacks = SocketTransport.Callbacks(
            onConnect: { queue.push(.connected($0)) },
            onFrame: { queue.push(.frame($0)) },
            onDisconnect: { queue.push(.disconnected) }
        )
        let transport = SocketTransport(path: path, callbacks: callbacks)
        try transport.start()
        defer { transport.stop() }

        let box = Box()
        // The client handshake runs on a background thread with blocking reads.
        Thread.detachNewThread {
            guard let host = FakeHost(path: path) else { box.finish(hello: nil, event: nil); return }
            defer { host.close() }
            host.send(Envelope(app: "", seq: 1, type: "hello", payload: .object([
                "v": .int(1), "host": .string("1.0.0"),
            ])))
            let hello = host.recvFrame().flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }

            host.send(Envelope(app: "", seq: 2, type: "catalog", payload: .object(["apps": .array([])])))
            if let data = try? Fixtures.data("commit-mount.json"),
               let commit = try? JSONDecoder().decode(Envelope.self, from: data) {
                host.send(commit)
            }
            let event = host.recvFrame().flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }
            box.finish(hello: hello, event: event)
        }

        // Drive the engine directly on this (main-actor) thread by draining wire
        // events; emit the click once the commit has landed.
        var engine: ProtocolEngine?
        var emitted = false
        let deadline = Date().addingTimeInterval(5)
        while !box.done, Date() < deadline {
            for item in queue.drain() {
                switch item {
                case .connected(let gen):
                    let created = ProtocolEngine(
                        screen: screen,
                        delegate: delegate,
                        send: { env in
                            outbound.record(env)
                            if let data = try? JSONEncoder().encode(env) { transport.sendFrame(data) }
                        }
                    )
                    created.connectionOpened(generation: gen)
                    engine = created
                case .frame(let data):
                    if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
                        engine?.receive(env)
                    }
                case .disconnected:
                    break
                }
            }
            if !emitted, let engine, delegate.commits.contains(where: { $0.app == "stocks" }) {
                engine.emitEvent(app: "stocks", id: 5, name: "click")
                emitted = true
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let hello = try #require(box.hello, "no hello reply")
        #expect(hello.type == "hello")
        #expect(try hello.decodePayload([String: JSONValue].self)["gen"]?.asInt != nil)

        let event = try #require(box.event, "no event frame")
        #expect(event.type == "event")
        #expect(try event.decodePayload([String: JSONValue].self)["id"]?.asInt == 5)

        #expect(delegate.commits.contains { $0.app == "stocks" })
        #expect(delegate.catalogs.count == 1)
    }

    @Test("An oversize frame drops the connection")
    func oversizeDropsConnection() throws {
        let path = tempPath()
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var _connected = false
            private var _disconnected = false
            var connected: Bool { lock.withLock { _connected } }
            var disconnected: Bool { lock.withLock { _disconnected } }
            func markConnected() { lock.withLock { _connected = true } }
            func markDisconnected() { lock.withLock { _disconnected = true } }
        }
        let flag = Flag()
        let callbacks = SocketTransport.Callbacks(
            onConnect: { _ in flag.markConnected() },
            onFrame: { _ in },
            onDisconnect: { flag.markDisconnected() }
        )
        let transport = SocketTransport(path: path, callbacks: callbacks)
        try transport.start()
        defer { transport.stop() }

        let host = try #require(FakeHost(path: path))
        // A length header declaring more than the 8 MiB cap.
        var header = Data()
        let tooBig = UInt32(FrameCodec.maxFrameSize + 1).littleEndian
        withUnsafeBytes(of: tooBig) { header.append(contentsOf: $0) }
        header.append(contentsOf: [0, 0, 0, 0])
        host.sendRaw(header)

        let deadline = Date().addingTimeInterval(3)
        while !flag.disconnected, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        #expect(flag.connected)
        #expect(flag.disconnected)
        host.close()
    }
}
