import AppKit
import Foundation
import LedgeShellCore
import QuartzCore

/// Ties the socket transport, protocol engine, and AppKit renderer together.
/// This is the only source of app content in the shell: every panel above the
/// strip is either a host-rendered tree from here, or one of the shell's own
/// built-in cards (placeholder / crash / chat / [+]).
///
/// It does not decide *what* is presented — the panel controller owns that
/// (Swift owns transient presentation) and tells this object, which turns the
/// gesture into `selection` + `lifecycle` envelopes (spec §4.2/§4.3).
@MainActor
final class HostSession {
    private let renderer = ProtocolRenderer()
    private var engine: ProtocolEngine!
    /// Executes the shell-side capabilities (spec §6): AppleScript / Shortcuts,
    /// notifications, screen capture. Held here because it is per-session state
    /// in the same sense the engine is.
    private let capabilities = CapabilityHost()
    private var transport: SocketTransport?
    private var drawTimer: Timer?

    /// Height reserved for the shell-drawn app strip (spec §5/§8). The 34 pt
    /// header the spec also reserves is now part of the app's own tree — see
    /// shell/README.md ("the header is app content").
    static let stripHeight: CGFloat = 42

    /// What the screen allows a panel to be. Set by the panel controller from
    /// the display it sits on; the fallback only applies before the first
    /// `reposition` (and in headless snapshot rendering).
    var limits: PanelLimits = .fallback

    /// Height of the panel's cutout exclusion row (the panel wings). Set by the
    /// panel controller from the same `NotchMetrics` the surface uses, because
    /// the panel's total height has to include a row the app's tree does not
    /// know exists — the app measures its own content, the shell adds the room
    /// it reserved.
    var cutoutRowHeight: CGFloat = NotchMetrics.fallback.closedHeight

    /// Everything a panel spends before the app's own tree gets a point: the
    /// app strip below, the cutout exclusion row above.
    var chromeHeight: CGFloat { Self.stripHeight + cutoutRowHeight }

    /// The app whose tree is currently in the panel, as last reported.
    private var shownApp: String?
    private(set) var catalog: [CatalogApp] = []
    /// Cached panel wrappers, keyed by app; the width is remembered with them so
    /// an app that changes `meta.panel.width` on reload gets a fresh wrapper.
    private var composites: [String: (view: NSView, width: CGFloat)] = [:]

    /// The catalog snapshot changed (spec §3.6) — rebuild the app strip.
    var onCatalog: (([CatalogApp]) -> Void)?
    /// A host connection opened or closed — the placeholder card keys off this.
    var onConnectionChanged: ((Bool) -> Void)?
    private(set) var isConnected = false
    /// An app's tree changed (commit applied, crash card, discard). The panel
    /// re-measures if that app is the one on screen.
    var onContentChanged: ((String) -> Void)?
    /// An app-level chrome request (spec §3.3): `expand`/`collapse`/`attention`,
    /// or a `wing` with its spec (nil spec = release the notch).
    var onChrome: ((_ app: String, _ request: String, _ wing: WingSpec?) -> Void)?
    /// The user clicked a notification's body (§6): open the notch at the app.
    var onNotificationOpened: ((_ app: String) -> Void)?

