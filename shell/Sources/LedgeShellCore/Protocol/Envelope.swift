import Foundation

/// The message envelope shared by both directions (spec §2). Unknown payload
/// shape is preserved as a `JSONValue` so a frame can be routed by `type`
/// before it is interpreted, and so invalid fixtures carrying an `_expect`
/// hint decode without error (extra keys are ignored by Codable).
public struct Envelope: Codable, Sendable, Equatable {
    public var v: Int
    public var app: String
    public var seq: Int
    public var type: String
    public var payload: JSONValue

    public init(v: Int = 1, app: String, seq: Int, type: String, payload: JSONValue) {
        self.v = v
        self.app = app
        self.seq = seq
        self.type = type
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case v, app, seq, type, payload
    }
}

/// Screen geometry exchanged in `hello` (§4.3) and `lifecycle` (§4.2).
public struct ScreenInfo: Codable, Sendable, Equatable {
    public var notchWidth: Double
    public var menubarHeight: Double
    public var scale: Double
    public var maxPanelHeight: Double?

    public init(
        notchWidth: Double,
        menubarHeight: Double,
        scale: Double,
        maxPanelHeight: Double? = nil
    ) {
        self.notchWidth = notchWidth
        self.menubarHeight = menubarHeight
        self.scale = scale
        self.maxPanelHeight = maxPanelHeight
    }
}

// MARK: - Inbound payloads (host → shell)

public struct HelloHostPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var host: String
}

/// The panel size an app declared in its `meta` (spec §5, extended by the
/// app-declared `meta.panel`). Both fields optional and both are *requests* —
/// the shell owns the screen and clamps them (`PanelLimits`).
public struct PanelSpec: Codable, Sendable, Equatable {
    public var width: Double?
    public var maxHeight: Double?

    public init(width: Double? = nil, maxHeight: Double? = nil) {
        self.width = width
        self.maxHeight = maxHeight
    }
}

public struct CatalogApp: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var icon: String
    public var order: Int
    public var enabled: Bool
    public var running: Bool
    /// Absent for an app that declared no `meta.panel` — the shell's defaults.
    public var panel: PanelSpec?

    public init(
        id: String,
        name: String,
        icon: String,
        order: Int,
        enabled: Bool,
        running: Bool,
        panel: PanelSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.order = order
        self.enabled = enabled
        self.running = running
        self.panel = panel
    }

    /// The icon as a **symbol name**. The wire spells it `"sf:<symbol>"` (spec
    /// §3.6, and §5's `icon` prop); every surface that draws one wants the name
    /// without the scheme, and three places in the renderer were each dropping
    /// the first three characters by hand.
    public var symbolName: String {
        icon.hasPrefix("sf:") ? String(icon.dropFirst(3)) : icon
    }
}

public struct CatalogPayload: Codable, Sendable, Equatable {
    public var apps: [CatalogApp]
    public init(apps: [CatalogApp]) { self.apps = apps }
}

public struct CommitPayload: Codable, Sendable, Equatable {
    public var mutations: [Mutation]
    public init(mutations: [Mutation]) { self.mutations = mutations }
}

public struct ErrorInfo: Codable, Sendable, Equatable {
    public var message: String
    public var stack: String?
}

/// `app` lifecycle from the host (§3.2). `type` is `"app"`.
public struct AppLifecyclePayload: Codable, Sendable, Equatable {
    public var state: String
    public var error: ErrorInfo?
}

/// A drawable strip in the right wing (spec §3.3 extension). `id` is the app's
/// own canvas node id — the same id its `draw` frames target (§3.4).
public struct WingCanvasSpec: Codable, Sendable, Equatable {
    public var id: Int
    public var w: Double

    public init(id: Int, w: Double) {
        self.id = id
        self.w = w
    }
}

/// A shell-drawn bar in the right wing (spec §3.3 extension) — flow.md's
/// **meter**, the third of the four wing forms. The app supplies a fraction and
/// nothing else: width, thickness, radius and ink belong to the shell, which is
/// the difference between a vocabulary and every app drawing its own bar.
public struct WingMeterSpec: Codable, Sendable, Equatable {
    /// `0…1`. Clamped on read (`fraction`) as well as by the host, because a
    /// fill wider than its own track is the one thing this must never draw.
    public var value: Double

