import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **Chat mode** — the transcript pane over the stage (flow.md, "Visit modes";
/// design.html §01 "Chat", §08 "The conversation").
///
/// Principle 11 makes this the foundational interface, so the laws it has to
/// keep are laws and not preferences:
///
///   · the pane arrests every event — the stage is inert, period
///   · the stage stays *mounted* at reduced prominence, and recedes further
///     while the user is reading the past
///   · the glass runs opaque at the top to nearly clear at the bottom, so the
///     pill sits on the clearest glass in the product
///   · entering pops, leaving settles
///   · Esc is the visit's, exactly once (flow.md's Transitions table)
@MainActor
@Suite("Chat mode — the conversation over the stage")
struct ChatModeTests {
    private static let stageHeight: CGFloat = 160

    private func makeChat(withStage: Bool = true) -> (ChatSurfaceView, NSView) {
        let chat = ChatSurfaceView()
        let stage = FlippedView()
        stage.frame = CGRect(x: 0, y: 0, width: PanelLimits.defaultWidth, height: Self.stageHeight)
        chat.frame = CGRect(
            x: 0, y: 0,
            width: PanelLimits.defaultWidth,
            height: ChatSurfaceView.panelHeight(
                stageHeight: withStage ? Self.stageHeight : nil
            )
        )
        chat.setStage(withStage ? stage : nil, height: withStage ? Self.stageHeight : 0)
        chat.layoutSubtreeIfNeeded()
        return (chat, stage)
    }

    /// The command the page would post, run through the real parser and the real
    /// hop — a test that set the flag directly would assert nothing about the
    /// bridge, which is the half most likely to be wrong.
    private func post(_ body: [String: Any], to chat: ChatSurfaceView) {
        guard let command = EditorBridge.command(from: body) else {
            Issue.record("the page's message did not parse: \(body)")
            return
        }
        chat.editor.apply(command)
    }

    // MARK: - The arrest

    /// flow.md: "The stage is always inert here: it hot-reloads in view, but the
    /// pane arrests every event." Not a policy the renderer has to remember — a
    /// fact of the view hierarchy.
    @Test("Nothing beneath the pane can be clicked, anywhere over the stage")
    func theStageIsInert() {
        let (chat, stage) = makeChat()
        // Three points down the stage's own rectangle, including its very top.
        for y in [ChatSurfaceView.topPad + 1, 40, Self.stageHeight * 0.9] {
            let hit = chat.hitTest(CGPoint(x: chat.bounds.midX, y: y))
            #expect(hit !== stage)
            #expect(hit?.isDescendant(of: stage) != true)
        }
    }

    /// And the well says no on its own account, so a future layout that stopped
    /// covering the stage would still not hand it a click.
    @Test("The well refuses hit tests even when nothing covers it")
    func theWellRefuses() {
        let (chat, stage) = makeChat()
        let well = stage.superview
        #expect(well != nil)
        #expect(well?.hitTest(CGPoint(x: 10, y: 10)) == nil)
        // The transcript, on the other hand, takes everything: keyboard focus
        // lives in the pill, always, in chat mode.
        #expect(chat.keyboardResponder.isDescendant(of: chat.editor))
    }

    // MARK: - Reduced prominence

    @Test("The stage stays mounted, dimmed to .92 and scaled to .96")
    func theStageIsReducedNotRemoved() {
        let (chat, stage) = makeChat()
        let well = try! #require(stage.superview)
        #expect(stage.superview != nil)                       // mounted, not a snapshot
        #expect(well.alphaValue == ChatSurfaceView.stageDim)
        let transform = well.layer?.affineTransform() ?? .identity
        #expect(abs(transform.a - ChatSurfaceView.stageScale) < 0.0001)
        #expect(abs(transform.d - ChatSurfaceView.stageScale) < 0.0001)
        // Anchored at the top of the pane and centred across it: an AppKit layer
        // anchors at (0, 0), so the scale alone would collapse it into a corner.
        #expect(well.frame.minY == ChatSurfaceView.topPad)
        let inset = chat.bounds.width * (1 - ChatSurfaceView.stageScale) / 2
        #expect(abs(transform.tx - inset) < 0.0001)
    }

    /// design.html §08: "scrolled back: the stage recedes, history slides under
    /// a top fade, a jump-to-latest bead appears".
    @Test("Scrolled into the past the stage recedes; jump-to-latest brings it back")
    func scrollbackRecedes() {
        let (chat, stage) = makeChat()
        let well = try! #require(stage.superview)

        post(["type": "scrollback", "past": true], to: chat)
        #expect(chat.recededIntoThePast)
        #expect(well.alphaValue == ChatSurfaceView.recededDim)
        // No blur, by ruling (G2.4): the recede is a dim, and the stage stays
        // legible behind the history.
        #expect(well.layer?.filters?.isEmpty != false)

        post(["type": "scrollback", "past": false], to: chat)
        #expect(!chat.recededIntoThePast)
        #expect(well.alphaValue == ChatSurfaceView.stageDim)
        #expect(well.layer?.filters?.isEmpty != false)
    }

    // MARK: - ⌄ / ⌃

    /// The pill's ⌄ hides the bubbles to *watch* — it does not make the stage
    /// touchable, it does not close anything, and (G2.3 ruling) it does NOT
    /// resize the surface: the transcript is a layer over the stage, so
    /// revealing the stage costs nothing in geometry.
    @Test("Collapsing the transcript never resizes the pane; the stage stays inert")
    func collapsing() {
        let (chat, stage) = makeChat()
        var remeasured = 0
        chat.onPaneChange = { remeasured += 1 }

        post(["type": "transcript", "collapsed": true], to: chat)
        #expect(chat.collapsed)
        // No re-measure and no height change: collapse is a web-layer fact.
        #expect(remeasured == 0)
        // Still inert, still one step back: "collapsing only clears the view to
        // watch; Done is the way to touch."
        #expect(chat.hitTest(CGPoint(x: chat.bounds.midX, y: 40)) !== stage)
        #expect(stage.superview?.alphaValue == ChatSurfaceView.stageDim)

        post(["type": "transcript", "collapsed": false], to: chat)
        #expect(!chat.collapsed)
        #expect(remeasured == 0)
    }

    /// flow.md: "A blank slot has no stage: chat only." Same glass, same pill,
    /// nothing behind it — and nothing for ⌄ to reveal, so the page is told so.
    @Test("A blank slot has no stage and takes the whole pane")
    func theBlankSlot() {
        let (chat, _) = makeChat(withStage: false)
        #expect(!chat.hasStage)
        #expect(chat.stageInset == 0)
        #expect(ChatSurfaceView.panelHeight(stageHeight: nil) == ChatSurfaceView.blankPanelHeight)
    }

    // MARK: - What the page is told

    /// The transcript leaves room for the stage rather than being given a
    /// smaller frame — that overlap is how a bubble floats over the stage's
    /// bottom edge instead of being clipped by a box.
    @Test("The stage's depth reaches the page, once per change")
    func theStageIsPublished() {
        let (chat, _) = makeChat()
        chat.bridge.submit(.ready)
        chat.bridge.setStage(present: true, inset: 0)     // clear the cache
        let before = chat.bridge.emitted.count
        chat.bridge.setStage(present: true, inset: Self.stageHeight * ChatSurfaceView.stageScale)
        #expect(chat.bridge.emitted.count == before + 1)
        let script = try! #require(chat.bridge.emitted.last)
        #expect(script.contains("\"stage\""))
        #expect(script.contains("141"))                  // 160 × 0.88, rounded to 0.5

        // A re-layout that changed nothing costs nothing: `layout` runs on every
        // applied commit, and a live app commits several times a second.
        chat.bridge.setStage(present: true, inset: Self.stageHeight * ChatSurfaceView.stageScale)
        #expect(chat.bridge.emitted.count == before + 1)
    }

    // MARK: - What the next visit inherits (G2.6)

    /// flow.md, Knobs: "Closing does not lose the visit: reopening restores
    /// the session *and* its mode." Walking away from a conversation and
    /// coming back must not silently swap it for the stage.
    @Test("A closed chat reopens as that chat")
    func aClosedChatReopensAsChat() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        let app = session.strip.apps[0]

        controller.present(.chat(app: app), animated: false)
        controller.present(.collapsed, animated: false)
        controller.surfaceForTesting.onClick?()
        #expect(controller.presentation == .chat(app: app))

        // …and a stage visit reopens as the stage: the memory is the mode the
        // user left, not a preference for chat.
        controller.present(.expanded(app: app), animated: false)
        controller.present(.collapsed, animated: false)
        controller.surfaceForTesting.onClick?()
        #expect(controller.presentation == .expanded(app: app))
    }

    /// The other half of the ruling: the ⌄ peek is state *inside* one chat
    /// visit. Every arrival into chat shows the conversation.
    @Test("Entering chat always reopens the transcript")
    func enteringChatShowsTheTranscript() {
        let (chat, _) = makeChat()
        chat.bridge.submit(.ready)                       // the page is up
        chat.editor.onTranscript?(true)                  // the page's ⌄
        #expect(chat.collapsed)

        chat.showTranscript()
        #expect(!chat.collapsed)
        let script = chat.bridge.emitted.last
        #expect(script?.contains("\"transcript\"") == true, "the page is told, not just the view")
        #expect(script?.contains("\"collapsed\":false") == true)
    }

    // MARK: - Esc

    /// **The call: one step.** flow.md's Transitions table has exactly one row
    /// for Esc — "Visit | click outside, or Esc | Resting" — and chat is a *mode
    /// of the visit*, not a sheet over it. A two-step Esc would give the same
    /// key two meanings separated by invisible state, and would strand a user
    /// who pressed it to dismiss the notch in front of a stage they did not ask
    /// for. The page keeps the one exception that is not about presentation at
    /// all: while a turn is running, Esc interrupts the turn and never gets
    /// here.
    @Test("Esc belongs to the visit, and the page hands it over explicitly")
    func escapeIsTheVisits() {
        #expect(EditorBridge.command(from: ["type": "escape"]) == .escape)
        let (chat, _) = makeChat()
        var escapes = 0
        chat.onEscape = { escapes += 1 }
        post(["type": "escape"], to: chat)
        #expect(escapes == 1)
        // …and it is never mistaken for something to send to the host.
        #expect(chat.bridge.emitted.isEmpty)
    }

    @Test("The page's two new messages parse, and an unknown one still does not")
    func theCommands() {
        #expect(EditorBridge.command(from: ["type": "transcript", "collapsed": true])
            == .transcript(collapsed: true))
        #expect(EditorBridge.command(from: ["type": "scrollback", "past": true])
            == .scrollback(past: true))
        // Absent flags are the safe direction: nothing collapsed, nothing past.
        #expect(EditorBridge.command(from: ["type": "transcript"]) == .transcript(collapsed: false))
        #expect(EditorBridge.command(from: ["type": "sudo"]) == nil)
    }
}

