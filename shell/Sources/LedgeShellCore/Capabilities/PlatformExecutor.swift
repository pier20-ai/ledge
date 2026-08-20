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

    /// The runaway bound on one recording (G3). Long enough for any meeting,
    /// short enough that a worker that died with the tape rolling cannot fill
    /// a disk overnight: past it the shell finalizes the session on its own.
    public static let maxRecordingSeconds: TimeInterval = 6 * 3600

    private let calendar: CalendarProviding?
    private let workspace: WorkspaceProbing?
    private let location: LocationProviding?
    private let spotlight: SpotlightSearching?
    private let audio: AudioControlling?
    private let speech: SpeechSynthesizing?
    private let quit: ShellQuitting?
    private let recorder: AudioRecording?

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
        quit: ShellQuitting? = nil,
        recorder: AudioRecording? = nil,
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
        self.quit = quit
        self.recorder = recorder
        self.spotlightTimeout = spotlightTimeout
        self.locationTimeout = locationTimeout
        self.locationCacheSeconds = locationCacheSeconds
        self.now = now
    }

    /// Run one call. `observe`/`unobserve` never arrive here — they are registry
    /// verbs, answered synchronously by `PlatformObserver`.
    ///
    /// `app` is who is asking. Only the record family reads it — recording is
    /// the first call with *ownership* (one recording, stoppable only by the
    /// app that started it), and ownership needs to know whose hand is on the
    /// button. Everything else stays app-blind on purpose.
    public func run(_ call: PlatformCall, app: String = "", completion: @escaping PlatformCompletion) {
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
        case .recordStatus:
            runRecordStatus(app: app, completion: completion)
        case let .recordStart(sources, format):
            runRecordStart(app: app, sources: sources, format: format, completion: completion)
        case .recordStop:
            runRecordStop(app: app, completion: completion)
        case .recordLevels:
            runRecordLevels(app: app, completion: completion)
        case .quit:
            runQuit(completion: completion)
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

    // MARK: - record (ctx.record, G3)

    /// Who holds the live recording, or nil. Public because the shell's global
    /// hotkey wants to land on the app whose tape is rolling.
    public private(set) var recordingOwner: String?
    /// The live session, kept here so `status` can describe it without asking
    /// the facade to remember anything but its files.
    private var recordingSession: RecordingSession?
    /// Bumped on every stop so the runaway-cap task from an old session can
    /// recognize itself as stale instead of stopping the next one.
    private var recordingGeneration = 0

    private func runRecordStatus(app: String, completion: @escaping PlatformCompletion) {
        guard let recorder else {
            completion(.failure(CapabilityError("this shell has no recording capability")))
            return
        }
        let mine = recordingOwner == app && recordingSession != nil
        var object: [String: JSONValue] = [
            "available": .bool(recorder.unavailableReason == nil),
            "recording": .bool(recordingOwner != nil),
            "mine": .bool(mine),
            "root": .string(recorder.root(for: app).path),
        ]
        if let reason = recorder.unavailableReason {
            object["reason"] = .string(reason)
        }
        if mine, let session = recordingSession {
            object["session"] = Self.json(session: session)
        }
        var transcription: [String: JSONValue] = [
            "available": .bool(recorder.transcriptionUnavailableReason == nil),
        ]
        if let reason = recorder.transcriptionUnavailableReason {
            transcription["reason"] = .string(reason)
        }
        object["transcription"] = .object(transcription)
        completion(.success(.object(object)))
    }

    private func runRecordStart(
        app: String,
        sources: [RecordingSource],
        format: RecordingFormat,
        completion: @escaping PlatformCompletion
    ) {
        guard let recorder else {
            completion(.failure(CapabilityError("this shell has no recording capability")))
            return
        }
        if let reason = recorder.unavailableReason {
            completion(.failure(CapabilityError(reason)))
            return
        }
        // One recording at a time, globally: the microphone and the system tap
        // are hardware, and two owners would be two apps believing they own
        // one stream. The refusal names the holder so the app can say so.
        guard recordingOwner == nil else {
            completion(.failure(CapabilityError("already recording for '\(recordingOwner ?? "?")'")))
            return
        }
        // Claim BEFORE the facade answers: start waits on a TCC prompt, and a
        // second app asking during the prompt must be refused, not raced.
        recordingOwner = app
        recorder.start(app: app, sources: sources, format: format) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(session):
                recordingSession = session
                armRecordingCap()
                completion(.success(Self.json(session: session)))
            case let .failure(error):
                recordingOwner = nil
                completion(.failure(error))
            }
        }
    }

    private func runRecordStop(app: String, completion: @escaping PlatformCompletion) {
        guard let recorder else {
            completion(.failure(CapabilityError("this shell has no recording capability")))
            return
        }
        guard let owner = recordingOwner else {
            completion(.failure(CapabilityError("nothing is recording")))
            return
        }
        guard owner == app else {
            completion(.failure(CapabilityError("only '\(owner)' may stop this recording")))
            return
        }
        finalizeRecording(with: recorder) { result in
            switch result {
            case let .success(stopped):
                var files: [String: JSONValue] = [:]
                for (source, path) in stopped.files { files[source.rawValue] = .string(path) }
                completion(.success(.object([
                    "id": .string(stopped.session.id),
                    "dir": .string(stopped.session.dir),
                    "seconds": .double(stopped.seconds),
                    "files": .object(files),
                ])))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    private func runRecordLevels(app: String, completion: @escaping PlatformCompletion) {
        guard let recorder else {
            completion(.failure(CapabilityError("this shell has no recording capability")))
            return
        }
        guard recordingOwner == app, let levels = recorder.levels() else {
            completion(.failure(CapabilityError("nothing is recording")))
            return
        }
        var object: [String: JSONValue] = ["seconds": .double(levels.seconds)]
        if let mic = levels.mic { object["mic"] = .double(mic) }
        if let system = levels.system { object["system"] = .double(system) }
        completion(.success(.object(object)))
    }

    /// Stop through one door, whoever asked: the app, or the runaway cap.
    private func finalizeRecording(
        with recorder: AudioRecording,
        completion: @escaping @MainActor (Result<RecordingStopResult, CapabilityError>) -> Void
    ) {
        recordingOwner = nil
        recordingSession = nil
        recordingGeneration += 1
        recorder.stop(completion: completion)
    }

    /// A worker can die with the tape rolling — deliberately, the shell keeps
    /// recording so a crashed recorder loses nothing and re-adopts on restart
    /// (`status` answers `mine: true`). The cap is what bounds the case where
    /// nothing ever comes back.
    private func armRecordingCap() {
        let generation = recordingGeneration
        after(Self.maxRecordingSeconds) { [weak self] in
            guard let self, recordingGeneration == generation, let recorder else { return }
            finalizeRecording(with: recorder) { _ in }
        }
    }

    static func json(session: RecordingSession) -> JSONValue {
        .object([
            "id": .string(session.id),
            "dir": .string(session.dir),
            "startedAt": .string(formatISO(session.startedAt)),
            "sources": .array(session.sources.map { .string($0.rawValue) }),
            "format": .string(session.format.rawValue),
        ])
    }

    // MARK: - quit

    /// Answer FIRST, then end the process.
    ///
    /// The completion is what puts the `ok` on the socket, and the app on the
    /// other end is awaiting it. Terminating inside this call would tear the
    /// socket down with a reply still in a buffer, so the facade is required to
    /// terminate on a later run-loop turn — which also makes "did the button
    /// work" observable in a test that never actually quits.
    private func runQuit(completion: @escaping PlatformCompletion) {
        guard let quit else {
            completion(.failure(CapabilityError("this shell cannot quit itself")))
            return
        }
        completion(.success(nil))
        quit.requestQuit()
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
