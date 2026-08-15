import Darwin
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
/// Why there is no host, in words a person can act on.
///
/// This exists because the panel's "waiting for host" card used to say
/// `cd host && bun run start` in every build, including a shipped one. A user
/// whose copy of Ledge could not start a host was handed a developer's command
/// for a repository they do not have — and the actual cause (an old .app with
/// no runtime inside it, left in ~/Applications) was written to NSLog, which
/// nobody reads.
enum HostStatus: Equatable {
    /// Running outside a bundle: the dev loop starts its own host, on purpose.
    case developerBuild
    /// Inside a `.app` that has no host in it. Almost always an old build.
    case bundleIncomplete(String)
    /// Launched; waiting for it to connect.
    case starting
    /// It ran and stopped, or would not start at all.
    case failed(String)
}

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
    /// Told whenever the answer to "why is there no host" changes, so the panel
    /// can say it instead of guessing.
    var onStatus: ((HostStatus) -> Void)?
    private var attempts = 0
    private var startedAt: Date?
    private var stopping = false
    /// PATH discovery is deliberately outside the main actor. Kept so repeated
    /// starts cannot launch parallel login shells while the first is resolving.
    private var environmentTask: Task<Void, Never>?

    init(socketPath: String, appsRoot: String, logURL: URL) {
        self.socketPath = socketPath
        self.appsRoot = appsRoot
        self.logURL = logURL
    }

    /// The bundled runtime + host entry, or nil when there is none. `locateHost`
    /// is the same question with an answer you can show someone.
    static func bundledHost() -> (runtime: URL, entry: URL)? {
        if case .found(let runtime, let entry) = locateHost() { return (runtime, entry) }
        return nil
    }

    func start() {
        guard !stopping, process == nil, environmentTask == nil else { return }
        switch Self.locateHost() {
        case .found(let runtime, let entry):
            report(.starting)
            environmentTask = Task { [weak self] in
                let path = await Task.detached(priority: .userInitiated) {
                    Self.loginPath()
                }.value
                guard let self else { return }
                self.environmentTask = nil
                guard !self.stopping, self.process == nil else { return }
                self.launch(runtime: runtime, entry: entry, loginPath: path)
            }
        case .developerBuild:
            NSLog("[ledge] no bundled host (dev build) — start one with `bun src/host.ts`")
            report(.developerBuild)
        case .incomplete(let what):
            // The failure: a Ledge.app built before the host was
            // bundled, still sitting in ~/Applications, launched by Spotlight in
            // preference to the new one. It can never work, and no amount of
            // waiting will change that — so the card says so.
            NSLog("[ledge] this bundle has no host: %@", what)
            report(.bundleIncomplete(what))
        }
    }

    private func report(_ status: HostStatus) {
        onStatus?(status)
    }

    /// What we found when we went looking for a host to run.
    enum Located: Equatable {
        case found(runtime: URL, entry: URL)
        /// Not in a bundle at all.
        case developerBuild
        /// In a bundle, but the host is not in it — with the part that is missing.
        case incomplete(String)
    }

    static func locateHost(bundle: Bundle = .main) -> Located {
        guard bundle.bundlePath.hasSuffix(".app") else { return .developerBuild }
        let root = bundle.bundleURL
        let runtime = root.appendingPathComponent("Contents/MacOS/\(executableName)")
        let entry = root.appendingPathComponent(entryPath)
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: runtime.path) else {
            return .incomplete("no \(executableName) in \(root.lastPathComponent)")
        }
        guard manager.fileExists(atPath: entry.path) else {
            return .incomplete("no host sources in \(root.lastPathComponent)")
        }
        return .found(runtime: runtime, entry: entry)
    }

    private func launch(runtime: URL, entry: URL, loginPath: String?) {
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
        if let loginPath { environment["PATH"] = loginPath }
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
            report(.failed("could not start it: \(error.localizedDescription)"))
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
            // The end of the line. Saying so beats a card that waits forever for
            // something nobody is going to try again.
            report(.failed("it stopped \(attempts) times — see ~/.ledge/host.log"))
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

    /// Restart the host now, at the user's request — the error card's one action
    /// (flow.md, Errors: "one action — Reload — which restarts the entire host").
    ///
    /// Distinct from the automatic backoff in two ways that both matter. The
    /// attempt counter resets, because a person pressing a button is new
    /// information and a host that gave up after five crashes must be reachable
    /// again. And there is no delay: the whole point of the card is that the
    /// worst case is a fresh visit, which a fifteen-second wait would not be.
    func restart() {
        guard !stopping else { return }
        NSLog("[ledge] host restart requested")
        // Clear the termination handler *before* terminating. Otherwise the
        // child's exit lands after the new one has started, and `hostExited`
        // nils out the process we just launched and schedules a third.
        if let process, process.isRunning {
            process.terminationHandler = nil
            // Closing stdin is still the graceful ask (`--exit-on-stdin-eof`);
            // terminate() is the follow-up.
            stdinPipe?.fileHandleForWriting.closeFile()
            process.terminate()
        }
        stdinPipe = nil
        process = nil
        environmentTask?.cancel()
        environmentTask = nil
        attempts = 0
        startedAt = nil
        start()
    }

    /// Terminate the child and stop restarting. Called from
    /// `applicationWillTerminate` — belt to the stdin-EOF braces, because that
    /// callback does not run on SIGKILL.
    func stop() {
        stopping = true
        environmentTask?.cancel()
        environmentTask = nil
        guard let process, process.isRunning else { return }
        // Closing stdin is the graceful path (the host unwinds its workers);
        // terminate() is the follow-up for a host that ignored it.
        stdinPipe?.fileHandleForWriting.closeFile()
        stdinPipe = nil
        process.terminate()
        self.process = nil
    }

    // MARK: - Environment

    /// The user's real PATH, read before a bundled host launch.
    ///
    /// `codex`, `bun` and friends live in places (`/opt/homebrew/bin`,
    /// `~/.local/bin`, a version manager's shims) that a GUI process never sees,
    /// and the builder is useless if it cannot find the agent. A login shell is
    /// the only thing that knows where the user actually installed things.
    nonisolated static func loginPath(
        shell: String? = nil,
        timeout: TimeInterval = 2
    ) -> String? {
        let shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l so the profile that sets PATH is actually read.
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.2)
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
