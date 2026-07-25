import Foundation
import Testing
@testable import LedgeShellCore

/// A stand-in for one shared OS resource. Every shipping source is one of these
/// wrapped around something that needs a battery, a network, a sound card or a
/// pasteboard; this is the same object with none of that, so the *registry*
/// contract — refcounted start/stop, name vocabulary, immediate fire, per-app
/// teardown — can be asserted exactly.
@MainActor
final class FakeSignalSource: PlatformSignalSource {
    let supportedNames: Set<String>?
    /// What `snapshot(for:)` answers — nil for an edge-shaped source.
    var snapshotPayload: [String: JSONValue]?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var addedNames: [String] = []
    private(set) var removedNames: [String] = []
    var isRunning: Bool { startCount > stopCount }

    private var emit: (@MainActor (String, [String: JSONValue]) -> Void)?

    init(supportedNames: Set<String>? = nil, snapshotPayload: [String: JSONValue]? = nil) {
        self.supportedNames = supportedNames
        self.snapshotPayload = snapshotPayload
    }

    func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        startCount += 1
        self.emit = emit
    }

    func stop() {
        stopCount += 1
        emit = nil
    }

    func addName(_ name: String) { addedNames.append(name) }
    func removeName(_ name: String) { removedNames.append(name) }
    func snapshot(for name: String) -> [String: JSONValue]? { snapshotPayload }

    /// Fire, the way the OS would.
    func fire(_ name: String, _ payload: [String: JSONValue] = [:]) {
        emit?(name, payload)
    }
}

/// The new observe kinds at the level they all share: the registry.
///
/// The per-kind translation (an `NSWorkspace` name becoming `screenLocked`, a
/// pasteboard change count becoming an event) is tested where those sources
/// live, in `LedgeShellTests`. What is tested here is the part every kind
/// depends on and no kind implements for itself.
@MainActor
@Suite("Platform observe kinds (spec §6 extension)")
struct PlatformKindsTests {
    /// A registry over fakes, one per kind, kept addressable by the test.
    @MainActor
    private final class Bench {
        var sources: [String: FakeSignalSource] = [:]
        var events: [(app: String, kind: String, name: String, payload: [String: JSONValue])] = []
    }

    private func makeRegistry(
        _ kinds: [String: FakeSignalSource]
    ) -> (PlatformObserver, Bench) {
        let bench = Bench()
        bench.sources = kinds
        let observer = PlatformObserver(sources: { kind in bench.sources[kind] })
        observer.onEvent = { app, kind, name, payload in
            bench.events.append((app, kind, name, payload))
        }
        return (observer, bench)
    }

    private func snapshotSource(_ payload: [String: JSONValue]? = nil) -> FakeSignalSource {
        FakeSignalSource(supportedNames: PlatformSignalName.snapshot, snapshotPayload: payload)
    }

