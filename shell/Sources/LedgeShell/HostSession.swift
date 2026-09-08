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

    /// The app holding a live `ctx.record` session, for the global hotkey:
    /// ⌃⌥Space while the tape rolls lands on the recorder (G3).
    var recordingOwner: String? { capabilities.recordingOwner }

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

    /// Everything a panel spends before the app's own tree gets a point.
    ///
    /// One row now, not two: the bottom app strip is gone (flow.md — in a visit
    /// the wings are Ledge's controls, and there is no bar), so the panel is the
    /// cutout exclusion row plus the app's own measured height and nothing else.
    /// **Panel height = content fit.**
    var chromeHeight: CGFloat { cutoutRowHeight }

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
    var onChrome: ((
        _ app: String,
        _ request: String,
        _ wing: WingSpec?,
        _ ms: Double?,
        _ priority: NotificationClass?
    ) -> Void)?
    /// The user clicked a notification's body (§6): open the notch at the app.
    var onNotificationOpened: ((_ app: String) -> Void)?
    /// A §4.1 event left one of an app's nodes. Reported as (app, name) only —
    /// this is not a second event bus, it is how the panel controller learns
    /// that the **action inside a notification swell** was pressed, which is a
    /// row of flow.md's Transitions table the shell cannot otherwise see: the
    /// button belongs to the app's borrowed tree and takes the click itself.
    var onNodeEvent: ((_ app: String, _ name: String) -> Void)?
    /// One event of an app's builder stream (spec §3.6), on its way to the
    /// editor surface. Not filtered here: which transcript an event belongs to
    /// is presentation, and presentation is the panel controller's half.
    var onBuilder: ((BuilderPayload) -> Void)?
    /// An app lifecycle transition (spec §3.2: `started`/`reloaded`/`crashed`/
    /// `stopped`). The crash card is already drawn by the renderer; this is the
    /// same signal read as *build status* for the editor's toggle.
    var onAppState: ((_ app: String, _ state: String) -> Void)?
    /// The error card's Reload (flow.md, Errors). Only the app delegate owns the
    /// `HostProcess`, so this is a pass-through: the renderer draws the button,
    /// the delegate restarts the process, and nothing in between knows both.
    var onReloadHost: (() -> Void)? {
        didSet { renderer.onReloadHost = onReloadHost }
    }

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
            self?.onNodeEvent?(app, name)
        }
        // The composite is *not* invalidated here: an ordinary commit mutates
        // the same root in place, and rebuilding the wrapper would cross-fade
        // the panel on every price tick. `content(for:)` notices a genuinely
        // new root (reload, resync) by checking the wrapper still holds it.
        renderer.onContentChanged = { [weak self] app in self?.onContentChanged?(app) }
        // A scrolling stack has to know the ceiling it is scrolling under, and
        // the ceiling is per-app (`meta.panel.maxHeight`) and per-screen.
        renderer.scrollCap = { [weak self] app in
            guard let self else {
                return PanelLimits.fallback.maxHeight - NotchMetrics.fallback.closedHeight
            }
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
        renderer.onChrome = { [weak self] app, request, wing, ms, priority in
            self?.onChrome?(app, request, wing, ms, priority)
        }
        renderer.onBuilder = { [weak self] payload in self?.onBuilder?(payload) }
        renderer.onLifecycle = { [weak self] app, state in
            guard let self else { return }
            self.onAppState?(app, state)
            // Spec §4.2's "once on connect", implemented where the phase is
            // actually known. A worker that has just come up has never been told
            // anything — not its panel phase and not Reduce Motion — and the
            // first thing many of them do is start a frame loop.
            if state == "started" || state == "reloaded" {
                self.engine.sendLifecycle(app: app, phase: self.shownApp == app ? "expanded" : "collapsed")
            }
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
        observeReduceMotion()
    }

    // MARK: - Reduce Motion (spec §4.2, principle 10)

    /// The system's Reduce Motion switch, forwarded to every app.
    ///
    /// Principle 10 is unobeyable from a worker: a Bun process cannot read an
    /// AppKit accessibility preference, and `ctx` carries exactly the things the
    /// platform cannot provide. So the shell reads it, `hello` seeds it, and
    /// every `lifecycle` carries it — see `sendReduceMotionToAll`.
    private var reduceMotionObserver: NSObjectProtocol?

    private func observeReduceMotion() {
        engine.updateReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        // `NSWorkspace`'s own centre, not the default one: this notification is
        // posted per-process by AppKit and never reaches `NotificationCenter`.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
    }

    /// Record the new value and, if it moved, tell every running app at once —
    /// the flag has no envelope of its own, so a fresh `lifecycle` with the
    /// app's *current* phase is how the change travels (spec §4.2).
    func applyReduceMotion(_ value: Bool) {
        guard engine.updateReduceMotion(value) else { return }
        NSLog("[ledge] reduce motion: %@", value ? "on" : "off")
        sendReduceMotionToAll()
    }

    private func sendReduceMotionToAll() {
        for app in catalog where app.running {
            engine.sendLifecycle(app: app.id, phase: shownApp == app.id ? "expanded" : "collapsed")
        }
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

    /// The same event, to an app the **caller** names rather than the presented
    /// one. A swipe across the collapsed pill belongs to whichever app owns the
    /// wing (spec §3.3 extension), and nothing is presented while the notch is
    /// closed — so the addressee cannot come from `shownApp`. Arbitration is
    /// still not this object's job: the panel controller knows the owner.
    func sendAppEvent(to app: String, name: String, data: JSONValue) {
        engine.emitAppEvent(app: app, name: name, data: data)
    }

    /// The user typed into the presented app's editor, or asked to interrupt the
    /// running turn (spec §4.3 `builderInput`). Mirrors `sendAppEvent`: the
    /// surface reports a gesture, this object decides who it is addressed to and
    /// owns the envelope — the editor never names an app itself, so it cannot
    /// send a turn to an app that is no longer on screen.
    ///
    /// Returns false when nothing is presented, which is the case the editor
    /// needs in order to stay silent rather than guess.
    @discardableResult
    func sendBuilderInput(text: String?, cancel: Bool = false) -> Bool {
        guard let app = shownApp else { return false }
        engine.sendBuilderInput(app: app, text: text, cancel: cancel)
        return true
    }

    /// Ask the host to make an app out of a sentence (spec §4.3: "`app` may name
    /// a not-yet-existing id when coming from the [+] surface"; §8: the host
    /// scaffolds first, then starts the session).
    ///
    /// Separate from `sendBuilderInput` because it is the one builder message
    /// that is *not* addressed to a presented app — guarding it on `shownApp`,
    /// as that one does, would silently drop every attempt to create anything.
    func sendBuilderCreate(text: String) {
        engine.sendBuilderInput(app: "", text: text)
    }

    /// Whether there is an app on screen that could receive a drop right now.
    var hasPresentedApp: Bool { shownApp != nil }

    /// **Stop a session** — the ledge's ✕ (flow.md, "The strip"; spec §4.3
    /// extension `appControl`). The worker is torn down by the host and the app
    /// stays installed; Settings' switch is the way back, and it is the same
    /// switch, because this sends the host down the path that one already takes.
    func stopApp(_ app: String) {
        setAppEnabled(app, enabled: false)
    }

    /// **Settings' switch** (flow.md, Edges: "Settings — a native macOS
    /// window"). Enable or disable an installed app.
    ///
    /// It is the same `appControl` envelope the ✕ sends, with the other action,
    /// and it lands on the same `setAppEnabled` in the host — persist the
    /// disabled list, start or stop the worker, re-send the catalog. That
    /// symmetry is the point: there is exactly one path by which an app becomes
    /// enabled or disabled, so the ledge's ✕ and Settings' switch can never
    /// disagree about what "off" means.
    ///
    /// Settings used to be a privileged *app* that reached the same code through
    /// `ctx.platform.enable/disable`. It is a native window now, so the shell
    /// asks directly and there is no privileged app surface left to protect.
    func setAppEnabled(_ app: String, enabled: Bool) {
        engine.sendAppControl(app: app, action: enabled ? "start" : "stop")
    }

    /// **A turned control** (G4, `meta.settings`): Settings' native switches
    /// and fields land here, one envelope per change. Deliberately without an
    /// optimistic local write — the host validates, persists, and answers with
    /// a full catalog, and the control follows the catalog like every other
    /// row in the window (the same no-optimism rule as the enable switch).
    func setAppSetting(_ app: String, key: String, value: JSONValue) {
        engine.sendAppSetting(app: app, key: key, value: value)
    }

    /// Every installed app, enabled or not — what the Settings window lists.
    ///
    /// Deliberately not `strip`, which filters to the enabled ones: a switch you
    /// can only find while the thing is already on is not a switch.
    var installedApps: [CatalogApp] {
        catalog.sorted { $0.order < $1.order }
    }

    /// The app's catalog glyph — an SF Symbol name (spec §3.6). The shelf draws
    /// it big and white; a session with no catalog row falls back to the generic
    /// square, which is what the strip has always shown for one.
    func icon(for app: String) -> String {
        catalog.first(where: { $0.id == app })?.symbolName ?? "square.dashed"
    }

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
    /// prefers (`NotchScreen`: the notched one, else the primary), reusing the
    /// same `NotchMetrics.detect` measurement the panel geometry uses so the
    /// host and the shell agree on the notch size — including when that notch
    /// is one the shell synthesized for a display that has none.
    /// `maxPanelHeight` is clamped to the visible screen height (spec §5:
    /// shell-computed, default 480).
    static func detectScreen() -> ScreenInfo {
        guard let screen = NotchScreen.preferred() else {
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

    /// Blit whatever draws are pending, right now (spec §3.4). Live, this is the
    /// display-link tick's job; the snapshot replay has no display link and has
    /// to ask, once the panel has been laid out and its canvases have a size.
    func flushDraws() {
        engine.flushDraws()
    }

    /// Test seam: every envelope the shell puts on the wire, as it goes out.
    ///
    /// The alternative is asserting against `ProtocolEngine` directly, which
    /// proves the engine builds the frame correctly but not that `HostSession`
    /// asked for the right one — and "Settings' switch sends `start`, the ✕
    /// sends `stop`" is a fact about this object.
    var onOutboundForTesting: ((Envelope) -> Void)?

    private func send(_ envelope: Envelope) {
        onOutboundForTesting?(envelope)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        transport?.sendFrame(data)
    }

    // MARK: - Presentation

    func name(for app: String) -> String {
        catalog.first(where: { $0.id == app })?.name ?? app
    }

    /// The panel size `app` asked for in its `meta.panel` (spec §5 extension),
    /// already clamped to what this screen allows. An app that declared nothing
    /// — every default app — gets the fixed 480 pt (G6) and the screen's own
    /// height cap.
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
    /// The app's `<mini>` content, or nil when it mounted none — in which case a
    /// `peek` has nothing to show and is refused (spec §3.3: silently).
    func miniView(for app: String) -> NSView? {
        renderer.miniView(for: app)
    }

    func panelWing(for app: String?) -> NSView? {
        app.flatMap { renderer.wingView(for: $0) }
    }

    /// The app's `<summary>` content (spec §5 `summary`), or nil when it
    /// declared none — in which case a hover that reaches Th opens the visit
    /// instead of a glance surface (flow.md).
    func summaryView(for app: String) -> NSView? {
        renderer.summaryView(for: app)
    }

    /// Is this session heavy — does it owe the hover a summary?
    func declaresSummary(for app: String) -> Bool {
        renderer.declaresSummary(for: app)
    }

    /// The strip of sessions the visit walks (flow.md, "The strip"). Session ≡
    /// app for now, and the catalog is the only source (spec §3.6).
    var strip: SessionStrip { SessionStrip(catalog: catalog) }

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
