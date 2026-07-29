import AppKit
import CoreGraphics
import LedgeShellCore
import QuartzCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Standard editing shortcuts, by hand.
    ///
    /// `LSUIElement` + a borderless non-activating panel means there is **no
    /// menu bar**, and on macOS the menu bar is what turns ⌘A / ⌘C / ⌘V / ⌘Z
    /// into actions — a text field does not implement them, it receives them.
    /// So in the editor's composer ⌘A did nothing at all, which reads as a
    /// broken text box rather than as a missing menu.
    ///
    /// Routed through the responder chain by selector, so the web view's text
    /// field, an `input` node in an app's tree, and anything else that edits
    /// text all get them for free.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let selector: Selector? = switch event.charactersIgnoringModifiers {
        case "a": #selector(NSText.selectAll(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "x": #selector(NSText.cut(_:))
        case "z": Selector(("undo:"))
        default: nil
        }
        if let selector, NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
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
    /// The peek surface. One instance reused across apps — there is one notch,
    /// so there is one mini, and the content is swapped rather than rebuilt.
    private let miniSurface = MiniContentView()
    /// Pending auto-dismiss for the mini currently on screen.
    private var miniDismiss: DispatchWorkItem?

    /// The editor (spec §8). **One instance, reused across apps** — there is one
    /// panel, so there is one editor, and a web view per app would mean a web
    /// content process per app for surfaces the user is not looking at.
    /// Switching apps is a message on the bridge (`EditorSurfaceView.present`).
    /// Created lazily: a shell that is never asked for the editor never pays for
    /// WebKit.
    private var editorSurface: EditorSurfaceView?
    /// Whether the panel is holding key focus for the editor. Tracked because
    /// taking it steals the user's insertion point, so releasing it has to be
    /// exactly as deliberate as taking it was.
    private var holdsEditorFocus = false
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
            guard let self, !self.shellState.presentation.isMini else { return false }
            guard let app = self.shellState.presentation.app else { return false }
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
        session.onChrome = { [weak self] app, request, wing, ms in
            self?.handleChrome(app: app, request: request, wing: wing, ms: ms)
        }
        // The builder stream (spec §3.6) has exactly one destination: the editor
        // surface for the app it names. Events for any other app are dropped by
        // the bridge, not queued — a transcript is per app, and a turn the user
        // cannot see is one the host is still recording anyway.
        session.onBuilder = { [weak self] payload in
            self?.editorSurface?.bridge.deliver(payload)
        }
        // The honest answer to "did that edit work" is the worker's, not the
        // agent's: an agent can finish a turn cleanly and leave an app that no
        // longer runs. Only the presented app's states colour the toggle.
        session.onAppState = { [weak self] app, state in
            guard let self, self.shellState.presentation.app == app else { return }
            switch state {
            case "started", "reloaded": self.surface.setBuildStatus(.reloaded)
            case "crashed": self.surface.setBuildStatus(.crashed)
            default: break              // `stopped` is not a build outcome
            }
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
        //
        // `reportedApp`, not `app`: a mini names its app but reports nothing,
        // because reporting is what tells a worker its panel opened. See
        // ShellPresentation.reportedApp.
        session.setPresented(presentation.reportedApp)

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
        case .mini(let app):
            // Borrow the app's live `<mini>` node. Nothing is rebuilt and the
            // worker is never asked anything, which is what makes a peek — and
            // a hover promoting one — instant.
            miniSurface.adopt(session.miniView(for: app))
            content = miniSurface
            let size = miniSurface.preferredSize(
                cutoutWidth: surface.metrics.closedWidth,
                maxWidth: surface.limits.maxWidth
            )
            width = size.width
            // Plus the cutout row: the surface hangs from the top of the screen,
            // so its first row is behind the camera like any other.
            height = size.height + surface.panelWingRowHeight
        case .chat(let app):
            content = editorView(for: app)
            width = PanelLimits.defaultWidth
            // Chrome surfaces are laid out at a fixed height, so the exclusion
            // row is added on rather than measured — every surface starts below
            // the camera, not only the ones with an app behind them.
            height = EditorSurfaceView.panelHeight + surface.panelWingRowHeight
        case .newApp:
            // The SAME editor, with no app behind it yet (spec §8: "`app` may
            // name a not-yet-existing id when coming from the [+] surface").
            // Two chat surfaces for one job would drift apart immediately, and
            // the old hand-drawn one had an inert composer and a preview box
            // that never previewed anything.
            content = editorView(for: "")
            width = PanelLimits.defaultWidth
            height = EditorSurfaceView.panelHeight + surface.panelWingRowHeight
        }

        // Before `present`, so the first layout of a newly-shown surface already
        // has the right zone content instead of flashing the previous app's.
        // The peek surface carries no chrome — no app name, no Edit (see
        // `PanelWingBarView`); its row is reserved but empty.
        surface.setPanelWing(
            name: presentation.isMini ? nil : presentation.app.map { session.name(for: $0) },
            content: presentation.isMini ? nil : session.panelWing(for: presentation.app),
            // Settings is the shell's own surface wearing an app's clothes — it
            // is in the catalog so the strip can show it, but there is no app
            // folder for an agent to edit. Offering Edit there promises
            // something that cannot work.
            canEdit: !presentation.isMini
                && presentation.app != nil
                && presentation.app != AppBarView.settingsAppID,
            showingEditor: presentation.isChat
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
        setEditorFocus(presentation.isChat)
    }

    /// Hold — or give back — key focus for the editor's text box.
    ///
    /// The panel is a borderless non-activating `NSPanel`, which is what lets it
    /// sit over everything without taking the user out of their work. Typing
    /// needs the opposite, so the editor is the second place in the shell that
    /// takes key (the first is a focusable canvas, above). Both must be
    /// reversible: taking key moves the insertion point out of whatever the user
    /// was writing in, and a notch that keeps it after the editor closes is a
    /// notch that ate their next sentence.
    private func setEditorFocus(_ wanted: Bool) {
        guard wanted != holdsEditorFocus else { return }
        holdsEditorFocus = wanted
        if wanted {
            panel.makeKeyAndOrderFront(nil)
            if let editorSurface { panel.makeFirstResponder(editorSurface.keyboardResponder) }
            return
        }
        // Dropping first responder is not enough — the panel would still be the
        // key window with nothing in it to type into. Deactivating hands key
        // back to the app the user was in; harmless when Ledge (an accessory
        // app) was never active to begin with.
        panel.makeFirstResponder(nil)
        NSApp.deactivate()
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

    /// Hover or click on the collapsed notch: reopen the last app — or, if a
    /// mini is on screen, open *that* app. Reaching for a peek means "tell me
    /// more about this", not "reopen whatever I had before".
    private func openFromCollapsed() {
        guard !shellState.isExpanded else { return }
        if shellState.presentation.isMini {
            miniDismiss?.cancel()
            miniDismiss = nil
            shellState.promoteMini()
            refresh(animated: true)
            return
        }
        toggleExpansion()
    }

    // MARK: - Chrome requests (spec §3.3)

    /// An app asked for something of the shell. Denials are silent, per §3.3 —
    /// an app cannot tell whether it was refused, so it cannot build on it.
    private func handleChrome(app: String, request: String, wing: WingSpec?, ms: Double?) {
        switch request {
        case "peek":
            peek(app: app, ms: ms)
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

    /// Default dwell when an app peeks without naming one. Matches the host's
    /// `DEFAULT_PEEK_MS`; duplicated rather than shared because the host clamps
    /// (policy about apps) and the shell defaults (policy about the surface).
    private static let defaultPeekSeconds: TimeInterval = 4

    /// `ctx.peek` (spec §3.3 extension): show the app's mini view for a moment.
    ///
    /// Refused, silently and in this order, when there is nothing to show, when
    /// the panel is already open, or when the app is not the one on screen.
    /// The second two matter most: a peek interrupting a panel the user is
    /// actively reading — or worse, replacing another app's panel — is a
    /// background app taking the screen, which is the thing the notch must never
    /// do. A peek is only ever an *escalation from collapsed*.
    private func peek(app: String, ms: Double?) {
        guard session.miniView(for: app) != nil else { return }
        switch shellState.presentation {
        case .collapsed:
            break
        case .mini:
            // Latest asker wins, exactly as with wings — the newest thing that
            // happened is the one worth showing.
            break
        case .expanded, .chat, .newApp:
            return
        }

        shellState.present(.mini(app: app))
        refresh(animated: true)

        let seconds = ms.map { $0 / 1000 } ?? Self.defaultPeekSeconds
        scheduleMiniDismiss(app: app, after: seconds)
    }

    /// Put the mini away when its dwell elapses — unless the user reached for it
    /// first, or another app took the surface (both checked in `dismissMini`).
    private func scheduleMiniDismiss(app: String, after seconds: TimeInterval) {
        miniDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Hovering holds it open: the user is looking at it, and pulling it
            // out from under them to then reopen on hover would flicker.
            guard !self.surface.isHovered else {
                self.scheduleMiniDismiss(app: app, after: 1)
                return
            }
            self.shellState.dismissMini(app: app)
            self.refresh(animated: true)
        }
        miniDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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

    private func editorView(for app: String) -> EditorSurfaceView {
        let view: EditorSurfaceView
        if let editorSurface {
            view = editorSurface
        } else {
            view = EditorSurfaceView()
            view.bridge.onInput = { [weak self] _, text, cancel in
                // The bridge names the app it is focused on; the session names
                // the app that is *presented*. Only the session's answer becomes
                // an envelope — see `HostSession.sendBuilderInput`.
                self?.session.sendBuilderInput(text: text, cancel: cancel)
            }
            // A new turn makes the last one's outcome stale: the toggle goes
            // back to neutral glass until the worker reloads or crashes again.
            view.onActivity = { [weak self] in self?.surface.setBuildStatus(.neutral) }
            editorSurface = view
        }
        view.present(app: app)
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
