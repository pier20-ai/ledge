import AppKit
import CoreGraphics
import CoreLocation
import EventKit
import Foundation
import LedgeShellCore
import UserNotifications

/// The shipping `PermissionProbing`: four non-prompting reads, four deliberate
/// asks, and one deep link per pane.
///
/// Every file in this one is a seam, in the same sense `PlatformSystemFacades`
/// is — it touches EventKit, CoreLocation, UserNotifications and CoreGraphics,
/// none of which a test runner can make behave, and one of which (UN) *aborts
/// the process* when there is no bundle. So there is no policy here: which
/// button a row offers, what it says, and which pane it opens all live in
/// `PermissionCatalog`, tested against a fake. What is left below is: ask the
/// framework, and translate its answer into a `PermissionStatus`.
///
/// The asks are the reason this class exists at all. macOS raises each consent
/// dialog at the moment the API is first called and never before, which means
/// the only way to let a user settle a permission *deliberately* — after reading
/// what it is for, rather than mid-gesture in some app — is to call the API on
/// their behalf, once, from a button they pressed.
@MainActor
final class SystemPermissionProbe: NSObject, PermissionProbing {
    /// Built on first use, not at init: a `CLLocationManager` is cheap but not
    /// free, and a user who never opens this surface should never pay for one.
    /// (It does not prompt merely by existing — see `SystemLocation`.)
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    /// The pending location ask. CoreLocation answers through the delegate, not
    /// a completion handler, so the callback has to be parked somewhere.
    private var locationAnswer: (@MainActor (PermissionStatus) -> Void)?
    /// One store, kept for the same reason `SystemCalendar` keeps one: it holds
    /// the authorization state, and a per-call store re-arms the change
    /// machinery every time the surface refreshes.
    private let calendarStore = EKEventStore()

    // MARK: - Reading

    func status(of permission: LedgePermission) -> PermissionStatus {
        if let reason = unreachable(permission) { return .unavailable(reason) }
        switch permission {
        case .automation:
            // Not readable at all, and the catalog says why (`unreadableReason`).
            return .unreadable(permission.unreadableReason ?? "")
        case .notifications:
            return Self.notificationStatus()
        case .screenRecording:
            // The one read that is a plain boolean: preflight tells us whether
            // the grant is in place, and cannot distinguish "never asked" from
            // "refused" — so a false answer stays `notDetermined` and the ask
            // resolves the ambiguity by trying (see `askScreenRecording`).
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .calendar:
            return Self.translate(EKEventStore.authorizationStatus(for: .event))
        case .location:
            return Self.translate(locationManager.authorizationStatus)
        }
    }

    /// Why this permission cannot be touched in this build — or nil.
    ///
    /// Both branches are crash guards, not politeness. Calling an EventKit or
    /// CoreLocation authorization API without its usage description terminates
    /// the process, and `UNUserNotificationCenter.current()` traps outright with
    /// no bundle identifier (see `NotificationPresenter`). A surface whose
    /// "Allow" button kills the shell is worse than no surface.
    private func unreachable(_ permission: LedgePermission) -> String? {
        if permission == .notifications, Bundle.main.bundleIdentifier == nil {
            return "Only the bundled Ledge.app can post notifications."
        }
        guard let key = permission.usageDescriptionKey else { return nil }
        guard Bundle.main.object(forInfoDictionaryKey: key) == nil else { return nil }
        return "Missing \(key) — run Ledge.app."
    }

    /// `getNotificationSettings` is asynchronous and this read is not, so the
    /// answer is cached from the last refresh and re-armed for the next one.
    ///
    /// That is a real limitation, stated rather than hidden: the very first draw
    /// of the surface shows `notDetermined` for notifications even on a machine
    /// that has already allowed them, and the row corrects itself a frame later
    /// when the callback lands and the surface reloads. The alternative — a
    /// semaphore on the main thread — deadlocks against UN's own queue.
    private static nonisolated(unsafe) var cachedNotificationStatus: PermissionStatus?

