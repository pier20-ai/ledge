import AppKit
import Darwin
import LedgeShellCore

/// No status-bar item, deliberately.
///
/// Ledge had one with "Toggle expansion" and "Quit Ledge" on it. The first
/// duplicated the notch itself — the whole product is a thing you click at the
/// top of the screen — and the second is one line in Settings. A menu-bar icon
/// that exists to hold a single Quit is a permanent tenant of a crowded strip,
/// paying rent on somebody else's screen.
///
/// The consequence is worth stating plainly: `LSUIElement` means no Dock icon
/// either, so the Settings panel is now the only way to quit Ledge without
/// Activity Monitor. That is a real constraint on Settings, not an afterthought.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var hostSession: HostSession?
    private var hostProcess: HostProcess?
    private var hotkey: HotkeyCenter?
    /// Socket path override; `nil` means `~/.ledge/ledge.sock` (spec §1).
    var socketPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let session = HostSession()
        hostSession = session
        let controller = NotchPanelController(session: session)
        panelController = controller
        controller.start()

        // ⌃⌥Space opens the notch from anywhere (G3). Registered after the
        // controller exists because the key is nothing but a message to it.
        hotkey = HotkeyCenter { [weak controller] in
            controller?.hotkeyPressed()
        }

        // The shell is the listener (spec §1): it binds the socket and the host
        // connects to it. Failing to bind is not fatal — the panel still opens
        // and shows the "waiting for host" card.
        do {
            try session.start(path: socketPath)
            NSLog("[ledge] serving on %@", socketPath ?? SocketTransport.defaultPath)
        } catch {
            fputs("Could not bind the Ledge socket: \(error)\n", stderr)
        }

        // Seed ~/.ledge, then start the host — in that order, because the host
        // scans the apps root at startup and an unseeded root is an empty
        // catalog. Both are no-ops in a dev build (see HostProcess.start).
        LedgeInstall.seedIfNeeded()
        // …and the `ledge` CLI onto the user's own bin, every launch — a
        // moved .app re-points the symlink here (env `LEDGE_CLI_DIR` reroutes
        // it for suites; a `--ledge-root` run without it skips entirely).
        LedgeInstall.cliDirOverride = ProcessInfo.processInfo.environment["LEDGE_CLI_DIR"]
        LedgeInstall.installCLIIfPossible()
        let host = HostProcess(
            socketPath: socketPath ?? SocketTransport.defaultPath,
            appsRoot: LedgeInstall.appsRoot.path,
            logURL: LedgeInstall.logURL
        )
        hostProcess = host
        // The panel says why there is no host, rather than offering everyone a
        // developer's shell command (see HostStatus).
        host.onStatus = { [weak self] status in
            self?.panelController?.hostDetail = Self.hostDetail(for: status)
        }
        // The one action on the one error card (flow.md, Errors): restart the
        // whole host. Worst case is a fresh visit.
        session.onReloadHost = { [weak host] in host?.restart() }
        host.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// One line, addressed to whoever is actually looking at it.
    static func hostDetail(for status: HostStatus) -> String {
        switch status {
        case .developerBuild:
            // The only audience for this is someone with the repository open.
            return "cd host && bun run start"
        case .bundleIncomplete(let what):
            // Almost always an old copy of Ledge.app that predates the bundled
            // host — and no amount of waiting fixes it, so say what to do.
            return "This copy has no host (\(what)). Replace it with a current build."
        case .starting:
            return "Starting…"
        case .failed(let why):
            return why
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // The host first: it should stop talking before the socket goes away.
        // This is the graceful path only — a SIGKILL never reaches here, which
        // is why the host also exits on stdin EOF (see HostProcess).
        hostProcess?.stop()
        hostSession?.stop()
    }

    @objc private func screenConfigurationChanged() {
        panelController?.reposition()
    }

}

@main
enum LedgeShellApp {
    static func main() {
        let application = NSApplication.shared
        let arguments = CommandLine.arguments

        // `--snapshots <outDir> [--commits <dir>]` renders PNGs headlessly by
        // replaying recorded commit batches (see scripts/snapshot-demos.sh) and
        // exits; it never binds a socket.
        if let index = arguments.firstIndex(of: "--snapshots") {
            guard let output = value(after: index, in: arguments) else {
                fputs("--snapshots needs an output directory\n", stderr)
                exit(EXIT_FAILURE)
            }
            let commits = arguments.firstIndex(of: "--commits").flatMap { value(after: $0, in: arguments) }
            do {
                try SnapshotRenderer.renderAll(
                    to: URL(fileURLWithPath: output, isDirectory: true),
                    commits: commits.map { URL(fileURLWithPath: $0, isDirectory: true) }
                )
            } catch {
                fputs("Could not render snapshots: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

        let delegate = AppDelegate()
        // `--ledge-root <path>` relocates the whole install (seed target, apps
        // root, host log) — how a bundle gets smoke-tested without touching the
        // user's real ~/.ledge.
        if let index = arguments.firstIndex(of: "--ledge-root") {
            LedgeInstall.rootOverride = value(after: index, in: arguments)
        }
        // `--socket <path>` overrides the default `~/.ledge/ledge.sock`; the
        // smoke test uses it so a run never touches the real one.
        if let index = arguments.firstIndex(of: "--socket") {
            delegate.socketPath = value(after: index, in: arguments)
        }
        application.delegate = delegate
        application.run()
    }

    private static func value(after index: Int, in arguments: [String]) -> String? {
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("--") else { return nil }
        return arguments[next]
    }
}
