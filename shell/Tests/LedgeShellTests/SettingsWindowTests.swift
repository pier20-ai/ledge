import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **Settings is a native window, and a deliberately boring one** (G4, and
/// then G4's own correction: "simplicity + familiarity + boring is the goal").
///
/// The window is plain SwiftUI — a `NavigationSplitView` and grouped `Form`s —
/// which moves everything assertable into `SettingsModel`: which panes exist,
/// what is selected, what the catalog says, and the envelopes a control sends.
/// SwiftUI's view tree is deliberately not inspected here; the model IS the
/// window's behavior, and the views are a rendering of it. What the suite pins
/// is the same law as ever: the catalog is the only truth, the switches drive
/// the same control plane the ledge's ✕ does, and the permission rows come
/// from the one shared probe.
@MainActor
@Suite("Settings — the native window")
struct SettingsWindowTests {
    private func makeController(
        on page: String? = nil
    ) throws -> (SettingsWindowController, HostSession, FakePermissionProbe) {
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
        if let page { controller.selectForTesting(page) }
        return (controller, session, probe)
    }

    /// A catalog whose first app declares one of every control kind, for the
    /// pane tests. Injected over the golden fixture the way the host would.
    private func declaringCatalog(_ session: HostSession) throws {
        var apps = session.installedApps
        guard var first = apps.first else { return }
        first.settings = [
            SettingSpec(key: "voice", label: "Voice", type: "toggle", defaultValue: .bool(true)),
            SettingSpec(key: "region", label: "Region", type: "choice", defaultValue: .string("Global"), options: ["Global", "Europe"]),
            SettingSpec(key: "model", label: "Model", type: "text", defaultValue: .string("gpt-5.6-luna")),
            SettingSpec(key: "depth", label: "Depth", type: "number", defaultValue: .int(24), min: 6, max: 36, step: 6),
            SettingSpec(key: "wat", label: "Future", type: "hologram"),
        ]
        first.values = [
            "voice": .bool(false), "region": .string("Europe"),
            "model": .string("gpt-5.6-luna"), "depth": .int(12), "wat": .null,
        ]
        apps[0] = first
        session.inject(Envelope(
            app: "", seq: 99, type: "catalog",
            payload: try JSONValue.fromEncodable(CatalogPayload(apps: apps))
        ))
    }

    // MARK: - It is a window, and an ordinary one

    @Test("A standard titled window — no glass, no silhouette, no panel")
    func itIsAPlainWindow() throws {
        let (controller, _, _) = try makeController()
        let window = try #require(controller.windowForTesting)

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.title == "Ledge Settings")

        // Emphatically not Ledge's own panel: the notch surface is a
        // borderless non-activating `NSPanel`, and this must not have picked
        // any of that up by being built next to it.
        #expect(!(window is NSPanel))
        #expect(!window.styleMask.contains(.nonactivatingPanel))
        #expect(window.standardWindowButton(.closeButton) != nil)
        #expect(!(window.contentView is ShellSurfaceView))

        // **Un-themed, deliberately** (the G4 correction): the window follows
        // the system's appearance — no forced dark aqua, no painted
        // background. Boring is the specification.
        #expect(window.appearance == nil)

        // Reopening brings the same window forward rather than stacking a
        // second one — the thing every settings window on the machine does.
        controller.loadForTesting()
        #expect(controller.windowForTesting === window)
    }

    // MARK: - Panes

    @Test("The standing panes, then one per app that declares settings")
    func panesFollowTheCatalog() throws {
        let (controller, session, _) = try makeController()
        // The golden catalog declares nothing: three panes, no app section.
        #expect(controller.pagesForTesting == ["general", "apps", "onboarding"])

        try declaringCatalog(session)
        controller.catalogChanged()
        let first = try #require(session.installedApps.first)
        #expect(controller.pagesForTesting == ["general", "apps", "onboarding", first.id])
        // …and only the declarer: an app with no `meta.settings` gets a row in
        // Apps, never a pane of its own.
        #expect(!controller.pagesForTesting.contains(session.installedApps[1].id))
    }

    @Test("Selection lands, survives reloads, and falls back when its app goes")
    func selectionIsManaged() throws {
        let (controller, session, _) = try makeController()
        try declaringCatalog(session)
        controller.catalogChanged()
        let first = try #require(session.installedApps.first)

        controller.selectForTesting(first.id)
        #expect(controller.selectedPageId == first.id)

        // A catalog that no longer carries the selected app's declaration
        // cannot leave the window on an empty pane. A FRESH snapshot, not the
        // fixture re-injected: the engine rightly drops a frame whose seq is
        // behind the declaring one above.
        let plain = session.installedApps.map { app in
            var stripped = app
            stripped.settings = nil
            stripped.values = nil
            return stripped
        }
        session.inject(Envelope(
            app: "", seq: 100, type: "catalog",
            payload: try JSONValue.fromEncodable(CatalogPayload(apps: plain))
        ))
        controller.catalogChanged()
        #expect(controller.selectedPageId == "general")
    }

    @Test("show(page:) lands on the asked-for pane")
    func showLandsOnThePage() throws {
        let (controller, _, _) = try makeController(on: "onboarding")
        #expect(controller.selectedPageId == "onboarding")
    }

    // MARK: - The control plane

    @Test("Throwing a switch sends appControl, and nothing moves until the catalog")
    func theSwitchDrivesTheControlPlane() throws {
        let (controller, session, _) = try makeController()
        var sent: [Envelope] = []
        session.onOutboundForTesting = { sent.append($0) }

        let model = controller.modelForTesting
        let app = try #require(model.apps.first)
        model.setEnabled(app.id, false)
        model.setEnabled(app.id, true)

        #expect(sent.count == 2)
        for envelope in sent {
            #expect(envelope.type == "appControl")
            #expect(envelope.app == "")
        }
        #expect(sent[0].payload.asObject?["action"]?.asString == "stop")
        #expect(sent[1].payload.asObject?["action"]?.asString == "start")
        #expect(sent[0].payload.asObject?["app"]?.asString == app.id)

        // The model did NOT move: the catalog is the only truth about
        // enabled, and none has arrived. (The view keeps its own transient
        // beat; the model must not.)
        #expect(model.apps.first?.enabled == app.enabled)
    }

    @Test("A turned setting is one appControl 'setting' envelope, typed")
    func aSettingIsOneEnvelope() throws {
        let (controller, session, _) = try makeController()
        try declaringCatalog(session)
        controller.catalogChanged()
        var sent: [Envelope] = []
        session.onOutboundForTesting = { sent.append($0) }

        let model = controller.modelForTesting
        let app = try #require(model.apps.first)
        model.setSetting(app.id, key: "voice", value: .bool(false))
        model.setSetting(app.id, key: "depth", value: .double(18))

        #expect(sent.count == 2)
        let first = try #require(sent.first?.payload.asObject)
        #expect(sent[0].type == "appControl")
        #expect(first["action"]?.asString == "setting")
        #expect(first["app"]?.asString == app.id)
        #expect(first["key"]?.asString == "voice")
        #expect(first["value"]?.asBool == false)
        let second = try #require(sent.last?.payload.asObject)
        #expect(second["key"]?.asString == "depth")
        #expect(second["value"]?.asDouble == 18)
    }

    @Test("The model hands a pane its app, spec and effective values")
    func paneDataIsTheCatalogs() throws {
        let (controller, session, _) = try makeController()
        try declaringCatalog(session)
        controller.catalogChanged()

        let model = controller.modelForTesting
        let first = try #require(session.installedApps.first)
        let app = try #require(model.app(for: .app(first.id)))
        let specs = try #require(app.settings)
        // The unknown-typed row travels (the model does not filter it; the
        // pane renders it as nothing — `SettingSpec.kind == nil`).
        #expect(specs.count == 5)
        #expect(specs.first { $0.key == "wat" }?.kind == nil)
        #expect(app.values?["depth"]?.asDouble == 12)
        #expect(app.values?["voice"]?.asBool == false)
    }

    // MARK: - Permissions

    @Test("The rows are the shared probe's, refreshed by ask")
    func permissionRowsAreTheProbes() throws {
        let (controller, _, probe) = try makeController(on: "onboarding")
        let model = controller.modelForTesting
        #expect(model.rows.map(\.permission) == LedgePermission.ordered)

        probe.statuses[.calendar] = .notDetermined
        model.refreshPermissions()
        #expect(model.rows.first { $0.permission == .calendar }?.action == .ask)

        // Asking re-reads: the fake grants, and the row must follow without
        // anyone remembering to poke it.
        model.ask(.calendar)
        #expect(probe.asked == [.calendar])
        #expect(model.rows.first { $0.permission == .calendar }?.status == .granted)
    }

    @Test("The TCC poll runs with the pane and stops with the window")
    func thePollFollowsThePane() throws {
        let (controller, _, _) = try makeController(on: "onboarding")
        let model = controller.modelForTesting
        // `onAppear` is SwiftUI's to fire and a headless test cannot wait on
        // it; the model's own start/stop pair is the contract the pane calls.
        model.startPermissionPoll()
        #expect(model.isPollingPermissionsForTesting)
        model.startPermissionPoll() // idempotent, not stacking timers
        #expect(model.isPollingPermissionsForTesting)

        // Closing the window is the hard stop: a poll that outlives its
        // window reads TCC forever for nobody.
        controller.windowForTesting?.delegate?.windowWillClose?(
            Notification(name: NSWindow.willCloseNotification)
        )
        #expect(!model.isPollingPermissionsForTesting)
    }
}

extension JSONValue {
    /// Fixture helper: a Codable payload as an envelope payload.
    static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
