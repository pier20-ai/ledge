import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The editor surface's bridge** — the pipe between the app's builder stream
/// (spec §3.6) and the page that renders it, and back out as `builderInput`
/// (§4.3).
///
/// The property this suite protects is that *the transcript on screen is this
/// app's, and nothing the agent writes can leave it*. Every failure mode below
/// was a real hazard rather than a hypothetical: another app's turn splicing
/// itself into the wrong transcript, an event arriving before the page could
/// receive it and being lost, and a line terminator inside model output ending
/// the statement Swift injects.
///
/// It is a unit suite by construction: the bridge is a separate type from the
/// view precisely because a live `WKWebView` cannot be driven inside
/// `swift test` — nothing here loads a page.
@MainActor
@Suite("Editor bridge (spec §3.6 / §4.3)")
struct EditorBridgeTests {

    /// A bridge already focused on an app with a page that has announced itself
    /// — the ordinary steady state.
    private func readyBridge(app: String = "stocks") -> EditorBridge {
        let bridge = EditorBridge()
        bridge.focus(app: app)
        bridge.submit(.ready)
        return bridge
    }

    private func event(
        app: String = "stocks",
        turn: Int = 3,
        event: String,
        delta: String? = nil,
        name: String? = nil,
        detail: String? = nil,
        state: String? = nil,
        ms: Int? = nil,
        ok: Bool? = nil,
        text: String? = nil,
        status: String? = nil,
        message: String? = nil
    ) -> BuilderPayload {
        BuilderPayload(
            app: app,
            turn: turn,
            event: event,
            delta: delta,
            name: name,
            detail: detail,
            state: state,
            ms: ms,
            ok: ok,
            text: text,
            status: status,
            message: message
        )
    }

    /// The page event carried by the last script the bridge emitted, decoded
    /// back out of the injected JS. Asserting on the JSON rather than on an
    /// intermediate value is deliberate: what the page receives is the contract.
    private func lastEvent(_ bridge: EditorBridge) throws -> [String: JSONValue] {
        let script = try #require(bridge.emitted.last)
        let open = try #require(script.firstIndex(of: "("))
        let close = try #require(script.lastIndex(of: ")"))
        let json = String(script[script.index(after: open)..<close])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try #require(value.asObject)
    }

    // MARK: - JS → Swift

