import AppKit
import CoreGraphics
import LedgeShellCore
import QuartzCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the shell's presentation state and turns it into a panel. Content comes
/// from the `HostSession` (app trees) or from the shell's own chrome surfaces;
/// nothing here knows what an app *is*.
@MainActor
final class NotchPanelController {
    /// Fixed window size: large enough for the biggest shape the surface can
    /// morph into — the widest panel the screen allows (an app may declare more
    /// than 440 pt now), the widest winged pill, and the tallest panel, plus
    /// shadow slack. Recomputed only when the screen configuration changes; the
    /// window frame still never animates, the shape morphs inside it.
    private var windowSize: CGSize = PanelLimits.fallback.windowSize(for: .fallback)

    private let panel: NotchPanel
    private let surface: ShellSurfaceView
    private var shellState = ShellState()
    private let session: HostSession

    /// The app that currently owns the collapsed notch (spec §3.3 extension).
    /// One notch, one wing: the latest app to ask wins, and only the owner can
    /// give it back.
    private var wingOwner: String?

    /// Chrome surfaces are rebuilt only when their app changes, so re-presenting
    /// one is a re-measure rather than a cross-fade.
    private var chatSurface: (app: String, view: ChatContentView)?
    private var newAppSurface: NewAppContentView?
    private var placeholder: (phase: HostPlaceholderView.Phase, view: HostPlaceholderView)?

    init(session: HostSession) {
        self.session = session
        var selectApp: ((String) -> Void)!
        var selectNewApp: (() -> Void)!
        var selectSettings: (() -> Void)!
        var toggleChat: (() -> Void)!
        let callbacks = ShellCallbacks(
            selectApp: { app in selectApp(app) },
            selectNewApp: { selectNewApp() },
            selectSettings: { selectSettings() },
            toggleChat: { toggleChat() }
        )
        surface = ShellSurfaceView(callbacks: callbacks)
        panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        selectApp = { [weak self] app in
            guard let self else { return }
            self.shellState.selectApp(app)
            self.refresh(animated: true)
        }
        selectNewApp = { [weak self] in self?.present(.newApp) }
        selectSettings = { [weak self] in
            guard let self else { return }
            self.shellState.selectApp(AppBarView.settingsAppID)
            self.refresh(animated: true)
        }
        toggleChat = { [weak self] in
            guard let self else { return }
            self.shellState.toggleChat()
            self.refresh(animated: true)
        }
        surface.requestOpen = { [weak self] in self?.openFromCollapsed() }
        surface.requestClose = { [weak self] in self?.present(.collapsed) }

        // The drop shelf (INTAKE): a file dropped on the open panel becomes an
        // app-level `drop` event for whatever app is on screen. Presentation
        // decides the addressee, so the answer lives here rather than in the
        // surface — the surface only knows it is expanded.
        surface.canAcceptDrop = { [weak self] in
            guard let self, let app = self.shellState.presentation.app else { return false }
            return self.session.content(for: app) != nil
        }
        surface.onDropFiles = { [weak self] paths in
            guard let self else { return false }
            NSLog("[ledge] drop %d file(s) -> %@", paths.count, self.shellState.presentation.app ?? "nobody")
            return self.session.sendAppEvent(
                name: "drop",
                data: .object(["paths": .array(paths.map { .string($0) })])
            )
        }

        session.onCatalog = { [weak self] apps in
            guard let self else { return }
            self.surface.setCatalog(apps)
            self.shellState.rememberIfUnset(
                apps.filter { $0.enabled }.sorted { $0.order < $1.order }.first?.id
            )
            self.refresh(animated: true)
        }
        session.onContentChanged = { [weak self] app in
            guard let self, self.shellState.presentedApp == app else { return }
            self.refresh(animated: true)
        }
        session.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            // Presentation state for a dead generation is gone (spec §1) — and a
            // wing is presentation state, so the notch goes back to idle rather
            // than showing a live activity nothing is driving any more.
            if !connected { self.setWing(app: nil, spec: nil) }
            guard self.shellState.isExpanded else { return }
            self.refresh(animated: true)
        }
        session.onChrome = { [weak self] app, request, wing in
            self?.handleChrome(app: app, request: request, wing: wing)
        }
        session.onNotificationOpened = { [weak self] app in
            // Same refusal as chrome "expand": opening onto the placeholder
            // because the worker hasn't committed (or crashed) is worse than
            // leaving the notch closed — the app still hears "opened" either way.
            guard let self, self.session.content(for: app) != nil else { return }
            self.shellState.present(.expanded(app: app))
            self.refresh(animated: true)
        }

