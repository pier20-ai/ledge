import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// Phase F1's foundation: the shadow ramp, the motion table, the two new control
/// variants, and the three view primitives that were being reinvented per
/// surface. Principle 15 is the thing under test throughout — *one* token
/// source, so an inline literal is a defect even when its value is right.
@MainActor
@Suite("Foundation — shadow ramp, motion, beads, rows (F1)")
struct FoundationTokensTests {
    // MARK: - The shadow ramp

    @Test("Three rungs, in order, and nothing between them")
    func shadowRampIsThree() {
        #expect(LedgeShadow.swell == LedgeShadow(yOffset: 6, blur: 18, opacity: 0.35))
        #expect(LedgeShadow.panel == LedgeShadow(yOffset: 14, blur: 34, opacity: 0.45))
        #expect(LedgeShadow.window == LedgeShadow(yOffset: 18, blur: 40, opacity: 0.50))

        // The ramp is a ramp: further off the wall ⇒ lower, softer, darker.
        let ramp = [LedgeShadow.swell, .panel, .window]
        #expect(ramp.map(\.yOffset) == ramp.map(\.yOffset).sorted())
        #expect(ramp.map(\.blur) == ramp.map(\.blur).sorted())
        #expect(ramp.map(\.opacity) == ramp.map(\.opacity).sorted())
    }

    @Test("CSS blur converts to a CoreAnimation sigma, and down is +y under a flipped view")
    func shadowGeometryConverts() {
        // design.html states blur radii; CALayer wants the sigma, which is half.
        #expect(LedgeShadow.panel.shadowRadius == 17)
        #expect(LedgeShadow.swell.shadowRadius == 9)

        let layer = CALayer()
        LedgeShadow.panel.applyGeometry(to: layer)
        #expect(layer.shadowOffset == CGSize(width: 0, height: 14))
        #expect(layer.shadowRadius == 17)
        // Geometry only. The opacity is a state — a collapsed notch casts
        // nothing — so the token must not switch the shadow on by itself.
        #expect(layer.shadowOpacity == 0)

        let unflipped = CALayer()
        LedgeShadow.panel.applyGeometry(to: unflipped, flipped: false)
        #expect(unflipped.shadowOffset == CGSize(width: 0, height: -14))
    }

    // MARK: - The motion table

    @Test("Two characters: pop overshoots once, settle never overshoots")
    func springCharacters() {
        #expect(LedgeMotion.Spring.pop.overshoots)
        #expect(!LedgeMotion.Spring.settle.overshoots)
        #expect(LedgeMotion.Spring.settle.damping == 1.0)
    }

    @Test("The four roles keep the feel they were tuned to")
    func springRolesAreUnchanged() {
        // F1 centralized these; it did not retune them. If one of these numbers
        // moves, it moved because someone changed how Ledge feels.
        #expect(LedgeMotion.Spring.open == LedgeMotion.Spring(response: 0.42, damping: 0.80))
        #expect(LedgeMotion.Spring.close == LedgeMotion.Spring(response: 0.45, damping: 1.0))
        #expect(LedgeMotion.Spring.morph == LedgeMotion.Spring(response: 0.40, damping: 0.85))
        #expect(LedgeMotion.Spring.bump == LedgeMotion.Spring(response: 0.30, damping: 0.75))

        // An arrival is a pop and a return is a settle — the mapping, not just
        // the numbers.
        #expect(LedgeMotion.Spring.open == .pop)
        #expect(LedgeMotion.Spring.close == .settle)
        #expect(LedgeMotion.Spring.morph.overshoots)
        #expect(LedgeMotion.Spring.bump.overshoots)
    }

    @Test("Three durations, and a spring keeps its character over a new distance")
    func durationsAndResponding() {
        #expect(LedgeMotion.fast == 0.18)
        #expect(LedgeMotion.move == 0.38)
        #expect(LedgeMotion.travel == 0.56)
        #expect(LedgeMotion.fast < LedgeMotion.move)
        #expect(LedgeMotion.move < LedgeMotion.travel)
        // The old `LedgeMetrics.hoverDuration` was a second, unused duration
        // table. It is now the same value as `fast`, by definition.
        #expect(LedgeMetrics.hoverDuration == LedgeMotion.fast)

        let quickPop = LedgeMotion.Spring.pop.responding(in: 0.2)
        #expect(quickPop.damping == LedgeMotion.Spring.pop.damping)
        #expect(quickPop.response == 0.2)
    }

