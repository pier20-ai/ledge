import AppKit
import LedgeShellCore
import ServiceManagement

/// **Settings is a window** (flow.md, Edges: "Settings — a native macOS window;
/// configuration doesn't belong on glass") — and since G4 it is shaped like one
/// the platform's own: a sidebar of pages on the left, one page on the right,
/// the way System Settings and every serious app's preferences read.
///
/// The pages:
///
///   · **General** — the hotkey, launch at login, and Quit (which lives in
///     Settings because `LSUIElement` means there is no Dock icon or menu-bar
///     item to hold it).
///   · **Apps** — every installed app with its switch, driving the same
///     `appControl` envelope the ledge's ✕ sends.
///   · **Onboarding** — the permission rows, rehosted over the shared probe.
///     This page IS first-run now: the notch no longer grows a permission
///     card; a fresh install opens this window on this page, once, ever.
///   · **One page per app that declares `meta.settings`** — the app's own
///     controls, rendered natively (a switch, a pop-up, a field, a slider)
///     and confirmed through the catalog rather than optimistically.
///
/// No glass, no silhouette, no bead. The one concession is the dark
/// appearance: the permission rows are `PermissionsCardView`, drawn in the
/// shell's white-on-black inks, and a light window would render them
/// invisible. Dark aqua is still standard macOS.
@MainActor
final class SettingsWindowController {
    static let sidebarWidth: CGFloat = 200
    static let contentWidth: CGFloat = PermissionsCardView.width + pad * 2
    static let pad: CGFloat = 20
    private static let initialHeight: CGFloat = 560

    /// A plain window background — a real one, not the panel's black glass.
    /// This window is furniture, and furniture matches the system.
    static let windowBackground = NSColor(white: 0.13, alpha: 1)

    private let session: HostSession
    private let probe: PermissionProbing
    private let onQuit: () -> Void

    private var window: NSWindow?
    private var sidebarStack: NSStackView?
    private var contentScroll: NSScrollView?

    // The standing pages, built once. App pages come and go with the catalog,
    // but these three ARE the window.
    private lazy var generalPage = GeneralSettingsPage(onQuit: onQuit)
    private lazy var appsPage = AppsSettingsPage(session: session)
    private lazy var onboardingPage = OnboardingSettingsPage(probe: probe) { [weak self] in
        self?.window?.performClose(nil)
    }
    /// One page per app that declares settings, kept by id so a rebuild while
    /// the user is mid-edit does not tear the field out from under them.
    private var appPages: [String: AppSettingsPage] = [:]

    private(set) var selectedPageId: String = GeneralSettingsPage.id

    init(session: HostSession, probe: PermissionProbing, onQuit: @escaping () -> Void) {
        self.session = session
        self.probe = probe
        self.onQuit = onQuit
    }

    // MARK: - Opening