    init() {
        // Send the shell's real geometry in `hello` (spec §4.3), not the mockup
        // 210×34 — a notched Mac reports its true cutout, other displays the
        // measured menu-bar height. Falls back to the mockup only when no screen
        // can be measured.
        let screen = Self.detectScreen()
        engine = ProtocolEngine(
            screen: screen,
            delegate: renderer,
            send: { [weak self] envelope in self?.send(envelope) }
        )
        renderer.onEvent = { [weak self] app, id, name, data in
            self?.engine.emitEvent(app: app, id: id, name: name, data: data)
        }
        // The composite is *not* invalidated here: an ordinary commit mutates
        // the same root in place, and rebuilding the wrapper would cross-fade
        // the panel on every price tick. `content(for:)` notices a genuinely
        // new root (reload, resync) by checking the wrapper still holds it.
        renderer.onContentChanged = { [weak self] app in self?.onContentChanged?(app) }
        // A scrolling stack has to know the ceiling it is scrolling under, and
        // the ceiling is per-app (`meta.panel.maxHeight`) and per-screen.
        renderer.scrollCap = { [weak self] app in
            guard let self else { return PanelLimits.fallback.maxHeight - Self.stripHeight }
            return max(0, self.panelSize(for: app).maxHeight - self.chromeHeight)
        }
        renderer.onCatalog = { [weak self] payload in
            guard let self else { return }
            self.catalog = payload.apps
            // Logged with the icons, because "the strip shows placeholders" was a
            // real bug and the catalog is the only place the truth can come from
            // (spec §3.6). scripts/e2e-smoke.sh asserts on this line.
            NSLog(
                "[ledge] catalog %d apps: %@",
                payload.apps.count,
                payload.apps.map { "\($0.id)=\($0.icon)" }.joined(separator: " ")
            )
            self.onCatalog?(payload.apps)
        }
        renderer.onChrome = { [weak self] app, request, wing in
            self?.onChrome?(app, request, wing)
        }

        // Shell-executed capabilities (spec §6). The engine answers `apple` /
        // `notify` / `capture` through this object and puts its results back on
        // the wire; a pressed notification button returns as `notifyAction`.
        capabilities.appName = { [weak self] app in self?.name(for: app) ?? app }
        capabilities.onNotificationAction = { [weak self] app, id, action in
            self?.engine.sendNotifyAction(app: app, id: id, action: action)
            // A body click means "show me the app", not just "tell the app":
            // the panel controller opens the notch at the poster. Button
            // presses don't open anything — the app decides (ctx.expand).
            if action == NotificationPresenter.openedAction {
                self?.onNotificationOpened?(app)
            }
        }
        // An observed OS signal (spec §6 extension) reaches the app as the id-0
        // `platform` event, the same app-level convention `drop` uses.
        capabilities.onPlatformEvent = { [weak self] app, kind, name, userInfo in
            self?.engine.sendPlatformEvent(app: app, kind: kind, name: name, userInfo: userInfo)
        }
        engine.capabilities = capabilities
        NSLog("[ledge] notifications via %@", capabilities.notificationMode)
    }

    /// An **app-level** event for the presented app (§4.1 with id 0): the drop
    /// shelf's file paths, today. Returns false when nothing is presented, which
    /// is what lets the drop shelf refuse the drag instead of eating it.
    @discardableResult
    func sendAppEvent(name: String, data: JSONValue) -> Bool {
        guard let app = shownApp else { return false }
        engine.emitAppEvent(app: app, name: name, data: data)
        return true
    }

    /// Whether there is an app on screen that could receive a drop right now.
    var hasPresentedApp: Bool { shownApp != nil }

    /// The renderer, for the wing canvas hookup (spec §3.3 extension). The panel
    /// controller owns which app's wing is up; the renderer owns where its draw
    /// frames land.
    var protocolRenderer: ProtocolRenderer { renderer }

