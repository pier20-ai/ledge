import Foundation
import Testing
@testable import LedgeShellCore

/// `ctx.platform.observe` (spec §6 extension): push invalidation via distributed
/// notifications, and the id-0 `platform` event it produces.
///
/// The center under test is a plain in-process `NotificationCenter` — which is
/// the base class `DistributedNotificationCenter` inherits from, so the code
/// path is the shipping one. Posting into the real system center would make
/// these tests depend on `distnoted` being reachable and prompt from inside a
/// test runner, which is a property of the machine rather than of the code.
@MainActor
@Suite("Platform observers (spec §6 extension)")
struct PlatformObserverTests {
    private let kind = PlatformPayload.distributedNotification

    private func makeObserver() -> (PlatformObserver, NotificationCenter) {
        let center = NotificationCenter()
        return (PlatformObserver(center: center), center)
    }

    @Test("An observed notification reaches the app that asked, reduced")
    func delivers() {
        let (observer, center) = makeObserver()
        var events: [(app: String, kind: String, name: String, info: [String: JSONValue])] = []
        observer.onEvent = { app, kind, name, info in
            events.append((app, kind, name, info))
        }
        #expect(observer.observe(app: "music", kind: kind, name: "com.apple.Music.playerInfo").isSuccess)

        center.post(
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            userInfo: [
                "Player State": "Playing",
                "Total Time": 140_000,
                "Loved": false,
                // Not a scalar and not a string key: both are dropped rather
                // than stringified — the wire is not a place for a blob.
                "Artwork": Data(count: 4_096),
                42: "not a string key",
            ]
        )

        #expect(events.count == 1)
        let event = try? #require(events.first)
        #expect(event?.app == "music")
        #expect(event?.name == "com.apple.Music.playerInfo")
        #expect(event?.info["Player State"] == .string("Playing"))
        #expect(event?.info["Total Time"]?.asDouble == 140_000)
        #expect(event?.info["Loved"] == .bool(false))
        #expect(event?.info["Artwork"] == nil)
        #expect(event?.info.count == 3)
    }

    @Test("Duplicate observes are idempotent, so one notification fires once")
    func idempotent() {
        let (observer, center) = makeObserver()
        var fired = 0
        observer.onEvent = { _, _, _, _ in fired += 1 }
        // The obvious way to write an app is to re-declare its observers on
        // every monitor pass. If that stacked handlers, a music app would fire
        // twenty times per track change after a minute of running.
        for _ in 0..<5 {
            #expect(observer.observe(app: "music", kind: kind, name: "n").isSuccess)
        }
        #expect(observer.registrations.count == 1)
        center.post(name: Notification.Name("n"), object: nil)
        #expect(fired == 1)
    }

    @Test("Two apps may watch the same notification without sharing a fate")
    func perApp() {
        let (observer, center) = makeObserver()
        var apps: [String] = []
        observer.onEvent = { app, _, _, _ in apps.append(app) }
        observer.observe(app: "music", kind: kind, name: "n")
        observer.observe(app: "widget", kind: kind, name: "n")
        center.post(name: Notification.Name("n"), object: nil)
        #expect(apps.sorted() == ["music", "widget"])

        apps.removeAll()
        observer.release(app: "music")
        center.post(name: Notification.Name("n"), object: nil)
        #expect(apps == ["widget"], "releasing one app took the other's registration with it")
    }

    @Test("Unobserving stops delivery; unobserving nothing is still a success")
    func unobserve() {
        let (observer, center) = makeObserver()
        var fired = 0
        observer.onEvent = { _, _, _, _ in fired += 1 }
        observer.observe(app: "music", kind: kind, name: "n")
        #expect(observer.unobserve(app: "music", kind: kind, name: "n").isSuccess)
        center.post(name: Notification.Name("n"), object: nil)
        #expect(fired == 0)
        // The app asked for a *state* ("do not watch this"), and it holds.
        #expect(observer.unobserve(app: "music", kind: kind, name: "n").isSuccess)
    }

