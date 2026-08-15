import Foundation
import LedgeShellCore

/// What the page can ask of the shell. Deliberately a closed set: the editor is
/// a *frontend over the protocol*, so the only things it may originate are the
/// two halves of `builderInput` (spec §4.3) plus the handshake that tells Swift
/// the page is alive.
///
/// `Sendable` and parsed by a `nonisolated` function on purpose — WebKit hands
/// the raw message over on whatever queue it likes, and the value that crosses
/// the hop back to the main actor has to be one the compiler can prove is safe.
/// Parsing before the hop is what keeps `WKScriptMessage` (which is not
/// Sendable, and whose `body` is `Any`) out of the closure entirely.
enum EditorCommand: Equatable, Sendable {
    /// The page's bridge module ran; queued events may be flushed.
    case ready
    case input(String)
    case cancel
    /// The pill's ⌄/⌃. The pane clears itself; Swift re-measures the panel,
    /// which is a different height with no transcript in it.
    case transcript(collapsed: Bool)
    /// The user scrolled into the past, or came back to the latest. The stage
    /// behind recedes while they are back there (design.html §08).
    case scrollback(past: Bool)
    /// Esc, with no turn to interrupt. Forwarded from the page rather than left
    /// to WebKit's responder chain: whether an unhandled key event escapes a
    /// focused `<textarea>` inside a `WKWebView` is not a contract anybody
    /// wrote down, and "Esc closes the visit" is flow.md's Transitions table.
    case escape
}

/// The JS↔Swift half of the editor surface, with no WebKit in it.
///
/// It exists as its own type because everything worth asserting about the
/// editor is here — which envelope becomes which page event, which page message
/// becomes a `builderInput`, and what happens to events that arrive before the
/// page can receive them — and none of it can be tested through a live
/// `WKWebView` in `swift test`. The view owns the web view; this owns the
/// contract.
@MainActor
final class EditorBridge {
    /// The app whose thread is on screen. One web view is reused across apps
    /// (there is one panel, so there is one editor), so switching apps is a
    /// message rather than a new instance — see `focus(app:)`.
    private(set) var app: String?
    /// Whether the page has announced itself. Until it does, events are held:
    /// `builder` frames start arriving the instant the host has something to
    /// say, which is routinely before `loadFileURL` has finished parsing the
    /// bundle, and an event evaluated into a page that has no `__ledgeDeliver`
    /// yet is simply lost.
    private(set) var isReady = false
    private var pending: [JSONValue] = []
    /// The agent capability is session-global and sent only once by the host.
    /// Keep it independently of transcript queues so a WebKit process reload
    /// can reconstruct the banner without asking the host to reconnect.
    private var latestAgentStatus: JSONValue?

    /// A cap on the held events, because "the page never came up" must cost a
    /// bounded amount of memory rather than an unbounded one. Dropping the
    /// oldest keeps the tail — the end of a turn is the part worth seeing.
    static let pendingLimit = 512

    /// The user typed, or asked to interrupt. Wired to `HostSession`, which owns
    /// envelope emission; `text` and `cancel` are the two shapes §4.3 allows.
    var onInput: ((_ app: String, _ text: String?, _ cancel: Bool) -> Void)?
    /// The host scaffolded an app for a turn typed into the [+] surface. The
    /// panel moves its presentation onto it, so Preview shows the thing being
    /// built and the next message routes to it like any other app's.
    var onCreated: ((String) -> Void)?
    /// Run JS in the page. Set by the surface to the web view's evaluator; nil
    /// in tests, where the emitted script is inspected instead.
    var evaluate: ((String) -> Void)?
    /// Every script this bridge emitted, newest last. The test seam — and the
    /// reason `evaluate` can stay nil without the bridge losing track.
    private(set) var emitted: [String] = []

    // MARK: - Thread switching

    /// Point the editor at an app. A no-op when it is already there, so an
    /// ordinary re-present (the panel re-measures on every applied commit) does
    /// not wipe the transcript the user is reading.
    func focus(app newApp: String?) {
        guard newApp != app else { return }
        app = newApp
        // Events queued for the app we just left are not this app's transcript.
        pending.removeAll()
        guard let newApp else { return }
        // The page clears and starts a fresh thread. Sent even before `ready`
        // (it queues like anything else), so a page that loads into an already
        // chosen app still learns which one.
        emit(.object([
            "event": .string("thread"),
            "app": .string(newApp),
        ]))
    }

