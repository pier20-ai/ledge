import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

@MainActor
@Suite("Protocol renderer (spec §5)")
struct ProtocolRendererTests {
    private func makeStack() -> (ProtocolEngine, ProtocolRenderer) {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        return (engine, renderer)
    }

    private func envelope(_ name: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: Fixtures.data(name))
    }

    @Test("commit-mount builds a stack root with the right children/kinds")
    func mountBuildsTree() throws {
        let (engine, renderer) = makeStack()
        engine.receive(try envelope("commit-mount.json"))

        let root = try #require(renderer.rootView(for: "stocks") as? NSStackView)
        #expect(root.arrangedSubviews.count == 4)         // ids 2..5
        #expect(renderer.kind(app: "stocks", id: 3) == .text)
        #expect(renderer.kind(app: "stocks", id: 4) == .chart)
        #expect(renderer.kind(app: "stocks", id: 5) == .button)

        // The text node maps to an editable-off NSTextField carrying the content.
        let priceField = try #require(renderer.view(app: "stocks", id: 3) as? NSTextField)
        #expect(priceField.stringValue == "$214.62")
    }

    @Test("button label/variant update in place — a chess piece must redraw")
    func buttonUpdates() throws {
        let (engine, renderer) = makeStack()
        engine.receive(try envelope("commit-mount.json"))

        let button = try #require(renderer.view(app: "stocks", id: 5) as? LedgeButton)
        #expect(button.currentLabel == "Refresh")

        engine.receive(Envelope(
            app: "stocks",
            seq: 9,
            type: "commit",
            payload: try JSONDecoder().decode(JSONValue.self, from: Data(
                #"{"mutations":[{"op":"update","id":5,"props":{"label":"♞","variant":"accent"}}]}"#.utf8
            ))
        ))
        #expect(button.currentLabel == "♞")
    }

    @Test("commit-update mutates in place and removes the button subtree")
    func updateAndRemove() throws {
        let (engine, renderer) = makeStack()
        engine.receive(try envelope("commit-mount.json"))
        engine.receive(try envelope("commit-update.json"))

        let root = try #require(renderer.rootView(for: "stocks") as? NSStackView)
        #expect(root.arrangedSubviews.count == 3)          // button (id 5) removed
        #expect(renderer.view(app: "stocks", id: 5) == nil)

        let priceField = try #require(renderer.view(app: "stocks", id: 3) as? NSTextField)
        #expect(priceField.stringValue == "$215.10")       // content updated
        #expect(priceField.textColor == LedgeTheme.green)  // color → semantic green
    }

    @Test("app:crashed replaces the app content with an error card")
    func errorCard() throws {
        let (engine, renderer) = makeStack()
        engine.receive(try envelope("commit-mount.json"))
        #expect(renderer.rootView(for: "stocks") is NSStackView)

        let crash = Envelope(app: "stocks", seq: 99, type: "app", payload: .object([
            "state": .string("crashed"),
            "error": .object(["message": .string("TypeError: x"), "stack": .string("at app.jsx:12")]),
        ]))
        engine.receive(crash)
        #expect(renderer.rootView(for: "stocks") is ErrorCardView)
    }

    @Test("A canvas node receives coalesced draw ops without error")
    func canvasDraw() throws {
        let (engine, renderer) = makeStack()
        let commit = Envelope(app: "game", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("canvas"),
                         "props": .object(["w": .int(80), "h": .int(40), "focusable": .bool(true)])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ]))
        engine.receive(commit)
        let canvas = try #require(renderer.view(app: "game", id: 2) as? ProtocolCanvasView)
        canvas.frame = CGRect(x: 0, y: 0, width: 80, height: 40)

        let draw = Envelope(app: "game", seq: 2, type: "draw", payload: .object([
            "id": .int(2),
            "ops": .array([
                .object(["op": .string("clear")]),
                .object(["op": .string("rect"), "x": .int(4), "y": .int(4), "w": .int(10), "h": .int(10),
                         "fill": .string("#30D158"), "radius": .int(2)]),
            ]),
        ]))
        engine.receive(draw)
        engine.flushDraws()                                // blits latest to the canvas
        #expect(canvas.focusable)
    }

    @Test("stack fill/stroke/radius map to theme tokens, and only to tokens")
    func containerTokens() throws {
        let (engine, renderer) = makeStack()
        let commit = Envelope(app: "deals", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("stack"),
                         "props": .object([
                            "axis": .string("h"),
                            "fill": .string("greenTint"),
                            "stroke": .string("green"),
                            "radius": .int(10),
                         ])]),
                // An unknown token is not a color — it must fall back to "no
                // styling", never to something the app didn't ask for.
                .object(["op": .string("create"), "id": .int(3), "kind": .string("stack"),
                         "props": .object(["axis": .string("h"), "fill": .string("#ff0000")])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(3), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ]))
        engine.receive(commit)

        let tinted = try #require(renderer.view(app: "deals", id: 2))
        #expect(tinted.layer?.backgroundColor == LedgeTheme.greenTint.cgColor)
        #expect(tinted.layer?.borderColor == LedgeTheme.greenStroke.cgColor)
        #expect(tinted.layer?.cornerRadius == 10)

        let raw = try #require(renderer.view(app: "deals", id: 3))
        #expect(raw.layer?.backgroundColor == nil)          // no token, no styling
    }

    @Test("distribute=equal shares a row's width (§5)")
    func equalDistribution() throws {
        let (engine, renderer) = makeStack()
        let commit = Envelope(app: "chips", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("h"), "distribute": .string("equal")])]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ]))
        engine.receive(commit)
        let stack = try #require(renderer.rootView(for: "chips") as? NSStackView)
        #expect(stack.distribution == .fillEqually)
    }

    @Test("A new generation discards all app view state (§1)")
    func reconnectDiscards() throws {
        let (engine, renderer) = makeStack()
        engine.receive(try envelope("commit-mount.json"))
        #expect(renderer.rootView(for: "stocks") != nil)

        engine.connectionOpened(generation: 2)
        #expect(renderer.rootView(for: "stocks") == nil)   // all view state gone
    }
}