    @Test("An unknown kind is refused rather than silently registering nothing")
    func unknownKind() {
        let (observer, _) = makeObserver()
        guard case .failure = observer.observe(app: "music", kind: "carrierPigeon", name: "n") else {
            Issue.record("an unknown source must not answer ok")
            return
        }
        #expect(observer.registrations.isEmpty)
        // An empty name is the same class of mistake.
        guard case .failure = observer.observe(app: "music", kind: kind, name: "") else {
            Issue.record("an empty notification name must not answer ok")
            return
        }
    }

    @Test("releaseAll drops everything — a new generation owns none of it")
    func releaseAll() {
        let (observer, center) = makeObserver()
        var fired = 0
        observer.onEvent = { _, _, _, _ in fired += 1 }
        observer.observe(app: "music", kind: kind, name: "a")
        observer.observe(app: "widget", kind: kind, name: "b")
        observer.releaseAll()
        #expect(observer.registrations.isEmpty)
        center.post(name: Notification.Name("a"), object: nil)
        center.post(name: Notification.Name("b"), object: nil)
        #expect(fired == 0)
    }
}

/// The engine's half of the same feature: the `platform` envelope in, the
/// `platformResult` and the id-0 `platform` event out.
@MainActor
@Suite("Platform envelopes (spec §6 extension)")
struct PlatformEnvelopeTests {
    /// A capability host built the way the shell builds one, but over an
    /// in-process center — so this exercises the real `PlatformObserver`, the
    /// real engine, and a real notification, end to end.
    private final class ObservingCapabilities: CapabilityDelegate {
        let observers: PlatformObserver
        /// Held open until the test settles it — what a TCC prompt looks like.
        var pendingCalls: [PlatformCompletion] = []
        var calls: [PlatformCall] = []
        var callResult: Result<JSONValue?, CapabilityError>?

        init(center: NotificationCenter) {
            observers = PlatformObserver(center: center)
        }

        func runPlatformCall(_ call: PlatformCall, app: String, completion: @escaping PlatformCompletion) {
            calls.append(call)
            if let callResult { completion(callResult) } else { pendingCalls.append(completion) }
        }

        func settleCall(_ result: Result<JSONValue?, CapabilityError>) {
            let waiting = pendingCalls
            pendingCalls.removeAll()
            for completion in waiting { completion(result) }
        }

        func runApple(_ invocation: AppleInvocation, app: String, completion: @escaping AppleCompletion) {}
        func postNotification(_ notification: NotifyPayload, app: String) {}
        func captureScreen(interactive: Bool, app: String, completion: @escaping CaptureCompletion) {}
        func observePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError> {
            observers.observe(app: app, kind: kind, name: name)
        }
        func unobservePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError> {
            observers.unobserve(app: app, kind: kind, name: name)
        }
        func releasePlatformObservers(app: String) { observers.release(app: app) }
        func releaseAllPlatformObservers() { observers.releaseAll() }
    }

