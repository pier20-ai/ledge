import AppKit
import Foundation
import LedgeShellCore
import Testing
@testable import LedgeShell

/// A probe that answers from a dictionary and touches nothing.
///
/// This is the mechanism behind the standing rule "never trigger a real TCC
/// prompt from a test": there is no path from this suite to `EKEventStore`,
/// `CLLocationManager`, `UNUserNotificationCenter` or `CGRequestScreenCaptureAccess`,
/// so a test cannot raise a dialog on the machine running it even by accident.
/// `asked` and `opened` record intent instead.
@MainActor
final class FakePermissionProbe: PermissionProbing {
    var statuses: [LedgePermission: PermissionStatus]
    /// What the next `ask` should resolve to, per permission.
    var answers: [LedgePermission: PermissionStatus] = [:]
    private(set) var asked: [LedgePermission] = []
    private(set) var opened: [LedgePermission] = []

    init(_ statuses: [LedgePermission: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    func status(of permission: LedgePermission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    func ask(_ permission: LedgePermission, then: @escaping @MainActor (PermissionStatus) -> Void) {
        asked.append(permission)
        let answer = answers[permission] ?? .granted
        statuses[permission] = answer
        then(answer)
    }

    func openSettings(for permission: LedgePermission) {
        opened.append(permission)
    }
}

/// First-run permission onboarding.
///
/// The properties worth defending are all honesty properties. This surface has
/// exactly one job macOS cannot do for us — say what is about to be asked and
/// why, before the bare dialog appears — and exactly one way to fail at it:
/// claim to know something it does not, or offer a button that cannot work.
@Suite("Permission onboarding")
@MainActor
struct PermissionsTests {
    // MARK: - Policy

    /// The whole table, because the interesting cases are the two that are not
    /// grants: a refusal cannot be re-asked (TCC never prompts twice), and an
    /// unreadable status must not offer to "Allow" something it cannot observe.
    @Test("Every status maps to the one action that can actually work")
    func actionPerStatus() {
        let cases: [(PermissionStatus, PermissionAction)] = [
            (.granted, .settled),
            (.notDetermined, .ask),
            (.denied, .openSettings),
            (.unreadable("because"), .openSettings),
            (.unavailable("because"), .settled),
        ]
        for (status, action) in cases {
            let row = PermissionRow(permission: .calendar, status: status)
            #expect(row.action == action, "\(status.badge) should offer \(String(describing: action))")
        }
    }

    /// Automation is the row that cannot answer its own question: there is no
    /// blanket grant to read, only a per-target one that would have to be
    /// prompted for. It must therefore never show an Allow button — pressing it
    /// would mean sending some app a stray Apple event to raise its dialog.
    @Test("Automation is never askable")
    func automationNeverAsks() {
        let probe = FakePermissionProbe()
        let rows = permissionRows(from: probe)
        let automation = try? #require(rows.first { $0.permission == .automation })
        #expect(automation?.action == .openSettings)
        #expect(automation?.status == .unreadable(LedgePermission.automation.unreadableReason ?? ""))
        // And the fake's answer is never consulted for it: the fact is macOS's,
        // not this build's.
        probe.statuses[.automation] = .granted
        #expect(permissionRows(from: probe).first?.action == .openSettings)
    }

    @Test("The list is every reachable permission, in display order")
    func listIsComplete() {
        #expect(Set(LedgePermission.ordered) == Set(LedgePermission.allCases))
        #expect(permissionRows(from: FakePermissionProbe()).map(\.permission) == LedgePermission.ordered)
    }

    /// A deep link is not a nicety here: once TCC has a refusal on file the API
    /// returns denied forever and asking again is a no-op, so the pane is the
    /// only remedy that exists. A URL that does not parse is a dead end.
    @Test("Every permission names a System Settings pane that parses")
    func settingsURLsParse() {
        for permission in LedgePermission.allCases {
            let url = URL(string: permission.settingsURL)
            #expect(url != nil, "\(permission.rawValue) has an unparseable settings URL")
            #expect(url?.scheme == "x-apple.systempreferences")
        }
    }

    /// The status's own note wins over the permission's standing explanation:
    /// "you refused this and macOS will not ask again" is more useful than
    /// "here is what it would have been for".
    @Test("A status with something to say replaces the standing explanation")
    func footnotePrefersStatus() {
        let denied = PermissionRow(permission: .screenRecording, status: .denied)
        #expect(denied.footnote == PermissionStatus.denied.note)
        let fresh = PermissionRow(permission: .screenRecording, status: .notDetermined)
        #expect(fresh.footnote == LedgePermission.screenRecording.detail)
        // Automation says it once: its standing explanation *is* why it cannot
        // be read, so `detail` is empty and the unreadable note carries it.
        let automation = PermissionRow(permission: .automation, status: .unreadable("why"))
        #expect(automation.footnote == "why")
        let quiet = PermissionRow(permission: .calendar, status: .granted)
        #expect(quiet.footnote == nil)
    }

    /// The three usage-description keys are load-bearing: calling the matching
    /// authorization API in a bundle that lacks one **terminates the process**,
    /// so `SystemPermissionProbe` refuses to offer a button for it. If a key
    /// name here drifts from the one `scripts/bundle-app.sh` writes, every
    /// affected row reports itself unavailable in the shipped app.
    @Test("Usage-description keys are declared for exactly the APIs that need one")
    func usageKeys() {
        #expect(LedgePermission.automation.usageDescriptionKey == "NSAppleEventsUsageDescription")
        #expect(LedgePermission.calendar.usageDescriptionKey == "NSCalendarsFullAccessUsageDescription")
        #expect(LedgePermission.location.usageDescriptionKey == "NSLocationWhenInUseUsageDescription")
        #expect(LedgePermission.notifications.usageDescriptionKey == nil)
        #expect(LedgePermission.screenRecording.usageDescriptionKey == nil)
    }

    // MARK: - The surface

    @Test("The card measures itself, and grows when a row gains a line")
    func cardMeasuresItself() {
        let quiet = FakePermissionProbe(
            Dictionary(uniqueKeysWithValues: LedgePermission.allCases.map { ($0, .granted) })
        )
        let quietCard = PermissionsCardView(probe: quiet)
        let noisy = FakePermissionProbe(
            Dictionary(uniqueKeysWithValues: LedgePermission.allCases.map { ($0, .denied) })
        )
        let noisyCard = PermissionsCardView(probe: noisy)

        #expect(quietCard.panelHeight > 0)
        // Every denied row carries the "macOS will not ask again" line, so the
        // noisy panel is exactly five footnote-heights taller.
        #expect(noisyCard.panelHeight > quietCard.panelHeight)
        // Still a panel: it has to fit under the notch on the smallest screen
        // `PanelLimits` will clamp to, cutout row included.
        // Still a panel. The worst case — all five refused, so every row carries
        // its "macOS will not ask again" line — has to fit under the notch on
        // the smallest Mac that has one: a 14" MacBook Pro caps the panel at
        // roughly 660 pt (`PanelLimits.detect`), cutout row included.
        #expect(noisyCard.panelHeight + NotchMetrics.fallback.closedHeight < 600)
        // And the case that actually happens on a fresh machine — two rows with
        // something to say — stays svelte.
        let fresh = PermissionsCardView(probe: FakePermissionProbe())
        #expect(fresh.panelHeight < 480)
    }

    @Test("Pressing a row's button does the one thing that row offers")
    func rowActions() {
        let probe = FakePermissionProbe([
            .calendar: .notDetermined,
            .location: .denied,
            .notifications: .granted,
        ])
        let card = PermissionsCardView(probe: probe)
        card.frame = CGRect(x: 0, y: 0, width: PermissionsCardView.width, height: card.panelHeight)
        card.layoutSubtreeIfNeeded()

        // The label is the promise; activating is the wiring. Both are asserted,
        // because a row that says "Allow…" and opens Settings is worse than
        // either mistake on its own.
        #expect(card.actionLabel(for: .calendar) == "Allow…")
        #expect(card.actionLabel(for: .location) == "Settings")
        // A granted row has no button at all — there is nothing left to do.
        #expect(card.actionLabel(for: .notifications) == nil)

        card.activate(.calendar)
        #expect(probe.asked == [.calendar])
        #expect(probe.opened.isEmpty)

        card.activate(.location)
        #expect(probe.asked == [.calendar])
        #expect(probe.opened == [.location])

        card.activate(.notifications)
        #expect(probe.asked == [.calendar])
        #expect(probe.opened == [.location])
    }

    /// Allowing something has to be visible immediately. The rows are rebuilt
    /// wholesale from a fresh read rather than patched, because one click can
    /// change the shape of the row it landed on.
    @Test("An answered prompt is reflected without reopening the surface")
    func answerReloads() {
        let probe = FakePermissionProbe([.calendar: .notDetermined])
        probe.answers[.calendar] = .granted
        let card = PermissionsCardView(probe: probe)
        card.activate(.calendar)
        #expect(card.visibleRows.first { $0.permission == .calendar }?.status == .granted)
        #expect(card.visibleRows.first { $0.permission == .calendar }?.action == .settled)
        #expect(card.actionLabel(for: .calendar) == nil)
    }

    /// A surface nobody is looking at must not poll TCC. It stays in the view
    /// hierarchy after the panel collapses, so the controller — not the window —
    /// is what turns it off.
    @Test("It only watches the system while it is on screen")
    func watchesOnlyWhenActive() {
        let card = PermissionsCardView(probe: FakePermissionProbe())
        #expect(!card.isWatching)
        card.setActive(true)
        #expect(card.isWatching)
        card.setActive(false)
        #expect(!card.isWatching)
    }

    @Test("Done dismisses, and dismissing is a legitimate answer")
    func dismiss() {
        let card = PermissionsCardView(probe: FakePermissionProbe())
        var dismissed = false
        card.onDismiss = { dismissed = true }
        card.dismiss()
        #expect(dismissed)
    }

    // MARK: - First run

    /// Shown once, ever — and marked on *presentation*, not on completion.
    /// A marker that only landed on "Done" would reopen the panel on every
    /// launch until the user pressed a button they were entitled to ignore.
    ///
    /// Runs entirely inside a temp root: `LedgeInstall.rootOverride` is what
    /// keeps this suite off the user's real `~/.ledge`.
    @Test("Onboarding marks itself seen once, under the install root")
    func onboardingMarker() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-onboarding-\(UUID().uuidString)")
        let previous = LedgeInstall.rootOverride
        LedgeInstall.rootOverride = root.path
        defer {
            LedgeInstall.rootOverride = previous
            try? FileManager.default.removeItem(at: root)
        }

        #expect(!LedgeInstall.hasOnboarded)
        LedgeInstall.markOnboarded()
        #expect(LedgeInstall.hasOnboarded)
        #expect(LedgeInstall.onboardedMarker.path.hasPrefix(root.path))
    }

    /// The surface is expanded chrome with no app behind it: it must light no
    /// icon in the strip, report no app to the host (a worker hearing
    /// "expanded" for a panel showing permissions would be a lie), and be a
    /// no-op for the ✦ toggle.
    @Test("Permissions is chrome, not an app")
    func presentationSemantics() {
        #expect(ShellPresentation.permissions.isExpanded)
        #expect(ShellPresentation.permissions.app == nil)
        #expect(ShellPresentation.permissions.reportedApp == nil)
        #expect(!ShellPresentation.permissions.isChat)

        var state = ShellState(presentation: .permissions)
        state.toggleChat()
        #expect(state.presentation == .permissions)
        // And it never becomes the app that hovering the pill reopens.
        state.toggleExpansion()
        #expect(state.presentation == .collapsed)
    }

    /// The way back in, once onboarding has been dismissed. The name is a wire
    /// value: Settings sends `chrome { request }` (spec §3.3) and the host has
    /// the string hardcoded on its side, so renaming it here silently breaks the
    /// only path to this surface.
    @Test("Settings reopens the surface through a named chrome request")
    func reopenRequestName() {
        #expect(NotchPanelController.permissionsChromeRequest == "permissions")
    }

    // MARK: - Rendering

    /// Rendered rather than reasoned about. `screencapture` returns the
    /// wallpaper without a Screen Recording grant (see `scripts/snapshot-editor.swift`),
    /// so the surface is drawn in-process into a bitmap and the pixels are read
    /// back — which is also the only way to catch a row that laid out at zero
    /// height or a label that drew in black on black.
    ///
    /// Set `LEDGE_SNAPSHOT_DIR` to keep the PNG and look at it.
    @Test("The card actually draws, in every state a row can be in")
    func rendersVisibly() throws {
        let probe = FakePermissionProbe([
            .notifications: .granted,
            .screenRecording: .notDetermined,
            .calendar: .denied,
            .location: .unavailable("Missing NSLocationWhenInUseUsageDescription — run Ledge.app."),
        ])
        let card = PermissionsCardView(probe: probe)
        let png = try render(card, named: "permissions.png")

        #expect(png.count > 2000, "a card that draws nothing compresses to almost nothing")
    }

    /// The same card in the real panel, because the card on its own cannot show
    /// the two things that go wrong at the seams: content starting *behind* the
    /// camera housing (every surface reserves the cutout row), and the 42 pt app
    /// strip drawing over the last row (spec §8 — apps render above it and can
    /// never cover it, and neither may shell chrome).
    @Test("It composes inside the panel: below the cutout, above the app strip")
    func composesInThePanel() throws {
        let card = PermissionsCardView(probe: FakePermissionProbe())
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.setCatalog([
            CatalogApp(id: "stocks", name: "Stocks", icon: "sf:chart.line.uptrend.xyaxis",
                       order: 0, enabled: true, running: true, panel: nil),
        ])
        // No app name and no Edit: there is no app behind this surface.
        surface.setPanelWing(name: nil, content: nil, canEdit: false)
        let height = card.panelHeight + surface.panelWingRowHeight
        surface.frame = CGRect(
            origin: .zero,
            size: surface.shapeSize(
                expanded: true,
                width: PermissionsCardView.width,
                height: height
            )
        )
        surface.present(
            .permissions,
            content: card,
            width: PermissionsCardView.width,
            height: height,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        surface.displayIfNeeded()

        let representation = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try Self.keep(png, named: "permissions-panel.png")
        #expect(png.count > 2000)
    }

    /// Draw one view into a bitmap and hand back the PNG, writing it out when
    /// `LEDGE_SNAPSHOT_DIR` says where.
    private func render(_ card: PermissionsCardView, named name: String) throws -> Data {
        let size = CGSize(width: PermissionsCardView.width, height: card.panelHeight)
        let host = FlippedView(frame: CGRect(origin: .zero, size: size))
        // Composited over the panel's own glass: the card is transparent by
        // design, and a snapshot on white would hide exactly the defect this is
        // most useful for — ink that is invisible against the real background.
        host.wantsLayer = true
        host.layer?.backgroundColor = LedgeTheme.glass.cgColor
        card.frame = host.bounds
        host.addSubview(card)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try Self.keep(png, named: name)
        return png
    }

    /// Write a rendered PNG out when `LEDGE_SNAPSHOT_DIR` asks for one.
    ///
    /// Creates the directory. Pointing the variable at a path that does not
    /// exist yet is the *normal* way to use it, and a test that fails because
    /// its own optional debug output could not be saved is a trap: the failure
    /// says nothing about the card, and the person who hit it was only trying
    /// to look at the thing.
    private static func keep(_ png: Data, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LEDGE_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try png.write(to: url.appendingPathComponent(name))
    }
}