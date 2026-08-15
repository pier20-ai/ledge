import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The glass toggle** — the left wing in a visit (flow.md, "Visit modes": the
/// left wing lowers the glass; Done is the way back to touching the stage).
///
/// It used to be an "Edit / Preview" affordance parked at the panel's right
/// edge. Three things changed and each one is asserted below: it is a **bead**
/// (design.html §01 — Ledge's own controls are swellings of the glass), it is on
/// the **left** and anchored to the notch rather than the panel, and it says
/// **Apps** / **Done** rather than Edit / Preview. What did not change is the
/// law the old suite existed for: the label names *where the press goes*, never
/// where you are — with two full-panel surfaces and one control between them, a
/// label that named the current surface sends every user the wrong way exactly
/// once.
@MainActor
@Suite("The glass toggle (flow.md, Visit modes)")
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

    @Test("Apps while the stage is showing, Done while the editor is")
    func labelNamesTheDestination() {
        let surface = makeSurface()
        let toggle = surface.panelWingBarView.glassToggleView

        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        #expect(toggle.currentLabel == "Apps")
        #expect(toggle.accessibilityLabel() == "Edit with AI")

        surface.setPanelWing(mode: .editor, canToggleGlass: true)
        #expect(toggle.currentLabel == "Done")
        #expect(toggle.accessibilityLabel() == "Show the app")

        // And back — a toggle that only travels one way is a door.
        surface.setPanelWing(mode: .stage, canToggleGlass: true)
        #expect(toggle.currentLabel == "Apps")
    }

    /// Principle 1's two-tier control law, and the reason this is not a `plain`
    /// button: a Ledge control is the glass swelling, an app's control is a bare
    /// white glyph in the content well, and the two must never be confusable.
    @Test("Both wing controls are beads, at the smallest rung of the ramp")
    func controlsAreBeads() {
        let bar = makeSurface().panelWingBarView
        #expect(bar.glassToggleView.currentVariant == .bead)
        #expect(bar.glassToggleView.currentSize == .s)
        // A bead is drawn from its two gradient sublayers, not from a flat
        // background — the accessor is nil for every other variant.
        #expect(bar.glassToggleView.beadFillColors?.count == 2)
        // `‹|›` is **one** bead split in two, not two beads (design.html §01),
        // so it is not a `LedgeButton` at all — but its halves are painted from
        // the same two fill stops, which is what makes the pair read as one
        // family with the toggle beside it.
        let walker = bar.walkerView
        walker.layoutSubtreeIfNeeded()
        #expect(walker.previousZone.fillColors == [LedgeTheme.beadFillTop, LedgeTheme.beadFillBottom])
        #expect(walker.nextZone.fillColors == [LedgeTheme.beadFillTop, LedgeTheme.beadFillBottom])
    }

    @Test("The build status is recorded without turning a permanent control into a status light")
    func statusDoesNotFillTheToggle() {
        let surface = makeSurface()
        let toggle = surface.panelWingBarView.glassToggleView
        #expect(surface.panelWingBarView.buildStatus == .neutral)

        surface.setBuildStatus(.reloaded)
        #expect(surface.panelWingBarView.buildStatus == .reloaded)
        surface.setBuildStatus(.crashed)
        #expect(surface.panelWingBarView.buildStatus == .crashed)

        // Principle 3: bold fills mark the one moment that warrants them, never
        // decoration — and a control that is on screen in every visit is not
        // that moment. The pulse carries the outcome instead.
        #expect(toggle.tint == nil)
        #expect(toggle.filledTint == nil)
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

    /// flow.md: "A blank slot has no stage: chat only, no glass toggle." The
    /// same is true of every surface with no session behind it.
    @Test("A surface with no stage has no glass to lower — but keeps ‹|›")
    func noStageNoToggle() {
        let surface = makeSurface()
        surface.setPanelWing(mode: .stage, canToggleGlass: false)
        surface.layoutSubtreeIfNeeded()
        #expect(surface.panelWingBarView.glassToggleView.isHidden)
        // The walker is never hidden: `‹|›` is how you leave a surface that has
        // nothing on it, so a surface with nothing on it is exactly when it has
        // to be there.
        #expect(!surface.panelWingBarView.walkerView.isHidden)
    }
}
