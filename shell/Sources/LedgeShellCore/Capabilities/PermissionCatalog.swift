import Foundation

/// The macOS consent surfaces Ledge can actually reach — and, for each one, what
/// is *honestly knowable* about it without asking.
///
/// This file is policy and copy only: no EventKit, no CoreLocation, no
/// UserNotifications, nothing that can prompt. The reading and the asking live
/// behind `PermissionProbing`, whose shipping implementation is in the shell
/// (`SystemPermissionProbe`) for the same reason `PlatformFacades` is: a test
/// runner cannot make TCC behave, and must never be allowed to try.
///
/// **This is not a grant UI.** Spec §6 and §3.6 are explicit that apps are
/// trusted local code and that macOS TCC is the consent layer; Ledge does not
/// keep its own grant state and nothing here gates a capability. What it does is
/// the part macOS cannot do for us: say *what* Ledge is about to ask for and
/// *why*, before the bare system dialog appears with no context — and, once a
/// permission has been refused, admit that TCC will never ask again and point at
/// the one pane that can undo it.
public enum LedgePermission: String, CaseIterable, Sendable {
    /// `ctx.apple` — AppleScript and Shortcuts (spec §6).
    case automation
    /// `ctx.notify` — `UNUserNotificationCenter` (spec §6).
    case notifications
    /// `ctx.capture` — Screen Recording (spec §6 extension).
    case screenRecording
    /// `ctx.platform.calendar` — EventKit.
    case calendar
    /// `ctx.platform.location` — CoreLocation.
    case location

    /// Display order: the ones an app is most likely to reach first, and the two
    /// that can be settled in one click last. Automation leads because it is
    /// both the most-used bridge and the only one whose story needs telling —
    /// see `detail`.
    public static let ordered: [LedgePermission] = [
        .automation, .notifications, .screenRecording, .calendar, .location,
    ]

    /// SF Symbol for the row. Chosen to name the *capability*, not the framework.
    public var symbol: String {
        switch self {
        case .automation: "wand.and.rays"
        case .notifications: "bell.badge"
        case .screenRecording: "camera.viewfinder"
        case .calendar: "calendar"
        case .location: "location"
        }
    }

    public var title: String {
        switch self {
        case .automation: "Automation"
        case .notifications: "Notifications"
        case .screenRecording: "Screen Recording"
        case .calendar: "Calendar"
        case .location: "Location"
        }
    }

    /// One line: what an app gets, in the user's terms rather than the API's.
    public var summary: String {
        switch self {
        case .automation: "Let apps drive Music, Notes, Safari — anything scriptable."
        case .notifications: "Banners with buttons, so an app can ask you something."
        case .screenRecording: "Apps that take a screenshot for you."
        case .calendar: "Reading today's events. Ledge never writes to a calendar."
        case .location: "Roughly where you are — city-level, for weather and the like."
        }
    }

    /// The second line, shown only when it earns its space: what macOS is about
    /// to do, or why this row cannot answer its own question.
    public var detail: String? {
        switch self {
        case .automation:
            // Automation's standing explanation is also the reason its state
            // cannot be read, so it is said once, in `unreadableReason`.
            nil
        case .notifications:
            nil
        case .screenRecording:
            "macOS may ask you to quit and reopen Ledge afterwards."
        case .calendar, .location:
            nil
        }
    }

    /// The System Settings pane that can undo a refusal.
    ///
    /// TCC has no re-prompt: once the user has said no, the API returns denied
    /// forever and asking again is a no-op. A deep link is not a convenience
    /// here, it is the only remedy that exists.
    public var settingsURL: String {
        switch self {
        case .automation:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .notifications:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .screenRecording:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .calendar:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .location:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        }
    }

    /// Why this permission's state cannot be read — or nil where macOS offers a
    /// check that does not prompt.
    ///
    /// Automation is the only one, and it is not an omission on Apple's part:
    /// there is no blanket Automation grant to read. `AEDeterminePermissionToAutomateTarget`
    /// answers about **one named target app**, and answering costs either that
    /// app's prompt or a "not determined" for every app Ledge has never talked
    /// to. So the row says so, and offers the pane instead of a button that
    /// would have to ambush some third app to learn anything.
    ///
    /// It lives here rather than in the probe because it is a fact about macOS,
    /// not about this build — the same answer in every process, testable without
    /// touching a framework.
    public var unreadableReason: String? {
        switch self {
        case .automation:
            // Short on purpose: it is a row's second line in a 440 pt panel,
            // and the truthful long version ("there is no blanket grant to
            // read, only a per-target one that would have to be prompted for")
            // is above.
            "macOS asks for each app Ledge talks to, the first time it does."
        case .notifications, .screenRecording, .calendar, .location:
            nil
        }
    }

    /// The `Info.plist` key macOS requires before the corresponding API may be
    /// called — or nil where there is none.
    ///
    /// Load-bearing, not documentation: calling `requestFullAccessToEvents` in a
    /// bundle without `NSCalendarsFullAccessUsageDescription` does not fail, it
    /// **terminates the process**. So the probe checks for the string before it
    /// offers a button that would kill the shell, and reports the gap instead.
    public var usageDescriptionKey: String? {
        switch self {
        case .automation: "NSAppleEventsUsageDescription"
        case .calendar: "NSCalendarsFullAccessUsageDescription"
        case .location: "NSLocationWhenInUseUsageDescription"
        case .notifications, .screenRecording: nil
        }
    }
}

