import AppKit
import CoreGraphics
import LedgeShellCore
import QuartzCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// **The visit's horizontal swipe, read before anything else sees it.**
    ///
    /// Set by the panel controller to `ShellSurfaceView.translateScroll`. A
    /// scroll event is delivered to the deepest view under the cursor, so in a
    /// visit it lands in the app's tree — an NSScrollView, a focusable canvas,
    /// or the editor's WKWebView — and those consume it. The surface therefore
    /// never saw the gesture and the strip never walked, while `‹` and `›`, which
    /// are ordinary clicks, worked fine.
    ///
    /// Intercepting here is the only place that is *above* every one of those
    /// views. A flick that is not a horizontal walk is forwarded untouched, so
    /// an app's list and the transcript still scroll exactly as they did.
    var translateScroll: ((NSEvent) -> Bool)?

    /// True when this event is the visit's walk and must go no further. Split
    /// out from `sendEvent` because *what is consumed* is the decision worth
    /// asserting, and a test cannot watch `super.sendEvent` from outside.
    func consumesForWalk(_ event: NSEvent) -> Bool {
        event.type == .scrollWheel && translateScroll?(event) == true
    }

    override func sendEvent(_ event: NSEvent) {
        guard !consumesForWalk(event) else { return }
        super.sendEvent(event)
    }

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

    /// ⌘, during a visit (flow.md, Edges). Set by the panel controller.
    ///
    /// Reachable only while this panel holds key — it is a *non-activating*
    /// panel, so a ⌘, typed while another app is frontmost belongs to that app,
    /// and no amount of local monitoring changes that. The right-click menu is
    /// the path that always works; both triggers are in flow.md, and this one is
    /// the convenience.
    var onSettingsShortcut: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        if event.charactersIgnoringModifiers == ",", onSettingsShortcut?() == true {
            return true
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
    /// The gestures the surface reports upward, kept because the **parked**
    /// body needs exactly the same set: it is the same surface, so its wings
    /// walk the same strip and open the same ledge.
    private let callbacks: ShellCallbacks
    private var shellState = ShellState()
    private let session: HostSession

    /// **The interaction machine** (flow.md's Transitions table). This object
    /// owns the timers and turns effects into presentations; the machine owns
    /// the table. Everything that changes what is on screen goes through
    /// `send(_:)` or is followed by `machine.sync(to:)`, so the two can never
    /// disagree about which of the six states we are in.
    private var machine = InteractionMachine()

    /// Th — armed on pointer-in, disarmed on pointer-out or on any surface
    /// arriving. Fires exactly once per hover.
    private var thresholdTimer: DispatchWorkItem?
    /// Ti — an ambient notification's dwell. Never armed for an alert-class one.
    private var dwellTimer: DispatchWorkItem?
    /// Texit — the walk-away timeout. Re-armed on every change to the inhibitor
    /// state, so a keystroke or a drag genuinely stops it rather than merely
    /// making its expiry a no-op.
    private var exitTimer: DispatchWorkItem?
    /// A click anywhere outside Ledge closes the visit (flow.md). The panel is a
    /// non-activating borderless panel, so those clicks never reach a view of
    /// ours — a global monitor is the only place they exist.
    private var outsideClickMonitor: Any?

    /// The app that currently owns the collapsed notch (spec §3.3 extension).
    /// One notch, one wing: the latest app to ask wins, and only the owner can
    /// give it back.
    private var wingOwner: String?
    /// Ta — the wing holder's idleness timer (see `scheduleWingIdle`).
    private var wingIdleTimer: DispatchWorkItem?

    /// Chrome surfaces are rebuilt only when their app changes, so re-presenting
    /// one is a re-measure rather than a cross-fade.
    /// The swell surface — both swells. One instance reused across apps and
    /// across the notification/summary distinction: there is one notch, so there
    /// is one swell, and the content (and the chevron) is swapped rather than
    /// rebuilt.
    private let swellSurface = MiniContentView()

    /// Chat mode (spec §8, flow.md "Visit modes"). **One instance, reused across
    /// sessions** — there is one panel, so there is one conversation on screen,
    /// and a web view per app would mean a web content process per app for
    /// surfaces the user is not looking at. Switching sessions is a message on
    /// the bridge (`ChatSurfaceView.focus`). Created lazily: a shell that is
    /// never asked for chat never pays for WebKit.
    private var chatSurface: ChatSurfaceView?
    /// Session-global capability sent once when the host binds. The editor is
    /// lazy, so the event routinely arrives before there is a bridge to receive
    /// it; replay it when that bridge is eventually created.
    private var latestAgentStatus: BuilderPayload?
    /// Whether the panel is holding key focus for the editor. Tracked because
    /// taking it steals the user's insertion point, so releasing it has to be
    /// exactly as deliberate as taking it was.
    private var holdsEditorFocus = false
    private var placeholder: (phase: HostPlaceholderView.Phase, view: HostPlaceholderView)?
    /// The permission surface (see `permissionsView`). Lazy for the same reason
    /// the editor is: a shell nobody ever asks should not build one.
    private var permissionsSurface: PermissionsCardView?

    /// **The ledge** (flow.md, "The strip"). One instance, like the chat pane:
    /// there is one strip, so there is one shelf, and its slabs are rebuilt from
    /// the catalog on every present.
    private var overviewSurface: OverviewSurfaceView?
    /// What **Back** returns to: the surface the overview was zoomed out of.
    /// Held here rather than derived, because "the session that was showing"
    /// includes which *mode* it was in — walking out of a chat and back into a
    /// stage would be the overview quietly changing something.
    private var overviewOrigin: ShellPresentation?

    /// What the last `refresh` drew — the seam that makes "entering chat" a
    /// detectable transition. Entering always reopens the transcript (G2.6):
    /// the ⌄ peek is state *inside* one chat visit, never carried into the
    /// next one.
    private var lastRefreshedPresentation: ShellPresentation = .collapsed

    /// **Parked** (flow.md, States). The window and its body, or nil when the
    /// surface is where it belongs. Everything that asks "is the visit on the
    /// notch or in a window" asks this.
    private var parked: (window: ParkedWindow, view: ParkedSurfaceView)?
    /// **One position for Ledge, not one per session.** The corner the user
    /// dropped the window at, held for as long as the window exists: walking the
    /// strip inside it changes the session and the size, never the place. It is
    /// deliberately not persisted across launches — the only way to park is to
    /// pull the surface off the notch, and that gesture always puts the window
    /// under the pointer, so a remembered corner would never be consulted.
    private var parkedCorner: CGPoint?
    /// Watches the parked window move (G2.8). Two jobs: keep `parkedCorner`
    /// honest when the *system* drags the window (its glass is
    /// `isMovableByWindowBackground`, so moves happen entirely outside this
    /// object — the stale corner was why a strip walk teleported the window
    /// back to the tear's first drop point), and notice a drop at the notch.
    private var parkedMoveObserver: NSObjectProtocol?
    /// True while `setParkedFrame` is the one moving the window, so the
    /// observer only reacts to the user's own drags.
    private var movingParkedProgrammatically = false
    /// The release-poll for "dropped at the notch" (G2.8: dragging the window
    /// back to the notch flies it home).
    private var flyHomePoll: DispatchWorkItem?
    /// The parked window's own dwell timer. The notch's `dwellTimer` belongs to
    /// a swell that is a *presentation*; the parked band is not one (see
    /// `notifyParked`), so it cannot share the machine's timer.
    private var parkedSwellTimer: DispatchWorkItem?

    /// The two-item menu (flow.md, Edges: "right-click any Ledge glass → native
    /// menu (Settings…, Quit Ledge)"). Built once and kept: it is the same menu
    /// on the pill, on a wing and on the panel's chrome, and an NSMenu rebuilt
    /// per right-click loses its highlight mid-track.
    private lazy var ledgeMenu: NSMenu = {
        let menu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(menuOpenSettings),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ledge", action: #selector(menuQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }()

    /// Settings is a **native macOS window** (flow.md, Edges: "configuration
    /// doesn't belong on glass"). It was an app in the strip; it is furniture
    /// now, and furniture belongs in a window. See `SettingsWindowController`.
    @objc private func menuOpenSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// ⌘, (flow.md, Edges).
    ///
    /// No longer gated on being in a visit. The old gate existed because
    /// Settings *was* a visit, so opening it from the collapsed pill made no
    /// sense; a window can be opened from anywhere, and a shortcut that works
    /// only in one of the shell's states is a shortcut nobody trusts.
    ///
    /// It still only fires while Ledge's panel holds key — the panel is
    /// non-activating, so a ⌘, typed into another app belongs to that app, and
    /// it should. The right-click menu is the path that always works.
    @discardableResult
    func handleSettingsShortcut() -> Bool {
        openSettings()
        return true
    }

    /// **One reading of the system, two surfaces.**
    ///
    /// The permission rows appear in the first-run card on the panel *and* in
    /// the Settings window. They are two views — a view cannot be in two windows
    /// at once, and reparenting one between them is exactly the class of bug
    /// that made the chat stage go black — but they share this probe, so they
    /// can never disagree about whether Ledge has Accessibility.
    ///
    /// Lazy because constructing it reads TCC, and a headless test that only
    /// wants a panel controller should not be asking macOS about the camera.
    private lazy var permissionProbe: PermissionProbing = SystemPermissionProbe()

    /// The window is built once and kept. Opening it again brings the same one
    /// forward, which is what every other settings window on the machine does.
    private lazy var settingsWindow = SettingsWindowController(
        session: session,
        probe: permissionProbe,
        onQuit: { NSApp.terminate(nil) }
    )

    private func openSettings() {
        settingsWindow.show()
    }

    // MARK: - Test seams

    /// The menu, for the assertion that it is exactly two items. Built lazily,
    /// so asking for it is also what proves it can be built at all.
    var contextMenuForTesting: NSMenu { ledgeMenu }
    func openSettingsForTesting() { openSettings() }
    /// The `‹|›` beads' own path, without synthesising a click on a bead in a
    /// window that does not exist headlessly. `-1` is `‹`, `+1` is `›` — the
    /// same signs the callback uses.
    func walkForTesting(_ steps: Int) { walk(steps) }
    /// The left bead: lower the glass, or raise it.
    func toggleChatForTesting() {
        shellState.toggleChat()
        machine.sync(to: shellState.presentation)
        refresh(animated: false)
    }
    /// The real window, so the swipe's *routing* can be asserted end to end —
    /// the bug was never in the recognizer, it was in who saw the event first.
    var panelForTesting: NSPanel { panel }
    var surfaceForTesting: ShellSurfaceView { surface }
    /// The parked window's body, or nil while the surface is on the notch. The
    /// tear itself needs a live drag, so the seam is one step in: tests park
    /// through `parkForTesting`, which is the same call the drag makes once it
    /// has crossed the threshold.
    var parkedSurfaceForTesting: ParkedSurfaceView? { parked?.view }
    var parkedWindowForTesting: NSWindow? { parked?.window }
    func parkForTesting(at topLeft: CGPoint = CGPoint(x: 400, y: 400)) {
        tearOff(to: topLeft)
    }

    /// The drop-at-the-notch predicate, for the tests: the poll and the mouse
    /// button are wall-clock and hardware, but the geometry is just geometry.
    var parkedWindowIsAtTheNotchForTesting: Bool { parkedWindowIsAtTheNotch }

    var overviewForTesting: OverviewSurfaceView? { overviewSurface }

    init(session: HostSession) {
        self.session = session
        var selectApp: ((String) -> Void)!
        var selectNewApp: (() -> Void)!
        var toggleChat: (() -> Void)!
        var walkStrip: ((Int) -> Void)!
        var showOverview: (() -> Void)!
        var parkNow: (() -> Void)!
        let callbacks = ShellCallbacks(
            selectApp: { app in selectApp(app) },
            selectNewApp: { selectNewApp() },
            toggleChat: { toggleChat() },
            walkStrip: { steps in walkStrip(steps) },
            showOverview: { showOverview() },
            park: { parkNow() },
            // Quit is the shell's, not a session's: it terminates the whole
            // process, host and all (the app delegate tears the host down in
            // `applicationWillTerminate`).
            quit: { NSApp.terminate(nil) }
        )
        self.callbacks = callbacks
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
            self.machine.sync(to: self.shellState.presentation)
            self.refresh(animated: true)
        }
        selectNewApp = { [weak self] in self?.present(.newApp) }
        toggleChat = { [weak self] in
            guard let self else { return }
            // One bead, three words (`PanelWingBarView.Mode`). In the overview
            // it reads **Back** and it goes back; everywhere else it lowers the
            // glass onto the conversation or raises it again.
            guard self.shellState.presentation != .overview else {
                self.leaveOverview()
                return
            }
            self.shellState.toggleChat()
            self.machine.sync(to: self.shellState.presentation)
            self.refresh(animated: true)
        }
        walkStrip = { [weak self] steps in self?.walk(steps) }
        // The `|` between `‹` and `›`: **the ledge** (flow.md, "The strip").
        showOverview = { [weak self] in self?.enterOverview() }
        // The tear bead beside `‹|›` (G2.7): the drag's clickable invitation.
        parkNow = { [weak self] in self?.parkFromButton() }

        surface.onPointerInside = { [weak self] inside in self?.pointerChanged(inside: inside) }
        surface.onClick = { [weak self] in self?.clicked() }
        surface.onEscape = { [weak self] in self?.send(.escape) }
        // "Visit | drag the panel down off the notch | Parked". The machine says
        // whether it parks; these three say *where*.
        surface.onTearBegan = { [weak self] topLeft in self?.tearOff(to: topLeft) }
        surface.onTearMoved = { [weak self] topLeft in self?.moveParked(to: topLeft) }
        surface.onTearEnded = { [weak self] in self?.settleParked() }
        surface.onSwipe = { [weak self] direction in self?.handleSwipe(direction) }
        surface.contextMenu = { [weak self] in self?.ledgeMenu }

        // The drop shelf (INTAKE): a file dropped on the open panel becomes an
        // app-level `drop` event for whatever app is on screen. Presentation
        // decides the addressee, so the answer lives here rather than in the
        // surface — the surface only knows it is expanded.
        surface.canAcceptDrop = { [weak self] in
            guard let self, !self.shellState.presentation.isSwell else { return false }
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
        session.onChrome = { [weak self] app, request, wing, ms, priority in
            self?.handleChrome(
                app: app,
                request: request,
                wing: wing,
                ms: ms,
                priority: priority
            )
        }
        // The builder stream (spec §3.6) has exactly one destination: the editor
        // surface for the app it names. Events for any other app are dropped by
        // the bridge, not queued — a transcript is per app, and a turn the user
        // cannot see is one the host is still recording anyway.
        session.onBuilder = { [weak self] payload in
            guard let self else { return }
            if payload.event == "agent" { self.latestAgentStatus = payload }
            self.chatSurface?.bridge.deliver(payload)
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
            self.present(.expanded(app: app))
        }
        // "Interruption | click the action | the action runs" — and then the
        // swell goes away. The action is an ordinary `button` in the app's
        // borrowed node, so AppKit has already given it the click and the
        // renderer has already put the §4.1 event on the wire; all the shell
        // learns is that one left. That is enough to tell this row of the table
        // apart from "click elsewhere", which reaches the surface instead.
        session.onNodeEvent = { [weak self] app, name in
            guard let self, name == "click" else { return }
            guard case .mini(let owner) = self.shellState.presentation, owner == app else { return }
            self.send(.click(.notificationAction))
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
        panel.onSettingsShortcut = { [weak self] in self?.handleSettingsShortcut() ?? false }
        // Ahead of the app's own views: see `NotchPanel.translateScroll`.
        panel.translateScroll = { [weak self] event in
            self?.surface.translateScroll(event) ?? false
        }
    }

    func start() {
        reposition()
        refresh(animated: false)
        panel.orderFrontRegardless()
        // The one time Ledge opens itself without being asked. It is worth it
        // exactly once: the alternative is that the first consent dialog the
        // user ever sees arrives unannounced, in the middle of something else,
        // attributed to an app they installed ten seconds ago — and TCC never
        // asks a second time. Marked as done on *presentation*, so this is once
        // ever and never blocks anything (see `PermissionsCardView`).
        guard !LedgeInstall.hasOnboarded else { return }
        LedgeInstall.markOnboarded()
        presentPermissions()
    }

    /// The chrome request (spec §3.3) an app can send to ask for the permission
    /// surface — and which is **refused, from every app, always** (see
    /// `handleChrome`).
    ///
    /// It is kept as a named constant rather than deleted because the refusal is
    /// the interesting part: chrome is not app content, and an app that could
    /// raise an official-looking permission panel at a moment of its choosing is
    /// the ambush the surface exists to prevent. Settings was the one holder of
    /// an exception here; it is a window now and asks the shell directly, so the
    /// exception is gone rather than inherited by somebody else.
    static let permissionsChromeRequest = "permissions"

    /// Show the permission surface on the panel.
    ///
    /// Two callers, both the shell's own: first run (once, ever), and nothing
    /// else. The way back afterwards is the Settings window, which does not come
    /// through here at all — it hosts its own `PermissionsCardView` over the
    /// same probe, because a view cannot be in two windows at once.
    func presentPermissions() {
        present(.permissions)
    }

    /// Why there is no host, as the placeholder should say it. Set by the app
    /// delegate from `HostProcess` — the shell cannot work it out for itself,
    /// and the previous answer (a developer's shell command, in every build)
    /// was wrong for everyone who had not built Ledge from source.
    var hostDetail: String = "Starting…" {
        didSet {
            guard hostDetail != oldValue, !session.isConnected else { return }
            // The card is rebuilt only when its phase changes, and the phase now
            // carries this string — so changing it has to force a re-present.
            placeholder = nil
            refresh(animated: false)
        }
    }

    func present(_ presentation: ShellPresentation, animated: Bool = true) {
        shellState.present(presentation)
        machine.sync(to: presentation)
        refresh(animated: animated)
    }

    /// What the notch is showing. A read-only window onto state this object
    /// owns — the shell state itself stays private, because everything that
    /// *changes* it goes through `present`/`refresh` so the surface is never
    /// left describing a presentation that is no longer on screen.
    var presentation: ShellPresentation { shellState.presentation }

    func toggleExpansion() {
        shellState.toggleExpansion()
        machine.sync(to: shellState.presentation)
        refresh(animated: true)
    }

    /// Which of the six states the machine believes it is in. Read by tests and
    /// by the log line; nothing changes it from outside.
    var interactionState: InteractionMachine.State { machine.state }

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
        // Who drew the well, which is what decides whether a right-click there
        // is Ledge's or somebody else's (`ShellSurfaceView.contextMenu(at:)`).
        // Shell by default: the menu is the only route to Settings and to Quit,
        // so anything the shell painted itself answers.
        var owner = ShellSurfaceView.ContentOwner.shell
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
                owner = .app
            } else {
                // The placeholder is shell chrome, so it keeps the shell's own
                // default width even when the app it stands in for wants more.
                let card = placeholderView(for: app)
                content = card
                width = PanelLimits.defaultWidth
                height = HostPlaceholderView.panelHeight + surface.panelWingRowHeight
            }
        case .mini(let app), .summary(let app):
            // Borrow the app's live `<mini>` / `<summary>` node. Nothing is
            // rebuilt and the worker is never asked anything, which is what
            // makes a swell — and a click promoting one — instant.
            //
            // The chevron is the shell's, and only the summary gets one: a
            // notification promises nothing (flow.md, §03).
            swellSurface.setShowsOpenAffordance(presentation.isSummary)
            swellSurface.adopt(
                presentation.isSummary
                    ? session.summaryView(for: app)
                    : session.miniView(for: app)
            )
            content = swellSurface
            let size = swellSurface.preferredSize(
                cutoutWidth: surface.metrics.closedWidth,
                maxWidth: surface.limits.maxWidth
            )
            width = size.width
            // Plus the cutout row: the surface hangs from the top of the screen,
            // so its payload sits strictly below the camera (principle 7).
            height = size.height + surface.panelWingRowHeight
        case .chat(let app):
            // **The stage stays mounted.** Chat is a mode of the visit, not
            // another page: the session's live tree goes on rendering behind the
            // pane, one step back and untouchable, and the conversation about it
            // floats over it (flow.md, "Visit modes").
            let stage = session.content(for: app)
            let chat = chatView(for: app)
            // Arriving from anywhere that is not chat, the conversation is
            // showing — a transcript collapsed on the way out stays collapsed
            // only within its own visit (G2.6).
            if !lastRefreshedPresentation.isChat { chat.showTranscript() }
            chat.setStage(stage?.view, height: max(0, (stage?.height ?? 0) - session.chromeHeight))
            content = chat
            // The pane is a web view with a composer in it: right-clicking a
            // half-typed sentence must give you Cut/Copy/Paste, not Quit Ledge.
            owner = .app
            // **The pane is the app plus its stated margins** (Manu's G2.7 size
            // law): the session's own width with `stagePad` of glass each side
            // — the stage is unscaled, so the margin is real air, not leftover
            // scale. Capped by the screen, because the chrome is the pane's
            // own and the app's declared cap only ever measured its stage.
            let size = session.panelSize(for: app)
            width = min(
                size.width + ChatSurfaceView.stagePad * 2,
                surface.limits.maxWidth
            )
            height = min(
                ChatSurfaceView.panelHeight(
                    stageHeight: stage.map { max(0, $0.height - session.chromeHeight) }
                ) + session.chromeHeight,
                surface.limits.maxHeight
            )
        case .newApp:
            // The SAME surface, with no session behind it yet (spec §8: "`app`
            // may name a not-yet-existing id when coming from the [+] surface").
            // A blank slot has no stage: chat only, full pane (flow.md).
            let chat = chatView(for: "")
            chat.setStage(nil, height: 0)
            content = chat
            owner = .app
            width = PanelLimits.defaultWidth
            height = ChatSurfaceView.panelHeight(stageHeight: nil) + surface.panelWingRowHeight
        case .permissions:
            // The one chrome surface that measures itself: a row grows a line
            // when its status has something to say, so the panel's height is a
            // function of what macOS currently reports (see `PermissionsCardView`).
            let card = permissionsView()
            content = card
            width = PanelLimits.defaultWidth
            height = card.panelHeight + surface.panelWingRowHeight
        case .overview:
            // **The ledge**: the strip, all of it, as a grid of cards. Shell
            // chrome — so the shell's own width, and a height that is a
            // function of the strip: a grid does not scroll, it grows a row.
            // `overviewOrigin` is where Back points, so `current` is the same
            // fact asked a second way rather than a second copy of it.
            let grid = overviewView()
            grid.apply(cards: overviewCards(), current: overviewOrigin?.app)
            content = grid
            width = PanelLimits.defaultWidth
            height = OverviewSurfaceView.panelHeight(count: grid.cards.count)
                + surface.panelWingRowHeight
        }

        let mode: PanelWingBarView.Mode = if presentation == .overview {
            .overview
        } else if presentation.isChat {
            .editor
        } else {
            .stage
        }
        // No glass to lower on a surface with no stage behind it: the blank slot
        // is chat-only (flow.md), and the placeholder and the permission card
        // have no session at all. The overview always shows the bead, because
        // there it is Back.
        //
        // Settings used to be the one *app* excepted here — in the catalog so
        // the strip could reach it, but with no folder for an agent to edit. It
        // is a window now, so every app in the strip is a real app with a real
        // folder, and the exception is gone with it.
        let canToggleGlass = presentation == .overview || presentation.app != nil

        // **Whichever body is on screen.** Parked, the visit lives in a window
        // and the notch shows the bare pill; everything above this line is the
        // same either way, because what is presented does not depend on where.
        if let parked {
            parked.view.rowHeight = surface.panelWingRowHeight
            parked.view.cutoutWidth = surface.metrics.closedWidth
            parked.view.setBodyMaterial(presentation.isConversation ? .chatGlass : .solid)
            parked.view.setPanelWing(mode: mode, canToggleGlass: canToggleGlass)
            parked.view.present(presentation, content: content, animated: animated)
            // Floored like the notch's own silhouette (G2.5/G2.8): the window
            // carries the same islands with the same notch-sized gap between
            // them, so it can never be narrower than they are.
            resizeParked(width: max(width, surface.visitBarWidth), height: height)
            surface.setContentOwner(.shell)
            surface.present(.collapsed, content: nil, height: 0, animated: animated)
        } else {
            // Before `present`, so the first layout of a newly-shown surface
            // already has the right controls instead of flashing the previous
            // mode's. A swell carries no chrome at all — its row is reserved but
            // empty.
            surface.setContentOwner(owner)
            // Chat lowers the glass onto the stage, and the body says so: opaque
            // at the top, all but clear at the bottom (flow.md, Material).
            surface.setBodyMaterial(presentation.isConversation ? .chatGlass : .solid)
            surface.setPanelWing(mode: mode, canToggleGlass: canToggleGlass)
            surface.present(
                presentation,
                content: content,
                width: width,
                height: height,
                animated: animated
            )
        }
        NSLog(
            "[ledge] presenting %@ (%@)",
            String(describing: presentation),
            machine.state.rawValue
        )
        // The permission surface watches the system while it is up — a status
        // can change in System Settings behind our back — and must stop the
        // moment it is not, or it polls TCC forever for a panel nobody sees.
        permissionsSurface?.setActive(presentation == .permissions)
        if let parked {
            // The window is where the keyboard lives now: the notch behind it is
            // a bare pill with nothing in it to type into.
            parked.window.orderFrontRegardless()
            if presentation.isConversation, let chatSurface {
                parked.window.makeKeyAndOrderFront(nil)
                parked.window.makeFirstResponder(chatSurface.keyboardResponder)
            } else if
                let app = presentation.app,
                let canvas = session.protocolRenderer.focusableCanvas(for: app),
                parked.window.firstResponder !== canvas
            {
                parked.window.makeKeyAndOrderFront(nil)
                parked.window.makeFirstResponder(canvas)
            }
        } else if presentation.isExpanded {
            panel.orderFrontRegardless()
            // Never in chat: "keyboard: in chat it is always in the pill"
            // (flow.md). A focusable canvas behind the pane is part of the
            // inert stage, and handing it first responder — even for the
            // instant before `setEditorFocus` takes it back — is the same bug
            // as letting it take a click.
            if !presentation.isConversation {
                focusCanvasIfNeeded(for: presentation.app)
            }
        }
        // Never while parked: the notch panel taking key for a surface that is
        // not in it would put the insertion point in an empty pill.
        setEditorFocus(parked == nil && presentation.isConversation)
        // Every arrival changes at least one of the inhibitors (the editor came
        // or went; a swell replaced the visit), so the walk-away timer is
        // re-decided here rather than only when the pointer moves.
        rearmExitTimer()
        updateOutsideClickMonitor()
        lastRefreshedPresentation = presentation
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
            if let chatSurface { panel.makeFirstResponder(chatSurface.keyboardResponder) }
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

    // MARK: - The interaction machine (flow.md's Transitions table)

    /// Feed one event to the machine and carry out whatever it decides.
    ///
    /// The single door. Nothing below this line changes what is on screen by
    /// hand; every path either calls this or calls `machine.sync(to:)` right
    /// after presenting something the table has no row for (an app's
    /// `ctx.expand`, the first-run permission card).
    private func send(_ event: InteractionMachine.Event) {
        for effect in machine.apply(event) { perform(effect) }
    }

    private func perform(_ effect: InteractionMachine.Effect) {
        switch effect {
        case .promise:
            surface.setPromise(true)
        case .unpromise:
            surface.setPromise(false)

        case .showSummary(let app):
            cancelDwell()
            shellState.present(.summary(app: app))
            refresh(animated: true)

        case .showNotification(let app, let dwell):
            shellState.present(.notification(app: app))
            refresh(animated: true)
            // Ti, and only for ambient class: an alert holds until it is acted
            // on (flow.md). Not arming the timer is the implementation of that
            // sentence; the machine refuses a stray one as well.
            guard let dwell else {
                cancelDwell()
                return
            }
            scheduleDwell(app: app, after: dwell)

        case .retractSwell:
            cancelDwell()
            shellState.present(.collapsed)
            refresh(animated: true)

        case .openVisit(let app):
            cancelDwell()
            surface.setPromise(false)
            if let app, app != shellState.lastPresentedApp {
                shellState.selectApp(app, reselectOpensChat: false)
            } else {
                // The remembered session comes back the way it was left —
                // chat reopens as chat (G2.6, `ShellState.reopenVisit`).
                shellState.reopenVisit()
            }
            refresh(animated: true)

        case .runNotificationAction:
            // The action itself is an ordinary `button` in the app's borrowed
            // node, so it has already run by the time this lands — AppKit gave
            // the click to that button and the renderer put a §4.1 event on the
            // wire. What is left is to get out of the way.
            break

        case .closeVisit:
            shellState.present(.collapsed)
            refresh(animated: true)

        case .walkStrip(let steps):
            walk(steps)

        case .park:
            // The window is stood up by `tearOff`, which is the only thing that
            // knows where the pointer is. This is everything else that changes
            // when the surface leaves the notch.
            break

        case .flyHome(let app):
            flyHome(app: app)

        case .leaveOverview:
            leaveOverview()
        }
    }

    // MARK: - The ledge (flow.md, "The strip")

    /// Zoom out: the strip becomes a grid of cards. Remembers what it zoomed
    /// out *of*, because that is what **Back** means.
    func enterOverview() {
        guard shellState.presentation != .overview else { return }
        overviewOrigin = shellState.presentation
        present(.overview)
    }

    /// **Back** — the left wing's bead, and Esc. Returns to the session that was
    /// showing, in the mode it was showing in; falls back to the last app when
    /// the overview was entered from somewhere that no longer exists (its
    /// session was stopped from the shelf, say).
    func leaveOverview() {
        guard shellState.presentation == .overview else { return }
        let origin = overviewOrigin
        overviewOrigin = nil
        guard let origin, origin != .overview, isStillReachable(origin) else {
            present(.expanded(app: shellState.lastPresentedApp))
            return
        }
        present(origin)
    }

    /// Whether a remembered surface is still somewhere to go back to. Only the
    /// app-bearing ones can go stale, and they go stale exactly when the ✕ on
    /// the ledge stopped them.
    private func isStillReachable(_ presentation: ShellPresentation) -> Bool {
        guard let app = presentation.app else { return true }
        return session.strip.apps.contains(app)
    }

    /// The grid's contents: the strip, in strip order, with the one blank slot
    /// last (`SessionStrip.slots`). The icons are the catalog's, which are SF
    /// Symbol names already (spec §3.6).
    private func overviewCards() -> [OverviewSurfaceView.Card] {
        session.strip.slots.map { slot in
            switch slot {
            case .app(let app):
                OverviewSurfaceView.Card(
                    app: app,
                    name: session.name(for: app),
                    icon: session.icon(for: app)
                )
            case .blank:
                .blank
            }
        }
    }

    private func overviewView() -> OverviewSurfaceView {
        if let overviewSurface { return overviewSurface }
        let grid = OverviewSurfaceView()
        grid.onSelect = { [weak self] app in
            guard let self else { return }
            // "Click jumps": that session takes the stage, and the zoom-out is
            // over — so the origin goes with it.
            self.overviewOrigin = nil
            if let app {
                self.shellState.selectApp(app, reselectOpensChat: false)
                self.machine.sync(to: self.shellState.presentation)
                self.refresh(animated: true)
            } else {
                self.present(.newApp)
            }
        }
        grid.onStop = { [weak self] app in self?.stopSession(app) }
        overviewSurface = grid
        return grid
    }

    /// **The only ✕ in the product** (flow.md, "The strip"). It stops the app's
    /// session — the worker is torn down by the host — and leaves the app
    /// installed: the same path Settings' switch takes, because "this app is not
    /// running" is one fact and it must not have two answers.
    func stopSession(_ app: String) {
        NSLog("[ledge] stop session '%@' <- the ledge", app)
        session.stopApp(app)
        // Back must not aim at a session that is being torn down.
        if overviewOrigin?.app == app { overviewOrigin = nil }
        shellState.forget(app)
    }

    // MARK: - Parked (flow.md, States: the window)

    /// Whether the surface is currently a window rather than the notch's panel.
    var isParked: Bool { parked != nil }

    /// **The tear.** The drag crossed the threshold: the machine parks, and the
    /// body stands up under the pointer at exactly the size the panel was.
    private func tearOff(to topLeft: CGPoint) {
        guard parked == nil, shellState.isExpanded else { return }
        let shape = surface.currentShapeRect
        // The glass the user was looking at, minus the fillets (notch
        // furniture): since G2.5 the silhouette is floored at the islands'
        // span, and the window keeps that floor — the same islands, the same
        // notch-sized gap between them (G2.8).
        let size = CGSize(
            width: max(PanelLimits.minWidth, shape.width - ShellSurfaceView.fillet * 2),
            height: max(PanelLimits.minHeight, shape.height)
        )
        send(.dragOffNotch)
        guard machine.state == .parked else { return }

        let view = ParkedSurfaceView(callbacks: callbacks)
        view.onFlyHome = { [weak self] in self?.send(.flyHome) }
        let window = ParkedWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isFloatingPanel = true
        window.backgroundColor = .clear
        window.isOpaque = false
        // The glass casts its own shadow (`LedgeShadow.window`), drawn into the
        // body's layer like every other Ledge surface. AppKit's window shadow
        // would be a rectangle around a rounded body.
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // "Fixed size, any position" (flow.md, §04): moved by dragging its glass,
        // never resized — there are no handles, and the size is the session's.
        window.isMovableByWindowBackground = true
        window.level = panel.level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        parked = (window, view)
        // The window's glass is `isMovableByWindowBackground`: the user's own
        // drags happen entirely inside the system, and this is the only seam
        // that hears about them (G2.8 — the stale-corner teleport, and the
        // drop-at-the-notch fly-home).
        parkedMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.parkedWindowMoved() }
        }

        // Wings pause the moment the surface leaves (flow.md: "wings pause").
        surface.setWing(nil, animated: false)
        setParkedFrame(topLeft: topLeft, size: size)
        window.orderFrontRegardless()
        refresh(animated: false)
        NSLog("[ledge] parked at %@", NSStringFromPoint(topLeft))
    }

    /// The tear bead (G2.7): park without the drag. The window stands up one
    /// step down-and-right of where the surface is — so it visibly comes *off*
    /// the notch rather than appearing somewhere — then settles on-screen the
    /// way a released drag does.
    private func parkFromButton() {
        guard !isParked, shellState.isExpanded, let window = surface.window else { return }
        let shape = surface.currentShapeRect
        let corner = window.convertPoint(
            toScreen: surface.convert(CGPoint(x: shape.minX, y: shape.minY), to: nil)
        )
        tearOff(to: CGPoint(x: corner.x + 24, y: corner.y - 48))
        settleParked()
    }

    private func moveParked(to topLeft: CGPoint) {
        guard let parked else { return }
        setParkedFrame(topLeft: topLeft, size: parked.window.frame.size)
    }

    private func setParkedFrame(topLeft: CGPoint, size: CGSize) {
        guard let parked else { return }
        parkedCorner = topLeft
        movingParkedProgrammatically = true
        parked.window.setFrame(
            CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
            display: true
        )
        movingParkedProgrammatically = false
    }

    /// The parked window moved. Ours (`setParkedFrame`) is already accounted
    /// for; the user's own background-drag is the case this exists for.
    private func parkedWindowMoved() {
        guard let parked, !movingParkedProgrammatically else { return }
        let frame = parked.window.frame
        // One position for Ledge, and it is wherever the user just put it.
        parkedCorner = CGPoint(x: frame.minX, y: frame.maxY)
        // Dropped at the notch, it flies home (G2.8). "Dropped" is when the
        // fingers let go, which the system's drag never tells us — so poll the
        // button, briefly, only while a candidate drop is in the air.
        scheduleFlyHomeCheck()
    }

    private func scheduleFlyHomeCheck() {
        guard flyHomePoll == nil else { return }
        pollFlyHomeOnRelease()
    }

    private func pollFlyHomeOnRelease() {
        flyHomePoll = nil
        guard parked != nil else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            let work = DispatchWorkItem { [weak self] in self?.pollFlyHomeOnRelease() }
            flyHomePoll = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            return
        }
        if parkedWindowIsAtTheNotch { send(.flyHome) }
    }

    /// Whether the parked window has been carried back to the notch: hard
    /// against the top of the usable screen, with the cutout within its reach.
    /// The system constrains a background-drag below the menu bar, so "at the
    /// top" is the visible frame's ceiling, not the screen's.
    private var parkedWindowIsAtTheNotch: Bool {
        guard let parked, let screen = parked.window.screen ?? NSScreen.main else { return false }
        let frame = parked.window.frame
        guard frame.maxY >= screen.visibleFrame.maxY - 8 else { return false }
        let cutout = surface.metrics.closedWidth
        let reach = (screen.frame.midX - cutout / 2 - 40)...(screen.frame.midX + cutout / 2 + 40)
        return frame.maxX >= reach.lowerBound && frame.minX <= reach.upperBound
    }

    /// The fingers let go. Whatever corner they left it at is the window's
    /// position from now on — except a corner that is off the screen, which is
    /// a window the user cannot reach: it slides back into view rather than
    /// being left where a slip put it.
    private func settleParked() {
        guard let parked, let screen = parked.window.screen ?? NSScreen.main else { return }
        let frame = parked.window.frame
        let visible = screen.visibleFrame
        let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        let y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        guard abs(x - frame.minX) > 0.5 || abs(y - frame.minY) > 0.5 else {
            parkedCorner = CGPoint(x: frame.minX, y: frame.maxY)
            return
        }
        setParkedFrame(topLeft: CGPoint(x: x, y: y + frame.height), size: frame.size)
    }

    /// A session with a panel of its own size walked into the window: the
    /// window is fixed-size *per session*, so it takes that size — growing
    /// downward from `parkedCorner`, the corner the user put it at, which is the
    /// one thing about a parked window that never changes (flow.md: "fixed
    /// size, any position").
    private func resizeParked(width: CGFloat, height: CGFloat) {
        guard let parked else { return }
        let frame = parked.window.frame
        guard abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 else { return }
        setParkedFrame(
            topLeft: parkedCorner ?? CGPoint(x: frame.minX, y: frame.maxY),
            size: CGSize(width: width, height: height)
        )
    }

    /// **Fly home** (flow.md: "Parked | ⌃, or click the bare notch | Visit").
    ///
    /// The window travels back into the notch — shrinking and arcing toward it
    /// on `LedgeMotion.travel` with the settle character, because a return never
    /// overshoots — and the visit lands where it left. Reduce Motion fades it.
    private func flyHome(app: String?) {
        guard let parked else { return }
        self.parked = nil
        parkedSwellTimer?.cancel()
        parkedSwellTimer = nil
        if let parkedMoveObserver { NotificationCenter.default.removeObserver(parkedMoveObserver) }
        parkedMoveObserver = nil
        flyHomePoll?.cancel()
        flyHomePoll = nil
        // The content is about to be reparented into the notch panel by the
        // refresh below; the shrinking window must stop laying it out (G2.4 —
        // the fly-home render bug).
        parked.view.abandonContent()

        // The visit re-presents in the notch *first*, so the surface the window
        // is flying toward is already the one that will be there when it lands.
        if let app {
            shellState.selectApp(app, reselectOpensChat: false)
        } else if !shellState.isExpanded {
            shellState.present(.expanded(app: shellState.lastPresentedApp))
        }
        refresh(animated: true)

        let window = parked.window
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = LedgeMotion.fast
                window.animator().alphaValue = 0
            }, completionHandler: { window.orderOut(nil) })
            return
        }
        // Where it is going: the notch, on whichever screen the surface lives.
        let notch = panel.frame
        let target = CGRect(
            x: notch.midX - window.frame.width * 0.18,
            y: notch.maxY - window.frame.height * 0.36,
            width: window.frame.width * 0.36,
            height: window.frame.height * 0.36
        )
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = LedgeMotion.travel
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.45, 1)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { window.orderOut(nil) })
    }

    /// The pointer crossed the shape's edge.
    ///
    /// In: arm Th. Out: disarm it, take back the promise, and — if a summary is
    /// up — retract it, because a summary is the hover's surface and lives
    /// exactly as long as the hover ("Summary | pointer exit | whence it came").
    private func pointerChanged(inside: Bool) {
        rearmExitTimer()
        guard inside else {
            cancelThreshold()
            send(.pointerExit)
            return
        }
        guard !shellState.isExpanded else { return }
        send(.hoverBegan)
        scheduleThreshold()
    }

    /// Th elapsed with the pointer still on the notch. Which surface that means
    /// is the *session's* answer — a `<summary>` node in its tree makes it heavy
    /// (principle 8) — so it is resolved here, once, and handed to the machine.
    private func thresholdReached() {
        let app = shellState.lastPresentedApp
        send(.hoverThreshold(
            app: app,
            declaresSummary: app.map { session.declaresSummary(for: $0) } ?? false
        ))
    }

    private func scheduleThreshold() {
        cancelThreshold()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.surface.isHovered, !self.shellState.isExpanded else { return }
            self.thresholdReached()
        }
        thresholdTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + LedgeInteraction.hoverThreshold,
            execute: work
        )
    }

    private func cancelThreshold() {
        thresholdTimer?.cancel()
        thresholdTimer = nil
    }

    /// A click on Ledge's own glass. Which of the table's five clicks it is
    /// depends only on what is on screen — the notification's *action* is a
    /// button inside the app's node and never reaches here, so a click that does
    /// is "elsewhere" by construction.
    private func clicked() {
        // **The bare notch, while parked, is the way home** (flow.md: "clicking
        // it, or the window's ⌃, flies the surface home"). Nothing else the
        // notch could mean applies: there is no swell on it and no visit in it.
        guard !isParked else {
            send(.click(.pill))
            return
        }
        switch shellState.presentation {
        case .summary:
            send(.click(.summary))
        case .mini:
            send(.click(.notificationElsewhere))
        case .collapsed:
            send(.click(surface.wing == nil ? .pill : .wing))
        case .expanded, .chat, .newApp, .permissions, .overview:
            break
        }
    }

    /// A horizontal swipe. One meaning now (principle 9): **it walks the session
    /// strip**, and only in a visit.
    ///
    /// It used to have two others. On a mini it dismissed the peek — a gesture
    /// the rest of the product does not have, taught in the one place a user is
    /// least able to experiment. On the pill it became an app-level `swipe`
    /// event, which made a fixed gesture vocabulary app-defined. Both are gone.
    @discardableResult
    func handleSwipe(_ direction: SwipeRecognizer.Direction) -> Bool {
        guard shellState.isExpanded else { return false }
        // A finger moving left walks *forward*, the way a page turns.
        send(.walkStrip(steps: direction == .left ? 1 : -1))
        return true
    }

    /// Which end of the strip the blank slot is standing in for right now —
    /// the walk's own memory (see `SessionStrip.step(from:by:blankEnd:)`).
    /// Trailing at launch: "First launch opens here" (flow.md), and from
    /// nowhere in particular the blank reads as the end of the line.
    private var blankEnd: SessionStrip.BlankEnd = .trailing

    /// Walk the strip (flow.md, "The strip"): installed apps in registry order,
    /// plus one blank slot reachable past either end — and the blank IS the
    /// end: walking outward from it bounces instead of wrapping (G2.7).
    private func walk(_ steps: Int) {
        let strip = session.strip
        let current = strip.slot(for: shellState.presentation)
        guard let next = strip.step(from: current, by: steps, blankEnd: blankEnd) else {
            surface.bounceAtEnd(toward: steps)
            parked?.view.bounceAtEnd(toward: steps)
            return
        }
        if next == .blank { blankEnd = steps > 0 ? .trailing : .leading }
        // **The mode comes with you.** `ShellState.walk(to:)` owns the rule —
        // chat walks to chat, a stage walks to a stage — because "which surface
        // am I on" is state, not a view decision, and it has to be the same
        // answer for the `‹|›` beads and for the swipe.
        shellState.walk(to: next)
        machine.sync(to: shellState.presentation)
        refresh(animated: true)
    }

    // MARK: - Texit, and the three things that stop it

    /// What is currently stopping the walk-away timer. The pointer half is the
    /// surface's; the rest is this object's, because only it knows whether the
    /// editor is up or where first responder went.
    var exitInhibitor: ExitInhibitor {
        ExitInhibitor(
            pointerAway: !surface.isHovered,
            keyboardHeld: holdsKeyboard,
            dragging: surface.isDragInFlight,
            editorShowing: shellState.presentation.isConversation
        )
    }

    /// Whether anything in the shell holds the keyboard: the editor's composer,
    /// an `input` node in an app's tree, a focusable `canvas`. All three are
    /// "the user is mid-sentence", and the panel must not evaporate under any of
    /// them (flow.md: the timer "never runs while the pill or the app holds the
    /// keyboard").
    private var holdsKeyboard: Bool {
        if holdsEditorFocus { return true }
        guard let responder = panel.firstResponder else { return false }
        if responder is NSText || responder is NSTextField { return true }
        return responder is ProtocolCanvasView
    }

    /// Re-decide the walk-away timer from scratch. Called on every pointer
    /// change and every presentation change, because an inhibitor that merely
    /// made the timer's expiry a no-op would still close the panel the moment
    /// the user stopped typing.
    private func rearmExitTimer() {
        exitTimer?.cancel()
        exitTimer = nil
        // **Texit does not run while parked.** A window is deliberate: the user
        // pulled it off the notch and put it somewhere, and a surface that
        // evaporated 2.5 seconds after they looked away would be undoing that
        // decision for them. Only the ⌃ and the bare notch put it away.
        guard !isParked,
              shellState.isExpanded,
              shellState.presentation.allowsPassiveCollapse,
              exitInhibitor.mayRunExitTimer else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.exitInhibitor.mayRunExitTimer else { return }
            self.send(.exitTimeout)
        }
        exitTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LedgeInteraction.exitDelay, execute: work)
    }

    /// A click anywhere outside Ledge closes the visit (flow.md). Installed only
    /// while a visit is up, so the shell is not watching every click in the
    /// session for no reason.
    private func updateOutsideClickMonitor() {
        // Parked, for the same reason as the walk-away timer: a click somewhere
        // else is not a dismissal of a window.
        let wanted = !isParked
            && shellState.isExpanded
            && shellState.presentation.allowsPassiveCollapse
        if wanted, outsideClickMonitor == nil {
            // `@Sendable`: a main-actor object handing a closure to a system
            // framework, which is the trap that only shows up in the bundled
            // .app (build-plan, Conventions).
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { @Sendable [weak self] _ in
                Task { @MainActor in self?.send(.clickOutside) }
            }
        } else if !wanted, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Chrome requests (spec §3.3)

    /// An app asked for something of the shell. Denials are silent, per §3.3 —
    /// an app cannot tell whether it was refused, so it cannot build on it.
    private func handleChrome(
        app: String,
        request: String,
        wing: WingSpec?,
        ms: Double?,
        priority: NotificationClass?
    ) {
        switch request {
        case "peek":
            notify(app: app, ms: ms, priority: priority ?? .ambient)
        case "expand":
            // The one genuine reason to refuse: there is nothing to show. An app
            // whose worker has not committed a tree (or crashed into an error
            // card) would open onto the placeholder, which is worse than not
            // opening at all — a monitor pinging expand at boot must not steal
            // the notch before the app can draw.
            guard session.content(for: app) != nil else { return }
            present(.expanded(app: app))
        case "collapse":
            // Only the presented app may put the panel away; anything else would
            // let a background app close the panel out from under the user. And
            // never a parked window: the user put that there.
            guard !isParked, shellState.presentedApp == app, shellState.isExpanded else { return }
            present(.collapsed)
        case "attention":
            surface.flashAttention()
        case "wing":
            setWing(app: app, spec: wing)
        case Self.permissionsChromeRequest:
            // **No app may raise the permission surface. Not one.**
            //
            // This is shell chrome, not app content: an app that could raise it
            // could put an official-looking permission panel in front of the
            // user at a moment of its own choosing, which is precisely the
            // ambush the surface exists to prevent.
            //
            // There used to be a single exception — Settings, which was the
            // shell wearing an app's clothes (spec §8). Settings is a native
            // window now and asks the shell directly, so the exception has no
            // holder and the rule is simply the rule. The request is still
            // *handled* rather than deleted: the shell refuses what an app asks
            // for on its own account, and a refusal that is written down is
            // worth more than a `default:` that happens to ignore it.
            NSLog("[ledge] refused a permissions request from '%@' — chrome is not app content", app)
        default:
            break                                   // unknown request → ignored
        }
    }

    /// Default dwell when an app notifies without naming one. Matches the host's
    /// `DEFAULT_PEEK_MS`; duplicated rather than shared because the host clamps
    /// (policy about apps) and the shell defaults (policy about the surface).
    private static let defaultPeekSeconds: TimeInterval = 4

    /// `ctx.peek` (spec §3.3 extension) — **the notification** (flow.md,
    /// Interruption): swell the notch with the app's `<mini>` node.
    ///
    /// Refused, silently and in this order, when there is nothing to show and
    /// when a visit is already open. The second matters most: a notification
    /// interrupting a panel the user is actively reading — or worse, replacing
    /// another session's panel — is a background app taking the screen, which is
    /// the thing the notch must never do. It is only ever an escalation from
    /// Resting or Ambient (or a swap of the swell already up).
    private func notify(app: String, ms: Double?, priority: NotificationClass) {
        guard let mini = session.miniView(for: app) else { return }
        // **Parked: the swell comes out of the window's top edge** (flow.md).
        guard !isParked else {
            notifyParked(app: app, mini: mini, ms: ms, priority: priority)
            return
        }
        switch shellState.presentation {
        case .collapsed, .mini, .summary:
            break
        case .expanded, .chat, .newApp, .permissions, .overview:
            return
        }
        // The machine raises the swell and arms **Ti**, the shell's default.
        send(.notificationArrived(app: app, priority: priority))
        // `ms` still means what it always meant, and it is the app's opinion
        // about its own moment — so it replaces Ti when there is one. An alert
        // ignores both: it holds until it is acted on.
        guard priority != .alert, let ms else { return }
        scheduleDwell(app: app, after: ms / 1000)
    }

    /// A notification while the surface is parked (flow.md: "Notifications swell
    /// from the parked window's top edge").
    ///
    /// **The compromise, stated.** On the notch a notification is a whole
    /// presentation: the shape becomes the swell, and the machine goes to
    /// Interruption. A parked window is a fixed size that the user placed, so it
    /// cannot deform outward without moving itself out from under their pointer
    /// — and a window that resized itself because an app had something to say
    /// would be the worst version of this surface. So the band grows *down from
    /// the window's own top edge* instead, carrying the same borrowed `<mini>`
    /// node, dismissed by the same dwell, and clicking it walks the window to
    /// that session exactly as clicking the notch swell opens it. Same content,
    /// same timings, same meaning; a rectangle instead of a deformation.
    private func notifyParked(
        app: String,
        mini: NSView,
        ms: Double?,
        priority: NotificationClass
    ) {
        guard let parked else { return }
        let width = parked.window.frame.width
        let height = parked.view.swellView.preferredHeight(width: width)
        parked.view.showSwell(mini, height: height, animated: true) { [weak self] in
            guard let self else { return }
            self.dismissParkedSwell()
            self.shellState.selectApp(app, reselectOpensChat: false)
            self.machine.sync(to: self.shellState.presentation)
            self.refresh(animated: true)
        }
        parkedSwellTimer?.cancel()
        // "alert-class holds until acted" — the one rule that survives the
        // change of geometry unchanged, because it is about attention and not
        // about shape.
        guard priority != .alert else { return }
        let dwell = ms.map { $0 / 1000 } ?? LedgeInteraction.notificationDwell
        let work = DispatchWorkItem { [weak self] in self?.dismissParkedSwell() }
        parkedSwellTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    private func dismissParkedSwell() {
        parkedSwellTimer?.cancel()
        parkedSwellTimer = nil
        parked?.view.hideSwell(animated: true)
    }

    /// Retract the notification when its dwell elapses — unless the user is
    /// looking straight at it, or it is no longer the swell that is up (checked
    /// by the machine, which knows both).
    private func scheduleDwell(app: String, after seconds: TimeInterval) {
        dwellTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Hovering holds it open: the user is reading it, and pulling it out
            // from under them would be the rudest possible timing.
            guard !self.surface.isHovered else {
                self.scheduleDwell(app: app, after: 1)
                return
            }
            self.send(.notificationTimeout)
        }
        dwellTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelDwell() {
        dwellTimer?.cancel()
        dwellTimer = nil
    }

    /// Wing arbitration (spec §3.3 extension). There is one collapsed notch, so
    /// there is one wing: the latest app to ask for one takes it, and a release
    /// (`nil`) only lands if it comes from the app that currently holds it —
    /// otherwise a background app clearing its own wing would blank the wing of
    /// whichever app took over.
    private func setWing(app: String?, spec: WingSpec?) {
        // **Wings pause while parked** (flow.md, Parked). Arbitration is
        // suspended rather than queued: a wing is a *live* activity, and the one
        // an app asked for while the notch was bare is stale by the time the
        // surface flies home. The next update from a live holder takes the wing
        // then, which is what "paused" has to mean for something that is only
        // ever the present tense.
        guard !isParked else {
            if spec != nil { NSLog("[ledge] wing '%@' refused — parked", app ?? "?") }
            return
        }
        if let spec, let app {
            wingOwner = app
            surface.setWing(spec)
            session.protocolRenderer.setWingTarget(
                app: spec.canvas == nil ? nil : app,
                id: spec.canvas?.id,
                view: surface.wingCanvasView
            )
            // "Resting | wing granted | Ambient". Every update from the holder
            // is also proof it is alive, which re-arms Ta.
            send(.wingGranted)
            scheduleWingIdle(app: app)
            return
        }
        // A release. `app == nil` is the shell's own (disconnect); an app's own
        // release only counts if it is the owner.
        if let app, wingOwner != app { return }
        wingOwner = nil
        wingIdleTimer?.cancel()
        wingIdleTimer = nil
        surface.setWing(nil)
        session.protocolRenderer.setWingTarget(app: nil, id: nil, view: surface.wingCanvasView)
        // "Ambient | holder idle > Ta, or released | Resting".
        send(.wingReleased)
    }

    /// **Ta** — how long a wing holder may go quiet before the shell takes the
    /// wing back (flow.md). Holder-declared in the eventual design; this is the
    /// shell's default, re-armed by every `wing` request the holder sends, so a
    /// live activity that is actually live never trips it and one whose worker
    /// has stopped talking does not sit on the notch forever.
    private func scheduleWingIdle(app: String) {
        wingIdleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wingOwner == app else { return }
            self.setWing(app: app, spec: nil)
        }
        wingIdleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LedgeInteraction.ambientIdle, execute: work)
    }

    // MARK: - Chrome surfaces

    private func chatView(for app: String) -> ChatSurfaceView {
        let view: ChatSurfaceView
        let created: Bool
        if let chatSurface {
            view = chatSurface
            created = false
        } else {
            view = ChatSurfaceView()
            // Esc in chat closes the visit — flow.md's Transitions table has
            // exactly one row for it and chat is a mode of the visit, not a
            // sheet over it. The page keeps the one exception it already had:
            // while a turn is running, Esc interrupts the turn and never
            // reaches here.
            view.onEscape = { [weak self] in self?.send(.escape) }
            // ⌄ / ⌃: the panel is a different height with no transcript in it.
            view.onPaneChange = { [weak self] in self?.refresh(animated: true) }
            view.bridge.onInput = { [weak self] bridgeApp, text, cancel in
                guard let self else { return }
                // The one case where the bridge's answer wins: on the [+]
                // surface it is focused on `""`, which is not "no app" but "the
                // app the host is about to make" (spec §4.3). Nothing is
                // presented, so asking the session would give up the message.
                if bridgeApp.isEmpty {
                    // Cancelling a turn whose app does not exist yet has nothing
                    // to address; the create request is one envelope and it has
                    // already gone.
                    if !cancel, let text { self.session.sendBuilderCreate(text: text) }
                    return
                }
                // Otherwise the bridge names the app it is focused on; the
                // session names the app that is *presented*. Only the session's
                // answer becomes an envelope — see `HostSession.sendBuilderInput`.
                self.session.sendBuilderInput(text: text, cancel: cancel)
            }
            view.bridge.onCreated = { [weak self] app in
                // The [+] surface becomes that app's chat, mid-turn: same web
                // view, same transcript, but now with something behind Preview
                // and a strip entry to come back to.
                self?.present(.chat(app: app))
            }
            // A new turn makes the last one's outcome stale: the toggle goes
            // back to neutral glass until the worker reloads or crashes again.
            view.editor.onActivity = { [weak self] in self?.surface.setBuildStatus(.neutral) }
            chatSurface = view
            created = true
        }
        view.focus(app: app)
        // Focus first: `focus` deliberately clears another app's pending queue,
        // while this event belongs to every app and must survive that boundary.
        if created, let latestAgentStatus {
            view.bridge.deliver(latestAgentStatus)
        }
        return view
    }


    /// The permission surface, built once and kept. It holds live state — the
    /// cached notification read, the poll that catches a change made in System
    /// Settings — and rebuilding it per presentation would drop both.
    private func permissionsView() -> PermissionsCardView {
        if let permissionsSurface { return permissionsSurface }
        let card = PermissionsCardView(probe: permissionProbe)
        card.onDismiss = { [weak self] in self?.present(.collapsed) }
        // A status changed under us (the user allowed something in Settings and
        // came back), and the row that reported it may have grown or lost its
        // explanatory line. Re-presenting is a re-measure, not a content swap —
        // `ShellSurfaceView.present` morphs the same view to a new height.
        card.onResize = { [weak self] in
            guard let self, self.shellState.presentation == .permissions else { return }
            self.refresh(animated: true)
        }
        permissionsSurface = card
        return card
    }

    private func placeholderView(for app: String?) -> HostPlaceholderView {
        // Name the actual gap: a connected host with zero apps is not
        // "waiting for host", it's an empty registry.
        let phase: HostPlaceholderView.Phase = if !session.isConnected {
            .noHost(detail: hostDetail)
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
            "[ledge] screen %@ %@ safeTop %.1f metrics %.1f x %.1f panel max %.0f x %.0f window %.0f x %.0f",
            NSStringFromRect(screen.frame),
            // Which kind of cutout this is, because "the pill is in the wrong
            // place" and "this display has no notch" look identical otherwise.
            metrics.isSynthesized ? "synthesized" : "hardware",
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

    /// See `NotchScreen`: a notched display if there is one, else the primary.
    private func preferredScreen() -> NSScreen {
        NotchScreen.preferred() ?? NSScreen.screens[0]
    }
}
