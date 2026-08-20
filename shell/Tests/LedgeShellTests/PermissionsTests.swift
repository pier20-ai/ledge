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

    // MARK: - The surface (the model behind the Onboarding pane)

    /// The card this section used to exercise is gone — the Onboarding pane
    /// is plain SwiftUI over `SettingsModel` (G4's boring-settings ruling) —
    /// but the two behaviors worth keeping were never about the card:

    /// An answered prompt is reflected without reopening the surface: the
    /// ask's callback re-derives the rows, and the row that was ASK is now
    /// settled — nobody has to remember to poke it.
    @Test("An answered prompt is reflected without reopening the surface")
    func answerReloads() {
        let probe = FakePermissionProbe([.calendar: .notDetermined])
        probe.answers[.calendar] = .granted
        let session = HostSession()
        session.openReplay()
        let model = SettingsModel(session: session, probe: probe, onQuit: {})
        model.ask(.calendar)
        #expect(model.rows.first { $0.permission == .calendar }?.status == .granted)
        #expect(model.rows.first { $0.permission == .calendar }?.action == .settled)
    }

    /// Screen Recording's shape: the ask learns "takes effect on relaunch"
    /// while every later preflight read still answers `notDetermined`. The
    /// answer is held over the ambiguous read — a settled read supersedes it —
    /// so the row does not snap back to an Allow… button that already worked.
    @Test("An answer survives an ambiguous system re-read")
    func ambiguousReadKeepsAnswer() {
        let probe = FakePermissionProbe([.screenRecording: .notDetermined])
        probe.answers[.screenRecording] = .unreadable("Takes effect when Ledge restarts.")
        probe.reflectsAnswers = false
        let session = HostSession()
        session.openReplay()
        let model = SettingsModel(session: session, probe: probe, onQuit: {})

        model.ask(.screenRecording)

        let row = model.rows.first { $0.permission == .screenRecording }
        #expect(row?.status == .unreadable("Takes effect when Ledge restarts."))
        #expect(row?.action == .openSettings)

        // …and a poll's refresh does not wash it away either.
        model.refreshPermissions()
        #expect(
            model.rows.first { $0.permission == .screenRecording }?.status
                == .unreadable("Takes effect when Ledge restarts.")
        )
    }

    /// A denied row's one remedy is the System Settings pane; the model must
    /// route there and never try to re-ask what TCC will not re-answer.
    @Test("A denied row opens the pane instead of asking again")
    func deniedOpensThePane() {
        let probe = FakePermissionProbe([.location: .denied])
        let session = HostSession()
        session.openReplay()
        let model = SettingsModel(session: session, probe: probe, onQuit: {})
        model.openSystemSettings(for: .location)
        #expect(probe.opened == [.location])
        #expect(probe.asked.isEmpty)
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
