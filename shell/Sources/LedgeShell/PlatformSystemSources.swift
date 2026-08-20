import AppKit
import Foundation
import IOKit.ps
import LedgeShellCore
import Network

/// The shipping `PlatformSignalSource`s — one per observe `kind` beyond
/// `distributedNotification`, which `LedgeShellCore` already owns because it
/// needs nothing but Foundation.
///
/// They live in the shell target for the same reason `NotificationPresenter`
/// does: AppKit, IOKit, CoreAudio and the Network framework are the shell's
/// business, and `LedgeShellCore` stays a Foundation-only protocol library that
/// a headless test can drive end to end.
///
/// Every one of them takes its OS resource as an injected protocol, so the
/// source's own logic — the name vocabulary, the payload shape, the
/// start/stop refcount — is testable without a pasteboard, a battery, a network
/// or a sound card.
enum SystemPlatformSources {
    /// The factory the shell hands `PlatformObserver`. Constructing a source is
    /// free; `start()` is where anything is acquired, which is what lets the
    /// registry build one speculatively just to answer "is this kind real?".
    @MainActor
    static func factory(
        distributed: NotificationCenter = DistributedNotificationCenter.default(),
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) -> PlatformObserver.SourceFactory {
        { kind in
            switch kind {
            case PlatformObserveKind.distributedNotification:
                return NotificationCenterSource(center: distributed)
            case PlatformObserveKind.workspace:
                return WorkspaceSource(workspace: workspace, distributed: distributed)
            case PlatformObserveKind.pasteboard:
                return PasteboardSource(
                    pasteboard: SystemPasteboard(),
                    ticker: TimerTicker()
                )
            case PlatformObserveKind.power:
                return PowerSource(reader: SystemPowerReader())
            case PlatformObserveKind.reachability:
                return ReachabilitySource(monitor: SystemPathMonitor())
            case PlatformObserveKind.audio:
                return AudioSource(device: SystemAudioDevice.shared, watcher: SystemAudioWatcher())
            case PlatformObserveKind.focus:
                return FocusSource(reader: SystemFocusReader(), watcher: SystemFocusWatcher())
            default:
                return nil
            }
        }
    }
}

// MARK: - workspace

/// `kind: "workspace"` — app activation, sleep/wake, and screen lock.
///
/// **The name vocabulary is translated, not passed through.** An app writes
/// `observe("workspace", "screenLocked")`, never `"com.apple.screenIsLocked"`.
/// Two reasons, and the second is the real one: the raw names are split across
/// two *different* notification centers (activation and sleep live on
/// `NSWorkspace`'s, lock and unlock are undocumented distributed notifications),
/// which an app has no way to know; and they are Apple's to rename. A small
/// stable vocabulary is the only thing here that is actually a contract.
@MainActor
final class WorkspaceSource: PlatformSignalSource {
    nonisolated let supportedNames: Set<String>? = PlatformSignalName.workspace

    private let workspace: NotificationCenter
    private let distributed: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(workspace: NotificationCenter, distributed: NotificationCenter) {
        self.workspace = workspace
        self.distributed = distributed
    }

    /// (our name, the raw notification, which center it is posted on).
    private static let workspaceMap: [(name: String, raw: Notification.Name)] = [
        (PlatformSignalName.didActivateApplication, NSWorkspace.didActivateApplicationNotification),
        (PlatformSignalName.willSleep, NSWorkspace.willSleepNotification),
        (PlatformSignalName.didWake, NSWorkspace.didWakeNotification),
        (PlatformSignalName.screensDidSleep, NSWorkspace.screensDidSleepNotification),
        (PlatformSignalName.screensDidWake, NSWorkspace.screensDidWakeNotification),
    ]

    private static let distributedMap: [(name: String, raw: Notification.Name)] = [
        (PlatformSignalName.screenLocked, Notification.Name("com.apple.screenIsLocked")),
        (PlatformSignalName.screenUnlocked, Notification.Name("com.apple.screenIsUnlocked")),
    ]

