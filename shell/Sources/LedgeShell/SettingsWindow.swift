import AppKit
import LedgeShellCore

/// **Settings is a window** (flow.md, Edges: "Settings — a native macOS window;
/// configuration doesn't belong on glass").
///
/// It used to be an app in the strip: a privileged session that could call
/// `ctx.platform.enable/disable` and raise the permission card. That was elegant
/// as a demonstration of the protocol and wrong as a product. Configuration is
/// not a glance and it is not a session — nobody wants their preferences to be a
/// thing that hovers, times out, walks off the end of a strip, or competes for
/// the notch with the music. It is also the one surface where the platform's own
/// conventions are worth more than ours: a titled window, ⌘W, the traffic
/// lights, real keyboard focus, a scroll bar that behaves.
///
/// So this is a plain `NSWindow`. No silhouette, no glass, no bead, no spring.
/// The one concession is the **dark appearance**: the permission rows it hosts
/// are `PermissionsCardView`, drawn in the shell's white-on-black inks, and a
/// light window would render them invisible. Dark aqua is still standard macOS —
/// it is a system appearance, not a Ledge material.
///
/// It carries exactly the two things that used to be in the Settings app:
///
///   · **the apps**, each with a switch, driving the same `appControl` envelope
///     the ledge's ✕ sends (`HostSession.setAppEnabled`); and
///   · **the permissions**, rehosted rather than reimplemented — it is the same
///     view the first-run card shows, and there must not be two answers to
///     "does Ledge have Accessibility".
@MainActor
final class SettingsWindowController {
    /// Wide enough for the permission card at its natural width plus the
    /// window's own margins; tall enough to open showing the whole of the apps
    /// list, and it scrolls from there.
    private static let contentWidth: CGFloat = PermissionsCardView.width + pad * 2
    private static let initialHeight: CGFloat = 560
    private static let pad: CGFloat = 20
    private static let sectionGap: CGFloat = 24

    private let session: HostSession
    private let probe: PermissionProbing
    /// Quit lives here because `LSUIElement` means there is no Dock icon and no
    /// menu-bar item to hold it (see `AppDelegate`). The right-click menu has
    /// the other copy.
    private let onQuit: () -> Void

    private var window: NSWindow?
    private var appsStack: NSStackView?
    private var permissions: PermissionsCardView?
    /// The catalog can change while the window is open — an app crashes, the
    /// host restarts, a switch we threw comes back confirmed — and the list has
    /// to follow it rather than showing what was true when it opened.
    private var listedApps: [CatalogApp] = []

    init(session: HostSession, probe: PermissionProbing, onQuit: @escaping () -> Void) {
        self.session = session
        self.probe = probe
        self.onQuit = onQuit
    }

    // MARK: - Opening

    /// Show it, and **activate**.
    ///
    /// Ledge is an accessory app, so its panel is deliberately non-activating —
    /// clicking the notch must not steal focus from what you were typing in. A
    /// settings window is the opposite case: it is a place you go, it has text
    /// fields and buttons and a close box, and every one of those needs the
    /// keyboard. An accessory app is allowed to activate and hold a key window;
    /// it simply has to ask, which nothing else in Ledge ever does.
    func show() {
        let window = existingOrNewWindow()
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        permissions?.setActive(true)
    }

    /// Whether the window is on screen. The controller asks so a second ⌘, can
    /// bring it forward rather than building another one.
    var isVisible: Bool { window?.isVisible ?? false }

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(
            contentRect: CGRect(
                x: 0, y: 0,
                width: Self.contentWidth,
                height: Self.initialHeight
            ),
            // No `.resizable`: the content is a fixed-width list and a fixed-width
            // card, so a resize would only ever add margin. `.miniaturizable` is
            // included because a window without it reads as a dialog, and this is
            // not a dialog — there is nothing to confirm.
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ledge Settings"
        // Survives its own close box: reopening must not rebuild the permission
        // probe or lose the scroll position.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        // Remembers where the user put it, which is the whole reason a settings
        // window is nicer than a pane.
        window.setFrameAutosaveName("LedgeSettings")
        window.delegate = windowDelegate
        window.contentView = buildContent()
        self.window = window
        return window
    }

    /// Stops the TCC poll when the window goes away. `PermissionsCardView`'s
    /// polling is owner-driven precisely so it cannot outlive its surface.
    private lazy var windowDelegate = SettingsWindowDelegate { [weak self] in
        self?.permissions?.setActive(false)
    }

    // MARK: - Content

