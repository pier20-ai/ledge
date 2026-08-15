import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **Settings is a native window** (flow.md, Edges: "Settings — a native macOS
/// window; configuration doesn't belong on glass").
///
/// It was an app in the strip — a privileged session reaching the control plane
/// through `ctx.platform.enable/disable`. The trigger was always final and the
/// destination never was; this is the destination. What the suite pins down is
/// that it is genuinely a *window* (plain chrome, no glass, no silhouette), that
/// its switches drive the same control plane the ledge's ✕ does, and that the
/// permission rows are the shell's own view rather than a second implementation
/// that could disagree with the first.
@MainActor
@Suite("Settings — the native window")
struct SettingsWindowTests {
    private func makeController() throws -> (SettingsWindowController, HostSession, FakePermissionProbe) {
        let session = HostSession()
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        let probe = FakePermissionProbe()
        let controller = SettingsWindowController(
            session: session,
            probe: probe,
            onQuit: {}
        )
        controller.loadForTesting()
        return (controller, session, probe)
    }

    // MARK: - It is a window, and an ordinary one

    @Test("A standard titled window — no glass, no silhouette, no panel")
    func itIsAPlainWindow() throws {
        let (controller, _, _) = try makeController()
        let window = try #require(controller.windowForTesting)

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.title == "Ledge Settings")

        // Emphatically not Ledge's own panel: the notch surface is a borderless,
        // non-activating `NSPanel` and this must not have picked up any of that
        // by being built next to it.
        #expect(!(window is NSPanel))
        #expect(!window.styleMask.contains(.nonactivatingPanel))
        // `.borderless` is rawValue 0, so `contains` is true of every mask and
        // asserting it would assert nothing. `.titled` is the real opposite of
        // borderless, and the window server agrees: a titled window has a
        // title-bar view and a borderless one does not.
        #expect(window.standardWindowButton(.closeButton) != nil)
        // A window with normal chrome is opaque and has a title bar; the glass
        // body belongs to the notch.
        #expect(window.contentView is NSScrollView)
        #expect(!(window.contentView is ShellSurfaceView))

        // Reopening brings the same window forward rather than stacking a
        // second one — the thing every settings window on the machine does.
        controller.loadForTesting()
        #expect(controller.windowForTesting === window)
    }

    // MARK: - The apps, and their switches

    @Test("Every installed app gets a row, enabled or not")
    func listsEveryInstalledApp() throws {
        let (controller, session, _) = try makeController()

        // Not `strip`, which filters to the enabled: a switch you can only find
        // while the thing is already on is not a switch.
        #expect(controller.listedAppsForTesting.count == session.installedApps.count)
        #expect(controller.togglesForTesting.count == session.installedApps.count)
        #expect(!controller.listedAppsForTesting.isEmpty)

        // Each switch reports its app's state.
        for (app, toggle) in zip(controller.listedAppsForTesting, controller.togglesForTesting) {
            #expect(toggle.isOn == app.enabled)
        }
    }

    @Test("A disabled app is still listed, with its switch off")
    func disabledAppsAreStillListed() throws {
        let session = HostSession()
        session.openReplay()
        session.inject(Envelope(
            app: "",
            seq: 1,
            type: "catalog",
            payload: try Self.catalogPayload([
                CatalogApp(id: "on", name: "On", icon: "sf:circle", order: 0, enabled: true, running: true),
                CatalogApp(id: "off", name: "Off", icon: "sf:circle", order: 1, enabled: false, running: false),
            ])
        ))
        let controller = SettingsWindowController(
            session: session,
            probe: FakePermissionProbe(),
            onQuit: {}
        )
        controller.loadForTesting()

        // The strip drops the disabled one; Settings must not.
        #expect(session.strip.apps == ["on"])
        #expect(controller.listedAppsForTesting.map(\.id) == ["on", "off"])
        #expect(controller.togglesForTesting.map(\.isOn) == [true, false])
    }

    // MARK: - The control plane

    /// The switch sends the *same* envelope the ledge's ✕ sends, with the other
    /// action. One path by which an app becomes enabled or disabled means the
    /// strip and Settings can never disagree about what "off" means.
    @Test("Throwing a switch sends appControl, and nothing else does the job")
    func theSwitchDrivesTheControlPlane() throws {
        let session = HostSession()
        session.openReplay()
        var sent: [Envelope] = []
        session.onOutboundForTesting = { sent.append($0) }

        session.setAppEnabled("chess", enabled: false)
        session.setAppEnabled("chess", enabled: true)

        #expect(sent.count == 2)
        for envelope in sent {
            #expect(envelope.type == "appControl")
            // The control plane is addressed to the shell, not to an app: the
            // target is in the payload.
            #expect(envelope.app == "")
        }
        #expect(try action(of: sent[0]) == "stop")
        #expect(try action(of: sent[1]) == "start")
        #expect(try target(of: sent[0]) == "chess")
    }

    /// The ✕ on the ledge and the switch in Settings are literally the same
    /// call. This is the assertion that keeps them that way.
    @Test("The ledge's ✕ is this same envelope")
    func stopIsTheSameEnvelope() throws {
        let session = HostSession()
        session.openReplay()
        var viaStop: Envelope?
        session.onOutboundForTesting = { viaStop = $0 }
        session.stopApp("chess")

        var viaSwitch: Envelope?
        session.onOutboundForTesting = { viaSwitch = $0 }
        session.setAppEnabled("chess", enabled: false)

        let stop = try #require(viaStop)
        let toggled = try #require(viaSwitch)
        #expect(stop.type == toggled.type)
        #expect(try action(of: stop) == (try action(of: toggled)))
        #expect(try target(of: stop) == (try target(of: toggled)))
    }

    /// **No optimistic update.** The catalog is the only truth about what is
    /// enabled (spec §3.6) and the host re-sends it as the last step of
    /// `setAppEnabled`, so the row moves when the change has actually happened.
    /// A switch that snaps and then silently disagrees with the strip is the
    /// failure this window exists to prevent.
    @Test("The row follows the catalog, not the click")
    func theRowFollowsTheCatalog() throws {
        let (controller, session, _) = try makeController()
        let first = try #require(controller.listedAppsForTesting.first)
        #expect(first.enabled)

        // Nothing has come back from the host yet.
        controller.reload()
        #expect(controller.togglesForTesting.first?.isOn == true)

        // The host confirms the change by re-sending the catalog.
        var apps = session.installedApps
        apps[0].enabled = false
        session.inject(Envelope(
            app: "",
            seq: 99,
            type: "catalog",
            payload: try Self.catalogPayload(apps)
        ))
        controller.reload()
        #expect(controller.togglesForTesting.first?.isOn == false)
    }

    // MARK: - The permissions

    /// Rehosted, not reimplemented: it is `PermissionsCardView`, the same view
    /// the first-run card shows. Two answers to "does Ledge have Accessibility"
    /// is one answer too many.
    @Test("The permission rows are the shell's own view, sharing one probe")
    func permissionsAreRehosted() throws {
        let (controller, _, probe) = try makeController()
        let card = try #require(controller.permissionsForTesting)
        #expect(!card.visibleRows.isEmpty)
        // It reads the probe it was given, rather than reaching for the system
        // behind the caller's back.
        #expect(card.visibleRows.count == permissionRows(from: probe).count)
    }

    /// The card polls TCC while it is on screen, because the user leaves,
    /// changes something in System Settings, and comes back. That poll is
    /// owner-driven so it cannot outlive the surface — a window that has been
    /// closed must not still be asking macOS about the microphone every 1.5 s.
    @Test("The TCC poll starts with the window and stops with it")
    func theProbeStopsWithTheWindow() throws {
        let (controller, _, _) = try makeController()
        let card = try #require(controller.permissionsForTesting)
        let window = try #require(controller.windowForTesting)

        #expect(!card.isWatching, "polling before the window was ever shown")

        card.setActive(true)
        #expect(card.isWatching)

        // Closing is what the user actually does; the delegate is the thing
        // under test, so drive the notification rather than the flag.
        window.delegate?.windowWillClose?(
            Notification(name: NSWindow.willCloseNotification, object: window)
        )
        #expect(!card.isWatching)
    }

    // MARK: - Payload helpers

    /// A `catalog` payload as `JSONValue`, the way the host would send it.
    private static func catalogPayload(_ apps: [CatalogApp]) throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(CatalogPayload(apps: apps))
        )
    }

    private func field(_ key: String, of envelope: Envelope) throws -> String {
        guard case .object(let payload) = envelope.payload else {
            Issue.record("the control-plane frame carried no object payload")
            return ""
        }
        return try #require(payload[key]?.asString)
    }

    private func action(of envelope: Envelope) throws -> String {
        try field("action", of: envelope)
    }

    private func target(of envelope: Envelope) throws -> String {
        try field("app", of: envelope)
    }
}