    func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        for entry in Self.workspaceMap {
            tokens.append(observe(on: workspace, entry.raw, as: entry.name, emit: emit))
        }
        for entry in Self.distributedMap {
            tokens.append(observe(on: distributed, entry.raw, as: entry.name, emit: emit))
        }
    }

    func stop() {
        for token in tokens { workspace.removeObserver(token); distributed.removeObserver(token) }
        tokens.removeAll()
    }

    private func observe(
        on center: NotificationCenter,
        _ raw: Notification.Name,
        as name: String,
        emit: @escaping @MainActor (String, [String: JSONValue]) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: raw, object: nil, queue: nil) { notification in
            let payload = Self.payload(for: name, notification: notification)
            MainActor.assumeIsolated { emit(name, payload) }
        }
    }

    /// Scalars only, like every other event on this wire. The activation payload
    /// is the one that carries anything: an `NSRunningApplication` reduced to
    /// the two strings an app can actually use.
    nonisolated static func payload(for name: String, notification: Notification) -> [String: JSONValue] {
        guard name == PlatformSignalName.didActivateApplication else { return [:] }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return [:] }
        var payload: [String: JSONValue] = [:]
        if let bundleId = app.bundleIdentifier { payload["bundleId"] = .string(bundleId) }
        if let localized = app.localizedName { payload["localizedName"] = .string(localized) }
        return payload
    }
}

// MARK: - pasteboard

/// What the pasteboard source is allowed to know. Deliberately **not** the
/// contents: see `PasteboardSource`.
@MainActor
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    /// Readable UTIs on the current item, e.g. `public.utf8-plain-text`.
    var types: [String] { get }
    var hasStrings: Bool { get }
}

/// A repeating timer, injected so the poll cadence can be driven by hand.
@MainActor
protocol PeriodicTicker: AnyObject {
    var isRunning: Bool { get }
    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class SystemPasteboard: PasteboardReading {
    var changeCount: Int { NSPasteboard.general.changeCount }
    var types: [String] { NSPasteboard.general.types?.map(\.rawValue) ?? [] }
    var hasStrings: Bool { NSPasteboard.general.canReadObject(forClasses: [NSString.self]) }
}

@MainActor
final class TimerTicker: PeriodicTicker {
    private var timer: Timer?
    var isRunning: Bool { timer != nil }

    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        // Common modes: the notch runs a tracking run loop while the panel is
        // being dragged, and a paste noticed only after the drag ends is a
        // paste noticed late.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// `kind: "pasteboard"` — the one signal macOS does not broadcast.
///
/// There is no pasteboard-changed notification, so this polls `changeCount` at
/// 2 Hz — but **only while somebody is watching**, which is the entire reason
/// the source lifecycle is refcounted. Zero observers, zero timer; a shell with
/// no clipboard app running does not wake twice a second forever.
///
/// The event carries the change count, the readable type identifiers, and
/// whether there is text — and **never the contents**. That is a deliberate
/// privacy line, not an oversight: the pasteboard holds passwords roughly as
/// often as it holds anything else, and a push event is the wrong place for
/// them. An app that genuinely wants the contents shells out to `pbpaste`,
/// which is a visible, greppable act in that app's own source. This event is
/// the *invalidation signal* — the same job it does for every other kind.
@MainActor
final class PasteboardSource: PlatformSignalSource {
    static let interval: TimeInterval = 0.5

    nonisolated let supportedNames: Set<String>? = PlatformSignalName.snapshot

    private let pasteboard: PasteboardReading
    private let ticker: PeriodicTicker
    private var lastChangeCount: Int?

    init(pasteboard: PasteboardReading, ticker: PeriodicTicker) {
        self.pasteboard = pasteboard
        self.ticker = ticker
    }

    func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        // The count at subscribe time is the baseline: the app is told about
        // changes *from now*, not about whatever was already on the pasteboard.
        lastChangeCount = pasteboard.changeCount
        ticker.start(interval: Self.interval) { [weak self] in
            self?.poll(emit: emit)
        }
    }

    func stop() {
        ticker.stop()
        lastChangeCount = nil
    }