    // MARK: - The stage behind the pane

    /// The last stage geometry sent, so a re-layout that changed nothing does
    /// not cost a `evaluateJavaScript` — `layout` runs on every applied commit,
    /// and a live app commits several times a second.
    private var stage: (present: Bool, inset: CGFloat)?

    /// Tell the page how much of the pane the native stage occupies at the top,
    /// and whether there is one at all. The transcript leaves that much room;
    /// the pill grows its ⌄/⌃ only when there is something to watch (flow.md:
    /// "A blank slot has no stage: chat only, no glass toggle").
    func setStage(present: Bool, inset: CGFloat) {
        let rounded = (inset * 2).rounded() / 2
        guard stage?.present != present || stage?.inset != rounded else { return }
        stage = (present, rounded)
        emit(.object([
            "event": .string("stage"),
            "present": .bool(present),
            "inset": .double(Double(rounded)),
        ]))
    }

    // MARK: - Swift → JS

    /// Deliver one `builder` envelope (spec §3.6). Returns false when the event
    /// belongs to another app — the host streams for whichever app has a turn
    /// running, which is not necessarily the one the panel is showing, and
    /// splicing another app's turn into this transcript is the bug this guard
    /// exists to prevent.
    @discardableResult
    func deliver(_ payload: BuilderPayload) -> Bool {
        // Whether the agent is installed is not any app's news — it is the
        // condition every turn depends on, and it arrives once per session with
        // an empty app. Delivered to whatever the editor is showing, and held
        // for a page that has not loaded yet like anything else.
        if payload.event == "agent" {
            let event = Self.pageEvent(for: payload)
            latestAgentStatus = event
            emit(event)
            return true
        }
        // The [+] surface: the editor is focused on `""` because the app did not
        // exist when the user pressed return, and `created` is the host telling
        // us what it called the one it just made (spec §4.3, §8). Adopting it
        // here rather than clearing and re-focusing is deliberate — `focus`
        // wipes the transcript, and the transcript at this moment contains the
        // user's prompt and the first words of the reply to it.
        if payload.event == "created", app == "", !payload.app.isEmpty {
            app = payload.app
            onCreated?(payload.app)
            emit(Self.pageEvent(for: payload))
            return true
        }
        guard let app, payload.app == app else { return false }
        emit(Self.pageEvent(for: payload))
        return true
    }

    private func emit(_ event: JSONValue) {
        guard isReady else {
            pending.append(event)
            if pending.count > Self.pendingLimit { pending.removeFirst() }
            return
        }
        let script = Self.script(delivering: event)
        emitted.append(script)
        evaluate?(script)
    }

    /// Normalise a wire payload into the one shape the page renders.
    ///
    /// Unknown `event` values are forwarded with whatever fields they carried
    /// rather than dropped: the host and the shell ship separately, and an
    /// editor that swallowed a new event type would be silently out of date
    /// instead of visibly so.
    static func pageEvent(for payload: BuilderPayload) -> JSONValue {
        var out: [String: JSONValue] = [
            "event": .string(payload.event),
            "app": .string(payload.app),
            "turn": .int(payload.turn),
        ]
        switch payload.event {
        case "text":
            out["delta"] = .string(payload.delta ?? "")
        case "tool":
            out["name"] = .string(payload.name ?? "")
            out["detail"] = .string(payload.detail ?? "")
            // A tool event with no state has already happened: adapters emit a
            // single frame for atomic tools (a one-shot `edit`) and a pair only
            // for ones that can be watched running.
            out["state"] = .string(payload.state == "started" ? "started" : "completed")
        case "status":
            out["text"] = .string(payload.text ?? legacyStatusText(state: payload.state, ms: payload.ms))
        case "done":
            // `ok: false` cannot express "interrupted", which is why `status`
            // replaced it — but a host still emitting `ok` must not read as a
            // failure-free turn either.
            out["status"] = .string(payload.status ?? (payload.ok == false ? "failed" : "completed"))
        case "error":
            out["message"] = .string(payload.message ?? payload.detail ?? payload.delta ?? "")
        case "agent":
            // Absent `installed` means the host did not say, and the surface
            // must not invent a banner for a working machine — so the safe
            // default is "installed".
            out["installed"] = .bool(payload.installed ?? true)
            if let install = payload.install { out["install"] = .string(install) }
            out["name"] = .string(payload.name ?? "the agent")
        default:
            for (key, value) in [
                "delta": payload.delta,
                "name": payload.name,
                "detail": payload.detail,
                "state": payload.state,
                "text": payload.text,
                "status": payload.status,
                "message": payload.message,
            ] where value != nil {
                out[key] = .string(value!)
            }
        }
        return .object(out)
    }

