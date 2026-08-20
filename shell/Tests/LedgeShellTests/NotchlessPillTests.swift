import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The pill on a display with no camera housing (ticket 0001 A3): external
/// monitors and pre-notch Macs. The shell is anchored to a cutout rect, so the
/// answer is not to special-case those screens but to **invent the rect** — and
/// then everything downstream (wing clamps, the mini's floor, the panel's
/// exclusion row) keeps working unchanged, because all of it already takes an
/// arbitrary cutout as input.
@MainActor
@Suite("The synthesized pill (ticket 0001 A3)")
struct NotchlessPillTests {
    @Test("A screen with no cutout gets one the width of a real notch")
    func synthesizedGeometry() {
        let metrics = NotchMetrics.synthesized(menubarHeight: 24, screenWidth: 2560)
        #expect(metrics.isSynthesized)
        #expect(metrics.closedWidth == NotchMetrics.synthesizedWidth)
        // A menu bar is thinner than a wing's content is tall, so the pill is
        // floored rather than matched exactly — otherwise a live activity in it
        // has nowhere to draw.
        #expect(metrics.closedHeight == NotchMetrics.synthesizedHeightRange.lowerBound)
    }

    @Test("A tall menu bar is followed, up to the ceiling; a narrow screen shrinks the pill")
    func synthesizedClamps() {
        #expect(NotchMetrics.synthesized(menubarHeight: 36, screenWidth: 2560).closedHeight == 36)
        // Past the ceiling the shape would stop reading as a pill and start
        // reading as a bar across the top of the display.
        #expect(NotchMetrics.synthesized(menubarHeight: 60, screenWidth: 2560).closedHeight
                == NotchMetrics.synthesizedHeightRange.upperBound)
        // A quarter of a genuinely narrow screen, never the full 210.
        #expect(NotchMetrics.synthesized(menubarHeight: 24, screenWidth: 640).closedWidth == 160)
    }

    @Test("A hardware cutout is never called synthesized")
    func hardwareIsMarked() {
        #expect(NotchMetrics.fallback.isSynthesized == false)
    }

    @Test("The surface anchors to a synthesized cutout exactly as to a real one")
    func surfaceUsesTheInventedRect() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        surface.metrics = NotchMetrics.synthesized(menubarHeight: 24, screenWidth: 1920)

        // Centred in the window — and the window is centred on the screen, so
        // the pill lands in the middle of the menu bar, where a notch would be.
        let cutout = surface.hardwareCutoutRect
        #expect(cutout.midX == surface.bounds.midX)
        #expect(cutout.minY == 0)
        #expect(cutout.width == NotchMetrics.synthesizedWidth)
        #expect(cutout.height == NotchMetrics.synthesizedHeightRange.lowerBound)

        // The collapsed shape is that rect plus its fillets, the same identity
        // the hardware path has — no branch anywhere between here and there.
        #expect(surface.shapeSize(expanded: false, height: 0).width
                == cutout.width + ShellSurfaceView.fillet * 2)

        // And a wing still grows from it: the pill is a cutout rect, wherever
        // the rect came from.
        surface.setWing(WingSpec(text: "12:04", width: nil, canvas: nil))
        #expect(surface.shapeSize(expanded: false, height: 0).width > cutout.width)
    }

    @Test("A notched display wins; with none, the surface goes to the primary screen")
    func screenPolicy() {
        // The cutout is the surface's home when there is one, wherever it sits
        // in the arrangement.
        #expect(NotchScreen.preferredIndex(notched: [false, true, false]) == 1)
        #expect(NotchScreen.preferredIndex(notched: [true, false]) == 0)

        // With no notch anywhere, index 0 — the display that owns the menu bar.
        // Deliberately not "whichever screen is `main`", which follows the key
        // window and would move the whole shell the next time the display
        // arrangement changed.
        #expect(NotchScreen.preferredIndex(notched: [false, false, false]) == 0)

        // AppKit really does report no screens for a moment while displays are
        // being reconfigured.
        #expect(NotchScreen.preferredIndex(notched: []) == nil)
    }
}
