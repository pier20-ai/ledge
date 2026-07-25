import Foundation

/// Settles one `platform` request/reply call. `nil` data is a call that
/// genuinely has no answer (`speak`), not a null on the wire.
public typealias PlatformCompletion = @MainActor @Sendable (Result<JSONValue?, CapabilityError>) -> Void

/// The request/reply half of `ctx.platform` (spec §6 extension): the six calls
/// that ask the shell a question only the shell process can answer.
///
/// Everything policy-shaped lives here and nothing framework-shaped does — see
/// `PlatformFacades`. The policy is the interesting part and is what an app
/// actually depends on:
///
/// - **Bounded.** A calendar range is capped at 14 days, a Spotlight query at 50
///   results and 5 seconds, a location fix at 8 seconds, an utterance at 500
///   characters. Every one of these is a limit on what one app can make the
///   shell hold in memory or wait for; without them a typo in a demo app is a
///   hung notch.
/// - **Cached where the cost is physical.** A location fix spins the radios, and
///   a weather app polling every thirty seconds must not do that thirty times an
///   hour, so a fix is reused for 60 s.
/// - **Always answered.** Every failure path — denial, timeout, no facade at all
///   — produces a `CapabilityError` with a sentence, because the app is awaiting
///   a Promise and a silent drop only moves the failure to the host's timeout
///   with a worse message.
@MainActor
public final class PlatformExecutor {
    /// A range longer than this is clamped, not refused: an app asking for "the
    /// next month" gets a fortnight of events rather than an error, and the cap
    /// is what stops one call from materializing a year of a busy calendar into
    /// a single socket frame.
    public static let maxCalendarDays = 14
    /// The default window when the app names neither end.
    public static let defaultCalendarHours = 24
    public static let maxSpotlightResults = 50
    public static let maxSpeechCharacters = 500

    private let calendar: CalendarProviding?
    private let workspace: WorkspaceProbing?
    private let location: LocationProviding?
    private let spotlight: SpotlightSearching?
    private let audio: AudioControlling?
    private let speech: SpeechSynthesizing?

    private let spotlightTimeout: TimeInterval
    private let locationTimeout: TimeInterval
    private let locationCacheSeconds: TimeInterval
    private let now: @Sendable () -> Date

    /// The last fix and when it was taken, so a polling app does not spin the
    /// radios once per poll.
    private var cachedFix: (fix: LocationFix, taken: Date)?

    /// Open requests, so a timeout and a late answer cannot both settle one
    /// Promise. Kept here rather than in a captured box because this class is
    /// already the main-actor-isolated owner of the state.
    private var open: Set<Int> = []
    private var nextToken = 0

    public init(
        calendar: CalendarProviding? = nil,
        workspace: WorkspaceProbing? = nil,
        location: LocationProviding? = nil,
        spotlight: SpotlightSearching? = nil,
        audio: AudioControlling? = nil,
        speech: SpeechSynthesizing? = nil,
        spotlightTimeout: TimeInterval = 5,
        locationTimeout: TimeInterval = 8,
        locationCacheSeconds: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.calendar = calendar
        self.workspace = workspace
        self.location = location
        self.spotlight = spotlight
        self.audio = audio
        self.speech = speech
        self.spotlightTimeout = spotlightTimeout
        self.locationTimeout = locationTimeout
        self.locationCacheSeconds = locationCacheSeconds
        self.now = now
    }

    /// Run one call. `observe`/`unobserve` never arrive here — they are registry
    /// verbs, answered synchronously by `PlatformObserver`.
    public func run(_ call: PlatformCall, completion: @escaping PlatformCompletion) {
        switch call {
        case .observe, .unobserve:
            completion(.failure(CapabilityError("observe verbs are handled by the observer registry")))
        case let .calendar(from, to):
            runCalendar(from: from, to: to, completion: completion)
        case .workspace:
            runWorkspace(completion: completion)
        case .location:
            runLocation(completion: completion)
        case let .spotlight(query, scopes):
            runSpotlight(query: query, scopes: scopes, completion: completion)
        case .audio:
            runAudio(completion: completion)
        case let .setVolume(value):
            runSetVolume(value, completion: completion)
        case let .speak(text, voice, rate):
            runSpeak(text: text, voice: voice, rate: rate, completion: completion)
        }
    }

    // MARK: - calendar

