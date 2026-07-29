import AVFoundation
import AppKit
import CoreAudio
import CoreLocation
import EventKit
import Foundation
import IOKit
import LedgeShellCore

/// The shipping implementations of `PlatformFacades` — the six request/reply
/// calls of `ctx.platform`, each one thin by design.
///
/// Every file in this one is a *seam*: EventKit and CoreLocation raise TCC
/// prompts, CoreAudio needs a sound card, `NSMetadataQuery` needs a real
/// Spotlight index, and `AVSpeechSynthesizer` needs a speaker. None of that can
/// run in a test runner, so none of the policy lives here — the ranges, caps,
/// timeouts, clamps, cache and JSON shapes are all in `PlatformExecutor`, which
/// is tested against fakes. What is left below is: ask the framework, translate
/// its answer into a value type, and turn its failure into a sentence.
///
/// TCC, per spec §6's trust model: the prompt is attributed to **the shell**,
/// which is the process the user recognizes, and there is no Ledge-side grant UI
/// duplicating it. A denial is an ordinary `CapabilityError` an app catches, and
/// never a crash — a calendar app on a machine where the user said no should say
/// so, not disappear.

// MARK: - Calendar (EventKit)

@MainActor
final class SystemCalendar: CalendarProviding {
    /// One store for the whole shell. `EKEventStore` is expensive to build and
    /// holds the authorization state; a per-call one would re-prompt the change
    /// notification machinery on every poll.
    private let store = EKEventStore()
    private var granted = false

    func requestAccess(_ completion: @escaping @MainActor @Sendable (Result<Void, CapabilityError>) -> Void) {
        if granted {
            completion(.success(()))
            return
        }
        // `requestFullAccessToEvents` is the macOS 14+ API and the deployment
        // target is 14 — the older `requestAccess(to:)` is deprecated and, on
        // 14+, silently means write-only for some callers.
        store.requestFullAccessToEvents { [weak self] ok, error in
            Task { @MainActor in
                guard ok else {
                    completion(.failure(CapabilityError(
                        error.map { "calendar access was refused: \($0.localizedDescription)" }
                            ?? "calendar access was refused in System Settings › Privacy & Security › Calendars"
                    )))
                    return
                }
                self?.granted = true
                completion(.success(()))
            }
        }
    }

    func events(
        from: Date,
        to: Date,
        completion: @escaping @MainActor @Sendable (Result<[CalendarEvent], CapabilityError>) -> Void
    ) {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map { event in
                CalendarEvent(
                    title: event.title ?? "(no title)",
                    start: event.startDate ?? from,
                    end: event.endDate ?? event.startDate ?? from,
                    allDay: event.isAllDay,
                    calendar: event.calendar?.title ?? "",
                    location: event.location
                )
            }
        completion(.success(events))
    }
}

// MARK: - Workspace probe

@MainActor
final class SystemWorkspaceProbe: WorkspaceProbing {
    func snapshot() -> WorkspaceSnapshot {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return WorkspaceSnapshot(
            frontmostBundleId: frontmost?.bundleIdentifier,
            frontmostName: frontmost?.localizedName,
            idleSeconds: Self.idleSeconds(),
            screenLocked: Self.screenLocked()
        )
    }

    /// Seconds since the user last did anything.
    ///
    /// `kCGAnyInputEventType` is `0xFFFFFFFF`, which is not a `CGEventType`
    /// case, so it cannot be spelled in Swift without an unsafe cast. Taking the
    /// minimum across the real input types is the same answer by construction:
    /// "any input" is exactly "the most recent of these".
    static func idleSeconds() -> Double {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .keyDown, .flagsChanged, .scrollWheel,
        ]
        let idle = types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        return idle.min() ?? 0
    }

    /// Cheaply knowable, so it is reported. `CGSessionCopyCurrentDictionary` is
    /// an in-process read of the window server's session dictionary — no
    /// polling, no permission.
    static func screenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        guard let locked = session["CGSSessionScreenIsLocked"] as? Bool else { return false }
        return locked
    }
}

// MARK: - Location (CoreLocation)

@MainActor
final class SystemLocation: NSObject, LocationProviding {
    private let manager = CLLocationManager()
    private var waiting: [@MainActor @Sendable (Result<LocationFix, CapabilityError>) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
        // Reduced accuracy is plenty for "which city am I in", which is what
        // every app on this surface actually wants, and it is the setting that
        // does not spin the GPS.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func requestFix(_ completion: @escaping @MainActor @Sendable (Result<LocationFix, CapabilityError>) -> Void) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            completion(.failure(CapabilityError(
                "location access was refused in System Settings › Privacy & Security › Location Services"
            )))
            return
        case .notDetermined:
            // Never blocks: the prompt is answered asynchronously and
            // `locationManagerDidChangeAuthorization` resumes the request. The
            // executor's 8 s deadline covers "the user never answered".
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        waiting.append(completion)
        if manager.authorizationStatus != .notDetermined {
            manager.requestLocation()
        }
    }

    fileprivate func settle(_ result: Result<LocationFix, CapabilityError>) {
        let pending = waiting
        waiting.removeAll()
        for completion in pending { completion(result) }
    }

    fileprivate func authorizationChanged() {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            settle(.failure(CapabilityError("location access was refused")))
        case .notDetermined:
            break
        default:
            if !waiting.isEmpty { manager.requestLocation() }
        }
    }
}

