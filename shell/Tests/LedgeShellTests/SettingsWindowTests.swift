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
///
/// Since G4 it is a window with a **sidebar of pages**: General, Apps,
/// Onboarding, and one page per app that declares `meta.settings`. Everything
/// below the page divide is the same law as the enable switch — the catalog is
/// the only truth, and no control moves until the host says so.
@MainActor
@Suite("Settings — the native window")
struct SettingsWindowTests {
    /// A loaded window over the golden catalog. `page` is where to land,
    /// because a page is built when you first arrive on it: the window opens on
    /// General, and the Apps rows do not exist until Apps is the page on
    /// screen. Every test that inspects a page therefore has to go there, which
    /// is also what the user does.
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
        #expect(!(window.contentView is ShellSurfaceView))

        // Reopening brings the same window forward rather than stacking a
        // second one — the thing every settings window on the machine does.
        controller.loadForTesting()
        #expect(controller.windowForTesting === window)
    }

    /// **The shape of a settings window on this platform** (G4). It was one
    /// scroll view of stacked rows, which is what a settings window looks like
    /// for about three rows; a sidebar of pages is what it looks like after
    /// that, and it is what System Settings and every serious app's preferences
    /// have converged on.
    ///
    /// So the content view is no longer *the* scroll view — it is a split: the
    /// system's sidebar material on the left, running the window's full height
    /// under a transparent titlebar, and one scrolling page on the right.
    @Test("Sidebar on the left, one page on the right — the platform's shape")
    func itIsASidebarAndPages() throws {
        let (controller, _, _) = try makeController()
        let window = try #require(controller.windowForTesting)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()

        #expect(!(root is NSScrollView), "the window is a split now, not one scroll")

        // The sidebar runs to the top edge, which is what `.fullSizeContentView`
        // plus a transparent titlebar buys — without both, the material stops
        // under the traffic lights and the seam shows.
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)

        let sidebar = try #require(
            root.subviews.compactMap { $0 as? NSVisualEffectView }.first,
            "no sidebar material"
        )
        #expect(sidebar.material == .sidebar)
        #expect(sidebar.frame.width == SettingsWindowController.sidebarWidth)
        #expect(sidebar.frame.minX == 0)

        // …and the page beside it, which is the half that scrolls.
        let content = try #require(
            root.subviews.compactMap { $0 as? NSScrollView }.first,
            "no content scroll"
        )
        #expect(content.frame.minX == SettingsWindowController.sidebarWidth)
        #expect(content.documentView != nil)

        // Dark, on purpose: `PermissionsCardView` draws in the shell's
        // white-on-black inks and a light window would hide every row of it.
        #expect(window.appearance?.name == .darkAqua)
    }

    // MARK: - The apps, and their switches

    @Test("Every installed app gets a row, enabled or not")
    func listsEveryInstalledApp() throws {
        let (controller, session, _) = try makeController(on: AppsSettingsPage.id)

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
        controller.selectForTesting(AppsSettingsPage.id)

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
        let (controller, session, _) = try makeController(on: AppsSettingsPage.id)
        let first = try #require(controller.listedAppsForTesting.first)
        #expect(first.enabled)

        // Nothing has come back from the host yet.
        controller.catalogChanged()
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
        controller.catalogChanged()
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
    ///
    /// With the sidebar, "on screen" got narrower: it is *this page selected*,
    /// not merely this window open. Sitting on General with the window up must
    /// not poll anything.
    @Test("The TCC poll runs while Onboarding is the page, and stops with the window")
    func theProbeStopsWithTheWindow() throws {
        let (controller, _, _) = try makeController()
        let card = try #require(controller.permissionsForTesting)
        let window = try #require(controller.windowForTesting)

        #expect(!card.isWatching, "polling from General, which has no rows to poll for")

        controller.selectForTesting(OnboardingSettingsPage.id)
        #expect(card.isWatching)

        // Closing is what the user actually does; the delegate is the thing
        // under test, so drive the notification rather than the flag.
        window.delegate?.windowWillClose?(
            Notification(name: NSWindow.willCloseNotification, object: window)
        )
        #expect(!card.isWatching)
    }

    /// The other way off the page: walking away in the sidebar. A poll that
    /// only stopped on close would keep running for a page the user left five
    /// minutes ago, which is the same defect in a smaller window.
    @Test("Leaving the page stops the poll; coming back starts it again")
    func theProbeFollowsTheSelectedPage() throws {
        let (controller, _, _) = try makeController()
        let card = try #require(controller.permissionsForTesting)

        controller.selectForTesting(OnboardingSettingsPage.id)
        #expect(card.isWatching)

        controller.selectForTesting(AppsSettingsPage.id)
        #expect(!card.isWatching, "still asking macOS about the microphone from the Apps page")

        controller.selectForTesting(OnboardingSettingsPage.id)
        #expect(card.isWatching)
    }

    // MARK: - The sidebar, and its pages

    /// The window's shape as a list: the three standing pages in a fixed order,
    /// then one page per app that declared `meta.settings`, in catalog order.
    ///
    /// Catalog order and not alphabetical, and not "the ones that are running":
    /// the sidebar is the same list as the ledge, so the page you are looking
    /// for is where the app is.
    @Test("Three standing pages, then one per app that declares settings, in catalog order")
    func pagesAreTheStandingThreePlusDeclarers() throws {
        let (controller, _, _) = try makeSettingsController()

        #expect(controller.pagesForTesting == [
            GeneralSettingsPage.id,
            AppsSettingsPage.id,
            OnboardingSettingsPage.id,
            "radio",
            "scribe",
        ])
    }

    /// **Declaring is what earns a page.** An app with no `meta.settings` has
    /// nothing to put on one, and a sidebar row leading to an empty pane is a
    /// promise the app never made. (The Apps page still lists it — that row is
    /// about the *app*, not about its settings.)
    @Test("An app that declares nothing gets no page at all")
    func silentAppsGetNoPage() throws {
        let (controller, _, _) = try makeSettingsController()

        #expect(!controller.pagesForTesting.contains("chess"))
        #expect(controller.appPageForTesting("chess") == nil)
        // …and it is still one of the app rows.
        controller.selectForTesting(AppsSettingsPage.id)
        #expect(controller.listedAppsForTesting.map(\.id).contains("chess"))
    }

    @Test("Selecting a page swaps the pane and says so")
    func selectingSwapsTheContent() throws {
        let (controller, _, _) = try makeSettingsController()
        #expect(controller.selectedPageId == GeneralSettingsPage.id)

        controller.selectForTesting("radio")
        #expect(controller.selectedPageId == "radio")
        let radio = try #require(controller.appPageForTesting("radio"))
        #expect(try shownPage(of: controller) === radio.pageView)

        controller.selectForTesting(AppsSettingsPage.id)
        #expect(controller.selectedPageId == AppsSettingsPage.id)
        #expect(try shownPage(of: controller) !== radio.pageView)

        // A page that is not there is not a landing: asking for one leaves the
        // window where it was rather than emptying the pane.
        controller.selectForTesting("chess")
        #expect(controller.selectedPageId == AppsSettingsPage.id)
    }

    /// The app you were configuring got disabled — from the ledge's ✕, or from
    /// the switch two pages over — and its page went with it. The window has to
    /// land somewhere, and General is the somewhere; a sidebar with nothing
    /// selected and an empty pane is the state this avoids.
    @Test("A selected app that vanishes from the catalog lands the window on General")
    func aVanishedAppLandsOnGeneral() throws {
        let (controller, session, _) = try makeSettingsController()
        controller.selectForTesting("radio")
        #expect(controller.selectedPageId == "radio")

        session.inject(Envelope(
            app: "",
            seq: 42,
            type: "catalog",
            payload: try Self.catalogPayload(Self.settingsCatalog.filter { $0.id != "radio" })
        ))
        controller.catalogChanged()

        #expect(controller.selectedPageId == GeneralSettingsPage.id)
        #expect(!controller.pagesForTesting.contains("radio"))
    }

    // MARK: - One app's declared controls (G4, `meta.settings`)

    /// One control per declared row, and the control the *type* asks for: a
    /// switch, a pop-up, a field, a slider. Native, because these are ordinary
    /// settings and macOS already knows what a setting looks like.
    @Test("Each declared type renders its own native control")
    func eachTypeRendersItsControl() throws {
        let (controller, _, _) = try makeSettingsController()
        let page = try #require(controller.appPageForTesting("radio"))

        #expect(controls(of: page).count == 4)
        #expect(control(LedgeToggle.self, labelled: "Report listens", in: page) != nil)
        #expect(control(NSPopUpButton.self, labelled: "Recording format", in: page) != nil)
        #expect(control(NSSlider.self, labelled: "Stations on the dial", in: page) != nil)
        #expect(control(NSTextField.self, labelled: "Model", in: page) != nil)

        // The pop-up offers exactly what was declared, in order.
        let popup = try #require(control(NSPopUpButton.self, labelled: "Recording format", in: page))
        #expect(popup.itemTitles == ["aac", "wav"])
        // The declared default is what it starts on, with nothing stored.
        #expect(popup.titleOfSelectedItem == "aac")
    }

    /// **A vocabulary from the future is skipped whole.** A newer host may
    /// sanitize a type this build has never heard of; the honest rendering of
    /// "I don't know what this is" is nothing at all — never a blank field, and
    /// never a control that sends a value the app cannot mean.
    @Test("A type this build does not know is skipped, and its neighbours are not")
    func anUnknownTypeIsSkippedWhole() throws {
        let (controller, _, _) = try makeSettingsController()
        let page = try #require(controller.appPageForTesting("scribe"))

        // scribe declares three: a text, a `colour-picker` from the future, and
        // a toggle. Two controls come out, and they are the two it knows.
        #expect(controls(of: page).count == 2)
        #expect(control(NSTextField.self, labelled: "Transcript name", in: page) != nil)
        #expect(control(LedgeToggle.self, labelled: "Keep the audio", in: page) != nil)
        // Not "rendered as something else" — not rendered at all.
        #expect(control(NSView.self, labelled: "Highlight", in: page) == nil)
    }

    /// The turned control's envelope: the same control-plane frame as the ✕ and
    /// the enable switch, with the `setting` verb, the declared key, and a value
    /// of the declared type.
    @Test("Throwing a declared switch sends appControl setting, keyed and typed")
    func aTurnedControlSendsTheEnvelope() throws {
        let (controller, session, _) = try makeSettingsController()
        let page = try #require(controller.appPageForTesting("radio"))
        let toggle = try #require(control(LedgeToggle.self, labelled: "Report listens", in: page))

        var sent: [Envelope] = []
        session.onOutboundForTesting = { sent.append($0) }
        toggle.flipForTesting()

        #expect(sent.count == 1)
        let envelope = try #require(sent.first)
        #expect(envelope.type == "appControl")
        #expect(envelope.app == "", "a setting is control plane, not app traffic")
        #expect(try action(of: envelope) == "setting")
        #expect(try target(of: envelope) == "radio")
        #expect(try field("key", of: envelope) == "clicks")
        // Typed as declared — a toggle sends a bool, not the string "false".
        guard case .object(let payload) = envelope.payload else {
            Issue.record("the setting frame carried no object payload")
            return
        }
        #expect(payload["value"] == .bool(false))
    }

    /// **No optimism here either.** The control does not move because it was
    /// clicked; it moves because the host validated, persisted, delivered, and
    /// answered with a full catalog (spec §4/§3.6). This is that round trip,
    /// with the click's own envelope thrown away — which is exactly what a
    /// *rejected* value looks like from where the window sits.
    @Test("Every control re-binds from the catalog the host sends back")
    func valuesFollowTheCatalog() throws {
        let (controller, session, _) = try makeSettingsController()
        let page = try #require(controller.appPageForTesting("radio"))

        let toggle = try #require(control(LedgeToggle.self, labelled: "Report listens", in: page))
        let popup = try #require(control(NSPopUpButton.self, labelled: "Recording format", in: page))
        let slider = try #require(control(NSSlider.self, labelled: "Stations on the dial", in: page))
        let model = try #require(control(NSTextField.self, labelled: "Model", in: page))

        // Where the declared defaults put them.
        #expect(toggle.isOn)
        #expect(slider.doubleValue == 24)
        #expect(model.stringValue == "gpt-5.6-luna")

        var apps = Self.settingsCatalog
        apps[0].values = [
            "clicks": .bool(false),
            "dial-size": .double(12),
            "format": .string("wav"),
            "model": .string("gpt-5.6-nova"),
        ]
        session.inject(Envelope(
            app: "", seq: 43, type: "catalog", payload: try Self.catalogPayload(apps)
        ))
        controller.catalogChanged()

        #expect(!toggle.isOn)
        #expect(slider.doubleValue == 12)
        #expect(popup.titleOfSelectedItem == "wav")
        #expect(model.stringValue == "gpt-5.6-nova")

        // The *same* controls moved — a rebuild on every catalog would throw
        // away the field the user is typing in, which is the one thing this
        // page must never do (a confirmation for the last change arrives while
        // they are making the next one).
        let sliderNow = try #require(control(NSSlider.self, labelled: "Stations on the dial", in: page))
        let modelNow = try #require(control(NSTextField.self, labelled: "Model", in: page))
        #expect(sliderNow === slider)
        #expect(modelNow === model)
    }

    /// A value the catalog has for a key the app no longer declares must not
    /// resurrect a control, and a declared key the catalog has no value for
    /// falls back to the declared default rather than to empty.
    @Test("The spec decides which controls exist; values only decide where they stand")
    func specDecidesTheControls() throws {
        let (controller, session, _) = try makeSettingsController()

        var apps = Self.settingsCatalog
        // Radio drops `clicks` and keeps the rest; the stored value for the
        // dropped key rides along, as a stale file entry would.
        apps[0].settings = apps[0].settings?.filter { $0.key != "clicks" }
        apps[0].values = ["clicks": .bool(true), "format": .string("wav")]
        session.inject(Envelope(
            app: "", seq: 44, type: "catalog", payload: try Self.catalogPayload(apps)
        ))
        controller.catalogChanged()

        let page = try #require(controller.appPageForTesting("radio"))
        #expect(controls(of: page).count == 3)
        #expect(control(LedgeToggle.self, labelled: "Report listens", in: page) == nil)
        // No stored value for the dial: the declared default, not zero.
        let slider = try #require(control(NSSlider.self, labelled: "Stations on the dial", in: page))
        #expect(slider.doubleValue == 24)
    }

    // MARK: - Fixtures for the declared-settings pages

    /// A catalog with all four control types on one app, a silent app, and an
    /// app carrying a type from the future. Built in Swift rather than read
    /// from a golden file: these are the shell's rendering rules, and the wire
    /// shape has its own pins in the Core suite.
    private static let settingsCatalog: [CatalogApp] = [
        CatalogApp(
            id: "radio", name: "Radio", icon: "sf:radio", order: 0, enabled: true, running: true,
            settings: [
                SettingSpec(
                    key: "dial-size", label: "Stations on the dial", type: "number",
                    defaultValue: .double(24), min: 6, max: 36, step: 6
                ),
                SettingSpec(
                    key: "clicks", label: "Report listens", type: "toggle",
                    defaultValue: .bool(true),
                    hint: "Radio Browser counts a tune-in when this is on."
                ),
                SettingSpec(
                    key: "format", label: "Recording format", type: "choice",
                    defaultValue: .string("aac"), options: ["aac", "wav"]
                ),
                SettingSpec(
                    key: "model", label: "Model", type: "text",
                    defaultValue: .string("gpt-5.6-luna")
                ),
            ]
        ),
        CatalogApp(id: "chess", name: "Chess", icon: "sf:crown", order: 1, enabled: true, running: true),
        CatalogApp(
            id: "scribe", name: "Scribe", icon: "sf:mic", order: 2, enabled: true, running: true,
            settings: [
                SettingSpec(key: "name", label: "Transcript name", type: "text", defaultValue: .string("note")),
                SettingSpec(key: "highlight", label: "Highlight", type: "colour-picker"),
                SettingSpec(key: "keep", label: "Keep the audio", type: "toggle", defaultValue: .bool(false)),
            ]
        ),
    ]

    private func makeSettingsController() throws
        -> (SettingsWindowController, HostSession, FakePermissionProbe) {
        let session = HostSession()
        session.openReplay()
        session.inject(Envelope(
            app: "", seq: 1, type: "catalog",
            payload: try Self.catalogPayload(Self.settingsCatalog)
        ))
        let probe = FakePermissionProbe()
        let controller = SettingsWindowController(session: session, probe: probe, onQuit: {})
        controller.loadForTesting()
        return (controller, session, probe)
    }

    /// The view currently in the content half of the window.
    private func shownPage(of controller: SettingsWindowController) throws -> NSView {
        let root = try #require(controller.windowForTesting?.contentView)
        let scroll = try #require(root.subviews.compactMap { $0 as? NSScrollView }.first)
        return try #require(scroll.documentView?.subviews.first)
    }

    /// The controls a page built, one per rendered row. Each row is
    /// `[labels, spacer, control]`; the header is a bare label and is not one.
    private func controls(of page: AppSettingsPage) -> [NSView] {
        guard let column = page.pageView as? NSStackView else { return [] }
        return column.arrangedSubviews.compactMap { row in
            (row as? NSStackView)?.arrangedSubviews.last
        }
    }

    /// One control by the accessibility label the page gives it — which is the
    /// declared `label`, so this is also how a screen reader finds it.
    ///
    /// Searched from the *trailing* half of each row only: the left half is the
    /// same label as static text, and a lookup that could land on it would keep
    /// answering after the control it names had stopped being built.
    private func control<T: NSView>(
        _ type: T.Type,
        labelled label: String,
        in page: AppSettingsPage
    ) -> T? {
        func search(_ view: NSView) -> T? {
            if let match = view as? T, match.accessibilityLabel() == label { return match }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        for trailing in controls(of: page) {
            if let found = search(trailing) { return found }
        }
        return nil
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