/// The panel body's material in chat mode (design.html §01 `.glasspanel`,
/// flow.md Material: "The chat surface runs opaque at the top to clear at the
/// bottom; the prompt pill sits where the glass is clearest").
///
/// Asserted in **pixels**, because every other way of checking it asserts that
/// the code says what it says rather than that the glass fades — and a gradient
/// that renders upside down passes every structural test there is.
@MainActor
@Suite("Chat mode — the glass")
struct ChatGlassTests {
    private func surface(_ presentation: ShellPresentation) -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.setBodyMaterial(presentation.isConversation ? .chatGlass : .solid)
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        surface.present(
            presentation,
            content: FlippedView(),
            width: PanelLimits.defaultWidth,
            height: 360,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        surface.displayIfNeeded()
        return surface
    }

    /// Alpha at a point of the rendered surface, 0…1.
    private func alpha(of surface: ShellSurfaceView, atY y: CGFloat) -> CGFloat {
        let region = surface.currentShapeRect
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(region.width), pixelsHigh: Int(region.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            Issue.record("no bitmap")
            return -1
        }
        surface.cacheDisplay(in: region, to: rep)
        let point = NSPoint(x: region.width / 2, y: y)
        return rep.colorAt(x: Int(point.x), y: Int(point.y))?.alphaComponent ?? -1
    }

