import Foundation

/// AppKit-facing side effects the engine drives. All calls land on the main
/// actor; the transport hops decoded frames onto main before `receive`.
@MainActor
public protocol ProtocolEngineDelegate: AnyObject {
    /// Apply a fully validated mutation list to the real view tree for `app`
    /// (spec §3.1). Guaranteed to already have passed shadow-tree validation, so
    /// the renderer can apply it inside one CATransaction without re-checking.
    func applyCommit(app: String, mutations: [Mutation])

    /// Discard all view state for one app (resync, reload teardown).
    func discardApp(_ app: String)

    /// Discard all per-app view state (reconnect / new generation, spec §1).
    func discardAllApps()

    /// Show the built-in error card for a crashed app (spec §3.2 / §7).
    func showErrorCard(app: String, message: String, stack: String?)

    /// A non-crash lifecycle transition (`started`/`reloaded`/`stopped`).
    func appLifecycle(app: String, state: String)

    /// App-level chrome request (`expand`/`collapse`/`attention`, spec §3.3),
    /// plus this phase's `wing` (§3.3 extension) whose payload rides along —
    /// `wing` is non-nil only for `request == "wing"` with a spec attached; a
    /// `wing` request with a nil spec releases the notch.
    func chromeRequest(app: String, request: String, wing: WingSpec?)

    /// Blit coalesced draw ops to one app's canvas (spec §3.4). Called on flush.
    /// Scoped by app because node ids restart at 1 per worker (§3.1).
    func drawCanvas(app: String, id: Int, ops: [JSONValue])

    /// The installed-app catalog changed (spec §3.6). Full snapshot.
    func catalogUpdated(_ catalog: CatalogPayload)

    /// A builder chat event for an app's chat surface (spec §3.6).
    func builderEvent(_ payload: BuilderPayload)
}

/// Why a capability failed, in words an app can log. Capability failures are
/// ordinary results, not stream errors: a cancelled screenshot or a missing
/// Shortcut must never cost the connection.
public struct CapabilityError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public typealias AppleCompletion = @MainActor @Sendable (Result<JSONValue, CapabilityError>) -> Void
public typealias CaptureCompletion = @MainActor @Sendable (Result<String, CapabilityError>) -> Void

/// The side effects only the *shell process* can perform (spec §6): AppleScript
/// and Shortcuts, user notifications, screen capture. They are deliberately a
/// **separate** delegate from `ProtocolEngineDelegate`: rendering a view tree
/// and driving macOS on an app's behalf are unrelated jobs, and the renderer
/// should not have to know that the second one exists. An engine with no
/// capability delegate (the snapshot replay, every headless test that doesn't
/// opt in) answers requests with a plain "unsupported" result rather than
/// leaving the app's Promise hanging.
@MainActor
public protocol CapabilityDelegate: AnyObject {
    /// Run AppleScript / a Shortcut and settle the request (spec §6). The
    /// completion may fire on a later turn — execution is off the main queue.
    func runApple(_ invocation: AppleInvocation, app: String, completion: @escaping AppleCompletion)

    /// Post a user notification, optionally with action buttons. Fire and
    /// forget: a pressed button comes back as `notifyAction`, nothing else does.
    func postNotification(_ notification: NotifyPayload, app: String)

    /// Take a screenshot into a shell-owned temp file and settle with its path.
    func captureScreen(interactive: Bool, app: String, completion: @escaping CaptureCompletion)

    /// `ctx.platform.observe` (spec §6 extension): start watching an OS signal
    /// for `app`. Synchronous — registration either happens or it doesn't; there
    /// is nothing to wait for, so the result is an answer rather than a promise.
    /// Must be idempotent per (app, kind, name).
    func observePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError>

    /// `ctx.platform.unobserve`. Unregistering something nobody registered is a
    /// success: the app asked for a state, not for an event.
    func unobservePlatform(kind: String, name: String, app: String) -> Result<Void, CapabilityError>

    /// Drop every observer one app holds — its worker is gone or being replaced.
    func releasePlatformObservers(app: String)

    /// Drop every observer, full stop: a new connection generation owns none of
    /// the previous one's presentation or subscription state (spec §1).
    func releaseAllPlatformObservers()

    /// The request/reply half of `ctx.platform` (spec §6 extension): calendar,
    /// workspace, location, spotlight, audio, setVolume, speak. Unlike the
    /// registry verbs above these produce a *value* and settle on a later turn,
    /// exactly like `runApple` — some of them wait on a TCC prompt, which is a
    /// person.
    ///
    /// Defaulted so a capability host that predates these calls (and every test
    /// double that only cares about routing) keeps compiling and answers
    /// honestly rather than leaving the app's Promise hanging.
    func runPlatformCall(_ call: PlatformCall, app: String, completion: @escaping PlatformCompletion)
}

