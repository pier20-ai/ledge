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
/// - `permissions` — the first-run macOS-permission surface. Shell chrome with
///   no app behind it at all: it is the shell explaining what it is about to ask
///   the system for on an app's behalf (spec §6's trust model, whose prompts are
///   attributed to the shell because a worker cannot own one).
/// - `mini(app:)` — **the notification** (flow.md, Interruption): the app's
///   `<mini>` subtree, in the notch's swell. `mini` is the *wire* name — the
///   §5 node and `ctx.peek` keep it for compatibility — but in shell code this
///   surface is the notification, one of the two members of the swell family.
///   It is *not* an expansion: the panel is not open and nothing takes focus.
/// - `summary(app:)` — **the summary** (flow.md, Summary): the app's `<summary>`
///   subtree in the same swell geometry, raised by a hover that reached Th. The
///   other swell. It carries a shell-drawn chevron the app cannot remove, which
///   is the promise that another click opens the full thing.
/// - `overview` — **the ledge** (flow.md, "The strip": "Zoom out to the overview
///   — the ledge: sessions as slabs on a shelf"). A mode of the visit, like
///   chat: the same panel, the same wings, the whole strip at once instead of
///   one session of it. It names no app because it is *about* all of them; the
///   session it was zoomed out of is remembered by the controller, which is what
///   the left wing's **Back** returns to.
public enum ShellPresentation: Equatable, Sendable {
    case collapsed
    case mini(app: String)
    case summary(app: String)
    case expanded(app: String?)
    case chat(app: String)
    case newApp
    case permissions
    case overview

    /// The swell family's other name for `.mini`. New shell code says
    /// "notification"; the wire, the §5 node and `ctx.peek` still say `mini`,
    /// and aliasing is cheaper than renaming a protocol nobody asked to change.
    public static func notification(app: String) -> ShellPresentation { .mini(app: app) }

    /// Whether the full panel is up. A mini is deliberately NOT an expansion:
    /// it draws no app strip, reserves no cutout row, takes no focus, and the
    /// interaction machine must treat it as "still closed": what a click means,
    /// whether the walk-away timer may run and whether the cutout row carries
    /// controls all turn on this, and every one of them answers wrongly for a
    /// swell that claimed to be a visit.
    public var isExpanded: Bool {
        switch self {
        case .collapsed, .mini, .summary: false
        case .expanded, .chat, .newApp, .permissions, .overview: true
        }
    }

    /// True while the notification swell is up. (Wire name; see `.mini`.)
    public var isMini: Bool {
        if case .mini = self { return true }
        return false
    }

    /// The swell family's name for `isMini`.
    public var isNotification: Bool { isMini }

    /// True while the hover's summary swell is up.
    public var isSummary: Bool {
        if case .summary = self { return true }
        return false
    }

    /// Either swell. The two share a geometry (flow.md: "five surfaces … the
    /// notification (the interruption's swell), the summary (the hover's
    /// swell)"), so nearly everything the surface asks is this question and not
    /// which of the two it is.
    public var isSwell: Bool { isMini || isSummary }

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
        isSwell ? nil : app
    }

    /// The session this surface belongs to — its tree, its chat, or its swell.
    /// `nil` for the collapsed pill, the placeholder, and the blank slot.
    public var app: String? {
        switch self {
        case .expanded(let app): app
        case .chat(let app): app
        case .mini(let app): app
        case .summary(let app): app
        case .collapsed, .newApp, .permissions, .overview: nil
        }
    }

    /// Chat stays lit on the same icon, so an app switch is "same app, other
    /// surface" rather than a new selection (spec §8: "while an app's chat is
    /// open, its icon stays lit").
    public var isChat: Bool {
        if case .chat = self { return true }
        return false
    }

    /// Chat mode, on either kind of session: an app's conversation, or the blank
    /// slot's — which has no stage behind it but is the same surface, the same
    /// glass and the same pill (flow.md, "Visit modes").
    public var isConversation: Bool {
        switch self {
        case .chat, .newApp: true
        case .collapsed, .mini, .summary, .expanded, .permissions, .overview: false
        }
    }

    /// Whether the walk-away timeout (flow.md `Texit`) may close this surface.
    ///
    /// Permission onboarding is raised by the shell rather than by the user, so
    /// letting a pointer that wandered off dismiss the first-run screen makes it
    /// disappear without anybody having done anything. It stays until an
    /// explicit dismissal; every other visit is walk-away-able.
    public var allowsPassiveCollapse: Bool {
        if case .permissions = self { return false }
        return true
    }
}

// `LedgeApps` lived here: the one app id the shell had an opinion about.
// Settings was an ordinary app to the protocol — a folder, a worker, a catalog
// row — but the shell knew two things about it nothing else could claim: it was
// the only caller allowed to raise the permission surface, and it had nothing
// behind it for an agent to edit, so it never showed the glass toggle.
//
// Settings is a native window now (flow.md, Edges; `SettingsWindowController`),
// so **no app id is special any more**. Both exceptions are gone rather than
// generalised: the permission surface refuses every app, and every app in the
// strip is a real app with a real folder. The shell has no opinion about names,
// which is a better place for it to be than having one with a token.