    /// Exposed for tests, which drive the tick by hand rather than waiting.
    func poll(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        emit(PlatformSignalName.changed, [
            "changeCount": .int(count),
            "types": .array(pasteboard.types.map { .string($0) }),
            "hasStrings": .bool(pasteboard.hasStrings),
        ])
    }
}

// MARK: - power

@MainActor
protocol PowerReading: AnyObject {
    func snapshot() -> [String: JSONValue]
    /// Begin delivering change callbacks. The IOKit run-loop source is the
    /// untestable half; everything above it is not.
    func start(changed: @escaping @MainActor () -> Void)
    func stop()
}

/// `kind: "power"` — battery level, charging, AC, low-power mode.
///
/// Fires **immediately on observe** (`snapshot(for:)`), because this describes a
/// *state*: an app that had to wait for the next change to learn the current one
/// would show a blank battery indicator until the machine happened to cross a
/// percent — which on a laptop sitting on AC is never.
@MainActor
final class PowerSource: PlatformSignalSource {
    nonisolated let supportedNames: Set<String>? = PlatformSignalName.snapshot

    private let reader: PowerReading

    init(reader: PowerReading) {
        self.reader = reader
    }

    func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        reader.start { [weak self] in
            guard let self else { return }
            emit(PlatformSignalName.changed, reader.snapshot())
        }
    }

    func stop() {
        reader.stop()
    }

    func snapshot(for name: String) -> [String: JSONValue]? {
        name == PlatformSignalName.changed ? reader.snapshot() : nil
    }
}

/// IOKit power sources + `ProcessInfo`. The run-loop source is the seam that
/// cannot run headlessly; the dictionary reduction below is ordinary code and is
/// exercised through `PowerSource` with a fake reader.
@MainActor
final class SystemPowerReader: PowerReading {
    private var source: CFRunLoopSource?
    private var callback: (@MainActor () -> Void)?

    func snapshot() -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "lowPowerMode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
        ]
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            // No battery (a desktop): on AC by definition, and there is no level.
            payload["onAC"] = .bool(true)
            payload["charging"] = .bool(false)
            return payload
        }
        var onAC = true
        var charging = false
        var level: Double?
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(blob, item)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                onAC = state == kIOPSACPowerValue
            }
            if let isCharging = description[kIOPSIsChargingKey] as? Bool {
                charging = isCharging
            }
            if
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let max = description[kIOPSMaxCapacityKey] as? Int,
                max > 0
            {
                level = Double(current) / Double(max)
            }
        }
        payload["onAC"] = .bool(onAC)
        payload["charging"] = .bool(charging)
        if let level { payload["level"] = .double(level) }
        return payload
    }

    func start(changed: @escaping @MainActor () -> Void) {
        stop()
        callback = changed
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let runLoopSource = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            let reader = Unmanaged<SystemPowerReader>.fromOpaque(raw).takeUnretainedValue()
            MainActor.assumeIsolated { reader.callback?() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        source = runLoopSource
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        source = nil
        callback = nil
    }
}

// MARK: - reachability

@MainActor
protocol PathObserving: AnyObject {
    func start(update: @escaping @MainActor ([String: JSONValue]) -> Void)
    func stop()
    /// The last path state seen, for the immediate fire.
    var latest: [String: JSONValue]? { get }
}

/// `kind: "reachability"` — one shared `NWPathMonitor` for the whole shell,
/// alive exactly while somebody is watching. Fires immediately on observe for
/// the same reason `power` does: an app that has just subscribed wants to know
/// whether it is online *now*, not the next time that changes.
@MainActor
final class ReachabilitySource: PlatformSignalSource {
    nonisolated let supportedNames: Set<String>? = PlatformSignalName.snapshot

    private let monitor: PathObserving

    init(monitor: PathObserving) {
        self.monitor = monitor
    }

    func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        monitor.start { payload in
            emit(PlatformSignalName.changed, payload)
        }
    }

    func stop() {
        monitor.stop()
    }

    func snapshot(for name: String) -> [String: JSONValue]? {
        guard name == PlatformSignalName.changed else { return nil }
        return monitor.latest
    }
}

@MainActor
final class SystemPathMonitor: PathObserving {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.ledge.shell.reachability")
    private(set) var latest: [String: JSONValue]?

