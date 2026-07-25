import Foundation
import Testing
@testable import LedgeShellCore

/// The shell half of the agentic layer (spec §6): `apple`, `notify` and
/// `capture` arriving from the host, their results going back, and the app-level
/// (id 0) events the shell originates. The executors themselves are exercised
/// separately — `AppleExecutorTests` really does run AppleScript.
@MainActor
@Suite("Shell capabilities (spec §6)")
struct CapabilityTests {
    private func makeEngine(
        withCapabilities: Bool = true
    ) -> (ProtocolEngine, RecordingCapabilities, OutboundRecorder) {
        let capabilities = RecordingCapabilities()
        let outbound = OutboundRecorder()
        // The render delegate is deliberately not kept: capabilities never draw
        // anything, which is the whole reason they are a separate delegate.
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2),
            delegate: RecordingDelegate(),
            send: { outbound.record($0) }
        )
        if withCapabilities { engine.capabilities = capabilities }
        engine.connectionOpened(generation: 3)
        return (engine, capabilities, outbound)
    }

    private func envelope(_ name: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: Fixtures.data(name))
    }

    private func payload(_ envelope: Envelope) throws -> [String: JSONValue] {
        try envelope.decodePayload([String: JSONValue].self)
    }

    // MARK: - apple

    @Test("A script request reaches the executor and its value returns as appleResult")
    func appleScriptRoundTrip() throws {
        let (engine, capabilities, outbound) = makeEngine()
        engine.receive(try envelope("apple-script.json"))

        #expect(capabilities.appleCalls.count == 1)
        #expect(capabilities.appleCalls.first?.app == "meeting")
        #expect(capabilities.appleCalls.first?.invocation == .script("return 1 + 2"))
        #expect(outbound.all(ofType: "appleResult").isEmpty)   // still running

        capabilities.settleApple(.success(.int(3)))
        let result = try #require(outbound.last(ofType: "appleResult"))
        #expect(result.app == "meeting")
        #expect(try payload(result)["id"]?.asInt == 3)
        #expect(try payload(result)["ok"]?.asBool == true)
        #expect(try payload(result)["value"]?.asInt == 3)
        // A success carries no error key at all, rather than a null one.
        #expect(try payload(result)["error"] == nil)
    }

    @Test("A shortcut request carries its name and input")
    func appleShortcut() throws {
        let (engine, capabilities, _) = makeEngine()
        engine.receive(try envelope("apple-shortcut.json"))
        let invocation = try #require(capabilities.appleCalls.first?.invocation)
        guard case let .shortcut(name, input) = invocation else {
            Issue.record("expected a shortcut invocation")
            return
        }
        #expect(name == "Log Note")
        #expect(input?.asObject?["note"]?.asString == "standup at 10")
    }

    @Test("A failure comes back as ok:false with the executor's message")
    func appleFailure() throws {
        let (engine, capabilities, outbound) = makeEngine()
        engine.receive(try envelope("apple-shortcut.json"))
        capabilities.settleApple(.failure(CapabilityError("shortcut \"Log Note\" not found")))

        let result = try #require(outbound.last(ofType: "appleResult"))
        #expect(try payload(result)["ok"]?.asBool == false)
        #expect(try payload(result)["error"]?.asString == "shortcut \"Log Note\" not found")
    }

    @Test("An unknown kind is answered, not dropped — the app is awaiting a Promise")
    func appleMalformedIsAnswered() throws {
        let (engine, capabilities, outbound) = makeEngine()
        engine.receive(Envelope(app: "meeting", seq: 1, type: "apple", payload: .object([
            "id": .int(9),
            "kind": .string("telepathy"),
        ])))
        #expect(capabilities.appleCalls.isEmpty)
        let result = try #require(outbound.last(ofType: "appleResult"))
        #expect(try payload(result)["id"]?.asInt == 9)
        #expect(try payload(result)["ok"]?.asBool == false)
    }

    @Test("An engine with no capability host answers unsupported instead of hanging")
    func appleWithoutCapabilities() throws {
        let (engine, _, outbound) = makeEngine(withCapabilities: false)
        engine.receive(try envelope("apple-script.json"))
        let result = try #require(outbound.last(ofType: "appleResult"))
        #expect(try payload(result)["ok"]?.asBool == false)
        #expect(try payload(result)["error"]?.asString?.contains("no AppleScript capability") == true)
    }

    // MARK: - notify

    @Test("A notification reaches the presenter with its title and buttons")
    func notifyRouting() throws {
        let (engine, capabilities, outbound) = makeEngine()
        engine.receive(try envelope("notify.json"))

        let posted = try #require(capabilities.notifications.first)
        #expect(posted.app == "deals")
        #expect(posted.payload.id == 7)
        #expect(posted.payload.title == "Deal Watch")
        #expect(posted.payload.actions?.map(\.id) == ["open", "snooze"])
        #expect(posted.payload.actions?.first?.label == "Open listing")
        // Fire and forget: no ack envelope, because ctx.notify awaits nothing.
        #expect(outbound.sent.isEmpty)
    }

    @Test("A pressed button goes back as notifyAction (§6 extension)")
    func notifyActionOutbound() throws {
        let (engine, _, outbound) = makeEngine()
        engine.sendNotifyAction(app: "deals", id: 7, action: "open")
        let sent = try #require(outbound.last(ofType: "notifyAction"))
        #expect(sent.app == "deals")
        #expect(try payload(sent)["id"]?.asInt == 7)
        #expect(try payload(sent)["action"]?.asString == "open")
    }

    // MARK: - capture

    @Test("A capture request runs interactively and returns a path")
    func captureRoundTrip() throws {
        let (engine, capabilities, outbound) = makeEngine()
        engine.receive(try envelope("capture.json"))
        #expect(capabilities.captureCalls.first?.interactive == true)

        capabilities.settleCapture(.success("/tmp/ledge-capture-1.png"))
        let result = try #require(outbound.last(ofType: "captureResult"))
        #expect(try payload(result)["ok"]?.asBool == true)
        #expect(try payload(result)["path"]?.asString == "/tmp/ledge-capture-1.png")
    }

    @Test("A cancelled capture is a failed result, not a dropped request")
    func captureCancelled() throws {
        let (engine, capabilities, outbound) = makeEngine()
        engine.receive(try envelope("capture.json"))
        capabilities.settleCapture(.failure(CapabilityError("capture cancelled")))
        let result = try #require(outbound.last(ofType: "captureResult"))
        #expect(try payload(result)["ok"]?.asBool == false)
        #expect(try payload(result)["error"]?.asString == "capture cancelled")
    }

    @Test("`interactive` defaults to true when the host omits it")
    func captureDefaultsInteractive() throws {
        let (engine, capabilities, _) = makeEngine()
        engine.receive(Envelope(app: "flights", seq: 1, type: "capture", payload: .object([
            "id": .int(1),
        ])))
        #expect(capabilities.captureCalls.first?.interactive == true)
    }

    // MARK: - App-level events (id 0)

    @Test("The drop shelf's event is an ordinary §4.1 event at id 0")
    func appLevelEvent() throws {
        let (engine, _, outbound) = makeEngine()
        engine.emitAppEvent(
            app: "flights",
            name: "drop",
            data: .object(["paths": .array([.string("/Users/you/Downloads/pass.pdf")])])
        )
        let sent = try #require(outbound.last(ofType: "event"))
        #expect(sent.app == "flights")
        let body = try payload(sent)
        #expect(body["id"]?.asInt == 0)
        #expect(body["name"]?.asString == "drop")
        #expect(body["data"]?.asObject?["paths"]?.asArray?.count == 1)
    }

    @Test("Shell → host capability results are ignored if echoed back at us")
    func resultsAreOutboundOnly() throws {
        let (engine, capabilities, _) = makeEngine()
        #expect(engine.receive(try envelope("apple-result.json")) == false)
        #expect(engine.receive(try envelope("capture-result.json")) == false)
        #expect(engine.receive(try envelope("notify-action.json")) == false)
        #expect(capabilities.appleCalls.isEmpty)
    }
}
