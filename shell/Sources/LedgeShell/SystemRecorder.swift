import AVFoundation
import CoreAudio
import Foundation
import LedgeShellCore

/// The mechanism behind `ctx.record` (G3): the microphone through
/// `AVAudioRecorder`, everyone else through a Core Audio **process tap**
/// (macOS 14.2+) — the whole reason the capability lives in the shell at all.
/// Both TCC prompts (Microphone; System Audio Recording) are attributed to
/// this process, which is the one with a face.
///
/// The two streams stay two files on purpose: the mic is the user and the tap
/// is everyone else, so two-party diarization is a property of the file
/// layout. (Without headphones the mic also hears the speakers — "separable",
/// not "clean" — which is a transcription-time dedupe, never a promise the UI
/// makes.)
///
/// Threading: this class is main-actor; the tap's IO callback is a CoreAudio
/// realtime thread. Everything that thread touches lives in `TapWriter`,
/// which is locked and never blocks on anything but its own lock and the
/// file write.
@MainActor
final class SystemRecorder: AudioRecording {
    /// Where sessions land: `<root>/<app>/<id>/`. The env seam is for dev
    /// shells and suites; the default is the honest place for user data —
    /// recordings are megabytes, and "beside the app" was the alarms.json
    /// lesson at a thousand times the size.
    private let rootDir: URL

    private var live: LiveSession?

    init(root: URL? = nil) {
        if let root {
            rootDir = root
        } else if let env = ProcessInfo.processInfo.environment["LEDGE_RECORDINGS_DIR"], !env.isEmpty {
            rootDir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSHomeDirectory())
            rootDir = support.appendingPathComponent("Ledge/recordings", isDirectory: true)
        }
    }

    // MARK: - AudioRecording

    var unavailableReason: String? {
        // The tap API is the floor for the whole capability: a shell that
        // could record only the mic would answer differently depending on
        // what the app asked for, and "sometimes available" is a worse
        // contract than a version floor two releases old.
        guard #available(macOS 14.2, *) else {
            return "audio capture needs macOS 14.2 or later"
        }
        return nil
    }

    var transcriptionUnavailableReason: String? {
        // `SpeechAnalyzer` (the long-form on-device engine) is macOS 26 API,
        // and this build's SDK predates it — the older per-utterance
        // recognizer would half-work on an hour of meeting, which is worse
        // than the truth. The sentence names the BUILD, not the OS, because
        // the OS got there first (the machine this runs on is Tahoe): when
        // the toolchain catches up this becomes an `#available` check
        // instead of a constant.
        "transcription needs a Ledge build against the macOS 26 SDK"
    }

    func root(for app: String) -> URL {
        rootDir.appendingPathComponent(app, isDirectory: true)
    }

    func start(
        app: String,
        sources: [RecordingSource],
        format: RecordingFormat,
        completion: @escaping @MainActor (Result<RecordingSession, CapabilityError>) -> Void
    ) {
        guard live == nil else {
            completion(.failure(CapabilityError("a recording is already running")))
            return
        }
        if let reason = unavailableReason {
            completion(.failure(CapabilityError(reason)))
            return
        }
        // The id doubles as the folder name, so it sorts by time on disk.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let id = stamp.string(from: Date())
        let dir = root(for: app).appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            completion(.failure(CapabilityError("could not create \(dir.path): \(error.localizedDescription)")))
            return
        }
        let session = RecordingSession(
            id: id, dir: dir.path, startedAt: Date(), sources: sources, format: format
        )

        // Consent first, mechanism second: the mic prompt can sit unanswered
        // for a long time, and nothing — no file, no tap — should exist until
        // the user has said yes to the part that needs asking.
        requestMicIfNeeded(sources: sources) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                try? FileManager.default.removeItem(at: dir)
                completion(.failure(CapabilityError("microphone access was denied")))
                return
            }
            do {
                live = try LiveSession(session: session, dir: dir)
                completion(.success(session))
            } catch let error as CapabilityError {
                try? FileManager.default.removeItem(at: dir)
                completion(.failure(error))
            } catch {
                try? FileManager.default.removeItem(at: dir)
                completion(.failure(CapabilityError("could not start recording: \(error.localizedDescription)")))
            }
        }
    }

    func stop(completion: @escaping @MainActor (Result<RecordingStopResult, CapabilityError>) -> Void) {
        guard let running = live else {
            completion(.failure(CapabilityError("nothing is recording")))
            return
        }
        live = nil
        completion(running.finish())
    }

    func levels() -> RecordingLevels? { live?.levels() }

    // MARK: - consent

    private func requestMicIfNeeded(sources: [RecordingSource], completion: @escaping @MainActor (Bool) -> Void) {
        guard sources.contains(.mic) else {
            completion(true)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        default:
            completion(false)
        }
    }
}

