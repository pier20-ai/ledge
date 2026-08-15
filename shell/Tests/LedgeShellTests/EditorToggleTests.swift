import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The [⌂|✦] split** — the left island in a visit (Manu's O2 conclusion,
/// G2.4). ⌂ shows the ledge, ✦ lowers the glass; the zone whose surface is up
/// stays lit, so the control answers "where am I" while the press still means
/// "take me there / back". The word "Apps" opening a chat was the
/// counterintuitive thing the whole options round existed to fix — there are
/// no words on this control at all now.
@MainActor
@Suite("The [⌂|✦] split (G2.4, O2 conclusion)")
struct EditorToggleTests {
    private func makeSurface() -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        surface.present(
            .expanded(app: "stocks"),
            content: FlippedView(),
            width: PanelLimits.defaultWidth,
            height: 300,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    @Test("The lit zone names the surface that is up")
    func litZoneNamesTheSurface() {
        let surface = makeSurface()
        let split = surface.panelWingBarView.splitView

        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        #expect(!split.homeZone.isLit)
        #expect(!split.chatZone.isLit)

        surface.setPanelWing(mode: .editor, canToggleGlass: true)
        #expect(!split.homeZone.isLit)
        #expect(split.chatZone.isLit)

        surface.setPanelWing(mode: .overview, canToggleGlass: true)
        #expect(split.homeZone.isLit)
        #expect(!split.chatZone.isLit)

        // And back — a toggle that only travels one way is a door.
        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        #expect(!split.homeZone.isLit)
        #expect(!split.chatZone.isLit)
    }

    /// Principle 1's two-tier control law: both islands are beads — one split
    /// capsule each, painted from the same two fill stops, never an accent.
    @Test("Both wing controls are split beads from the same two fill stops")
    func controlsAreBeads() {
        let bar = makeSurface().panelWingBarView
        let split = bar.splitView
        split.layoutSubtreeIfNeeded()
        #expect(split.homeZone.fillColors == [LedgeTheme.beadFillTop, LedgeTheme.beadFillBottom])
        #expect(split.chatZone.fillColors == [LedgeTheme.beadFillTop, LedgeTheme.beadFillBottom])
        let walker = bar.walkerView
        walker.layoutSubtreeIfNeeded()
        #expect(walker.previousZone.fillColors == [LedgeTheme.beadFillTop, LedgeTheme.beadFillBottom])
        #expect(walker.nextZone.fillColors == [LedgeTheme.beadFillTop, LedgeTheme.beadFillBottom])
    }

    /// The pulse is an answer to something the user just did. Re-applying the
    /// same status happens on every applied commit (the panel re-measures), and
    /// a panel that flashed green on every price tick would be an alarm.
    @Test("Only a genuine change pulses")
    func repeatedStatusDoesNotPulse() {
        let surface = makeSurface()
        surface.setBuildStatus(.reloaded)
        let first = surface.attentionPulseCount
        surface.setBuildStatus(.reloaded)
        #expect(surface.attentionPulseCount == first)

        surface.setBuildStatus(.crashed)
        #expect(surface.attentionPulseCount == first + 1)

        // Going back to neutral is not an outcome, so it colours without a pulse.
        surface.setBuildStatus(.neutral)
        #expect(surface.attentionPulseCount == first + 1)
    }

    /// flow.md: "A blank slot has no stage: chat only." A surface with no
    /// session behind it loses the ✦ zone — there is no glass to lower — but
    /// keeps ⌂: home is how you leave a surface with nothing on it, exactly
    /// like ‹|›.
    @Test("No stage: the ✦ zone hides, ⌂ and ‹|› remain")
    func noStageNoChatZone() {
        let surface = makeSurface()
        surface.setPanelWing(mode: .stage, canToggleGlass: false)
        surface.layoutSubtreeIfNeeded()
        let split = surface.panelWingBarView.splitView
        #expect(split.chatZone.isHidden)
        #expect(!split.homeZone.isHidden)
        #expect(!split.isHidden)
        #expect(!surface.panelWingBarView.walkerView.isHidden)
    }
}