public extension CapabilityDelegate {
    func runPlatformCall(_ call: PlatformCall, app: String, completion: @escaping PlatformCompletion) {
        completion(.failure(CapabilityError("this shell cannot answer platform calls")))
    }
}

/// The control plane + commit pipeline (spec §§1–4). Owns the shadow tree per
/// app, sequence gating, outbound sequencing, the draw coalescer, and the native
/// transducer host. AppKit rendering is delegated; the socket is abstracted to a
/// `send` closure so the engine is fully testable headlessly.
@MainActor
public final class ProtocolEngine {
    public private(set) var generation: Int = 0
    public private(set) var helloComplete = false

    private weak var delegate: ProtocolEngineDelegate?
    /// Executes `apple`/`notify`/`capture` (spec §6). Optional by design — see
    /// `CapabilityDelegate`; nil means "this shell can't", answered as a result.
    public weak var capabilities: CapabilityDelegate?
    private let send: (Envelope) -> Void
    private var screen: ScreenInfo

    private var shadows: [String: ShadowTree] = [:]
    private var inbound = SeqGate()
    private var outboundSeq: [String: Int] = [:]
    private var coalescer = DrawCoalescer()
    public let native: NativeHost

    public init(
        screen: ScreenInfo,
        delegate: ProtocolEngineDelegate,
        transducer: TransducerExecutor = ScriptedTransducer(),
        send: @escaping (Envelope) -> Void
    ) {
        self.screen = screen
        self.delegate = delegate
        self.send = send
        self.native = NativeHost(executor: transducer)
    }

    // MARK: - Connection lifecycle (spec §1)

    /// A new connection was accepted. Bump the generation and discard everything
    /// scoped to the dead one — reconnect expects fresh commits.
    public func connectionOpened(generation: Int) {
        self.generation = generation
        helloComplete = false
        shadows.removeAll()
        inbound = SeqGate()
        outboundSeq.removeAll()
        coalescer.discardAll()
        native.removeAll()
        // Observers are subscription state scoped to the dead generation, the
        // same way wings are presentation state scoped to it (§1).
        capabilities?.releaseAllPlatformObservers()
        delegate?.discardAllApps()
    }

    /// The connection dropped. View state is already dead for this generation;
    /// the next `connectionOpened` will rescope everything.
    public func connectionClosed() {
        helloComplete = false
        coalescer.discardAll()
        native.removeAll()
        capabilities?.releaseAllPlatformObservers()
    }

    public func updateScreen(_ screen: ScreenInfo) { self.screen = screen }

    // MARK: - Inbound dispatch (spec §3)

    /// Handle one decoded envelope. Returns false only when the frame is
    /// rejected for a reason that does not itself require closing the stream
    /// (version mismatch, stale seq) — malformed framing/JSON is handled by the
    /// transport, which closes the connection.
    @discardableResult
    public func receive(_ envelope: Envelope) -> Bool {
        guard envelope.v == 1 else { return false }          // version mismatch → drop (§2)
        guard inbound.accept(app: envelope.app, seq: envelope.seq) else {
            return false                                     // stale seq → drop (§2)
        }
        guard let kind = envelope.kind else { return false }

        switch kind {
        case .hello:      handleHello(envelope)
        case .catalog:    handleCatalog(envelope)
        case .commit:     handleCommit(envelope)
        case .app:        handleAppLifecycle(envelope)
        case .chrome:     handleChrome(envelope)
        case .draw:       handleDraw(envelope)
        case .native:     handleNative(envelope)
        case .builder:    handleBuilder(envelope)
        case .apple:      handleApple(envelope)
        case .notify:     handleNotify(envelope)
        case .capture:    handleCapture(envelope)
        case .platform:   handlePlatform(envelope)
        // Shell → host types are never received; ignore if echoed.
        case .event, .lifecycle, .selection, .builderInput, .resyncRequest,
             .appleResult, .notifyAction, .captureResult, .platformResult:
            return false
        }
        return true
    }

    private func handleHello(_ envelope: Envelope) {
        guard (try? envelope.decodePayload(HelloHostPayload.self)) != nil else { return }
        // Reply with our own hello carrying the generation and screen (§4.3).
        var payloadScreen = screen
        if payloadScreen.maxPanelHeight == nil { payloadScreen.maxPanelHeight = 480 }
        let payload: [String: JSONValue] = [
            "v": .int(1),
            "gen": .int(generation),
            "screen": screenJSON(payloadScreen),
        ]
        emit(app: "", type: .hello, payload: .object(payload))
        helloComplete = true
    }

