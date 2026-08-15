import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The horizontal swipe walks the session strip** — one of the two gestures
/// principle 9 allows besides the click, and now the only thing a sideways flick
/// means anywhere in the product.
///
/// It used to mean two other things, and both are gone. On a mini it dismissed
/// the peek: a gesture nothing else in the product has, taught in the one place
/// a user is least able to experiment. On the pill it became an id-0 `swipe`
/// event for whichever app owned the wing, which made a *fixed* gesture
/// vocabulary app-extensible. What survived is `SwipeRecognizer` — the policy is
/// unchanged, only its destination is.
@MainActor
@Suite("The swipe walks the strip (principle 9, flow.md)")
struct SwipeGestureTests {
    // MARK: - The policy

    /// One trackpad gesture: `count` deltas of `dx` each, then a finger lift.
    private func gesture(
        dx: CGFloat,
        dy: CGFloat = 0,
        count: Int = 1,
        from time: TimeInterval = 100,
        into recognizer: inout SwipeRecognizer
    ) -> [SwipeRecognizer.Direction] {
        var fired: [SwipeRecognizer.Direction] = []
        for step in 0..<count {
            if let direction = recognizer.feed(
                dx: dx, dy: dy,
                began: step == 0, ended: false,
                at: time + Double(step) * 0.016
            ) {
                fired.append(direction)
            }
        }
        _ = recognizer.feed(dx: 0, dy: 0, began: false, ended: true, at: time + 0.2)
        return fired
    }

    @Test("Travel accumulates across a gesture and fires once, in the right direction")
    func firesOncePerGesture() {
        var recognizer = SwipeRecognizer()
        // Six frames of 10 pt: no single delta is a swipe, the gesture is.
        #expect(gesture(dx: 10, count: 6, into: &recognizer) == [.right])

        var backwards = SwipeRecognizer()
        #expect(gesture(dx: -10, count: 6, into: &backwards) == [.left])
    }

    @Test("A short scroll is not a swipe, and a diagonal one is not either")
    func rejectsWhatIsNotASwipe() {
        var short = SwipeRecognizer()
        #expect(gesture(dx: 4, count: 3, into: &short).isEmpty)

        // Mostly vertical: the pill sits under the menu bar, where plenty of
        // scrolling is aimed at something else entirely.
        var diagonal = SwipeRecognizer()
        #expect(gesture(dx: 10, dy: 12, count: 6, into: &diagonal).isEmpty)
    }

    @Test("A new gesture re-arms; a quiet gap does too, for wheels that have no phases")
    func gesturesAreSeparated() {
        var recognizer = SwipeRecognizer()
        #expect(gesture(dx: 10, count: 6, from: 100, into: &recognizer) == [.right])
        #expect(gesture(dx: 10, count: 6, from: 200, into: &recognizer) == [.right])

        // A mouse wheel carries no phase at all, so only the idle gap separates
        // two flicks — and nothing separates one long one.
        var wheel = SwipeRecognizer()
        var fired: [SwipeRecognizer.Direction] = []
        for step in 0..<10 {
            if let direction = wheel.feed(
                dx: 8, dy: 0, began: false, ended: false, at: 300 + Double(step) * 0.05
            ) {
                fired.append(direction)
            }
        }
        #expect(fired == [.right])
        // …and after the wheel goes quiet, the next flick is a new gesture.
        #expect(wheel.feed(dx: 30, dy: 0, began: false, ended: false, at: 400) == .right)
    }

    @Test("A gesture that reverses mid-flight reports where it actually went")
    func travelIsNetNotPeak() {
        var recognizer = SwipeRecognizer()
        var fired: [SwipeRecognizer.Direction] = []
        for (step, dx) in [20.0, -20.0, -20.0, -20.0].enumerated() {
            if let direction = recognizer.feed(
                dx: dx, dy: 0, began: step == 0, ended: false, at: 500 + Double(step) * 0.016
            ) {
                fired.append(direction)
            }
        }
        #expect(fired == [.left])
    }

