import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **Panel wings** — the two zones flanking the hardware cutout at the top of the
/// expanded panel (spec §5 `wing`). Distinct from the collapsed §3.3 wings in
/// `WingGeometryTests`: those are live-activity areas on the pill.
///
/// What this suite exists to keep true is one sentence: *an app cannot draw
/// under the camera*. That was previously a convention, and every app in the
/// repo broke it — chess's engine label, blocks's key hints and settings' worker
/// count were all partly invisible on a notched Mac. The fix is structural, so
/// the assertions are structural: the content host starts below the row, and the
/// zones stop at the dead zone's edge whatever they are given.
@MainActor
@Suite("Panel wings (spec §5)")
struct PanelWingTests {
    private func makeSurface(
        width: CGFloat = PanelLimits.defaultWidth,
        height: CGFloat = 300
    ) -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback                      // 210 × 34, the mockup
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        surface.present(
            .expanded(app: "settings"),
            content: FlippedView(),
            width: width,
            height: height,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    /// A zone's rect in the *surface's* coordinates — the space the hardware
    /// cutout is described in, so the two are directly comparable.
    private func zones(_ surface: ShellSurfaceView) -> (left: CGRect, right: CGRect, dead: CGRect) {
        surface.layoutSubtreeIfNeeded()
        let bar = surface.panelWingBarView
        return (
            surface.convert(bar.leftZoneRect, from: bar),
            surface.convert(bar.rightZoneRect, from: bar),
            surface.convert(bar.deadZoneRect, from: bar)
        )
    }

    // MARK: - The exclusion row

    @Test("The app's tree starts below a row as tall as the cutout")
    func contentStartsBelowTheRow() {
        let surface = makeSurface()
        let host = surface.panelContentHost
        let row = surface.panelWingRowHeight
        #expect(row == surface.metrics.closedHeight)

        let hostRect = surface.convert(host.bounds, from: host)
        #expect(hostRect.minY == row, "content began at \(hostRect.minY), row is \(row) tall")
        // …and the cutout is entirely above it, which is the whole claim.
        #expect(hostRect.minY >= surface.hardwareCutoutRect.maxY)
    }

    @Test("Collapsing gives the row back — the pill IS the cutout")
    func collapsedHasNoRow() {
        let surface = makeSurface()
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()
        let host = surface.panelContentHost
        #expect(surface.convert(host.bounds, from: host).minY == 0)
        #expect(surface.panelWingBarView.isHidden)
    }

    @Test("Neither zone ever overlaps the dead zone")
    func zonesFlankTheCutout() {
        for width in [PanelLimits.minWidth, 440, 520, 640] as [CGFloat] {
            let surface = makeSurface(width: width)
            let (left, right, dead) = zones(surface)
            #expect(left.maxX <= dead.minX + 0.01, "left zone crossed the cutout at \(width)")
            #expect(right.minX >= dead.maxX - 0.01, "right zone crossed the cutout at \(width)")
            // The dead zone really does cover the housing, with margin either
            // side — an edge flush with a hole in the display reads as clipped.
            let housing = surface.hardwareCutoutRect
            #expect(dead.minX <= housing.minX)
            #expect(dead.maxX >= housing.maxX)
            #expect(dead.width == housing.width + LedgeMetrics.panelWingCutoutMargin * 2)
        }
    }

    /// **The bar is the panel** (G6). It used to be a constant span around the
    /// cutout whatever session was up; now the glass is the constant — every
    /// default session is `PanelLimits.defaultWidth` — and the bar is exactly
    /// that glass, so the zones run from the panel's edge to the dead zone.
    /// A session that asked for more (the exception) gets wider zones, and one
    /// that tried to be narrower is floored so the islands still fit.
    @Test("The zones span the panel: identical at the fixed width, floored below it")
    func zonesAreThePanel() {
        var lefts: [CGRect] = []
        var rights: [CGRect] = []
        for width in [PanelLimits.defaultWidth, PanelLimits.defaultWidth] {
            let surface = makeSurface(width: width)
            let (left, right, dead) = zones(surface)
            lefts.append(left)
            rights.append(right)
            // Real room on both sides for the wider island (the 67 pt walker
            // plus the tear bead) with air.
            #expect(left.width > 67)
            #expect(right.width > 101)
            #expect(dead.width == surface.hardwareCutoutRect.width
                    + LedgeMetrics.panelWingCutoutMargin * 2)
            // The zones reach the glass's own ends, less the bar's pad.
            let body = surface.currentShapeRect.insetBy(dx: ShellSurfaceView.fillet, dy: 0)
            #expect(abs(left.minX - (body.minX + LedgeMetrics.panelWingPad)) < 0.01)
            #expect(abs(right.maxX - (body.maxX - LedgeMetrics.panelWingPad)) < 0.01)
        }
        #expect(Set(lefts.map { "\($0)" }).count == 1)
        #expect(Set(rights.map { "\($0)" }).count == 1)

        // Below the floor the bar is the floor, never the session's width: the
        // islands always have their glass — at the floor, *exactly* the run
        // they need, which is how the floor was derived.
        let narrow = makeSurface(width: 180)
        let (left, right, _) = zones(narrow)
        #expect(left.width >= 67)
        #expect(right.width >= 101)
        #expect(narrow.visitBarRect.width == narrow.visitFloorWidth)
    }