    /// Show it, and **activate**: Ledge is an accessory app whose panel never
    /// takes focus, but a settings window is a place you go — it has fields
    /// and a close box, and both need the keyboard. `page` lands the window on
    /// a specific page (first run opens Onboarding); nil keeps the last one.
    func show(page: String? = nil) {
        let window = existingOrNewWindow()
        catalogChanged()
        if let page { select(page) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The catalog moved: an app appeared, a switch we threw confirmed, a
    /// setting's new value came back. Cheap when the window has never been
    /// built (nothing to do), and never *builds* it — a catalog envelope must
    /// not summon a window.
    func catalogChanged() {
        guard window != nil else { return }
        appsPage.reload()
        rebuildAppPages()
        rebuildSidebar()
    }

    // MARK: - Window

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(
            contentRect: CGRect(
                x: 0, y: 0,
                width: Self.sidebarWidth + Self.contentWidth,
                height: Self.initialHeight
            ),
            // `.fullSizeContentView` + a transparent titlebar is what lets the
            // sidebar's material run to the top edge — the shape every
            // settings window on the platform has today.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ledge Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.setFrameAutosaveName("LedgeSettings")
        window.delegate = windowDelegate
        window.contentView = buildContent()
        self.window = window
        catalogChanged()
        select(selectedPageId)
        return window
    }

    /// Stops the TCC poll when the window goes away — the onboarding page's
    /// polling is owner-driven precisely so it cannot outlive its surface.
    private lazy var windowDelegate = SettingsWindowDelegate { [weak self] in
        guard let self else { return }
        page(for: selectedPageId)?.pageDidHide()
    }

    private func buildContent() -> NSView {
        let root = NSView()

        // The sidebar: the system's material, running the window's full
        // height, with the page list laid over it.
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack = stack

        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        let sidebarDocument = FlippedView()
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        sidebarDocument.addSubview(stack)
        sidebarScroll.documentView = sidebarDocument
        sidebar.addSubview(sidebarScroll)

        // The content half: one scroll view whose document is the selected
        // page's view.
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.windowBackground
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll = scroll

        root.addSubview(sidebar)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            // Below the (transparent) titlebar, so the traffic lights never
            // sit on a row.
            sidebarScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 40),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            stack.topAnchor.constraint(equalTo: sidebarDocument.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: sidebarDocument.bottomAnchor),
            sidebarDocument.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    // MARK: - Pages

    /// Every page, in sidebar order: the standing three, then the apps that
    /// declare settings.
    private var pages: [SettingsPage] {
        var all: [SettingsPage] = [generalPage, appsPage, onboardingPage]
        for app in session.installedApps where !(app.settings ?? []).isEmpty {
            if let page = appPages[app.id] { all.append(page) }
        }
        return all
    }

    private func page(for id: String) -> SettingsPage? {
        pages.first { $0.pageId == id }
    }

    private func rebuildAppPages() {
        var kept: [String: AppSettingsPage] = [:]
        for app in session.installedApps where !(app.settings ?? []).isEmpty {
            let page = appPages[app.id] ?? AppSettingsPage(session: session)
            page.update(app: app)
            kept[app.id] = page
        }
        appPages = kept
        // The selected page can vanish — the app was disabled mid-look — and
        // the window must land somewhere rather than on an empty pane.
        if page(for: selectedPageId) == nil {
            select(GeneralSettingsPage.id)
        } else if selectedPageId == appsPage.pageId || appPages[selectedPageId] != nil {
            // The visible page's content may have changed under it.
            showSelected()
        }
    }

    private func rebuildSidebar() {
        guard let sidebarStack else { return }
        sidebarStack.arrangedSubviews.forEach {
            sidebarStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let standing: [SettingsPage] = [generalPage, appsPage, onboardingPage]
        for page in standing {
            sidebarStack.addArrangedSubview(sidebarRow(for: page))
        }
        let declaring = pages.filter { appPages[$0.pageId] != nil }
        if !declaring.isEmpty {
            sidebarStack.addArrangedSubview(sidebarEyebrow("Apps"))
            for page in declaring {
                sidebarStack.addArrangedSubview(sidebarRow(for: page))
            }
        }
    }

    private func sidebarRow(for page: SettingsPage) -> NSView {
        let row = SettingsSidebarRow(
            title: page.pageTitle,
            symbol: page.pageSymbol,
            selected: page.pageId == selectedPageId
        ) { [weak self] in
            self?.select(page.pageId)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.sidebarWidth - 20).isActive = true
        return row
    }

    private func sidebarEyebrow(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: LedgeTheme.systemFont(LedgeMetrics.TypeSize.xs.pointSize, weight: .semibold),
                .foregroundColor: LedgeTheme.tertiary,
                .kern: LedgeMetrics.TypeSize.xs.pointSize * LedgeMetrics.capsTracking,
            ]
        )
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            box.heightAnchor.constraint(equalToConstant: 28),
        ])
        return box
    }

    /// Land on a page: swap the content document, tell the pages, repaint the
    /// sidebar's selection.
    func select(_ id: String) {
        guard let target = page(for: id) else { return }
        if selectedPageId != id {
            page(for: selectedPageId)?.pageDidHide()
        }
        selectedPageId = id
        rebuildSidebar()
        showSelected()
        target.pageDidShow()
    }

    private func showSelected() {
        guard let contentScroll, let target = page(for: selectedPageId) else { return }
        let view = target.pageView
        view.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(view)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            view.topAnchor.constraint(equalTo: document.topAnchor, constant: 40),
            view.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.pad),
            view.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.pad),
            view.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.pad),
        ])
        contentScroll.documentView = document
    }

    // MARK: - Test seams

    var windowForTesting: NSWindow? { window }
    var listedAppsForTesting: [CatalogApp] { appsPage.listedApps }
    /// The enable switches, in the order the Apps page draws them.
    var togglesForTesting: [LedgeToggle] { appsPage.togglesForTesting }
    var permissionsForTesting: PermissionsCardView? { onboardingPage.cardForTesting }
    var pagesForTesting: [String] { pages.map(\.pageId) }
    var appPageForTesting: (String) -> AppSettingsPage? { { self.appPages[$0] } }
    /// Build the window without showing it — layout assertions need the view
    /// tree, and none of them needs to steal the user's focus.
    func loadForTesting() {
        _ = existingOrNewWindow()
        catalogChanged()
    }
    func selectForTesting(_ id: String) { select(id) }
}