extension SystemLocation: CLLocationManagerDelegate {
    /// CoreLocation calls back on the queue its manager was created on — the
    /// main one — so this is an assertion, not a hop.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last else {
                settle(.failure(CapabilityError("location returned no fix")))
                return
            }
            settle(.success(LocationFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracyMeters: location.horizontalAccuracy,
                timestamp: location.timestamp
            )))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            settle(.failure(CapabilityError("location failed: \(error.localizedDescription)")))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { authorizationChanged() }
    }
}

// MARK: - Spotlight (NSMetadataQuery)

@MainActor
final class SystemSpotlight: SpotlightSearching {
    private var query: NSMetadataQuery?
    private var token: NSObjectProtocol?

    func search(
        query text: String,
        scopes: [String],
        limit: Int,
        timeout: TimeInterval,
        completion: @escaping @MainActor @Sendable (Result<[SpotlightHit], CapabilityError>) -> Void
    ) {
        // **The exception trap.** `NSPredicate(format:)` raises an ObjC
        // exception on a malformed predicate, and an ObjC exception in Swift is
        // not catchable — one app's typo would kill the shell and every other
        // app's panel with it. `predicateFromMetadataQueryString:` is the
        // failable parser for exactly this string grammar: it *returns nil*
        // instead of raising, which is the whole reason it is used here.
        guard let predicate = NSPredicate(fromMetadataQueryString: text) else {
            completion(.failure(CapabilityError("spotlight query is not a valid metadata predicate")))
            return
        }
        stop()
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes.map { URL(fileURLWithPath: $0) }
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        token = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: nil
        ) { _ in
            // `self` (main-actor isolated) rather than the query: `NSMetadataQuery`
            // is not `Sendable`, and it is already reachable from here.
            MainActor.assumeIsolated { self.gathered(limit: limit, completion: completion) }
        }
        self.query = query
        guard query.start() else {
            stop()
            completion(.failure(CapabilityError("spotlight could not start the query")))
            return
        }
    }

    private func gathered(
        limit: Int,
        completion: @escaping @MainActor @Sendable (Result<[SpotlightHit], CapabilityError>) -> Void
    ) {
        guard let query else { return }
        query.disableUpdates()
        let hits = (0..<min(query.resultCount, limit)).compactMap { index -> SpotlightHit? in
            guard let item = query.result(at: index) as? NSMetadataItem else { return nil }
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            return SpotlightHit(
                path: path,
                name: item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
                    ?? (path as NSString).lastPathComponent,
                contentType: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String ?? "",
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            )
        }
        stop()
        completion(.success(hits))
    }

    /// The executor owns the deadline; this only has to make sure a query that
    /// outlived it is not still indexing in the background.
    private func stop() {
        query?.stop()
        query = nil
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

// MARK: - Audio (CoreAudio)

@MainActor
final class SystemAudioDevice: AudioControlling {
    static let shared = SystemAudioDevice()

    func snapshot() -> Result<AudioSnapshot, CapabilityError> {
        guard let device = Self.defaultOutputDevice() else {
            return .failure(CapabilityError("no default output device"))
        }
        let transport = Self.transportType(device)
        return .success(AudioSnapshot(
            deviceName: Self.name(device) ?? "Output",
            volume: Self.volume(device) ?? 0,
            muted: Self.muted(device) ?? false,
            transportType: transport,
            batteryPercent: transport == "bluetooth" ? Self.bluetoothBatteryPercent() : nil
        ))
    }

    func setVolume(_ value: Double) -> Result<Void, CapabilityError> {
        guard let device = Self.defaultOutputDevice() else {
            return .failure(CapabilityError("no default output device"))
        }
        // The main element carries the volume on most devices; on the ones that
        // expose only per-channel scalars, the first two channels are the pair a
        // user thinks of as "the volume", and both have to be written or the
        // balance shifts. So: try main, and fall back to writing every channel.
        if write(volume: value, device: device, element: kAudioObjectPropertyElementMain) {
            return .success(())
        }
        let channels = [1, 2].filter { write(volume: value, device: device, element: AudioObjectPropertyElement($0)) }
        guard !channels.isEmpty else {
            return .failure(CapabilityError("the default output device does not allow setting its volume"))
        }
        return .success(())
    }

    private func write(volume: Double, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard
            AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
            settable.boolValue
        else { return false }
        var scalar = Float(volume)
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &scalar
        ) == noErr
    }

    // MARK: CoreAudio reads

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func name(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // `Unmanaged` rather than `CFString`: the property is a +1 reference and
        // a raw pointer to a Swift-managed `CFString` variable is exactly the
        // "may contain an object reference" hazard the compiler warns about.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func volume(_ device: AudioDeviceID) -> Double? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { continue }
            return Double(value)
        }
        return nil
    }

    static func muted(_ device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func transportType(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return "other" }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayPort"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        default: return "other"
        }
    }

    /// Best effort, and nil is a perfectly good answer. AirPods publish a
    /// percentage in the IORegistry under the HID service that carries them;
    /// most other Bluetooth output devices publish nothing at all, and inventing
    /// a number for those would be worse than omitting the key.
    static func bluetoothBatteryPercent() -> Double? {
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        let keys = ["BatteryPercentCombined", "BatteryPercent", "BatteryPercentLeft", "BatteryPercentRight"]
        var lowest: Double?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            for key in keys {
                guard let raw = IORegistryEntryCreateCFProperty(
                    service, key as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? NSNumber else { continue }
                let percent = raw.doubleValue
                guard percent > 0 else { continue }
                lowest = min(lowest ?? percent, percent)
            }
        }
        return lowest
    }
}