    // MARK: - Ledge's controls (flow.md: in a visit, the wings are Ledge's)

    /// The law that replaced "the left zone names the app, the right offers
    /// Edit". Both zones are the shell's now, and an app has no say in either.
    @Test("The left zone is the glass toggle; the right zone is ‹|›")
    func controlsFillBothZones() {
        let surface = makeSurface()
        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        surface.layoutSubtreeIfNeeded()
        let bar = surface.panelWingBarView

        #expect(!bar.splitView.isHidden)
        #expect(!bar.walkerView.isHidden)

        // Neither control crosses into the camera's dead zone.
        let (left, right, dead) = zones(surface)
        let toggle = surface.convert(bar.splitView.bounds, from: bar.splitView)
        let walker = surface.convert(bar.walkerView.bounds, from: bar.walkerView)
        #expect(toggle.maxX <= dead.minX + 0.01)
        #expect(walker.minX >= dead.maxX - 0.01)
        #expect(toggle.minX >= left.minX - 0.01)
        #expect(walker.maxX <= right.maxX + 0.01)
    }

    /// **Principle 8: persistent controls stand still.** The old bottom strip
    /// moved every control whenever the panel resized, so walking from one
    /// session to the next slid the next control out from under the pointer.
    ///
    /// Since G6 the law is kept by the glass, not the camera: every default
    /// session is the same fixed width, and the islands hug **its** edges —
    /// [⌂|✦] at the far left, the walker's run ending at the far right (Manu:
    /// hugging the cutout "looked extremely weird"; the parked window's G2.9
    /// layout is now the only layout). Same width, same two places.
    @Test("Switching sessions never moves a control: they hug the panel's edges")
    func controlsDoNotMoveWithPanelWidth() {
        var togglePositions: [CGFloat] = []
        var walkerPositions: [CGFloat] = []
        for height in [200, 300, 600] as [CGFloat] {
            let surface = makeSurface(height: height)
            surface.setPanelWing(mode: .stage, canToggleGlass: true)
            surface.layoutSubtreeIfNeeded()
            let bar = surface.panelWingBarView
            // In the SURFACE's coordinates — the space the hardware cutout is
            // described in, and therefore the space "on screen" means.
            let toggle = surface.convert(bar.splitView.bounds, from: bar.splitView)
            let walker = surface.convert(bar.walkerView.bounds, from: bar.walkerView)
            let tear = surface.convert(bar.tearView.bounds, from: bar.tearView)
            togglePositions.append(toggle.minX)
            walkerPositions.append(walker.maxX)
            // Edge-anchored: the split's leading edge one pad in from the
            // glass's left end, the run's trailing edge one pad in from its
            // right end.
            let body = surface.currentShapeRect.insetBy(dx: ShellSurfaceView.fillet, dy: 0)
            #expect(abs(toggle.minX - (body.minX + LedgeMetrics.panelWingPad)) < 0.01)
            let runEnd = bar.tearView.isHidden ? walker.maxX : tear.maxX
            #expect(abs(runEnd - (body.maxX - LedgeMetrics.panelWingPad)) < 0.01)
            // …and clear of the camera, which is the other half of the law.
            #expect(toggle.maxX <= zones(surface).dead.minX + 0.01)
            #expect(walker.minX >= zones(surface).dead.maxX - 0.01)
        }
        // Every default session is the fixed width (`PanelLimits` sees to
        // it), so every default session puts the controls in the same place.
        #expect(Set(togglePositions.map { round($0) }).count == 1)
        #expect(Set(walkerPositions.map { round($0) }).count == 1)
    }