// MARK: - The page protocol

/// One sidebar entry and the pane it shows. A page owns its view and keeps it
/// (state like a half-typed field must survive a catalog reload); the window
/// owns when it is visible.
@MainActor
protocol SettingsPage: AnyObject {
    var pageId: String { get }
    var pageTitle: String { get }
    var pageSymbol: String { get }
    var pageView: NSView { get }
    func pageDidShow()
    func pageDidHide()
}

extension SettingsPage {
    func pageDidShow() {}
    func pageDidHide() {}
}

// MARK: - Sidebar row

/// One page in the sidebar: icon, title, and the system's rounded selection.
final class SettingsSidebarRow: NSControl {
    private let title: String
    private let symbol: String
    private let selected: Bool
    private let onPress: () -> Void
    private var hovered = false

    init(title: String, symbol: String, selected: Bool, onPress: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.onPress = onPress
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            (selected ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.06)).setFill()
            path.fill()
        }
        let ink: NSColor = selected ? .white : NSColor.white.withAlphaComponent(0.72)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let tinted = image.tinted(ink)
            tinted.draw(in: CGRect(x: 10, y: (bounds.height - 15) / 2, width: 16, height: 15))
        }
        let text = NSAttributedString(
            string: title,
            attributes: [
                .font: LedgeTheme.systemFont(LedgeMetrics.TypeSize.s.pointSize, weight: selected ? .medium : .regular),
                .foregroundColor: ink,
            ]
        )
        text.draw(at: CGPoint(x: 34, y: (bounds.height - text.size().height) / 2))
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - General

/// The shell's own knobs. Small on purpose: a General page that accretes every
/// idea is how settings windows go to seed.
@MainActor
final class GeneralSettingsPage: SettingsPage {
    static let id = "general"
    var pageId: String { Self.id }
    var pageTitle: String { "General" }
    var pageSymbol: String { "gearshape" }

    private let onQuit: () -> Void
    private var built: NSView?

    init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    var pageView: NSView {
        if let built { return built }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18

        column.addArrangedSubview(SettingsRows.header("General"))

        // The hotkey. Stated, not configurable: one chord, until a second
        // binding earns a table (see `HotkeyCenter`).
        column.addArrangedSubview(SettingsRows.labeled(
            title: "Open Ledge",
            detail: "From anywhere, no hover. Lands on a live recording when there is one.",
            trailing: SettingsRows.keycap("⌃⌥Space")
        ))

        column.addArrangedSubview(SettingsRows.labeled(
            title: "Launch at login",
            detail: launchDetail,
            trailing: launchControl()
        ))

        let quit = LedgeButton("Quit Ledge", variant: .glass) { [onQuit] in onQuit() }
        column.addArrangedSubview(quit)

        built = column
        return column
    }

    /// `SMAppService` needs a real bundle: registering a bare executable is an
    /// error, and the row says so instead of offering a switch that throws.
    private var canManageLogin: Bool { Bundle.main.bundleIdentifier != nil }

    private var launchDetail: String {
        canManageLogin
            ? "Ledge starts when you log in."
            : "Only the bundled Ledge.app can register for login."
    }

    private func launchControl() -> NSView {
        guard canManageLogin else {
            let label = NSTextField(labelWithString: "Unavailable")
            label.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.xs.pointSize)
            label.textColor = LedgeTheme.tertiary
            return label
        }
        let toggle = LedgeToggle(on: SMAppService.mainApp.status == .enabled) { on in
            do {
                if on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[ledge] launch at login: %@", String(describing: error))
            }
        }
        toggle.setAccessibilityLabel("Launch at login")
        return toggle
    }
}

// MARK: - Apps

/// Every installed app with its switch — the rows the old single-scroll window
/// carried, now a page.
@MainActor
final class AppsSettingsPage: SettingsPage {
    static let id = "apps"
    var pageId: String { Self.id }
    var pageTitle: String { "Apps" }
    var pageSymbol: String { "square.grid.2x2" }

    private let session: HostSession
    private var stack: NSStackView?
    private(set) var listedApps: [CatalogApp] = []

    init(session: HostSession) {
        self.session = session
    }

    var pageView: NSView {
        if let stack { return stack }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        stack = column
        reload()
        return column
    }