    /// Refresh the notification cache, calling back when it has actually changed
    /// (so the surface reloads once, not on every poll).
    static func refreshNotificationStatus(_ changed: @escaping @MainActor () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // `@Sendable` for the same reason as everywhere else UN is touched: an
        // un-annotated closure inherits main-actor isolation, UN calls back on
        // its own queue, and the executor assertion kills the process. See
        // `NotificationPresenter.requestAuthorizationIfNeeded`.
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            let status = translate(settings.authorizationStatus)
            Task { @MainActor in
                guard cachedNotificationStatus != status else { return }
                cachedNotificationStatus = status
                changed()
            }
        }
    }

    private static func notificationStatus() -> PermissionStatus {
        cachedNotificationStatus ?? .notDetermined
    }

    // MARK: - Asking

    func ask(_ permission: LedgePermission, then answer: @escaping @MainActor (PermissionStatus) -> Void) {
        switch permission {
        case .automation:
            // Never reachable: `.unreadable` yields `.openSettings`, not `.ask`.
            // Kept exhaustive rather than fatal — a surface that traps because a
            // row's policy changed is worse than one that does nothing.
            // Asking would mean picking some app to send a stray Apple event to
            // purely to raise its dialog, which is exactly the ambush this
            // surface exists to prevent.
            answer(status(of: permission))
        case .notifications:
            askNotifications(answer)
        case .screenRecording:
            askScreenRecording(answer)
        case .calendar:
            askCalendar(answer)
        case .location:
            askLocation(answer)
        }
    }

    private func askNotifications(_ answer: @escaping @MainActor (PermissionStatus) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            answer(status(of: .notifications))
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { @Sendable granted, _ in
                let status: PermissionStatus = granted ? .granted : .denied
                Task { @MainActor in
                    Self.cachedNotificationStatus = status
                    answer(status)
                }
            }
    }

    /// Screen Recording is the one grant macOS does not apply to a running
    /// process. `CGRequestScreenCaptureAccess` shows the dialog and returns
    /// false whether the user said no *or* said yes and the grant is waiting on
    /// a relaunch — and it shows nothing at all if they refused on some earlier
    /// day. Three outcomes, one boolean.
    ///
    /// So a false answer becomes `unreadable` carrying all of it, which routes
    /// the row to Settings: the pane shows the truth in every one of the three
    /// cases, and asking again would be a no-op in two of them.
    private func askScreenRecording(_ answer: @escaping @MainActor (PermissionStatus) -> Void) {
        if CGRequestScreenCaptureAccess() {
            answer(.granted)
            return
        }
        answer(.unreadable("Takes effect when Ledge restarts — or it was already refused."))
    }

    private func askCalendar(_ answer: @escaping @MainActor (PermissionStatus) -> Void) {
        calendarStore.requestFullAccessToEvents { @Sendable _, _ in
            // The boolean is not the answer we want to show: "write only" is a
            // grant that returns false here and is *not* the same as a refusal,
            // and the row has to say which one happened. Re-read instead.
            Task { @MainActor in answer(Self.translate(EKEventStore.authorizationStatus(for: .event))) }
        }
    }

    private func askLocation(_ answer: @escaping @MainActor (PermissionStatus) -> Void) {
        // Already settled either way: the prompt will not appear, so parking a
        // callback that CoreLocation will never fire would leave the row
        // spinning forever.
        let current = Self.translate(locationManager.authorizationStatus)
        guard current == .notDetermined else {
            answer(current)
            return
        }
        locationAnswer = answer
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Settings

    func openSettings(for permission: LedgePermission) {
        guard let url = URL(string: permission.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Translation

    nonisolated static func translate(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: .granted
        // Write-only is EventKit's own middle rung and it is useless to us:
        // `ctx.platform.calendar` only ever reads. Reporting it as granted would
        // promise events that every query will fail to return.
        case .writeOnly: .denied
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unreadable("macOS reported a state this build does not recognize.")
        }
    }

    nonisolated static func translate(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .authorizedAlways: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unreadable("macOS reported a state this build does not recognize.")
        }
    }

    nonisolated static func translate(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unreadable("macOS reported a state this build does not recognize.")
        }
    }
}

extension SystemPermissionProbe: CLLocationManagerDelegate {
    /// CoreLocation calls back on the queue its manager was created on — the
    /// main one — so this is an assertion, not a hop (as in `SystemLocation`).
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // `self.locationManager`, not the parameter: `CLLocationManager` is
            // not `Sendable`, so the argument cannot cross into the isolated
            // body — and it is the same object either way.
            let status = Self.translate(locationManager.authorizationStatus)
            // `notDetermined` still means the sheet is up; only a decision ends
            // the wait. Fires once at registration too, which is the same case.
            guard status != .notDetermined, let answer = locationAnswer else { return }
            locationAnswer = nil
            answer(status)
        }
    }
}
