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
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let narrow = surface.shapeSize(expanded: true, width: 360, height: 300)
        let wide = surface.shapeSize(expanded: true, width: 520, height: 300)
        #expect(narrow.width == 360 + ShellSurfaceView.fillet * 2)
        #expect(wide.width == 520 + ShellSurfaceView.fillet * 2)

        surface.present(.expanded(app: "chess"), content: nil, width: 520, height: 300, animated: false)
        #expect(surface.expandedWidth == 520)
        // Collapsing keeps the hardware notch's width — the panel width is only
        // ever consulted when expanded.
        #expect(surface.shapeSize(expanded: false, height: 0).width
                == surface.metrics.closedWidth + ShellSurfaceView.fillet * 2)
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

    @Test("The app strip is built from the catalog's real names and icons (§3.6)")
    func stripUsesCatalogIdentity() throws {
        // The user-visible bug this phase fixes: before `meta` extraction the
        // catalog carried a placeholder icon for every app, so the strip showed
        // five identical dashed squares. The strip has always read the catalog —
        // what changed is that the catalog now carries the truth.
        #expect(AppBarView.symbol(from: "sf:chart.line.uptrend.xyaxis") == "chart.line.uptrend.xyaxis")
        #expect(AppBarView.symbol(from: "crown") == "crown")

        let apps = try Fixtures.envelope("catalog.json").decodePayload(CatalogPayload.self).apps
        let bar = AppBarView(callbacks: .inert)
        bar.setApps(apps)

        // The app icons live inside the strip's scrolling area now, so the walk
        // is recursive — [+] and Settings are still direct children, because
        // they are the two controls that must never scroll away.
        let icons = allButtons(in: bar)
        let labels = icons.compactMap { $0.accessibilityLabel() }
        // Enabled, non-Settings apps in catalog order, then [+], then Settings.
        #expect(labels.contains("Stocks"))
        #expect(labels.contains("Chess"))
        #expect(labels.contains("New app"))
        #expect(!labels.contains("Deal Watch"))          // disabled apps are dropped

        let symbols = icons.map(\.symbolName)
        #expect(symbols.contains("chart.line.uptrend.xyaxis"))
        #expect(symbols.contains("crown"))
        #expect(!symbols.contains("square.dashed"))      // no placeholder survives
    }
}

/// Every strip icon in a view subtree. The strip's app icons sit in a scroll
/// view's document view, so a one-level `subviews` walk stopped finding them.
@MainActor
func allButtons(in view: NSView) -> [HoverIconButton] {
    view.subviews.flatMap { child -> [HoverIconButton] in
        (child as? HoverIconButton).map { [$0] } ?? allButtons(in: child)
    }
}