    /// Rebuild the rows from the live catalog. Wholesale rather than diffed:
    /// the list is a handful of rows, and an app appearing, disappearing or
    /// being renamed all arrive the same way.
    func reload() {
        // The list is refreshed even before the page has ever been shown:
        // `listedApps` is read by seams and future callers, and a window
        // sitting on General must not make it lie about the catalog.
        listedApps = session.installedApps
        guard let stack else { return }
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        stack.addArrangedSubview(SettingsRows.header("Apps"))
        guard !listedApps.isEmpty else {
            let label = NSTextField(labelWithString: "No apps installed yet.")
            label.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize)
            label.textColor = LedgeTheme.secondary
            stack.addArrangedSubview(label)
            return
        }
        for app in listedApps {
            stack.addArrangedSubview(row(for: app))
        }
    }

    private func row(for app: CatalogApp) -> NSView {
        let icon = LedgeSymbolView(symbol: app.symbolName)
        icon.contentTintColor = app.enabled ? LedgeTheme.primary : LedgeTheme.tertiary

        let name = NSTextField(labelWithString: app.name)
        name.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize, weight: .medium)
        name.textColor = app.enabled ? LedgeTheme.primary : LedgeTheme.secondary

        // What the switch is actually reporting: an enabled app whose worker
        // is not up is a crash, and hiding that behind a green switch would
        // make Settings lie about the one thing it is for.
        let status = NSTextField(labelWithString: statusLine(for: app))
        status.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.xs.pointSize)
        status.textColor = LedgeTheme.tertiary

        let labels = NSStackView(views: [name, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        // Deliberately NOT optimistic: the catalog is the only truth about
        // enabled (spec §3.6) and the host re-sends it as the change's last
        // step, so the row moves when the change has actually happened.
        let toggle = LedgeToggle(on: app.enabled) { [session] on in
            session.setAppEnabled(app.id, enabled: on)
        }
        toggle.setAccessibilityLabel(app.name)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [icon, labels, spacer, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = LedgeMetrics.gap + 2
        row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(
            equalToConstant: SettingsWindowController.contentWidth - SettingsWindowController.pad * 2
        ).isActive = true
        return row
    }

    private func statusLine(for app: CatalogApp) -> String {
        switch (app.enabled, app.running) {
        case (false, _): "Off"
        case (true, true): "Running"
        case (true, false): "Starting…"
        }
    }

    var togglesForTesting: [LedgeToggle] {
        (stack?.arrangedSubviews ?? []).compactMap { row in
            (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? LedgeToggle }.first
        }
    }
}

// MARK: - Onboarding

/// The permission rows, as a page — and as first-run itself: a fresh install
/// opens the window here, once, ever (`NotchPanelController.start`). Rehosted
/// rather than reimplemented, so this page and any other holder of the probe
/// can never disagree about whether Ledge has a grant.
@MainActor
final class OnboardingSettingsPage: SettingsPage {
    static let id = "onboarding"
    var pageId: String { Self.id }
    var pageTitle: String { "Onboarding" }
    var pageSymbol: String { "checklist" }

    private let probe: PermissionProbing
    private let onDone: () -> Void
    private var built: NSView?
    private var card: PermissionsCardView?

    init(probe: PermissionProbing, onDone: @escaping () -> Void) {
        self.probe = probe
        self.onDone = onDone
    }

    var pageView: NSView {
        if let built { return built }
        let card = PermissionsCardView(probe: probe)
        // The card's Done is the window's close here — a first-run user has
        // one job on this page and the button should end it.
        card.onDismiss = onDone
        card.onResize = { [weak self, weak card] in
            guard let card else { return }
            self?.cardHeight?.constant = card.panelHeight
        }
        self.card = card

        card.translatesAutoresizingMaskIntoConstraints = false
        let height = card.heightAnchor.constraint(equalToConstant: card.panelHeight)
        height.isActive = true
        cardHeight = height
        card.widthAnchor.constraint(equalToConstant: PermissionsCardView.width).isActive = true

        let column = NSStackView(views: [card])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        built = column
        return column
    }

    private var cardHeight: NSLayoutConstraint?

    /// The TCC poll runs exactly while this page is the one on screen.
    func pageDidShow() { card?.setActive(true) }
    func pageDidHide() { card?.setActive(false) }

    var cardForTesting: PermissionsCardView? {
        _ = pageView
        return card
    }
}

// MARK: - One app's settings

/// The native rendering of one app's `meta.settings` (G4): a switch for a
/// toggle, a pop-up for a choice, a field for text, a slider for a bounded
/// number. Values are never trusted optimistically — every change goes down
/// the control plane and the control re-reads what the catalog confirms.
@MainActor
final class AppSettingsPage: SettingsPage {
    private let session: HostSession
    private var app: CatalogApp?

    var pageId: String { app?.id ?? "" }
    var pageTitle: String { app?.name ?? "" }
    var pageSymbol: String { app?.symbolName ?? "square.dashed" }

    private var column: NSStackView?
    /// The declared spec the built rows were rendered from. Controls are only
    /// rebuilt when the SPEC moves; a value change re-binds in place, which is
    /// what keeps a half-typed field alive through its own confirmation.
    private var builtFor: [SettingSpec] = []
    private var binders: [String: (JSONValue?) -> Void] = [:]

    init(session: HostSession) {
        self.session = session
    }

    var pageView: NSView {
        if let column { return column }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        column = stack
        rebuildIfNeeded(force: true)
        return stack
    }

    /// A fresh catalog entry: rebuild if the declared controls changed shape,
    /// otherwise just re-bind the confirmed values into the existing controls.
    func update(app: CatalogApp) {
        self.app = app
        guard column != nil else { return }
        rebuildIfNeeded(force: false)
        for spec in app.settings ?? [] {
            binders[spec.key]?(effectiveValue(for: spec))
        }
    }

    private func effectiveValue(for spec: SettingSpec) -> JSONValue? {
        app?.values?[spec.key] ?? spec.defaultValue
    }

    private func rebuildIfNeeded(force: Bool) {
        guard let column, let app else { return }
        let specs = app.settings ?? []
        guard force || specs != builtFor else { return }
        builtFor = specs
        binders = [:]
        popupTargets.empty() // the old controls die with their rows
        column.arrangedSubviews.forEach {
            column.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        column.addArrangedSubview(SettingsRows.header(app.name))
        for spec in specs {
            guard let kind = spec.kind else { continue } // future vocabulary
            column.addArrangedSubview(row(spec: spec, kind: kind))
        }
    }

    private func row(spec: SettingSpec, kind: SettingSpec.Kind) -> NSView {
        let control: NSView
        switch kind {
        case .toggle: control = toggleControl(spec)
        case .choice: control = choiceControl(spec)
        case .text: control = textControl(spec)
        case .number: control = numberControl(spec)
        }
        return SettingsRows.labeled(title: spec.label, detail: spec.hint, trailing: control)
    }

    private func send(_ spec: SettingSpec, _ value: JSONValue) {
        guard let app else { return }
        session.setAppSetting(app.id, key: spec.key, value: value)
    }

    private func toggleControl(_ spec: SettingSpec) -> NSView {
        let toggle = LedgeToggle(on: effectiveValue(for: spec)?.asBool ?? false) { [weak self] on in
            self?.send(spec, .bool(on))
        }
        toggle.setAccessibilityLabel(spec.label)
        binders[spec.key] = { [weak toggle] value in
            toggle?.apply(on: value?.asBool ?? false, disabled: nil)
        }
        return toggle
    }

    private func choiceControl(_ spec: SettingSpec) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: spec.options ?? [])
        popup.selectItem(withTitle: effectiveValue(for: spec)?.asString ?? "")
        popup.target = popupTargets.hold(ControlTarget { [weak self, weak popup] in
            guard let title = popup?.titleOfSelectedItem else { return }
            self?.send(spec, .string(title))
        })
        popup.action = #selector(ControlTarget.fire)
        popup.setAccessibilityLabel(spec.label)
        binders[spec.key] = { [weak popup] value in
            if let title = value?.asString { popup?.selectItem(withTitle: title) }
        }
        return popup
    }

    private func textControl(_ spec: SettingSpec) -> NSView {
        let field = NSTextField(string: effectiveValue(for: spec)?.asString ?? "")
        field.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.s.pointSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        field.target = popupTargets.hold(ControlTarget { [weak self, weak field] in
            guard let field else { return }
            self?.send(spec, .string(field.stringValue))
        })
        field.action = #selector(ControlTarget.fire)
        // Enter fires the action on its own; tabbing or clicking away must
        // count as the same statement or half the edits never leave the field.
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        field.setAccessibilityLabel(spec.label)
        binders[spec.key] = { [weak field] value in
            guard let field else { return }
            // Never clobber a field mid-edit: the confirmation for the LAST
            // change arrives while the user types the next one.
            guard field.currentEditor() == nil else { return }
            field.stringValue = value?.asString ?? ""
        }
        return field
    }

    private func numberControl(_ spec: SettingSpec) -> NSView {
        // Bounded numbers are a slider; an unbounded number is a text field
        // with a formatter, because a slider with invented ends would be a
        // guess wearing hardware.
        guard let min = spec.min, let max = spec.max else {
            let field = NSTextField(string: numberText(effectiveValue(for: spec)?.asDouble))
            field.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.s.pointSize)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.target = popupTargets.hold(ControlTarget { [weak self, weak field] in
                guard let field, let value = Double(field.stringValue) else { return }
                self?.send(spec, .double(value))
            })
            field.action = #selector(ControlTarget.fire)
            field.setAccessibilityLabel(spec.label)
            binders[spec.key] = { [weak field] value in
                guard let field, field.currentEditor() == nil else { return }
                field.stringValue = numberText(value?.asDouble)
            }
            return field
        }

        let slider = NSSlider(value: effectiveValue(for: spec)?.asDouble ?? min, minValue: min, maxValue: max, target: nil, action: nil)
        slider.isContinuous = false // one envelope per release, not per pixel
        if let step = spec.step, step > 0 {
            slider.allowsTickMarkValuesOnly = true
            slider.numberOfTickMarks = Int(((max - min) / step).rounded()) + 1
        }
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let readout = NSTextField(labelWithString: numberText(effectiveValue(for: spec)?.asDouble))
        readout.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.xs.pointSize)
        readout.textColor = LedgeTheme.secondary
        slider.target = popupTargets.hold(ControlTarget { [weak self, weak slider, weak readout] in
            guard let slider else { return }
            readout?.stringValue = numberText(slider.doubleValue)
            self?.send(spec, .double(slider.doubleValue))
        })
        slider.action = #selector(ControlTarget.fire)
        slider.setAccessibilityLabel(spec.label)
        binders[spec.key] = { [weak slider, weak readout] value in
            guard let number = value?.asDouble else { return }
            slider?.doubleValue = number
            readout?.stringValue = numberText(number)
        }
        let pair = NSStackView(views: [slider, readout])
        pair.orientation = .horizontal
        pair.spacing = 8
        return pair
    }

    /// Targets for AppKit's target/action controls, retained for the page's
    /// life — a popup does not retain its target.
    private let popupTargets = TargetBag()
}

