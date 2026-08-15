import AppKit
import LedgeShellCore

/// **The** error card. There is one, it is generic, and it is everywhere
/// (flow.md, Edges → Errors).
///
/// No raw error ever reaches the glass. Not a stack trace, not an error code,
/// not even the app's name — a card that says which app died asks the reader to
/// do triage they cannot act on, on a surface the width of a notch. What they
/// can act on is one button, and the button restarts the whole host: worst case
/// is a fresh visit.
///
/// The diagnosis is not lost, only relocated. The message and the trace go to
/// `~/.ledge/host.log` and `crash.log`, which is where a person debugging an app
/// is already looking.
final class ErrorCardView: FlippedView {
    /// One line. It is deliberately not a description of what happened.
    static let line = "Something broke."
    /// The only action, and the only one there will ever be.
    static let actionTitle = "Reload Ledge"

    private let empty: LedgeEmptyState

    /// - Parameter onReload: restarts the host process. Wired in
    ///   `LedgeShellApp` → `HostSession` → `ProtocolRenderer`; nil leaves the
    ///   button inert, which is what a snapshot render wants.
    init(onReload: (() -> Void)? = nil) {
        empty = LedgeEmptyState(
            symbol: "exclamationmark.triangle",
            line: Self.line,
            actionTitle: Self.actionTitle,
            onAction: onReload ?? {}
        )
        super.init(frame: .zero)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        // Pinned on all four edges — the panel measures this view to size itself.
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor),
            empty.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Test/introspection accessors.
    var reloadButton: LedgeButton? { empty.actionButton }
    var messageLine: String { empty.line }
}

/// Shown when the panel is expanded but there is nothing to draw. Deliberately
/// quiet — the shell has no content of its own to invent, and an empty panel
/// reads as a bug — but it must name the *actual* gap: "waiting for host" when
/// the host is connected but has no apps sends the user debugging the wrong
/// process. Same card language as the crash card (§7).
final class HostPlaceholderView: FlippedView {
    /// Total panel height (content + the 42 pt app strip).
    static let panelHeight: CGFloat = 34 + 74 + 42

    /// What is actually missing, most specific first.
    enum Phase: Equatable {
        /// No host connection on the socket. `detail` is why, in words the
        /// reader can act on — the dev command in a dev build, the actual fault
        /// in a shipped one (see `HostStatus`).
        case noHost(detail: String)
        /// A host is connected but its catalog is empty.
        case noApps
        /// The app exists in the catalog but has not committed a tree yet.
        case starting(app: String)
    }

    init(phase: Phase) {
        super.init(frame: .zero)

        let headerTitle: String
        let status: String
        let titleText: String
        let detailText: String
        switch phase {
        case .noHost(let detail):
            headerTitle = "Ledge"
            status = "no host"
            titleText = "Waiting for host…"
            detailText = detail
        case .noApps:
            headerTitle = "Ledge"
            status = "0 apps"
            titleText = "Host connected — no apps installed."
            detailText = "Add app folders to ~/.ledge/apps, or: bun run start:demos"
        case .starting(let app):
            headerTitle = app
            status = "starting"
            titleText = "Starting ‘\(app)’…"
            detailText = "No tree committed yet."
        }

        let header = AppHeaderView(title: headerTitle, status: status)
        header.frame = CGRect(x: 0, y: 0, width: 440, height: 34)
        addSubview(header)

        let card = RoundedBoxView(
            fill: LedgeTheme.raised,
            stroke: LedgeTheme.hairline,
            radius: LedgeMetrics.rCard
        )
        card.frame = CGRect(x: LedgeMetrics.errorCardPad, y: 40, width: 408, height: 62)
        addSubview(card)

        let title = makeLabel(
            titleText,
            font: LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize, weight: .semibold),
            color: LedgeTheme.secondary
        )
        title.frame = CGRect(x: 14, y: 12, width: 380, height: 18)
        card.addSubview(title)

        let detail = makeLabel(
            detailText,
            font: LedgeTheme.monoFont(10.5),
            color: LedgeTheme.tertiary
        )
        detail.frame = CGRect(x: 14, y: 32, width: 380, height: 16)
        card.addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
