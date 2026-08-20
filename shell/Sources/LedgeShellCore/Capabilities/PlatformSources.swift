import Foundation

/// The observe-source vocabulary (`kind` on a `platform` envelope). Each kind is
/// one *shared* OS resource behind an arbitrary number of per-app registrations:
/// six apps watching `power` cost one IOKit run-loop source, not six.
public enum PlatformObserveKind {
    /// Any `DistributedNotificationCenter` name, verbatim. The one kind with an
    /// open vocabulary, because the names belong to whoever posts them.
    public static let distributedNotification = "distributedNotification"
    /// `NSWorkspace` + the screen-lock distributed notifications, translated to
    /// a small stable vocabulary (see `PlatformSignalName.workspace`).
    public static let workspace = "workspace"
    /// `NSPasteboard.general.changeCount`, polled while anyone is watching.
    public static let pasteboard = "pasteboard"
    /// Battery / AC / low-power state.
    public static let power = "power"
    /// Network path state (`NWPathMonitor`).
    public static let reachability = "reachability"
    /// Default output device and its volume/mute.
    public static let audio = "audio"
    /// Do Not Disturb / Focus: whether a mode is on, and which one.
    ///
    /// Read from the user's own Focus database (`~/Library/DoNotDisturb/DB`),
    /// which is a **file read** — the same mechanism every third-party menu-bar
    /// tool uses, and deliberately not a private framework. The format is
    /// undocumented but has been stable for years; the source is written so a
    /// shape change makes it go *quiet* rather than confidently wrong (see
    /// `FocusSource`).
    public static let focus = "focus"

    public static let all: Set<String> = [
        distributedNotification, workspace, pasteboard, power, reachability, audio, focus,
    ]
}

/// The **name** vocabulary, per kind.
///
/// Every kind except `distributedNotification` has a closed vocabulary, and that
/// is the point: an app should write `observe("workspace", "screenLocked")`, not
/// `"com.apple.screenIsLocked"`. Raw `NSNotification` names are an implementation
/// detail of whichever macOS is running — one of them lives on
/// `DistributedNotificationCenter` and the rest on `NSWorkspace`'s own center,
/// which an app has no way to know and no business knowing. A name outside the
/// vocabulary is refused with the list of the ones that exist, rather than
/// registering nothing and looking like it worked.
public enum PlatformSignalName {
    /// The single name used by the state-snapshot kinds: what changed is in the
    /// payload, so one registration gets an app everything about that resource.
    public static let changed = "changed"

    public static let didActivateApplication = "didActivateApplication"
    public static let willSleep = "willSleep"
    public static let didWake = "didWake"
    public static let screensDidSleep = "screensDidSleep"
    public static let screensDidWake = "screensDidWake"
    public static let screenLocked = "screenLocked"
    public static let screenUnlocked = "screenUnlocked"

    public static let workspace: Set<String> = [
        didActivateApplication, willSleep, didWake,
        screensDidSleep, screensDidWake, screenLocked, screenUnlocked,
    ]

    /// The one-name vocabulary shared by `pasteboard`, `power`, `reachability`,
    /// `audio` and `focus`.
    public static let snapshot: Set<String> = [changed]
}

/// One shared OS resource, behind one observe `kind`.
///
/// The lifecycle is refcounted by the registry, not by the source: `start` is
/// called when the *first* observer of that kind arrives and `stop` when the
/// last one goes away, so an app that forgets to unobserve still costs nothing
/// once its worker dies (observers are released per app on every §3.2 lifecycle
/// transition). **A source must therefore acquire nothing in `init`** — the
/// registry constructs one to answer "is this kind real?" and may throw it away
/// unstarted.
///
/// `snapshot(for:)` is the immediate-fire hook: `power` and `reachability`
/// describe a *state*, and an app that had to wait for the next change to learn
/// the current one would have to make a separate read call for the thing it
/// just subscribed to. So the registry delivers the snapshot at registration.
@MainActor
public protocol PlatformSignalSource: AnyObject {
    /// Names this source accepts, or nil for "any non-empty name".
    var supportedNames: Set<String>? { get }
    /// The first observer of this kind arrived. Acquire the OS resource here.
    func start(emit: @escaping @MainActor (_ name: String, _ payload: [String: JSONValue]) -> Void)
    /// The last observer of this kind went away. Release everything.
    func stop()
    /// A name entered the watch set (refcounted). Only the open-vocabulary
    /// sources need this; the fixed ones emit every name they know.
    func addName(_ name: String)
    /// A name left the watch set (refcounted).
    func removeName(_ name: String)
    /// State to deliver immediately to a newly registered observer, if any.
    func snapshot(for name: String) -> [String: JSONValue]?
}

public extension PlatformSignalSource {
    func addName(_ name: String) {}
    func removeName(_ name: String) {}
    func snapshot(for name: String) -> [String: JSONValue]? { nil }
}

/// `distributedNotification` — the original source, unchanged in behavior.
///
/// **The center's type is the base class on purpose.**
/// `DistributedNotificationCenter` is a `NotificationCenter` subclass, so a test
/// can hand in a plain in-process center, post into it, and assert on the
/// envelope that comes out — without depending on `distnoted` being reachable
/// and answering promptly inside a test runner.
@MainActor
public final class NotificationCenterSource: PlatformSignalSource {
    /// Open vocabulary: the names belong to whoever posts them.
    public nonisolated let supportedNames: Set<String>? = nil

    private let center: NotificationCenter
    private var emit: (@MainActor (String, [String: JSONValue]) -> Void)?
    private var tokens: [String: NSObjectProtocol] = [:]

    public init(center: NotificationCenter) {
        self.center = center
    }

    public func start(emit: @escaping @MainActor (String, [String: JSONValue]) -> Void) {
        self.emit = emit
    }

    public func stop() {
        for token in tokens.values { center.removeObserver(token) }
        tokens.removeAll()
        emit = nil
    }

    public func addName(_ name: String) {
        guard tokens[name] == nil else { return }
        // `queue: nil` — distributed notifications are delivered on the main run
        // loop, and hopping to an OperationQueue would only add a turn of
        // latency to the one thing this whole mechanism exists to make fast.
        tokens[name] = center.addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // `userInfo` is reduced to `Sendable` scalars right here, at the
            // boundary: it is an arbitrary dictionary owned by whoever posted
            // the notification, and the only safe thing to carry out of this
            // block is the JSON subset that will cross the wire anyway.
            let reduced = PlatformObserver.reduce(notification.userInfo)
            MainActor.assumeIsolated {
                self?.emit?(name, reduced)
            }
        }
    }

    public func removeName(_ name: String) {
        guard let token = tokens.removeValue(forKey: name) else { return }
        center.removeObserver(token)
    }
}
