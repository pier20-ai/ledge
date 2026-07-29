import AppKit
import LedgeShellCore

/// First-run permission onboarding, drawn by the shell in the notch panel.
///
/// The problem it solves is small and specific. Ledge apps reach macOS through
/// the *shell* (spec §6: a worker cannot own a TCC prompt), so the consent
/// dialogs are attributed to Ledge — and they arrive with no context whatsoever,
/// at whatever moment some app first touches the API, which may be a monitor
/// tick the user did not initiate and cannot connect to anything they did. Worse
/// is the second time: TCC never re-asks, so a permission refused in that
/// contextless moment is refused permanently and silently, and the app that
/// needed it just fails forever.
///
/// So this surface does exactly three things, and deliberately not a fourth:
///
/// 1. **Explains**, before anything is asked, what each grant is for.
/// 2. **Reads** the current state where macOS allows a read that does not
///    prompt, and says "unknown" where it does not (see `PermissionCatalog`).
/// 3. **Lets the user raise each prompt deliberately**, one click at a time, or
///    sends them to the pane that can undo a refusal.
///
/// The fourth thing — pre-prompting for everything at launch — is the pattern
/// this exists to avoid, and it is worth saying why beyond taste: macOS only
/// shows a dialog when the API is actually called, so a launch-time sweep would
/// be six dialogs for capabilities no app has asked for yet, answered blind, and
/// two thirds of them refused. Nothing here is required. A user who closes the
/// panel gets a working Ledge and the ordinary just-in-time prompts.
///
/// It is not a grant UI either: Ledge stores no grant state of its own, and no
/// row here gates a capability. Every button is a shortcut to something macOS
/// was going to ask anyway.
final class PermissionsCardView: FlippedView {
    /// The strip the expanded panel always reserves (spec §8). Content stops
    /// above it; the same constant `HostPlaceholderView` adds to its own height.
    static let appStripHeight: CGFloat = 42

    static let width: CGFloat = PanelLimits.defaultWidth
    private static let pad: CGFloat = LedgeMetrics.errorCardPad
    private static let rowGap: CGFloat = 5

    /// The user is done with this surface — dismissed, not "finished", because
    /// there is nothing here that has to be completed.
    var onDismiss: (() -> Void)?
    /// The rows changed shape — a status gained or lost its explanatory line —
    /// so the panel has to be re-measured around them.
    var onResize: (() -> Void)?

    private let probe: PermissionProbing
    private let content = FlippedView()
    private var rows: [PermissionRow] = []
    private var rowViews: [LedgePermission: PermissionRowView] = [:]
    /// Re-read while the surface is on screen. The whole point of the Settings
    /// button is that the user leaves and changes something behind our back; a
    /// row still reading DENIED when they come back would teach them the deep
    /// link does not work.
    private var poll: Timer?

    /// Total panel height for this content, including the app strip — the number
    /// `NotchPanelController` needs before it can present. Measured rather than
    /// declared, because the rows grow a line when a status has something to say.
    private(set) var panelHeight: CGFloat = 0