    private func handleCatalog(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(CatalogPayload.self) else { return }
        delegate?.catalogUpdated(payload)
    }

    private func handleCommit(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(CommitPayload.self) else { return }
        let app = envelope.app
        let shadow = shadows[app] ?? {
            let tree = ShadowTree()
            shadows[app] = tree
            return tree
        }()
        switch shadow.apply(payload.mutations) {
        case .success:
            delegate?.applyCommit(app: app, mutations: payload.mutations)
            // Drop any pending draws for canvases removed by this commit.
        case .failure:
            // The shadow tree is untouched on failure; ask for a fresh commit.
            sendResyncRequest(app: app)
        }
    }

    private func handleAppLifecycle(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(AppLifecyclePayload.self) else { return }
        let app = envelope.app
        // Every one of these transitions replaces or ends the worker that asked,
        // so its platform observers go with it — the same rule, at the same
        // point, as the wing release the host performs on its own side (§3.3
        // extension; §6 rule 3: nothing lands after death).
        capabilities?.releasePlatformObservers(app: app)
        switch payload.state {
        case "crashed":
            delegate?.showErrorCard(
                app: app,
                message: payload.error?.message ?? "The app crashed.",
                stack: payload.error?.stack
            )
        case "started", "reloaded":
            // A freshly spawned or hot-reloaded worker restarts its node ids at 1
            // (spec §3.1) — so the full mount commit that follows this envelope
            // would collide with the previous session's shadow-tree ids
            // (duplicateCreate → failed validation → resync loop) unless we reset
            // first. Drop this app's shadow tree AND its rendered views here; the
            // next `commit` allocates a fresh ShadowTree and mounts clean. Seq
            // scoping is untouched: the host's per-app outbound seq is continuous
            // across a reload (same connection generation), so gating still holds.
            shadows[app] = nil
            // The canvases those frames were addressed to no longer exist.
            coalescer.discard(app: app)
            delegate?.discardApp(app)
            delegate?.appLifecycle(app: app, state: payload.state)
        case "stopped":
            shadows[app] = nil
            // The canvases those frames were addressed to no longer exist.
            coalescer.discard(app: app)
            delegate?.discardApp(app)
            delegate?.appLifecycle(app: app, state: payload.state)
        default:
            delegate?.appLifecycle(app: app, state: payload.state)
        }
    }

    private func handleChrome(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(ChromePayload.self) else { return }
        // An empty wing object carries no instruction; treat it as a release so
        // the shell never has to reason about "a wing that shows nothing".
        let wing = payload.wing.flatMap { $0.isEmpty ? nil : $0 }
        delegate?.chromeRequest(app: envelope.app, request: payload.request, wing: wing)
    }

    private func handleDraw(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(DrawPayload.self) else { return }
        coalescer.submit(app: envelope.app, canvas: payload.id, ops: payload.ops)
    }

    private func handleNative(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(NativeInstallPayload.self),
              payload.action == "install" else { return }
        native.install(
            canvas: payload.canvas,
            hash: payload.hash,
            code: payload.code,
            initial: payload.initial
        )
        // Seed input on install (§3.5).
        _ = feedTransducer(app: envelope.app, canvas: payload.canvas, input: .seed(value: 0))
    }

    private func handleBuilder(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(BuilderPayload.self) else { return }
        delegate?.builderEvent(payload)
    }

    // MARK: - Capabilities (spec §6)

    /// `apple` — validate the request, hand it to the capability delegate, and
    /// answer with `appleResult` either way. A malformed request is answered
    /// rather than dropped: the app is awaiting a Promise, and a silent drop
    /// would hang it until the host's own timeout fires.
    private func handleApple(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(ApplePayload.self) else { return }
        let app = envelope.app
        guard let invocation = payload.invocation else {
            sendAppleResult(app: app, .failure(id: payload.id, error: "malformed apple request (kind '\(payload.kind)')"))
            return
        }
        guard let capabilities else {
            sendAppleResult(app: app, .failure(id: payload.id, error: "this shell has no AppleScript capability"))
            return
        }
        capabilities.runApple(invocation, app: app) { [weak self] result in
            switch result {
            case let .success(value):
                self?.sendAppleResult(app: app, .success(id: payload.id, value: value))
            case let .failure(error):
                self?.sendAppleResult(app: app, .failure(id: payload.id, error: error.message))
            }
        }
    }

