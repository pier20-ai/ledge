import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **Parked** — flow.md's sixth state, and design.html §04's right specimen.
///
/// > The whole surface torn off as a floating window, fixed size. The notch sits
/// > bare; clicking it, or the window's ⌃, flies the surface home. Notifications
/// > swell from the parked window's top edge; wings pause.
///
/// The drag itself is the one part a headless suite cannot press — it is a live
/// mouse loop over real glass — so the seam is one step in: `parkForTesting` is
/// the same call the drag makes the instant it crosses the threshold. What the
/// tests below own is everything after that instant, which is all of the law.
@MainActor
@Suite("Parked — the surface, torn off")
struct ParkedTests {
    private func parked() throws -> (HostSession, NotchPanelController, String) {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        let app = session.strip.apps[0]
        controller.present(.expanded(app: app), animated: false)
        controller.parkForTesting()
        return (session, controller, app)
    }

    // MARK: - The tear

    @Test("Parking moves the whole surface into a window and leaves the notch bare")
    func theTear() throws {
        let (_, controller, app) = try parked()
        #expect(controller.isParked)
        #expect(controller.interactionState == .parked)
        // The visit is still the visit — it is just somewhere else.
        #expect(controller.presentation == .expanded(app: app))
        #expect(
            controller.surfaceForTesting.presentation == .collapsed,
            "the notch shows the bare pill behind it"
        )
        #expect(controller.parkedSurfaceForTesting?.presentation == .expanded(app: app))
    }

    /// Principle 6: "never a window that appeared nearby". Borderless, glass,
    /// its own shadow, the same level as the notch — and never a titled window.
    @Test("The window is the same body, not a macOS window")
    func theWindowIsGlass() throws {
        let (_, controller, _) = try parked()
        let window = try #require(controller.parkedWindowForTesting)
        #expect(window.styleMask.contains(.borderless))
        #expect(!window.styleMask.contains(.titled))
        #expect(!window.hasShadow, "the shadow is the body's own (LedgeShadow.window)")
        #expect(window.backgroundColor == .clear)
        #expect(!window.isOpaque)
        #expect(window.level == controller.panelForTesting.level)
        #expect(window.isMovableByWindowBackground, "fixed size, any position")
    }

    /// G2.8/G2.9: the window keeps the notch's floored glass, and its islands
    /// hug the window's own edges — [⌂|✦] at the far left, ‹|› at the far
    /// right, flex space between (Manu: "let the controls hug… that makes the
    /// app look good"). At G6 the notch panel adopted the same layout, so the
    /// tail of this test is now the sameness rather than the difference.
    @Test("The window carries the floor, and its islands hug its edges")
    func theWindowHugsItsEdges() throws {
        let (_, controller, _) = try parked()
        let window = try #require(controller.parkedWindowForTesting)
        let view = try #require(controller.parkedSurfaceForTesting)
        let surface = controller.surfaceForTesting
        #expect(window.frame.width >= surface.visitFloorWidth)
        #expect(window.frame.width >= PanelLimits.defaultWidth)
        view.layoutSubtreeIfNeeded()
        let bar = view.wingBarView
        #expect(bar.tearView.isHidden, "a window cannot tear off of itself")

        // The split's leading edge at the bar's leading edge; the walker's
        // trailing edge at the bar's trailing end (no tear bead in here).
        let split = bar.convert(bar.splitView.bounds, from: bar.splitView)
        let walker = bar.convert(bar.walkerView.bounds, from: bar.walkerView)
        #expect(abs(split.minX - LedgeMetrics.panelWingPad) < 0.01)
        #expect(abs(walker.maxX - (bar.bounds.width - LedgeMetrics.panelWingPad)) < 0.01)

        // …and the notch's own bar does exactly the same (G6): one layout,
        // two bodies — principle 6, "one material, one body".
        surface.present(
            .expanded(app: "settings"), content: FlippedView(),
            width: PanelLimits.defaultWidth, height: 300, animated: false
        )
        surface.layoutSubtreeIfNeeded()
        let notchBar = surface.panelWingBarView
        let notchSplit = notchBar.convert(notchBar.splitView.bounds, from: notchBar.splitView)
        #expect(abs(notchSplit.minX - LedgeMetrics.panelWingPad) < 0.01)
    }

    /// The window spends `topPad` on air above its chrome row, which the
    /// panel never had to — so it is that much taller than the panel it tore
    /// off, and the content host is exactly the height the session measured
    /// its tree at. It was the panel's height, and every parked app lost six
    /// points off its bottom: the first thing Manu saw after G6.
    @Test("The window is the panel plus its top pad, so nothing at the bottom clips")
    func theWindowIsTallEnough() throws {
        let (_, controller, _) = try parked()
        let window = try #require(controller.parkedWindowForTesting)
        let view = try #require(controller.parkedSurfaceForTesting)
        // The fixture's app has no tree, so what parked is the placeholder
        // card — whose panel height is a known number: the card plus the row.
        let panelHeight = HostPlaceholderView.panelHeight + controller.surfaceForTesting.panelWingRowHeight
        #expect(window.frame.height == ParkedSurfaceView.windowHeight(forPanelHeight: panelHeight))
        view.layoutSubtreeIfNeeded()
        // The content gets what it was measured at: the panel less the row.
        #expect(abs(view.contentHostFrame.height - (panelHeight - view.rowHeight)) < 0.01)
        #expect(ParkedSurfaceView.windowHeight(forPanelHeight: 300) == 300 + ParkedSurfaceView.topPad)
    }

    /// The content clips to the body's rounded outline, as it does in the
    /// notch panel. Since G6 the content is exactly the body's width, so a
    /// square-cornered tree — or the chat pane's web view and its opaque
    /// backdrop — stood out past the glass's corners without this.
    @Test("The content host clips to the window's rounded body")
    func contentClipsToTheBody() throws {
        let (_, controller, _) = try parked()
        let view = try #require(controller.parkedSurfaceForTesting)
        view.layoutSubtreeIfNeeded()
        let mask = try #require(view.contentHostView.layer?.mask as? CAShapeLayer)
        let path = try #require(mask.path)
        let host = view.contentHostFrame
        #expect(mask.frame.size == host.size)
        // The body's corner is outside the clip; the bottom edge's middle and
        // the host's own middle are inside it.
        #expect(!path.contains(CGPoint(x: 0.5, y: host.height - 0.5)))
        #expect(!path.contains(CGPoint(x: host.width - 0.5, y: host.height - 0.5)))
        #expect(path.contains(CGPoint(x: host.width / 2, y: host.height - 0.5)))
        #expect(path.contains(CGPoint(x: 0.5, y: host.height / 2)))
    }

    /// G2.10: the window is floored at the islands' span, so a session
    /// narrower than the floor sits centred in the wider glass — the notch's
    /// own law, kept by the window (blocks was left-hugging on device).
    @Test("A narrow session is centred in the floored window")
    func narrowSessionIsCentred() throws {
        let (_, controller, _) = try parked()
        let view = try #require(controller.parkedSurfaceForTesting)
        view.layoutSubtreeIfNeeded()
        try #require(view.contentWidth > 0)
        let host = view.contentHostFrame
        #expect(abs(host.midX - view.bounds.midX) < 0.5, "centred, not left-hugging")
        #expect(host.width == min(view.contentWidth, view.bounds.width))
    }

    /// G2.10: a walk that pulls the glass out from under a stationary pointer
    /// holds the walk-away timer until the hand actually moves — the grace's
    /// mechanism, since a live stranded pointer cannot be staged headlessly.
    @Test("The exit grace holds until the pointer moves, then normal rules resume")
    func exitGraceHoldsUntilTheHandMoves() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)

        controller.armExitGraceForTesting()
        #expect(controller.isHoldingExitGraceForTesting)

        // The pointer crossing the shape's edge is a move: the grace ends.
        controller.surfaceForTesting.onPointerInside?(true)
        #expect(!controller.isHoldingExitGraceForTesting)
    }

    /// G2.8 bug 3's regression: park, fly home, park again — the whole cycle,
    /// twice, because the second tear is the one that used to be dead.
    @Test("The tear works again after flying home")
    func tearAfterFlyHome() throws {
        let (_, controller, app) = try parked()
        controller.surfaceForTesting.onClick?()
        #expect(!controller.isParked)
        #expect(controller.presentation == .expanded(app: app))

        controller.parkForTesting()
        #expect(controller.isParked, "the second tear parks exactly like the first")
        #expect(controller.interactionState == .parked)
        #expect(controller.parkedSurfaceForTesting?.presentation == .expanded(app: app))
    }

    /// G2.8 bug 2's regression: the user moves the window by its own glass —
    /// a system drag this object never sees directly — and then walks the
    /// strip. The window must stay where the user put it, not teleport back
    /// to the tear's first drop point.
    @Test("Walking after a hand-moved window keeps the moved corner")
    func walkingKeepsTheMovedCorner() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)
        controller.parkForTesting(at: CGPoint(x: 380, y: 700))
        let window = try #require(controller.parkedWindowForTesting)

        // The user's own drag: a frame change straight on the window, which
        // posts `didMove` — the only signal the controller gets.
        let moved = window.frame.offsetBy(dx: 140, dy: -120)
        window.setFrame(moved, display: true)

        _ = controller.handleSwipe(.left)
        let after = try #require(controller.parkedWindowForTesting).frame
        #expect(abs(after.minX - moved.minX) < 0.5, "the corner is wherever the user last put it")
        #expect(abs(after.maxY - moved.maxY) < 0.5)
    }

    /// G2.8 bug 4: carried back up to the notch and let go, the window means
    /// "home". The user's drag reaches the controller only as `didMove`;
    /// headlessly no button is held, so the release-poll resolves at once and
    /// the whole gesture is testable as geometry in, presentation out.
    @Test("Dropped at the notch the window flies home; dropped elsewhere it stays")
    func droppedAtTheNotch() throws {
        let (_, controller, app) = try parked()
        let window = try #require(controller.parkedWindowForTesting)
        let screen = try #require(window.screen ?? NSScreen.main)
        #expect(!controller.parkedWindowIsAtTheNotchForTesting, "parked at 400,400: not the notch")

        // Against the ceiling but far to the side: near nothing that means home.
        let frame = window.frame
        window.setFrame(
            CGRect(
                x: screen.frame.minX,
                y: screen.visibleFrame.maxY - frame.height,
                width: frame.width,
                height: frame.height
            ),
            display: true
        )
        #expect(controller.isParked, "the corner of the screen is not the notch")

        // Astride the cutout, against the ceiling: that is the notch, and the
        // drop flies the visit home.
        window.setFrame(
            CGRect(
                x: screen.frame.midX - frame.width / 2,
                y: screen.visibleFrame.maxY - frame.height,
                width: frame.width,
                height: frame.height
            ),
            display: true
        )
        #expect(!controller.isParked, "dropped at the notch: it flew home")
        #expect(controller.presentation == .expanded(app: app))
        #expect(controller.interactionState == .visit)
    }

    @Test("The window is the size the panel was, and takes it from the pointer's corner")
    func theWindowTakesThePanelsSize() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)

        let corner = CGPoint(x: 520, y: 640)
        controller.parkForTesting(at: corner)
        let window = try #require(controller.parkedWindowForTesting)
        #expect(abs(window.frame.minX - corner.x) < 0.5)
        #expect(abs(window.frame.maxY - corner.y) < 0.5, "the corner the fingers were holding")
        #expect(window.frame.width >= PanelLimits.minWidth)
        #expect(window.frame.height >= PanelLimits.minHeight)
    }

    @Test("The tear threshold is a deliberate pull, downward, and it is stated once")
    func theThreshold() {
        #expect(LedgeMetrics.parkTearThreshold == 40)
    }

    // MARK: - The whole surface keeps working inside it

    @Test("The visit's own controls come with it — and one more, the ⌃")
    func theWindowCarriesTheWings() throws {
        let (_, controller, _) = try parked()
        let view = try #require(controller.parkedSurfaceForTesting)
        #expect(!view.wingBarView.splitView.isHidden)
        #expect(view.homeBead.frame.maxX <= view.bounds.width)
        // The ⌃ is at the top-right, and the walker sits clear of it.
        view.frame = CGRect(x: 0, y: 0, width: 440, height: 300)
        view.layoutSubtreeIfNeeded()
        #expect(view.homeBead.frame.minX > view.wingBarView.frame.maxX - 1)
    }

    @Test("The strip still walks inside the window, and the window stays parked")
    func walkingInsideTheWindow() throws {
        let (session, controller, app) = try parked()
        #expect(controller.handleSwipe(.left))
        let next = session.strip.apps[1]
        #expect(controller.presentation == .expanded(app: next))
        #expect(controller.isParked, "walking the strip is not flying home")
        #expect(controller.parkedSurfaceForTesting?.presentation == .expanded(app: next))
        #expect(controller.surfaceForTesting.presentation == .collapsed)
        #expect(app != next)
    }

    /// One position for Ledge, not one per session: the size is the session's,
    /// the corner is the user's. A window that jumped as you walked the strip
    /// would be two windows pretending to be one body.
    @Test("Walking the strip changes the window's size, never its corner")
    func theCornerIsTheUsers() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)
        let corner = CGPoint(x: 380, y: 700)
        controller.parkForTesting(at: corner)

        for _ in 0..<3 {
            _ = controller.handleSwipe(.left)
            let frame = try #require(controller.parkedWindowForTesting).frame
            #expect(abs(frame.minX - corner.x) < 0.5)
            #expect(abs(frame.maxY - corner.y) < 0.5)
        }
    }

    @Test("Chat and the ledge both work inside the window")
    func modesInsideTheWindow() throws {
        let (_, controller, app) = try parked()
        let view = try #require(controller.parkedSurfaceForTesting)

        controller.enterOverview()
        #expect(controller.presentation == .overview)
        #expect(controller.isParked)
        #expect(!view.wingBarView.backView.isHidden, "the ledge wears ‹ Back in the window too")
        #expect(view.wingBarView.splitView.isHidden)

        controller.leaveOverview()
        #expect(controller.presentation == .expanded(app: app))
        #expect(!view.wingBarView.splitView.isHidden)
        #expect(view.wingBarView.backView.isHidden)
    }

    // MARK: - While parked

    /// "wings pause (WingSpec arbitration suspended)". A wing is a live activity
    /// on a notch that is now bare; the request is refused rather than queued,
    /// because the next update from a live holder is the one that should win.
    @Test("Wings pause: a wing request while parked never reaches the notch")
    func wingsPause() throws {
        let (session, controller, app) = try parked()
        session.onChrome?(app, "wing", WingSpec(text: "12:04"), nil, nil)
        #expect(controller.surfaceForTesting.wing == nil)
        #expect(controller.isParked)
    }

    /// "Texit does not run while parked (the window is deliberate)." Neither
    /// does Esc, and neither does a click anywhere else.
    @Test("Nothing passive puts the window away")
    func nothingPassiveCloses() throws {
        let (_, controller, app) = try parked()
        controller.surfaceForTesting.onEscape?()
        #expect(controller.isParked, "Esc is not a way to close a window")
        #expect(controller.presentation == .expanded(app: app))
    }

    /// The notification's geometry changes and nothing else does: same borrowed
    /// `<mini>` node, same dwell, from the window's top edge instead of the
    /// notch's (the compromise is documented on `notifyParked`).
    @Test("A notification swells from the window's top edge, not from the notch")
    func notificationsComeFromTheWindow() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        session.inject(Envelope(app: "music", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("mini")]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        controller.present(.expanded(app: "music"), animated: false)
        controller.parkForTesting()

        session.onChrome?("music", "peek", nil, 4000, NotificationClass.ambient)
        #expect(controller.parkedSurfaceForTesting?.isShowingSwell == true)
        // The notch behind it is untouched: no swell, and the machine is still
        // parked rather than interrupted.
        #expect(controller.surfaceForTesting.presentation == .collapsed)
        #expect(controller.interactionState == .parked)
        #expect(controller.presentation == .expanded(app: "music"))
    }

    // MARK: - Flying home

    @Test("Clicking the bare notch flies the surface home")
    func theBareNotchFliesItHome() throws {
        let (_, controller, app) = try parked()
        controller.surfaceForTesting.onClick?()
        #expect(!controller.isParked)
        #expect(controller.interactionState == .visit)
        #expect(controller.presentation == .expanded(app: app))
        #expect(controller.surfaceForTesting.presentation == .expanded(app: app))
    }

    @Test("The ⌃ flies it home too, and the window goes away")
    func theChevronFliesItHome() throws {
        let (_, controller, app) = try parked()
        let view = try #require(controller.parkedSurfaceForTesting)
        #expect(view.homeBead.accessibilityPerformPress())
        #expect(!controller.isParked)
        #expect(controller.presentation == .expanded(app: app))
    }

    /// The session that flew home is the one that was in the window, not
    /// "whatever you were last in": walk the strip inside it, then fly.
    @Test("The visit that lands is the visit that left")
    func theVisitThatLands() throws {
        let (session, controller, _) = try parked()
        _ = controller.handleSwipe(.left)
        let walked = session.strip.apps[1]
        controller.surfaceForTesting.onClick?()
        #expect(controller.presentation == .expanded(app: walked))
    }

    /// …and once home, everything passive works again: Esc closes the visit.
    @Test("Home again, the visit closes the ordinary way")
    func homeAgainTheVisitIsOrdinary() throws {
        let (_, controller, _) = try parked()
        controller.surfaceForTesting.onClick?()
        controller.surfaceForTesting.onEscape?()
        #expect(controller.presentation == .collapsed)
        #expect(controller.interactionState == .resting)
    }
}