    @Test("Every ratified kind has a source in the shipping factory's vocabulary")
    func kindVocabulary() {
        #expect(PlatformObserveKind.all == [
            "distributedNotification", "workspace", "pasteboard", "power", "reachability", "audio",
        ])
        // The state-shaped kinds share one name, and the payload says what
        // changed — an app that cares about volume nearly always also cares
        // about the headphones being unplugged.
        #expect(PlatformSignalName.snapshot == ["changed"])
        #expect(PlatformSignalName.workspace.contains("screenLocked"))
        #expect(PlatformSignalName.workspace.count == 7)
    }

    @Test("The shared source starts at the first observer and stops at the last")
    func refcountedLifecycle() {
        let power = snapshotSource(["level": .double(0.5)])
        let (observer, _) = makeRegistry([PlatformObserveKind.power: power])

        #expect(power.isRunning == false, "a source must acquire nothing before anyone is watching")
        observer.observe(app: "battery", kind: PlatformObserveKind.power, name: "changed")
        #expect(power.startCount == 1)
        #expect(observer.liveSourceKinds == [PlatformObserveKind.power])

        // A second app is a second registration over the SAME resource: six apps
        // watching the battery must not be six IOKit run-loop sources.
        observer.observe(app: "menubar", kind: PlatformObserveKind.power, name: "changed")
        #expect(power.startCount == 1)
        #expect(observer.registrations.count == 2)

        observer.unobserve(app: "battery", kind: PlatformObserveKind.power, name: "changed")
        #expect(power.isRunning, "the last watcher had not left yet")
        observer.unobserve(app: "menubar", kind: PlatformObserveKind.power, name: "changed")
        #expect(power.stopCount == 1)
        #expect(observer.liveSourceKinds.isEmpty, "a poll timer left running is a timer firing for nobody")
    }

    @Test("A per-app release tears the shared resource down too, when it was the last")
    func lifecycleReleaseStopsTheSource() {
        let pasteboard = snapshotSource()
        let (observer, _) = makeRegistry([PlatformObserveKind.pasteboard: pasteboard])
        observer.observe(app: "clips", kind: PlatformObserveKind.pasteboard, name: "changed")
        #expect(pasteboard.isRunning)

        // The §3.2 lifecycle point: the worker that asked is gone.
        observer.release(app: "clips")
        #expect(observer.registrations.isEmpty)
        #expect(pasteboard.stopCount == 1)

        // …and so is a new connection generation (§1).
        observer.observe(app: "clips", kind: PlatformObserveKind.pasteboard, name: "changed")
        #expect(pasteboard.startCount == 2)
        observer.releaseAll()
        #expect(pasteboard.stopCount == 2)
        #expect(observer.liveSourceKinds.isEmpty)
    }

    @Test("Registering a state kind fires the current state immediately")
    func immediateFire() {
        let power = snapshotSource([
            "level": .double(0.62), "charging": .bool(false),
            "onAC": .bool(false), "lowPowerMode": .bool(true),
        ])
        let reachability = snapshotSource(["satisfied": .bool(true), "interface": .string("wifi")])
        let edge = FakeSignalSource(supportedNames: PlatformSignalName.workspace)
        let (observer, bench) = makeRegistry([
            PlatformObserveKind.power: power,
            PlatformObserveKind.reachability: reachability,
            PlatformObserveKind.workspace: edge,
        ])

        observer.observe(app: "battery", kind: PlatformObserveKind.power, name: "changed")
        observer.observe(app: "stocks", kind: PlatformObserveKind.reachability, name: "changed")
        // An *edge* — "the screen locked" — has no current value to deliver.
        observer.observe(app: "focus", kind: PlatformObserveKind.workspace, name: "screenLocked")

        #expect(bench.events.count == 2)
        #expect(bench.events.first?.payload["level"]?.asDouble == 0.62)
        #expect(bench.events.last?.payload["interface"]?.asString == "wifi")
        // Without this an app would show a blank battery until the machine
        // happened to cross a percent, which on AC power is never.
        #expect(bench.events.allSatisfy { $0.name == "changed" })
    }

    @Test("A re-declared observer neither duplicates nor re-fires")
    func idempotent() {
        let power = snapshotSource(["level": .double(1)])
        let (observer, bench) = makeRegistry([PlatformObserveKind.power: power])
        // The obvious way to write an app is to re-declare on every monitor pass.
        for _ in 0..<5 {
            #expect(observer.observe(app: "battery", kind: PlatformObserveKind.power, name: "changed").isSuccess)
        }
        #expect(observer.registrations.count == 1)
        #expect(power.startCount == 1)
        #expect(power.addedNames == ["changed"])
        // One immediate fire, not five: a monitor at 1 Hz would otherwise push a
        // battery event every second forever.
        #expect(bench.events.count == 1)

        power.fire("changed", ["level": .double(0.9)])
        #expect(bench.events.count == 2)
    }

    @Test("A name outside the kind's vocabulary is refused, with the list")
    func nameVocabularyIsEnforced() {
        let workspace = FakeSignalSource(supportedNames: PlatformSignalName.workspace)
        let (observer, _) = makeRegistry([PlatformObserveKind.workspace: workspace])

        #expect(observer.observe(app: "focus", kind: PlatformObserveKind.workspace, name: "screenLocked").isSuccess)
        // The raw notification name is exactly the mistake the vocabulary exists
        // to catch: it is Apple's to rename, and it is posted on a *different*
        // center from the rest of this kind.
        guard case let .failure(error) = observer.observe(
            app: "focus",
            kind: PlatformObserveKind.workspace,
            name: "com.apple.screenIsLocked"
        ) else {
            Issue.record("a raw notification name must not register under 'workspace'")
            return
        }
        #expect(error.message.contains("screenLocked"), "the refusal should name the ones that exist")
        #expect(observer.registrations.count == 1)
        #expect(workspace.startCount == 1, "a refused name must not have started anything new")
    }

    @Test("An unknown kind is refused rather than silently registering nothing")
    func unknownKind() {
        let (observer, _) = makeRegistry([:])
        guard case .failure = observer.observe(app: "music", kind: "carrierPigeon", name: "n") else {
            Issue.record("an unknown source must not answer ok")
            return
        }
        // Unobserving an unknown kind is a typo too, not a satisfied state.
        guard case .failure = observer.unobserve(app: "music", kind: "carrierPigeon", name: "n") else {
            Issue.record("an unknown source must not answer ok on unobserve either")
            return
        }
        #expect(observer.registrations.isEmpty)
        #expect(observer.liveSourceKinds.isEmpty)
    }

    @Test("Delivery is filtered by name as well as by kind")
    func deliveryIsFilteredByName() {
        let workspace = FakeSignalSource(supportedNames: PlatformSignalName.workspace)
        let (observer, bench) = makeRegistry([PlatformObserveKind.workspace: workspace])
        observer.observe(app: "focus", kind: PlatformObserveKind.workspace, name: "screenLocked")
        observer.observe(app: "clock", kind: PlatformObserveKind.workspace, name: "didWake")

        // One source, all seven names — the registry is what makes each app see
        // only the one it asked for.
        workspace.fire("screenLocked")
        workspace.fire("didWake")
        workspace.fire("screensDidSleep")

        #expect(bench.events.map(\.app) == ["focus", "clock"])
        #expect(bench.events.map(\.name) == ["screenLocked", "didWake"])
    }

    @Test("Two apps on one name share the source and unregister independently")
    func perAppNameRefcount() {
        let pasteboard = snapshotSource()
        let (observer, bench) = makeRegistry([PlatformObserveKind.pasteboard: pasteboard])
        observer.observe(app: "clips", kind: PlatformObserveKind.pasteboard, name: "changed")
        observer.observe(app: "shelf", kind: PlatformObserveKind.pasteboard, name: "changed")
        #expect(pasteboard.addedNames == ["changed"], "the name is refcounted, not re-added per app")

        observer.unobserve(app: "clips", kind: PlatformObserveKind.pasteboard, name: "changed")
        #expect(pasteboard.removedNames.isEmpty, "one app leaving must not stop the other's delivery")
        pasteboard.fire("changed", ["changeCount": .int(9)])
        #expect(bench.events.map(\.app) == ["shelf"])

        observer.unobserve(app: "shelf", kind: PlatformObserveKind.pasteboard, name: "changed")
        #expect(pasteboard.removedNames == ["changed"])
    }
}