    public init(value: Double) {
        self.value = value
    }

    /// The value as something safe to multiply a width by. A non-finite value
    /// reads as empty rather than as a NaN frame.
    public var fraction: Double {
        value.isFinite ? Swift.min(1, Swift.max(0, value)) : 0
    }
}

/// What an app wants the collapsed notch to look like (spec §3.3 extension):
/// a label in the left wing, a canvas strip or a meter in the right wing,
/// and/or a bare total-width request for shape-only animation.
public struct WingSpec: Codable, Sendable, Equatable {
    public var text: String?
    public var width: Double?
    public var canvas: WingCanvasSpec?
    /// The right wing's stock form. A spec carrying both this and a `canvas` is
    /// two claims on one wing: the canvas wins, because those are the app's own
    /// pixels and this is a shape the shell could always draw somewhere else.
    public var meter: WingMeterSpec?

    public init(
        text: String? = nil,
        width: Double? = nil,
        canvas: WingCanvasSpec? = nil,
        meter: WingMeterSpec? = nil
    ) {
        self.text = text
        self.width = width
        self.canvas = canvas
        self.meter = meter
    }

    /// A wing with nothing in it at all is indistinguishable from no wing.
    public var isEmpty: Bool { text == nil && width == nil && canvas == nil && meter == nil }
}

/// `chrome` (spec §3.3): `expand`/`collapse`/`attention`, plus the `wing` and
/// `peek` requests this phase adds. Each extra field belongs to exactly one
/// request — `wing` to `"wing"` (null/absent there means "release the notch"),
/// `ms` to `"peek"` — so the shell reads the field its verb names and ignores
/// the rest, and a new request stays a new *value* rather than a new envelope.
public struct ChromePayload: Codable, Sendable, Equatable {
    public var request: String
    public var wing: WingSpec?
    /// Peek dwell in milliseconds. Absent means the shell's own default; the
    /// host has already clamped anything an app asked for.
    public var ms: Double?
    /// `class` on the wire (a Swift keyword here, hence the rename): which
    /// priority class a notification belongs to — `"ambient"` or `"alert"`.
    ///
    /// It is the whole of flow.md's "Ti ≈ 6 s for ambient-class, alert-class
    /// holds". An ambient notification retracts on its dwell; an alert holds
    /// until it is acted on or dismissed, because the one thing an alert must
    /// not do is time out while the user is looking away. Absent is ambient —
    /// an app that says nothing is not raising an alarm.
    public var priority: NotificationClass?

    enum CodingKeys: String, CodingKey {
        case request
        case wing
        case ms
        case priority = "class"
    }

    public init(
        request: String,
        wing: WingSpec? = nil,
        ms: Double? = nil,
        priority: NotificationClass? = nil
    ) {
        self.request = request
        self.wing = wing
        self.ms = ms
        self.priority = priority
    }
}

/// The two notification classes (flow.md, "Knobs"). Urgency is *ink*, never
/// geometry (flow.md, Edges: "the holder's content turns red and pulses twice")
/// — so the only thing this changes is how long the swell stays up.
public enum NotificationClass: String, Codable, Sendable, Equatable {
    /// Retracts on `Ti`.
    case ambient
    /// Holds until acted on or dismissed.
    case alert

    /// An unknown class is ambient. A forward-compatible wire never turns a
    /// value the shell has not heard of into a swell that never goes away.
    public init(token: String?) {
        self = NotificationClass(rawValue: token ?? "") ?? .ambient
    }
}

/// Imperative canvas draw (§3.4). Ops stay as raw JSON — the renderer interprets
/// the small op vocabulary and skips unknown ops without a version bump.
public struct DrawPayload: Codable, Sendable, Equatable {
    public var id: Int
    public var ops: [JSONValue]

    /// Only decoded in the live path; constructed by the snapshot replay, which
    /// synthesises the frames a monitor drew during its capture window.
    public init(id: Int, ops: [JSONValue]) {
        self.id = id
        self.ops = ops
    }
}

