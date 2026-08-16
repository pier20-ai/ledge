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
/// repo broke it — chess's engine label, tetris's key hints and settings' worker
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

    /// **The bar does not answer to the panel.** It used to be exactly as wide
    /// as whatever session was on screen, so a 180 pt app left no room for a
    /// wing and a 640 pt one gave both zones a hundred points of slack. It is a
    /// constant now (`visitBarWidth`), so the zones are constants too.
    @Test("The zones are the same on the narrowest session and the widest")
    func zonesDoNotAnswerToThePanel() {
        var lefts: [CGRect] = []
        var rights: [CGRect] = []
        for width in [180, PanelLimits.minWidth, 440, 640] as [CGFloat] {
            let surface = makeSurface(width: width)
            let (left, right, dead) = zones(surface)
            lefts.append(left)
            rights.append(right)
            // Real room on every one of them — enough for the wider island
            // (the 67 pt walker) with air, which the narrow panel never had.
            // (The reach shrank from 150 to what the islands need at G2.5.)
            #expect(left.width > 67)
            #expect(right.width > 67)
            #expect(dead.width == surface.hardwareCutoutRect.width
                    + LedgeMetrics.panelWingCutoutMargin * 2)
        }
        #expect(Set(lefts.map { "\($0)" }).count == 1)
        #expect(Set(rights.map { "\($0)" }).count == 1)
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

    /// **Principle 8: persistent controls are notch-anchored, never
    /// panel-anchored.** This is the assertion that pays for the whole redesign:
    /// the old bottom strip moved every control whenever the panel resized, so
    /// walking from a 440 pt session to a 520 pt one slid the next control out
    /// from under the pointer.
    ///
    /// They hug the **cutout** as floating islands (Manu's G2.4 conclusion:
    /// the bar band is gone, the silhouette is one uniform width, and the
    /// controls sit just beside the physical notch).
    @Test("Switching sessions never moves a control: they hug the cutout")
    func controlsDoNotMoveWithPanelWidth() {
        var togglePositions: [CGFloat] = []
        var walkerPositions: [CGFloat] = []
        for width in [PanelLimits.minWidth, PanelLimits.defaultWidth, 520, 640] as [CGFloat] {
            let surface = makeSurface(width: width)
            surface.setPanelWing(mode: .stage, canToggleGlass: true)
            surface.layoutSubtreeIfNeeded()
            let bar = surface.panelWingBarView
            // In the SURFACE's coordinates — the space the hardware cutout is
            // described in, and therefore the space "on screen" means.
            let toggle = surface.convert(bar.splitView.bounds, from: bar.splitView)
            let walker = surface.convert(bar.walkerView.bounds, from: bar.walkerView)
            togglePositions.append(toggle.minX)
            walkerPositions.append(walker.maxX)
            // Inner-anchored: trailing edge against the dead zone's near side,
            // leading edge against its far side.
            let deadRect = zones(surface).dead
            #expect(abs(toggle.maxX - deadRect.minX) < 0.01)
            #expect(abs(walker.minX - deadRect.maxX) < 0.01)
            // …and still clear of the camera, which is the other half of the law.
            #expect(toggle.maxX <= zones(surface).dead.minX + 0.01)
            #expect(walker.minX >= zones(surface).dead.maxX - 0.01)
        }
        #expect(Set(togglePositions.map { round($0) }).count == 1)
        #expect(Set(walkerPositions.map { round($0) }).count == 1)
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

        // A different session, a different width, the editor showing.
        surface.present(
            .chat(app: "chess"),
            content: FlippedView(),
            width: 520,
            height: 360,
            animated: false
        )
        surface.setPanelWing(mode: .editor, canToggleGlass: true)
        surface.layoutSubtreeIfNeeded()
        let after = surface.convert(bar.splitView.bounds, from: bar.splitView)
        // Only the word changed. The two labels differ by a point or two in
        // width, so the frame is compared where it is anchored.
        #expect(bar.splitView.chatZone.isLit)
        #expect(abs(after.maxX - before.maxX) < 0.01)
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
