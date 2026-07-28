import AppKit
import Darwin
import LedgeShellCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var statusItem: NSStatusItem?
    private var hostSession: HostSession?
    private var hostProcess: HostProcess?
    /// Socket path override; `nil` means `~/.ledge/ledge.sock` (spec §1).
    var socketPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let session = HostSession()
        hostSession = session
        let controller = NotchPanelController(session: session)
        panelController = controller
        installStatusMenu()
        controller.start()

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
        let host = HostProcess(
            socketPath: socketPath ?? SocketTransport.defaultPath,
            appsRoot: LedgeInstall.appsRoot.path,
            logURL: LedgeInstall.logURL
        )
        hostProcess = host
        host.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // The host first: it should stop talking before the socket goes away.
        // This is the graceful path only — a SIGKILL never reaches here, which
        // is why the host also exits on stdin EOF (see HostProcess).
        hostProcess?.stop()
        hostSession?.stop()
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.tophalf.inset.filled",
            accessibilityDescription: "Ledge"
        )
        item.button?.toolTip = "Ledge"

        let menu = NSMenu(title: "Ledge")
        let collapse = NSMenuItem(
            title: "Toggle expansion",
            action: #selector(toggleExpansion),
            keyEquivalent: " "
        )
        collapse.target = self
        menu.addItem(collapse)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Ledge",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleExpansion() {
        panelController?.toggleExpansion()
    }

    @objc private func screenConfigurationChanged() {
        panelController?.reposition()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
