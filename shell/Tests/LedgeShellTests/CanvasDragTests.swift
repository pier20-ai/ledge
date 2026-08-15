import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The `canvas` drag loop (spec §5 `onDrag` → §4.1 `drag`). The shell half of a
/// scrubber: real mouse events go into the real view, and `down`/`move`/`up`
/// envelopes have to come out addressed to the right app and node — coalesced on
/// the way, because a trackpad produces moves far faster than a panel redraws.
@MainActor
@Suite("Canvas drag input (spec §4.1)")
struct CanvasDragTests {
    /// Everything one scrubber needs, held together: the renderer keeps only a
    /// weak reference to itself inside the view's handlers, so a test that let
    /// it go would silently stop emitting anything at all.
    private struct Scrubber {
        let engine: ProtocolEngine
        let renderer: ProtocolRenderer
        let canvas: ProtocolCanvasView
        let outbound: OutboundLog
    }

    /// A canvas the size of the world clock's scrub ruler, in a real window so
    /// window→view coordinate conversion is the one the app would see.
    private func makeScrubber(
        onDrag: Bool = true,
        onClick: Bool = false
    ) -> Scrubber {
        let renderer = ProtocolRenderer()
        let outbound = OutboundLog()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 210, menubarHeight: 34, scale: 2, maxPanelHeight: 700),
            delegate: renderer,
            send: { outbound.sent.append($0) }
        )
        renderer.onEvent = { app, id, name, data in
            engine.emitEvent(app: app, id: id, name: name, data: data)
        }
        engine.connectionOpened(generation: 1)
        var props: [String: JSONValue] = ["w": .int(200), "h": .int(40)]
        if onDrag { props["onDrag"] = .bool(true) }
        if onClick { props["onClick"] = .bool(true) }
        engine.receive(Envelope(app: "worldclock", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("canvas"),
                         "props": .object(props)]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        let canvas = renderer.canvas(app: "worldclock", id: 2)!
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(canvas)
        canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        return Scrubber(engine: engine, renderer: renderer, canvas: canvas, outbound: outbound)
    }

    /// A mouse event whose `locationInWindow` is `point` expressed in
    /// **canvas-local** coordinates — the y-down space §3.4 ops use, which is
    /// also the space the emitted event reports. `convert(_:to: nil)` accounts
    /// for the canvas being flipped inside an unflipped window.
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in canvas: NSView) -> NSEvent {
        let window = canvas.window!
        return NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func dragEvents(_ log: OutboundLog) throws -> [[String: JSONValue]] {
        try log.sent
            .filter { $0.type == "event" }
            .map { try $0.decodePayload([String: JSONValue].self) }
            .filter { $0["name"]?.asString == "drag" }
            .compactMap { $0["data"]?.asObject }
    }

    @Test("Press-drag-release becomes down/move/up with canvas-local points")
    func phasesReachTheWorker() throws {
        let scrubber = makeScrubber()
        let (canvas, outbound) = (scrubber.canvas, scrubber.outbound)
        canvas.dragMoveInterval = 0              // no coalescing: assert every move

        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 20), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 60, y: 21), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 22), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 130, y: 23), in: canvas))

        let events = outbound.sent.filter { $0.type == "event" }
        #expect(events.allSatisfy { $0.app == "worldclock" })
        let payloads = try events.map { try $0.decodePayload([String: JSONValue].self) }
        #expect(payloads.allSatisfy { $0["id"]?.asInt == 2 })

        let drags = try dragEvents(outbound)
        #expect(drags.map { $0["phase"]?.asString } == ["down", "move", "move", "up"])
        #expect(drags.map { $0["x"]?.asDouble } == [10, 60, 120, 130])
        #expect(drags.first?["y"]?.asDouble == 20)
        // The release carries the final position, so an app that only ever saw
        // coalesced moves still lands on the value the user let go at.
        #expect(drags.last?["x"]?.asDouble == 130)
    }

    @Test("`move` is throttled shell-side; `down` and `up` never are")
    func movesAreCoalesced() throws {
        let scrubber = makeScrubber()
        let (canvas, outbound) = (scrubber.canvas, scrubber.outbound)
        // The shipping interval: a burst inside one frame collapses to its first.
        #expect(canvas.dragMoveInterval == ProtocolCanvasView.dragMoveInterval)

        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 0, y: 10), in: canvas))
        for x in 1...40 {
            canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: CGFloat(x), y: 10), in: canvas))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 40, y: 10), in: canvas))

        let drags = try dragEvents(outbound)
        let phases = drags.compactMap { $0["phase"]?.asString }
        #expect(phases.first == "down")
        #expect(phases.last == "up")
        // Forty moves in well under a 30 Hz frame: at most a couple survive.
        #expect(phases.filter { $0 == "move" }.count < 5)
        #expect(drags.last?["x"]?.asDouble == 40)
    }

    @Test("A canvas that never declared `onDrag` puts nothing on the socket")
    func undeclaredCanvasStaysSilent() throws {
        let scrubber = makeScrubber(onDrag: false)
        let (canvas, outbound) = (scrubber.canvas, scrubber.outbound)
        canvas.dragMoveInterval = 0

        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 5, y: 5), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 25, y: 5), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 25, y: 5), in: canvas))

        #expect(try dragEvents(outbound).isEmpty)
    }

    @Test("`onDrag` resolves from the merged prop set, so it can be turned off")
    func dragFollowsPartialUpdates() throws {
        let scrubber = makeScrubber(onDrag: false)
        let (engine, canvas, outbound) = (scrubber.engine, scrubber.canvas, scrubber.outbound)
        canvas.dragMoveInterval = 0
        #expect(canvas.dragEnabled == false)

        // Declared later (§3.1 partial update) — the phases start flowing.
        engine.receive(Envelope(app: "worldclock", seq: 2, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("update"), "id": .int(2),
                         "props": .object(["onDrag": .bool(true)])]),
            ]),
        ])))
        #expect(canvas.dragEnabled)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 8, y: 8), in: canvas))
        #expect(try dragEvents(outbound).count == 1)

        // Deleted with null — and it really does stop, rather than reading as
        // "unchanged" the way a create-only prop would.
        engine.receive(Envelope(app: "worldclock", seq: 3, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("update"), "id": .int(2), "props": .object(["onDrag": .null])]),
            ]),
        ])))
        #expect(canvas.dragEnabled == false)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 9, y: 9), in: canvas))
        #expect(try dragEvents(outbound).count == 1)
    }

    @Test("A canvas that asked for both gets both on press — neither is synthesized")
    func clickAndDragCoexist() throws {
        let scrubber = makeScrubber(onClick: true)
        let (canvas, outbound) = (scrubber.canvas, scrubber.outbound)
        canvas.dragMoveInterval = 0
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 12, y: 6), in: canvas))

        let names = try outbound.sent
            .filter { $0.type == "event" }
            .map { try $0.decodePayload([String: JSONValue].self)["name"]?.asString }
        #expect(names == ["click", "drag"])
    }
}