/// `native` transducer install (§3.5). Only `install` arrives from the host;
/// `checkpoint` flows the other way.
public struct NativeInstallPayload: Codable, Sendable, Equatable {
    public var action: String
    public var canvas: Int
    public var hash: String
    public var code: String
    public var initial: JSONValue
}

// MARK: - Capabilities (the agentic layer: spec §6 `ctx.apple`, notifications,
// `ctx.capture`). All three are the same shape of thing: the worker cannot do
// them, because doing them means owning a TCC prompt, and TCC attributes to the
// process with the UI — the shell. So each is a host → shell *request* carrying
// a worker-allocated `id`, and a shell → host *result* carrying it back.

/// What an `apple` request actually asks for, once its `kind` has been checked.
/// Decoding to this enum is the validation: a request whose kind is unknown, or
/// whose payload is missing the field that kind needs, never reaches an
/// executor.
public enum AppleInvocation: Sendable, Equatable {
    case script(String)
    case shortcut(name: String, input: JSONValue?)
}

/// `apple` (spec §6) — AppleScript or a Shortcut, executed by the shell.
/// `source` belongs to `kind: "script"`, `name`/`input` to `kind: "shortcut"`.
public struct ApplePayload: Codable, Sendable, Equatable {
    public var id: Int
    public var kind: String
    public var source: String?
    public var name: String?
    public var input: JSONValue?

    public init(
        id: Int,
        kind: String,
        source: String? = nil,
        name: String? = nil,
        input: JSONValue? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.name = name
        self.input = input
    }

    /// The validated invocation, or nil for an unknown kind / a missing field.
    public var invocation: AppleInvocation? {
        switch kind {
        case "script":
            guard let source, !source.isEmpty else { return nil }
            return .script(source)
        case "shortcut":
            guard let name, !name.isEmpty else { return nil }
            return .shortcut(name: name, input: input)
        default:
            return nil
        }
    }
}

/// `appleResult` (shell → host): settles one `apple` request by `id`. `value` on
/// success, `error` on failure; a result whose id the host no longer knows is
/// dropped there (the request already timed out, or its worker was replaced).
public struct AppleResultPayload: Codable, Sendable, Equatable {
    public var id: Int
    public var ok: Bool
    public var value: JSONValue?
    public var error: String?

    public init(id: Int, ok: Bool, value: JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.value = value
        self.error = error
    }

    public static func success(id: Int, value: JSONValue) -> Self {
        Self(id: id, ok: true, value: value)
    }

    public static func failure(id: Int, error: String) -> Self {
        Self(id: id, ok: false, error: error)
    }
}

/// One button on a notification (spec §6 `ctx.notify` extension). `id` is the
/// app's own token — it comes back verbatim in `notifyAction`.
public struct NotifyActionSpec: Codable, Sendable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// `notify` (spec §6): a user notification posted by the shell, because
/// notification authorization is per-bundle and the shell is the bundle. `id`
/// is the worker's notification id, echoed back by `notifyAction`.
public struct NotifyPayload: Codable, Sendable, Equatable {
    public var id: Int
    public var text: String
    public var title: String?
    public var actions: [NotifyActionSpec]?

    public init(id: Int, text: String, title: String? = nil, actions: [NotifyActionSpec]? = nil) {
        self.id = id
        self.text = text
        self.title = title
        self.actions = actions
    }
}

/// `notifyAction` (shell → host): the user pressed a button on notification
/// `id`. Delivered to the app as the id-0 app-level `notification` event.
public struct NotifyActionPayload: Codable, Sendable, Equatable {
    public var id: Int
    public var action: String

    public init(id: Int, action: String) {
        self.id = id
        self.action = action
    }
}

/// `capture` (spec §6 extension): an interactive screenshot taken by the shell,
/// which is also what makes the Screen Recording prompt attribute to Ledge.
public struct CapturePayload: Codable, Sendable, Equatable {
    public var id: Int
    /// Absent means interactive (region select) — the useful default.
    public var interactive: Bool?

    public init(id: Int, interactive: Bool? = nil) {
        self.id = id
        self.interactive = interactive
    }

    public var isInteractive: Bool { interactive ?? true }
}

