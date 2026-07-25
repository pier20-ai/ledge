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
public enum ShellPresentation: Equatable, Sendable {
    case collapsed
    case expanded(app: String?)
    case chat(app: String)
    case newApp

    public var isExpanded: Bool {
        if case .collapsed = self { return false }
        return true
    }

    /// The app whose icon is lit in the strip — an app's tree or its chat.
    /// `nil` for the collapsed pill, the placeholder, and the **[+]** surface.
    public var app: String? {
        switch self {
        case .expanded(let app): app
        case .chat(let app): app
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
        if let app = presentation.app {
            lastPresentedApp = app
        }
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
        case .collapsed, .newApp:
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