    /// The exception, and what it costs: an app that asked for more glass
    /// (`meta.panel.width`, G6's one escape hatch) moves the islands to *its*
    /// edges. That is the point of anchoring to the edges — a wider well is
    /// framed by its own controls, not by controls left behind at the old
    /// width — and it is why no default app declares one.
    @Test("A wider session takes its islands with it, to its own edges")
    func widerSessionMovesTheIslandsToItsEdges() {
        let fixed = makeSurface()
        let wide = makeSurface(width: 640)
        for surface in [fixed, wide] {
            surface.setPanelWing(mode: .stage, canToggleGlass: true)
            surface.layoutSubtreeIfNeeded()
        }
        let edge = { (s: ShellSurfaceView) -> CGFloat in
            let bar = s.panelWingBarView
            return s.convert(bar.splitView.bounds, from: bar.splitView).minX
        }
        let body = wide.currentShapeRect.insetBy(dx: ShellSurfaceView.fillet, dy: 0)
        #expect(abs(edge(wide) - (body.minX + LedgeMetrics.panelWingPad)) < 0.01)
        #expect(edge(wide) < edge(fixed), "more glass, and the island went to its end")
    }

    /// The geometry is identical regardless of *which* session is on screen,
    /// which is the other half of "wings never move": an app cannot put anything
    /// in either zone, so there is nothing for an app to change.
    @Test("The bar has the same two controls for every session, and only those")
    func geometryIsIdenticalAcrossApps() {
        let surface = makeSurface()
        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        surface.layoutSubtreeIfNeeded()
        let bar = surface.panelWingBarView
        // In the SURFACE's coordinates, not the bar's: the bar is as wide as the
        // panel, so a frame measured inside it moves by half the width change
        // even when nothing moved on screen. Screen space is what the law is
        // about.
        let before = surface.convert(bar.splitView.bounds, from: bar.splitView)

        // A different session, a different height, the editor showing — at
        // the fixed width, as every default session is (G6).
        surface.present(
            .chat(app: "chess"),
            content: FlippedView(),
            width: PanelLimits.defaultWidth,
            height: 360,
            animated: false
        )
        surface.setPanelWing(mode: .editor, canToggleGlass: true)
        surface.layoutSubtreeIfNeeded()
        // G2.6: the editor wears ‹ Back, in the split's exact anchorage — only
        // the island changed, not the place. Since G6 the anchorage is the
        // leading edge (the islands hug the glass's ends), so that is the
        // edge that must not move.
        #expect(bar.splitView.isHidden)
        #expect(!bar.backView.isHidden)
        let after = surface.convert(bar.backView.bounds, from: bar.backView)
        #expect(abs(after.minX - before.minX) < 0.01)
        #expect(after.height == before.height)
    }