    private func runCalendar(from: String?, to: String?, completion: @escaping PlatformCompletion) {
        guard let calendar else {
            completion(.failure(CapabilityError("this shell has no calendar capability")))
            return
        }
        let range: (start: Date, end: Date)
        switch Self.calendarRange(from: from, to: to, now: now())
        {
        case let .success(value): range = value
        case let .failure(error):
            completion(.failure(error))
            return
        }
        // Access first, always: a denial must not still read the store, and the
        // grant is remembered by the facade so this is one prompt, not one per
        // poll.
        calendar.requestAccess { access in
            if case let .failure(error) = access {
                completion(.failure(error))
                return
            }
            calendar.events(from: range.start, to: range.end) { result in
                switch result {
                case let .success(events):
                    completion(.success(.array(events.map(Self.json(event:)))))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Range resolution, split out because it is the whole of the calendar
    /// call's policy and the only part worth asserting on.
    static func calendarRange(
        from: String?,
        to: String?,
        now: Date
    ) -> Result<(start: Date, end: Date), CapabilityError> {
        let start: Date
        if let from {
            guard let parsed = parseISO(from) else {
                return .failure(CapabilityError("calendar `from` is not an ISO-8601 date: '\(from)'"))
            }
            start = parsed
        } else {
            start = now
        }
        var end: Date
        if let to {
            guard let parsed = parseISO(to) else {
                return .failure(CapabilityError("calendar `to` is not an ISO-8601 date: '\(to)'"))
            }
            end = parsed
        } else {
            end = start.addingTimeInterval(TimeInterval(defaultCalendarHours) * 3600)
        }
        guard end > start else {
            return .failure(CapabilityError("calendar range must end after it starts"))
        }
        let cap = start.addingTimeInterval(TimeInterval(maxCalendarDays) * 86_400)
        if end > cap { end = cap }
        return .success((start, end))
    }

    // MARK: - workspace

    private func runWorkspace(completion: @escaping PlatformCompletion) {
        guard let workspace else {
            completion(.failure(CapabilityError("this shell has no workspace capability")))
            return
        }
        completion(.success(Self.json(workspace: workspace.snapshot())))
    }

    // MARK: - location

    private func runLocation(completion: @escaping PlatformCompletion) {
        guard let location else {
            completion(.failure(CapabilityError("this shell has no location capability")))
            return
        }
        // A fix costs GPS/Wi-Fi scanning; a weather app polling every 30 s must
        // not pay for it every time.
        if let cached = cachedFix, now().timeIntervalSince(cached.taken) < locationCacheSeconds {
            completion(.success(Self.json(fix: cached.fix)))
            return
        }
        let token = begin()
        let seconds = locationTimeout
        after(seconds) { [weak self] in
            self?.settle(
                token,
                .failure(CapabilityError("location timed out after \(Int(seconds)) s")),
                completion
            )
        }
        location.requestFix { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(fix):
                cachedFix = (fix, now())
                settle(token, .success(Self.json(fix: fix)), completion)
            case let .failure(error):
                settle(token, .failure(error), completion)
            }
        }
    }

    // MARK: - spotlight

    private func runSpotlight(query: String, scopes: [String]?, completion: @escaping PlatformCompletion) {
        guard let spotlight else {
            completion(.failure(CapabilityError("this shell has no spotlight capability")))
            return
        }
        // Default scope is the user's home: the whole index would include system
        // caches and other volumes, which is never what an app meant.
        let named = (scopes ?? []).filter { !$0.isEmpty }
        let searchScopes = named.isEmpty ? [NSHomeDirectory()] : named
        let token = begin()
        let timeout = spotlightTimeout
        after(timeout) { [weak self] in
            self?.settle(
                token,
                .failure(CapabilityError("spotlight timed out after \(Int(timeout)) s")),
                completion
            )
        }
        spotlight.search(
            query: query,
            scopes: searchScopes,
            limit: Self.maxSpotlightResults,
            timeout: timeout
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(hits):
                let capped = hits.prefix(Self.maxSpotlightResults).map(Self.json(hit:))
                settle(token, .success(.array(Array(capped))), completion)
            case let .failure(error):
                settle(token, .failure(error), completion)
            }
        }
    }

    // MARK: - audio

    private func runAudio(completion: @escaping PlatformCompletion) {
        guard let audio else {
            completion(.failure(CapabilityError("this shell has no audio capability")))
            return
        }
        switch audio.snapshot() {
        case let .success(snapshot):
            completion(.success(Self.json(audio: snapshot)))
        case let .failure(error):
            completion(.failure(error))
        }
    }

    private func runSetVolume(_ value: Double, completion: @escaping PlatformCompletion) {
        guard let audio else {
            completion(.failure(CapabilityError("this shell has no audio capability")))
            return
        }
        // Clamped rather than refused: 1.2 from an app doing arithmetic means
        // "as loud as it goes", and an error there would be pedantry.
        let clamped = min(max(value, 0), 1)
        switch audio.setVolume(clamped) {
        case .success:
            // The applied value comes back so an app learns it was clamped.
            completion(.success(.object(["volume": .double(clamped)])))
        case let .failure(error):
            completion(.failure(error))
        }
    }

    // MARK: - speak

    private func runSpeak(
        text: String,
        voice: String?,
        rate: Double?,
        completion: @escaping PlatformCompletion
    ) {
        guard let speech else {
            completion(.failure(CapabilityError("this shell has no speech capability")))
            return
        }
        guard text.count <= Self.maxSpeechCharacters else {
            completion(.failure(CapabilityError(
                "speak text is \(text.count) characters; the limit is \(Self.maxSpeechCharacters)"
            )))
            return
        }
        speech.speak(text: text, voice: voice, rate: rate) { result in
            switch result {
            case .success: completion(.success(nil))
            case let .failure(error): completion(.failure(error))
            }
        }
    }

    // MARK: - One-shot settlement

    private func begin() -> Int {
        nextToken += 1
        open.insert(nextToken)
        return nextToken
    }

    private func settle(
        _ token: Int,
        _ result: Result<JSONValue?, CapabilityError>,
        _ completion: PlatformCompletion
    ) {
        // Whichever of (answer, timeout) is first wins; the other is dropped,
        // because settling a Promise twice is worse than settling it late.
        guard open.remove(token) != nil else { return }
        completion(result)
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            work()
        }
    }

    // MARK: - JSON shapes (see `PlatformSnapshotJSON`)

    static func json(event: CalendarEvent) -> JSONValue { PlatformSnapshotJSON.event(event) }
    static func json(workspace: WorkspaceSnapshot) -> JSONValue { PlatformSnapshotJSON.workspace(workspace) }
    static func json(fix: LocationFix) -> JSONValue { PlatformSnapshotJSON.fix(fix) }
    static func json(hit: SpotlightHit) -> JSONValue { PlatformSnapshotJSON.hit(hit) }
    static func json(audio: AudioSnapshot) -> JSONValue { PlatformSnapshotJSON.audio(audio) }

    static func parseISO(_ text: String) -> Date? { PlatformSnapshotJSON.parseISO(text) }
    static func formatISO(_ date: Date) -> String { PlatformSnapshotJSON.formatISO(date) }
}

/// The wire shape of every platform payload, in one place.
///
/// Public because the `audio` observe *event* carries exactly the object the
/// `audio()` *call* returns: one shape, one parser in the app, and no chance of
/// the two drifting apart because they were written in different files.
public enum PlatformSnapshotJSON {
    public static func event(_ event: CalendarEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "title": .string(event.title),
            "start": .string(formatISO(event.start)),
            "end": .string(formatISO(event.end)),
            "allDay": .bool(event.allDay),
            "calendar": .string(event.calendar),
        ]
        if let location = event.location, !location.isEmpty {
            object["location"] = .string(location)
        }
        return .object(object)
    }