    init(probe: PermissionProbing) {
        self.probe = probe
        super.init(frame: .zero)
        addSubview(content)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Start or stop watching the system.
    ///
    /// Driven by the controller rather than by `viewDidMoveToWindow`, because
    /// the surface stays in the view hierarchy after the panel collapses — a
    /// window-based guard would leave this polling TCC forever for a panel
    /// nobody can see.
    func setActive(_ active: Bool) {
        guard active != (poll != nil) else { return }
        poll?.invalidate()
        poll = nil
        guard active else { return }
        // Notifications are the one status that cannot be read synchronously,
        // so the first draw guesses "not asked" and this corrects it.
        SystemPermissionProbe.refreshNotificationStatus { [weak self] in self?.reload() }
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStatuses() }
        }
    }

    /// Test/introspection accessor: whether the surface is watching the system.
    var isWatching: Bool { poll != nil }

    private func pollStatuses() {
        SystemPermissionProbe.refreshNotificationStatus { [weak self] in self?.reload() }
        // Rebuild only on a real change: this fires every 1.5 s, and tearing the
        // subtree down under the user's cursor would flicker every button's hover.
        guard permissionRows(from: probe) != rows else { return }
        reload()
    }

    /// Rebuild the whole list from a fresh read.
    ///
    /// Wholesale rather than per-row on purpose: one click can move two rows.
    /// Allowing Screen Recording is the case — the answer comes back as "we
    /// cannot tell until you relaunch", which is a different row shape than the
    /// one that was clicked.
    private func reload() {
        rows = permissionRows(from: probe)
        rowViews.removeAll()
        content.subviews.forEach { $0.removeFromSuperview() }

        let header = AppHeaderView(title: "Ledge", status: "permissions")
        header.frame = CGRect(x: 0, y: 0, width: Self.width, height: 34)
        content.addSubview(header)

        let intro = NSTextField(wrappingLabelWithString: Self.intro)
        intro.font = LedgeTheme.systemFont(11.5)
        intro.textColor = LedgeTheme.secondary
        intro.isSelectable = false
        // Measured, not guessed: the copy is three lines at 440 pt and a fixed
        // two-line box clipped the last one clean off.
        let introWidth = Self.width - Self.pad * 2
        let introHeight = ceil(intro.sizeThatFits(CGSize(width: introWidth, height: .greatestFiniteMagnitude)).height)
        intro.frame = CGRect(x: Self.pad, y: 38, width: introWidth, height: introHeight)
        content.addSubview(intro)

        var y = 44 + introHeight
        for row in rows {
            let view = PermissionRowView(row: row) { [weak self] in self?.activate(row.permission) }
            rowViews[row.permission] = view
            view.frame = CGRect(
                x: Self.pad,
                y: y,
                width: Self.width - Self.pad * 2,
                height: PermissionRowView.height(for: row)
            )
            content.addSubview(view)
            y += view.frame.height + Self.rowGap
        }
        y -= Self.rowGap                      // no gap after the last row
        let footnote = makeLabel(
            "You can reopen this from Settings.",
            font: LedgeTheme.systemFont(11),
            color: LedgeTheme.tertiary
        )
        footnote.frame = CGRect(x: Self.pad, y: y + 9, width: 240, height: 16)
        content.addSubview(footnote)

        let done = LedgeButton("Done", variant: .glass, size: .s) { [weak self] in
            self?.dismiss()
        }
        let doneWidth = max(72, done.intrinsicContentSize.width)
        done.frame = CGRect(
            x: Self.width - Self.pad - doneWidth,
            y: y,
            width: doneWidth,
            height: LedgeMetrics.Size.s.height
        )
        content.addSubview(done)

        let measured = y + LedgeMetrics.Size.s.height + Self.pad + Self.appStripHeight
        let grew = measured != panelHeight && panelHeight != 0
        panelHeight = measured
        content.frame = CGRect(x: 0, y: 0, width: Self.width, height: panelHeight)
        needsLayout = true
        // Only after the first build: the controller asks for `panelHeight`
        // straight after init, so announcing it then would re-enter `refresh`
        // for a surface that is not on screen yet.
        if grew { onResize?() }
    }

    override func layout() {
        super.layout()
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: content.frame.height)
    }

    /// Do whatever this permission's row offers — which is at most one thing,
    /// and for a granted row is nothing at all.
    ///
    /// Internal rather than private because it is also the seam a test presses:
    /// `LedgeButton` runs its own mouse loop off `window.nextEvent`, so a
    /// synthetic click on a view that is in no window can never reach the
    /// handler. Calling this is the same path minus AppKit's event pump.
    func activate(_ permission: LedgePermission) {
        guard let row = rows.first(where: { $0.permission == permission }) else { return }
        switch row.action {
        case .settled:
            break
        case .ask:
            probe.ask(row.permission) { [weak self] _ in self?.reload() }
        case .openSettings:
            probe.openSettings(for: row.permission)
        }
    }

    /// The user is finished with the surface. Not "done": nothing here has to be
    /// completed, and closing without touching a row is a legitimate answer.
    func dismiss() {
        onDismiss?()
    }

    /// Test/introspection accessors: what the surface currently believes, and
    /// what each row is offering to do about it.
    var visibleRows: [PermissionRow] { rows }
    func actionLabel(for permission: LedgePermission) -> String? {
        rowViews[permission]?.actionButton?.currentLabel
    }

    /// Deliberately says "when an app needs it" rather than "later": the reason
    /// this surface is optional is that the prompts still happen on their own,
    /// and a user who does not know that reads a skipped onboarding as a broken
    /// install.
    private static let intro = """
        Apps reach macOS through Ledge, so the system asks Ledge — normally at \
        the moment an app first needs something. You can settle any of these now \
        instead, or skip it and answer when it comes up.
        """
}

