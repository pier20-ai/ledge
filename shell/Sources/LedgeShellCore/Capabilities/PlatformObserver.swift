import Foundation

/// `ctx.platform.observe` (spec §6 extension): the shell watches an OS-level
/// signal for one app and pushes an event back when it fires.
///
/// This exists because polling is the wrong shape for "tell me when something
/// changed". Music's `monitor` asks Music.app what is playing every three
/// seconds, which is the right *reconciliation* cadence and a terrible
/// *latency* — a track change takes up to three seconds to reach the notch. A
/// distributed notification is exactly the missing half: the OS already
/// broadcasts `com.apple.Music.playerInfo` the instant the track changes, so the
/// app can keep its slow, authoritative poll and additionally be woken.
///
/// It lives in the shell rather than the worker for the same reason `ctx.apple`
/// does: every one of these registrations is a per-*process* subscription — with
/// the notification daemon, with `NSWorkspace`, with CoreAudio — and the process
/// the system knows is the one with the UI.
///
/// ## Shape
///
/// Two levels, refcounted against each other:
///
/// - a **registration** is one (app, kind, name) triple. Keyed by app as well as
///   by name because two apps may legitimately watch the same signal, and one of
///   them stopping must not take the other's registration with it.
/// - a **source** is the shared OS resource behind one `kind`. It is created and
///   started when the first registration for that kind arrives and stopped when
///   the last one goes away, so a pasteboard poll timer or an `NWPathMonitor`
///   exists exactly while somebody is listening and never one moment longer.
///
/// Sources are injected (`SourceFactory`) for the same reason the notification
/// center always was: the shipping ones touch AppKit, CoreAudio, IOKit and the
/// Network framework, none of which a headless test should have to make behave.
@MainActor
public final class PlatformObserver {
    /// One registration.
    public struct Key: Hashable, Sendable {
        public let app: String
        public let kind: String
        public let name: String

        public init(app: String, kind: String, name: String) {
            self.app = app
            self.kind = kind
            self.name = name
        }
    }

    /// Builds the source for one `kind`, or returns nil for a kind this shell
    /// cannot watch. Called speculatively — it must not acquire anything (that
    /// is `start`'s job).
    public typealias SourceFactory = @MainActor (_ kind: String) -> PlatformSignalSource?

    /// A signal fired. `payload` has already been reduced to the scalar-only
    /// subset that may cross the wire.
    public var onEvent: ((_ app: String, _ kind: String, _ name: String, _ payload: [String: JSONValue]) -> Void)?

    private let makeSource: SourceFactory
    private var keys: Set<Key> = []
    private var sources: [String: PlatformSignalSource] = [:]

    /// The historical initializer: `distributedNotification` over an injectable
    /// center, and nothing else. Kept because it is the whole surface a test of
    /// that kind needs, and because the shell passes a full factory anyway.
    public convenience init(center: NotificationCenter = DistributedNotificationCenter.default()) {
        self.init(sources: { kind in
            kind == PlatformObserveKind.distributedNotification
                ? NotificationCenterSource(center: center)
                : nil
        })
    }

    public init(sources: @escaping SourceFactory) {
        makeSource = sources
    }

    /// Live registrations, for tests and for the "nothing outlives its worker"
    /// assertion.
    public var registrations: Set<Key> { keys }

    /// Which shared sources are currently started. The other half of the same
    /// assertion: a registry with no registrations must hold no OS resources.
    public var liveSourceKinds: Set<String> { Set(sources.keys) }

