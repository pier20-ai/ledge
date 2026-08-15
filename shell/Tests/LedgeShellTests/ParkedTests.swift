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
        #expect(view.wingBarView.glassToggleView.currentLabel == "Apps")
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
        #expect(view.wingBarView.glassToggleView.currentLabel == "Back")

        controller.leaveOverview()
        #expect(controller.presentation == .expanded(app: app))
        #expect(view.wingBarView.glassToggleView.currentLabel == "Apps")
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