    @Test("Typed input becomes a `builderInput` envelope for the presented app")
    func inputBecomesAnEnvelope() throws {
        var sent: [Envelope] = []
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 210, menubarHeight: 34, scale: 2),
            delegate: ProtocolRenderer(),
            send: { sent.append($0) }
        )
        engine.connectionOpened(generation: 1)

        let bridge = readyBridge()
        bridge.onInput = { app, text, cancel in
            engine.sendBuilderInput(app: app, text: text, cancel: cancel)
        }

        // Exactly what the page posts.
        let command = try #require(
            EditorBridge.command(from: ["type": "input", "text": "make the price green when it's up"])
        )
        bridge.submit(command)

        let envelope = try #require(sent.last)
        #expect(envelope.kind == .builderInput)
        // Shell-level frame with the app in the payload (§4.3) — not an
        // app-scoped one. The host routes on the payload.
        #expect(envelope.app == "")
        let payload = try #require(envelope.payload.asObject)
        #expect(payload["app"]?.asString == "stocks")
        #expect(payload["text"]?.asString == "make the price green when it's up")
        #expect(payload["cancel"] == nil)
    }

    @Test("Cancel interrupts the running turn rather than starting one")
    func cancelBecomesAnEnvelope() throws {
        var sent: [Envelope] = []
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 210, menubarHeight: 34, scale: 2),
            delegate: ProtocolRenderer(),
            send: { sent.append($0) }
        )
        engine.connectionOpened(generation: 1)

        let bridge = readyBridge()
        bridge.onInput = { app, text, cancel in
            engine.sendBuilderInput(app: app, text: text, cancel: cancel)
        }
        bridge.submit(try #require(EditorBridge.command(from: ["type": "cancel"])))

        let payload = try #require(sent.last?.payload.asObject)
        #expect(payload["cancel"]?.asBool == true)
        #expect(payload["text"] == nil)
    }

    /// A turn costs an agent invocation. "The user pressed return on an empty
    /// box" must never spend one, and neither must a page bug — so the rejection
    /// is in the parser, before anything stateful sees the message.
    @Test("An empty message never becomes a turn")
    func emptyInputIsNotACommand() {
        #expect(EditorBridge.command(from: ["type": "input", "text": ""]) == nil)
        #expect(EditorBridge.command(from: ["type": "input", "text": "   \n "]) == nil)
        #expect(EditorBridge.command(from: ["type": "input"]) == nil)
        #expect(EditorBridge.command(from: ["type": "input", "text": " hi "]) == .input("hi"))
    }

    @Test("Unrecognised page messages are dropped, not forwarded")
    func unknownMessagesAreDropped() {
        #expect(EditorBridge.command(from: ["type": "resyncRequest"]) == nil)
        #expect(EditorBridge.command(from: ["type": 7]) == nil)
        #expect(EditorBridge.command(from: "cancel") == nil)
        #expect(EditorBridge.command(from: ["type": "ready"]) == .ready)
    }

    @Test("A bridge with no app sends nothing, whatever the page posts")
    func noAppNoEnvelope() {
        let bridge = EditorBridge()
        bridge.submit(.ready)
        var calls = 0
        bridge.onInput = { _, _, _ in calls += 1 }
        bridge.submit(.input("hello"))
        bridge.submit(.cancel)
        #expect(calls == 0)
    }

    // MARK: - Swift → JS

    @Test("A `builder` envelope reaches the page in the documented shape")
    func builderEventReachesThePage() throws {
        let bridge = readyBridge()
        #expect(bridge.deliver(event(event: "text", delta: "Making the price track…")))

        let page = try lastEvent(bridge)
        #expect(page["event"]?.asString == "text")
        #expect(page["delta"]?.asString == "Making the price track…")
        // Both are on every event: the page groups by turn and asserts the app.
        #expect(page["app"]?.asString == "stocks")
        #expect(page["turn"]?.asInt == 3)
    }

    /// The host streams for whichever app has a turn running — not necessarily
    /// the one the panel is showing. Splicing that into this transcript would
    /// attribute another app's edits to this one.
    @Test("Another app's turn is not spliced into this transcript")
    func otherAppsAreDropped() {
        let bridge = readyBridge(app: "stocks")
        #expect(!bridge.deliver(event(app: "music", event: "text", delta: "…")))
        #expect(bridge.emitted.filter { $0.contains("\"text\"") }.isEmpty)
    }

    /// `builder` frames start the instant the host has something to say, which
    /// is routinely before `loadFileURL` has finished parsing the bundle. An
    /// event evaluated into a page with no `__ledgeDeliver` is simply lost.
    @Test("Events that arrive before the page is ready are held, then flushed in order")
    func eventsQueueUntilReady() throws {
        let bridge = EditorBridge()
        bridge.focus(app: "stocks")
        bridge.deliver(event(event: "text", delta: "one"))
        bridge.deliver(event(event: "text", delta: "two"))
        #expect(bridge.emitted.isEmpty)

        bridge.submit(.ready)
        // The thread message first, then the two deltas in arrival order — a
        // transcript replayed out of order is worse than one replayed late.
        #expect(bridge.emitted.count == 3)
        #expect(bridge.emitted[0].contains("\"thread\""))
        #expect(bridge.emitted[1].contains("\"one\""))
        #expect(bridge.emitted[2].contains("\"two\""))
    }

    @Test("A page that never comes up costs a bounded amount of memory")
    func queueIsBounded() {
        let bridge = EditorBridge()
        bridge.focus(app: "stocks")
        for index in 0..<(EditorBridge.pendingLimit + 50) {
            bridge.deliver(event(event: "text", delta: "\(index)"))
        }
        bridge.submit(.ready)
        #expect(bridge.emitted.count == EditorBridge.pendingLimit)
        // The tail is what is kept: the end of a turn is the part worth seeing.
        #expect(bridge.emitted.last?.contains("\"\(EditorBridge.pendingLimit + 49)\"") == true)
    }

    /// One web view serves every app (there is one panel), so switching apps is
    /// a message. The queue goes with it: events held for the app you left are
    /// not this app's transcript.
    @Test("Switching apps starts a thread and abandons the previous app's queue")
    func focusSwitchesThreads() throws {
        let bridge = EditorBridge()
        bridge.focus(app: "stocks")
        bridge.deliver(event(event: "text", delta: "stocks-only"))

        bridge.focus(app: "music")
        bridge.submit(.ready)

        #expect(bridge.emitted.count == 1)
        let page = try lastEvent(bridge)
        #expect(page["event"]?.asString == "thread")
        #expect(page["app"]?.asString == "music")
    }

    @Test("Re-presenting the same app does not wipe the transcript")
    func refocusingIsANoOp() {
        let bridge = readyBridge(app: "stocks")
        bridge.deliver(event(event: "text", delta: "hello"))
        let before = bridge.emitted.count
        bridge.focus(app: "stocks")
        #expect(bridge.emitted.count == before)
    }

    // MARK: - Normalisation

    @Test("Every documented event shape survives the trip")
    func eventShapes() throws {
        let bridge = readyBridge()

        bridge.deliver(event(event: "tool", name: "edit", detail: "app.jsx +2 −1", state: "started"))
        var page = try lastEvent(bridge)
        #expect(page["name"]?.asString == "edit")
        #expect(page["detail"]?.asString == "app.jsx +2 −1")
        #expect(page["state"]?.asString == "started")

        // A tool with no state has already happened — adapters emit one frame
        // for atomic tools and a pair only for ones worth watching run.
        bridge.deliver(event(event: "tool", name: "edit", detail: "app.jsx"))
        page = try lastEvent(bridge)
        #expect(page["state"]?.asString == "completed")

        bridge.deliver(event(event: "status", text: "reloaded · 1.2s"))
        page = try lastEvent(bridge)
        #expect(page["text"]?.asString == "reloaded · 1.2s")

        bridge.deliver(event(event: "done", status: "interrupted"))
        page = try lastEvent(bridge)
        #expect(page["status"]?.asString == "interrupted")

        bridge.deliver(event(event: "error", message: "claude: command not found"))
        page = try lastEvent(bridge)
        #expect(page["message"]?.asString == "claude: command not found")
    }

    /// The spec's first draft wrote status as `{ state, ms }` and completion as
    /// `{ ok }`. The host is being rewritten to the newer shape; a shell that
    /// only understood one of them would blank the editor for whichever half of
    /// the pair it met first.
    @Test("The pre-`{status}` wire shapes still render")
    func legacyShapesNormalise() throws {
        let bridge = readyBridge()

        bridge.deliver(event(event: "status", state: "reloaded", ms: 1200))
        #expect(try lastEvent(bridge)["text"]?.asString == "reloaded · 1.2s")

        bridge.deliver(event(event: "done", ok: true))
        #expect(try lastEvent(bridge)["status"]?.asString == "completed")

        bridge.deliver(event(event: "done", ok: false))
        #expect(try lastEvent(bridge)["status"]?.asString == "failed")
    }

    /// The host and the shell ship separately. An editor that swallowed an event
    /// type it did not know would be silently out of date rather than visibly.
    @Test("An unknown event type reaches the page rather than vanishing")
    func unknownEventsAreForwarded() throws {
        let bridge = readyBridge()
        bridge.deliver(event(event: "thinking", delta: "…"))
        let page = try lastEvent(bridge)
        #expect(page["event"]?.asString == "thinking")
        #expect(page["delta"]?.asString == "…")
    }

    /// The one that is not cosmetic. U+2028 is an ordinary character inside a
    /// JSON string and a *line terminator* in JavaScript source, so an agent
    /// that emitted one would end the injected statement mid-string — and the
    /// editor would stop receiving events for the rest of the session.
    @Test("A line separator in agent output cannot terminate the injected statement")
    func lineSeparatorsAreEscaped() throws {
        let bridge = readyBridge()
        bridge.deliver(event(event: "text", delta: "before\u{2028}after\u{2029}end"))

        let script = try #require(bridge.emitted.last)
        #expect(!script.contains("\u{2028}"))
        #expect(!script.contains("\u{2029}"))
        // Still the same string once the page parses it.
        #expect(try lastEvent(bridge)["delta"]?.asString == "before\u{2028}after\u{2029}end")
    }

    @Test("A page reload starts a fresh thread rather than replaying the old one")
    func pageResetRestartsTheThread() throws {
        let bridge = readyBridge()
        bridge.deliver(event(event: "text", delta: "hello"))

        bridge.pageReset()
        #expect(!bridge.isReady)
        let before = bridge.emitted.count
        bridge.deliver(event(event: "text", delta: "ignored while down"))
        #expect(bridge.emitted.count == before)

        bridge.submit(.ready)
        #expect(bridge.emitted.count == before + 2)
        #expect(bridge.emitted[before].contains("\"thread\""))
    }

    // MARK: - End to end, through the real engine

    @Test("A `builder` frame off the wire reaches the session's editor hook")
    func builderFrameReachesTheSession() throws {
        let session = HostSession()
        var received: [BuilderPayload] = []
        session.onBuilder = { received.append($0) }
        session.openReplay()

        for line in try String(decoding: Fixtures.data("builder-stream.jsonl"), as: UTF8.self)
            .split(separator: "\n") where !line.isEmpty {
            session.inject(try JSONDecoder().decode(Envelope.self, from: Data(line.utf8)))
        }

        #expect(received.count == 4)
        #expect(received.map(\.event) == ["text", "tool", "status", "done"])
        #expect(received.allSatisfy { $0.app == "stocks" })
    }

    /// The toggle's colour comes from §3.2, not from `done`: an agent can end a
    /// turn cleanly and leave an app that no longer runs, and "did that work" is
    /// the worker's answer.
    @Test("An `app` lifecycle frame off the wire reaches the build-status hook")
    func appStateReachesTheSession() {
        let session = HostSession()
        var states: [(String, String)] = []
        session.onAppState = { app, state in states.append((app, state)) }
        session.openReplay()

        for (index, state) in ["reloaded", "crashed"].enumerated() {
            session.inject(Envelope(
                app: "stocks",
                seq: index + 1,
                type: "app",
                payload: .object(["state": .string(state)])
            ))
        }

        #expect(states.map(\.1) == ["reloaded", "crashed"])
        #expect(states.allSatisfy { $0.0 == "stocks" })
    }

    // MARK: - The [+] surface (spec §4.3, §8)

    /// The panel presents this same editor with `app: ""` when there is nothing
    /// behind it — the user is about to describe an app that does not exist. The
    /// host scaffolds one and says what it called it; the bridge has to move
    /// onto it *without* clearing, because the transcript already holds the
    /// prompt that caused it and the reply is streaming into it.
    @Test("`created` moves the [+] surface onto the app the host just made")
    func createdAdoptsTheNewApp() {
        let bridge = EditorBridge()
        bridge.focus(app: "")
        bridge.submit(.ready)
        var announced: [String] = []
        bridge.onCreated = { announced.append($0) }

        #expect(bridge.deliver(event(app: "pomodoro-timer", turn: 0, event: "created")))
        #expect(bridge.app == "pomodoro-timer")
        #expect(announced == ["pomodoro-timer"])

        // And the turn that follows it — which names the new app, not "" — now
        // belongs to this transcript rather than being dropped as someone else's.
        #expect(bridge.deliver(event(app: "pomodoro-timer", turn: 1, event: "text", delta: "on it")))
    }

    /// Adoption is for the [+] surface only. An app's own chat receiving a
    /// `created` for a DIFFERENT app — the user pressed [+], typed, then went
    /// back to stocks while the scaffold was in flight — must not hijack the
    /// transcript the user is looking at.
    @Test("`created` for another app leaves a focused editor where it is")
    func createdDoesNotHijackAFocusedEditor() {
        let bridge = readyBridge()
        var announced: [String] = []
        bridge.onCreated = { announced.append($0) }

        #expect(bridge.deliver(event(app: "pomodoro-timer", turn: 0, event: "created")) == false)
        #expect(bridge.app == "stocks")
        #expect(announced.isEmpty)
    }

    /// What the user typed on the [+] surface still has to reach the host. The
    /// bridge reports the app it is focused on — `""` — and the panel turns that
    /// into the create envelope; a bridge that refused to forward it would make
    /// the surface silently inert, which is what it was before this existed.
    @Test("Input from the [+] surface is forwarded with an empty app")
    func inputFromTheNewAppSurfaceIsForwarded() {
        let bridge = EditorBridge()
        bridge.focus(app: "")
        bridge.submit(.ready)
        var sent: [(String, String?, Bool)] = []
        bridge.onInput = { app, text, cancel in sent.append((app, text, cancel)) }

        bridge.submit(.input("a pomodoro timer"))
        #expect(sent.count == 1)
        #expect(sent[0].0 == "")
        #expect(sent[0].1 == "a pomodoro timer")
    }
}
