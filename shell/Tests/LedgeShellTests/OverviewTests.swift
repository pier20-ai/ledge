import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The ledge** — flow.md's "The strip", and design.html §04's left specimen.
///
/// > Zoom out to the overview — the ledge: sessions as slabs on a shelf. Click
/// > jumps; the only ✕ in the product lives here. Trigger: the `|` divider.
///
/// Four claims, and this suite is one per claim: the trigger reaches it, the
/// shelf is the strip (blank slot included), the slabs rise toward the cursor on
/// design.html's own falloff, and the ✕ stops a session without uninstalling it.
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

    @Test("Opening the ledge presents it, and the left wing reads Back")
    func openingTheLedge() throws {
        let (session, controller) = try loaded()
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)
        controller.enterOverview()

        #expect(controller.presentation == .overview)
        #expect(controller.presentation.isExpanded, "the ledge is a visit, zoomed out")
        let split = controller.surfaceForTesting.panelWingBarView.splitView
        #expect(split.homeZone.isLit, "⌂ lights while the shelf is up — it is the way off it")
        #expect(!split.homeZone.isHidden)
    }

    // MARK: - The shelf is the strip

    @Test("One slab per session, the blank slot last, with the catalog's own glyphs")
    func theShelfIsTheStrip() throws {
        let (session, controller) = try loaded()
        controller.enterOverview()
        let shelf = try #require(controller.overviewForTesting)

        #expect(shelf.slabs.count == session.strip.slots.count)
        #expect(shelf.slabs.dropLast().allSatisfy { !$0.isBlank })
        #expect(shelf.slabs.last?.isBlank == true, "at most one blank exists, and it is last")
        for (slab, app) in zip(shelf.slabs, session.strip.apps) {
            #expect(slab.app == app)
            #expect(slab.icon == session.icon(for: app))
            #expect(slab.name == session.name(for: app))
        }
    }

    @Test("Slabs stand on the shelf hairline, in one row, at the mockup's size")
    func slabsStandOnTheShelf() throws {
        let (_, controller) = try loaded()
        controller.enterOverview()
        let shelf = try #require(controller.overviewForTesting)
        shelf.frame = CGRect(x: 0, y: 0, width: PanelLimits.defaultWidth, height: OverviewSurfaceView.panelHeight)
        shelf.layoutSubtreeIfNeeded()

        let frames = shelf.slabFrames
        #expect(frames.count > 1)
        #expect(frames.allSatisfy { $0.maxY == shelf.shelfHairlineFrame.minY })
        #expect(frames.allSatisfy { $0.height == LedgeMetrics.slabHeight })
        #expect(frames.allSatisfy { $0.width == LedgeMetrics.slabWidth })
        #expect(frames.first!.minX >= 0)
        // Left to right, no overlaps, and the mockup's air between them.
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(b.minX - a.maxX == LedgeMetrics.slabGap)
        }
    }

    // MARK: - The shelf pans (G3.2)

    /// A shelf longer than the panel: nine sessions and the blank slot, which is
    /// what a real machine's catalog looks like and exactly the case the audit
    /// caught. Built here rather than out of the catalog fixture, which holds
    /// three apps and would never overflow anything.
    private func crowded(current: String? = nil, sessions: Int = 9) -> OverviewSurfaceView {
        let shelf = OverviewSurfaceView()
        var slabs = (0..<sessions).map {
            OverviewSurfaceView.Slab(app: "app\($0)", name: "App \($0)", icon: "circle")
        }
        slabs.append(.blank)
        shelf.apply(slabs: slabs, current: current)
        shelf.frame = CGRect(
            x: 0, y: 0,
            width: PanelLimits.defaultWidth,
            height: OverviewSurfaceView.panelHeight
        )
        shelf.layoutSubtreeIfNeeded()
        return shelf
    }

    /// The audit's finding: nine sessions no longer fit, and the old layout paid
    /// for that by slicing the first slab off the panel edge. **Slabs never
    /// shrink** — the shelf is longer than the well and slides.
    @Test("A crowded shelf grows past the well instead of squeezing its slabs")
    func aCrowdedShelfPans() {
        let shelf = crowded()
        #expect(shelf.slabFrames.allSatisfy { $0.width == LedgeMetrics.slabWidth })
        #expect(shelf.contentWidth == OverviewSurfaceView.contentWidth(count: shelf.slabs.count))
        #expect(shelf.contentWidth > shelf.viewportFrame.width, "it does not fit, and does not pretend to")
        #expect(shelf.maxScrollOffset == shelf.contentWidth - shelf.viewportFrame.width)

        // A shelf that fits does not scroll, and stays centred in the well.
        let roomy = crowded(sessions: 2)
        #expect(roomy.maxScrollOffset == 0)
        #expect(roomy.contentWidth == roomy.viewportFrame.width)
        let span = roomy.slabFrames.first!.minX + (roomy.viewportFrame.width - roomy.slabFrames.last!.maxX)
        #expect(abs(roomy.slabFrames.first!.minX - span / 2) < 0.5, "centred, with equal air either side")
    }

    @Test("The wheel slides the shelf, and it stops at both ends")
    func theShelfSlides() throws {
        let shelf = crowded()
        let limit = shelf.maxScrollOffset
        try #require(limit > 0)
        #expect(shelf.scrollOffset == 0, "no current session: it opens at the beginning")
        #expect(!shelf.pan(by: -40), "…and says so, so the wheel goes on to whoever else wants it")

        #expect(shelf.pan(by: 30))
        #expect(shelf.scrollOffset == 30)
        shelf.pan(by: limit * 2)
        #expect(shelf.scrollOffset == limit, "it does not slide off its end")
        #expect(!shelf.pan(by: 40))
        shelf.pan(by: -limit * 2)
        #expect(shelf.scrollOffset == 0, "nor off its beginning")
    }

    /// The blank slot is flow.md's guarantee — "at most one blank exists" and it
    /// is always there. Pushed off the right edge it was not; at the end of a
    /// shelf you can slide, it is.
    @Test("The blank slot is at the trailing end, and sliding to the end shows all of it")
    func theBlankSlotIsReachable() throws {
        let shelf = crowded()
        #expect(shelf.slabs.last?.isBlank == true)
        let blank = try #require(shelf.slabFrames.last)
        #expect(blank.maxX == shelf.contentWidth, "it is the trailing end of the shelf")

        shelf.pan(by: shelf.maxScrollOffset)
        // On screen means: inside the well, once the shelf has been slid over.
        let onScreen = blank.offsetBy(dx: -shelf.scrollOffset, dy: 0)
        #expect(onScreen.minX >= 0)
        #expect(onScreen.maxX <= shelf.viewportFrame.width + 0.5)
    }

    @Test("The shelf opens centred on the session it was zoomed out of")
    func theShelfOpensOnTheCurrentSession() throws {
        // One in the middle: centred exactly, with shelf either side of it.
        let middle = crowded(current: "app4")
        let index = try #require(middle.slabs.firstIndex { $0.app == "app4" })
        let centre = middle.slabFrames[index].midX - middle.scrollOffset
        #expect(abs(centre - middle.viewportFrame.width / 2) < 0.5)
        #expect(middle.scrollOffset > 0 && middle.scrollOffset < middle.maxScrollOffset)

        // One at the far end: as centred as an end allows, and no further.
        let last = crowded(current: "app8")
        #expect(last.scrollOffset == last.maxScrollOffset)
        let lastIndex = try #require(last.slabs.firstIndex { $0.app == "app8" })
        let lastCentre = last.slabFrames[lastIndex].midX - last.scrollOffset
        #expect(lastCentre > last.viewportFrame.width / 2)
        #expect(lastCentre < last.viewportFrame.width)

        // The controller passes what Back points at, so zooming out of a session
        // and zooming out of the ledge cannot disagree about which one it is.
        let (session, controller) = try loaded()
        let app = session.strip.apps[1]
        controller.present(.expanded(app: app), animated: false)
        controller.enterOverview()
        #expect(controller.overviewForTesting?.current == app)
    }

    /// A hard clip reads as a rendering fault; a fade reads as more shelf. The
    /// mask is on whichever side is actually cut, and on neither when the whole
    /// strip fits.
    @Test("The cut edge fades, on the side that is cut")
    func theCutEdgeFades() {
        let shelf = crowded()
        #expect(shelf.edgeFadeSides == (leading: false, trailing: true))

        shelf.pan(by: shelf.maxScrollOffset / 2)
        #expect(shelf.edgeFadeSides == (leading: true, trailing: true))

        shelf.pan(by: shelf.maxScrollOffset)
        #expect(shelf.edgeFadeSides == (leading: true, trailing: false))

        // A shelf that fits is not cut anywhere, so it wears no mask at all.
        #expect(crowded(sessions: 2).edgeFadeSides == (leading: false, trailing: false))
    }

    /// The rise is measured on the shelf, not on the panel: slide the shelf
    /// under a cursor that has not moved and the slab that arrives under it is
    /// the one that lifts.
    @Test("The rise follows the shelf's own coordinates once it is scrolled")
    func theRiseFollowsTheScroll() throws {
        let shelf = crowded()
        try #require(shelf.maxScrollOffset > 0)
        // A cursor parked in the middle of the well, in surface coordinates.
        let parked = shelf.viewportFrame.midX
        shelf.apply(pointerX: shelf.shelfX(fromSurface: parked))
        let before = try #require(shelf.slabRises.firstIndex { $0 > LedgeMetrics.slabRise / 2 })

        shelf.pan(by: LedgeMetrics.slabWidth + LedgeMetrics.slabGap)
        shelf.apply(pointerX: shelf.shelfX(fromSurface: parked))
        let after = try #require(shelf.slabRises.firstIndex { $0 > LedgeMetrics.slabRise / 2 })
        #expect(after == before + 1, "one slab of travel, one slab further along the shelf")
    }

    // MARK: - Slabs rise toward the cursor

    /// design.html §04's page script, as arithmetic: `exp(-d² / 2σ²)`, σ = 72.
    /// One function, so the view and the mockup cannot drift apart.
    @Test("The falloff is design.html's gaussian")
    func theFalloff() {
        #expect(LedgeMetrics.slabMagnification(distance: 0) == 1)
        #expect(abs(LedgeMetrics.slabMagnification(distance: 72) - exp(-0.5)) < 0.0001)
        #expect(LedgeMetrics.slabMagnification(distance: 300) < 0.001)
        // Symmetric: a cursor to the left lifts a slab exactly as much as one
        // the same distance to the right.
        #expect(
            LedgeMetrics.slabMagnification(distance: -40)
                == LedgeMetrics.slabMagnification(distance: 40)
        )
    }

    @Test("The slab under the cursor rises fully, its neighbours partly, the far ones not at all")
    func slabsRise() throws {
        let (_, controller) = try loaded()
        controller.enterOverview()
        let shelf = try #require(controller.overviewForTesting)
        shelf.frame = CGRect(x: 0, y: 0, width: PanelLimits.defaultWidth, height: OverviewSurfaceView.panelHeight)
        shelf.layoutSubtreeIfNeeded()

        let frames = shelf.slabFrames
        try #require(frames.count >= 3)
        shelf.apply(pointerX: frames[0].midX)
        let rises = shelf.slabRises
        #expect(abs(rises[0] - LedgeMetrics.slabRise) < 0.001)
        #expect(rises[1] > 0 && rises[1] < rises[0])
        #expect(rises.dropFirst().allSatisfy { $0 < rises[0] })

        // Pointer off the shelf: every slab flat on it again.
        shelf.apply(pointerX: nil)
        #expect(shelf.slabRises.allSatisfy { $0 == 0 })
    }

    /// Principle 10: "Reduce Motion swaps motion for fades" — it does not
    /// remove affordances. The shelf stops magnifying; the ✕ still appears.
    @Test("Reduce Motion holds the slabs still and keeps the ✕")
    func reduceMotion() throws {
        let (_, controller) = try loaded()
        controller.enterOverview()
        let shelf = try #require(controller.overviewForTesting)
        shelf.reduceMotionOverride = true
        shelf.frame = CGRect(x: 0, y: 0, width: PanelLimits.defaultWidth, height: OverviewSurfaceView.panelHeight)
        shelf.layoutSubtreeIfNeeded()

        shelf.apply(pointerX: shelf.slabFrames[0].midX)
        #expect(!shelf.magnifies)
        #expect(shelf.slabRises.allSatisfy { $0 == 0 }, "nothing moves")
        #expect(shelf.isShowingClose, "…but the ✕ is still a reveal, and still reveals")
    }

    // MARK: - The only ✕ in the product

    @Test("The ✕ belongs to a session: it follows the hover and never lands on the blank slot")
    func theOnlyClose() throws {
        let (_, controller) = try loaded()
        controller.enterOverview()
        let shelf = try #require(controller.overviewForTesting)
        shelf.frame = CGRect(x: 0, y: 0, width: PanelLimits.defaultWidth, height: OverviewSurfaceView.panelHeight)
        shelf.layoutSubtreeIfNeeded()

        #expect(!shelf.isShowingClose, "nothing is hovered yet")
        let frames = shelf.slabFrames
        shelf.apply(pointerX: frames[0].midX)
        #expect(shelf.isShowingClose)
        // Above the slab it belongs to, and travelling with it as it rises.
        let bead = shelf.closeBeadView.frame
        #expect(bead.midX == frames[0].midX)
        #expect(bead.maxY <= frames[0].minY - shelf.slabRises[0])

        // The blank slot has no session to stop.
        shelf.apply(pointerX: frames.last!.midX)
        #expect(!shelf.isShowingClose)
    }

    /// The audit's second finding: with the shelf overflowing, the ✕ for the
    /// clipped first slab floated in the panel's top-left corner, above nothing.
    /// It cannot any more — the bead lives *inside* what pans and what clips, so
    /// it goes where its slab goes and stops where its slab stops.
    @Test("The ✕ is clipped and panned with its slab, never orphaned beside it")
    func theCloseTravelsWithItsSlab() throws {
        let shelf = crowded()
        let bead = shelf.closeBeadView
        #expect(bead.isDescendant(of: shelf.viewportForTesting))
        #expect(bead.superview === shelf.slabViewsForTesting.first?.superview)
        #expect(shelf.viewportForTesting.layer?.masksToBounds == true)

        // The last session's ✕, out at the far end of a shelf that overflows: in
        // surface space it is off the panel entirely until the shelf is slid.
        let index = shelf.slabs.count - 2
        shelf.apply(pointerX: shelf.slabFrames[index].midX)
        try #require(shelf.isShowingClose)
        let parked = shelf.convert(bead.frame, from: bead.superview)
        #expect(parked.minX > shelf.viewportFrame.maxX, "clipped away with its slab")

        shelf.pan(by: shelf.maxScrollOffset)
        shelf.apply(pointerX: shelf.slabFrames[index].midX)
        let slid = shelf.convert(bead.frame, from: bead.superview)
        // Half a point of slack: a fully risen slab's cap lands exactly on the
        // well's top edge, which is what `shelfTopPad` is derived to guarantee.
        #expect(
            shelf.viewportFrame.insetBy(dx: -0.5, dy: -0.5).contains(slid),
            "and inside it once the shelf is slid over"
        )
    }

    @Test("Pressing the ✕ stops that session and leaves the shelf standing")
    func pressingTheClose() throws {
        let (session, controller) = try loaded()
        let victim = session.strip.apps[0]
        controller.present(.expanded(app: victim), animated: false)
        controller.enterOverview()
        let shelf = try #require(controller.overviewForTesting)
        shelf.frame = CGRect(x: 0, y: 0, width: PanelLimits.defaultWidth, height: OverviewSurfaceView.panelHeight)
        shelf.layoutSubtreeIfNeeded()
        shelf.apply(pointerX: shelf.slabFrames[0].midX)

        #expect(shelf.closeBeadView.accessibilityPerformPress())
        #expect(controller.presentation == .overview, "stopping one session does not leave the shelf")
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

    @Test("Clicking a slab jumps to that session; the blank slab opens the blank slot")
    func clickingASlabJumps() throws {
        let (session, controller) = try loaded()
        controller.present(.expanded(app: session.strip.apps[0]), animated: false)
        controller.enterOverview()
        let shelf = try #require(controller.overviewForTesting)

        let second = session.strip.apps[1]
        let slab = try #require(shelf.slabViewsForTesting.first { $0.slab.app == second })
        #expect(slab.accessibilityPerformPress())
        #expect(controller.presentation == .expanded(app: second))

        controller.enterOverview()
        let blank = try #require(shelf.slabViewsForTesting.last)
        #expect(blank.slab.isBlank)
        #expect(blank.accessibilityPerformPress())
        #expect(controller.presentation == .newApp)
    }

    /// The overview is a *mode*, so the strip still walks out of it — and
    /// walking is leaving, not zooming further.
    @Test("Walking the strip from the ledge lands on a session")
    func walkingLeavesTheShelf() throws {
        let (_, controller) = try loaded()
        controller.present(.overview, animated: false)
        #expect(controller.handleSwipe(.left))
        #expect(controller.presentation != .overview)
    }
}
