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
    /// System Screen Recording preflight is intentionally unable to reflect the
    /// transitional answer until relaunch.
    var reflectsAnswers = true
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
        if reflectsAnswers { statuses[permission] = answer }
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

    /// The five usage-description keys are load-bearing: calling the matching
    /// authorization API in a bundle that lacks one **terminates the process**,
    /// so `SystemPermissionProbe` refuses to offer a button for it. If a key
    /// name here drifts from the one `scripts/bundle-app.sh` writes, every
    /// affected row reports itself unavailable in the shipped app.
    @Test("Usage-description keys are declared for exactly the APIs that need one")
    func usageKeys() {
        #expect(LedgePermission.automation.usageDescriptionKey == "NSAppleEventsUsageDescription")
        #expect(LedgePermission.calendar.usageDescriptionKey == "NSCalendarsFullAccessUsageDescription")
        #expect(LedgePermission.location.usageDescriptionKey == "NSLocationWhenInUseUsageDescription")
        // G3: `ctx.record`'s two sources are two separate TCC services, and both
        // kill the process if their key is missing — the mic on the first
        // `AVCaptureDevice` request, the tap on the first `AudioHardwareCreate…`.
        #expect(LedgePermission.microphone.usageDescriptionKey == "NSMicrophoneUsageDescription")
        #expect(LedgePermission.systemAudio.usageDescriptionKey == "NSAudioCaptureUsageDescription")
        #expect(LedgePermission.notifications.usageDescriptionKey == nil)
        #expect(LedgePermission.screenRecording.usageDescriptionKey == nil)
    }

    /// The list itself, pinned by length and order. `listIsComplete` proves the
    /// ordered list and the case list are the same *set*; this is the shape the
    /// card is measured against below, and the reason a row added without a
    /// second thought shows up as two failing tests rather than one.
    @Test("Seven rows, in the order the card draws them")
    func orderedRows() {
        #expect(LedgePermission.ordered.count == 7)
        #expect(LedgePermission.ordered == [
            .automation, .notifications, .screenRecording, .microphone, .systemAudio,
            .calendar, .location,
        ])
        // The record pair sits next to Screen Recording rather than beside the
        // other two data grants: what those three have in common is that an app
        // is capturing the machine, which is the comparison a user is making
        // when they read down the card.
    }

    /// System Audio is the second row that cannot answer its own question, and
    /// for a different reason from Automation's: TCC's audio-capture service has
    /// no public preflight at all — creating the tap *is* the ask. So the row
    /// says so instead of showing "Not asked" as though it knew.
    @Test("System Audio is unreadable by design; the microphone is not")
    func systemAudioIsUnreadable() {
        let rows = permissionRows(from: FakePermissionProbe([.microphone: .granted]))
        let system = rows.first { $0.permission == .systemAudio }
        #expect(system?.status == .unreadable(LedgePermission.systemAudio.unreadableReason ?? ""))
        #expect(system?.action == .openSettings, "there is nothing to ask, only a pane to open")
        // The microphone has an ordinary preflight, so the probe's answer stands.
        #expect(rows.first { $0.permission == .microphone }?.status == .granted)
        #expect(LedgePermission.microphone.unreadableReason == nil)
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
        // noisy panel is exactly one footnote-height per row taller.
        #expect(noisyCard.panelHeight > quietCard.panelHeight)

        // **Seven rows outgrew every screen, and the card now clamps.**
        //
        // Until G3 the card was five rows and its natural height stayed under
        // every cap on its own. `ctx.record` added Microphone and System Audio
        // — and System Audio's second line is permanent (unreadable by
        // design), so the natural card is 711 pt fresh and 809 pt worst-case,
        // against a ~661 pt ceiling on the smallest notched Mac. The fix is
        // `maxPanelHeight`: the controller hands the card the screen's
        // allowance, `panelHeight` clamps to it, and the rows scroll behind
        // the glass while Done stays on it. Three facts pinned here: the
        // scroller is genuinely earning its place, the clamp holds at both
        // historic caps, and the natural height keeps its growth ratchet.
        let fresh = PermissionsCardView(probe: FakePermissionProbe())
        #expect(
            fresh.measuredHeight > PanelLimits.fallback.maxHeight,
            "the natural card fits every screen again — the scroller could go back to being a plain view"
        )
        fresh.maxPanelHeight = 560
        #expect(fresh.panelHeight == 560)
        noisyCard.maxPanelHeight = 660 - NotchMetrics.fallback.closedHeight
        #expect(noisyCard.panelHeight + NotchMetrics.fallback.closedHeight <= 660)
        // The growth ratchet, kept from the interregnum: the NATURAL height
        // may not quietly grow another row's worth either — a taller card is
        // more scrolling on every machine, and a new permission row should
        // come with this number consciously re-cut.
        #expect(fresh.measuredHeight <= 711)
        #expect(
            noisyCard.measuredHeight + NotchMetrics.fallback.closedHeight <= 809
        )
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

    @Test("Permission copy is laid out below its action, never under it")
    func rowCopyClearsActions() throws {
        let card = PermissionsCardView(probe: FakePermissionProbe())
        card.frame = CGRect(x: 0, y: 0, width: PermissionsCardView.width, height: card.panelHeight)
        card.layoutSubtreeIfNeeded()

        let button = try #require(
            descendants(of: card)
                .compactMap { $0 as? LedgeButton }
                .first { $0.currentLabel == "Settings" }
        )
        let summary = try #require(
            descendants(of: card)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == LedgePermission.automation.summary }
        )
        let buttonFrame = card.convert(button.bounds, from: button)
        let summaryFrame = card.convert(summary.bounds, from: summary)
        #expect(!buttonFrame.intersects(summaryFrame))
        #expect(summaryFrame.minY >= buttonFrame.maxY)
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

    @Test("An answer survives an ambiguous system re-read")
    func ambiguousReadKeepsAnswer() {
        let probe = FakePermissionProbe([.screenRecording: .notDetermined])
        probe.answers[.screenRecording] = .unreadable("Takes effect when Ledge restarts.")
        probe.reflectsAnswers = false
        let card = PermissionsCardView(probe: probe)

        card.activate(.screenRecording)

        let row = card.visibleRows.first { $0.permission == .screenRecording }
        #expect(row?.status == .unreadable("Takes effect when Ledge restarts."))
        #expect(row?.action == .openSettings)
        #expect(card.actionLabel(for: .screenRecording) == "Settings")
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

    /// **First run is a window now** (G4). Onboarding used to be a seventh
    /// presentation — expanded chrome with no app behind it, on the panel — and
    /// the notch had to grow a card taller than it wanted to be. It is a
    /// Settings page instead, so the assertion that matters is the negative
    /// one: the one time Ledge opens itself, it opens a *window* and leaves the
    /// notch exactly where it found it.
    @Test("First run opens the Settings window on Onboarding, and never the panel")
    func firstRunOpensTheWindow() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        controller.present(.collapsed, animated: false)

        controller.presentPermissions()

        let settings = try #require(
            controller.settingsWindowForTesting,
            "first run did not build the Settings window"
        )
        #expect(settings.windowForTesting != nil)
        #expect(settings.selectedPageId == OnboardingSettingsPage.id)

        // The notch is untouched: no expansion, no visit, nothing to walk away
        // from. This is what the old presentation could not promise.
        #expect(controller.presentation == .collapsed)
        #expect(!controller.presentation.isExpanded)
        #expect(controller.interactionState == .resting)
    }

    /// The refusal, in a constant. An app asking for the permission surface via
    /// `chrome { request }` (spec §3.3) is refused — from every app, always —
    /// and the name is kept written down because the refusal is the interesting
    /// part. Settings was the one holder of an exception; it is a window that
    /// asks the shell directly now, so the exception has no holder left.
    @Test("The permission chrome request keeps its name, and its refusal")
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

    /// The same card **in its new home** (G4). It used to be composed into the
    /// panel, below the camera cutout; onboarding is a Settings page now, so
    /// the seam that can go wrong has moved with it: the card is drawn in the
    /// shell's white-on-black inks, and a settings window that was not dark
    /// would render every row invisible. That is exactly the defect a bitmap
    /// catches and a layout assertion never would.
    @Test("It composes inside the Settings window, on the window's own ground")
    func composesInTheSettingsWindow() throws {
        let page = OnboardingSettingsPage(probe: FakePermissionProbe(), onDone: {})
        let card = try #require(page.cardForTesting)
        let body = page.pageView

        let size = CGSize(
            width: SettingsWindowController.contentWidth,
            height: card.panelHeight + SettingsWindowController.pad * 2
        )
        let host = FlippedView(frame: CGRect(origin: .zero, size: size))
        host.wantsLayer = true
        // The window's real background, not white: this is the assertion.
        host.layer?.backgroundColor = SettingsWindowController.windowBackground.cgColor
        body.frame = host.bounds.insetBy(dx: SettingsWindowController.pad, dy: SettingsWindowController.pad)
        host.addSubview(body)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try Self.keep(png, named: "permissions-settings-page.png")
        #expect(png.count > 2000, "rows that drew in black on black compress to almost nothing")
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