    /// Bind the socket and begin listening. `path` overrides the default
    /// `~/.ledge/ledge.sock` (used by the smoke test).
    func start(path: String? = nil) throws {
        let callbacks = SocketTransport.Callbacks(
            onConnect: { [weak self] gen in
                Task { @MainActor in
                    guard let self else { return }
                    self.engine.connectionOpened(generation: gen)
                    self.isConnected = true
                    self.onConnectionChanged?(true)
                }
            },
            onFrame: { [weak self] data in
                Task { @MainActor in self?.handleFrame(data) }
            },
            onDisconnect: { [weak self] in
                Task { @MainActor in self?.handleDisconnect() }
            }
        )
        let transport = SocketTransport(path: path ?? SocketTransport.defaultPath, callbacks: callbacks)
        self.transport = transport
        try transport.start()

        // Blit coalesced draws on a display cadence (§3.4).
        drawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.engine.flushDraws() }
        }
    }

    func stop() {
        drawTimer?.invalidate()
        drawTimer = nil
        transport?.stop()
        transport = nil
    }

    /// Build the `ScreenInfo` reported in `hello` from the display the shell
    /// prefers (the notched one, else the main screen), reusing the same
    /// `NotchMetrics.detect` measurement the panel geometry uses so the host and
    /// the shell agree on the notch size. `maxPanelHeight` is clamped to the
    /// visible screen height (spec §5: shell-computed, default 480).
    static func detectScreen() -> ScreenInfo {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        else {
            return ScreenInfo(
                notchWidth: 210,
                menubarHeight: 34,
                scale: 2,
                maxPanelHeight: Double(PanelLimits.fallback.maxHeight)
            )
        }
        let metrics = NotchMetrics.detect(for: screen)
        return ScreenInfo(
            notchWidth: Double(metrics.closedWidth),
            menubarHeight: Double(metrics.closedHeight),
            scale: Double(screen.backingScaleFactor),
            // The real cap, not the spec's 480 pt placeholder: an app that reads
            // `maxPanelHeight` and asks for exactly that must actually get it.
            maxPanelHeight: Double(PanelLimits.detect(for: screen).maxHeight)
        )
    }

    // MARK: - Inbound

    private func handleFrame(_ data: Data) {
        // Malformed JSON means the stream is no longer trustworthy — close (§1).
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            transport?.dropConnection()
            return
        }
        Task { @MainActor in self.engine.receive(envelope) }
    }

    private func handleDisconnect() {
        engine.connectionClosed()
        // The catalog belongs to the dead connection; the strip empties until a
        // host reconnects and re-sends it (spec §3.6 — full snapshots only).
        catalog = []
        composites.removeAll()
        isConnected = false
        onCatalog?([])
        onConnectionChanged?(false)
        if let shownApp { onContentChanged?(shownApp) }
    }

    /// Feed one envelope straight into the engine, bypassing the socket. Used by
    /// the snapshot replay (`--snapshots`), which drives the real engine and
    /// renderer from recorded commit batches so a PNG proves the same code path
    /// a live host exercises.
    func inject(_ envelope: Envelope) {
        engine.receive(envelope)
    }

    /// Open a synthetic connection generation for the replay path.
    func openReplay() {
        engine.connectionOpened(generation: 1)
    }

    private func send(_ envelope: Envelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        transport?.sendFrame(data)
    }

    // MARK: - Presentation

    func name(for app: String) -> String {
        catalog.first(where: { $0.id == app })?.name ?? app
    }

    /// The panel size `app` asked for in its `meta.panel` (spec §5 extension),
    /// already clamped to what this screen allows. An app that declared nothing
    /// gets 440 pt and the screen's own height cap — exactly the old behavior.
    func panelSize(for app: String?) -> (width: CGFloat, maxHeight: CGFloat) {
        let panel = app.flatMap { id in catalog.first(where: { $0.id == id })?.panel }
        return (limits.width(requesting: panel?.width), limits.height(requesting: panel?.maxHeight))
    }

    /// The panel content for an app: its committed tree wrapped at that app's
    /// panel width, plus the panel width and height it wants. `nil` when the app
    /// has no tree yet — the caller shows the placeholder card.
    func content(for app: String) -> (view: NSView, width: CGFloat, height: CGFloat)? {
        guard let root = renderer.rootView(for: app) else { return nil }
        let size = panelSize(for: app)

        let composite: NSView
        if let existing = composites[app],
           existing.width == size.width,
           existing.view.subviews.contains(where: { $0 === root }) {
            composite = existing.view
        } else {
            composite = Self.makeComposite(root: root, width: size.width)
            composites[app] = (composite, size.width)
        }

        let fitting = renderer.rootFittingHeight(for: app)
        let height = min(fitting + chromeHeight, size.maxHeight)
        return (composite, size.width, height)
    }

    /// The app's panel-wing content (spec §5 `wing`), or nil for the shell's own
    /// default. Asked on every refresh — see `ProtocolRenderer.wingView`.
    func panelWing(for app: String?) -> NSView? {
        app.flatMap { renderer.wingView(for: $0) }
    }

    /// Report which app the panel is showing (spec §4.3): a `selection`
    /// envelope, plus `collapsed` for the app leaving the panel and `expanded`
    /// for the one entering it (§4.2). The host is the source of truth for what
    /// "selected" means; the shell just reports the switch — so this is a no-op
    /// unless the app actually changed.
    func setPresented(_ app: String?) {
        guard shownApp != app else { return }
        let previous = shownApp
        shownApp = app
        engine.sendSelection(app: app)
        if let previous { engine.sendLifecycle(app: previous, phase: "collapsed") }
        if let app { engine.sendLifecycle(app: app, phase: "expanded") }
    }

    /// Wrap a host tree at the panel's content width. The tree owns everything
    /// above the strip, including its own header row.
    static func makeComposite(
        root: NSView,
        width: CGFloat = ProtocolRenderer.contentWidth
    ) -> NSView {
        let composite = FlippedView()
        root.translatesAutoresizingMaskIntoConstraints = false
        composite.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: composite.leadingAnchor),
            root.widthAnchor.constraint(equalToConstant: width),
            root.topAnchor.constraint(equalTo: composite.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: composite.bottomAnchor),
        ])
        return composite
    }
}
