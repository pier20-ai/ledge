import Foundation
@testable import LedgeShellCore

/// A scripted stand-in for the shell's capability host: it records what the
/// engine asked for and settles each request on command, so the routing can be
/// exercised without AppleScript, notifications or a screenshot.
@MainActor
final class RecordingCapabilities: CapabilityDelegate {
    struct AppleCall { let app: String; let invocation: AppleInvocation }
    struct CaptureCall { let app: String; let interactive: Bool }

    struct ObserveCall: Equatable { let app: String; let kind: String; let name: String }

    var appleCalls: [AppleCall] = []
    var notifications: [(app: String, payload: NotifyPayload)] = []
    var captureCalls: [CaptureCall] = []

    /// `ctx.platform.observe` bookkeeping. A real `PlatformObserver` is exercised
    /// on its own (`PlatformObserverTests`); here we only care about routing.
    var observeCalls: [ObserveCall] = []
    var unobserveCalls: [ObserveCall] = []
    var releasedApps: [String] = []
    var releaseAllCount = 0
    /// Set to fail the next observe — the "unsupported kind" path.
    var observeResult: Result<Void, CapabilityError> = .success(())

    /// Set to settle synchronously; leave nil to hold the request open (which is
    /// what an AppleScript talking to a slow app looks like).
    var appleResult: Result<JSONValue, CapabilityError>?
    var captureResult: Result<String, CapabilityError>?

    private var pendingApple: [AppleCompletion] = []
    private var pendingCapture: [CaptureCompletion] = []

    func runApple(_ invocation: AppleInvocation, app: String, completion: @escaping AppleCompletion) {
        appleCalls.append(AppleCall(app: app, invocation: invocation))
        if let appleResult { completion(appleResult) } else { pendingApple.append(completion) }
    }

    func postNotification(_ notification: NotifyPayload, app: String) {
        notifications.append((app, notification))
    }

    func captureScreen(interactive: Bool, app: String, completion: @escaping CaptureCompletion) {
        captureCalls.append(CaptureCall(app: app, interactive: interactive))
        if let captureResult { completion(captureResult) } else { pendingCapture.append(completion) }
    }

    func observePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError> {
        observeCalls.append(ObserveCall(app: app, kind: kind, name: name))
        return observeResult
    }

    func unobservePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError> {
        unobserveCalls.append(ObserveCall(app: app, kind: kind, name: name))
        return .success(())
    }

    func releasePlatformObservers(app: String) {
        releasedApps.append(app)
    }

    func releaseAllPlatformObservers() {
        releaseAllCount += 1
    }

    /// Settle a request that was held open, the way a real executor would once
    /// its off-main work finished.
    func settleApple(_ result: Result<JSONValue, CapabilityError>) {
        let waiting = pendingApple
        pendingApple.removeAll()
        for completion in waiting { completion(result) }
    }

    func settleCapture(_ result: Result<String, CapabilityError>) {
        let waiting = pendingCapture
        pendingCapture.removeAll()
        for completion in waiting { completion(result) }
    }
}