/// `captureResult` (shell → host): the path of a shell-owned temp PNG, or the
/// reason there isn't one (the user cancelled the selection, most often).
public struct CaptureResultPayload: Codable, Sendable, Equatable {
    public var id: Int
    public var ok: Bool
    public var path: String?
    public var error: String?

    public init(id: Int, ok: Bool, path: String? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.path = path
        self.error = error
    }

    public static func success(id: Int, path: String) -> Self {
        Self(id: id, ok: true, path: path)
    }

    public static func failure(id: Int, error: String) -> Self {
        Self(id: id, ok: false, error: error)
    }
}

/// What a `platform` envelope actually asks for, once its `call` has been
/// checked and the fields that call needs have been found. Decoding to this enum
/// **is** the validation, exactly as `AppleInvocation` is for `apple`: a request
/// whose call is unknown, or which is missing the field its call needs, never
/// reaches an executor — it is answered `ok: false` instead.
///
/// Two families share the envelope on purpose. `observe`/`unobserve` are
/// registry verbs, answered synchronously (registration either happened or it
/// didn't). The rest are request/reply calls that produce a value and settle on
/// a later turn — the same shape `apple` and `capture` already have.
public enum PlatformCall: Sendable, Equatable {
    case observe(kind: String, name: String)
    case unobserve(kind: String, name: String)
    /// ISO-8601 strings as the app wrote them; range defaulting and the 14-day
    /// cap are the executor's, so the wire stays a faithful record of the ask.
    case calendar(from: String?, to: String?)
    case workspace
    case location
    case spotlight(query: String, scopes: [String]?)
    case audio
    case setVolume(Double)
    case speak(text: String, voice: String?, rate: Double?)
    /// `ctx.record.*` (G3): the four verbs of the audio-capture capability.
    /// Start carries what to record and in what container; the other three are
    /// bare verbs whose only context is the envelope's own `app`.
    case recordStatus
    case recordStart(sources: [RecordingSource], format: RecordingFormat)
    case recordStop
    case recordLevels
    /// End the process. Settings only, and the only quit the user has: there is
    /// no menu-bar item and no Dock icon (see `AppDelegate`).
    case quit

    /// Registry verbs answer synchronously; everything else goes to the
    /// executor and settles later.
    public var isObserveVerb: Bool {
        switch self {
        case .observe, .unobserve: true
        default: false
        }
    }
}

/// `platform` (spec §6 extension, `ctx.platform.*`): the app asks the shell to
/// watch an OS-level signal on its behalf and push an event back when it fires —
/// the invalidation half of a polling monitor — or to answer one question only
/// the shell process can answer (the calendar, the frontmost app, a location
/// fix, a Spotlight query, the audio device, the speech synthesizer).
///
/// `call` is the verb, and each verb reads the fields it needs and ignores the
/// rest. That keeps one envelope for the whole surface: a new call is a new
/// `call` value plus optional fields, never a new envelope type, and an older
/// shell answers `ok: false` for a call it has never heard of rather than
/// leaving the app's Promise hanging.
///
/// For `observe`/`unobserve`, `kind` is the *source* being watched — a second
/// axis from `call`, which is why they are two fields.
public struct PlatformPayload: Codable, Sendable, Equatable {
    /// The original observe source, kept as a name for the fixtures and tests
    /// written against it. The full vocabulary lives in `PlatformObserveKind`.
    public static let distributedNotification = PlatformObserveKind.distributedNotification

    public var id: Int
    public var call: String
    // observe / unobserve
    public var kind: String?
    public var name: String?
    // calendar
    public var from: String?
    public var to: String?
    // spotlight
    public var query: String?
    public var scopes: [String]?
    // setVolume
    public var value: Double?
    // speak
    public var text: String?
    public var voice: String?
    public var rate: Double?
    // recordStart
    public var sources: [String]?
    public var format: String?