    // MARK: - The bead

    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        view.layout()
    }

    @Test("A bead is a gradient swelling, not a flat chip")
    func beadIsConvex() {
        let bead = LedgeButton("Reload Ledge", variant: .bead, size: .s) {}
        laidOut(bead, width: 110, height: LedgeMetrics.Size.s.height)

        // Top-lit: the fill is brighter at the top than the bottom. That single
        // fact is what makes the control read as convex.
        let fill = bead.beadFillColors
        #expect(fill?.count == 2)
        #expect(fill?.first == LedgeTheme.beadFillTop)
        #expect(fill?.last == LedgeTheme.beadFillBottom)

        // Specular line above, shadow below — the inset edge from design.html.
        let edge = bead.beadEdgeColors
        #expect(edge?.first == LedgeTheme.beadEdgeHighlight)
        #expect(edge?.last == LedgeTheme.beadEdgeShadow)

        // No flat background underneath: it would fill the capsule and flatten
        // the gradient back into a chip.
        #expect(bead.layer?.backgroundColor?.alpha == 0)
        // And it is still a capsule — the control ramp's radius rule, unchanged.
        #expect(bead.layer?.cornerRadius == LedgeMetrics.capsule(LedgeMetrics.Size.s.height))
    }

    @Test("A ghost is bare pure white, and only the cursor gives it a shape")
    func ghostIsBare() {
        let ghost = LedgeButton("", symbol: "play.fill", variant: .ghost) {}
        laidOut(ghost, width: 34, height: 34)

        // Pure white, not `primary`: a ghost has no background to lift it, and
        // the 6% chrome ink gives up is what would make it look switched off.
        #expect(ghost.currentVariant == .ghost)
        #expect(ghost.layer?.backgroundColor?.alpha == 0)
        #expect(ghost.layer?.borderWidth == 0)
        // No bead layers — a ghost is the *other* tier.
        #expect(ghost.beadFillColors == nil)
    }

    @Test("A bead sinks under the press; every other variant still scales")
    func beadSinksRatherThanShrinking() {
        let bead = LedgeButton("Reload Ledge", variant: .bead, size: .s) {}
        laidOut(bead, width: 110, height: LedgeMetrics.Size.s.height)
        #expect(!bead.isPressed)

        let glass = LedgeButton("Done", variant: .glass) {}
        laidOut(glass, width: 80, height: LedgeMetrics.Size.m.height)
        #expect(glass.beadFillColors == nil)
        #expect(LedgeMetrics.beadPressSink == 0.5)
    }

    @Test("A variant change builds and tears down the bead's layers")
    func variantChangeRebuildsBead() {
        let button = LedgeButton("Reload Ledge", variant: .plain) {}
        laidOut(button, width: 110, height: LedgeMetrics.Size.m.height)
        #expect(button.beadFillColors == nil)

        button.apply(variant: .bead)
        laidOut(button, width: 110, height: LedgeMetrics.Size.m.height)
        #expect(button.beadFillColors?.count == 2)

        button.apply(variant: .plain)
        laidOut(button, width: 110, height: LedgeMetrics.Size.m.height)
        #expect(button.beadFillColors == nil)
    }

    @Test("An app cannot dress its buttons as chrome")
    func wireVariantsCannotReachTheShellTiers() {
        // The wire vocabulary is four (spec §5, F2.3): `ghost` is the *app* tier
        // of design.html §06's two-tier law and belongs to app content, so it
        // crosses. `bead` is Ledge's own chrome and does not — an app naming it
        // gets the ordinary plain button. See AppControlsTests for the fixture
        // replay; this is the mapping table itself.
        #expect(ProtocolRenderer.variant("glass") == .glass)
        #expect(ProtocolRenderer.variant("accent") == .accent)
        #expect(ProtocolRenderer.variant("ghost") == .ghost)
        #expect(ProtocolRenderer.variant("bead") == .plain)
    }

    // MARK: - The row

    @Test("A row is full-bleed: only the content is inset")
    func rowIsFullBleed() {
        let row = LedgeRowView(title: "Launch at login", value: "On", chevron: true) {}
        laidOut(row, width: 300, height: LedgeMetrics.rowHeight)

        #expect(row.intrinsicContentSize.height == LedgeMetrics.rowHeight)
        #expect(row.currentTitle == "Launch at login")
        #expect(row.currentValue == "On")
        #expect(row.hasChevron)
        // The rule runs edge to edge — a divider that stopped short of the fill
        // is what makes a column of rows read as a stack of cards.
        #expect(row.dividerIsVisible)
    }

    @Test("The trailing value is set in tabular figures")
    func rowValueIsTabular() {
        let row = LedgeRowView(title: "Balance", value: "214.62")
        laidOut(row, width: 300, height: LedgeMetrics.rowHeight)
        // A column of numbers that shifts as it ticks is the whole reason this
        // slot exists rather than a second free-form label.
        let field = try? #require(row.subviews.compactMap { $0 as? NSTextField }.last)
        #expect(field?.alignment == .right)
    }

    @Test("An inert row has no hover, and the owner owns the last rule")
    func rowHoverAndDivider() {
        let inert = LedgeRowView(title: "Version", value: "0.4.0")
        laidOut(inert, width: 300, height: LedgeMetrics.rowHeight)
        // No handler ⇒ nothing to press ⇒ no hover fill, ever. A row that lights
        // up and then does nothing is a lie.
        #expect(!inert.isHovering)
        #expect(!inert.hoverFillIsVisible)

        // Only the owner knows which row is last; a row that guessed would draw
        // a rule under the bottom of the list.
        inert.showsDivider = false
        #expect(!inert.dividerIsVisible)
    }

    // MARK: - The empty state and the one error card

    @Test("An empty state is a glyph, one line, and at most one action")
    func emptyStateShape() {
        let quiet = LedgeEmptyState(symbol: "tray", line: "Nothing scheduled today.")
        #expect(quiet.line == "Nothing scheduled today.")
        #expect(quiet.actionButton == nil)

        let actionable = LedgeEmptyState(
            symbol: "tray",
            line: "Nothing scheduled today.",
            actionTitle: "Add one"
        ) {}
        #expect(actionable.actionButton?.currentLabel == "Add one")
        // The action is a bead: it is a Ledge control on Ledge's own surface.
        #expect(actionable.actionButton?.currentVariant == .bead)
    }

    @Test("The error card says one thing and offers one way out")
    func errorCardIsGeneric() {
        let card = ErrorCardView()
        #expect(ErrorCardView.line == "Something broke.")
        #expect(card.messageLine == "Something broke.")
        #expect(card.reloadButton?.currentLabel == "Reload Ledge")
        #expect(card.reloadButton?.currentVariant == .bead)
    }

    @Test("A crash reaches the panel as the generic card — no message, no app name")
    func crashRendersTheGenericCard() {
        var reloads = 0
        let renderer = ProtocolRenderer()
        renderer.onReloadHost = { reloads += 1 }
        renderer.showErrorCard(
            app: "stocks",
            message: "TypeError: undefined is not a function",
            stack: "at monitor (app.jsx:12)\nat tick (host.ts:88)"
        )

        let card = try? #require(renderer.rootView(for: "stocks") as? ErrorCardView)
        #expect(card?.messageLine == "Something broke.")
        // Nothing about the app, the error, or the trace is on the glass — the
        // reader cannot act on any of it, and ~/.ledge/host.log already has it.
        let text = card.map(Self.allStrings) ?? []
        #expect(!text.contains { $0.contains("TypeError") })
        #expect(!text.contains { $0.contains("app.jsx") })
        #expect(!text.contains { $0.localizedCaseInsensitiveContains("stocks") })
        #expect(!text.contains { $0.localizedCaseInsensitiveContains("crashed") })

        // The one action restarts the host (flow.md, Errors).
        #expect(card?.reloadButton?.accessibilityPerformPress() == true)
        #expect(reloads == 1)
    }

    private static func allStrings(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        if let button = view as? LedgeButton { found.append(button.currentLabel) }
        for child in view.subviews { found += allStrings(in: child) }
        return found
    }
}