    public static func workspace(_ workspace: WorkspaceSnapshot) -> JSONValue {
        var object: [String: JSONValue] = ["idleSeconds": .double(workspace.idleSeconds)]
        if let bundleId = workspace.frontmostBundleId {
            object["frontmost"] = .object([
                "bundleId": .string(bundleId),
                "localizedName": .string(workspace.frontmostName ?? bundleId),
            ])
        }
        if let locked = workspace.screenLocked {
            object["screenLocked"] = .bool(locked)
        }
        return .object(object)
    }

    public static func fix(_ fix: LocationFix) -> JSONValue {
        .object([
            "lat": .double(fix.latitude),
            "lon": .double(fix.longitude),
            "accuracyMeters": .double(fix.accuracyMeters),
            "timestamp": .string(formatISO(fix.timestamp)),
        ])
    }

    public static func hit(_ hit: SpotlightHit) -> JSONValue {
        var object: [String: JSONValue] = [
            "path": .string(hit.path),
            "name": .string(hit.name),
            "contentType": .string(hit.contentType),
        ]
        if let modified = hit.modified {
            object["modified"] = .string(formatISO(modified))
        }
        return .object(object)
    }

    public static func audio(_ audio: AudioSnapshot) -> JSONValue {
        var object: [String: JSONValue] = [
            "deviceName": .string(audio.deviceName),
            "volume": .double(audio.volume),
            "muted": .bool(audio.muted),
            "transportType": .string(audio.transportType),
        ]
        if let battery = audio.batteryPercent {
            object["batteryPercent"] = .double(battery)
        }
        return .object(object)
    }

    // MARK: - ISO-8601

    /// Lenient on the way in (with and without fractional seconds — both are
    /// what `Date.toISOString()` and hand-written app strings produce), strict
    /// on the way out.
    public static func parseISO(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    public static func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