    private func buildContent() -> NSView {
        let apps = NSStackView()
        apps.orientation = .vertical
        apps.alignment = .leading
        apps.spacing = 4
        appsStack = apps

        let card = PermissionsCardView(probe: probe)
        // The card's own dismiss is the panel's "Done"; in a window the close
        // box is the way out, so the button would be a second one that does
        // something subtly different. Re-measure is still ours to honour.
        card.onDismiss = { [weak self] in self?.window?.performClose(nil) }
        card.onResize = { [weak self] in self?.layoutPermissions() }
        permissions = card

        // No "Permissions" header of our own: `PermissionsCardView` brings its
        // own ("Ledge / permissions"), and two headers stacked on one section is
        // the sort of thing that happens when a view is rehosted without being
        // looked at.
        let column = NSStackView(views: [
            sectionHeader("Apps"),
            apps,
            card,
            quitRow(),
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Self.sectionGap
        column.edgeInsets = NSEdgeInsets(
            top: Self.pad, left: Self.pad, bottom: Self.pad, right: Self.pad
        )
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.defaultHigh, for: .vertical)

        // A scroll view, because the apps list grows with what is installed and
        // a settings window that clips its own content is worse than one that
        // scrolls.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.windowBackground
        scroll.autohidesScrollers = true
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(column)
        scroll.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            column.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: documentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        return scroll
    }

    /// A plain window background — a real one, not the panel's black glass. This
    /// window is furniture, and furniture matches the system.
    private static let windowBackground = NSColor(white: 0.13, alpha: 1)

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = LedgeTheme.systemFont(
            LedgeMetrics.TypeSize.xs.pointSize,
            weight: .semibold
        )
        label.textColor = LedgeTheme.tertiary
        // The eyebrow tracking every other section header in the product uses.
        label.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: LedgeTheme.systemFont(
                    LedgeMetrics.TypeSize.xs.pointSize,
                    weight: .semibold
                ),
                .foregroundColor: LedgeTheme.tertiary,
                .kern: LedgeMetrics.TypeSize.xs.pointSize * LedgeMetrics.capsTracking,
            ]
        )
        return label
    }

    private func quitRow() -> NSView {
        let button = LedgeButton("Quit Ledge", variant: .glass) { [weak self] in
            self?.onQuit()
        }
        return button
    }

    // MARK: - The apps list

    /// Rebuild the rows from the live catalog.
    ///
    /// Called on every open and on every catalog envelope. Wholesale rather than
    /// diffed: the list is a handful of rows, and an app appearing, disappearing
    /// or being renamed all arrive the same way.
    func reload() {
        guard let appsStack else { return }
        listedApps = session.installedApps
        appsStack.arrangedSubviews.forEach {
            appsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !listedApps.isEmpty else {
            appsStack.addArrangedSubview(emptyRow())
            return
        }
        for app in listedApps {
            appsStack.addArrangedSubview(row(for: app))
        }
        layoutPermissions()
    }

    private func emptyRow() -> NSView {
        let label = NSTextField(labelWithString: "No apps installed yet.")
        label.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize)
        label.textColor = LedgeTheme.secondary
        return label
    }

    private func row(for app: CatalogApp) -> NSView {
        let icon = LedgeSymbolView(symbol: app.symbolName ?? "square.dashed")
        icon.contentTintColor = app.enabled ? LedgeTheme.primary : LedgeTheme.tertiary

        let name = NSTextField(labelWithString: app.name)
        name.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize, weight: .medium)
        name.textColor = app.enabled ? LedgeTheme.primary : LedgeTheme.secondary

        // What the switch is actually reporting: an enabled app whose worker is
        // not up is a crash, and hiding that behind a green switch would make
        // Settings lie about the one thing it is for.
        let status = NSTextField(labelWithString: statusLine(for: app))
        status.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.xs.pointSize)
        status.textColor = LedgeTheme.tertiary

        let labels = NSStackView(views: [name, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let toggle = LedgeToggle(on: app.enabled) { [weak self] on in
            self?.setEnabled(app.id, on)
        }
        toggle.setAccessibilityLabel(app.name)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [icon, labels, spacer, toggle])
        row.orientation = NSUserInterfaceLayoutOrientation.horizontal
        row.alignment = NSLayoutConstraint.Attribute.centerY
        row.spacing = LedgeMetrics.gap + 2
        row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth - Self.pad * 2),
        ])
        return row
    }

    private func statusLine(for app: CatalogApp) -> String {
        switch (app.enabled, app.running) {
        case (false, _): "Off"
        case (true, true): "Running"
        // Enabled but not running: the host is between spawns, or the worker
        // died. Either way it is a real state and the row says so.
        case (true, false): "Starting…"
        }
    }

    /// Throw the switch.
    ///
    /// Deliberately **does not** update the row optimistically. The catalog is
    /// the only truth about what is installed and enabled (spec §3.6), and the
    /// host re-sends it as the last step of `setAppEnabled` — so the row moves
    /// when the change has actually happened. A switch that snaps immediately
    /// and then silently disagrees with the strip is the exact failure this
    /// window exists to prevent.
    private func setEnabled(_ app: String, _ enabled: Bool) {
        session.setAppEnabled(app, enabled: enabled)
    }

    // MARK: - Layout

    private func layoutPermissions() {
        guard let permissions else { return }
        permissions.translatesAutoresizingMaskIntoConstraints = false
        permissions.setFrameSize(
            CGSize(width: PermissionsCardView.width, height: permissions.panelHeight)
        )
        permissions.layoutSubtreeIfNeeded()
        // The card measures itself and the window's column has to take that
        // number rather than guess it — a row grows a line when a status has
        // something to say.
        permissionsHeight?.isActive = false
        let constraint = permissions.heightAnchor.constraint(
            equalToConstant: max(1, permissions.panelHeight)
        )
        constraint.isActive = true
        permissionsHeight = constraint
        permissionsWidth?.isActive = false
        let width = permissions.widthAnchor.constraint(equalToConstant: PermissionsCardView.width)
        width.isActive = true
        permissionsWidth = width
    }

    private var permissionsHeight: NSLayoutConstraint?
    private var permissionsWidth: NSLayoutConstraint?

    // MARK: - Test seams

    var windowForTesting: NSWindow? { window }
    var listedAppsForTesting: [CatalogApp] { listedApps }
    /// The switches, in the order they are drawn.
    var togglesForTesting: [LedgeToggle] {
        (appsStack?.arrangedSubviews ?? []).compactMap { row in
            (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? LedgeToggle }.first
        }
    }
    var permissionsForTesting: PermissionsCardView? { permissions }
    /// Build the window without showing it — every layout assertion needs the
    /// view tree, and none of them needs to steal the user's focus.
    func loadForTesting() {
        _ = existingOrNewWindow()
        reload()
    }
}

/// `NSWindowDelegate` as a small object rather than making the controller one:
/// the controller is not a view and has no other business with AppKit's
/// delegate protocol.
@MainActor
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