    /// The pre-`{text}` status shape (`{ state: "reloaded", ms: 1200 }`) phrased
    /// as the line the page would otherwise have to phrase itself.
    private static func legacyStatusText(state: String?, ms: Int?) -> String {
        let base = state ?? ""
        guard let ms else { return base }
        return base.isEmpty
            ? String(format: "%.1fs", Double(ms) / 1000)
            : base + String(format: " · %.1fs", Double(ms) / 1000)
    }

    /// Wrap an event as the one statement Swift evaluates in the page.
    ///
    /// JSON is *almost* a subset of JavaScript: U+2028 and U+2029 are ordinary
    /// characters inside a JSON string and line terminators in JS source, so an
    /// agent that emits one — and agents emit whatever the model wrote — would
    /// end the statement in the middle of a string literal. Escaping them is the
    /// difference between "the transcript shows an odd character" and "the
    /// editor stops receiving events for the rest of the session".
    static func script(delivering event: JSONValue) -> String {
        let data = (try? JSONEncoder().encode(event)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.__ledgeDeliver && window.__ledgeDeliver(\(json));"
    }

    // MARK: - JS → Swift

    /// Parse a raw `postMessage` body. `nonisolated` and pure: it runs on
    /// WebKit's own queue (see `EditorCommand`), so it must touch no state.
    ///
    /// Empty input is rejected here rather than in `submit`, because "the user
    /// pressed return on an empty box" is a message that should never have been
    /// sent — turning it into a turn would spend an agent invocation on nothing.
    nonisolated static func command(from body: Any) -> EditorCommand? {
        guard let message = body as? [String: Any],
              let type = message["type"] as? String
        else { return nil }
        switch type {
        case "ready":
            return .ready
        case "cancel":
            return .cancel
        case "escape":
            return .escape
        case "transcript":
            return .transcript(collapsed: message["collapsed"] as? Bool ?? false)
        case "scrollback":
            return .scrollback(past: message["past"] as? Bool ?? false)
        case "input":
            guard let text = message["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .input(trimmed)
        default:
            // Unknown message types are dropped, not forwarded: the page is the
            // one piece of this surface that gets rewritten often, and a typo in
            // it must not become an envelope on the wire.
            return nil
        }
    }

    /// Apply a parsed command. Called on the main actor, after the hop.
    func submit(_ command: EditorCommand) {
        switch command {
        case .ready:
            isReady = true
            let queued = pending
            pending.removeAll()
            for event in queued { emit(event) }
        case .input(let text):
            guard let app else { return }
            onInput?(app, text, false)
        case .cancel:
            guard let app else { return }
            onInput?(app, nil, true)
        case .transcript, .scrollback, .escape:
            // Presentation, not protocol: these never become an envelope. The
            // surface acted on them before handing the command over (see
            // `EditorSurfaceView.handle`), and they are listed rather than
            // defaulted so a new command cannot be silently swallowed here.
            break
        }
    }

    /// The page went away (a reload, a crash of the web content process). The
    /// queue starts again rather than replaying a transcript the page will
    /// rebuild from its own `thread` message.
    func pageReset() {
        isReady = false
        pending.removeAll()
        // The new page knows nothing about the stage behind it; the next layout
        // has to be allowed to tell it again.
        stage = nil
        guard let app else { return }
        emit(.object(["event": .string("thread"), "app": .string(app)]))
        if let latestAgentStatus { emit(latestAgentStatus) }
    }
}
