import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The shell's own capability host, wired the way `HostSession` wires it. The
/// engine-level routing is covered in `PlatformEnvelopeTests`; what this adds is
/// that the class the shipping shell actually instantiates registers, delivers
/// and tears down — the bit a test double cannot vouch for.
@MainActor
@Suite("CapabilityHost platform observers (spec §6 extension)")
struct PlatformHostTests {
    private let kind = PlatformPayload.distributedNotification

    @Test("Registration, delivery and per-app teardown through the real host")
    func hostObserves() {
        let center = NotificationCenter()
        let host = CapabilityHost(notificationCenter: center)
        var events: [(app: String, name: String, info: [String: JSONValue])] = []
        host.onPlatformEvent = { app, _, name, info in events.append((app, name, info)) }

        guard case .success = host.observePlatform(
            kind: kind,
            name: "com.apple.Music.playerInfo",
            app: "music"
        ) else {
            Issue.record("registration failed")
            return
        }
        #expect(host.platformRegistrations.count == 1)

        center.post(
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            userInfo: ["Player State": "Paused"]
        )
        #expect(events.count == 1)
        #expect(events.first?.app == "music")
        #expect(events.first?.info["Player State"] == .string("Paused"))

        // The lifecycle point wings are released at: the worker that asked is
        // gone, so what it asked for goes with it.
        host.releasePlatformObservers(app: "music")
        #expect(host.platformRegistrations.isEmpty)
        center.post(name: Notification.Name("com.apple.Music.playerInfo"), object: nil)
        #expect(events.count == 1)
    }

    @Test("An unsupported source is refused by the host, not registered quietly")
    func hostRefusesUnknownKind() {
        let host = CapabilityHost(notificationCenter: NotificationCenter())
        guard case .failure = host.observePlatform(kind: "carrierPigeon", name: "n", app: "music") else {
            Issue.record("an unknown source must not answer ok")
            return
        }
        #expect(host.platformRegistrations.isEmpty)
    }

    @Test("The shipping factory answers for every ratified kind and nothing else")
    func factoryCoversTheVocabulary() {
        // Constructing a source must be free — the registry builds one
        // speculatively just to decide whether a kind is real, and may throw it
        // away unstarted. Nothing below acquires a timer, a monitor or a
        // listener; only `start()` does.
        let factory = SystemPlatformSources.factory(
            distributed: NotificationCenter(),
            workspace: NotificationCenter()
        )
        for kind in PlatformObserveKind.all {
            #expect(factory(kind) != nil, "no source for '\(kind)'")
        }
        #expect(factory("carrierPigeon") == nil)
    }

    @Test("A new observe kind registers, delivers and tears its resource down")
    func hostObservesNewKinds() {
        // The host wired with fake sources — the seam that lets a headless test
        // exercise the *shipping* CapabilityHost with no battery and no network.
        let power = FakePowerReader()
        let path = FakePathMonitor()
        let host = CapabilityHost(sources: { kind in
            switch kind {
            case PlatformObserveKind.power: PowerSource(reader: power)
            case PlatformObserveKind.reachability: ReachabilitySource(monitor: path)
            default: nil
            }
        })
        var events: [(app: String, kind: String, payload: [String: JSONValue])] = []
        host.onPlatformEvent = { app, kind, _, payload in events.append((app, kind, payload)) }

        #expect(host.observePlatform(kind: PlatformObserveKind.power, name: "changed", app: "battery").isSuccess)
        // Immediate fire: an app never has to make a separate read call for the
        // state it just subscribed to.
        #expect(events.count == 1)
        #expect(events[0].payload["level"]?.asDouble == 0.62)
        #expect(host.platformSourceKinds == [PlatformObserveKind.power])

        #expect(host.observePlatform(
            kind: PlatformObserveKind.reachability, name: "changed", app: "stocks"
        ).isSuccess)
        #expect(host.platformSourceKinds.count == 2)

        // A name outside the vocabulary is refused rather than registering
        // something that can never fire.
        #expect(host.observePlatform(kind: PlatformObserveKind.power, name: "batteryLow", app: "battery").isFailure)

        // The §3.2 lifecycle point: both directions of the refcount asserted.
        host.releasePlatformObservers(app: "battery")
        #expect(power.stopped == 1)
        #expect(host.platformSourceKinds == [PlatformObserveKind.reachability])
        host.releaseAllPlatformObservers()
        #expect(path.stopped == 1)
        #expect(host.platformSourceKinds.isEmpty)
        #expect(host.platformRegistrations.isEmpty)
    }

    @Test("A platform call is routed to the host's executor and answered")
    func hostRunsCalls() {
        let audio = StubAudioDevice()
        let host = CapabilityHost(
            sources: { _ in nil },
            platform: PlatformExecutor(audio: audio)
        )
        let results = PlatformCallResults()
        host.runPlatformCall(.audio, app: "music", completion: results.completion)
        #expect(results.last?.asObject?["deviceName"]?.asString == "Speakers")

        host.runPlatformCall(.setVolume(2), app: "music", completion: results.completion)
        #expect(results.last?.asObject?["volume"]?.asDouble == 1)
    }
}

/// Where a `runPlatformCall` completion lands (a `@Sendable` completion cannot
/// capture a mutable local).
@MainActor
final class PlatformCallResults {
    private(set) var settled: [Result<JSONValue?, CapabilityError>] = []
    var completion: PlatformCompletion { { [weak self] in self?.settled.append($0) } }
    var last: JSONValue? {
        guard case let .success(value) = settled.last else { return nil }
        return value
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isFailure: Bool { !isSuccess }
}