    /// `notify` — fire and forget. There is no `notifyResult`: `ctx.notify` does
    /// not await anything, and inventing an ack would make every app pay for a
    /// round trip none of them use.
    private func handleNotify(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(NotifyPayload.self) else { return }
        capabilities?.postNotification(payload, app: envelope.app)
    }

    private func handleCapture(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(CapturePayload.self) else { return }
        let app = envelope.app
        guard let capabilities else {
            sendCaptureResult(app: app, .failure(id: payload.id, error: "this shell has no capture capability"))
            return
        }
        capabilities.captureScreen(interactive: payload.isInteractive, app: app) { [weak self] result in
            switch result {
            case let .success(path):
                self?.sendCaptureResult(app: app, .success(id: payload.id, path: path))
            case let .failure(error):
                self?.sendCaptureResult(app: app, .failure(id: payload.id, error: error.message))
            }
        }
    }

    /// `platform` — the whole of `ctx.platform` (spec §6 extension).
    ///
    /// Two families, one envelope. `observe`/`unobserve` are registry verbs:
    /// answered synchronously, and always answered, because "I registered
    /// nothing" has to be distinguishable from "I registered it" or an app will
    /// happily rely on an event that can never arrive. The rest are calls that
    /// produce a value on a later turn — the `apple` shape — and carry it back
    /// in `platformResult.data`.
    private func handlePlatform(_ envelope: Envelope) {
        guard let payload = try? envelope.decodePayload(PlatformPayload.self) else { return }
        let app = envelope.app
        guard let call = payload.invocation else {
            sendPlatformResult(app: app, .failure(
                id: payload.id,
                error: "malformed platform request (call '\(payload.call)')"
            ))
            return
        }
        guard let capabilities else {
            sendPlatformResult(app: app, .failure(
                id: payload.id,
                error: "this shell has no platform capability"
            ))
            return
        }
        switch call {
        case let .observe(kind, name):
            settle(payload.id, app: app, capabilities.observePlatform(kind: kind, name: name, app: app))
        case let .unobserve(kind, name):
            settle(payload.id, app: app, capabilities.unobservePlatform(kind: kind, name: name, app: app))
        default:
            capabilities.runPlatformCall(call, app: app) { [weak self] result in
                switch result {
                case let .success(data):
                    self?.sendPlatformResult(app: app, .success(id: payload.id, data: data))
                case let .failure(error):
                    self?.sendPlatformResult(app: app, .failure(id: payload.id, error: error.message))
                }
            }
        }
    }

    private func settle(_ id: Int, app: String, _ result: Result<Void, CapabilityError>) {
        switch result {
        case .success:
            sendPlatformResult(app: app, .success(id: id))
        case let .failure(error):
            sendPlatformResult(app: app, .failure(id: id, error: error.message))
        }
    }

    // MARK: - Draw flush (spec §3.4)

    /// Blit the latest coalesced ops per canvas. Call on the display-link tick.
    public func flushDraws() {
        for frame in coalescer.drain() {
            delegate?.drawCanvas(app: frame.app, id: frame.canvas, ops: frame.ops)
        }
    }

    public var hasPendingDraws: Bool { !coalescer.isEmpty }

    // MARK: - Native transducer input/checkpoint (spec §3.5)

    /// Route a local input to a canvas' transducer, blitting its draw and
    /// forwarding its events to the worker. Returns whether the canvas stepped.
    @discardableResult
    public func feedTransducer(app: String, canvas: Int, input: TransducerInput) -> Bool {
        guard let result = native.input(canvas: canvas, input) else { return false }
        if !result.draw.isEmpty {
            delegate?.drawCanvas(app: app, id: canvas, ops: result.draw)
        }
        for event in result.events {
            emitEvent(app: app, id: canvas, name: event.name, data: event.data)
        }
        if result.suspended {
            // Three over-budget ticks (or a throw) → app crash to the worker.
            emit(app: app, type: .event, payload: .object([
                "id": .int(canvas),
                "name": .string("crash"),
                "data": .object(["reason": .string("transducer over budget")]),
            ]))
        }
        return true
    }

    /// Checkpoint a canvas' transducer state back to the host (§3.5): at 1 Hz
    /// and on collapse.
    public func checkpoint(app: String, canvas: Int) {
        guard let state = native.checkpointState(canvas: canvas) else { return }
        emit(app: app, type: .native, payload: .object([
            "action": .string("checkpoint"),
            "canvas": .int(canvas),
            "state": state,
        ]))
    }