    public init(
        id: Int,
        call: String,
        kind: String? = nil,
        name: String? = nil,
        from: String? = nil,
        to: String? = nil,
        query: String? = nil,
        scopes: [String]? = nil,
        value: Double? = nil,
        text: String? = nil,
        voice: String? = nil,
        rate: Double? = nil,
        sources: [String]? = nil,
        format: String? = nil
    ) {
        self.id = id
        self.call = call
        self.kind = kind
        self.name = name
        self.from = from
        self.to = to
        self.query = query
        self.scopes = scopes
        self.value = value
        self.text = text
        self.voice = voice
        self.rate = rate
        self.sources = sources
        self.format = format
    }

    /// The validated call, or nil for an unknown verb / a missing field.
    public var invocation: PlatformCall? {
        switch call {
        case "observe", "unobserve":
            guard let kind, !kind.isEmpty, let name, !name.isEmpty else { return nil }
            return call == "observe"
                ? .observe(kind: kind, name: name)
                : .unobserve(kind: kind, name: name)
        case "calendar":
            return .calendar(from: from, to: to)
        case "workspace":
            return .workspace
        case "location":
            return .location
        case "spotlight":
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return .spotlight(query: query, scopes: scopes)
        case "audio":
            return .audio
        case "setVolume":
            // A missing or non-finite volume is a malformed request, not a 0:
            // silently muting the machine is the worst possible reading of a typo.
            guard let value, value.isFinite else { return nil }
            return .setVolume(value)
        case "speak":
            guard let text, !text.isEmpty else { return nil }
            return .speak(text: text, voice: voice, rate: rate)
        case "recordStatus":
            return .recordStatus
        case "recordStart":
            // Defaults live here, not in the executor: "record" with no fields
            // means both sources in AAC, and a source or format the shell has
            // never heard of is a malformed request, not a silent drop of one
            // stream — half a recording is the worst possible reading.
            let named = sources ?? RecordingSource.allCases.map(\.rawValue)
            var parsed: [RecordingSource] = []
            for raw in named {
                guard let source = RecordingSource(rawValue: raw) else { return nil }
                if !parsed.contains(source) { parsed.append(source) }
            }
            guard !parsed.isEmpty else { return nil }
            guard let container = RecordingFormat(rawValue: format ?? "aac") else { return nil }
            return .recordStart(sources: parsed.sorted(), format: container)
        case "recordStop":
            return .recordStop
        case "recordLevels":
            return .recordLevels
        case "quit":
            // No fields: the envelope's own `app` is the only context there is,
            // and quitting takes no argument.
            return .quit
        default:
            return nil
        }
    }

    /// Whether this is a request the shell knows how to answer at all. Checked
    /// before the capability host is consulted, so a typo answers `ok: false`
    /// instead of registering nothing and looking like it worked.
    public var isSupported: Bool { invocation != nil }
}

/// `platformResult` (shell → host): settles one `platform` request by `id`.
///
/// Registration is instant, so for `observe`/`unobserve` this is an
/// acknowledgement rather than a value — but the app awaits it, and an
/// unsupported kind has to be answerable. The value-producing calls (calendar,
/// workspace, location, spotlight, audio, setVolume) carry their answer in
/// `data`, which is absent — not null — for the calls that have none.
public struct PlatformResultPayload: Codable, Sendable, Equatable {
    public var id: Int
    public var ok: Bool
    public var data: JSONValue?
    public var error: String?

    public init(id: Int, ok: Bool, data: JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.data = data
        self.error = error
    }

    public static func success(id: Int, data: JSONValue? = nil) -> Self {
        Self(id: id, ok: true, data: data)
    }

    public static func failure(id: Int, error: String) -> Self {
        Self(id: id, ok: false, error: error)
    }
}

