import Foundation
import Testing
@testable import LedgeShellCore

@MainActor
@Suite("Protocol engine (spec §§2–4)")
struct ProtocolEngineTests {
    private func makeEngine(
        transducer: TransducerExecutor = ScriptedTransducer()
    ) -> (ProtocolEngine, RecordingDelegate, OutboundRecorder) {
        let delegate = RecordingDelegate()
        let outbound = OutboundRecorder()
        let screen = ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480)
        let engine = ProtocolEngine(
            screen: screen,
            delegate: delegate,
            transducer: transducer,
            send: { outbound.record($0) }
        )
        engine.connectionOpened(generation: 7)
        return (engine, delegate, outbound)
    }

    private func envelope(_ name: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: Fixtures.data(name))
    }

    // MARK: - Control plane

    @Test("Hello exchange replies with gen and screen (§3.6/§4.3)")
    func helloExchange() throws {
        let (engine, _, outbound) = makeEngine()
        engine.receive(try envelope("hello-host.json"))

        let reply = try #require(outbound.last(ofType: "hello"))
        #expect(reply.app == "")
        #expect(reply.seq == 1)
        let payload = try reply.decodePayload([String: JSONValue].self)
        #expect(payload["gen"]?.asInt == 7)
        #expect(payload["screen"]?.asObject?["notchWidth"]?.asDouble == 189)
        #expect(payload["screen"]?.asObject?["maxPanelHeight"]?.asDouble == 480)
        #expect(engine.helloComplete)
    }

    @Test("Catalog ingestion forwards the full snapshot (§3.6)")
    func catalogIngestion() throws {
        let (engine, delegate, _) = makeEngine()
        engine.receive(try envelope("catalog.json"))
        #expect(delegate.catalogs.count == 1)
        #expect(delegate.catalogs.first?.apps.map(\.id) == ["stocks", "music", "chess", "deals"])
        // The app-declared panel size rides along in the snapshot (spec §5 ext).
        #expect(delegate.catalogs.first?.apps.first(where: { $0.id == "chess" })?.panel?.width == 520)
    }

    @Test("Version mismatch is dropped (§2)")
    func versionMismatch() {
        let (engine, delegate, _) = makeEngine()
        let stale = Envelope(v: 2, app: "stocks", seq: 1, type: "catalog", payload: .object(["apps": .array([])]))
        #expect(engine.receive(stale) == false)
        #expect(delegate.catalogs.isEmpty)
    }

    // MARK: - Seq / gen scoping (§2, §1)

    @Test("Stale seq for an app is dropped")
    func staleSeqDropped() throws {
        let (engine, delegate, _) = makeEngine()
        engine.receive(try envelope("commit-mount.json"))    // seq 1
        engine.receive(try envelope("commit-update.json"))   // seq 2
        #expect(delegate.commits.count == 2)

        // Re-deliver seq 2 — stale, dropped.
        #expect(engine.receive(try envelope("commit-update.json")) == false)
        #expect(delegate.commits.count == 2)
    }

    @Test("A new generation resets seq scoping (§1)")
    func generationResetsSeq() throws {
        let (engine, delegate, _) = makeEngine()
        engine.receive(try envelope("commit-mount.json"))    // seq 1 accepted
        engine.receive(try envelope("commit-update.json"))   // seq 2 accepted
        #expect(delegate.commits.count == 2)

        // Reconnect: fresh generation, counters reset, seq 1 accepted again.
        engine.connectionOpened(generation: 8)
        #expect(delegate.discardAllCount == 2)               // one per connectionOpened
        engine.receive(try envelope("commit-mount.json"))    // seq 1 again
        #expect(delegate.commits.count == 3)
    }

    // MARK: - Commit pipeline (§3.1)

    @Test("A valid commit is applied; no resync")
    func validCommitApplied() throws {
        let (engine, delegate, outbound) = makeEngine()
        engine.receive(try envelope("commit-mount.json"))
        #expect(delegate.commits.count == 1)
        #expect(outbound.all(ofType: "resyncRequest").isEmpty)
    }

    @Test("Each invalid commit fixture yields resyncRequest and no tree change")
    func invalidCommitsResync() throws {
        for name in try Fixtures.jsonNames() where name.hasPrefix("invalid-commit-") {
            let (engine, delegate, outbound) = makeEngine()
            engine.receive(try envelope("commit-mount.json"))    // establish a tree
            let commitsBefore = delegate.commits.count

            let invalid = try envelope(name)
            engine.receive(invalid)
            #expect(delegate.commits.count == commitsBefore, "\(name) must not apply")

            // The resync is addressed at the shell level (app "") and names the
            // app in its payload — whichever app the fixture belongs to.
            let resync = try #require(outbound.last(ofType: "resyncRequest"), "\(name)")
            #expect(resync.app == "")
            #expect(
                try resync.decodePayload([String: JSONValue].self)["app"]?.asString == invalid.app,
                "\(name)"
            )
        }
    }

    // MARK: - Lifecycle (§3.2)

    @Test("app:crashed renders the error card")
    func crashShowsErrorCard() {
        let (engine, delegate, _) = makeEngine()
        let crash = Envelope(app: "stocks", seq: 1, type: "app", payload: .object([
            "state": .string("crashed"),
            "error": .object(["message": .string("boom"), "stack": .string("at app.jsx:3")]),
        ]))
        engine.receive(crash)
        #expect(delegate.errorCards.count == 1)
        #expect(delegate.errorCards.first?.message == "boom")
        #expect(delegate.errorCards.first?.stack == "at app.jsx:3")
    }

    @Test("app:stopped discards the app's view state")
    func stopDiscardsApp() {
        let (engine, delegate, _) = makeEngine()
        let stop = Envelope(app: "stocks", seq: 1, type: "app", payload: .object(["state": .string("stopped")]))
        engine.receive(stop)
        #expect(delegate.discardedApps == ["stocks"])
    }

    @Test("Reload lifecycle resets the shadow tree so a remount with colliding ids validates (§3.1/§3.2)")
    func reloadRemountResetsIds() {
        let (engine, delegate, outbound) = makeEngine()

        // A full mount using ids 1 (root stack) and 2 (text child). A respawned
        // worker restarts its ids at 1, so the remount reuses these exact ids.
        func mount(seq: Int) -> Envelope {
            Envelope(app: "stocks", seq: seq, type: "commit", payload: .object([
                "mutations": .array([
                    .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                             "props": .object(["axis": .string("v")])]),
                    .object(["op": .string("create"), "id": .int(2), "kind": .string("text"),
                             "props": .object(["content": .string("hi")])]),
                    .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                    .object(["op": .string("setRoot"), "id": .int(1)]),
                ]),
            ]))
        }

        engine.receive(mount(seq: 1))
        #expect(delegate.commits.count == 1)

        // Hot reload (spec §3.2): the host respawned the worker; its ids reset to 1.
        let reloaded = Envelope(app: "stocks", seq: 2, type: "app",
                                payload: .object(["state": .string("reloaded")]))
        engine.receive(reloaded)
        #expect(delegate.discardedApps.contains("stocks"))
        #expect(delegate.lifecycles.contains { $0.app == "stocks" && $0.state == "reloaded" })

        // The remount reuses ids 1 and 2. Without the reset this is a
        // duplicateCreate → failed validation → resyncRequest; with it, it
        // validates against a fresh shadow tree and applies cleanly.
        engine.receive(mount(seq: 3))
        #expect(delegate.commits.count == 2)
        #expect(outbound.all(ofType: "resyncRequest").isEmpty)
    }

    // MARK: - Draw coalescing (§3.4)

    @Test("Faster-than-refresh draws coalesce to the latest per canvas")
    func drawCoalescing() {
        let (engine, delegate, _) = makeEngine()
        let first = Envelope(app: "game", seq: 1, type: "draw", payload: .object([
            "id": .int(12), "ops": .array([.object(["op": .string("clear")])]),
        ]))
        let second = Envelope(app: "game", seq: 2, type: "draw", payload: .object([
            "id": .int(12), "ops": .array([.object(["op": .string("rect")])]),
        ]))
        engine.receive(first)
        engine.receive(second)
        #expect(delegate.draws.isEmpty)               // nothing until flush
        #expect(engine.hasPendingDraws)

        engine.flushDraws()
        #expect(delegate.draws.count == 1)            // only the latest survives
        #expect(delegate.draws.first?.ops.first?.asObject?["op"]?.asString == "rect")
        #expect(delegate.draws.first?.app == "game")  // scoped by app, not id alone
    }

    @Test("Draws from two apps sharing a canvas id stay apart (§3.1 ids restart at 1)")
    func drawScopedByApp() throws {
        let (engine, delegate, _) = makeEngine()
        func draw(app: String, marker: String) -> Envelope {
            Envelope(app: app, seq: 1, type: "draw", payload: .object([
                "id": .int(12),
                "ops": .array([.object(["op": .string(marker)])]),
            ]))
        }
        engine.receive(draw(app: "tetris", marker: "tetris"))
        engine.receive(draw(app: "aviary", marker: "aviary"))
        engine.flushDraws()
        #expect(delegate.draws.count == 2)
        #expect(Set(delegate.draws.map(\.app)) == ["tetris", "aviary"])
    }

    @Test("The golden draw fixture reaches the canvas verbatim (§3.4)")
    func drawFixtureRoutes() throws {
        let (engine, delegate, _) = makeEngine()
        engine.receive(try envelope("draw-frame.json"))
        engine.flushDraws()
        let frame = try #require(delegate.draws.first)
        #expect(frame.app == "play")
        #expect(frame.id == 12)
        // Unknown ops are forwarded, not filtered: skipping them is the
        // renderer's job, which is what lets §3.4 grow without a version bump.
        #expect(frame.ops.count == 6)
    }

    @Test("A reload drops that app's pending draws but nobody else's")
    func reloadDropsPendingDraws() {
        let (engine, delegate, _) = makeEngine()
        engine.receive(Envelope(app: "tetris", seq: 1, type: "draw", payload: .object([
            "id": .int(3), "ops": .array([.object(["op": .string("clear")])]),
        ])))
        engine.receive(Envelope(app: "aviary", seq: 1, type: "draw", payload: .object([
            "id": .int(3), "ops": .array([.object(["op": .string("clear")])]),
        ])))
        engine.receive(Envelope(app: "tetris", seq: 2, type: "app",
                                payload: .object(["state": .string("reloaded")])))
        engine.flushDraws()
        #expect(delegate.draws.map(\.app) == ["aviary"])
    }

    // MARK: - Chrome + wings (§3.3)

    @Test("Chrome requests reach the delegate, wing payload attached (§3.3)")
    func chromeRequests() throws {
        let (engine, delegate, _) = makeEngine()
        engine.receive(try envelope("chrome-expand.json"))
        engine.receive(try envelope("chrome-wing.json"))
        engine.receive(try envelope("chrome-wing-width.json"))
        engine.receive(try envelope("chrome-wing-clear.json"))

        #expect(delegate.chromeRequests.map(\.request) == ["expand", "wing", "wing", "wing"])
        #expect(delegate.chromeRequests[0].wing == nil)
        #expect(delegate.chromeRequests[1].app == "stocks")
        #expect(delegate.chromeRequests[1].wing?.canvas == WingCanvasSpec(id: 12, w: 64))
        #expect(delegate.chromeRequests[2].wing?.width == 286)
        // `wing: null` is a release, and arrives as a wing request with no spec.
        #expect(delegate.chromeRequests[3].wing == nil)
    }

    @Test("A peek carries its dwell; other requests carry none (§3.3 extension)")
    func peekCarriesDwell() throws {
        let (engine, delegate, _) = makeEngine()
        engine.receive(try envelope("chrome-peek.json"))
        engine.receive(try envelope("chrome-expand.json"))

        #expect(delegate.chromeRequests[0].request == "peek")
        #expect(delegate.chromeRequests[0].ms == 4000)
        // `ms` belongs to `peek` alone — each extra field on the chrome payload
        // is read by the one verb that names it (§3.3).
        #expect(delegate.chromeRequests[0].wing == nil)
        #expect(delegate.chromeRequests[1].ms == nil)
    }

    @Test("A wing carrying nothing at all is a release, not an empty wing")
    func emptyWingIsRelease() {
        let (engine, delegate, _) = makeEngine()
        engine.receive(Envelope(app: "stocks", seq: 1, type: "chrome", payload: .object([
            "request": .string("wing"),
            "wing": .object([:]),
        ])))
        #expect(delegate.chromeRequests.count == 1)
        #expect(delegate.chromeRequests[0].wing == nil)
    }

    // MARK: - Native transducer routing (§3.5)

    @Test("Native install + tick routes draw to the canvas and events to the worker")
    func nativeInputRouting() {
        let transducer = ScriptedTransducer { _, _, input in
            if case .tick = input {
                return TransducerOutput(
                    state: .object(["score": .int(1)]),
                    draw: [.object(["op": .string("rect")])],
                    events: [.init(name: "gameOver", data: .object(["score": .int(1200)]))]
                )
            }
            return TransducerOutput(state: .object(["score": .int(0)]))
        }
        let (engine, delegate, outbound) = makeEngine(transducer: transducer)

        let install = Envelope(app: "game", seq: 1, type: "native", payload: .object([
            "action": .string("install"),
            "canvas": .int(12),
            "hash": .string("sha256:abc"),
            "code": .string("function step(){}"),
            "initial": .object(["score": .int(0)]),
        ]))
        engine.receive(install)
        #expect(engine.native.isInstalled(canvas: 12))

        engine.feedTransducer(app: "game", canvas: 12, input: .tick(dt: 16.6, t: 1000))
        #expect(delegate.draws.contains { $0.id == 12 })

        let event = outbound.all(ofType: "event").first { env in
            (try? env.decodePayload([String: JSONValue].self))?["name"]?.asString == "gameOver"
        }
        #expect(event != nil)

        // Checkpoint mirrors current state back to the host.
        engine.checkpoint(app: "game", canvas: 12)
        let checkpoint = outbound.all(ofType: "native").first
            .flatMap { try? $0.decodePayload([String: JSONValue].self) }
        #expect(checkpoint?["action"]?.asString == "checkpoint")
        #expect(checkpoint?["state"]?.asObject?["score"]?.asInt == 1)
    }

    // MARK: - Outbound (§4)

    @Test("Outbound events and selection carry correct scope and increment seq")
    func outboundScoping() throws {
        let (engine, _, outbound) = makeEngine()
        engine.emitEvent(app: "stocks", id: 5, name: "click")
        engine.sendSelection(app: "music")
        engine.sendSelection(app: nil, surface: "settings")

        let event = try #require(outbound.all(ofType: "event").first)
        #expect(event.app == "stocks")
        #expect(try event.decodePayload([String: JSONValue].self)["id"]?.asInt == 5)

        let selections = outbound.all(ofType: "selection")
        #expect(selections.count == 2)
        #expect(selections[0].app == "")
        #expect(try selections[0].decodePayload([String: JSONValue].self)["app"]?.asString == "music")
        let second = try selections[1].decodePayload([String: JSONValue].self)
        #expect(second["app"] == .null)
        #expect(second["surface"]?.asString == "settings")

        // Shell-level ("") outbound seq increments across selection sends.
        #expect(selections[0].seq == 1)
        #expect(selections[1].seq == 2)
    }

    @Test("Builder input and cancel serialize correctly (§4.3)")
    func builderInput() throws {
        let (engine, _, outbound) = makeEngine()
        engine.sendBuilderInput(app: "stocks", text: "make it green")
        engine.sendBuilderInput(app: "stocks", cancel: true)
        let sends = outbound.all(ofType: "builderInput")
        #expect(try sends[0].decodePayload([String: JSONValue].self)["text"]?.asString == "make it green")
        #expect(try sends[1].decodePayload([String: JSONValue].self)["cancel"]?.asBool == true)
    }
}