    func start(update: @escaping @MainActor ([String: JSONValue]) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let payload = SystemPathMonitor.payload(for: path)
            Task { @MainActor [weak self] in
                self?.latest = payload
                update(payload)
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        latest = nil
    }

    nonisolated static func payload(for path: NWPath) -> [String: JSONValue] {
        let interface: String = if path.usesInterfaceType(.wifi) {
            "wifi"
        } else if path.usesInterfaceType(.wiredEthernet) {
            "wired"
        } else if path.usesInterfaceType(.cellular) {
            "cellular"
        } else {
            "other"
        }
        return [
            "satisfied": .bool(path.status == .satisfied),
            "expensive": .bool(path.isExpensive),
            "constrained": .bool(path.isConstrained),
            "interface": .string(interface),
        ]
    }
}

// MARK: - focus

/// What the focus source is allowed to know: the current state, or **nil** when
/// it cannot be established. The distinction is the whole design — see
/// `FocusSource`.
@MainActor
protocol FocusReading: AnyObject {
    func snapshot() -> [String: JSONValue]?
}

/// The change half: something that calls back when the Focus database is
/// written. Injected for the same reason every other backend is — a file-system
/// event source is not something a headless test should have to provoke.
@MainActor
protocol FocusWatching: AnyObject {
    func start(changed: @escaping @MainActor () -> Void)
    func stop()
}

/// `kind: "focus"` — Do Not Disturb / Focus, as `{ active, modeName? }`.
///
/// macOS publishes no notification for this and no public API to read it. What
/// it does have is the user's own Focus database at `~/Library/DoNotDisturb/DB`,
/// which is a **file read** — the mechanism every third-party menu-bar tool
/// already uses, and specifically not a private framework. It is TCC-protected,
/// so a Ledge without Full Disk Access simply reads nothing.
///
/// Both of the ways this can fail — an undocumented format that shifts under a
/// macOS update, and a read the system refuses — are handled the same way: the
/// reader answers **nil**, and the source emits nothing at all. An app that
/// observed `focus` sees silence, which is the same posture the platform takes
/// everywhere else (a monitor whose API starts 429ing goes quiet; it does not
/// start reporting zero). Reporting `active: false` because a file moved would
/// be confidently wrong, and something would act on it.
///
/// Payloads are deduped: the database is rewritten for more than mode changes,
/// and waking every observing app for an identical state is exactly the cost
/// this kind exists to avoid.
@MainActor
final class FocusSource: PlatformSignalSource {
    nonisolated let supportedNames: Set<String>? = PlatformSignalName.snapshot

    private let reader: FocusReading
    private let watcher: FocusWatching
    private var lastPayload: [String: JSONValue]?

    init(reader: FocusReading, watcher: FocusWatching) {
        self.reader = reader
        self.watcher = watcher
    }

    func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        lastPayload = nil
        watcher.start { [weak self] in
            guard let self, let payload = reader.snapshot(), payload != lastPayload else { return }
            lastPayload = payload
            emit(PlatformSignalName.changed, payload)
        }
    }

    func stop() {
        watcher.stop()
        lastPayload = nil
    }

    /// Fires immediately on observe, like `power` and `reachability`: this
    /// describes a *state*, and an app that had to wait for the next change to
    /// learn the current one would show the wrong thing until the user next
    /// touched Focus — which can be days.
    func snapshot(for name: String) -> [String: JSONValue]? {
        guard name == PlatformSignalName.changed, let payload = reader.snapshot() else { return nil }
        lastPayload = payload
        return payload
    }
}

/// The Focus database, read defensively.
///
/// **The shape is searched for, not walked to.** The documented-by-nobody layout
/// is `data[0].storeAssertionRecords[…].assertionDetails.assertionDetailsModeIdentifier`,
/// and a fixed path through it breaks on any re-nesting Apple does. Looking for
/// the two keys *anywhere* in the tree survives that, and is no less correct:
/// nothing else in the file is called `storeAssertionRecords`.
@MainActor
final class SystemFocusReader: FocusReading {
    /// Overridable so tests read a database they wrote, rather than the one
    /// belonging to whoever is running the suite.
    let directory: URL