        panel.contentView = surface
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
    }

    func start() {
        reposition()
        refresh(animated: false)
        panel.orderFrontRegardless()
    }

    func present(_ presentation: ShellPresentation, animated: Bool = true) {
        shellState.present(presentation)
        refresh(animated: animated)
    }

    func toggleExpansion() {
        shellState.toggleExpansion()
        refresh(animated: true)
    }

    /// Push the current state to the surface: resolve the content view and the
    /// panel height for whatever is presented, and report the presented app to
    /// the host (spec §4.3).
    private func refresh(animated: Bool) {
        let presentation = shellState.presentation
        // Chat sits *below* the live preview (spec §8), so the app stays
        // selected while its chat is open; [+] and the pill select nothing.
        session.setPresented(presentation.app)

        let content: NSView?
        let width: CGFloat
        let height: CGFloat
        switch presentation {
        case .collapsed:
            content = nil
            width = PanelLimits.defaultWidth
            height = 0
        case .expanded(let app):
            if let app, let resolved = session.content(for: app) {
                content = resolved.view
                width = resolved.width
                height = resolved.height
            } else {
                // The placeholder is shell chrome, so it keeps the shell's own
                // default width even when the app it stands in for wants more.
                let card = placeholderView(for: app)
                content = card
                width = PanelLimits.defaultWidth
                height = HostPlaceholderView.panelHeight + surface.panelWingRowHeight
            }
        case .chat(let app):
            content = chatView(for: app)
            width = PanelLimits.defaultWidth
            // Chrome surfaces are laid out at a fixed height, so the exclusion
            // row is added on rather than measured — every surface starts below
            // the camera, not only the ones with an app behind them.
            height = ChatContentView.panelHeight + surface.panelWingRowHeight
        case .newApp:
            content = newAppView()
            width = PanelLimits.defaultWidth
            height = NewAppContentView.panelHeight + surface.panelWingRowHeight
        }

        // Before `present`, so the first layout of a newly-shown surface already
        // has the right zone content instead of flashing the previous app's.
        surface.setPanelWing(
            name: presentation.app.map { session.name(for: $0) },
            content: session.panelWing(for: presentation.app),
            canEdit: presentation.app != nil
        )
        surface.present(
            presentation,
            content: content,
            width: width,
            height: height,
            animated: animated
        )
        NSLog("[ledge] presenting %@", String(describing: presentation))
        if presentation.isExpanded {
            panel.orderFrontRegardless()
            focusCanvasIfNeeded(for: presentation.app)
        }
    }

    /// Hand first responder to the presented app's focusable canvas (spec §5
    /// `focusable`), so §4.1 `key` events flow the moment the panel opens rather
    /// than only after the user thinks to click the canvas.
    ///
    /// This is the one case where the notch takes key focus: a game needs the
    /// keyboard, and nothing else in the shell does. Panels without a focusable
    /// canvas are ordered front without ever becoming key, so the user's
    /// frontmost app keeps its insertion point.
    private func focusCanvasIfNeeded(for app: String?) {
        guard let app, let canvas = session.protocolRenderer.focusableCanvas(for: app) else {
            return
        }
        // `refresh` runs on every applied commit, and a game commits often —
        // re-making the same first responder would resign and re-become it
        // dozens of times a second, dropping key events in between.
        guard panel.firstResponder !== canvas else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
    }

    /// Hover or click on the collapsed notch: reopen the last app.
    private func openFromCollapsed() {
        guard !shellState.isExpanded else { return }
        toggleExpansion()
    }

    // MARK: - Chrome requests (spec §3.3)

    /// An app asked for something of the shell. Denials are silent, per §3.3 —
    /// an app cannot tell whether it was refused, so it cannot build on it.
    private func handleChrome(app: String, request: String, wing: WingSpec?) {
        switch request {
        case "expand":
            // The one genuine reason to refuse: there is nothing to show. An app
            // whose worker has not committed a tree (or crashed into an error
            // card) would open onto the placeholder, which is worse than not
            // opening at all — a monitor pinging expand at boot must not steal
            // the notch before the app can draw.
            guard session.content(for: app) != nil else { return }
            shellState.present(.expanded(app: app))
            refresh(animated: true)
        case "collapse":
            // Only the presented app may put the panel away; anything else would
            // let a background app close the panel out from under the user.
            guard shellState.presentedApp == app, shellState.isExpanded else { return }
            shellState.present(.collapsed)
            refresh(animated: true)
        case "attention":
            surface.flashAttention()
        case "wing":
            setWing(app: app, spec: wing)
        default:
            break                                   // unknown request → ignored
        }
    }

    /// Wing arbitration (spec §3.3 extension). There is one collapsed notch, so
    /// there is one wing: the latest app to ask for one takes it, and a release
    /// (`nil`) only lands if it comes from the app that currently holds it —
    /// otherwise a background app clearing its own wing would blank the wing of
    /// whichever app took over.
    private func setWing(app: String?, spec: WingSpec?) {
        if let spec, let app {
            wingOwner = app
            surface.setWing(spec)
            session.protocolRenderer.setWingTarget(
                app: spec.canvas == nil ? nil : app,
                id: spec.canvas?.id,
                view: surface.wingCanvasView
            )
            return
        }
        // A release. `app == nil` is the shell's own (disconnect); an app's own
        // release only counts if it is the owner.
        if let app, wingOwner != app { return }
        wingOwner = nil
        surface.setWing(nil)
        session.protocolRenderer.setWingTarget(app: nil, id: nil, view: surface.wingCanvasView)
    }

    // MARK: - Chrome surfaces

    private func chatView(for app: String) -> ChatContentView {
        if let chatSurface, chatSurface.app == app { return chatSurface.view }
        let view = ChatContentView(
            title: session.name(for: app),
            callbacks: ShellCallbacks(
                selectApp: { _ in },
                selectNewApp: {},
                selectSettings: {},
                toggleChat: { [weak self] in
                    guard let self else { return }
                    self.shellState.toggleChat()
                    self.refresh(animated: true)
                }
            )
        )
        chatSurface = (app, view)
        return view
    }

    private func newAppView() -> NewAppContentView {
        if let newAppSurface { return newAppSurface }
        let view = NewAppContentView(callbacks: .inert)
        newAppSurface = view
        return view
    }

    private func placeholderView(for app: String?) -> HostPlaceholderView {
        // Name the actual gap: a connected host with zero apps is not
        // "waiting for host", it's an empty registry.
        let phase: HostPlaceholderView.Phase = if !session.isConnected {
            .noHost
        } else if let app {
            .starting(app: session.name(for: app))
        } else {
            .noApps
        }
        if let placeholder, placeholder.phase == phase { return placeholder.view }
        let view = HostPlaceholderView(phase: phase)
        placeholder = (phase, view)
        return view
    }

    // MARK: - Geometry

    func reposition() {
        let screen = preferredScreen()
        let metrics = NotchMetrics.detect(for: screen)
        let limits = PanelLimits.detect(for: screen)
        surface.metrics = metrics
        surface.limits = limits
        session.limits = limits
        // The panel's total height includes the cutout exclusion row, and the
        // row is the cutout's own height — so the session, which measures app
        // trees, has to be told the same measurement the surface draws with.
        session.cutoutRowHeight = surface.panelWingRowHeight
        windowSize = limits.windowSize(for: metrics)
        NSLog(
            "[ledge] screen %@ safeTop %.1f metrics %.1f x %.1f panel max %.0f x %.0f window %.0f x %.0f",
            NSStringFromRect(screen.frame),
            screen.safeAreaInsets.top,
            metrics.closedWidth,
            metrics.closedHeight,
            limits.maxWidth,
            limits.maxHeight,
            windowSize.width,
            windowSize.height
        )
        // Not an animation — this is the only time the window frame ever moves,
        // and it moves at screen-configuration time, never during a gesture.
        panel.setFrame(
            CGRect(
                x: screen.frame.midX - windowSize.width / 2,
                y: screen.frame.maxY - windowSize.height,
                width: windowSize.width,
                height: windowSize.height
            ),
            display: true
        )
    }

    private func preferredScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