/// The CoreAudio property listeners behind `kind: "audio"`. One listener on the
/// system object (the default device changed) plus one per property on the
/// current device (its volume, its mute), re-pointed whenever the device
/// changes — a listener left on an unplugged device would go quiet, which is the
/// exact failure the source exists to prevent.
@MainActor
final class SystemAudioWatcher: AudioWatching {
    private var changed: (@MainActor (String) -> Void)?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceProperties: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var watchedDevice: AudioDeviceID?

    func start(changed: @escaping @MainActor (String) -> Void) {
        stop()
        self.changed = changed
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in
                self?.attachDeviceListeners()
                self?.changed?("device")
            }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        attachDeviceListeners()
    }

    func stop() {
        if let deviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, deviceListener
            )
        }
        deviceListener = nil
        detachDeviceListeners()
        changed = nil
    }

    private func attachDeviceListeners() {
        detachDeviceListeners()
        guard let device = SystemAudioDevice.defaultOutputDevice() else { return }
        watchedDevice = device
        let selectors: [(AudioObjectPropertySelector, String)] = [
            (kAudioDevicePropertyVolumeScalar, "volume"),
            (kAudioDevicePropertyMute, "volume"),
        ]
        for (selector, reason) in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor [weak self] in self?.changed?(reason) }
            }
            guard AudioObjectAddPropertyListenerBlock(
                device, &address, DispatchQueue.main, listener
            ) == noErr else { continue }
            deviceProperties.append((device, address, listener))
        }
    }

    private func detachDeviceListeners() {
        for (device, address, listener) in deviceProperties {
            var mutable = address
            AudioObjectRemovePropertyListenerBlock(device, &mutable, DispatchQueue.main, listener)
        }
        deviceProperties.removeAll()
        watchedDevice = nil
    }
}

// MARK: - Speech (AVSpeechSynthesizer)

/// `ctx.platform.speak`, owned by the shell and **one utterance at a time**.
///
/// A second `speak` while speaking *replaces* the first rather than queueing
/// behind it. That is not a simplification: notch announcements are status, and
/// status that queues is status that lies — an app announcing every price tick
/// would build a backlog and still be reading out numbers from four minutes ago.
/// The replaced utterance's Promise **resolves** (it did not fail; it was
/// superseded), so nobody is left awaiting a sentence that will never be spoken.
@MainActor
final class SystemSpeech: NSObject, SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance is remembered by **identity**, not by reference:
    /// `AVSpeechUtterance` is not `Sendable`, and the delegate callbacks are
    /// nonisolated, so an `ObjectIdentifier` is the only thing that may cross.
    private var current: (
        id: ObjectIdentifier,
        completion: @MainActor @Sendable (Result<Void, CapabilityError>) -> Void
    )?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        text: String,
        voice: String?,
        rate: Double?,
        completion: @escaping @MainActor @Sendable (Result<Void, CapabilityError>) -> Void
    ) {
        finishCurrent()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: text)
        if let voice {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voice)
                ?? AVSpeechSynthesisVoice(language: voice)
        }
        if let rate {
            utterance.rate = Float(min(
                max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                Double(AVSpeechUtteranceMaximumSpeechRate)
            ))
        }
        current = (ObjectIdentifier(utterance), completion)
        synthesizer.speak(utterance)
    }

    /// Settle whatever is speaking as done. Called when a new utterance replaces
    /// it and when the synthesizer reports it finished or was cancelled.
    private func finishCurrent(_ id: ObjectIdentifier? = nil) {
        guard let entry = current else { return }
        if let id, id != entry.id { return }
        current = nil
        entry.completion(.success(()))
    }
}

extension SystemSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated { finishCurrent(id) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated { finishCurrent(id) }
    }
}

// MARK: - Quit (NSApplication)

/// `ctx.platform.quit()`, shipping implementation.
///
/// Asynchronous on purpose. `NSApp.terminate` runs the whole termination
/// sequence — `applicationShouldTerminate`, `applicationWillTerminate`, and in
/// our case `HostProcess`'s teardown — and doing that from inside the socket
/// read that delivered the request would destroy the session that still has an
/// `ok` reply to write. One hop through the main queue is the difference
/// between an app whose `await ctx.platform.quit()` resolves and one whose
/// Promise dies with the connection.
@MainActor
final class SystemQuit: ShellQuitting {
    func requestQuit() {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
