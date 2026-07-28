import Foundation

/// Runs the Bun host as a child of the shell (spec §1: Swift listens, the host
/// connects), and makes sure it dies when we do.
///
/// Only `Ledge.app` does this. A development build launched from `.build/debug`
/// deliberately does **not** auto-start a host, because the whole dev loop is
/// running one by hand — `bun src/host.ts` with a debugger, a different apps
/// root, a rebuild every few seconds. Two hosts on one socket is a confusing
/// failure, and the bundle check is the one signal that reliably distinguishes
/// "shipped" from "someone is working on this".
@MainActor
final class HostProcess {
    /// The Bun runtime, shipped as a helper executable (rather than a resource)
    /// so `codesign --deep` signs it as part of the app. Named for its job:
    /// this process is the Ledge host.
    private static let executableName = "ledge-host"

    /// The host's entry module inside the bundle. We ship Bun plus the host's
    /// TypeScript rather than a `--compile` binary — same size, and a compiled
    /// host could never run `bun install` for an app's `// deps:` (spec §6).
    /// See scripts/bundle-app.sh for the full reasoning.
    private static let entryPath = "Contents/Resources/host/src/host.ts"

    /// Restart backoff, mirroring the host's own app-crash policy (spec §6 rule
    /// 2): quick first retry, then back off, and stop pretending after a while.
    private static let backoff: [TimeInterval] = [0.5, 1, 2, 5, 15]
    private static let maxAttempts = 5
    /// Uptime past which a run counts as healthy and the backoff counter resets.
    private static let healthyRunSeconds: TimeInterval = 30

    private let socketPath: String
    private let appsRoot: String
    private let logURL: URL

    private var process: Process?
    /// Held open for the child's lifetime. Closing it — or dying, which closes
    /// it for us — is what tells the host to exit (`--exit-on-stdin-eof`).
    private var stdinPipe: Pipe?
    private var attempts = 0
    private var startedAt: Date?
    private var stopping = false

    init(socketPath: String, appsRoot: String, logURL: URL) {
        self.socketPath = socketPath
        self.appsRoot = appsRoot
        self.logURL = logURL
    }

    /// The bundled runtime + host entry, or nil when running outside a `.app`
    /// (dev) or when either half is missing from the bundle.
    static func bundledHost() -> (runtime: URL, entry: URL)? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        let root = Bundle.main.bundleURL
        let runtime = root.appendingPathComponent("Contents/MacOS/\(executableName)")
        let entry = root.appendingPathComponent(entryPath)
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: runtime.path) else { return nil }
        guard manager.fileExists(atPath: entry.path) else {
            NSLog("[ledge] bundle has no host sources at %@", entry.path)
            return nil
        }
        return (runtime, entry)
    }

    func start() {
        guard !stopping else { return }
        guard let bundled = Self.bundledHost() else {
            NSLog("[ledge] no bundled host (dev build) — start one with `bun src/host.ts`")
            return
        }
        launch(runtime: bundled.runtime, entry: bundled.entry)
    }

    private func launch(runtime: URL, entry: URL) {
        let process = Process()
        process.executableURL = runtime
        process.arguments = [
            entry.path, socketPath, "--apps-root", appsRoot, "--exit-on-stdin-eof",
        ]

        // A GUI app inherits a minimal PATH — no /opt/homebrew/bin, no
        // ~/.local/bin — so a host spawned from here cannot find `codex`, `bun`,
        // or anything else the user installed. Rather than guess at locations,
        // ask the user's own login shell what their PATH is (see `loginPath()`).
        var environment = ProcessInfo.processInfo.environment
        if let path = Self.loginPath() { environment["PATH"] = path }
        process.environment = environment

        // stdin stays open for as long as we live; its closure is the shutdown
        // signal. We never write to it.
        let stdin = Pipe()
        process.standardInput = stdin

        // Host stdout/stderr is the only record of what the host and every app's
        // console did. Unbundled it went to a terminal; bundled it would go
        // nowhere at all, which makes a misbehaving app undebuggable.
        if let handle = Self.appendingHandle(for: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.hostExited(status: finished.terminationStatus) }
        }

        do {
            try process.run()
            self.process = process
            self.stdinPipe = stdin
            self.startedAt = Date()
            NSLog("[ledge] host started (pid %d), logging to %@", process.processIdentifier, logURL.path)
        } catch {
            NSLog("[ledge] could not start the host: %@", String(describing: error))
            scheduleRestart()
        }
    }

    private func hostExited(status: Int32) {
        process = nil
        stdinPipe = nil
        guard !stopping else { return }

        // A run that stayed up is evidence the install is fine; whatever killed
        // it this time is not the same as a boot loop (spec §6 rule 2).
        if let startedAt, Date().timeIntervalSince(startedAt) >= Self.healthyRunSeconds {
            attempts = 0
        }
        NSLog("[ledge] host exited with status %d", status)
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard attempts < Self.maxAttempts else {
            NSLog("[ledge] host failed %d times — not restarting", attempts)
            return
        }
        let delay = Self.backoff[min(attempts, Self.backoff.count - 1)]
        attempts += 1
        NSLog("[ledge] restarting host in %.1fs (attempt %d)", delay, attempts)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping else { return }
            self.start()
        }
    }

    /// Terminate the child and stop restarting. Called from
    /// `applicationWillTerminate` — belt to the stdin-EOF braces, because that
    /// callback does not run on SIGKILL.
    func stop() {
        stopping = true
        guard let process, process.isRunning else { return }
        // Closing stdin is the graceful path (the host unwinds its workers);
        // terminate() is the follow-up for a host that ignored it.
        stdinPipe?.fileHandleForWriting.closeFile()
        stdinPipe = nil
        process.terminate()
        self.process = nil
    }

    // MARK: - Environment

    /// The user's real PATH, read once from their login shell.
    ///
    /// `codex`, `bun` and friends live in places (`/opt/homebrew/bin`,
    /// `~/.local/bin`, a version manager's shims) that a GUI process never sees,
    /// and the builder is useless if it cannot find the agent. A login shell is
    /// the only thing that knows where the user actually installed things.
    private static func loginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l so the profile that sets PATH is actually read.
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty ?? true) ? nil : path
    }

    private static func appendingHandle(for url: URL) -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}
