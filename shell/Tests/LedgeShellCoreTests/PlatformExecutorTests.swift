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

/// The quit seam. The shipping one is `NSApp.terminate`, which would take the
/// test runner with it — which is precisely why it is a seam.
@MainActor
final class FakeQuit: ShellQuitting {
    private(set) var asked = 0
    func requestQuit() { asked += 1 }
}

/// The recorder seam (G3). The shipping one is `SystemRecorder`, which opens
/// AVFoundation devices and a Core Audio process tap — it would raise a real mic
/// prompt on the machine running the suite and record whatever was said near it.
/// **This is the entire reason `AudioRecording` lives in Core**: every rule worth
/// asserting about `ctx.record` is ownership policy in the executor, and none of
/// it needs a microphone.
///
/// `start` deliberately holds its completion open by default, because that is
/// what an unanswered TCC prompt looks like from the executor's side — and the
/// claim-before-consent rule only has a case to answer during that window.
@MainActor
final class FakeRecorder: AudioRecording {
    var unavailableReason: String?
    /// The honest answer on every machine this build runs on.
    var transcriptionUnavailableReason: String? = "transcription needs a Ledge build against the macOS 26 SDK"
    var rootBase = "/tmp/ledge-test-recordings"
    var levelsValue: RecordingLevels?

    /// What `start` should answer, or nil to hold the call open (the prompt is
    /// on screen and the user has not touched it). `finishStart` settles it.
    var startResult: Result<RecordingSession, CapabilityError>?
    var stopResult: Result<RecordingStopResult, CapabilityError>?

    private(set) var starts: [(app: String, sources: [RecordingSource], format: RecordingFormat)] = []
    private(set) var stops = 0
    private var pendingStart: (@MainActor (Result<RecordingSession, CapabilityError>) -> Void)?

    var isStartPending: Bool { pendingStart != nil }

    func root(for app: String) -> URL {
        URL(fileURLWithPath: rootBase).appendingPathComponent(app)
    }

    func start(
        app: String,
        sources: [RecordingSource],
        format: RecordingFormat,
        completion: @escaping @MainActor (Result<RecordingSession, CapabilityError>) -> Void
    ) {
        starts.append((app, sources, format))
        guard let startResult else {
            pendingStart = completion
            return
        }
        completion(startResult)
    }

    /// The user answered the prompt (or the device opened). `session` nil builds
    /// one from the call that is waiting, so a test only names what it cares about.
    func finishStart(_ result: Result<RecordingSession, CapabilityError>? = nil) {
        guard let completion = pendingStart else { return }
        pendingStart = nil
        let call = starts.last
        completion(result ?? .success(RecordingSession(
            id: "s1",
            dir: root(for: call?.app ?? "?").appendingPathComponent("s1").path,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: call?.sources ?? [.mic, .system],
            format: call?.format ?? .aac
        )))
    }

    func stop(completion: @escaping @MainActor (Result<RecordingStopResult, CapabilityError>) -> Void) {
        stops += 1
        completion(stopResult ?? .success(RecordingStopResult(
            session: RecordingSession(
                id: "s1",
                dir: "\(rootBase)/scribe/s1",
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                sources: [.mic, .system],
                format: .aac
            ),
            seconds: 12.5,
            files: [.mic: "\(rootBase)/scribe/s1/mic.m4a", .system: "\(rootBase)/scribe/s1/system.m4a"]
        )))
    }

    func levels() -> RecordingLevels? { levelsValue }
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