    /// **`‹|›` is ONE bead, split** (design.html §01 `.wpair`: a single capsule
    /// holding `‹`, a 1 pt rule, `›`). It shipped as two circular beads with a
    /// hairline parked between them, which on device read as two controls that
    /// happened to be adjacent — the defect this suite now pins shut.
    ///
    /// One background, one outline, three targets: walk back, walk forward, and
    /// the seam that opens **the ledge** (a later phase — wired now so the two
    /// halves either side of it never have to move again).
    @Test("The walker is one split bead: two halves that meet, and a seam")
    func walkerShape() {
        let surface = makeSurface()
        surface.layoutSubtreeIfNeeded()
        let walker = surface.panelWingBarView.walkerView
        walker.layoutSubtreeIfNeeded()

        // One silhouette: the capsule is the *control's*, and the halves have no
        // radius of their own to give it away.
        #expect(walker.layer?.cornerRadius == LedgeMetrics.capsule(walker.bounds.height))
        #expect(walker.layer?.masksToBounds == true)
        #expect(walker.previousZone.layer?.cornerRadius == 0)
        #expect(walker.nextZone.layer?.cornerRadius == 0)

        // The halves *meet* — no gap for the black glass to show through, which
        // is what would make it two beads again.
        #expect(walker.previousZone.frame.maxX == walker.nextZone.frame.minX)
        #expect(walker.previousZone.frame.minX == 0)
        #expect(walker.nextZone.frame.maxX == walker.bounds.width)
        #expect(walker.previousZone.frame.height == walker.bounds.height)

        // The rule sits on the seam; the *lane* around it is the hit target,
        // because a one-point click target is not a control.
        #expect(walker.dividerFrame.width == LedgeMetrics.hairline)
        #expect(abs(walker.dividerFrame.midX - walker.bounds.midX) < 0.01)
        #expect(walker.dividerLaneRect.width == LedgeMetrics.walkerDividerLane)
        #expect(LedgeMetrics.walkerDividerLane > LedgeMetrics.hairline)

        // Three zones, and the seam belongs to neither half.
        #expect(walker.zone(at: CGPoint(x: 4, y: 14)) == .previous)
        #expect(walker.zone(at: CGPoint(x: walker.bounds.midX, y: 14)) == .overview)
        #expect(walker.zone(at: CGPoint(x: walker.bounds.maxX - 4, y: 14)) == .next)

        #expect(walker.previousZone.accessibilityLabel() == "Previous session")
        #expect(walker.nextZone.accessibilityLabel() == "Next session")
    }

    /// The states live in the halves, not in the bead: the zone under the cursor
    /// brightens and the one you press sinks, while the capsule around them both
    /// does nothing at all.
    @Test("Hover and press are per zone; the bead itself never changes")
    func walkerZoneStates() {
        let surface = makeSurface()
        surface.layoutSubtreeIfNeeded()
        let walker = surface.panelWingBarView.walkerView
        walker.layoutSubtreeIfNeeded()

        let rest = [LedgeTheme.beadFillTop, LedgeTheme.beadFillBottom]
        let lit = [LedgeTheme.beadFillTopHover, LedgeTheme.beadFillBottomHover]
        #expect(walker.previousZone.fillColors == rest)
        #expect(walker.nextZone.fillColors == rest)

        walker.previousZone.isHovered = true
        #expect(walker.previousZone.fillColors == lit)
        // The other half is untouched — that is the whole point of a split
        // control, and a capsule that lit up as one would be telling the user it
        // is a single button.
        #expect(walker.nextZone.fillColors == rest)
        #expect(walker.layer?.backgroundColor == nil)

        // Pressed, the light comes from the wrong side: the same two stops,
        // reversed, which is what a dent looks like.
        walker.previousZone.isPressed = true
        #expect(walker.previousZone.fillColors == [lit[1], lit[0]])
        // …and it sinks rather than shrinking.
        #expect(walker.previousZone.layer?.affineTransform().ty == LedgeMetrics.beadPressSink)
        walker.previousZone.isPressed = false
        #expect(walker.previousZone.layer?.affineTransform().ty == 0)
    }

    // MARK: - End to end, through the real engine

    /// The `wing` node still routes **out** of the app's content stack, which is
    /// the law this suite was written for and the one that has not changed: an
    /// app cannot draw under the camera. Where its view goes has changed — in a
    /// visit both zones are Ledge's controls now (flow.md), so a mounted wing is
    /// held and not shown. Kept working rather than deleted: removing a §5 kind
    /// is a protocol change, and the placement discipline is worth keeping
    /// whatever the zone eventually holds.
    @Test("A `wing` commit routes out of the app's content stack")
    func wingCommitRoutesToTheZone() throws {
        let session = HostSession()
        session.openReplay()
        session.inject(try Fixtures.envelope("commit-wing.json"))

        let wing = try #require(session.panelWing(for: "wings"))
        #expect(wing is LedgeWingView)

        // The root tree knows nothing about it: the app's content is the stack
        // and the one text node it kept, and the wing's two children went to the
        // wing instead. That is the fix — a top row an app renders can no longer
        // be a top row the camera covers.
        let root = try #require(session.content(for: "wings")).view
        root.layoutSubtreeIfNeeded()
        #expect(!descendants(of: root).contains { $0 === wing })

        let texts = descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts == ["APPS"])
        let wingTexts = descendants(of: wing).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(wingTexts == ["●", "4 workers · 38 MB"])

