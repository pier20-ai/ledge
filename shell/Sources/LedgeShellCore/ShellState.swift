import Foundation

/// What the notch is showing right now.
///
/// This is *presentation* state — Swift's half of the division in the spec's
/// preamble ("Swift owns transient presentation"). It never describes an app's
/// content: the tree for `.expanded(app:)` comes from the host's commits, and
/// the panel's height is measured from that tree, not stored here.
///
/// - `collapsed` — the idle pill over the hardware notch.
/// - `expanded(app:)` — an app's tree fills the panel. `nil` means "expanded but
///   nothing to show" (no host connected, or no tree for the app yet); the shell
///   renders its built-in placeholder card.
/// - `chat(app:)` — the app's chat surface (spec §8). Shell chrome, not an app.
/// - `newApp` — the **[+]** surface (spec §8). Shell chrome over a fresh folder.
/// - `mini(app:)` — the app's `<mini>` subtree, in a small surface below the
///   notch. The middle rung between a wing and the panel: shown by `ctx.peek`,
///   dismissed on a timer, and promoted to `.expanded` the moment the user
///   hovers it. It is *not* an expansion — the panel is not open, the app strip
///   is not drawn, and nothing about it takes focus.
public enum ShellPresentation: Equatable, Sendable {
    case collapsed
    case mini(app: String)
    case expanded(app: String?)
    case chat(app: String)
    case newApp

    /// Whether the full panel is up. A mini is deliberately NOT an expansion:
    /// it draws no app strip, reserves no cutout row, takes no focus, and the
    /// hover machinery must treat it as "still closed" so that hovering it opens
    /// the panel rather than reading as an already-open panel.
    public var isExpanded: Bool {
        switch self {
        case .collapsed, .mini: false
        case .expanded, .chat, .newApp: true
        }
    }

    /// True while the small surface is up.
    public var isMini: Bool {
        if case .mini = self { return true }
        return false
    }

    /// The app to report to the host as *presented* (spec §4.3 `selection`, and
    /// the `expanded`/`collapsed` lifecycle that rides with it).
    ///
    /// Not the same question as `app`. A mini names its app — the icon logic and
    /// the dwell timer both need it — but must report **nothing**, because
    /// reporting is what tells a worker its panel opened. Apps use
    /// `onLifecycle("expanded")` to start animating and polling harder; a peek
    /// that reported itself would spin up every app that flashes a track change
    /// and then immediately tell it to collapse again, for a panel that never
    /// opened.
    public var reportedApp: String? {
        isMini ? nil : app
    }

    /// The app whose icon is lit in the strip — an app's tree or its chat.
    /// `nil` for the collapsed pill, the placeholder, and the **[+]** surface.
    public var app: String? {
        switch self {
        case .expanded(let app): app
        case .chat(let app): app
        case .mini(let app): app
        case .collapsed, .newApp: nil
        }
    }

    /// Chat stays lit on the same icon, so an app switch is "same app, other
    /// surface" rather than a new selection (spec §8: "while an app's chat is
    /// open, its icon stays lit").
    public var isChat: Bool {
        if case .chat = self { return true }
        return false
    }
}

/// The shell's presentation state machine. Deliberately tiny: which surface is
/// up, plus the one piece of memory the interaction model needs — the last app
/// that actually filled the panel, so hovering the collapsed pill reopens it.
public struct ShellState: Equatable, Sendable {
    public private(set) var presentation: ShellPresentation
    /// Remembered across collapse and across the chrome surfaces (chat/[+]),
    /// so `toggleExpansion` reopens the app you were last using.
    public private(set) var lastPresentedApp: String?

    public init(presentation: ShellPresentation = .collapsed, lastPresentedApp: String? = nil) {
        self.presentation = presentation
        self.lastPresentedApp = lastPresentedApp ?? presentation.app
    }

    public var isExpanded: Bool { presentation.isExpanded }
    public var presentedApp: String? { presentation.app }

    public mutating func present(_ presentation: ShellPresentation) {
        self.presentation = presentation
        // A peek is an interruption, not a visit: it must NOT become the app
        // that hovering the pill reopens. Otherwise a track change while you
        // were using Chess would quietly rewrite "the app you were last in",
        // and your next hover would open Music.
        if let app = presentation.app, !presentation.isMini {
            lastPresentedApp = app
        }
    }

    /// The user reached for a mini that was on screen — hovered or clicked it.
    /// That IS a choice, so the app becomes the remembered one and the panel
    /// opens. A no-op unless a mini is actually up.
    public mutating func promoteMini() {
        guard case .mini(let app) = presentation else { return }
        present(.expanded(app: app))
    }

    /// The peek's dwell elapsed. Only closes if that same mini is still up —
    /// the user may already have promoted it, or another app may have taken the
    /// surface, and a late timer must not close either of those.
    public mutating func dismissMini(app: String) {
        guard case .mini(let current) = presentation, current == app else { return }
        present(.collapsed)
    }

    public mutating func collapse() {
        present(.collapsed)
    }

    /// Seed the hover-reopen memory without changing what is on screen — used
    /// when the first catalog arrives so the very first hover opens a real app
    /// instead of the placeholder. Never overwrites a real visit.
    public mutating func rememberIfUnset(_ app: String?) {
        guard lastPresentedApp == nil, let app else { return }
        lastPresentedApp = app
    }

    /// Hover/click on the pill, or the menu item: open the last app used (or the
    /// placeholder when there is nothing to reopen), and close from anywhere.
    public mutating func toggleExpansion() {
        if presentation.isExpanded {
            present(.collapsed)
        } else {
            present(.expanded(app: lastPresentedApp))
        }
    }

    /// The **✦** affordance: swap between an app's live tree and its chat
    /// surface. A no-op on the placeholder and the **[+]** surface, which have
    /// no app to talk about.
    public mutating func toggleChat() {
        switch presentation {
        case .expanded(let app):
            guard let app else { return }
            present(.chat(app: app))
        case .chat(let app):
            present(.expanded(app: app))
        case .collapsed, .mini, .newApp:
            break
        }
    }

    /// Strip selection (spec §4.3/§8): picking the app that is already presented
    /// toggles its chat, matching "the ✦ toggle opens the chat below the live
    /// preview" without adding a second control to the strip.
    public mutating func selectApp(_ app: String) {
        if presentation.app == app {
            toggleChat()
        } else {
            present(.expanded(app: app))
        }
    }
}
