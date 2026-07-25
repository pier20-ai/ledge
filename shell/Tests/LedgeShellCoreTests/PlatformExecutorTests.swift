import Foundation
import Testing
@testable import LedgeShellCore

// MARK: - Fakes

/// Where the completions land. A plain local `var` cannot be captured by a
/// `@Sendable` completion, and the box being main-actor-isolated is the same
/// guarantee the executor itself runs under.
@MainActor
final class PlatformResults {
    private(set) var settled: [Result<JSONValue?, CapabilityError>] = []

    var completion: PlatformCompletion {
        { [weak self] result in self?.settled.append(result) }
    }

    var count: Int { settled.count }
    var data: JSONValue? {
        guard case let .success(value) = settled.last else { return nil }
        return value
    }

    var object: [String: JSONValue]? { data?.asObject }
    var array: [JSONValue]? { data?.asArray }

    var error: String? {
        guard case let .failure(error) = settled.last else { return nil }
        return error.message
    }
}

/// A clock the test can wind forward. The executor only ever reads it from the
/// main actor (it is main-actor-isolated itself), so `assumeIsolated` is an
/// assertion of that fact rather than a workaround.
@MainActor
final class FakeClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    nonisolated var read: @Sendable () -> Date {
        { MainActor.assumeIsolated { self.now } }
    }
}

@MainActor
final class FakeCalendar: CalendarProviding {
    var access: Result<Void, CapabilityError> = .success(())
    var events: [CalendarEvent] = []
    private(set) var requestedFrom: Date?
    private(set) var requestedTo: Date?
    private(set) var accessCalls = 0

    func requestAccess(_ completion: @escaping @MainActor @Sendable (Result<Void, CapabilityError>) -> Void) {
        accessCalls += 1
        completion(access)
    }

    func events(
        from: Date,
        to: Date,
        completion: @escaping @MainActor @Sendable (Result<[CalendarEvent], CapabilityError>) -> Void
    ) {
        requestedFrom = from
        requestedTo = to
        completion(.success(events))
    }
}

@MainActor
final class FakeWorkspaceProbe: WorkspaceProbing {
    var value = WorkspaceSnapshot()
    func snapshot() -> WorkspaceSnapshot { value }
}

@MainActor
final class FakeLocation: LocationProviding {
    /// nil holds the request open — what an unanswered TCC prompt looks like.
    var result: Result<LocationFix, CapabilityError>?
    private(set) var calls = 0

    func requestFix(_ completion: @escaping @MainActor @Sendable (Result<LocationFix, CapabilityError>) -> Void) {
        calls += 1
        if let result { completion(result) }
    }
}

@MainActor
final class FakeSpotlight: SpotlightSearching {
    /// nil holds the query open — an index that never finishes gathering.
    var result: Result<[SpotlightHit], CapabilityError>?
    private(set) var lastScopes: [String] = []
    private(set) var lastLimit = 0

    func search(
        query: String,
        scopes: [String],
        limit: Int,
        timeout: TimeInterval,
        completion: @escaping @MainActor @Sendable (Result<[SpotlightHit], CapabilityError>) -> Void
    ) {
        lastScopes = scopes
        lastLimit = limit
        if let result { completion(result) }
    }
}

@MainActor
final class FakeAudio: AudioControlling {
    var state = AudioSnapshot(deviceName: "Speakers", volume: 0.3, muted: false, transportType: "builtIn")
    var readResult: Result<AudioSnapshot, CapabilityError>?
    var writeResult: Result<Void, CapabilityError> = .success(())
    private(set) var written: [Double] = []

    func snapshot() -> Result<AudioSnapshot, CapabilityError> { readResult ?? .success(state) }

    func setVolume(_ value: Double) -> Result<Void, CapabilityError> {
        written.append(value)
        return writeResult
    }
}

@MainActor
final class FakeSpeech: SpeechSynthesizing {
    private(set) var spoken: [(text: String, voice: String?, rate: Double?)] = []
    private var pending: [@MainActor @Sendable (Result<Void, CapabilityError>) -> Void] = []

