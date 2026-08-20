import Foundation
import LedgeShellCore

/// The shell's half of the agentic layer (spec §6): it executes what a worker
/// cannot — AppleScript and Shortcuts, user notifications, screen capture — and
/// hands the results back to the `ProtocolEngine`, which puts them on the wire.
///
/// It is a `CapabilityDelegate` rather than part of the renderer delegate on
/// purpose: none of this draws anything. The split also means the snapshot
/// replay and the headless tests run a real engine with **no** capability host
/// at all, and requests answer "unsupported" instead of hanging.
///
/// Trust model is spec §6's, unchanged: apps are trusted local code and macOS
/// TCC is the consent layer. There is no Ledge-side grant UI, and adding one
/// would only duplicate a prompt the OS already shows — attributed to the shell,
/// which is exactly the process the user recognizes.
@MainActor
final class CapabilityHost: NSObject, CapabilityDelegate {
    private let apple = AppleExecutor()
    private let capture = ScreenCaptureExecutor()
    private let notifications = NotificationPresenter()
    private let observers: PlatformObserver
    private let platform: PlatformExecutor

    /// Human-readable app name for a notification's title, from the catalog.
    var appName: ((String) -> String)?
    /// A pressed notification button, on its way to `notifyAction` (§6 ext).
    var onNotificationAction: ((_ app: String, _ id: Int, _ action: String) -> Void)?
    /// An observed OS signal fired, on its way to the id-0 `platform` event.
    var onPlatformEvent: ((_ app: String, _ kind: String, _ name: String, _ userInfo: [String: JSONValue]) -> Void)?

    /// `notificationCenter` is injectable so a test can post into an in-process
    /// `NotificationCenter` instead of depending on the system's notification
    /// daemon being reachable from a test runner (see `PlatformObserver`).
    /// `sources` and `platform` are injectable for the same reason one level up:
    /// the shipping observe sources and call facades touch AppKit, IOKit,
    /// CoreAudio, EventKit, CoreLocation and the speech synthesizer, none of
    /// which a test runner can make behave.
    init(
        notificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        sources: PlatformObserver.SourceFactory? = nil,
        platform: PlatformExecutor? = nil
    ) {
        observers = PlatformObserver(
            sources: sources ?? SystemPlatformSources.factory(distributed: notificationCenter)
        )
        // Facades are built eagerly but acquire nothing: `EKEventStore` and
        // `CLLocationManager` do not prompt until asked, and the synthesizer is
        // silent until spoken to. Nothing here raises a TCC prompt at launch.
        self.platform = platform ?? PlatformExecutor(
            calendar: SystemCalendar(),
            workspace: SystemWorkspaceProbe(),
            location: SystemLocation(),
            spotlight: SystemSpotlight(),
            audio: SystemAudioDevice.shared,
            speech: SystemSpeech(),
            // Wired here rather than in `AppDelegate` because there is nothing
            // to configure: the shell either can end itself or is a headless
            // replay with no NSApp, and this file is the one that knows which.
            quit: SystemQuit(),
            // Like the others it acquires nothing eagerly: the mic and the
            // system tap (and their TCC prompts) are touched only by a start.
            recorder: SystemRecorder()
        )
        super.init()
        notifications.onAction = { [weak self] app, id, action in
            self?.onNotificationAction?(app, id, action)
        }
        observers.onEvent = { [weak self] app, kind, name, userInfo in
            self?.onPlatformEvent?(app, kind, name, userInfo)
        }
    }

    /// Test/inspection accessor: which (app, kind, name) triples are live.
    var platformRegistrations: Set<PlatformObserver.Key> { observers.registrations }

    /// Which notification path this process got, for the log line at startup.
    var notificationMode: String {
        NotificationPresenter.isAvailable
            ? "UNUserNotificationCenter"
            : "unavailable (unbundled — ctx.notify dropped)"
    }

    // MARK: - CapabilityDelegate

    func runApple(_ invocation: AppleInvocation, app: String, completion: @escaping AppleCompletion) {
        // Executed off the main queue (an Apple event to another app can block
        // for seconds), then hopped back so the engine only ever sends from main.
        apple.run(invocation) { result in
            Task { @MainActor in completion(result) }
        }
    }

    func postNotification(_ notification: NotifyPayload, app: String) {
        notifications.post(notification, app: app, appName: appName?(app) ?? app)
    }

    func captureScreen(interactive: Bool, app: String, completion: @escaping CaptureCompletion) {
        capture.capture(interactive: interactive) { result in
            Task { @MainActor in completion(result) }
        }
    }

    func observePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError> {
        let result = observers.observe(app: app, kind: kind, name: name)
        if case .success = result {
            NSLog("[ledge] observe %@ '%@' for %@", kind, name, app)
        }
        return result
    }

    func unobservePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError> {
        observers.unobserve(app: app, kind: kind, name: name)
    }

    func releasePlatformObservers(app: String) {
        observers.release(app: app)
    }

    func releaseAllPlatformObservers() {
        observers.releaseAll()
    }

    /// The request/reply half of `ctx.platform` (spec §6 extension). The
    /// executor already runs everything off the main thread that has any reason
    /// to be, and settles on main, so there is nothing to hop here.
    func runPlatformCall(_ call: PlatformCall, app: String, completion: @escaping PlatformCompletion) {
        platform.run(call, app: app, completion: completion)
    }

    /// The app whose recording is live, for the global hotkey: ⌃⌥Space while
    /// the tape rolls should land on the recorder, not on "whatever was last".
    var recordingOwner: String? { platform.recordingOwner }

    /// Test/inspection accessor: which shared OS resources are currently held.
    var platformSourceKinds: Set<String> { observers.liveSourceKinds }
}
