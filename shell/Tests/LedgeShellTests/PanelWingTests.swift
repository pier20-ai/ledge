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

    @Test("Zones shrink to nothing rather than going negative on a narrow panel")
    func zonesClamp() {
        // Narrower than the cutout plus its margins: there is no room for a wing
        // at all, and the honest answer is a zone of zero width, not a wing
        // hanging over the camera.
        let surface = makeSurface(width: 180)
        let (left, right, dead) = zones(surface)
        #expect(left.width == 0)
        #expect(right.width == 0)
        #expect(dead.width <= 180)

        // And a wide panel gives both zones real room.
        let wide = makeSurface(width: 640)
        let wideZones = zones(wide)
        #expect(wideZones.left.width > 100)
        #expect(wideZones.right.width > 100)
    }

    // MARK: - Shell defaults

    @Test("The left zone names the app; the right zone offers Edit")
    func defaults() {
        let surface = makeSurface()
        surface.setPanelWing(name: "Settings", content: nil, canEdit: true)
        surface.layoutSubtreeIfNeeded()
        let bar = surface.panelWingBarView

        #expect(bar.nameView.stringValue == "Settings")
        #expect(!bar.nameView.isHidden)
        #expect(!bar.editView.isHidden)
        #expect(bar.editView.currentLabel == "Edit")
        // The affordance is trailing-aligned inside its zone, so it hangs off the
        // panel's right edge rather than drifting with the zone's width.
        let right = zones(surface).right
        let edit = surface.convert(bar.editView.bounds, from: bar.editView)
        #expect(abs(edit.maxX - right.maxX) < 0.01)
        #expect(edit.minX >= right.minX - 0.01)
        #expect(bar.editView.currentSize == .s)
    }

    @Test("A surface with no app behind it offers nothing to edit")
    func noAppNoEdit() {
        let surface = makeSurface()
        surface.setPanelWing(name: nil, content: nil, canEdit: false)
        surface.layoutSubtreeIfNeeded()
        #expect(surface.panelWingBarView.editView.isHidden)
        #expect(surface.panelWingBarView.nameView.isHidden)
    }

    @Test("A long app name ellipsizes inside its zone instead of running on")
    func longNameTruncates() {
        let surface = makeSurface()
        let name = String(repeating: "Wide ", count: 40)
        surface.setPanelWing(name: name, content: nil, canEdit: true)
        surface.layoutSubtreeIfNeeded()
        let bar = surface.panelWingBarView
        let label = surface.convert(bar.nameView.bounds, from: bar.nameView)

        let measured = (name as NSString)
            .size(withAttributes: [.font: bar.nameView.font as Any]).width
        #expect(label.width < measured, "the frame must clamp so the cell can ellipsize")
        #expect(label.maxX <= zones(surface).dead.minX + 0.01)
        #expect(bar.nameView.lineBreakMode == .byTruncatingTail)
    }

    // MARK: - App content

    @Test("An app's left wing replaces the name and is clipped to the zone")
    func appWingReplacesName() {
        let surface = makeSurface()
        let content = LedgeWingView()
        surface.setPanelWing(name: "Settings", content: content, canEdit: true)
        surface.layoutSubtreeIfNeeded()
        let bar = surface.panelWingBarView

        #expect(bar.appContentView === content)
        #expect(bar.nameView.isHidden, "an app that names itself twice wastes the zone")
        let frame = surface.convert(content.bounds, from: content)
        #expect(frame.maxX <= zones(surface).dead.minX + 0.01)
        #expect(frame.height <= surface.panelWingRowHeight)

        // Removing it (the app dropped its wing node) restores the name.
        surface.setPanelWing(name: "Settings", content: nil, canEdit: true)
        surface.layoutSubtreeIfNeeded()
        #expect(bar.appContentView == nil)
        #expect(!bar.nameView.isHidden)
        #expect(content.superview == nil, "the outgoing wing must be released, not stranded")
    }

    // MARK: - End to end, through the real engine

    @Test("A `wing` commit routes to the zone, never into the app's content stack")
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

    @Test("The panel reserves the row on top of the app's own measured height")
    func panelHeightIncludesTheRow() throws {
        let session = HostSession()
        session.limits = PanelLimits(maxWidth: 640, maxHeight: 700)
        session.cutoutRowHeight = 34
        session.openReplay()
        session.inject(try Fixtures.envelope("commit-wing.json"))

        let resolved = try #require(session.content(for: "wings"))
        let fitting = resolved.height - HostSession.stripHeight - session.cutoutRowHeight
        #expect(fitting > 0, "the app's own tree still gets real room")
        #expect(session.chromeHeight == HostSession.stripHeight + 34)
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