    // MARK: - The surface

    /// A trackpad scroll delta as AppKit delivers one. Phases ride on the
    /// underlying `CGEvent`; `NSEvent` has no initializer that takes them.
    private func scroll(dx: CGFloat, dy: CGFloat = 0, momentum: Bool = false) -> NSEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        )!
        // 2 = kCGScrollPhaseChanged, and kCGMomentumScrollPhaseContinue.
        event.setIntegerValueField(
            momentum ? .scrollWheelEventMomentumPhase : .scrollWheelEventScrollPhase,
            value: 2
        )
        return NSEvent(cgEvent: event)!
    }

    private func rightClick(in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeSurface() -> (ShellSurfaceView, Box<[SwipeRecognizer.Direction]>) {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let fired = Box<[SwipeRecognizer.Direction]>([])
        surface.onSwipe = { fired.value.append($0) }
        return (surface, fired)
    }

    /// The visit is where the gesture means something now, which is the inverse
    /// of the old law ("only the pill and the mini are small enough to *be* the
    /// gesture"). A strip you walk is a thing you walk while you are looking at
    /// it.
    @Test("A sideways flick across the visit is reported once")
    func visitReportsSwipes() {
        let (surface, fired) = makeSurface()
        surface.present(.expanded(app: "deals"), content: nil, width: 440, height: 300, animated: false)
        for _ in 0..<6 { surface.scrollWheel(with: scroll(dx: -10)) }
        #expect(fired.value == [.left])
    }

    /// A vertical flick is still a scroll: an app's list, the transcript. The
    /// recognizer's 1.5× dominance rule is the whole of that guarantee, and it
    /// is what lets the visit be swipeable without every list flick becoming a
    /// session change.
    @Test("A vertical scroll in the visit is never a swipe")
    func verticalScrollIsNotASwipe() {
        let (surface, fired) = makeSurface()
        surface.present(.expanded(app: "deals"), content: nil, width: 440, height: 300, animated: false)
        for _ in 0..<10 { surface.scrollWheel(with: scroll(dx: 2, dy: 20)) }
        #expect(fired.value.isEmpty)
    }

    @Test("Momentum after the fingers leave is not a gesture of its own")
    func momentumIsIgnored() {
        let (surface, fired) = makeSurface()
        surface.present(.expanded(app: "deals"), content: nil, width: 440, height: 300, animated: false)

        // Inertia on its own: the fingers are already gone, so there is no
        // gesture here to report.
        for _ in 0..<20 { surface.scrollWheel(with: scroll(dx: 10, momentum: true)) }
        #expect(fired.value.isEmpty)

        // A real flick fires once — and the inertia that follows it, which is
        // the same intention still travelling, adds nothing.
        for _ in 0..<6 { surface.scrollWheel(with: scroll(dx: 10)) }
        for _ in 0..<20 { surface.scrollWheel(with: scroll(dx: 10, momentum: true)) }
        #expect(fired.value == [.right])
    }

    /// **The defect.** A scroll event goes to the deepest view under the cursor
    /// and only bubbles up if nobody eats it — and in a visit almost everything
    /// eats it: a `stack scroll` is an NSScrollView, a focusable canvas takes
    /// the wheel, and the chat surface is a WKWebView, which swallows the lot.
    /// So `‹` and `›` walked the strip and the swipe did nothing, which is
    /// exactly what Manu saw. Measured on device: with the plain placeholder up
    /// the flick walked; the moment it landed on the editor, every scroll event
    /// went to the web view and the surface was never called.
    ///
    /// The gesture is read at the **window** now, ahead of dispatch — the one
    /// place that is above every view an app can put on the glass.
    @Test("The panel reads the flick before any view can eat it")
    func thePanelReadsTheFlickFirst() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let panel = NotchPanel(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = surface
        panel.translateScroll = { [weak surface] in surface?.translateScroll($0) ?? false }
        surface.present(.expanded(app: "deals"), content: nil, width: 440, height: 300, animated: false)

        // Five frames of 10 pt is not yet a swipe: the panel takes nothing, and
        // whatever is under the cursor gets its scroll.
        for _ in 0..<2 { #expect(panel.consumesForWalk(scroll(dx: -10)) == false) }
        // The frame that crosses the 28 pt threshold is consumed — it never
        // reaches the app's tree at all.
        #expect(panel.consumesForWalk(scroll(dx: -10)))

        // A vertical flick is the app's, always: the dominance rule decides, and
        // the panel hands it straight back.
        for _ in 0..<10 { #expect(panel.consumesForWalk(scroll(dx: 2, dy: 20)) == false) }
        // …and so is everything that is not a scroll.
        #expect(panel.consumesForWalk(rightClick(in: panel)) == false)
    }

    /// …and the whole path, through the real panel: six frames of a sideways
    /// flick sent to the window walk the strip, with an app's own view sitting
    /// over the glass the entire time.
    @Test("A flick on the real panel walks the strip, over a greedy app view")
    func realPanelWalksTheStrip() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        let apps = session.strip.apps
        controller.present(.expanded(app: apps[0]), animated: false)

        let panel = controller.panelForTesting
        let surface = controller.surfaceForTesting
        let greedy = GreedyScrollView(frame: surface.panelContentHost.bounds)
        surface.panelContentHost.addSubview(greedy)
        surface.layoutSubtreeIfNeeded()

        for _ in 0..<6 { panel.sendEvent(scroll(dx: -10)) }
        #expect(greedy.received == 0)
        #expect(controller.presentation == .expanded(app: apps[1]))

        // A vertical flick is still the app's: the shell takes horizontal walks
        // and nothing else.
        for _ in 0..<10 { panel.sendEvent(scroll(dx: 2, dy: 20)) }
        #expect(controller.presentation == .expanded(app: apps[1]))
    }

    /// Below the visit the gesture has no meaning at all (principle 9 leaves the
    /// pill exactly one gesture, the click). It used to be reported and then
    /// dropped by the controller; now it is never reported, so there is nothing
    /// for a future caller to start believing in.
    @Test("The surface does not even report a flick below the visit")
    func collapsedReportsNothing() {
        let (surface, fired) = makeSurface()
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        for _ in 0..<6 { #expect(surface.translateScroll(scroll(dx: -10)) == false) }
        #expect(fired.value.isEmpty)

        surface.present(.summary(app: "music"), content: nil, width: 300, height: 90, animated: false)
        for _ in 0..<6 { #expect(surface.translateScroll(scroll(dx: -10)) == false) }
        #expect(fired.value.isEmpty)
    }

    /// **…and not on the ledge** (G3.2). Zoomed out, the shelf is longer than
    /// the panel and a sideways flick slides it; it cannot also be the walk,
    /// because the walk *leaves* the ledge — two fingers moved to see the far
    /// end would pan 28 points and then drop you into a session. `‹ ›` and Back
    /// are still there, so nothing became unreachable; only the gesture moved.
    @Test("The ledge keeps the horizontal flick: it is the pan, not the walk")
    func theLedgeOwnsTheFlick() {
        let (surface, fired) = makeSurface()
        surface.present(.overview, content: nil, width: 440, height: 300, animated: false)
        for _ in 0..<8 { #expect(surface.translateScroll(scroll(dx: -10)) == false) }
        #expect(fired.value.isEmpty)

        // …and the very next visit walks exactly as it did.
        surface.present(.expanded(app: "deals"), content: nil, width: 440, height: 300, animated: false)
        for _ in 0..<3 { surface.translateScroll(scroll(dx: -10)) }
        #expect(fired.value == [.left])
    }

    /// One feed per event. The panel asks first and hands a non-swipe back to be
    /// dispatched — which can bring the very same `NSEvent` round to the
    /// surface's own `scrollWheel`, where feeding its deltas a second time would
    /// trip the 28 pt threshold at half a flick.
    @Test("The same event is never fed to the recognizer twice")
    func oneFeedPerEvent() {
        let (surface, fired) = makeSurface()
        surface.present(.expanded(app: "deals"), content: nil, width: 440, height: 300, animated: false)
        for _ in 0..<3 {
            let event = scroll(dx: -8)
            surface.translateScroll(event)      // the panel's pass
            surface.scrollWheel(with: event)    // …and the dispatched one
        }
        // 3 × 8 pt is 24: under the 28 pt threshold however many times it is
        // counted, and double-feeding would have made it 48.
        #expect(fired.value.isEmpty)
        surface.translateScroll(scroll(dx: -8))
        #expect(fired.value == [.left])
    }

    // MARK: - What a swipe does

    /// One meaning, and only in a visit. A flick on the collapsed pill or on a
    /// swell is dropped: the pill has exactly one gesture (the click), and a
    /// notification you could flick away would be teaching a gesture the rest of
    /// the product does not have.
    @Test("Only the visit walks; the pill and the swells ignore the gesture")
    func onlyTheVisitWalks() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        session.inject(Envelope(app: "music", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("mini")]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))

        controller.present(.collapsed, animated: false)
        #expect(controller.handleSwipe(.left) == false)

        // A notification is up. It used to be dismissed by exactly this; now it
        // is not, because a swell is not a thing you swipe.
        controller.present(.notification(app: "music"), animated: false)
        #expect(controller.handleSwipe(.left) == false)
        #expect(controller.presentation == .mini(app: "music"))

        // The summary is the same: it lives and dies by the pointer, not by a
        // gesture of its own.
        controller.present(.summary(app: "music"), animated: false)
        #expect(controller.handleSwipe(.left) == false)
        #expect(controller.presentation == .summary(app: "music"))
    }

    /// A swipe and `‹|›` are the same code path (flow.md: "the right wing `<|>`
    /// walks the strip; a horizontal swipe does the same"), so the direction has
    /// to agree with the arrows: a finger moving **left** turns the page
    /// forward, exactly as `›` does.
    @Test("In a visit, a swipe walks the strip in the direction the arrows do")
    func visitSwipeWalksTheStrip() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        let strip = session.strip
        let first = try #require(strip.apps.first)
        let second = try #require(strip.apps.dropFirst().first)

        controller.present(.expanded(app: first), animated: false)
        #expect(controller.handleSwipe(.left))
        #expect(controller.presentation == .expanded(app: second))

        // …and back.
        #expect(controller.handleSwipe(.right))
        #expect(controller.presentation == .expanded(app: first))

        // Off the near end: the blank slot, which is what **[+]** became.
        #expect(controller.handleSwipe(.right))
        #expect(controller.presentation == .newApp)
    }

    /// Walking onto a session shows the session, never its transcript. Lowering
    /// the glass is the left wing's job and nothing else's — the old
    /// "re-selecting an app opens its chat" shortcut would otherwise make every
    /// full lap of the strip land in the editor.
    @Test("Walking onto a session shows the stage, never the transcript")
    func walkingNeverOpensTheEditor() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        let apps = session.strip.apps
        controller.present(.expanded(app: apps[0]), animated: false)
        for _ in 0..<(apps.count + 1) {
            _ = controller.handleSwipe(.left)
            #expect(!controller.presentation.isChat)
        }
        // A full lap ends where it started.
        #expect(controller.presentation == .expanded(app: apps[0]))
    }
}

/// A view that takes the wheel and keeps it — every real panel surface does:
/// an NSScrollView, a focusable canvas, the editor's WKWebView. `hitTest`
/// answers for the whole view so a test never has to do coordinate arithmetic
/// to be sure this is what the event would have been dispatched to.
final class GreedyScrollView: NSView {
    private(set) var received = 0
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func scrollWheel(with event: NSEvent) { received += 1 }
}

/// A mutable box, so a `@Sendable` callback can record into a `let`.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
