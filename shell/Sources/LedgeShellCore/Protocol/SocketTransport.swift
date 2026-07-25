import Darwin
import Dispatch
import Foundation

/// Unix-domain-socket transport (spec §1). Swift listens; the Bun host connects.
/// One connection at a time, all apps multiplexed. Framing, the 8 MiB cap, the
/// connection-generation counter, and close-on-malformed all live here; message
/// interpretation is the engine's job.
///
/// All mutable state is confined to a single serial queue, so no locking is
/// needed and the class is safe to hand across actors.
public final class SocketTransport: @unchecked Sendable {
    /// The default socket path, `~/.ledge/ledge.sock`.
    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ledge/ledge.sock")
    }

    public struct Callbacks: Sendable {
        /// A connection was accepted; the argument is its generation (§1).
        public var onConnect: @Sendable (Int) -> Void
        /// One complete, length-validated frame payload (still raw JSON bytes).
        public var onFrame: @Sendable (Data) -> Void
        /// The active connection closed (EOF, error, or malformed frame).
        public var onDisconnect: @Sendable () -> Void

        public init(
            onConnect: @escaping @Sendable (Int) -> Void,
            onFrame: @escaping @Sendable (Data) -> Void,
            onDisconnect: @escaping @Sendable () -> Void
        ) {
            self.onConnect = onConnect
            self.onFrame = onFrame
            self.onDisconnect = onDisconnect
        }
    }

    public enum StartError: Error {
        case socketCreationFailed(errno: Int32)
        case pathTooLong
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
    }

    private let path: String
    private let callbacks: Callbacks
    private let queue = DispatchQueue(label: "com.ledge.socket")

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var clientSource: DispatchSourceRead?
    private var decoder = FrameDecoder()
    private var generation = 0

    public init(path: String = SocketTransport.defaultPath, callbacks: Callbacks) {
        self.path = path
        self.callbacks = callbacks
    }

    // MARK: - Lifecycle

    public func start() throws {
        try queue.sync {
            try openListener()
        }
    }

    public func stop() {
        queue.sync {
            closeClient()
            listenSource?.cancel()
            listenSource = nil
            if listenFD >= 0 {
                Darwin.close(listenFD)
                listenFD = -1
            }
            unlink(path)
        }
    }

    /// Close the active connection. Used when a frame's payload fails to parse
    /// as JSON — the stream can no longer be trusted (§1).
    public func dropConnection() {
        queue.async { [weak self] in self?.closeClient() }
    }

    /// Frame and write `payload` to the active connection (no-op if none).
    public func sendFrame(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            let frame = FrameCodec.encode(payload)
            self.writeAll(frame, to: self.clientFD)
        }
    }

    // MARK: - Listener (queue-confined)

    private func openListener() throws {
        // Ensure the parent directory exists (~/.ledge).
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketCreationFailed(errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLen else {
            Darwin.close(fd)
            throw StartError.pathTooLong
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { cString in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), cString, maxLen)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, size)
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw StartError.bindFailed(errno: code)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw StartError.listenFailed(errno: code)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        listenSource = source
    }

    private func acceptConnection() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        // A peer vanishing mid-write must surface as a write error, not a
        // process-killing SIGPIPE.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        // Only one connection at a time (§1): a new accept supplants the old.
        closeClient()

        clientFD = fd
        decoder = FrameDecoder()
        generation += 1
        let gen = generation
        callbacks.onConnect(gen)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        clientSource = source
    }

    // MARK: - Reader (queue-confined)

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { buffer in
            Darwin.read(clientFD, buffer.baseAddress, buffer.count)
        }
        if count == 0 {
            closeClient()                     // clean EOF
            return
        }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            closeClient()                     // read error
            return
        }
        let data = Data(chunk[0..<count])
        do {
            let frames = try decoder.push(data)
            for frame in frames {
                callbacks.onFrame(frame)
            }
        } catch {
            // Oversize declared length: the stream is no longer byte-aligned and
            // there is no in-band recovery — close (§1). Loudly: a silent close
            // here once hid a partial-write bug behind a reconnect loop.
            NSLog("[ledge] closing connection: framing violation (%@)", String(describing: error))
            closeClient()
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let written = Darwin.write(fd, base + offset, total - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    closeClient()             // broken pipe / error
                    return
                }
            }
        }
    }

    private func closeClient() {
        guard clientFD >= 0 else { return }
        clientSource?.cancel()               // cancel handler closes the fd
        clientSource = nil
        clientFD = -1
        decoder = FrameDecoder()
        callbacks.onDisconnect()
    }
}