// MARK: - One live session

/// Everything a rolling recording holds: the mic recorder, the tap chain, and
/// where it all lands. Built fully or not at all — a session that got its mic
/// but not its tap tears the mic down and throws, because half a recording
/// presented as whole is the worst failure this file could have.
@MainActor
private final class LiveSession {
    let session: RecordingSession
    private let dir: URL
    private var mic: AVAudioRecorder?
    private var tap: ProcessTapCapture?

    init(session: RecordingSession, dir: URL) throws {
        self.session = session
        self.dir = dir
        do {
            if session.sources.contains(.mic) {
                let url = dir.appendingPathComponent("mic.\(session.format.fileExtension)")
                let recorder = try AVAudioRecorder(url: url, settings: Self.settings(for: session.format))
                recorder.isMeteringEnabled = true
                guard recorder.record() else {
                    throw CapabilityError("the microphone recorder would not start")
                }
                mic = recorder
            }
            if session.sources.contains(.system) {
                let url = dir.appendingPathComponent("system.\(session.format.fileExtension)")
                tap = try ProcessTapCapture(url: url, format: session.format)
            }
        } catch {
            teardown()
            throw error
        }
    }

    /// 48 kHz stereo: what the tap runs at anyway, and a mic upsampled to
    /// match means the two files share a clock for any later alignment.
    static func settings(for format: RecordingFormat) -> [String: Any] {
        switch format {
        case .aac:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .wav:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
    }

    func levels() -> RecordingLevels {
        var micLevel: Double?
        if let mic {
            mic.updateMeters()
            // dB → linear. -50 as the floor: below it the meter is noise and
            // the needle should rest, not tremble.
            let db = Double(mic.averagePower(forChannel: 0))
            micLevel = db <= -50 ? 0 : min(1, pow(10, db / 20) * 3.2)
        }
        return RecordingLevels(
            mic: micLevel,
            system: tap?.currentLevel,
            seconds: Date().timeIntervalSince(session.startedAt)
        )
    }

    func finish() -> Result<RecordingStopResult, CapabilityError> {
        let seconds = Date().timeIntervalSince(session.startedAt)
        teardown()
        var files: [RecordingSource: String] = [:]
        for source in session.sources {
            let name = "\(source == .mic ? "mic" : "system").\(session.format.fileExtension)"
            files[source] = dir.appendingPathComponent(name).path
        }
        // meta.json is what makes a folder a *session* to the apps that list
        // them later; basenames, so a moved folder stays coherent.
        let meta: [String: Any] = [
            "id": session.id,
            "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
            "seconds": (seconds * 10).rounded() / 10,
            "sources": session.sources.map(\.rawValue),
            "format": session.format.rawValue,
            "files": Dictionary(uniqueKeysWithValues: files.map { ($0.key.rawValue, ($0.value as NSString).lastPathComponent) }),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        return .success(RecordingStopResult(session: session, seconds: seconds, files: files))
    }

    private func teardown() {
        mic?.stop()
        mic = nil
        tap?.stop()
        tap = nil
    }
}

// MARK: - The process tap

/// System audio via `AudioHardwareCreateProcessTap` (macOS 14.2+): a global
/// tap of every process's output, pulled through a private aggregate device
/// into an `AVAudioFile`. No kext, no virtual driver, one TCC prompt
/// ("System Audio Recording").
private final class ProcessTapCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let writer: TapWriter

    var currentLevel: Double { writer.level }

    init(url: URL, format: RecordingFormat) throws {
        guard #available(macOS 14.2, *) else {
            throw CapabilityError("system audio capture needs macOS 14.2 or later")
        }
        // A global tap, excluding nothing: what the speakers would play is
        // what "them" sounds like. `isPrivate` keeps the tap and the
        // aggregate out of every device picker on the machine.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var createdTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &createdTap)
        guard status == noErr, createdTap != kAudioObjectUnknown else {
            // -1 is what a refused "System Audio Recording" consent looks
            // like from here; the sentence covers both readings honestly.
            throw CapabilityError("system audio capture was refused (\(status))")
        }
        tapID = createdTap

        // The tap's own stream format, for the file writer: sample rate and
        // channel count follow the output device and are not ours to choose.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            Self.destroyTap(tapID)
            throw CapabilityError("the system tap has no readable format (\(status))")
        }