        // Poll for the deadline to fire rather than sleeping a fixed 300 ms.
        // A fixed sleep is a race — the executor's timeout lands on a queue, and
        // under a parallel test run the sleep could finish first, which is why
        // this test failed ~50% of runs. Written inline rather than as a helper
        // because handing a non-Sendable result holder to an async function
        // trips Swift 6 isolation checking.
        var settled = false
        for _ in 0..<600 {
            if results.count == 1 { settled = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(settled)
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
        // Poll for the deadline to fire rather than sleeping a fixed 300 ms.
        // A fixed sleep is a race — the executor's timeout lands on a queue, and
        // under a parallel test run the sleep could finish first, which is why
        // this test failed ~50% of runs. Written inline rather than as a helper
        // because handing a non-Sendable result holder to an async function
        // trips Swift 6 isolation checking.
        var settled = false
        for _ in 0..<600 {
            if results.count == 1 { settled = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(settled)

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
        // Poll for the deadline to fire rather than sleeping a fixed 300 ms.
        // A fixed sleep is a race — the executor's timeout lands on a queue, and
        // under a parallel test run the sleep could finish first, which is why
        // this test failed ~50% of runs. Written inline rather than as a helper
        // because handing a non-Sendable result holder to an async function
        // trips Swift 6 isolation checking.
        var settled = false
        for _ in 0..<600 {
            if results.count == 1 { settled = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(settled)
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

    // MARK: record (ctx.record, G3)

    /// `status` is the call an app makes before it draws anything, so every
    /// field it carries is one the app is about to branch on. The interesting
    /// ones are the honest negatives: `available` with a reason when the shell
    /// cannot record at all, and a transcription gate that says why rather than
    /// half-transcribing.
    @Test("status() answers availability, this app's own root, and the transcription gate")
    func recordStatusShape() throws {
        let recorder = FakeRecorder()
        let executor = PlatformExecutor(recorder: recorder)
        let results = PlatformResults()
        executor.run(.recordStatus, app: "scribe", completion: results.completion)

        let object = try #require(results.object)
        #expect(object["available"]?.asBool == true)
        #expect(object["reason"] == nil, "an available recorder gives no reason")
        #expect(object["recording"]?.asBool == false)
        #expect(object["mine"]?.asBool == false)
        // Sessions are per-app: the root is the *asking* app's folder, which is
        // what makes one app's recordings invisible to another's session list.
        #expect(object["root"]?.asString == "/tmp/ledge-test-recordings/scribe")
        #expect(object["session"] == nil, "nothing is recording, so there is no session to describe")
        let transcription = try #require(object["transcription"]?.asObject)
        #expect(transcription["available"]?.asBool == false)
        #expect(transcription["reason"]?.asString == "transcription needs a Ledge build against the macOS 26 SDK")

        // A shell that cannot record says so in the same shape rather than
        // failing the call: the app still has a root to list past sessions from.
        recorder.unavailableReason = "microphone access was denied"
        executor.run(.recordStatus, app: "scribe", completion: results.completion)
        #expect(results.object?["available"]?.asBool == false)
        #expect(results.object?["reason"]?.asString == "microphone access was denied")
    }

    /// **The claim happens before the facade answers**, and this is the case it
    /// exists for: `start` blocks on the mic's TCC prompt, which can sit on
    /// screen for as long as the user ignores it. A second app asking during
    /// that window must be refused by name, not raced into a second stream on
    /// hardware that only has one.
    @Test("A start claims the recorder before the prompt is answered, so a second app is refused")
    func recordStartClaimsBeforeConsent() {
        let recorder = FakeRecorder()      // holds `start` open: the prompt is up
        let executor = PlatformExecutor(recorder: recorder)
        let results = PlatformResults()

        executor.run(.recordStart(sources: [.mic, .system], format: .aac), app: "scribe", completion: results.completion)
        #expect(results.count == 0, "the call is still waiting on the user")
        #expect(recorder.isStartPending)
        #expect(executor.recordingOwner == "scribe", "claimed on the way in, not on the way back")

        executor.run(.recordStart(sources: [.mic], format: .wav), app: "dictaphone", completion: results.completion)
        #expect(results.error == "already recording for 'scribe'")
        #expect(recorder.starts.count == 1, "the second ask never reached the hardware")

        // And when the user finally says yes, the first call — and only it —
        // settles, in the documented shape.
        recorder.finishStart()
        #expect(results.count == 2)
        let session = results.object
        #expect(session?["id"]?.asString == "s1")
        #expect(session?["dir"]?.asString == "/tmp/ledge-test-recordings/scribe/s1")
        #expect(session?["startedAt"]?.asString == "2027-01-15T08:00:00Z")
        #expect(session?["sources"]?.asArray?.compactMap(\.asString) == ["mic", "system"])
        #expect(session?["format"]?.asString == "aac")
    }

    /// A refused prompt has to give the claim back. Otherwise one denial locks
    /// the recorder for the life of the process and every later start — from any
    /// app — reports a recording that is not happening.
    @Test("A facade start that fails releases the claim rather than wedging the recorder")
    func recordStartFailureReleasesTheClaim() {
        let recorder = FakeRecorder()
        let executor = PlatformExecutor(recorder: recorder)
        let results = PlatformResults()

        executor.run(.recordStart(sources: [.mic], format: .aac), app: "scribe", completion: results.completion)
        #expect(executor.recordingOwner == "scribe")
        recorder.finishStart(.failure(CapabilityError("microphone access was denied")))
        #expect(results.error == "microphone access was denied")
        #expect(executor.recordingOwner == nil, "a denial must not hold the recorder hostage")

        // Proof that it is genuinely free: the next start goes through.
        recorder.startResult = .success(RecordingSession(
            id: "s2",
            dir: "/tmp/ledge-test-recordings/scribe/s2",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [.mic],
            format: .aac
        ))
        executor.run(.recordStart(sources: [.mic], format: .aac), app: "scribe", completion: results.completion)
        #expect(results.object?["id"]?.asString == "s2")
        #expect(executor.recordingOwner == "scribe")
    }

    /// Only the owner may stop, and the refusal names the holder — an app that
    /// cannot stop the tape can at least tell the user who can.
    @Test("Another app cannot stop this app's recording, and is told whose it is")
    func recordStopIsOwnerOnly() {
        let recorder = FakeRecorder()
        let executor = PlatformExecutor(recorder: recorder)
        let results = PlatformResults()

        // Nothing running at all is its own sentence, not an ownership error.
        executor.run(.recordStop, app: "scribe", completion: results.completion)
        #expect(results.error == "nothing is recording")

        recorder.startResult = .success(RecordingSession(
            id: "s1",
            dir: "/tmp/ledge-test-recordings/scribe/s1",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [.mic, .system],
            format: .aac
        ))
        executor.run(.recordStart(sources: [.mic, .system], format: .aac), app: "scribe", completion: results.completion)

        executor.run(.recordStop, app: "dictaphone", completion: results.completion)
        #expect(results.error == "only 'scribe' may stop this recording")
        #expect(recorder.stops == 0, "a refused stop must not close the files")
        #expect(executor.recordingOwner == "scribe")
    }

    /// The stop shape, and the fact the app depends on afterwards: the recorder
    /// is free again, so the same app can start the next session immediately.
    @Test("The owner's stop reports the files and the seconds, and frees the recorder")
    func recordStopShapeAndRelease() throws {
        let recorder = FakeRecorder()
        recorder.startResult = .success(RecordingSession(
            id: "s1",
            dir: "/tmp/ledge-test-recordings/scribe/s1",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [.mic, .system],
            format: .aac
        ))
        let executor = PlatformExecutor(recorder: recorder)
        let results = PlatformResults()
        executor.run(.recordStart(sources: [.mic, .system], format: .aac), app: "scribe", completion: results.completion)

        // While it runs, the owner's status carries the live session.
        executor.run(.recordStatus, app: "scribe", completion: results.completion)
        #expect(results.object?["recording"]?.asBool == true)
        #expect(results.object?["mine"]?.asBool == true)
        #expect(results.object?["session"]?.asObject?["id"]?.asString == "s1")

        executor.run(.recordStop, app: "scribe", completion: results.completion)
        let stopped = try #require(results.object)
        #expect(stopped["id"]?.asString == "s1")
        #expect(stopped["dir"]?.asString == "/tmp/ledge-test-recordings/scribe/s1")
        #expect(stopped["seconds"]?.asDouble == 12.5)
        // Absolute paths, keyed by source. A source that was never requested has
        // no key at all — the app reads presence, not an empty string.
        let files = try #require(stopped["files"]?.asObject)
        #expect(files["mic"]?.asString == "/tmp/ledge-test-recordings/scribe/s1/mic.m4a")
        #expect(files["system"]?.asString == "/tmp/ledge-test-recordings/scribe/s1/system.m4a")
        #expect(recorder.stops == 1)
        #expect(executor.recordingOwner == nil)

        // Free means free: the next session starts without a restart.
        executor.run(.recordStart(sources: [.mic], format: .wav), app: "scribe", completion: results.completion)
        #expect(executor.recordingOwner == "scribe")
        #expect(recorder.starts.count == 2)
    }

    /// A second app asking for status while someone else records learns that a
    /// recording is happening — enough to say "Scribe is recording" — and
    /// nothing about it. `mine` false means no session object, so one app's
    /// session directory never reaches another's process.
    @Test("A bystander app sees `recording` but never the session itself")
    func recordStatusForABystander() throws {
        let recorder = FakeRecorder()
        recorder.startResult = .success(RecordingSession(
            id: "s1",
            dir: "/tmp/ledge-test-recordings/scribe/s1",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [.mic],
            format: .aac
        ))
        let executor = PlatformExecutor(recorder: recorder)
        let results = PlatformResults()
        executor.run(.recordStart(sources: [.mic], format: .aac), app: "scribe", completion: results.completion)

        executor.run(.recordStatus, app: "notes", completion: results.completion)
        let object = try #require(results.object)
        #expect(object["recording"]?.asBool == true)
        #expect(object["mine"]?.asBool == false)
        #expect(object["session"] == nil, "another app's session dir is not this app's business")
        #expect(object["root"]?.asString == "/tmp/ledge-test-recordings/notes")
    }

    /// The meters are the owner's, for the same reason the stop is: `levels` is
    /// a live read of what the microphone is hearing right now, which is the
    /// single most sensitive thing this capability produces.
    @Test("levels() answers the owner and refuses everyone else")
    func recordLevelsAreOwnerOnly() throws {
        let recorder = FakeRecorder()
        recorder.startResult = .success(RecordingSession(
            id: "s1",
            dir: "/tmp/ledge-test-recordings/scribe/s1",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [.mic],
            format: .aac
        ))
        recorder.levelsValue = RecordingLevels(mic: 0.42, system: nil, seconds: 7.25)
        let executor = PlatformExecutor(recorder: recorder)
        let results = PlatformResults()

        // Before anything runs there is nothing to meter.
        executor.run(.recordLevels, app: "scribe", completion: results.completion)
        #expect(results.error == "nothing is recording")

        executor.run(.recordStart(sources: [.mic], format: .aac), app: "scribe", completion: results.completion)
        executor.run(.recordLevels, app: "scribe", completion: results.completion)
        let levels = try #require(results.object)
        #expect(levels["mic"]?.asDouble == 0.42)
        #expect(levels["system"] == nil, "a source not in the session has no key")
        // `seconds` rides along so the app's elapsed clock is the recorder's,
        // not its own drifting copy between polls.
        #expect(levels["seconds"]?.asDouble == 7.25)

        executor.run(.recordLevels, app: "notes", completion: results.completion)
        #expect(results.error == "nothing is recording", "a bystander is told nothing about the meters")
    }

    /// The snapshot replay and any build without `SystemRecorder` behind it. An
    /// app awaiting `ctx.record.status()` there gets a sentence, not a timeout.
    @Test("A shell with no recorder answers all four verbs instead of hanging")
    func recordWithoutAFacade() {
        let executor = PlatformExecutor()
        let results = PlatformResults()
        for call in [PlatformCall.recordStatus, .recordStart(sources: [.mic], format: .aac),
                     .recordStop, .recordLevels] {
            executor.run(call, app: "scribe", completion: results.completion)
        }
        #expect(results.count == 4)
        #expect(results.settled.allSatisfy { result in
            guard case let .failure(error) = result else { return false }
            return error.message == "this shell has no recording capability"
        })
        #expect(executor.recordingOwner == nil)
    }

    /// The runaway bound, stated once. Six hours is longer than any meeting and
    /// short enough that a worker that died with the tape rolling cannot fill a
    /// disk overnight — the cap is not a timeout on the *call*, it is a ceiling
    /// on the session.
    @Test("The runaway cap is six hours")
    func recordCap() {
        #expect(PlatformExecutor.maxRecordingSeconds == 6 * 3600)
    }

    // MARK: quit

    @Test("Quit answers before it ends the process, so the reply gets out")
    func quitAnswersFirst() {
        let quit = FakeQuit()
        let executor = PlatformExecutor(quit: quit)
        let results = PlatformResults()
        executor.run(.quit, completion: results.completion)

        // Order is the whole point: the app is awaiting a Promise, and the
        // socket that carries the reply dies with the process. The facade's
        // contract is to terminate on a later run-loop turn; the executor's is
        // to have answered by then.
        #expect(results.count == 1)
        #expect(results.settled.first?.isSuccess == true)
        #expect(results.data == nil, "a call with no answer carries no data")
        #expect(quit.asked == 1)
    }

    @Test("A shell that cannot quit says so instead of hanging")
    func quitWithoutAFacade() {
        // The snapshot replay runs a real engine with no NSApp behind it. An app
        // awaiting `ctx.platform.quit()` there gets a sentence, not a timeout.
        let executor = PlatformExecutor()
        let results = PlatformResults()
        executor.run(.quit, completion: results.completion)
        #expect(results.error?.contains("cannot quit itself") == true)
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