    init(directory: URL = SystemFocusReader.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    func snapshot() -> [String: JSONValue]? {
        // No database at all: this Mac has never used Focus, or the read was
        // refused. Either way we do not know, so we say nothing.
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let assertions = directory.appendingPathComponent("Assertions.json")
        guard FileManager.default.fileExists(atPath: assertions.path) else {
            // The directory is there and the file is not: nothing is asserted.
            return ["active": .bool(false)]
        }
        guard let root = Self.json(at: assertions) else { return nil }

        let records = Self.firstArray(in: root, key: "storeAssertionRecords") ?? []
        var payload: [String: JSONValue] = ["active": .bool(!records.isEmpty)]
        if let identifier = Self.firstString(in: records, key: "assertionDetailsModeIdentifier") {
            payload["modeName"] = .string(modeName(for: identifier) ?? Self.shortName(identifier))
        }
        return payload
    }

    /// The user's own name for a mode ("Work"), from the configuration file
    /// beside the assertions. Best effort by design: a mode the file does not
    /// describe falls back to the identifier's last component, which is at
    /// least stable and greppable.
    private func modeName(for identifier: String) -> String? {
        guard let root = Self.json(at: directory.appendingPathComponent("ModeConfigurations.json")),
              let configurations = Self.firstObject(in: root, key: "modeConfigurations"),
              let mode = configurations[identifier] else { return nil }
        return Self.firstString(in: mode, key: "name")
    }

    private static func shortName(_ identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    private static func json(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Shape-tolerant lookups

    private static func firstArray(in value: Any, key: String) -> [Any]? {
        first(in: value, key: key) as? [Any]
    }

    private static func firstObject(in value: Any, key: String) -> [String: Any]? {
        first(in: value, key: key) as? [String: Any]
    }

    private static func firstString(in value: Any, key: String) -> String? {
        first(in: value, key: key) as? String
    }

    /// Breadth-first search for `key` anywhere in a decoded JSON tree.
    private static func first(in value: Any, key: String) -> Any? {
        var queue: [Any] = [value]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let object = current as? [String: Any] {
                if let hit = object[key] { return hit }
                queue.append(contentsOf: object.values)
            } else if let array = current as? [Any] {
                queue.append(contentsOf: array)
            }
        }
        return nil
    }
}

/// A file-system event source on the Focus database's **directory**, not on the
/// file: the assertions file is replaced rather than edited, and a descriptor
/// held on the old inode would stop hearing about anything the moment Focus was
/// first toggled.
@MainActor
final class SystemFocusWatcher: FocusWatching {
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    init(directory: URL = SystemFocusReader.defaultDirectory) {
        self.directory = directory
    }

    func start(changed: @escaping @MainActor () -> Void) {
        stop()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }               // unreadable → simply quiet
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { changed() }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()                            // its cancel handler closes fd
        source = nil
        descriptor = -1
    }
}

// MARK: - audio

/// The change half of the audio kind (the read half is `AudioControlling`,
/// which the `audio()` call shares).
@MainActor
protocol AudioWatching: AnyObject {
    func start(changed: @escaping @MainActor (_ reason: String) -> Void)
    func stop()
}

/// `kind: "audio"` — the default output device, its volume and its mute state.
///
/// One name (`changed`) rather than two, with a `reason` in the payload: an app
/// that cares about volume almost always also cares about the headphones being
/// unplugged, and making it register twice for one concept is a worse API than
/// one scalar it can branch on.
@MainActor
final class AudioSource: PlatformSignalSource {
    nonisolated let supportedNames: Set<String>? = PlatformSignalName.snapshot

    private let device: AudioControlling
    private let watcher: AudioWatching

    init(device: AudioControlling, watcher: AudioWatching) {
        self.device = device
        self.watcher = watcher
    }

    func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        watcher.start { [weak self] reason in
            guard let self, var payload = snapshotPayload() else { return }
            payload["reason"] = .string(reason)
            emit(PlatformSignalName.changed, payload)
        }
    }

    func stop() {
        watcher.stop()
    }

    func snapshot(for name: String) -> [String: JSONValue]? {
        guard name == PlatformSignalName.changed else { return nil }
        guard var payload = snapshotPayload() else { return nil }
        payload["reason"] = .string("current")
        return payload
    }

    private func snapshotPayload() -> [String: JSONValue]? {
        guard case let .success(snapshot) = device.snapshot() else { return nil }
        guard case let .object(object) = PlatformSnapshotJSON.audio(snapshot) else { return nil }
        return object
    }
}
