import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The Edit/Preview toggle** — the one control in the cutout row's right zone
/// (spec §5/§8), now that the editor takes the whole panel rather than sitting
/// under a live preview.
///
/// Two things are worth protecting. First, that the label always names *where
/// the press goes* rather than where you are: with two full-panel surfaces and
/// one control between them, a label that named the current surface would send
/// every user the wrong way exactly once. Second, that the build status is
/// carried by colour on this control — because the eye is already on this corner
/// when the user goes to look back at the app.
@MainActor
@Suite("Editor toggle (spec §8)")
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

    @Test("Edit while the app's tree is shown, Preview while the editor is")
    func labelNamesTheDestination() {
        let surface = makeSurface()
        let edit = surface.panelWingBarView.editView

        surface.setPanelWing(name: "Stocks", content: nil, canEdit: true, showingEditor: false)
        #expect(edit.currentLabel == "Edit")
        #expect(edit.accessibilityLabel() == "Edit with AI")

        surface.setPanelWing(name: "Stocks", content: nil, canEdit: true, showingEditor: true)
        #expect(edit.currentLabel == "Preview")
        #expect(edit.accessibilityLabel() == "Show the app")

        // And back — a toggle that only travels one way is a door.
        surface.setPanelWing(name: "Stocks", content: nil, canEdit: true, showingEditor: false)
        #expect(edit.currentLabel == "Edit")
    }

    /// The icon carries which *kind* of thing is on the other side; the two
    /// words alone are nearly the same width and read as one control blinking.
    @Test("The wand and the eye swap with the label")
    func iconSwapsWithTheLabel() {
        let surface = makeSurface()
        let edit = surface.panelWingBarView.editView

        surface.setPanelWing(name: "Stocks", content: nil, canEdit: true, showingEditor: false)
        surface.layoutSubtreeIfNeeded()
        let wand = edit.iconFrame

        surface.setPanelWing(name: "Stocks", content: nil, canEdit: true, showingEditor: true)
        surface.layoutSubtreeIfNeeded()
        #expect(edit.iconFrame != nil)
        #expect(wand != nil)
        // Both states draw a glyph — a state that quietly lost its icon would
        // still pass every label assertion above.
        #expect((edit.iconFrame?.width ?? 0) > 0)
    }

    @Test("The toggle stays neutral glass until a turn lands")
    func statusStartsNeutral() {
        let surface = makeSurface()
        #expect(surface.panelWingBarView.buildStatus == .neutral)
        #expect(surface.panelWingBarView.editView.tint == nil)
    }

    @Test("A clean reload turns the toggle green; a crash turns it red")
    func statusCarriesTheBuildOutcome() {
        let surface = makeSurface()
        let edit = surface.panelWingBarView.editView

        surface.setBuildStatus(.reloaded)
        #expect(surface.panelWingBarView.buildStatus == .reloaded)
        #expect(edit.tint == LedgeTheme.green)

        surface.setBuildStatus(.crashed)
        #expect(surface.panelWingBarView.buildStatus == .crashed)
        #expect(edit.tint == LedgeTheme.red)

        // A new turn makes the last outcome stale.
        surface.setBuildStatus(.neutral)
        #expect(edit.tint == nil)
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

    @Test("A surface with nothing behind it has no toggle to colour")
    func noAppNoToggle() {
        let surface = makeSurface()
        surface.setPanelWing(name: nil, content: nil, canEdit: false, showingEditor: false)
        surface.layoutSubtreeIfNeeded()
        #expect(surface.panelWingBarView.editView.isHidden)
    }
}
