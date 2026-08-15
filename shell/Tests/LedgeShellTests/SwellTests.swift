import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The swell** — the notch growing down and out (principle 7, design.html §03).
///
/// Two surfaces share it: the **notification** (the app interrupting) and the
/// **summary** (the user asking). This suite is about the things that are true
/// of both — one silhouette, the cutout excluded, the shadow ramp's `swell`
/// rung — plus the one thing that is true of only the summary: the chevron the
/// app cannot remove.
@MainActor
@Suite("The swell — notification & summary (flow.md, principle 7)")
struct SwellTests {
    private func makeSurface() -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback                      // 210 × 34
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        return surface
    }

    /// A real summary node, built the way the renderer builds one.
    private func renderedSummary() throws -> NSView {
        let renderer = ProtocolRenderer()
        let mutations = try Fixtures.envelope("commit-summary.json")
            .decodePayload(CommitPayload.self).mutations
        renderer.applyCommit(app: "chess", mutations: mutations)
        return try #require(renderer.summaryView(for: "chess"))
    }

    // MARK: - The node

    @Test("A summary is a shell zone: mounted, but never inside the app's content")
    func summaryIsNotInTheContentStack() throws {
        let renderer = ProtocolRenderer()
        let mutations = try Fixtures.envelope("commit-summary.json")
            .decodePayload(CommitPayload.self).mutations
        renderer.applyCommit(app: "chess", mutations: mutations)

        let summary = try #require(renderer.summaryView(for: "chess"))
        let root = try #require(renderer.rootView(for: "chess"))
        // The panel must not grow a copy of the summary. A session that says
        // "White +0.8 · your move" on hover is not asking for that line to
        // appear above its board as well.
        #expect(!descendants(of: root).contains(summary))
        #expect(!descendants(of: summary).isEmpty)
        // The board itself is still in the panel, where it belongs.
        #expect(descendants(of: root).contains { $0 is ProtocolCanvasView })
    }

    /// Declaring a summary is what makes a session **heavy** (principle 8), and
    /// the shell asks exactly this question at Th.
    @Test("A summary node is the answer to `is this session heavy`")
    func declaresSummary() throws {
        let renderer = ProtocolRenderer()
        renderer.applyCommit(
            app: "chess",
            mutations: try Fixtures.envelope("commit-summary.json")
                .decodePayload(CommitPayload.self).mutations
        )
        #expect(renderer.declaresSummary(for: "chess"))

        // A session with a `mini` and no `summary` is light: it can interrupt,
        // but it owes the hover nothing and opens straight into the visit.
        renderer.applyCommit(
            app: "music",
            mutations: try Fixtures.envelope("commit-mini.json")
                .decodePayload(CommitPayload.self).mutations
        )
        #expect(!renderer.declaresSummary(for: "music"))
        #expect(renderer.miniView(for: "music") != nil)
        #expect(renderer.summaryView(for: "music") == nil)
    }

    /// An app that drops its summary stops being heavy, immediately. Stated
    /// rather than inferred: the zone ids are not in the root's *view*
    /// hierarchy, so nothing about removing a subtree reaches them by accident.
    @Test("Dropping the summary node — or the root — makes the session light again")
    func summaryRemoval() throws {
        let session = HostSession()
        session.openReplay()
        session.inject(try Fixtures.envelope("commit-summary.json"))
        #expect(session.declaresSummary(for: "chess"))

        session.inject(Envelope(app: "chess", seq: 5, type: "commit", payload: .object([
            "mutations": .array([.object(["op": .string("remove"), "id": .int(2)])]),
        ])))
        #expect(!session.declaresSummary(for: "chess"))

        let fresh = HostSession()
        fresh.openReplay()
        fresh.inject(try Fixtures.envelope("commit-summary.json"))
        fresh.inject(Envelope(app: "chess", seq: 6, type: "commit", payload: .object([
            "mutations": .array([.object(["op": .string("remove"), "id": .int(1)])]),
        ])))
        #expect(!fresh.declaresSummary(for: "chess"))
    }

    // MARK: - The chevron

    /// flow.md: "The summary always shows a quiet open affordance — it must be
    /// obvious that a click opens the full thing." Drawn by the shell, outside
    /// the app's node, so an app cannot forget it or take it away.
    @Test("The summary carries a shell-drawn chevron; the notification does not")
    func chevronBelongsToTheShell() throws {
        let swell = MiniContentView()
        swell.adopt(try renderedSummary())
        #expect(!swell.showsOpenAffordance, "a notification promises nothing")
        #expect(swell.chevronView.isHidden)

        swell.setShowsOpenAffordance(true)
        #expect(swell.chevronView.isHidden == false)
        // ink-3: quiet enough to be an affordance rather than a control.
        #expect(swell.chevronView.contentTintColor == LedgeTheme.tertiary)
    }

    @Test("The chevron is trailing, and paid for out of the surface, not the app")
    func chevronGeometry() throws {
        let content = try renderedSummary()
        let plain = MiniContentView()
        plain.adopt(content)
        let withoutChevron = plain.preferredSize(cutoutWidth: 210, maxWidth: 640)

        let swell = MiniContentView()
        swell.setShowsOpenAffordance(true)
        swell.adopt(try renderedSummary())
        let withChevron = swell.preferredSize(cutoutWidth: 210, maxWidth: 640)

        // The surface pays: same content, wider surface, same height. The app's
        // row never shrinks to make space for something it did not ask for.
        #expect(withChevron.width >= withoutChevron.width)
        #expect(withChevron.height == withoutChevron.height)

        swell.frame = CGRect(origin: .zero, size: withChevron)
        swell.layoutSubtreeIfNeeded()
        let chevron = swell.chevronView.frame
        #expect(chevron.maxX <= swell.bounds.width - MiniContentView.padX + 0.01)
        #expect(abs(chevron.midY - swell.bounds.midY) < 1)
    }

    // MARK: - The geometry

    /// Principle 7: "the physical notch is an exclusion zone — nothing ever
    /// renders behind the cutout; content wraps around it." A swell hangs from
    /// the top of the screen like the panel does, so it reserves the same row.
    @Test("A swell reserves the cutout row: the payload sits strictly below it")
    func swellReservesTheCutoutRow() {
        for presentation in [ShellPresentation.notification(app: "music"), .summary(app: "chess")] {
            let surface = makeSurface()
            let content = FlippedView()
            surface.present(presentation, content: content, width: 300, height: 90, animated: false)
            surface.layoutSubtreeIfNeeded()

            let host = surface.panelContentHost
            let hostRect = surface.convert(host.bounds, from: host)
            #expect(hostRect.minY == surface.panelWingRowHeight, "\(presentation)")
            #expect(hostRect.minY >= surface.hardwareCutoutRect.maxY, "\(presentation)")
        }
    }

    /// A swell is the notch *widening*, never pinching in. The shape is centred
    /// on the cutout like the panel, not anchored beside it like the pill.
    @Test("A swell is centred on the cutout and never narrower than it")
    func swellIsCentredAndWide() {
        let surface = makeSurface()
        surface.present(
            .summary(app: "chess"),
            content: FlippedView(),
            width: 300,
            height: 90,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        let shape = surface.currentShapeRect
        let cutout = surface.hardwareCutoutRect
        #expect(abs(shape.midX - surface.bounds.midX) < 0.01)
        #expect(shape.width >= cutout.width)
        #expect(shape.height > cutout.height, "down as well as out")
    }

    /// The shadow ramp's `swell` rung (F1's Theme). A swell is a breath off the
    /// wall; the panel hangs from it; a collapsed notch casts nothing.
    @Test("A swell lights the swell rung, the visit the panel rung, the pill none")
    func shadowRung() {
        let surface = makeSurface()
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()
        #expect(surface.shadowOpacity == 0)

        surface.present(
            .notification(app: "music"),
            content: FlippedView(),
            width: 300,
            height: 90,
            animated: false
        )
        #expect(surface.shadowOpacity == LedgeShadow.swell.opacity)

        surface.present(
            .expanded(app: "music"),
            content: FlippedView(),
            width: 440,
            height: 300,
            animated: false
        )
        #expect(surface.shadowOpacity == LedgeShadow.panel.opacity)
    }

    // MARK: - The promissory swell (hover < Th)

    /// flow.md: "hover < Th → a small promissory swell of the notch, nothing
    /// more". A few points, down and out. The old `hoverBumpWidth` was 14 pt of
    /// pure width and it was announcing an *open* the hover was about to
    /// perform; this announces only that the notch noticed.
    @Test("The promise grows the notch a few points, down and out")
    func promiseGrowsTheNotch() {
        let surface = makeSurface()
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()
        let resting = surface.currentShapeRect

        surface.setPromise(true)
        surface.layoutSubtreeIfNeeded()
        let promised = surface.currentShapeRect
        #expect(surface.isPromising)
        #expect(promised.width == resting.width + LedgeInteraction.promiseWidth)
        #expect(promised.height == resting.height + LedgeInteraction.promiseHeight)
        // Symmetric about the cutout: a promise that drifted sideways would read
        // as the notch sliding, not swelling.
        #expect(abs(promised.midX - resting.midX) < 0.01)
        // A few points, not a surface. If this ever grows past a wing's width
        // it has stopped being a promise.
        #expect(LedgeInteraction.promiseWidth < 12)

        surface.setPromise(false)
        surface.layoutSubtreeIfNeeded()
        #expect(!surface.isPromising)
        #expect(surface.currentShapeRect == resting)
    }

    /// The promise is the *only* sub-threshold hover response. There is no
    /// `hoverPolicy`, no open delay and no close delay left to configure, and a
    /// promise on an open panel would be the notch swelling behind the panel.
    @Test("A promise is refused by the visit and by a swell")
    func promiseOnlyBelowTheVisit() {
        let surface = makeSurface()
        surface.present(
            .expanded(app: "music"),
            content: FlippedView(),
            width: 440,
            height: 300,
            animated: false
        )
        surface.setPromise(true)
        #expect(!surface.isPromising)

        surface.present(
            .summary(app: "chess"),
            content: FlippedView(),
            width: 300,
            height: 90,
            animated: false
        )
        surface.setPromise(true)
        #expect(!surface.isPromising, "the swell IS the surface the promise was promising")
    }

    /// No slop. The region used to carry four margins — 26 pt around the open
    /// panel, 8 and 6 around the pill — because leaving it *closed the panel*.
    /// Nothing leaving it closes anything on its own now, so "pointer fully
    /// away" (flow.md) means outside the shape.
    @Test("The pointer region is the shape, with no forgiveness margin")
    func pointerRegionIsTheShape() {
        let surface = makeSurface()
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()
        let shape = surface.currentShapeRect

        // A point just inside the shape hits; a point just outside passes
        // through to whatever is beneath.
        let inside = CGPoint(x: shape.midX, y: shape.midY)
        let outside = CGPoint(x: shape.maxX + 4, y: shape.midY)
        #expect(surface.hitTest(inside) != nil)
        #expect(surface.hitTest(outside) == nil)
    }
}