    @Test("Chat glass: opaque under the notch, all but clear at the pill")
    func theGlassFades() {
        let chat = surface(.chat(app: "stocks"))
        let shape = chat.currentShapeRect
        let underTheNotch = alpha(of: chat, atY: chat.panelWingRowHeight + 6)
        let atThePill = alpha(of: chat, atY: shape.height - 8)

        // The top of the pane is the notch's own black — the stage sits in it.
        #expect(underTheNotch > 0.9)
        // The bottom is still the clearest glass in the product, and that is
        // where the pill lives — but it is a *material* now rather than the
        // near-nothing design.html drew over its own dark page.
        //
        // The old bound here was `< 0.4`, matching a `.18` floor, and on device
        // that floor meant a bright window came through the bottom of the pane
        // almost intact: ink-2 measured 1.26:1 against white. The floor is `.55`
        // (see `LedgeGlass.chat` and `ChatGlassLegibilityTests`), so the range
        // moves with it. What has to stay true is the *shape* of the material —
        // opaque at the notch, clearest at the pill — and that is the third
        // assertion, which is the one that was ever really the point.
        #expect(atThePill < 0.75)
        #expect(atThePill > 0.4)
        #expect(underTheNotch > atThePill)
    }

    @Test("Every other surface is solid black glass, top to bottom")
    func theStageIsOpaque() {
        let stage = surface(.expanded(app: "stocks"))
        let shape = stage.currentShapeRect
        #expect(alpha(of: stage, atY: stage.panelWingRowHeight + 6) > 0.9)
        #expect(alpha(of: stage, atY: shape.height - 8) > 0.9)
        #expect(stage.bodyMaterial == .solid)
    }

    /// principle 10 / design.html §07: arrivals pop, returns settle. The
    /// transcript pane coming over the stage is an arrival; the glass lifting
    /// back off it is a return, and returns are always the calmer of the two.
    @Test("Entering chat pops, leaving settles")
    func theMotion() {
        let surface = surface(.expanded(app: "stocks"))
        surface.present(
            .chat(app: "stocks"), content: FlippedView(),
            width: PanelLimits.defaultWidth, height: 380, animated: true
        )
        #expect(surface.lastSpring?.overshoots == true)
        #expect(surface.lastSpring == LedgeMotion.Spring.open)

        surface.present(
            .expanded(app: "stocks"), content: FlippedView(),
            width: PanelLimits.defaultWidth, height: 360, animated: true
        )
        #expect(surface.lastSpring?.overshoots == false)
        #expect(surface.lastSpring == LedgeMotion.Spring.close)
    }
}