    private func makeEngine() -> (ProtocolEngine, RecordingDelegate, Outbound, ObservingCapabilities, NotificationCenter) {
        let delegate = RecordingDelegate()
        let outbound = Outbound()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 210, menubarHeight: 34, scale: 2),
            delegate: delegate,
            send: { outbound.sent.append($0) }
        )
        let center = NotificationCenter()
        let capabilities = ObservingCapabilities(center: center)
        // What `HostSession` wires in the real shell: a fired observer becomes
        // the id-0 app event.
        capabilities.observers.onEvent = { app, kind, name, userInfo in
            engine.sendPlatformEvent(app: app, kind: kind, name: name, userInfo: userInfo)
        }
        engine.capabilities = capabilities
        engine.connectionOpened(generation: 1)
        return (engine, delegate, outbound, capabilities, center)
    }

    final class Outbound {
        var sent: [Envelope] = []
        func all(ofType type: String) -> [Envelope] { sent.filter { $0.type == type } }
        func last(ofType type: String) -> Envelope? { all(ofType: type).last }
    }

    @Test("observe is acknowledged, and the notification comes back as an id-0 event")
    func observeRoundTrip() throws {
        // `capabilities` is bound, not discarded: the engine holds it *weakly*
        // (rendering and driving macOS are separate jobs with separate owners),
        // so a `_` here would deallocate the host and the engine would honestly
        // answer "this shell has no platform capability".
        let (engine, _, outbound, capabilities, center) = makeEngine()
        engine.receive(try Fixtures.envelope("platform-observe.json"))

        let ack = try #require(outbound.last(ofType: "platformResult"))
        #expect(ack.app == "music")
        #expect(try ack.decodePayload(PlatformResultPayload.self) == .success(id: 5))
        #expect(capabilities.observers.registrations.count == 1)

        center.post(
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            userInfo: ["Player State": "Playing"]
        )

        let event = try #require(outbound.last(ofType: "event"))
        #expect(event.app == "music")
        let payload = try event.decodePayload([String: JSONValue].self)
        // id 0 is the app-level convention (§4.1) — the same one `drop` and
        // `notification` use, so this costs the protocol no new event type.
        #expect(payload["id"]?.asInt == 0)
        #expect(payload["name"]?.asString == "platform")
        let data = try #require(payload["data"]?.asObject)
        #expect(data["kind"]?.asString == PlatformPayload.distributedNotification)
        #expect(data["name"]?.asString == "com.apple.Music.playerInfo")
        #expect(data["userInfo"]?.asObject?["Player State"]?.asString == "Playing")
    }

    @Test("unobserve is acknowledged and really stops delivery")
    func unobserveRoundTrip() throws {
        let (engine, _, outbound, capabilities, center) = makeEngine()
        defer { _ = capabilities }              // the engine's ref is weak
        engine.receive(Envelope(app: "music", seq: 1, type: "platform", payload: .object([
            "id": .int(1), "call": .string("observe"),
            "kind": .string(PlatformPayload.distributedNotification),
            "name": .string("com.spotify.client.PlaybackStateChanged"),
        ])))
        engine.receive(try Fixtures.envelope("platform-unobserve.json"))
        #expect(try outbound.last(ofType: "platformResult")?
            .decodePayload(PlatformResultPayload.self) == .success(id: 6))

        let before = outbound.all(ofType: "event").count
        center.post(name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        #expect(outbound.all(ofType: "event").count == before)
    }

    @Test("A malformed or unsupported request is answered, never dropped")
    func malformedIsAnswered() throws {
        let (engine, _, outbound, capabilities, _) = makeEngine()
        engine.receive(Envelope(app: "music", seq: 1, type: "platform", payload: .object([
            "id": .int(3), "call": .string("observe"),
            "kind": .string("carrierPigeon"), "name": .string("n"),
        ])))
        // The app is awaiting a Promise: a silent drop only moves the failure to
        // a timeout, ten seconds later, with a worse message.
        let result = try #require(outbound.last(ofType: "platformResult"))
            .decodePayload(PlatformResultPayload.self)
        #expect(result.id == 3)
        #expect(result.ok == false)
        #expect(result.error?.isEmpty == false)
        #expect(capabilities.observers.registrations.isEmpty)
    }

    @Test("A shell with no capability host answers rather than hanging")
    func noCapabilityHost() throws {
        let delegate = RecordingDelegate()
        let outbound = Outbound()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 210, menubarHeight: 34, scale: 2),
            delegate: delegate,
            send: { outbound.sent.append($0) }
        )
        engine.receive(try Fixtures.envelope("platform-observe.json"))
        let result = try #require(outbound.last(ofType: "platformResult"))
            .decodePayload(PlatformResultPayload.self)
        #expect(result.ok == false)
    }

    @Test("A value-producing call settles on a later turn and carries `data`")
    func callRoundTrip() throws {
        let (engine, _, outbound, capabilities, _) = makeEngine()
        engine.receive(try Fixtures.envelope("platform-workspace.json"))

        // Not answered yet: this family is the `apple` shape, not the registry
        // shape — the answer may need a prompt, a query or a radio.
        #expect(outbound.all(ofType: "platformResult").isEmpty)
        #expect(capabilities.calls == [.workspace])

        capabilities.settleCall(.success(.object([
            "idleSeconds": .double(4.5),
            "frontmost": .object(["bundleId": .string("com.apple.dt.Xcode"),
                                  "localizedName": .string("Xcode")]),
        ])))
        let result = try #require(outbound.last(ofType: "platformResult"))
            .decodePayload(PlatformResultPayload.self)
        #expect(result.id == 22)
        #expect(result.ok)
        #expect(result.data?.asObject?["idleSeconds"]?.asDouble == 4.5)
        #expect(result.error == nil)
    }

    @Test("A refused call comes back as ok:false with the shell's sentence")
    func callFailure() throws {
        let (engine, _, outbound, capabilities, _) = makeEngine()
        capabilities.callResult = .failure(CapabilityError("calendar access was refused"))
        engine.receive(try Fixtures.envelope("platform-calendar.json"))

        let result = try #require(outbound.last(ofType: "platformResult"))
            .decodePayload(PlatformResultPayload.self)
        #expect(result.ok == false)
        #expect(result.error == "calendar access was refused")
        #expect(result.data == nil)
    }

    @Test("A call with no answer settles with no `data` key at all")
    func callWithoutData() throws {
        let (engine, _, outbound, capabilities, _) = makeEngine()
        capabilities.callResult = .success(nil)
        engine.receive(try Fixtures.envelope("platform-speak.json"))

        #expect(capabilities.calls == [.speak(text: "Standup in five minutes.", voice: nil, rate: 0.5)])
        // Absent rather than null, the same rule `appleResult` follows — so the
        // golden fixture can assert an exact object.
        let envelope = try #require(outbound.last(ofType: "platformResult"))
        #expect(try envelope.decodePayload([String: JSONValue].self)["data"] == nil)
        #expect(try envelope.decodePayload(PlatformResultPayload.self) == .success(id: 27))
    }

    @Test("Each new observe kind is registered under its own (app, kind, name)")
    func newKindsRegister() throws {
        // The registry here is the historical distributedNotification-only one,
        // so these must be *refused* — which is the property that matters: a
        // shell that cannot watch a kind says so rather than answering ok and
        // never firing.
        let (engine, _, outbound, capabilities, _) = makeEngine()
        for file in ["platform-observe-workspace.json", "platform-observe-power.json"] {
            engine.receive(try Fixtures.envelope(file))
            let result = try #require(outbound.last(ofType: "platformResult"))
                .decodePayload(PlatformResultPayload.self)
            #expect(result.ok == false, "\(file)")
            #expect(result.error?.contains("unsupported observe kind") == true, "\(file)")
        }
        #expect(capabilities.observers.registrations.isEmpty)
    }

    @Test("Observers die with their worker, and with the connection generation")
    func lifecycleReleasesObservers() throws {
        let (engine, _, outbound, capabilities, center) = makeEngine()
        engine.receive(try Fixtures.envelope("platform-observe.json"))
        #expect(capabilities.observers.registrations.count == 1)

        // A reload replaces the worker that asked; its observers go with it, at
        // the same point the host releases its wing (§3.3 extension, §6 rule 3).
        engine.receive(Envelope(app: "music", seq: 20, type: "app", payload: .object([
            "state": .string("reloaded"),
        ])))
        #expect(capabilities.observers.registrations.isEmpty)
        let before = outbound.all(ofType: "event").count
        center.post(name: Notification.Name("com.apple.Music.playerInfo"), object: nil)
        #expect(outbound.all(ofType: "event").count == before)

        // And a new generation owns none of the old one's subscriptions (§1).
        engine.receive(Envelope(app: "music", seq: 30, type: "platform", payload: .object([
            "id": .int(9), "call": .string("observe"),
            "kind": .string(PlatformPayload.distributedNotification),
            "name": .string("com.apple.Music.playerInfo"),
        ])))
        #expect(capabilities.observers.registrations.count == 1)
        engine.connectionOpened(generation: 2)
        #expect(capabilities.observers.registrations.isEmpty)
    }
}

extension Fixtures {
    /// One golden fixture decoded as an envelope, ready to inject.
    static func envelope(_ name: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data(name))
    }
}
