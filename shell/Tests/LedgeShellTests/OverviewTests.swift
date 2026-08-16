import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The ledge** — flow.md's "The strip", zoomed out.
///
/// > Sessions as a grid of square glass cards that swell toward the cursor;
/// > the blank slot is a dashed card, last. Click jumps; the only ✕ in the
/// > product lives here. Trigger: the `|` divider, or ⌂.
///
/// The G2.5 redesign: the first ledge was a shelf of flat-bottomed slabs that
/// panned sideways, and on device it read as a truncated x-y list. The grid
/// shows the whole strip at once — square cards, fully rounded, swelling
/// toward the hand on a 2-D gaussian — so this suite is one claim per law:
/// the trigger reaches it, the grid *is* the strip, the geometry is a grid of
/// squares, the swell follows the cursor, and the ✕ stops a session without
/// uninstalling it.
@MainActor
@Suite("The ledge — the strip, zoomed out")
struct OverviewTests {
    private func loaded() throws -> (HostSession, NotchPanelController) {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        return (session, controller)
    }

    /// A grid big enough to wrap: nine sessions and the blank slot, which is
    /// what a real machine's catalog looks like. Built here rather than out of
    /// the catalog fixture, which holds three apps and never fills a row.
    private func crowded(current: String? = nil, sessions: Int = 9) -> OverviewSurfaceView {
        let grid = OverviewSurfaceView()
        var cards = (0..<sessions).map {
            OverviewSurfaceView.Card(app: "app\($0)", name: "App \($0)", icon: "circle")
        }
        cards.append(.blank)
        grid.apply(cards: cards, current: current)
        grid.frame = CGRect(
            x: 0, y: 0,
            width: PanelLimits.defaultWidth,
            height: OverviewSurfaceView.panelHeight(count: cards.count)
        )
        grid.layoutSubtreeIfNeeded()
        return grid
    }

    // MARK: - The trigger

    /// The `|` between `‹` and `›` is the overview's trigger and nothing else's.
    /// The lane is eleven points wide because a one-point target is not a
    /// control; the two halves must not be able to steal it.
    @Test("The walker's seam is the ledge's trigger, and it is a real target")
    func theDividerIsTheTrigger() {
        var opened = 0
        let walker = WingWalkerView(onWalk: { _ in }, onOverview: { opened += 1 })
        walker.frame = CGRect(origin: .zero, size: walker.intrinsicContentSize)
        walker.layoutSubtreeIfNeeded()

        let lane = walker.dividerLaneRect
        #expect(lane.width == LedgeMetrics.walkerDividerLane)
        #expect(walker.zone(at: CGPoint(x: lane.midX, y: lane.midY)) == .overview)
        // …and the halves either side of it are still the walk.
        #expect(walker.zone(at: CGPoint(x: lane.minX - 2, y: lane.midY)) == .previous)
        #expect(walker.zone(at: CGPoint(x: lane.maxX + 2, y: lane.midY)) == .next)
        #expect(opened == 0, "the geometry is the claim here; the press is the next test")
    }

    @Test("Opening the ledge presents it, and the ⌂ lights up wearing a back arrow")
    func openingTheLedge() throws {
        let (session, controller) = try loaded()
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)
        let split = controller.surfaceForTesting.panelWingBarView.splitView
        #expect(split.homeZone.symbolName == "house")

        controller.enterOverview()
        #expect(controller.presentation == .overview)
        #expect(controller.presentation.isExpanded, "the ledge is a visit, zoomed out")
        #expect(split.homeZone.isLit, "⌂ lights while the ledge is up — it is the way off it")
        #expect(!split.homeZone.isHidden)
        // G2.5: while you are viewing all apps, the press means "back to the
        // app", and the icon says so.
        #expect(split.homeZone.symbolName == "arrow.left")

