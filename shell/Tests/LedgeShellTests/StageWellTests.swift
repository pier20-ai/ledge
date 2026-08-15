import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The stage well survives the presentation switch** (flow.md, "Visit modes":
/// "the session's live tree goes on rendering behind the pane").
///
/// On device the well was a black rectangle: chat mode showed its own glass card
/// and nothing inside it, while every snapshot of the same surface was correct.
/// The difference is the *order* real presentation happens in, which snapshots
/// never perform.
///
/// `NotchPanelController.refresh` enters chat by
///
///   1. reparenting the shared composite into `ChatSurfaceView`'s stage well,
///      then
///   2. calling `ShellSurfaceView.present(.chat(app), content: chatPane)`.
///
/// At step 2 the surface's outgoing content *is* that composite — and
/// `swapContent` cross-faded and `removeFromSuperview()`'d whatever it found
/// there. So the panel emptied the well one frame after the well was filled, and
/// the composite was left holding `alphaValue == 0` for good measure. A snapshot
/// builds a fresh pane with no prior content, so step 2 had nothing to tear down
/// and the bug was invisible to the whole snapshot suite.
///
/// The law: **a host may only tear down a view it still owns**, ownership being
/// `superview` and nothing else.
@MainActor
@Suite("The stage well — chat shows the live app, not a black rectangle")
struct StageWellTests {
    private static let stageHeight: CGFloat = 160
    private static let width = PanelLimits.defaultWidth

    /// A surface sized like the real panel, plus the composite the session would
    /// hand it and the chat pane that will host that composite.
    private func makeRig() -> (ShellSurfaceView, ChatSurfaceView, NSView) {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let composite = FlippedView()
        composite.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.stageHeight)

        let chat = ChatSurfaceView()
        chat.frame = CGRect(
            x: 0, y: 0,
            width: Self.width,
            height: ChatSurfaceView.panelHeight(stageHeight: Self.stageHeight)
        )
        return (surface, chat, composite)
    }

    /// Exactly what the controller does, in the order it does it.
    private func enterChat(
        _ surface: ShellSurfaceView,
        _ chat: ChatSurfaceView,
        _ composite: NSView,
        animated: Bool
    ) {
        chat.setStage(composite, height: Self.stageHeight)
        surface.present(
            .chat(app: "chess"),
            content: chat,
            height: chat.frame.height,
            animated: animated
        )
        surface.layoutSubtreeIfNeeded()
        chat.layoutSubtreeIfNeeded()
    }

    private func enterStage(
        _ surface: ShellSurfaceView,
        _ chat: ChatSurfaceView,
        _ composite: NSView,
        animated: Bool
    ) {
        surface.present(
            .expanded(app: "chess"),
            content: composite,
            height: Self.stageHeight,
            animated: animated
        )
        surface.layoutSubtreeIfNeeded()
    }

    // MARK: - The defect

    @Test("Stage → chat leaves the live tree in the well, visible")
    func stageToChatKeepsTheComposite() {
        let (surface, chat, composite) = makeRig()

        enterStage(surface, chat, composite, animated: false)
        #expect(composite.superview === surface.panelContentHost)

        enterChat(surface, chat, composite, animated: false)

        // It is still in the hierarchy…
        #expect(composite.superview != nil, "the composite was torn out of the well")
        // …specifically the well's, not the panel's.
        #expect(composite.superview !== surface.panelContentHost)
        #expect(composite.isDescendant(of: chat))
        // …and it is drawn. The *well* dims (0.92); the tree inside it does not.
        #expect(composite.alphaValue == 1)
        #expect(chat.hasStage)
        // …at the well's size, not the panel's leftover frame.
        #expect(composite.frame.width > 0)
        #expect(composite.frame.height > 0)
    }

    /// The animated path is the one that actually shipped — the teardown was in
    /// a completion handler, so a non-animated test would have passed all along.
    @Test("…and the same holds on the animated path")
    func stageToChatAnimated() {
        let (surface, chat, composite) = makeRig()

        enterStage(surface, chat, composite, animated: false)
        enterChat(surface, chat, composite, animated: true)

        // Let the 0.10 s fade-out completion (and the 0.12 s entry delay) run.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        #expect(composite.superview != nil, "the fade-out completion removed it")
        #expect(composite.isDescendant(of: chat))
        #expect(composite.alphaValue == 1, "left invisible by a cross-fade it was not part of")
    }

    @Test("Chat → stage hands the composite back, fully drawn")
    func chatBackToStage() {
        let (surface, chat, composite) = makeRig()

        enterStage(surface, chat, composite, animated: false)
        enterChat(surface, chat, composite, animated: false)
        enterStage(surface, chat, composite, animated: false)

        #expect(composite.superview === surface.panelContentHost)
        #expect(composite.alphaValue == 1)
        // The chat pane is gone from the panel, and it did not take the
        // composite with it.
        #expect(chat.superview == nil)
    }

    @Test("Round-tripping the mode never loses the stage")
    func repeatedRoundTrips() {
        let (surface, chat, composite) = makeRig()
        enterStage(surface, chat, composite, animated: false)

        for turn in 0..<4 {
            enterChat(surface, chat, composite, animated: false)
            #expect(composite.isDescendant(of: chat), "lost the stage on chat turn \(turn)")
            #expect(composite.alphaValue == 1, "stage went invisible on chat turn \(turn)")

            enterStage(surface, chat, composite, animated: false)
            #expect(
                composite.superview === surface.panelContentHost,
                "lost the stage on stage turn \(turn)"
            )
            #expect(composite.alphaValue == 1, "stage went invisible on stage turn \(turn)")
        }
    }

    // MARK: - The ownership law itself

    @Test("The panel only tears down content it still owns")
    func swapContentRespectsOwnership() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let borrowed = FlippedView()
        surface.present(
            .expanded(app: "chess"),
            content: borrowed,
            height: 200,
            animated: false
        )
        #expect(borrowed.superview === surface.panelContentHost)

        // Somebody else adopts it — which is exactly what `setStage` does.
        let elsewhere = FlippedView()
        elsewhere.addSubview(borrowed)
        #expect(borrowed.superview === elsewhere)

        // The panel moves on. It must not reach into `elsewhere`.
        surface.present(
            .expanded(app: "weather"),
            content: FlippedView(),
            height: 200,
            animated: false
        )
        #expect(borrowed.superview === elsewhere, "the panel evicted a view it had given away")
        #expect(borrowed.alphaValue == 1)
    }

    @Test("A view the panel does own is still cleaned up")
    func ownedContentIsStillRemoved() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let first = FlippedView()
        surface.present(.expanded(app: "chess"), content: first, height: 200, animated: false)
        #expect(first.superview === surface.panelContentHost)

        let second = FlippedView()
        surface.present(.expanded(app: "weather"), content: second, height: 200, animated: false)
        // The ownership guard must not become a leak: content the panel put
        // there is content the panel takes away.
        #expect(first.superview == nil)
        #expect(second.superview === surface.panelContentHost)
    }

    // MARK: - The blank slot

    @Test("The blank slot has no stage and shows no well")
    func blankSlotHasNoStage() {
        let (surface, chat, _) = makeRig()
        chat.setStage(nil, height: 0)
        surface.present(.newApp, content: chat, height: chat.frame.height, animated: false)
        surface.layoutSubtreeIfNeeded()

        #expect(!chat.hasStage)
    }
}
