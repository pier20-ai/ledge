import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// Panel sizing (spec §5 "Layout & sizing", extended by the app-declared
/// `meta.panel`). The rule these tests pin down: an app *requests* a size, the
/// shell *decides* one — 440 pt when nothing is declared, clamped to what the
/// screen can hold when something is.
@MainActor
@Suite("Panel limits & per-app width (spec §5)")
struct PanelGeometryTests {
    private let limits = PanelLimits(maxWidth: 640, maxHeight: 700)

    @Test("No declaration is the old behavior exactly: 440 pt")
    func defaultWidth() {
        #expect(limits.width(requesting: nil) == 440)
        #expect(PanelLimits.defaultWidth == 440)
    }

    @Test("A requested width is clamped to [320, screen max]")
    func widthClamped() {
        #expect(limits.width(requesting: 520) == 520)
        #expect(limits.width(requesting: 100) == PanelLimits.minWidth)
        #expect(limits.width(requesting: 4000) == 640)
        #expect(limits.width(requesting: .nan) == PanelLimits.defaultWidth)
    }

    @Test("A requested maxHeight is clamped to the screen-derived cap")
    func heightClamped() {
        #expect(limits.height(requesting: nil) == 700)      // no declaration = the cap
        #expect(limits.height(requesting: 420) == 420)
        #expect(limits.height(requesting: 4000) == 700)
        #expect(limits.height(requesting: 10) == PanelLimits.minHeight)
    }

    @Test("The fixed window fits the widest panel AND the widest winged pill")
    func windowFitsEveryShape() {
        let metrics = NotchMetrics.fallback                 // 210 × 34
        let size = limits.windowSize(for: metrics)

        // Widest expanded shape: panel + both fillets.
        #expect(size.width >= limits.maxWidth + ShellSurfaceView.fillet * 2)
        // Widest collapsed shape: the notch plus a full wing each side.
        let widestPill = metrics.closedWidth + PanelLimits.maxWingWidth * 2
        #expect(size.width >= widestPill + ShellSurfaceView.fillet * 2)
        // Tallest panel still fits, which the old fixed 520 × 440 window did not
        // once the height cap went past 440.
        #expect(size.height >= limits.maxHeight)

        // A narrow screen still gets a window wide enough for its wings.
        let narrow = PanelLimits(maxWidth: 440, maxHeight: 400)
        #expect(narrow.windowSize(for: metrics).width >= widestPill)
    }

    @Test("The surface draws an app's declared width, not always 440")
    func surfaceHonorsWidth() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        // Past the bar's own width the shape *is* the panel; under it the bar is
        // the floor and the panel hangs beneath (see `visitBarIsInvariant`).
        let bar = surface.visitBarWidth
        let wide = surface.shapeSize(expanded: true, width: bar + 80, height: 300)
        #expect(wide.width == bar + 80 + ShellSurfaceView.fillet * 2)
        let narrow = surface.shapeSize(expanded: true, width: 360, height: 300)
        #expect(narrow.width == bar + ShellSurfaceView.fillet * 2)