    /// Register, idempotently. A second `observe` for the same (app, kind, name)
    /// succeeds and changes nothing — an app that re-declares its observers on
    /// every monitor pass (the obvious way to write it) must not accumulate a
    /// duplicate handler per pass and fire N times per signal.
    @discardableResult
    public func observe(app: String, kind: String, name: String) -> Result<Void, CapabilityError> {
        guard !name.isEmpty else {
            return .failure(CapabilityError("observe needs a name"))
        }
        let started = sources[kind]
        guard let source = started ?? makeSource(kind) else {
            return .failure(CapabilityError("unsupported observe kind '\(kind)'"))
        }
        // The vocabulary check happens before the idempotence check so a typo is
        // always reported, not just the first time.
        if let supported = source.supportedNames, !supported.contains(name) {
            let known = supported.sorted().joined(separator: ", ")
            return .failure(CapabilityError("unknown '\(kind)' signal '\(name)' (known: \(known))"))
        }
        let key = Key(app: app, kind: kind, name: name)
        guard !keys.contains(key) else { return .success(()) }

        if started == nil {
            sources[kind] = source
            source.start { [weak self] firedName, payload in
                self?.deliver(kind: kind, name: firedName, payload: payload)
            }
        }
        keys.insert(key)
        if count(kind: kind, name: name) == 1 { source.addName(name) }

        // Immediate fire (power, reachability, and anything else describing a
        // *state* rather than an edge): without it every such app would need a
        // separate read call for the value it just subscribed to, and would show
        // a blank until the state next happened to change — which for a machine
        // sitting on AC power could be hours.
        if let snapshot = source.snapshot(for: name) {
            onEvent?(app, kind, name, snapshot)
        }
        return .success(())
    }

    /// Unregister. Unobserving something nobody observed is a success, not an
    /// error: the app's intent ("do not watch this") is satisfied either way.
    /// An unknown *kind* is still refused — that is a typo, not a state.
    @discardableResult
    public func unobserve(app: String, kind: String, name: String) -> Result<Void, CapabilityError> {
        guard sources[kind] != nil || makeSource(kind) != nil else {
            return .failure(CapabilityError("unsupported observe kind '\(kind)'"))
        }
        remove(Key(app: app, kind: kind, name: name))
        return .success(())
    }

    /// Drop every registration one app holds. Called at the same lifecycle point
    /// wings are released (§3.3 extension): an observer belongs to a live
    /// worker, and the fresh one re-declares whatever it still wants.
    public func release(app: String) {
        for key in keys where key.app == app { remove(key) }
    }

    /// Drop everything — a new connection generation (spec §1) owns none of it.
    public func releaseAll() {
        for key in keys { remove(key) }
    }

    // MARK: - Internals

    private func count(kind: String, name: String) -> Int {
        keys.reduce(into: 0) { total, key in
            if key.kind == kind, key.name == name { total += 1 }
        }
    }

    private func remove(_ key: Key) {
        guard keys.remove(key) != nil else { return }
        guard let source = sources[key.kind] else { return }
        if count(kind: key.kind, name: key.name) == 0 { source.removeName(key.name) }
        // Zero registrations for this kind ⇒ nothing is listening, so the shared
        // OS resource goes away with them. This is the direction that actually
        // costs something if it is wrong: a pasteboard poll left running is a
        // timer firing twice a second forever, for nobody.
        guard !keys.contains(where: { $0.kind == key.kind }) else { return }
        source.stop()
        sources[key.kind] = nil
    }

    private func deliver(kind: String, name: String, payload: [String: JSONValue]) {
        for key in keys where key.kind == kind && key.name == name {
            onEvent?(key.app, kind, name, payload)
        }
    }

    /// `userInfo` reduced to what may cross the wire: strings, numbers and
    /// bools, keyed by string.
    ///
    /// Everything else is **dropped**, not stringified. A distributed
    /// notification's payload is arbitrary — Music's carries plist values, some
    /// senders carry data blobs — and a shell that helpfully `String(describing:)`d
    /// them would put an unbounded, unparseable blob on a socket whose frame
    /// budget is 8 MiB and whose failure mode is losing the connection (§1).
    /// An app that needs more than a scalar has `ctx.apple` and a real query;
    /// this event's job is to say *when*, not *what*.
    ///
    /// The same rule binds every kind, not just this one: the shell-built
    /// payloads below are scalars by construction.
    nonisolated static func reduce(_ userInfo: [AnyHashable: Any]?) -> [String: JSONValue] {
        guard let userInfo else { return [:] }
        var reduced: [String: JSONValue] = [:]
        for (rawKey, value) in userInfo {
            guard let key = rawKey as? String else { continue }
            switch value {
            case let string as String:
                reduced[key] = .string(string)
            case let number as NSNumber:
                // NSNumber is where a plist's bools, ints and doubles all land,
                // and they are only distinguishable by the ObjC type encoding.
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    reduced[key] = .bool(number.boolValue)
                } else {
                    reduced[key] = .double(number.doubleValue)
                }
            case let flag as Bool:
                reduced[key] = .bool(flag)
            default:
                continue
            }
        }
        return reduced
    }
}
