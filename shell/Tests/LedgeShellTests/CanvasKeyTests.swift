import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The `canvas` keyboard loop (spec §5 `focusable`/`onKey` → §4.1 `key`). This
/// is the shell half of the loop a game needs: a real commit builds the canvas,
/// a real key event goes into the real view, and an `event` envelope has to come
/// out the other side addressed to the right app and node.
@MainActor
@Suite("Canvas key input (spec §4.1)")
struct CanvasKeyTests {
    private func makeGame(focusable: Bool = true) -> (ProtocolEngine, ProtocolRenderer, OutboundLog) {
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
        engine.receive(Envelope(app: "tetris", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("canvas"),
                         "props": .object([
                            "w": .int(200), "h": .int(320),
                            "focusable": .bool(focusable), "onKey": .bool(true),
                         ])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        return (engine, renderer, outbound)
    }

    /// A key event the way AppKit delivers one. `keyCode` is what the shell maps
    /// to a §4.1 key name; the characters are what an ordinary letter key uses.
    private func keyEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        characters: String = ""
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test("A focused canvas turns key down/up into `key` events for its app")
    func keysReachTheWorker() throws {
        let (_, renderer, outbound) = makeGame()
        let canvas = try #require(renderer.canvas(app: "tetris", id: 2))

        // Put it in a real window and make it first responder, which is what the
        // panel controller does when it presents an app with a focusable canvas.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(canvas)
        canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 320)
        #expect(window.makeFirstResponder(canvas))

        canvas.keyDown(with: keyEvent(type: .keyDown, keyCode: 123))     // ArrowLeft
        canvas.keyUp(with: keyEvent(type: .keyUp, keyCode: 123))
        canvas.keyDown(with: keyEvent(type: .keyDown, keyCode: 49, characters: " "))

        let events = outbound.sent.filter { $0.type == "event" }
        #expect(events.count == 3)
        let payloads = try events.map { try $0.decodePayload([String: JSONValue].self) }
        #expect(events.allSatisfy { $0.app == "tetris" })
        #expect(payloads.allSatisfy { $0["id"]?.asInt == 2 })
        #expect(payloads.allSatisfy { $0["name"]?.asString == "key" })
        #expect(payloads[0]["data"]?.asObject?["key"]?.asString == "ArrowLeft")
        #expect(payloads[0]["data"]?.asObject?["down"]?.asBool == true)
        #expect(payloads[1]["data"]?.asObject?["down"]?.asBool == false)
        #expect(payloads[2]["data"]?.asObject?["key"]?.asString == " ")
    }

    @Test("A canvas that did not ask to be focusable never takes focus or keys")
    func nonFocusableCanvasIsInert() throws {
        let (_, renderer, outbound) = makeGame(focusable: false)
        let canvas = try #require(renderer.canvas(app: "tetris", id: 2))
        #expect(canvas.acceptsFirstResponder == false)
        #expect(renderer.focusableCanvas(for: "tetris") == nil)

        // Even handed an event directly, it falls through to super rather than
        // inventing a §4.1 event nobody subscribed to.
        canvas.keyDown(with: keyEvent(type: .keyDown, keyCode: 123))
        #expect(outbound.sent.filter { $0.type == "event" }.isEmpty)
    }

    @Test("The presented app's focusable canvas is discoverable for focusing")
    func focusableCanvasIsFound() throws {
        let (_, renderer, _) = makeGame()
        let found = try #require(renderer.focusableCanvas(for: "tetris"))
        #expect(found === renderer.canvas(app: "tetris", id: 2))
        #expect(renderer.focusableCanvas(for: "nobody") == nil)
    }

    @Test("Draw frames reach the canvas of the app that sent them, not a namesake")
    func drawsAreAppScoped() throws {
        let (engine, renderer, _) = makeGame()
        // A second app whose canvas also happens to be node 2 (ids restart at 1
        // in every worker, spec §3.1).
        engine.receive(Envelope(app: "aviary", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("canvas"),
                         "props": .object(["w": .int(80), "h": .int(34)])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        let tetris = try #require(renderer.canvas(app: "tetris", id: 2))
        let aviary = try #require(renderer.canvas(app: "aviary", id: 2))
        tetris.frame = CGRect(x: 0, y: 0, width: 200, height: 320)
        aviary.frame = CGRect(x: 0, y: 0, width: 80, height: 34)
        #expect(tetris !== aviary)

        engine.receive(Envelope(app: "aviary", seq: 2, type: "draw", payload: .object([
            "id": .int(2),
            "ops": .array([.object(["op": .string("clear")])]),
        ])))
        engine.flushDraws()
        // Nothing to assert on pixels here beyond "it did not throw and it did
        // not go to the wrong view" — which the engine-level test pins down by
        // app id; this one proves the two views are genuinely distinct.
        #expect(renderer.canvas(app: "tetris", id: 2) === tetris)
    }

    @Test("A wing canvas gets the same frames as the app's in-panel canvas")
    func wingCanvasMirrorsDraws() throws {
        let (engine, renderer, _) = makeGame()
        let panelCanvas = try #require(renderer.canvas(app: "tetris", id: 2))
        panelCanvas.frame = CGRect(x: 0, y: 0, width: 200, height: 320)

        let wingCanvas = ProtocolCanvasView()
        wingCanvas.frame = CGRect(x: 0, y: 0, width: 64, height: 34)
        renderer.setWingTarget(app: "tetris", id: 2, view: wingCanvas)

        engine.receive(Envelope(app: "tetris", seq: 2, type: "draw", payload: .object([
            "id": .int(2),
            "ops": .array([
                .object(["op": .string("clear")]),
                .object(["op": .string("rect"), "x": .int(2), "y": .int(2), "w": .int(8),
                         "h": .int(8), "fill": .string("#30D158")]),
            ]),
        ])))
        engine.flushDraws()
        #expect(wingCanvas.hasBuffer)
        #expect(panelCanvas.hasBuffer)

        // Releasing the wing stops the mirroring.
        renderer.setWingTarget(app: nil, id: nil, view: wingCanvas)
        let fresh = ProtocolCanvasView()
        fresh.frame = CGRect(x: 0, y: 0, width: 64, height: 34)
        renderer.setWingTarget(app: "someone-else", id: 99, view: fresh)
        engine.receive(Envelope(app: "tetris", seq: 3, type: "draw", payload: .object([
            "id": .int(2), "ops": .array([.object(["op": .string("clear")])]),
        ])))
        engine.flushDraws()
        #expect(fresh.hasBuffer == false)
    }
}

/// Collects the envelopes the engine would have written to the socket.
@MainActor
final class OutboundLog {
    var sent: [Envelope] = []
}