        // Updates on wing children land normally.
        session.inject(try Fixtures.envelope("commit-wing-update.json"))
        let updated = descendants(of: wing).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(updated == ["●", "5 workers · 41 MB"])
    }

    @Test("Removing the wing — or the root it hangs off — releases the zone")
    func wingRemoval() throws {
        let session = HostSession()
        session.openReplay()
        session.inject(try Fixtures.envelope("commit-wing.json"))
        #expect(session.panelWing(for: "wings") != nil)

        session.inject(Envelope(app: "wings", seq: 5, type: "commit", payload: .object([
            "mutations": .array([.object(["op": .string("remove"), "id": .int(2)])]),
        ])))
        #expect(session.panelWing(for: "wings") == nil)

        // And a root that goes takes its wing with it. The wing is deliberately
        // not in the root's *view* hierarchy, so this cannot fall out of the
        // subtree walk — it has to be stated. (A second session, because seq is
        // monotonic per app per generation and replaying the mount would be
        // stale, §2.)
        let fresh = HostSession()
        fresh.openReplay()
        fresh.inject(try Fixtures.envelope("commit-wing.json"))
        #expect(fresh.panelWing(for: "wings") != nil)
        fresh.inject(Envelope(app: "wings", seq: 6, type: "commit", payload: .object([
            "mutations": .array([.object(["op": .string("remove"), "id": .int(1)])]),
        ])))
        #expect(fresh.panelWing(for: "wings") == nil)
    }

    /// **Panel height = content fit + the exclusion row, and nothing else.**
    /// The 42 pt app strip this used to add is gone with the bar (flow.md).
    @Test("The panel reserves the cutout row on top of the app's measured height")
    func panelHeightIncludesTheRow() throws {
        let session = HostSession()
        session.limits = PanelLimits(maxWidth: 640, maxHeight: 700)
        session.cutoutRowHeight = 34
        session.openReplay()
        session.inject(try Fixtures.envelope("commit-wing.json"))

        let resolved = try #require(session.content(for: "wings"))
        let fitting = resolved.height - session.cutoutRowHeight
        #expect(fitting > 0, "the app's own tree still gets real room")
        #expect(session.chromeHeight == 34, "the bottom bar is gone; one row is all a panel spends")
    }

    @Test("A right-hand wing from an app is a §5 validation error (§3.1: all or nothing)")
    func rightWingRejected() throws {
        let tree = ShadowTree()
        let mutations = try Fixtures.envelope("invalid-commit-right-wing.json")
            .decodePayload(CommitPayload.self).mutations
        guard case .failure(let failure) = tree.apply(mutations) else {
            Issue.record("a right wing must not validate")
            return
        }
        #expect(failure == .badProps(id: 2, key: "side"))
        // All or nothing: the root the same batch declared did not land either.
        #expect(tree.isEmpty)
    }

    @Test("A wing that is not a direct child of the root is rejected too")
    func nestedWingRejected() throws {
        let tree = ShadowTree()
        let mutations = try Fixtures.envelope("invalid-commit-nested-wing.json")
            .decodePayload(CommitPayload.self).mutations
        guard case .failure(let failure) = tree.apply(mutations) else {
            Issue.record("a nested wing must not validate")
            return
        }
        #expect(failure == .misplacedZone(id: 3, kind: .wing))
        #expect(tree.isEmpty)
    }
}

/// Every view under `root`, depth first. The panel-wing assertions are about
/// *where a node ended up*, which is a question about the whole subtree.
@MainActor
func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}
