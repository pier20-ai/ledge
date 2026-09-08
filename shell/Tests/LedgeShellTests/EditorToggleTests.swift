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

    /// G2.6: the split belongs to the stage. Chat and the ledge wear a single
    /// **‹ Back** in its exact place — "you're going back to the app; this is
    /// cleaner" — so which island is up *is* the mode, and the word on it
    /// names where the press goes.
    @Test("The stage wears the split; chat and the ledge wear ‹ Back")
    func theLeftIslandNamesTheWayOut() {
        let surface = makeSurface()
        let bar = surface.panelWingBarView

        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        #expect(!bar.splitView.isHidden)
        #expect(bar.backView.isHidden)

        surface.setPanelWing(mode: .editor, canToggleGlass: true)
        #expect(bar.splitView.isHidden)
        #expect(!bar.backView.isHidden)
        #expect(bar.backView.currentLabel == "Back")

        surface.setPanelWing(mode: .overview, canToggleGlass: true)
        #expect(bar.splitView.isHidden)
        #expect(!bar.backView.isHidden)

        // And back — a toggle that only travels one way is a door.
        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        #expect(!bar.splitView.isHidden)
        #expect(bar.backView.isHidden)
    }

    /// ‹ Back takes the split's anchorage, so the island never moves when the
    /// surface changes underneath it (principle 8). Since G6 the anchorage is
    /// the **leading** edge — the islands hug the glass's ends — so that is
    /// the edge the two share.
    @Test("Back stands exactly where the split stood")
    func backTakesTheSplitsAnchorage() {
        let surface = makeSurface()
        let bar = surface.panelWingBarView
        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        surface.layoutSubtreeIfNeeded()
        let splitLeading = bar.splitView.frame.minX

        surface.setPanelWing(mode: .editor, canToggleGlass: true)
        surface.layoutSubtreeIfNeeded()
        #expect(abs(bar.backView.frame.minX - splitLeading) < 0.01)
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