        do {
            writer = try TapWriter(url: url, tapFormat: tapFormat, container: format)
        } catch {
            Self.destroyTap(tapID)
            throw error
        }

        // A private aggregate carrying the tap — AND the default output device
        // as its clock. Load-bearing, not decoration: an aggregate whose only
        // member is a tap starts without error and then never fires its
        // IOProc, because nothing in it owns a hardware clock (found live —
        // every call answered noErr and zero callbacks arrived). Drift
        // compensation keeps the tap honest against that clock.
        var outputUID: CFString = "" as CFString
        do {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var outputID = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var probe = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &outputID
            )
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            if probe == noErr {
                probe = AudioObjectGetPropertyData(outputID, &uidAddress, 0, nil, &uidSize, &outputUID)
            }
            guard probe == noErr else {
                Self.destroyTap(tapID)
                throw CapabilityError("no default output device to clock the tap (\(probe))")
            }
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Ledge Recording Tap",
            kAudioAggregateDeviceUIDKey as String: "sh.ledge.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &createdAggregate)
        guard status == noErr, createdAggregate != kAudioObjectUnknown else {
            Self.destroyTap(tapID)
            throw CapabilityError("could not stand up the tap's aggregate device (\(status))")
        }
        aggregateID = createdAggregate

        let writer = writer
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInputData, _, _, _ in
            // Realtime thread: hand the buffers to the locked writer and get
            // out. Nothing here allocates but the AVAudioPCMBuffer view.
            writer.write(bufferList: inInputData)
        }
        guard status == noErr, let procID else {
            stop()
            throw CapabilityError("could not attach to the tap's device (\(status))")
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw CapabilityError("the tap's device would not start (\(status))")
        }
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        Self.destroyTap(tapID)
        tapID = kAudioObjectUnknown
        writer.close()
    }

    private static func destroyTap(_ id: AudioObjectID) {
        guard id != kAudioObjectUnknown else { return }
        if #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(id)
        }
    }
}

/// The only object the realtime thread touches. The lock is uncontended in
/// practice (levels reads ~7/s, IO writes ~90/s, both microseconds long);
/// `AVAudioFile.write` converts PCM → AAC in-process when the file was
/// created with AAC settings, so the callback stays free of converters.
private final class TapWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let tapFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var rms: Double = 0

    var level: Double {
        lock.lock()
        defer { lock.unlock() }
        return rms
    }

    init(url: URL, tapFormat: AVAudioFormat, container: RecordingFormat) throws {
        self.tapFormat = tapFormat
        var settings: [String: Any]
        switch container {
        case .aac:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: tapFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: tapFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: tapFormat.commonFormat,
                interleaved: tapFormat.isInterleaved
            )
        } catch {
            throw CapabilityError("could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func write(bufferList: UnsafePointer<AudioBufferList>) {
        // A no-copy view over CoreAudio's own buffers, valid for this call.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: bufferList,
            deallocator: nil
        ) else { return }
        // Interleaved-safe on purpose: the tap reports the output device's own
        // format, which in practice IS interleaved — and `floatChannelData`
        // is nil for interleaved buffers, which is a meter forever at zero.
        // Channel 0, strided, straight off the buffer list.
        var meanSquare: Double = 0
        let list = buffer.audioBufferList.pointee
        if buffer.frameLength > 0, list.mNumberBuffers > 0, let data = list.mBuffers.mData,
           tapFormat.commonFormat == .pcmFormatFloat32 {
            let stride = tapFormat.isInterleaved ? Int(tapFormat.channelCount) : 1
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.frameLength)
            for i in 0..<count {
                let value = Double(samples[i * stride])
                meanSquare += value * value
            }
            meanSquare /= Double(count)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        try? file.write(from: buffer)
        // Eased, not raw: one IO slice is ~10 ms and a meter that honest
        // flickers. Same trick as every needle in the product, one level down.
        rms = rms * 0.8 + min(1, meanSquare.squareRoot() * 3.2) * 0.2
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil // AVAudioFile finalizes on release
        rms = 0
    }
}
