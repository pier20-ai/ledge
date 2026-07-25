import Foundation

/// The OS-touching seams behind `ctx.platform`'s request/reply calls.
///
/// Every one of these is a protocol with exactly one shipping implementation
/// (in the `LedgeShell` target, where AppKit / EventKit / CoreLocation /
/// CoreAudio / AVFoundation live) and one fake per test. That split is not
/// decoration: EventKit and CoreLocation raise **TCC prompts**, which a test
/// runner cannot answer and a CI machine does not have; CoreAudio and
/// `NSMetadataQuery` need real hardware and a real index. Everything *around*
/// them — range defaulting, the 14-day cap, the result cap, the timeouts, the
/// clamp, the cache, the JSON shape — is in `PlatformExecutor` and is fully
/// tested, and what is left at the boundary is one method that either answers
/// or doesn't.
///
/// The results are value types on purpose: nothing framework-shaped (an
/// `EKEvent`, a `CLLocation`, an `NSMetadataItem`) crosses back into the
/// executor, so the executor never has to link the framework it is orchestrating.

// MARK: - Calendar (EventKit)

public struct CalendarEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendar: String
    public var location: String?

    public init(
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        calendar: String,
        location: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
    }
}

@MainActor
public protocol CalendarProviding: AnyObject {
    /// Ensure access, prompting once if macOS has not asked yet. **Must not
    /// block the main thread**: the prompt is a modal the user has to answer,
    /// and the notch has to keep animating while they do. A denial is a
    /// `CapabilityError` with a sentence an app can show, never a crash.
    func requestAccess(_ completion: @escaping @MainActor @Sendable (Result<Void, CapabilityError>) -> Void)

    /// Events overlapping `[from, to]`, already sorted by start.
    func events(
        from: Date,
        to: Date,
        completion: @escaping @MainActor @Sendable (Result<[CalendarEvent], CapabilityError>) -> Void
    )
}

// MARK: - Workspace probe (NSWorkspace + CGEventSource)

public struct WorkspaceSnapshot: Sendable, Equatable {
    public var frontmostBundleId: String?
    public var frontmostName: String?
    public var idleSeconds: Double
    /// Omitted from the result when nil — "cheaply knowable" is a property of
    /// the machine, and inventing `false` would be worse than saying nothing.
    public var screenLocked: Bool?

    public init(
        frontmostBundleId: String? = nil,
        frontmostName: String? = nil,
        idleSeconds: Double = 0,
        screenLocked: Bool? = nil
    ) {
        self.frontmostBundleId = frontmostBundleId
        self.frontmostName = frontmostName
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
    }
}

@MainActor
public protocol WorkspaceProbing: AnyObject {
    /// Synchronous on purpose: every field is a cheap in-process read.
    func snapshot() -> WorkspaceSnapshot
}

// MARK: - Location (CoreLocation)

public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, accuracyMeters: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.timestamp = timestamp
    }
}

@MainActor
public protocol LocationProviding: AnyObject {
    /// One reduced-accuracy fix. Authorization (WhenInUse) is requested on
    /// first use and a denial comes back as a `CapabilityError`; the executor
    /// additionally bounds the wait, because "the user never answered the
    /// prompt" and "the radios never got a fix" look identical from here.
    func requestFix(_ completion: @escaping @MainActor @Sendable (Result<LocationFix, CapabilityError>) -> Void)
}

// MARK: - Spotlight (NSMetadataQuery)

public struct SpotlightHit: Sendable, Equatable {
    public var path: String
    public var name: String
    public var contentType: String
    public var modified: Date?

    public init(path: String, name: String, contentType: String, modified: Date? = nil) {
        self.path = path
        self.name = name
        self.contentType = contentType
        self.modified = modified
    }
}

@MainActor
public protocol SpotlightSearching: AnyObject {
    /// `query` is NSPredicate metadata-query format. The implementation **must
    /// not** let a malformed predicate escape: `NSPredicate(format:)` raises an
    /// ObjC exception, which in Swift is not catchable and would take the whole
    /// shell down for one app's typo. Validate or trap, and answer with an
    /// error result.
    func search(
        query: String,
        scopes: [String],
        limit: Int,
        timeout: TimeInterval,
        completion: @escaping @MainActor @Sendable (Result<[SpotlightHit], CapabilityError>) -> Void
    )
}

// MARK: - Audio (CoreAudio)

public struct AudioSnapshot: Sendable, Equatable {
    public var deviceName: String
    public var volume: Double
    public var muted: Bool
    public var transportType: String
    /// Best effort, Bluetooth only: AirPods publish a battery percentage in the
    /// IORegistry and most other devices publish nothing. Absent means "this
    /// device does not say", never "empty".
    public var batteryPercent: Double?

    public init(
        deviceName: String,
        volume: Double,
        muted: Bool,
        transportType: String,
        batteryPercent: Double? = nil
    ) {
        self.deviceName = deviceName
        self.volume = volume
        self.muted = muted
        self.transportType = transportType
        self.batteryPercent = batteryPercent
    }
}

@MainActor
public protocol AudioControlling: AnyObject {
    func snapshot() -> Result<AudioSnapshot, CapabilityError>
    /// `value` arrives already clamped to 0…1 by the executor.
    func setVolume(_ value: Double) -> Result<Void, CapabilityError>
}

// MARK: - Speech (AVSpeechSynthesizer)

@MainActor
public protocol SpeechSynthesizing: AnyObject {
    /// Speak, **replacing** whatever is speaking. The replaced utterance's
    /// completion fires too (successfully): a notch announcement that has been
    /// superseded is finished as far as the app that asked is concerned, and an
    /// app awaiting it must not be left hanging by a newer announcement.
    func speak(
        text: String,
        voice: String?,
        rate: Double?,
        completion: @escaping @MainActor @Sendable (Result<Void, CapabilityError>) -> Void
    )
}
