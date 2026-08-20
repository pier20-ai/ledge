import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

// MARK: - Fake backends

/// A pasteboard that is not a pasteboard. The point of the split: the source's
/// logic (baseline, dedupe, payload shape) is ordinary code, and only the
/// `NSPasteboard` read is not.
@MainActor
final class FakePasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    var hasStrings = false
}

@MainActor
final class FakeTicker: PeriodicTicker {
    private(set) var isRunning = false
    private(set) var interval: TimeInterval = 0
    private var tick: (@MainActor () -> Void)?

    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        isRunning = true
        self.interval = interval
        self.tick = tick
    }

    func stop() {
        isRunning = false
        tick = nil
    }

    /// Drive the clock by hand instead of sleeping half a second per assertion.
    func fire() { tick?() }
}

@MainActor
final class FakePowerReader: PowerReading {
    var state: [String: JSONValue] = [
        "level": .double(0.62), "charging": .bool(false),
        "onAC": .bool(false), "lowPowerMode": .bool(false),
    ]
    private(set) var started = 0
    private(set) var stopped = 0
    private var changed: (@MainActor () -> Void)?

    func snapshot() -> [String: JSONValue] { state }
    func start(changed: @escaping @MainActor () -> Void) {
        started += 1
        self.changed = changed
    }

    func stop() {
        stopped += 1
        changed = nil
    }

    func fire() { changed?() }
}

@MainActor
final class FakePathMonitor: PathObserving {
    var latest: [String: JSONValue]?
    private(set) var started = 0
    private(set) var stopped = 0
    private var update: (@MainActor ([String: JSONValue]) -> Void)?

    func start(update: @escaping @MainActor ([String: JSONValue]) -> Void) {
        started += 1
        self.update = update
    }

    func stop() {
        stopped += 1
        update = nil
        latest = nil
    }

    func push(_ payload: [String: JSONValue]) {
        latest = payload
        update?(payload)
    }
}

@MainActor
final class FakeAudioWatcher: AudioWatching {
    private(set) var started = 0
    private(set) var stopped = 0
    private var changed: (@MainActor (String) -> Void)?

    func start(changed: @escaping @MainActor (String) -> Void) {
        started += 1
        self.changed = changed
    }

    func stop() {
        stopped += 1
        changed = nil
    }

    func fire(_ reason: String) { changed?(reason) }
}

@MainActor
final class StubAudioDevice: AudioControlling {
    var state = AudioSnapshot(deviceName: "Speakers", volume: 0.5, muted: false, transportType: "builtIn")
    var result: Result<AudioSnapshot, CapabilityError>?
    func snapshot() -> Result<AudioSnapshot, CapabilityError> { result ?? .success(state) }
    func setVolume(_ value: Double) -> Result<Void, CapabilityError> { .success(()) }
}

@MainActor
final class FakeFocusReader: FocusReading {
    /// nil = the database could not be read (no Full Disk Access, or a format
    /// the shell no longer recognizes).
    var state: [String: JSONValue]? = ["active": .bool(false)]
    func snapshot() -> [String: JSONValue]? { state }
}

@MainActor
final class FakeFocusWatcher: FocusWatching {
    private(set) var started = 0
    private(set) var stopped = 0
    private var changed: (@MainActor () -> Void)?

    func start(changed: @escaping @MainActor () -> Void) {
        started += 1
        self.changed = changed
    }

    func stop() {
        stopped += 1
        changed = nil
    }

    func fire() { changed?() }
}

/// A throwaway Focus database on disk — the real reader against real files, in
/// a directory the test owns rather than the one belonging to whoever is running
/// the suite (which is TCC-protected and would make this untestable).
enum FocusDatabase {
    static func make() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func write(_ contents: String, to file: String, in directory: URL) throws {
        try contents.write(
            to: directory.appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
    }

    static func writeAssertions(_ contents: String, in directory: URL) throws {
        try write(contents, to: "Assertions.json", in: directory)
    }
}

// MARK: - Tests

/// The shipping observe sources: the translation each one performs between an OS
/// signal and the small scalar payload that crosses the wire.
///
/// Each takes its OS resource as an injected protocol, so what runs below is the
/// *shipping* source class with the battery, the network, the sound card and the
/// pasteboard replaced. What is left untested is one method per source, and that
/// is deliberate — see the seam list in `PlatformSystemFacades`.
@MainActor
@Suite("Platform signal sources (spec §6 extension)")
struct PlatformSourcesTests {
    // MARK: workspace