/// One event of an app's builder stream (spec §3.6). Every field past `event` is
/// optional because the shape is per-event, not per-payload: a `text` carries a
/// `delta`, a `tool` a `name`/`detail`/`state`, a `done` a `status`.
///
/// Two generations of field names coexist deliberately. The spec's first draft
/// wrote status as `{ state, ms }` and completion as `{ ok }`; the adapters now
/// emit `{ text }` and `{ status }` (interrupted is neither ok nor an error, and
/// `ok: false` could not say so). Both decode, and `EditorBridge` normalises to
/// the newer shape before the page ever sees an event — so a host mid-rewrite
/// never blanks the editor, and the page has exactly one shape to render.
public struct BuilderPayload: Codable, Sendable, Equatable {
    /// The app this belongs to.
    ///
    /// Filled from the **envelope**, not the payload. Spec §2 puts `app` on every
    /// envelope, and §3.6's examples show whole frames rather than payloads — so
    /// the host quite correctly sends only `{turn, …event}` here. Requiring it in
    /// the payload made every real builder event fail to decode, and the decode
    /// site is a `guard … else { return }`: the entire stream vanished with no
    /// error anywhere. Defaulted rather than optional so nothing downstream has
    /// to unwrap a value the engine always sets.
    public var app: String = ""
    /// Which exchange this belongs to, so the editor can group a turn. Defaulted
    /// for the same reason: a missing field must never cost the whole event.
    public var turn: Int = 0
    public var event: String
    public var delta: String?
    public var name: String?
    public var detail: String?
    public var state: String?
    public var ms: Int?
    public var ok: Bool?
    /// `status` events: the line to show, already phrased by the adapter.
    public var text: String?
    /// `done` events: `completed` | `interrupted` | `failed`.
    public var status: String?
    /// `error` events: the agent's own failure text, passed through verbatim.
    public var message: String?
    /// `agent` events: whether the agent this build talks to is installed. Not a
    /// turn and not an app's — it is the condition every turn depends on, sent
    /// once per session before anything is typed.
    public var installed: Bool?
    /// `agent` events: the command that installs it, when it is missing.
    public var install: String?

    /// Every field is decode-if-present. The builder stream is the one place a
    /// third party (the agent adapter) shapes a payload, so a field we did not
    /// expect must cost that field and nothing more — never the event, and never
    /// the rest of the turn behind it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decodeIfPresent(String.self, forKey: .app) ?? ""
        turn = try container.decodeIfPresent(Int.self, forKey: .turn) ?? 0
        event = try container.decodeIfPresent(String.self, forKey: .event) ?? ""
        delta = try container.decodeIfPresent(String.self, forKey: .delta)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        ms = try container.decodeIfPresent(Int.self, forKey: .ms)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed)
        install = try container.decodeIfPresent(String.self, forKey: .install)
    }

    public init(
        app: String = "",
        turn: Int = 0,
        event: String,
        delta: String? = nil,
        name: String? = nil,
        detail: String? = nil,
        state: String? = nil,
        ms: Int? = nil,
        ok: Bool? = nil,
        text: String? = nil,
        status: String? = nil,
        message: String? = nil,
        installed: Bool? = nil,
        install: String? = nil
    ) {
        self.app = app
        self.turn = turn
        self.event = event
        self.delta = delta
        self.name = name
        self.detail = detail
        self.state = state
        self.ms = ms
        self.ok = ok
        self.text = text
        self.status = status
        self.message = message
        self.installed = installed
        self.install = install
    }
}

// MARK: - Envelope typed decoding

public enum EnvelopeType: String, Sendable {
    case hello
    case catalog
    case commit
    case app
    case chrome
    case draw
    case native
    case builder
    case apple
    case notify
    case capture
    case platform
    case platformResult
    case event
    case lifecycle
    case selection
    case builderInput
    /// The shell asking the host to stop a session (spec §4.3 extension) — the
    /// ledge's ✕, and nothing else sends it. A control-plane frame like
    /// `selection`: the envelope's `app` is `""` and the target is in the
    /// payload, because it is a statement *about* an app rather than one made by
    /// it.
    case appControl
    case resyncRequest
    case appleResult
    case notifyAction
    case captureResult
}

public extension Envelope {
    var kind: EnvelopeType? { EnvelopeType(rawValue: type) }

    /// Re-decode this envelope's payload into a concrete Codable payload type.
    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public extension JSONValue {
    /// Re-encode a Codable payload as a `JSONValue` so it can ride in an
    /// envelope. Optionals that are nil encode to absent keys (Codable's
    /// synthesized `encodeIfPresent`), which is what keeps `{ ok: true }`
    /// results free of a null `error`.
    static func encoding(_ value: some Encodable) -> JSONValue {
        guard
            let data = try? JSONEncoder().encode(value),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return json
    }
}
