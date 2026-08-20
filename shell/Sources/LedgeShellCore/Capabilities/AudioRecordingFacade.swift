import Foundation

/// What `ctx.record` records from. Two sources, deliberately: the microphone
/// is the user and the system tap is everyone else, which is what makes
/// two-party diarization a fact of the file layout instead of an ML problem.
public enum RecordingSource: String, Sendable, CaseIterable, Comparable {
    case mic
    case system

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The container the session's files are written in. AAC is the default —
/// an hour of meeting per few dozen megabytes. WAV exists for apps that want
/// to *read* the samples back in the worker (pitch tracking, a mantra
/// teacher): PCM needs no decoder on the JS side.
public enum RecordingFormat: String, Sendable {
    case aac
    case wav

    /// The file extension a source's file gets.
    public var fileExtension: String {
        switch self {
        case .aac: "m4a"
        case .wav: "wav"
        }
    }
}

/// One live (or just-finished) recording session, as the executor and the
/// wire both describe it. `dir` is the session's own folder; everything the
/// session produces — audio, `meta.json`, whatever the app adds (jots) —
/// lives inside it, so deleting the folder deletes the session whole.
public struct RecordingSession: Sendable, Equatable {
    public var id: String
    public var dir: String
    public var startedAt: Date
    public var sources: [RecordingSource]
    public var format: RecordingFormat

    public init(id: String, dir: String, startedAt: Date, sources: [RecordingSource], format: RecordingFormat) {
        self.id = id
        self.dir = dir
        self.startedAt = startedAt
        self.sources = sources
        self.format = format
    }
}

/// A finished session: how long it ran and where each source's file landed
/// (absolute paths; a source that was not requested has no entry).
public struct RecordingStopResult: Sendable, Equatable {
    public var session: RecordingSession
    public var seconds: Double
    public var files: [RecordingSource: String]

    public init(session: RecordingSession, seconds: Double, files: [RecordingSource: String]) {
        self.session = session
        self.seconds = seconds
        self.files = files
    }
}

/// One reading of the meters, 0…1 RMS per live source. `seconds` rides along
/// so an app's elapsed clock is the recorder's, not its own drifting copy.
public struct RecordingLevels: Sendable, Equatable {
    public var mic: Double?
    public var system: Double?
    public var seconds: Double

    public init(mic: Double?, system: Double?, seconds: Double) {
        self.mic = mic
        self.system = system
        self.seconds = seconds
    }
}

/// The mechanism half of `ctx.record`: files, devices, meters. All the policy
/// — one recording at a time, who may stop it, the runaway cap — lives in
/// `PlatformExecutor`, so a test can fake this protocol and still exercise
/// every rule the app will actually meet.
@MainActor
public protocol AudioRecording: AnyObject {
    /// nil when this process can record; a sentence for the app when it cannot.
    var unavailableReason: String? { get }
    /// Whether this build can transcribe at all, and why not when it cannot.
    /// (The macOS 26 `SpeechAnalyzer` is the long-form engine; a build against
    /// an older SDK reports the gap honestly instead of half-transcribing.)
    var transcriptionUnavailableReason: String? { get }
    /// Where app `app`'s sessions land. Creating nothing — status() must be
    /// able to answer for an app that never recorded.
    func root(for app: String) -> URL
    /// Start one session. The facade creates the directory, opens the files,
    /// and asks the OS for whatever consent it needs (the completion can wait
    /// on a TCC prompt).
    func start(
        app: String,
        sources: [RecordingSource],
        format: RecordingFormat,
        completion: @escaping @MainActor (Result<RecordingSession, CapabilityError>) -> Void
    )
    /// Finalize the live session: close files, write `meta.json`.
    func stop(completion: @escaping @MainActor (Result<RecordingStopResult, CapabilityError>) -> Void)
    /// The meters, or nil when nothing is recording.
    func levels() -> RecordingLevels?
}