        controller.leaveOverview()
        #expect(split.homeZone.symbolName == "house", "and the ⌂ comes back with the stage")
    }

    // MARK: - The grid is the strip

    @Test("One card per session, the blank slot last, with the catalog's own glyphs")
    func theGridIsTheStrip() throws {
        let (session, controller) = try loaded()
        controller.enterOverview()
        let grid = try #require(controller.overviewForTesting)

        #expect(grid.cards.count == session.strip.slots.count)
        #expect(grid.cards.dropLast().allSatisfy { !$0.isBlank })
        #expect(grid.cards.last?.isBlank == true, "at most one blank exists, and it is last")
        for (card, app) in zip(grid.cards, session.strip.apps) {
            #expect(card.app == app)
            #expect(card.icon == session.icon(for: app))
            #expect(card.name == session.name(for: app))
        }
    }

    @Test("The cards are squares on a grid: rows of gridColumns, every row centred")
    func theCardsAreSquares() {
        let grid = crowded()                                   // 10 cards: 4+4+2
        let frames = grid.cardFrames
        #expect(frames.allSatisfy { $0.width == LedgeMetrics.cardSize })
        #expect(frames.allSatisfy { $0.height == LedgeMetrics.cardSize }, "square, not slab")

        let columns = LedgeMetrics.gridColumns
        for (index, frame) in frames.enumerated() {
            let row = index / columns
            let column = index % columns
            #expect(
                frame.minY == LedgeMetrics.gridPad
                    + CGFloat(row) * (LedgeMetrics.cardSize + LedgeMetrics.cardGap)
            )
            if column > 0 {
                #expect(frame.minX - frames[index - 1].maxX == LedgeMetrics.cardGap)
            }
        }
        // Full rows and the short last row are each centred on the panel.
        let mid = grid.bounds.midX
        #expect(abs((frames[0].minX + frames[3].maxX) / 2 - mid) < 0.5)
        #expect(abs((frames[8].minX + frames[9].maxX) / 2 - mid) < 0.5,
                "two cards in the last row: centred, not left-hung")
        // Nothing pans and nothing is cut: every card is inside the surface.
        #expect(frames.allSatisfy { grid.bounds.contains($0) })
    }

    /// The grid does not scroll — it grows a row, and the panel grows with it.
    @Test("The panel height is a function of the rows")
    func thePanelGrowsByRows() {
        let one = OverviewSurfaceView.panelHeight(count: 3)
        let two = OverviewSurfaceView.panelHeight(count: 5)
        let three = OverviewSurfaceView.panelHeight(count: 9)
        #expect(two - one == LedgeMetrics.cardSize + LedgeMetrics.cardGap)
        #expect(three - two == LedgeMetrics.cardSize + LedgeMetrics.cardGap)
        #expect(OverviewSurfaceView.panelHeight(count: 4) == one, "a fuller row is not taller")
        #expect(OverviewSurfaceView.rows(count: 4) == 1)
        #expect(OverviewSurfaceView.rows(count: 5) == 2)
        #expect(OverviewSurfaceView.columns(count: 2) == 2, "two cards, two columns, centred")
    }

    // MARK: - The swell toward the cursor

    /// One function for the falloff, so the view and the tests cannot drift
    /// apart: `exp(-d² / 2σ²)`, σ = `cardFalloff`.
    @Test("The falloff is one gaussian")
    func theFalloff() {
        #expect(LedgeMetrics.cardMagnification(distance: 0) == 1)
        #expect(
            abs(LedgeMetrics.cardMagnification(distance: LedgeMetrics.cardFalloff) - exp(-0.5))
                < 0.0001
        )
        #expect(LedgeMetrics.cardMagnification(distance: 400) < 0.001)
        // Symmetric: a cursor to the left swells a card exactly as much as one
        // the same distance to the right.
        #expect(
            LedgeMetrics.cardMagnification(distance: -40)
                == LedgeMetrics.cardMagnification(distance: 40)
        )
    }

    @Test("The card under the cursor swells fully, its neighbours partly, the far corner not at all")
    func cardsSwell() throws {
        let grid = crowded()
        let frames = grid.cardFrames
        try #require(frames.count == 10)

        grid.apply(pointer: CGPoint(x: frames[0].midX, y: frames[0].midY))
        let factors = grid.cardMagnifications
        #expect(abs(factors[0] - 1) < 0.001, "directly under the cursor: the full swell")
        #expect(factors[1] > 0.05 && factors[1] < factors[0], "its neighbour leans")
        #expect(factors[4] > 0.05, "…and so does the card below: the gaussian is 2-D")
        #expect(factors[7] < 0.01, "the far corner does not move")

        // The swell is real geometry, centred on the card's own centre.
        let live = grid.cardLiveFrames[0]
        #expect(live.width > frames[0].width)
        #expect(abs(live.midX - frames[0].midX) < 0.001)
        #expect(abs(live.midY - frames[0].midY) < 0.001)

        // Pointer gone: every card back at rest.
        grid.apply(pointer: nil)
        #expect(grid.cardMagnifications.allSatisfy { $0 == 0 })
        for (live, base) in zip(grid.cardLiveFrames, grid.cardFrames) {
            // Within float noise: the rest frame is recomputed off midX/midY.
            #expect(abs(live.minX - base.minX) < 0.001)
            #expect(abs(live.minY - base.minY) < 0.001)
            #expect(live.size == base.size)
        }
    }

    /// Principle 10: "Reduce Motion swaps motion for fades" — it does not
    /// remove affordances. The grid stops swelling; the ✕ still appears.
    @Test("Reduce Motion holds the cards still and keeps the ✕")
    func reduceMotion() {
        let grid = crowded()
        grid.reduceMotionOverride = true
        let frames = grid.cardFrames
        grid.apply(pointer: CGPoint(x: frames[0].midX, y: frames[0].midY))
        #expect(!grid.magnifies)
        #expect(grid.cardMagnifications.allSatisfy { $0 == 0 }, "nothing moves")
        #expect(grid.isShowingClose, "…but the ✕ is still a reveal, and still reveals")
    }

    // MARK: - The only ✕ in the product

    @Test("The ✕ rides the hovered card's corner and never lands on the blank slot")
    func theOnlyClose() throws {
        let grid = crowded()
        #expect(!grid.isShowingClose, "nothing is hovered yet")

        let frames = grid.cardFrames
        grid.apply(pointer: CGPoint(x: frames[0].midX, y: frames[0].midY))
        #expect(grid.isShowingClose)
        // On the swollen card's top-right corner, straddling it like a badge.
        let bead = grid.closeBeadView.frame
        let live = grid.cardLiveFrames[0]
        #expect(abs(bead.midX - (live.maxX - 8)) < 0.5)
        #expect(abs(bead.midY - (live.minY + 8)) < 0.5)
        // …and never past the surface: `gridPad` reserves the bead's ride.
        #expect(bead.minY >= 0)

        // The blank slot has no session to stop.
        let blank = try #require(frames.last)
        grid.apply(pointer: CGPoint(x: blank.midX, y: blank.midY))
        #expect(!grid.isShowingClose)
    }

    @Test("Pressing the ✕ stops that session and leaves the ledge standing")
    func pressingTheClose() throws {
        let (session, controller) = try loaded()
        let victim = session.strip.apps[0]
        controller.present(.expanded(app: victim), animated: false)
        controller.enterOverview()
        let grid = try #require(controller.overviewForTesting)
        grid.frame = CGRect(
            x: 0, y: 0,
            width: PanelLimits.defaultWidth,
            height: OverviewSurfaceView.panelHeight(count: grid.cards.count)
        )
        grid.layoutSubtreeIfNeeded()
        let first = grid.cardFrames[0]
        grid.apply(pointer: CGPoint(x: first.midX, y: first.midY))

        #expect(grid.closeBeadView.accessibilityPerformPress())
        #expect(controller.presentation == .overview, "stopping one session does not leave the ledge")
        // …and Back no longer aims at the session that was stopped.
        controller.leaveOverview()
        #expect(controller.presentation.app != victim)
    }

    /// The wire half of the ✕ (spec §4.3 extension `appControl`): a
    /// control-plane frame, addressed to nobody, naming the app in its payload.
    /// It lands on the host's existing enable/disable path — the worker goes,
    /// the app stays installed.
    @Test("Stopping a session is one envelope, and it names the app in the payload")
    func stopIsAnEnvelope() {
        var sent: [Envelope] = []
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 210, menubarHeight: 34, scale: 2),
            delegate: ProtocolRenderer(),
            send: { sent.append($0) }
        )
        engine.sendAppControl(app: "chess", action: "stop")

        #expect(sent.count == 1)
        #expect(sent[0].type == "appControl")
        #expect(sent[0].app == "", "a control-plane frame is addressed to nobody")
        #expect(sent[0].payload == .object(["app": .string("chess"), "action": .string("stop")]))
    }

    // MARK: - Back

    /// The controller passes what Back points at, so zooming out of a session
    /// and zooming out of the ledge cannot disagree about which one it is.
    @Test("The grid knows the session it was zoomed out of")
    func theGridKnowsItsOrigin() throws {
        let (session, controller) = try loaded()
        let app = session.strip.apps[1]
        controller.present(.expanded(app: app), animated: false)
        controller.enterOverview()
        #expect(controller.overviewForTesting?.current == app)
    }

    @Test("Back returns to the session that was showing, in the mode it was in")
    func backReturnsToTheSession() throws {
        let (session, controller) = try loaded()
        let app = session.strip.apps[1]
        controller.present(.chat(app: app), animated: false)
        controller.enterOverview()
        #expect(controller.presentation == .overview)

        controller.leaveOverview()
        #expect(controller.presentation == .chat(app: app), "the mode came back too")
    }

    /// Esc in the overview is **Back**, not close-visit. The machine owns that
    /// row (see `InteractionMachineTests`); this is the controller obeying it.
    @Test("Esc on the ledge goes back; Esc again closes the visit")
    func escapeGoesBack() throws {
        let (session, controller) = try loaded()
        let app = session.strip.apps[0]
        controller.present(.expanded(app: app), animated: false)
        controller.enterOverview()

        controller.surfaceForTesting.onEscape?()
        #expect(controller.presentation == .expanded(app: app))
        controller.surfaceForTesting.onEscape?()
        #expect(controller.presentation == .collapsed)
    }

    @Test("Clicking a card jumps to that session; the blank card opens the blank slot")
    func clickingACardJumps() throws {
        let (session, controller) = try loaded()
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)
        controller.enterOverview()
        let grid = try #require(controller.overviewForTesting)

        let second = session.strip.apps[1]
        let card = try #require(grid.cardViewsForTesting.first { $0.card.app == second })
        #expect(card.accessibilityPerformPress())
        #expect(controller.presentation == .expanded(app: second))

        controller.enterOverview()
        let blank = try #require(grid.cardViewsForTesting.last)
        #expect(blank.card.isBlank)
        #expect(blank.accessibilityPerformPress())
        #expect(controller.presentation == .newApp)
    }

    /// The overview is a *mode*, so the strip still walks out of it — and
    /// walking is leaving, not zooming further.
    @Test("Walking the strip from the ledge lands on a session")
    func walkingLeavesTheLedge() throws {
        let (_, controller) = try loaded()
        controller.present(.overview, animated: false)
        #expect(controller.handleSwipe(.left))
        #expect(controller.presentation != .overview)
    }
}
