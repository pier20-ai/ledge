import Foundation
import LedgeShellCore
import UserNotifications

/// User notifications, posted by the shell (spec §6, `ctx.notify`) — through
/// `UNUserNotificationCenter` and nothing else. The OS API is the only one that
/// can carry **action buttons** ("[Execute] [Skip]" in the notification is the
/// whole agentic approval loop) and the only one whose clicks come back to us:
///
/// - a pressed button returns its action id;
/// - a click on the body returns the pseudo-action **"opened"**, the shell
///   opens the notch at the posting app, and the app can render
///   because-of-a-notification UI off the same id-0 `notification` event.
///
/// `UNUserNotificationCenter.current()` aborts the process when there is no
/// bundle identifier, so an unbundled shell (`swift run`, the test harness)
/// never touches it: `ctx.notify` there is a warning in the log and nothing
/// else. There is deliberately no fallback path — a notification that cannot
/// answer "what happens when the user clicks it?" is not a notification, it is
/// a toast pretending.
@MainActor
final class NotificationPresenter: NSObject {
    /// Whether this process can post at all. Nil bundle identifier means
    /// `UNUserNotificationCenter.current()` would abort rather than return.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Called with `(app, notificationId, actionId)` when the user presses a
    /// button, or with `Self.openedAction` when they click the body.
    var onAction: ((String, Int, String) -> Void)?

    /// Category identifiers already registered with the notification center.
    /// `setNotificationCategories` *replaces* the whole set, so the set has to
    /// be remembered rather than appended to.
    private var categories: [String: UNNotificationCategory] = [:]
    private var authorizationRequested = false
    private var warnedUnavailable = false
    /// UN notification identifier → the app + notification id that posted it,
    /// so a response can be routed back to the right worker.
    private var posted: [String: (app: String, id: Int)] = [:]

    /// The clicked-the-body pseudo-action: the user asked for the app, not for
    /// any of its buttons. The shell opens the notch at the app; the app hears
    /// this name and can decide to show notification-specific UI.
    static let openedAction = "opened"

    override init() {
        super.init()
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post one notification. Fire and forget: `ctx.notify` awaits nothing, so a
    /// failure here is a log line, never an app-visible error.
    func post(_ notification: NotifyPayload, app: String, appName: String) {
        guard Self.isAvailable else {
            if !warnedUnavailable {
                warnedUnavailable = true
                NSLog("[ledge] ctx.notify dropped: no bundle identifier — run the bundled shell (Ledge.app) for notifications")
            }
            return
        }

        let center = UNUserNotificationCenter.current()
        requestAuthorizationIfNeeded(center)

        let content = UNMutableNotificationContent()
        content.title = notification.title ?? appName
        content.body = notification.text
        content.sound = nil

        if let actions = notification.actions, !actions.isEmpty {
            content.categoryIdentifier = registerCategory(for: actions, center: center)
        }

        let identifier = UUID().uuidString
        posted[identifier] = (app, notification.id)
        // @Sendable for the same reason as the authorization callback above:
        // MainActor inheritance + a UN-owned callback queue = SIGTRAP.
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { @Sendable error in
            if let error {
                NSLog("[ledge] notification failed: %@", error.localizedDescription)
            }
        }
    }

    private func requestAuthorizationIfNeeded(_ center: UNUserNotificationCenter) {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        // macOS shows this prompt once per bundle; a denial is the user's
        // answer and we never ask again in this process.
        // `@Sendable` is load-bearing, not decoration. This class is @MainActor,
        // so an un-annotated closure INHERITS that isolation — and UN calls back
        // on one of its own queues, which trips the executor assertion and kills
        // the process with SIGTRAP. It only ever fires in a bundled build,
        // because unbundled the UN path is skipped entirely, so it cannot be
        // caught by any dev run. Marking the closure @Sendable makes it
        // non-isolated, which is correct here: the body only logs.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error {
                NSLog("[ledge] notification authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("[ledge] notifications not authorized — ctx.notify will be silent")
            }
        }
    }

    /// One category per distinct set of buttons. The identifier is derived from
    /// the buttons themselves, so an app that posts the same two buttons a
    /// thousand times registers one category.
    private func registerCategory(
        for actions: [NotifyActionSpec],
        center: UNUserNotificationCenter
    ) -> String {
        let identifier = "ledge.actions." + actions.map { "\($0.id)\u{1}\($0.label)" }.joined(separator: "\u{2}")
        if categories[identifier] == nil {
            let category = UNNotificationCategory(
                identifier: identifier,
                actions: actions.map {
                    UNNotificationAction(identifier: $0.id, title: $0.label, options: [.foreground])
                },
                intentIdentifiers: [],
                options: []
            )
            categories[identifier] = category
            center.setNotificationCategories(Set(categories.values))
        }
        return identifier
    }

    /// UN response identifier → the action name apps see, or nil for the one
    /// response that is not an action: a dismissal. The user declining to
    /// engage is not a decision the app should act on.
    static func actionName(for identifier: String) -> String? {
        switch identifier {
        case UNNotificationDismissActionIdentifier: nil
        case UNNotificationDefaultActionIdentifier: openedAction
        default: identifier
        }
    }

    /// Route one notification response to the app that posted it.
    fileprivate func deliver(identifier: String, action: String) {
        guard let name = Self.actionName(for: action) else { return }
        guard let origin = posted[identifier] else { return }
        onAction?(origin.app, origin.id, name)
    }
}

extension NotificationPresenter: UNUserNotificationCenterDelegate {
    /// A pressed button (or a click on the body). Everything that is not a
    /// dismissal becomes a `notifyAction` for the app that posted it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Pull the two strings we need out of the (non-Sendable) response before
        // hopping, and tell the system we are done straight away: the routing
        // below is our business, not something the notification centre waits on.
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in self.deliver(identifier: identifier, action: action) }
        completionHandler()
    }

    /// Show the banner even while Ledge is frontmost — the notch panel is not a
    /// window the user "is in", so suppressing would just lose the message.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