private func numberText(_ value: Double?) -> String {
    guard let value else { return "" }
    return value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
}

/// A closure with an `@objc` selector, for AppKit's target/action controls.
@MainActor
final class ControlTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() { handler() }
}

/// Keeps `ControlTarget`s alive: AppKit targets are unretained.
@MainActor
final class TargetBag {
    private var held: [ControlTarget] = []
    func hold(_ target: ControlTarget) -> ControlTarget {
        held.append(target)
        return target
    }

    /// Rebuilding a page's rows replaces its controls; their targets must not
    /// pile up for the page's life.
    func empty() { held.removeAll() }
}

// MARK: - Shared row shapes

/// The window's row vocabulary, in one place so four pages agree on it.
@MainActor
enum SettingsRows {
    static func header(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.l.pointSize, weight: .semibold)
        label.textColor = LedgeTheme.primary
        return label
    }

    /// Title + optional detail line on the left, one control on the right.
    static func labeled(title: String, detail: String?, trailing: NSView) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize, weight: .medium)
        name.textColor = LedgeTheme.primary

        let labels = NSStackView(views: [name])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let detail, !detail.isEmpty {
            let line = NSTextField(wrappingLabelWithString: detail)
            line.font = LedgeTheme.systemFont(LedgeMetrics.TypeSize.xs.pointSize)
            line.textColor = LedgeTheme.tertiary
            line.preferredMaxLayoutWidth = 300
            labels.addArrangedSubview(line)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [labels, spacer, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(
            equalToConstant: SettingsWindowController.contentWidth - SettingsWindowController.pad * 2
        ).isActive = true
        return row
    }

    /// The chord, drawn as the key it is.
    static func keycap(_ chord: String) -> NSView {
        let label = NSTextField(labelWithString: chord)
        label.font = NSFont.monospacedSystemFont(ofSize: LedgeMetrics.TypeSize.s.pointSize, weight: .medium)
        label.textColor = LedgeTheme.primary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        cap.layer?.cornerRadius = 5
        cap.layer?.borderWidth = 1
        cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            cap.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 16),
            cap.heightAnchor.constraint(equalToConstant: 24),
        ])
        return cap
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