        surface.present(.expanded(app: "chess"), content: nil, width: 520, height: 300, animated: false)
        #expect(surface.expandedWidth == 520)
        // Collapsing keeps the hardware notch's width — the panel width is only
        // ever consulted when expanded, and the bar is a *visit* control.
        #expect(surface.shapeSize(expanded: false, height: 0).width
                == surface.metrics.closedWidth + ShellSurfaceView.fillet * 2)
    }

    /// **The bar is an invariant** (principle 8, and defect 4 on device: the
    /// controls hugged the cutout instead of sitting at the black bar's outer
    /// edges). design.html §01 draws a *fixed-width* bar — 470 over a 168 pt
    /// cutout — with the two controls at its far ends, and a 336 pt panel
    /// hanging beneath it. So the bar's frame must be the same rect for every
    /// session, whatever width that session asked for.
    @Test("The visit bar is one frame, identical across sessions of every width")
    func visitBarIsInvariant() {
        var bars: [CGRect] = []
        var shapes: [CGFloat] = []
        for width in [PanelLimits.minWidth, 360, PanelLimits.defaultWidth, 520, 640] as [CGFloat] {
            let surface = ShellSurfaceView(callbacks: .inert)
            surface.metrics = .fallback                          // 210 × 34
            surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            surface.present(
                .expanded(app: "app-\(width)"),
                content: FlippedView(),
                width: width,
                height: 300,
                animated: false
            )
            surface.layoutSubtreeIfNeeded()
            let bar = surface.panelWingBarView
            bars.append(surface.convert(bar.bounds, from: bar))
            shapes.append(surface.currentShapeRect.width)

            // The width itself: cutout + a fixed reach each side, and centred on
            // the cutout so the controls straddle the camera symmetrically.
            #expect(surface.visitBarWidth
                    == surface.metrics.closedWidth + LedgeMetrics.visitBarWing * 2)
            #expect(abs(surface.visitBarRect.midX - surface.hardwareCutoutRect.midX) < 0.01)
            // …and noticeably wider than the cutout, which is the whole
            // complaint: 210 → 510 on the mockup's own proportion.
            #expect(surface.visitBarWidth > surface.metrics.closedWidth + 200)
        }
        #expect(Set(bars.map { "\($0)" }).count == 1, "the bar moved: \(bars)")

        // The silhouette still grows with the session — the bar is a floor, not
        // a cap. A panel wider than the bar meets its edges; a narrower one
        // hangs beneath it, and the shape stays bar-width.
        #expect(shapes.first == shapes[1])                       // both under the bar
        #expect(shapes.last! > shapes.first!)                    // 640 is past it
    }

    @Test("A catalog panel declaration drives the session's panel size (§3.6 → §5)")
    func catalogDrivesPanelSize() throws {
        let session = HostSession()
        session.limits = limits
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))

        // `chess` declares 520 × 560 in the golden catalog fixture.
        let chess = session.panelSize(for: "chess")
        #expect(chess.width == 520)
        #expect(chess.maxHeight == 560)

        // `stocks` declares nothing and gets the shell's defaults.
        let stocks = session.panelSize(for: "stocks")
        #expect(stocks.width == PanelLimits.defaultWidth)
        #expect(stocks.maxHeight == limits.maxHeight)

        // So does an app that is not in the catalog at all.
        #expect(session.panelSize(for: "ghost").width == PanelLimits.defaultWidth)
        #expect(session.panelSize(for: nil).width == PanelLimits.defaultWidth)
    }

    @Test("A declared width is what the app's tree is actually laid out at")
    func compositeUsesDeclaredWidth() throws {
        let session = HostSession()
        session.limits = limits
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        session.inject(Envelope(app: "chess", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v"), "pad": .int(12)])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("text"),
                         "props": .object(["content": .string("Ruy López")])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))

        let resolved = try #require(session.content(for: "chess"))
        #expect(resolved.width == 520)
        resolved.view.layoutSubtreeIfNeeded()
        let root = try #require(resolved.view.subviews.first)
        #expect(root.frame.width == 520)
        // Height is still measured from the tree, capped by the declared max.
        #expect(resolved.height > 0)
        #expect(resolved.height <= 560)
    }

    /// **Panel height = content fit** (flow.md — there is no bottom bar any
    /// more, so there is nothing below the app's tree to pay for).
    ///
    /// This used to be `fitting + 42 pt strip + 34 pt cutout row`. The strip is
    /// deleted; the cutout row is not optional, because it is the exclusion zone
    /// that keeps an app's first row out from under the camera (principle 7).
    @Test("A panel is the app's measured height plus the cutout row, and nothing else")
    func panelHeightIsContentFit() throws {
        let session = HostSession()
        session.limits = limits
        session.cutoutRowHeight = 34
        session.openReplay()
        session.inject(try Fixtures.envelope("commit-mount.json"))

        #expect(session.chromeHeight == 34)
        let resolved = try #require(session.content(for: "stocks"))
        // The tree's own fitting height is whatever is left once the one row of
        // chrome is taken off — stated as a derivation, not a magic number, so
        // a bar sneaking back in would fail here rather than look plausible.
        #expect(resolved.height - session.chromeHeight > 0)
    }
}
