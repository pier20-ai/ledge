import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The hover ring** — a hairline all the way round the control under the
/// cursor, on the two variants that had no border of their own.
///
/// The brighten a bead already had is a change of *degree*: 11% of white to 17%.
/// You can only see it by comparing the hovered bead with one you are not
/// hovering, and at notch scale over a moving stage there is often nothing to
/// compare with. A ring is a change of *kind* and needs no reference. It is
/// added to the existing treatment, never instead of it — the bead still
/// brightens, the ghost still washes.
@MainActor
@Suite("Hover ring — beads and ghosts gain an edge under the cursor")
struct HoverRingTests {
    private func button(_ variant: LedgeButtonVariant, disabled: Bool = false) -> LedgeButton {
        let button = LedgeButton("", symbol: "chevron.down", variant: variant, handler: {})
        button.apply(disabled: disabled)
        button.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        button.layoutSubtreeIfNeeded()
        return button
    }

    private func ringColor(_ button: LedgeButton) -> NSColor? {
        guard let cgColor = button.layer?.borderColor else { return nil }
        return NSColor(cgColor: cgColor)
    }

    // MARK: - The two ringed variants

    @Test("A bead gains the ring on hover, and keeps its brighten", arguments: [
        LedgeButtonVariant.bead, .ghost,
    ])
    func ringAppearsOnHover(variant: LedgeButtonVariant) {
        let button = self.button(variant)

        #expect(button.layer?.borderWidth == 0, "idle controls have no edge to find")

        button.setHoveredForTesting(true)
        #expect(button.layer?.borderWidth == LedgeMetrics.hairline)
        #expect(ringColor(button)?.alphaComponent == LedgeTheme.hoverRing.alphaComponent)

        button.setHoveredForTesting(false)
        #expect(button.layer?.borderWidth == 0, "the ring is a hover state, not a border")
    }

    @Test("The bead still brightens — the ring is additional, not a replacement")
    func beadStillBrightens() {
        let button = self.button(.bead)
        let idle = button.beadFillColors
        button.setHoveredForTesting(true)
        let hovered = button.beadFillColors

        #expect(idle?.first?.alphaComponent == LedgeTheme.beadFillTop.alphaComponent)
        #expect(hovered?.first?.alphaComponent == LedgeTheme.beadFillTopHover.alphaComponent)
        // …and the ring is there at the same time.
        #expect(button.layer?.borderWidth == LedgeMetrics.hairline)
    }

    @Test("The ghost still washes — the ring is additional there too")
    func ghostStillWashes() {
        let button = self.button(.ghost)
        #expect((button.layer?.backgroundColor?.alpha ?? 0) == 0)

        button.setHoveredForTesting(true)
        let wash = button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        #expect(wash?.alphaComponent == LedgeTheme.raisedHover.alphaComponent)
        #expect(button.layer?.borderWidth == LedgeMetrics.hairline)
    }

    // MARK: - Who does not get one

    @Test("A glass button is left alone — it already carries an edge in both states")
    func glassKeepsItsOwnBorder() {
        let button = self.button(.glass)
        #expect(button.layer?.borderWidth == LedgeMetrics.hairline)
        let idle = ringColor(button)?.alphaComponent

        button.setHoveredForTesting(true)
        // Still one hairline, and it moves along its own hairline/hairlineHover
        // ramp rather than jumping to the ring token. A second rule here would
        // only thicken an edge that is already doing this job.
        #expect(button.layer?.borderWidth == LedgeMetrics.hairline)
        #expect(idle == LedgeTheme.hairline.alphaComponent)
        #expect(ringColor(button)?.alphaComponent == LedgeTheme.hairlineHover.alphaComponent)
    }

    @Test("A disabled control never rings")
    func disabledNeverRings() {
        for variant in [LedgeButtonVariant.bead, .ghost] {
            let button = self.button(variant, disabled: true)
            button.setHoveredForTesting(true)
            #expect(button.layer?.borderWidth == 0, "\(variant) rang while disabled")
        }
    }

    // MARK: - The token

    @Test("The ring is a token, and it is the bead's own specular value")
    func ringIsATokenNotALiteral() {
        // rgba(255,255,255,.16) — the same white the bead's top edge is drawn
        // in. The ring is that edge continued round the control, which is why it
        // is not a new number.
        #expect(LedgeTheme.hoverRing.alphaComponent == 0.16)
        #expect(LedgeTheme.hoverRing.alphaComponent == LedgeTheme.beadEdgeHighlight.alphaComponent)
        let white = LedgeTheme.hoverRing.usingColorSpace(.deviceRGB)
        #expect(white?.redComponent == 1)
        #expect(white?.greenComponent == 1)
        #expect(white?.blueComponent == 1)
    }
}