/// What we know about one permission right now.
///
/// `unreadable` and `unavailable` exist so that the surface never has to guess.
/// Where macOS offers a read that does not prompt — `getNotificationSettings`,
/// `CGPreflightScreenCaptureAccess`, `EKEventStore.authorizationStatus`,
/// `CLLocationManager.authorizationStatus` — the row shows the real answer.
/// Where it does not, the row says so in as many words. A cheerful "Allowed"
/// derived from a hunch is worse than an honest "Unknown": it sends the user
/// away believing something that will fail the first time an app tries it.
public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    /// macOS exposes no way to read this without prompting for it.
    case unreadable(String)
    /// The API cannot be reached in this build at all — an unbundled dev shell,
    /// or a missing usage description (see `usageDescriptionKey`).
    case unavailable(String)

    /// Short text for the row's status pill.
    public var badge: String {
        switch self {
        case .granted: "ALLOWED"
        case .denied: "DENIED"
        case .notDetermined: "NOT ASKED"
        case .unreadable: "UNKNOWN"
        case .unavailable: "N/A"
        }
    }

    /// The same state as a WORD, for a row that has no button.
    ///
    /// `badge` is pill copy — short, upper-case, sized to sit inside a shape.
    /// Set as plain text at the end of a title line it reads as shouting, and
    /// "N/A" reads as a form field. This is the same fact said normally.
    public var plain: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not asked"
        case .unreadable: "Unknown"
        case .unavailable: "Unavailable"
        }
    }

    /// Hue family, named by meaning. The shell maps it to a palette; Core has no
    /// colors, and a status that carried one would be the one place the theme
    /// could not be changed from `LedgeTheme`.
    public var tone: PermissionTone {
        switch self {
        case .granted: .good
        case .denied: .bad
        case .notDetermined, .unreadable, .unavailable: .quiet
        }
    }

    /// The sentence to show *instead of* the permission's own detail, when this
    /// status is itself the interesting thing.
    public var note: String? {
        switch self {
        case .granted, .notDetermined: nil
        case .denied: "Refused earlier — macOS will not ask again. Change it in Settings."
        case .unreadable(let why): why
        case .unavailable(let why): why
        }
    }
}

public enum PermissionTone: Sendable {
    case good
    case bad
    case quiet
}

/// What the row's button should offer.
public enum PermissionAction: Equatable, Sendable {
    /// Nothing to do — it is already allowed, or unreachable in this build.
    ///
    /// **Not** spelled `none`: `row.action == .none` on an optional row parses
    /// as a nil check, which is how this shipped once claiming every missing row
    /// was a settled one.
    case settled
    /// Raise the real system prompt. Only ever from a deliberate click: this is
    /// the whole reason onboarding exists rather than pre-prompting at launch.
    case ask
    /// TCC will not ask again; open the pane that can undo it.
    case openSettings

    public var label: String? {
        switch self {
        case .settled: nil
        case .ask: "Allow…"
        case .openSettings: "Settings"
        }
    }
}

/// One permission plus what is currently known about it. Deliberately a value:
/// the surface re-derives the whole list after any action rather than mutating
/// a row in place, because a single click can change two rows (allowing Screen
/// Recording is the case — the answer arrives as a refusal we could not have
/// read beforehand).
public struct PermissionRow: Equatable, Sendable {
    public let permission: LedgePermission
    public let status: PermissionStatus

    public init(permission: LedgePermission, status: PermissionStatus) {
        self.permission = permission
        self.status = status
    }

    public var action: PermissionAction {
        switch status {
        case .granted, .unavailable: .settled
        case .notDetermined: .ask
        // Unreadable is Automation's case: we cannot know, so we cannot offer to
        // ask — the honest affordance is the pane that lists what has been asked.
        case .denied, .unreadable: .openSettings
        }
    }

    /// The explanatory line under the summary: the status's note when it has one
    /// (a refusal, or why the answer is unknown), otherwise the permission's own.
    public var footnote: String? {
        status.note ?? permission.detail
    }
}

/// Reading and asking, behind a seam. The shell implements it against the real
/// frameworks; tests implement it against a dictionary, which is what keeps the
/// standing rule ("never trigger a real TCC prompt from a test") mechanical
/// rather than a matter of care.
@MainActor
public protocol PermissionProbing: AnyObject {
    /// Never prompts. Every implementation of this is required to be a read.
    func status(of permission: LedgePermission) -> PermissionStatus
    /// Raises the real prompt and reports what the user chose. Only called from
    /// a `.ask` action, i.e. only ever from a click.
    func ask(_ permission: LedgePermission, then: @escaping @MainActor (PermissionStatus) -> Void)
    func openSettings(for permission: LedgePermission)
}

/// The list, in display order, read fresh. Free of AppKit so a test can assert
/// the whole table against a fake probe.
@MainActor
public func permissionRows(from probe: PermissionProbing) -> [PermissionRow] {
    LedgePermission.ordered.map { permission in
        // The unreadable ones are settled before the probe is asked: whether a
        // status can be read at all is a fact about macOS, and a probe that
        // answered differently would be wrong rather than interesting.
        if let reason = permission.unreadableReason {
            return PermissionRow(permission: permission, status: .unreadable(reason))
        }
        return PermissionRow(permission: permission, status: probe.status(of: permission))
    }
}
