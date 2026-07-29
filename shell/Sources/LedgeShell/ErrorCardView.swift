import AppKit
import LedgeShellCore

/// Built-in panel shown when an app crashes (spec §3.2 / §7): the message plus a
/// stack snippet, styled to match the dark glass theme. No app cooperation
/// required — the shell renders this itself.
final class ErrorCardView: FlippedView {
    init(app: String, message: String, stack: String?) {
        super.init(frame: .zero)

        let header = AppHeaderView(title: app.isEmpty ? "App" : app, status: "crashed")
        header.frame = CGRect(x: 0, y: 0, width: 440, height: 34)
        addSubview(header)

        // The badge is a pill like any other: the red tint/stroke/ink triple from
        // the theme, at the pill tier's capsule radius (D6, law L9).
        let badge = LedgePill(text: "CRASHED", tone: .red)
        badge.frame = CGRect(
            x: LedgeMetrics.errorCardPad,
            y: 44,
            width: 74,
            height: LedgeMetrics.pillHeight
        )
        addSubview(badge)

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = LedgeTheme.systemFont(12.5, weight: .semibold)
        messageLabel.textColor = LedgeTheme.primary
        messageLabel.isSelectable = true
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.frame = CGRect(x: 16, y: 74, width: 408, height: 40)
        addSubview(messageLabel)

        if let stack, !stack.isEmpty {
            let box = RoundedBoxView(
                fill: LedgeTheme.sunken,
                stroke: LedgeTheme.hairline,
                radius: LedgeMetrics.rCard
            )
            box.frame = CGRect(x: LedgeMetrics.errorCardPad, y: 120, width: 408, height: 132)

            let snippet = NSTextField(wrappingLabelWithString: Self.snippet(from: stack))
            snippet.font = LedgeTheme.monoFont(10)
            // Hue is meaning and the theme owns the value (L9/L1): a stack trace
            // is the error's own red, not a bespoke salmon.
            snippet.textColor = LedgeTheme.red
            snippet.isSelectable = true
            snippet.maximumNumberOfLines = 8
            snippet.lineBreakMode = .byTruncatingTail
            snippet.frame = CGRect(x: 12, y: 10, width: 384, height: 112)
            box.addSubview(snippet)
            addSubview(box)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// First few stack lines; the full trace lands in `crash.log` (§7).
    private static func snippet(from stack: String) -> String {
        stack
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(8)
            .joined(separator: "\n")
    }
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
            font: LedgeTheme.systemFont(12.5, weight: .semibold),
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