    // MARK: - Outbound (spec §4)

    /// Emit a `click`/`change`/`hover`/`key` event for a node (§4.1).
    public func emitEvent(app: String, id: Int, name: String, data: JSONValue = .object([:])) {
        emit(app: app, type: .event, payload: .object([
            "id": .int(id),
            "name": .string(name),
            "data": data,
        ]))
    }

    /// An **app-level** event — one that belongs to the running app rather than
    /// to any node in its tree (§4.1). Node ids start at 1 (§3.1), so id 0 is
    /// free and means exactly this: a drop onto the shelf, a pressed
    /// notification button. The host routes it to the app's worker like any
    /// other event; the worker dispatches id-0 events to the app's optional
    /// `onEvent` export instead of to a prop handler.
    public func emitAppEvent(app: String, name: String, data: JSONValue) {
        emitEvent(app: app, id: 0, name: name, data: data)
    }

    /// Settle one `apple` request (spec §6).
    public func sendAppleResult(app: String, _ result: AppleResultPayload) {
        emit(app: app, type: .appleResult, payload: .encoding(result))
    }

    /// Settle one `capture` request (spec §6 extension).
    public func sendCaptureResult(app: String, _ result: CaptureResultPayload) {
        emit(app: app, type: .captureResult, payload: .encoding(result))
    }

    /// Settle one `platform` request (spec §6 extension).
    public func sendPlatformResult(app: String, _ result: PlatformResultPayload) {
        emit(app: app, type: .platformResult, payload: .encoding(result))
    }

    /// An observed OS signal fired (spec §6 extension). Delivered as the id-0
    /// app-level `platform` event — it belongs to the app, not to any node in
    /// its tree, exactly like `drop` and `notification`.
    public func sendPlatformEvent(
        app: String,
        kind: String,
        name: String,
        userInfo: [String: JSONValue]
    ) {
        emitAppEvent(app: app, name: "platform", data: .object([
            "kind": .string(kind),
            "name": .string(name),
            "userInfo": .object(userInfo),
        ]))
    }

    /// The user pressed a button on notification `id` (spec §6 extension).
    public func sendNotifyAction(app: String, id: Int, action: String) {
        emit(app: app, type: .notifyAction, payload: .encoding(NotifyActionPayload(id: id, action: action)))
    }

    /// Report a per-app panel state change (§4.2).
    public func sendLifecycle(app: String, phase: String) {
        emit(app: app, type: .lifecycle, payload: .object([
            "phase": .string(phase),
            "screen": screenJSON(screen),
        ]))
    }

    /// The user switched apps via the strip (§4.3). Pass `app` for an app, or nil
    /// with a `surface` (`settings`/`new`).
    public func sendSelection(app: String?, surface: String? = nil) {
        var payload: [String: JSONValue] = [:]
        payload["app"] = app.map { .string($0) } ?? .null
        if let surface { payload["surface"] = .string(surface) }
        emit(app: "", type: .selection, payload: .object(payload))
    }

    /// The user typed into an app's chat, or cancelled the running turn (§4.3).
    public func sendBuilderInput(app: String, text: String? = nil, cancel: Bool = false) {
        var payload: [String: JSONValue] = ["app": .string(app)]
        if cancel {
            payload["cancel"] = .bool(true)
        } else if let text {
            payload["text"] = .string(text)
        }
        emit(app: "", type: .builderInput, payload: .object(payload))
    }

    /// Ask the host for a fresh full commit for one app (§4.3). Sent with the
    /// shell-level app id `""` and the target app in the payload.
    public func sendResyncRequest(app: String) {
        emit(app: "", type: .resyncRequest, payload: .object(["app": .string(app)]))
    }

    // MARK: - Helpers

    private func emit(app: String, type: EnvelopeType, payload: JSONValue) {
        let seq = nextSeq(app: app)
        send(Envelope(v: 1, app: app, seq: seq, type: type.rawValue, payload: payload))
    }

    private func nextSeq(app: String) -> Int {
        let seq = outboundSeq[app, default: 0] + 1
        outboundSeq[app] = seq
        return seq
    }

    private func screenJSON(_ screen: ScreenInfo) -> JSONValue {
        var object: [String: JSONValue] = [
            "notchWidth": .double(screen.notchWidth),
            "menubarHeight": .double(screen.menubarHeight),
            "scale": .double(screen.scale),
        ]
        if let max = screen.maxPanelHeight {
            object["maxPanelHeight"] = .double(max)
        }
        return .object(object)
    }
}