    func speak(
        text: String,
        voice: String?,
        rate: Double?,
        completion: @escaping @MainActor @Sendable (Result<Void, CapabilityError>) -> Void
    ) {
        // The shipping synthesizer settles the utterance it is replacing before
        // it starts the new one; the fake does the same so the *executor's* view
        // of "one at a time" is what is under test.
        finishAll()
        spoken.append((text, voice, rate))
        pending.append(completion)
    }

    /// The utterance ran to the end.
    func finishAll() {
        let waiting = pending
        pending.removeAll()
        for completion in waiting { completion(.success(())) }
    }

    var isSpeaking: Bool { !pending.isEmpty }
}

// MARK: - Tests

/// The request/reply half of `ctx.platform` (spec §6 extension).
///
/// Nothing below touches EventKit, CoreLocation, CoreAudio, Spotlight or a
/// speaker: every one of those is a one-method facade, and what these tests are
/// for is the policy *around* them — the range cap, the result cap, the
/// deadlines, the clamp, the cache, the replacement rule, and the JSON shape an
/// app actually parses.
@MainActor
@Suite("Platform calls (spec §6 extension)")
struct PlatformExecutorTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z

    // MARK: calendar

    @Test("The default range is the next 24 hours")
    func calendarDefaultRange() throws {
        let calendar = FakeCalendar()
        let executor = PlatformExecutor(calendar: calendar, now: { [epoch] in epoch })
        let results = PlatformResults()
        executor.run(.calendar(from: nil, to: nil), completion: results.completion)

        #expect(calendar.requestedFrom == epoch)
        #expect(calendar.requestedTo == epoch.addingTimeInterval(86_400))
        #expect(results.array?.isEmpty == true)
    }

    @Test("A range longer than a fortnight is clamped, not refused")
    func calendarCap() throws {
        // Clamped rather than refused because "the next month" is a reasonable
        // thing to ask for and an error would be pedantry — but a year of a busy
        // calendar in one socket frame is not something one app gets to do.
        let range = try #require(try? PlatformExecutor.calendarRange(
            from: "2027-01-15T08:00:00Z",
            to: "2027-06-15T08:00:00Z",
            now: epoch
        ).get())
        #expect(range.end.timeIntervalSince(range.start) == 14 * 86_400)
    }

    @Test("A malformed or inverted range is an error, not a guess")
    func calendarBadRange() {
        #expect(PlatformExecutor.calendarRange(from: "yesterday", to: nil, now: epoch).isFailure)
        #expect(PlatformExecutor.calendarRange(
            from: "2027-01-15T08:00:00Z",
            to: "2027-01-14T08:00:00Z",
            now: epoch
        ).isFailure)
        // Fractional seconds are what `Date.toISOString()` produces, so both
        // spellings have to parse or half the apps written against this fail.
        #expect(PlatformExecutor.calendarRange(from: "2027-01-15T08:00:00.000Z", to: nil, now: epoch).isSuccess)
    }

    @Test("Events come back in the documented shape; an absent location stays absent")
    func calendarShape() throws {
        let calendar = FakeCalendar()
        calendar.events = [
            CalendarEvent(
                title: "Standup",
                start: epoch,
                end: epoch.addingTimeInterval(900),
                allDay: false,
                calendar: "Work"
            ),
            CalendarEvent(
                title: "Offsite",
                start: epoch,
                end: epoch.addingTimeInterval(86_400),
                allDay: true,
                calendar: "Personal",
                location: "Studio"
            ),
        ]
        let executor = PlatformExecutor(calendar: calendar, now: { [epoch] in epoch })
        let results = PlatformResults()
        executor.run(.calendar(from: nil, to: nil), completion: results.completion)

        let events = try #require(results.array)
        #expect(events.count == 2)
        let first = try #require(events[0].asObject)
        #expect(first["title"]?.asString == "Standup")
        #expect(first["allDay"]?.asBool == false)
        #expect(first["calendar"]?.asString == "Work")
        #expect(first["location"] == nil, "an absent location must be an absent key, not a null")
        #expect(first["start"]?.asString == "2027-01-15T08:00:00Z")
        #expect(try #require(events[1].asObject)["location"]?.asString == "Studio")
    }

    @Test("A denied calendar prompt is an error sentence, never a crash and never a hang")
    func calendarDenied() {
        let calendar = FakeCalendar()
        calendar.access = .failure(CapabilityError("calendar access was refused"))
        let executor = PlatformExecutor(calendar: calendar, now: { [epoch] in epoch })
        let results = PlatformResults()
        executor.run(.calendar(from: nil, to: nil), completion: results.completion)

        #expect(results.count == 1)
        #expect(results.error?.contains("refused") == true)
        #expect(calendar.requestedFrom == nil, "a denial must not still read the store")
    }

    @Test("A shell without the facade answers rather than leaving the Promise open")
    func missingFacades() {
        let executor = PlatformExecutor()
        let results = PlatformResults()
        for call in [PlatformCall.calendar(from: nil, to: nil), .workspace, .location,
                     .spotlight(query: "x", scopes: nil), .audio, .setVolume(0.5),
                     .speak(text: "hi", voice: nil, rate: nil)] {
            executor.run(call, completion: results.completion)
        }
        #expect(results.count == 7)
        #expect(results.error?.isEmpty == false)
    }

    // MARK: workspace

    @Test("workspace() reports the frontmost app, idle seconds and the lock state")
    func workspaceShape() throws {
        let probe = FakeWorkspaceProbe()
        probe.value = WorkspaceSnapshot(
            frontmostBundleId: "com.apple.Safari",
            frontmostName: "Safari",
            idleSeconds: 12.5,
            screenLocked: false
        )
        let executor = PlatformExecutor(workspace: probe)
        let results = PlatformResults()
        executor.run(.workspace, completion: results.completion)

        let object = try #require(results.object)
        #expect(object["idleSeconds"]?.asDouble == 12.5)
        #expect(object["screenLocked"]?.asBool == false)
        #expect(try #require(object["frontmost"]?.asObject)["bundleId"]?.asString == "com.apple.Safari")
    }

    @Test("What the shell cannot know cheaply is omitted, not invented")
    func workspaceOmissions() throws {
        let probe = FakeWorkspaceProbe()
        probe.value = WorkspaceSnapshot(idleSeconds: 0)
        let executor = PlatformExecutor(workspace: probe)
        let results = PlatformResults()
        executor.run(.workspace, completion: results.completion)

        let object = try #require(results.object)
        // A `screenLocked: false` on a machine where we do not know would be a
        // worse answer than no key at all.
        #expect(object["screenLocked"] == nil)
        #expect(object["frontmost"] == nil)
        #expect(object["idleSeconds"]?.asDouble == 0)
    }

    // MARK: location

    @Test("A fix is cached for 60 s so a polling app does not spin the radios")
    func locationCache() throws {
        let provider = FakeLocation()
        provider.result = .success(LocationFix(
            latitude: 37.77, longitude: -122.41, accuracyMeters: 1200, timestamp: epoch
        ))
        let clock = FakeClock(epoch)
        let executor = PlatformExecutor(location: provider, now: clock.read)
        let results = PlatformResults()

        executor.run(.location, completion: results.completion)
        #expect(provider.calls == 1)
        #expect(try #require(results.object)["lat"]?.asDouble == 37.77)

        clock.now = epoch.addingTimeInterval(30)
        executor.run(.location, completion: results.completion)
        #expect(provider.calls == 1, "a fix 30 s old is the same fix")

        clock.now = epoch.addingTimeInterval(61)
        executor.run(.location, completion: results.completion)
        #expect(provider.calls == 2)
        #expect(results.count == 3)
    }

    @Test("A refused location prompt rejects with a sentence")
    func locationDenied() {
        let provider = FakeLocation()
        provider.result = .failure(CapabilityError(
            "location access was refused in System Settings › Privacy & Security › Location Services"
        ))
        let executor = PlatformExecutor(location: provider, now: { [epoch] in epoch })
        let results = PlatformResults()
        executor.run(.location, completion: results.completion)
        #expect(results.error?.contains("refused") == true)
    }

    @Test("An unanswered prompt times out rather than hanging forever")
    func locationTimeout() async {
        // The fake never calls back — which is exactly what a TCC prompt nobody
        // has answered looks like from here.
        let executor = PlatformExecutor(
            location: FakeLocation(),
            locationTimeout: 0.05,
            now: { [epoch] in epoch }
        )
        let results = PlatformResults()
        executor.run(.location, completion: results.completion)
        #expect(results.count == 0)

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(results.count == 1)
        #expect(results.error?.contains("timed out") == true)
    }

    @Test("A late answer after a timeout is dropped, not delivered twice")
    func locationSettlesOnce() async {
        let provider = FakeLocation()
        let executor = PlatformExecutor(
            location: provider,
            locationTimeout: 0.05,
            now: { [epoch] in epoch }
        )
        let results = PlatformResults()
        executor.run(.location, completion: results.completion)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(results.count == 1)

        // Settling a Promise twice is worse than settling it late.
        provider.result = .success(LocationFix(latitude: 1, longitude: 2, accuracyMeters: 3, timestamp: epoch))
        provider.requestFix { _ in }
        #expect(results.count == 1)
    }

    // MARK: spotlight

    @Test("Spotlight defaults to the home directory and caps the results at 50")
    func spotlightScopeAndCap() throws {
        let spotlight = FakeSpotlight()
        spotlight.result = .success((0..<80).map {
            SpotlightHit(path: "/tmp/\($0).pdf", name: "\($0).pdf", contentType: "com.adobe.pdf")
        })
        let executor = PlatformExecutor(spotlight: spotlight)
        let results = PlatformResults()
        executor.run(.spotlight(query: "kMDItemFSName == \"*.pdf\"", scopes: nil), completion: results.completion)

        #expect(spotlight.lastScopes == [NSHomeDirectory()])
        #expect(spotlight.lastLimit == 50)
        // Capped again on the way out: a facade that ignores the limit must not
        // be able to put 80 objects on a socket.
        #expect(results.array?.count == 50)
        let first = try #require(results.array?.first?.asObject)
        #expect(first["path"]?.asString == "/tmp/0.pdf")
        #expect(first["modified"] == nil)
    }

    @Test("A malformed predicate is an error result, never an uncatchable exception")
    func spotlightMalformed() {
        let spotlight = FakeSpotlight()
        // The shipping facade uses the *failable* metadata-string parser for
        // this: `NSPredicate(format:)` raises an ObjC exception, which Swift
        // cannot catch, so one app's typo would kill every app's panel.
        spotlight.result = .failure(CapabilityError("spotlight query is not a valid metadata predicate"))
        let executor = PlatformExecutor(spotlight: spotlight)
        let results = PlatformResults()
        executor.run(.spotlight(query: "kMDItem ==== nonsense", scopes: nil), completion: results.completion)
        #expect(results.error?.contains("valid metadata predicate") == true)
    }

    @Test("A query that never finishes gathering times out")
    func spotlightTimeout() async {
        let executor = PlatformExecutor(spotlight: FakeSpotlight(), spotlightTimeout: 0.05)
        let results = PlatformResults()
        executor.run(.spotlight(query: "kMDItemFSName == \"x\"", scopes: ["/tmp"]), completion: results.completion)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(results.count == 1)
        #expect(results.error?.contains("timed out") == true)
    }

    // MARK: audio

    @Test("audio() reports the device, and omits a battery the device does not publish")
    func audioShape() throws {
        let audio = FakeAudio()
        audio.state = AudioSnapshot(
            deviceName: "AirPods Pro", volume: 0.42, muted: false,
            transportType: "bluetooth", batteryPercent: 78
        )
        let executor = PlatformExecutor(audio: audio)
        let results = PlatformResults()
        executor.run(.audio, completion: results.completion)
        var object = try #require(results.object)
        #expect(object["deviceName"]?.asString == "AirPods Pro")
        #expect(object["transportType"]?.asString == "bluetooth")
        #expect(object["batteryPercent"]?.asDouble == 78)

        audio.state = AudioSnapshot(deviceName: "Speakers", volume: 1, muted: true, transportType: "builtIn")
        executor.run(.audio, completion: results.completion)
        object = try #require(results.object)
        // Absent means "this device does not say", which is not the same as 0.
        #expect(object["batteryPercent"] == nil)
        #expect(object["muted"]?.asBool == true)
    }

    @Test("setVolume clamps to 0…1 and reports what it applied")
    func setVolumeClamp() throws {
        let audio = FakeAudio()
        let executor = PlatformExecutor(audio: audio)
        let results = PlatformResults()

        executor.run(.setVolume(1.4), completion: results.completion)
        #expect(audio.written.last == 1)
        #expect(try #require(results.object)["volume"]?.asDouble == 1)

        executor.run(.setVolume(-3), completion: results.completion)
        #expect(audio.written.last == 0)
        #expect(try #require(results.object)["volume"]?.asDouble == 0)

        executor.run(.setVolume(0.25), completion: results.completion)
        #expect(audio.written == [1, 0, 0.25])
    }

    @Test("A device that refuses the write is an error, not a silent success")
    func setVolumeRefused() {
        let audio = FakeAudio()
        audio.writeResult = .failure(CapabilityError("the default output device does not allow setting its volume"))
        let executor = PlatformExecutor(audio: audio)
        let results = PlatformResults()
        executor.run(.setVolume(0.5), completion: results.completion)
        #expect(results.error?.contains("does not allow") == true)
    }

    // MARK: speak

    @Test("A second utterance replaces the first, and the first still resolves")
    func speakReplaces() {
        let speech = FakeSpeech()
        let executor = PlatformExecutor(speech: speech)
        let results = PlatformResults()

        executor.run(.speak(text: "AAPL up two percent", voice: nil, rate: nil), completion: results.completion)
        #expect(results.count == 0, "still speaking")

        executor.run(.speak(text: "AAPL up three percent", voice: "en-US", rate: 0.4), completion: results.completion)
        // Notch announcements are status, and status that queues is status that
        // lies — but the superseded call must still settle, or an app awaiting it
        // waits forever.
        #expect(results.count == 1)
        #expect(speech.spoken.map(\.text) == ["AAPL up two percent", "AAPL up three percent"])
        #expect(speech.spoken.last?.voice == "en-US")
        #expect(speech.spoken.last?.rate == 0.4)

        speech.finishAll()
        #expect(results.count == 2)
        #expect(results.settled.allSatisfy { $0.isSuccess })
    }

    @Test("Text past 500 characters is refused before it reaches the synthesizer")
    func speakCap() {
        let speech = FakeSpeech()
        let executor = PlatformExecutor(speech: speech)
        let results = PlatformResults()
        executor.run(
            .speak(text: String(repeating: "a", count: 501), voice: nil, rate: nil),
            completion: results.completion
        )
        #expect(results.error?.contains("501") == true)
        #expect(speech.spoken.isEmpty)

        executor.run(
            .speak(text: String(repeating: "a", count: 500), voice: nil, rate: nil),
            completion: results.completion
        )
        #expect(speech.spoken.count == 1, "exactly at the limit is allowed")
    }

    // MARK: routing

    @Test("The registry verbs never reach the executor")
    func observeVerbsAreNotCalls() {
        let executor = PlatformExecutor()
        let results = PlatformResults()
        executor.run(.observe(kind: "power", name: "changed"), completion: results.completion)
        // They are answered synchronously by `PlatformObserver`; arriving here at
        // all is a routing bug, and it says so rather than pretending.
        #expect(results.error?.contains("observer registry") == true)
        #expect(PlatformCall.observe(kind: "power", name: "changed").isObserveVerb)
        #expect(PlatformCall.audio.isObserveVerb == false)
    }
}