/// One permission: what it is, what it is for, where it stands, and the single
/// thing you can do about it.
fileprivate final class PermissionRowView: RoundedBoxView {
    /// The row's single affordance, or nil when there is nothing left to do.
    private(set) var actionButton: LedgeButton?

    private static let padX: CGFloat = 12
    private static let padY: CGFloat = 8
    private static let titleHeight: CGFloat = 16
    private static let lineHeight: CGFloat = 14
    private static let footnoteHeight: CGFloat = 13
    private static let iconColumn: CGFloat = 26
    /// The row's own width: the panel minus the card inset either side. Stated
    /// here because the pill and the button are laid out from the right edge
    /// before the row has been given a frame.
    private static let width = PermissionsCardView.width - LedgeMetrics.errorCardPad * 2
    /// Width of the two text lines. They sit *below* the title, so they have the
    /// row to themselves — the pill and the button share the title's line.
    private static let textWidth = width - iconColumn - padX * 2

    static func height(for row: PermissionRow) -> CGFloat {
        let footnote = row.footnote == nil ? 0 : footnoteHeight + 2
        return padY * 2 + titleHeight + 2 + lineHeight + footnote
    }

    init(row: PermissionRow, act: @escaping () -> Void) {
        super.init(fill: LedgeTheme.raised, stroke: LedgeTheme.hairline, radius: LedgeMetrics.rCard)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: row.permission.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            )
        // The glyph is a label for the row, not a status: it stays quiet ink
        // whatever the state is, and the pill carries the colour (L9).
        icon.contentTintColor = LedgeTheme.secondary
        icon.frame = CGRect(x: Self.padX, y: Self.padY, width: 18, height: Self.titleHeight)
        addSubview(icon)

        let title = makeLabel(
            row.permission.title,
            font: LedgeTheme.systemFont(12.5, weight: .semibold),
            color: LedgeTheme.primary
        )
        title.frame = CGRect(
            x: Self.padX + Self.iconColumn,
            y: Self.padY,
            width: 200,
            height: Self.titleHeight
        )
        addSubview(title)

        let summary = makeLabel(
            row.permission.summary,
            font: LedgeTheme.systemFont(11),
            color: LedgeTheme.secondary
        )
        summary.frame = CGRect(
            x: Self.padX + Self.iconColumn,
            y: Self.padY + Self.titleHeight + 2,
            width: Self.textWidth,
            height: Self.lineHeight
        )
        addSubview(summary)

        if let footnote = row.footnote {
            let label = makeLabel(
                footnote,
                font: LedgeTheme.systemFont(10.5),
                color: LedgeTheme.tertiary
            )
            label.frame = CGRect(
                x: Self.padX + Self.iconColumn,
                y: Self.padY + Self.titleHeight + Self.lineHeight + 4,
                width: Self.textWidth,
                height: Self.footnoteHeight
            )
            addSubview(label)
        }

        let pill = LedgePill(text: row.status.badge, tone: Self.tone(row.status))
        addSubview(pill)

        var rightEdge = Self.width - Self.padX
        if let label = row.action.label {
            let button = LedgeButton(label, variant: .glass, size: .s, handler: act)
            let buttonWidth = max(64, button.intrinsicContentSize.width)
            button.frame = CGRect(
                x: rightEdge - buttonWidth,
                y: Self.padY - 3,
                width: buttonWidth,
                height: LedgeMetrics.Size.s.height
            )
            addSubview(button)
            actionButton = button
            rightEdge -= buttonWidth + 8
        }
        let pillWidth = pill.intrinsicContentSize.width
        pill.frame = CGRect(
            x: rightEdge - pillWidth,
            y: Self.padY + 1,
            width: pillWidth,
            height: LedgeMetrics.pillHeight
        )

        setAccessibilityRole(.group)
        setAccessibilityLabel("\(row.permission.title): \(row.status.badge)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func tone(_ status: PermissionStatus) -> LedgePill.Tone {
        switch status.tone {
        case .good: .green
        case .bad: .red
        case .quiet: .neutral
        }
    }
}