/// The shell's presentation state machine. Deliberately tiny: which surface is
/// up, plus the one piece of memory the interaction model needs — the last app
/// that actually filled the panel, so clicking the collapsed pill reopens it.
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
        // A swell is a glance, not a visit: it must NOT become the app that
        // clicking the pill reopens. Otherwise a track change while you were
        // using Chess would quietly rewrite "the app you were last in", and
        // your next click would open Music.
        if let app = presentation.app, !presentation.isSwell {
            lastPresentedApp = app
        }
        switch presentation {
        case .chat: visitMode = .chat
        case .expanded: visitMode = .stage
        // Everything else leaves it alone — see `visitMode`.
        case .collapsed, .mini, .summary, .newApp, .permissions, .overview: break
        }
    }

    /// Which of the two visit modes the user last chose (flow.md, "Visit
    /// modes"). Not derived from `presentation`, because the surfaces that are
    /// neither — the blank slot above all — must not *change* the answer.
    ///
    /// It exists for `walk(to:)`. Walking the strip keeps the mode, and the
    /// strip's ring runs through the blank slot, which is a conversation with no
    /// stage behind it. Reading the mode off the live presentation would make a
    /// lap of a five-app strip in stage mode come back in chat mode purely
    /// because it passed the blank on the way round — the mode would depend on
    /// the route rather than on anything the user did.
    public enum VisitMode: Equatable, Sendable {
        case stage
        case chat
    }

    public private(set) var visitMode: VisitMode = .stage

    /// The user acted on the swell that was on screen — clicked the summary, or
    /// clicked a notification anywhere but its action (flow.md: "Summary | click
    /// anywhere | Visit"; "Interruption | click elsewhere | Visit (owning
    /// session)"). That IS a choice, so the app becomes the remembered one and
    /// the visit opens. A no-op unless a swell is actually up.
    public mutating func promoteSwell() {
        guard presentation.isSwell, let app = presentation.app else { return }
        present(.expanded(app: app))
    }

    /// A swell's own timer elapsed, or the pointer left the summary. Only
    /// retracts if that same swell is still up — the user may already have
    /// promoted it, or another app may have taken the surface, and a late timer
    /// must not close either of those.
    public mutating func retractSwell(app: String) {
        guard presentation.isSwell, presentation.app == app else { return }
        present(.collapsed)
    }

    /// The wire-named aliases. `mini` is what §5 and `ctx.peek` call the
    /// notification; keeping the old spellings means the protocol's vocabulary
    /// and the shell's can differ without a rename sweep through every file.
    public mutating func promoteMini() { promoteSwell() }
    public mutating func dismissMini(app: String) { retractSwell(app: app) }

    public mutating func collapse() {
        present(.collapsed)
    }

    /// Forget an app the user stopped (the ledge's ✕). The reopen memory is the
    /// one place a stopped session can linger: without this, the next click on
    /// the pill opens the placeholder card for a worker that is deliberately
    /// gone. What is on screen is not touched — stopping a session from the
    /// shelf does not close the shelf.
    public mutating func forget(_ app: String) {
        guard lastPresentedApp == app else { return }
        lastPresentedApp = nil
    }

    /// Seed the reopen memory without changing what is on screen — used when
    /// the first catalog arrives so the very first click opens a real app
    /// instead of the placeholder. Never overwrites a real visit.
    public mutating func rememberIfUnset(_ app: String?) {
        guard lastPresentedApp == nil, let app else { return }
        lastPresentedApp = app
    }

    /// A click on the pill, or the menu item: open the last app used (or the
    /// placeholder when there is nothing to reopen), and close from anywhere.
    public mutating func toggleExpansion() {
        if presentation.isExpanded {
            present(.collapsed)
        } else {
            reopenVisit()
        }
    }

    /// Reopen the last visit **the way it was left** (G2.6: hover away and
    /// come back, and the conversation you were having must still be the
    /// surface — a walk-away that silently swapped chat for stage was read as
    /// the state being lost). The mode memory is `visitMode`, the same one the
    /// strip walk honours; it only ever applies to the remembered session,
    /// because it was that session's conversation.
    public mutating func reopenVisit() {
        if visitMode == .chat, let app = lastPresentedApp {
            present(.chat(app: app))
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
        case .collapsed, .mini, .summary, .newApp, .permissions, .overview:
            break
        }
    }

    /// Strip selection (spec §4.3/§8): picking the app that is already presented
    /// toggles its chat, matching "the ✦ toggle opens the chat below the live
    /// preview" without adding a second control to the strip.
    public mutating func selectApp(_ app: String, reselectOpensChat: Bool = true) {
        if reselectOpensChat, presentation.app == app {
            toggleChat()
        } else {
            present(.expanded(app: app))
        }
    }

    /// **Walking the strip changes the session, not the mode** (flow.md, "The
    /// strip": `‹|›` and the horizontal swipe).
    ///
    /// The walk used to land on `.expanded` from wherever it started, so `›` in
    /// a conversation dropped you onto the next session's *stage* — you asked to
    /// change the subject and the shell changed the subject and the surface. In
    /// use that reads as the control being wrong rather than as a mode change:
    /// the thing you were doing (talking) is the thing you meant to keep.
    ///
    /// So the mode survives the walk. Chat walks to chat — the next session's
    /// transcript, over the next session's stage — and a stage walks to a stage.
    ///
    /// The mode comes from `visitMode` rather than from the presentation, so the
    /// blank slot is transparent to it: walking past the blank in stage mode
    /// comes out the other side still in stage mode, and a full lap of the strip
    /// ends exactly where it began. Walking *onto* the blank is the blank
    /// whichever mode you were in, because it has no stage to be in the other
    /// one.
    ///
    /// The overview is deliberately untouched. It is not a visit mode: `‹|›`
    /// there is the machine leaving the overview (`showingOverview`), a
    /// different gesture wearing the same control, and it lands on whichever
    /// mode was last chosen exactly as it always did.
    public mutating func walk(to slot: SessionStrip.Slot) {
        switch slot {
        case .app(let app):
            present(visitMode == .chat ? .chat(app: app) : .expanded(app: app))
        case .blank:
            present(.newApp)
        }
    }
}