    @Test("Workspace names are translated, and the two centers are both watched")
    func workspaceTranslates() {
        let workspaceCenter = NotificationCenter()
        let distributed = NotificationCenter()
        let source = WorkspaceSource(workspace: workspaceCenter, distributed: distributed)
        var fired: [(String, [String: JSONValue])] = []
        source.start { name, payload in fired.append((name, payload)) }

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Lock and unlock live on a *different* center from the rest of this
        // kind, which is exactly why an app must not be handed the raw names.
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        #expect(fired.map(\.0) == ["willSleep", "screensDidWake", "screenLocked", "screenUnlocked"])
        #expect(fired.allSatisfy { PlatformSignalName.workspace.contains($0.0) })
    }

    @Test("An activation carries the app's bundle id and name, and nothing else")
    func workspaceActivationPayload() {
        let center = NotificationCenter()
        let source = WorkspaceSource(workspace: center, distributed: NotificationCenter())
        var fired: [(String, [String: JSONValue])] = []
        source.start { name, payload in fired.append((name, payload)) }

        // `NSRunningApplication` cannot be constructed, but this process is one.
        let running = NSRunningApplication.current
        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: running]
        )

        #expect(fired.count == 1)
        let payload = fired[0].1
        #expect(payload["localizedName"]?.asString == running.localizedName)
        // Scalars only: the NSRunningApplication itself never crosses.
        #expect(payload.values.allSatisfy { $0.asString != nil })
        #expect(payload.count <= 2)
    }

    @Test("Stopping a workspace source really unsubscribes")
    func workspaceStops() {
        let center = NotificationCenter()
        let source = WorkspaceSource(workspace: center, distributed: NotificationCenter())
        var count = 0
        source.start { _, _ in count += 1 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(count == 1)

        source.stop()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(count == 1)
    }

    // MARK: pasteboard

    @Test("The pasteboard timer runs only while somebody is watching")
    func pasteboardTimerLifecycle() {
        let ticker = FakeTicker()
        let source = PasteboardSource(pasteboard: FakePasteboard(), ticker: ticker)
        #expect(ticker.isRunning == false)

        source.start { _, _ in }
        #expect(ticker.isRunning)
        #expect(ticker.interval == PasteboardSource.interval)
        #expect(ticker.interval == 0.5)

        source.stop()
        // A poll left running is a timer firing twice a second, forever, for
        // nobody — the one failure mode a polled source has that a notification
        // does not.
        #expect(ticker.isRunning == false)
    }

    @Test("A pasteboard event is the invalidation signal, never the contents")
    func pasteboardPayload() {
        let pasteboard = FakePasteboard()
        pasteboard.changeCount = 100
        let ticker = FakeTicker()
        let source = PasteboardSource(pasteboard: pasteboard, ticker: ticker)
        var fired: [[String: JSONValue]] = []
        source.start { _, payload in fired.append(payload) }

        // The count at subscribe time is the baseline: the app is told about
        // changes from now, not about whatever was already sitting there.
        ticker.fire()
        #expect(fired.isEmpty)

        pasteboard.changeCount = 101
        pasteboard.types = ["public.utf8-plain-text", "public.html"]
        pasteboard.hasStrings = true
        ticker.fire()
        #expect(fired.count == 1)
        let payload = fired[0]
        #expect(payload["changeCount"]?.asInt == 101)
        #expect(payload["hasStrings"]?.asBool == true)
        #expect(payload["types"]?.asArray?.count == 2)
        // The privacy line: an app that genuinely wants the clipboard shells out
        // to `pbpaste`, which is a visible act in its own source.
        #expect(payload["contents"] == nil)
        #expect(payload.count == 3)

        // A tick with no change is not an event.
        ticker.fire()
        #expect(fired.count == 1)
    }

    // MARK: power

    @Test("Power fires the current state on registration and again on change")
    func powerSnapshotAndChange() {
        let reader = FakePowerReader()
        let source = PowerSource(reader: reader)
        var fired: [[String: JSONValue]] = []
        source.start { _, payload in fired.append(payload) }
        #expect(reader.started == 1)

        // The immediate fire is the registry's job; the source only has to have
        // an answer for it.
        let snapshot = source.snapshot(for: PlatformSignalName.changed)
        #expect(snapshot?["level"]?.asDouble == 0.62)
        #expect(source.snapshot(for: "somethingElse") == nil)

        reader.state["level"] = .double(0.55)
        reader.state["charging"] = .bool(true)
        reader.fire()
        #expect(fired.count == 1)
        #expect(fired[0]["level"]?.asDouble == 0.55)
        #expect(fired[0]["charging"]?.asBool == true)

        source.stop()
        #expect(reader.stopped == 1)
    }

    // MARK: reachability

    @Test("Reachability shares one monitor and answers the immediate fire from it")
    func reachability() {
        let monitor = FakePathMonitor()
        let source = ReachabilitySource(monitor: monitor)
        var fired: [[String: JSONValue]] = []
        source.start { _, payload in fired.append(payload) }
        #expect(monitor.started == 1)
        // Nothing seen yet ⇒ nothing to deliver at registration; the first path
        // update fills it in.
        #expect(source.snapshot(for: PlatformSignalName.changed) == nil)

        monitor.push([
            "satisfied": .bool(false), "expensive": .bool(true),
            "constrained": .bool(false), "interface": .string("cellular"),
        ])
        #expect(fired.count == 1)
        #expect(fired[0]["interface"]?.asString == "cellular")
        #expect(source.snapshot(for: PlatformSignalName.changed)?["satisfied"]?.asBool == false)

        source.stop()
        #expect(monitor.stopped == 1)
    }

    // MARK: audio

    @Test("An audio event carries the same object the audio() call returns, plus a reason")
    func audioEvent() throws {
        let device = StubAudioDevice()
        device.state = AudioSnapshot(
            deviceName: "AirPods Pro", volume: 0.42, muted: false,
            transportType: "bluetooth", batteryPercent: 78
        )
        let watcher = FakeAudioWatcher()
        let source = AudioSource(device: device, watcher: watcher)
        var fired: [[String: JSONValue]] = []
        source.start { _, payload in fired.append(payload) }

        watcher.fire("device")
        #expect(fired.count == 1)
        #expect(fired[0]["deviceName"]?.asString == "AirPods Pro")
        #expect(fired[0]["batteryPercent"]?.asDouble == 78)
        // One name and a `reason`, rather than two names: an app that cares
        // about volume nearly always also cares about the headphones going away.
        #expect(fired[0]["reason"]?.asString == "device")

        watcher.fire("volume")
        #expect(fired.last?["reason"]?.asString == "volume")

        // The immediate fire is the same shape, labelled for what it is.
        let snapshot = try #require(source.snapshot(for: PlatformSignalName.changed))
        #expect(snapshot["reason"]?.asString == "current")
        // …and it is literally the call's payload, so an app parses one shape.
        let callShape = try #require(PlatformSnapshotJSON.audio(device.state).asObject)
        #expect(snapshot.filter { $0.key != "reason" } == callShape)

        source.stop()
        #expect(watcher.stopped == 1)
    }

    @Test("A device that cannot be read produces no event rather than a hollow one")
    func audioUnreadable() {
        let device = StubAudioDevice()
        device.result = .failure(CapabilityError("no default output device"))
        let watcher = FakeAudioWatcher()
        let source = AudioSource(device: device, watcher: watcher)
        var fired = 0
        source.start { _, _ in fired += 1 }
        watcher.fire("device")
        #expect(fired == 0)
        #expect(source.snapshot(for: PlatformSignalName.changed) == nil)
    }

    // MARK: focus

    @Test("Focus fires the current state on observe, and again only when it changes")
    func focusDedupes() throws {
        let reader = FakeFocusReader()
        let watcher = FakeFocusWatcher()
        let source = FocusSource(reader: reader, watcher: watcher)
        var fired: [[String: JSONValue]] = []

        // The order the registry uses: start the shared resource, then deliver
        // the immediate state to the app that just registered.
        source.start { _, payload in fired.append(payload) }
        let immediate = try #require(source.snapshot(for: PlatformSignalName.changed))
        #expect(immediate["active"]?.asBool == false)

        // The database is rewritten for more than mode changes; an identical
        // state must not wake every observing app — including one identical to
        // the immediate fire it has already been given.
        watcher.fire()
        #expect(fired.isEmpty)

        reader.state = ["active": .bool(true), "modeName": .string("Work")]
        watcher.fire()
        watcher.fire()
        #expect(fired.count == 1)
        #expect(fired.last?["modeName"]?.asString == "Work")

        source.stop()
        #expect(watcher.stopped == 1)
    }

    @Test("A Focus database it cannot read is silent, never a confident `active: false`")
    func focusUnreadableIsQuiet() {
        let reader = FakeFocusReader()
        reader.state = nil                 // no Full Disk Access, or a new format
        let watcher = FakeFocusWatcher()
        let source = FocusSource(reader: reader, watcher: watcher)
        var fired = 0
        source.start { _, _ in fired += 1 }
        watcher.fire()
        #expect(fired == 0)
        #expect(source.snapshot(for: PlatformSignalName.changed) == nil)
    }

    @Test("The reader finds the state wherever the undocumented file nests it")
    func focusReaderParsesTheDatabase() throws {
        let directory = try FocusDatabase.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = SystemFocusReader(directory: directory)

        // No assertions recorded: Focus is off, and we know it.
        try FocusDatabase.writeAssertions(#"{ "data": [ { "storeAssertionRecords": [] } ] }"#, in: directory)
        #expect(reader.snapshot()?["active"]?.asBool == false)

        // On, with a mode the configuration file names.
        try FocusDatabase.writeAssertions(#"""
        { "data": [ { "storeAssertionRecords": [
          { "assertionDetails": {
              "assertionDetailsModeIdentifier": "com.apple.focus.work" } } ] } ] }
        """#, in: directory)
        try FocusDatabase.write(#"""
        { "data": [ { "modeConfigurations": {
            "com.apple.focus.work": { "mode": { "name": "Deep Work" } } } } ] }
        """#, to: "ModeConfigurations.json", in: directory)
        var snapshot = try #require(reader.snapshot())
        #expect(snapshot["active"]?.asBool == true)
        #expect(snapshot["modeName"]?.asString == "Deep Work")

        // A mode nothing describes still gets a name: the identifier's last
        // component, which is at least stable and greppable.
        try FocusDatabase.write("{}", to: "ModeConfigurations.json", in: directory)
        snapshot = try #require(reader.snapshot())
        #expect(snapshot["modeName"]?.asString == "work")

        // The format shifting under a macOS update: still valid JSON, but the
        // records are gone. Nothing is asserted, and that is what we report —
        // the *unreadable* case below is the one that has to stay silent.
        try FocusDatabase.writeAssertions(#"{ "somethingElse": true }"#, in: directory)
        #expect(reader.snapshot()?["active"]?.asBool == false)

        // Not JSON at all (or a read the system refused): we do not know.
        try FocusDatabase.writeAssertions("<plist>not json</plist>", in: directory)
        #expect(reader.snapshot() == nil)

        // No database directory: this Mac has never used Focus, or the read was
        // refused outright. Either way, saying nothing beats inventing a state.
        try FileManager.default.removeItem(at: directory)
        #expect(reader.snapshot() == nil)
    }

    // MARK: the probes that really do run headlessly

    @Test("The workspace probe reads idle time and lock state without any prompt")
    func workspaceProbeIsCheap() {
        // Both are in-process reads — no TCC, no polling — which is why
        // `workspace()` is the one call on this surface with no permission story.
        #expect(SystemWorkspaceProbe.idleSeconds() >= 0)
        let snapshot = SystemWorkspaceProbe().snapshot()
        #expect(snapshot.idleSeconds >= 0)
        // In a test runner there may be no frontmost app; the field is optional
        // for exactly that reason.
        if let bundleId = snapshot.frontmostBundleId { #expect(!bundleId.isEmpty) }
    }
}
