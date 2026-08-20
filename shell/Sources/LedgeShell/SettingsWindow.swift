import AppKit
import LedgeShellCore
import ServiceManagement
import SwiftUI

/// **Settings is a window, and a deliberately boring one** (G4, Manu's ruling:
/// "simplicity + familiarity + boring is the goal — avoid theming the settings
/// UI at all"). The first cut of the sidebar window hand-rolled its rows,
/// headers and backgrounds; this one is plain SwiftUI — `NavigationSplitView`
/// for the sidebar, grouped `Form`s for every pane, the system's own colors in
/// the system's own appearance. If a control here looks custom, that is a bug.
///
/// The panes:
///
///   · **General** — the hotkey, launch at login, Quit (which lives here
///     because `LSUIElement` means no Dock icon or menu-bar item holds it).
///   · **Apps** — every installed app with its switch, driving the same
///     `appControl` envelope the ledge's ✕ sends.
///   · **Onboarding** — the permission rows over the shared probe. This pane
///     IS first-run: a fresh install opens the window here, once, ever.
///   · **One pane per app that declares `meta.settings`** — native controls,
///     confirmed through the catalog rather than trusted optimistically.
///
/// All decisions live in `SettingsModel`; the views only render it. That split
/// is what the tests hold on to — SwiftUI internals are not assertable, the
/// model and the envelopes it sends are.
@MainActor
final class SettingsWindowController {
    private let model: SettingsModel

    private var window: NSWindow?

    init(session: HostSession, probe: PermissionProbing, onQuit: @escaping () -> Void) {
        model = SettingsModel(session: session, probe: probe, onQuit: onQuit)
    }

    // MARK: - Opening

    /// Show it, and **activate**: Ledge is an accessory app whose panel never
    /// takes focus, but a settings window is a place you go. `page` lands on a
    /// specific pane (first run opens Onboarding); nil keeps the last one.
    func show(page: String? = nil) {
        let window = existingOrNewWindow()
        model.refreshCatalog()
        if let page, let target = SettingsPane(id: page) { model.selection = target }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The catalog moved. Cheap when the window has never been built, and
    /// never *builds* it — a catalog envelope must not summon a window.
    func catalogChanged() {
        guard window != nil else { return }
        model.refreshCatalog()
    }

    // MARK: - Window

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ledge Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(CGSize(width: 720, height: 520))
        window.isReleasedWhenClosed = false
        // No appearance override and no background color, deliberately: the
        // window follows the system, light or dark, like every other settings
        // window on the machine.
        window.center()
        window.setFrameAutosaveName("LedgeSettings")
        window.delegate = windowDelegate
        self.window = window
        model.refreshCatalog()
        return window
    }

    /// The TCC poll must not outlive the window (a pane's `onDisappear` is
    /// not guaranteed to fire for a window that merely closes).
    private lazy var windowDelegate = SettingsWindowDelegate { [weak self] in
        self?.model.stopPermissionPoll()
    }

    // MARK: - Test seams

    var windowForTesting: NSWindow? { window }
    var modelForTesting: SettingsModel { model }
    var selectedPageId: String { model.selection.id }
    var pagesForTesting: [String] { model.panes.map(\.id) }
    func selectForTesting(_ id: String) {
        if let pane = SettingsPane(id: id) { model.selection = pane }
    }
    /// Build the window without showing it — assertions need it to exist,
    /// none of them needs to steal the user's focus.
    func loadForTesting() {
        _ = existingOrNewWindow()
        model.refreshCatalog()
    }
}

// MARK: - Panes

/// One sidebar entry. `app` panes exist per app that declares `meta.settings`.
enum SettingsPane: Hashable, Identifiable {
    case general
    case apps
    case onboarding
    case app(String)

    var id: String {
        switch self {
        case .general: "general"
        case .apps: "apps"
        case .onboarding: "onboarding"
        case let .app(appId): appId
        }
    }

    init?(id: String) {
        switch id {
        case "general": self = .general
        case "apps": self = .apps
        case "onboarding": self = .onboarding
        case "": return nil
        default: self = .app(id)
        }
    }
}

/// The Onboarding pane's stable id, for the first-run call site.
enum OnboardingSettingsPage {
    static let id = "onboarding"
}

// MARK: - The model

/// Everything the window *decides*, kept out of the views so it can be
/// asserted: which panes exist, what is selected, what the catalog says, and
/// the envelope-sending actions. Views render this and nothing else.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var apps: [CatalogApp] = []
    @Published var selection: SettingsPane = .general
    @Published var rows: [PermissionRow] = []

    private let session: HostSession
    private let probe: PermissionProbing
    let onQuit: () -> Void
    private var permissionPoll: Timer?
    /// An ask can know more than a subsequent preflight read. Screen Recording
    /// is the concrete case: macOS says "not determined" both before asking
    /// and after a grant that needs a relaunch. The answer is held until a
    /// later read reaches a settled state, instead of snapping the row back
    /// to "Allow…". (Ported verbatim from the retired PermissionsCardView.)
    private var answered: [LedgePermission: PermissionStatus] = [:]

    init(session: HostSession, probe: PermissionProbing, onQuit: @escaping () -> Void) {
        self.session = session
        self.probe = probe
        self.onQuit = onQuit
        refreshPermissions()
    }

    /// The sidebar, in order: the standing three, then the declarers.
    var panes: [SettingsPane] {
        [.general, .apps, .onboarding]
            + apps.filter { !($0.settings ?? []).isEmpty }.map { .app($0.id) }
    }

    func app(for pane: SettingsPane) -> CatalogApp? {
        guard case let .app(id) = pane else { return nil }
        return apps.first { $0.id == id }
    }

    func refreshCatalog() {
        apps = session.installedApps
        // The selected pane can vanish — the app was disabled mid-look, or a
        // reload stopped declaring settings — and the window must land
        // somewhere rather than on an empty pane. Membership in `panes` is
        // the whole test: a pane only exists for a declarer.
        if case .app = selection, !panes.contains(selection) {
            selection = .general
        }
    }

    // MARK: Actions (the envelopes)

    /// Deliberately NOT optimistic in the model: the catalog is the only truth
    /// (spec §3.6) and the host re-sends it as the change's last step. The
    /// views keep their own transient state for the beat in between.
    func setEnabled(_ app: String, _ enabled: Bool) {
        session.setAppEnabled(app, enabled: enabled)
    }

    func setSetting(_ app: String, key: String, value: JSONValue) {
        session.setAppSetting(app, key: key, value: value)
    }

    // MARK: Permissions

    func refreshPermissions() {
        rows = permissionRows(from: probe).map { observed in
            guard let held = answered[observed.permission] else { return observed }
            // A settled system read supersedes our transitional answer; an
            // ambiguous `notDetermined` does not.
            guard observed.status == .notDetermined else {
                answered.removeValue(forKey: observed.permission)
                return observed
            }
            return PermissionRow(permission: observed.permission, status: held)
        }
    }

    func ask(_ permission: LedgePermission) {
        probe.ask(permission) { [weak self] status in
            self?.answered[permission] = status
            self?.refreshPermissions()
        }
    }

    func openSystemSettings(for permission: LedgePermission) {
        probe.openSettings(for: permission)
    }

    /// Re-read while the Onboarding pane is up: the whole point of its
    /// Settings deep links is that the user leaves, changes something behind
    /// our back, and comes back — a row still reading DENIED then would teach
    /// them the link does not work.
    func startPermissionPoll() {
        guard permissionPoll == nil else { return }
        SystemPermissionProbe.refreshNotificationStatus { [weak self] in self?.refreshPermissions() }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                SystemPermissionProbe.refreshNotificationStatus { self?.refreshPermissions() }
                self?.refreshPermissions()
            }
        }
    }

    func stopPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    var isPollingPermissionsForTesting: Bool { permissionPoll != nil }
}

// MARK: - Root

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("General", systemImage: "gearshape").tag(SettingsPane.general)
                Label("Apps", systemImage: "square.grid.2x2").tag(SettingsPane.apps)
                Label("Onboarding", systemImage: "checklist").tag(SettingsPane.onboarding)
                let declaring = model.panes.compactMap { model.app(for: $0) }
                if !declaring.isEmpty {
                    Section("Apps") {
                        ForEach(declaring, id: \.id) { app in
                            Label(app.name, systemImage: app.symbolName)
                                .tag(SettingsPane.app(app.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail.navigationTitle(title)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .general: GeneralPane(model: model)
        case .apps: AppsPane(model: model)
        case .onboarding: OnboardingPane(model: model)
        case .app:
            if let app = model.app(for: model.selection) {
                AppSettingsPane(model: model, app: app)
            }
        }
    }

    private var title: String {
        switch model.selection {
        case .general: "General"
        case .apps: "Apps"
        case .onboarding: "Onboarding"
        case .app: model.app(for: model.selection)?.name ?? ""
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// `SMAppService` needs a real bundle: registering a bare executable is an
    /// error, and the row says so instead of offering a switch that throws.
    private var canManageLogin: Bool { Bundle.main.bundleIdentifier != nil }

    var body: some View {
        Form {
            Section {
                LabeledContent("Open Ledge") {
                    Text("⌃⌥Space").monospaced()
                }
                if canManageLogin {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                if on {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                NSLog("[ledge] launch at login: %@", String(describing: error))
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                } else {
                    LabeledContent("Launch at login") {
                        Text("Only the bundled Ledge.app can register.")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("⌃⌥Space opens the notch from anywhere — no hover — and lands on a live recording when there is one.")
            }
            Section {
                Button("Quit Ledge", role: .destructive) { model.onQuit() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

struct AppsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                if model.apps.isEmpty {
                    Text("No apps installed yet.").foregroundStyle(.secondary)
                }
                ForEach(model.apps, id: \.id) { app in
                    AppRow(model: model, app: app)
                }
            } footer: {
                Text("Off tears the app's worker down; the app stays installed. The ledge's ✕ is this same switch.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppRow: View {
    @ObservedObject var model: SettingsModel
    let app: CatalogApp
    /// The switch's own beat between the click and the catalog confirming.
    @State private var wanted: Bool?

    var body: some View {
        Toggle(isOn: binding) {
            // A fixed icon column, because SF Symbols have ragged natural
            // widths and ragged label edges were the first thing the eye
            // caught on device (G4, Manu's screenshot).
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: app.symbolName)
                    .frame(width: 20, alignment: .center)
            }
        }
        .onChange(of: app.enabled) { _, _ in wanted = nil } // the catalog confirmed
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { wanted ?? app.enabled },
            set: { on in
                wanted = on
                model.setEnabled(app.id, on)
            }
        )
    }

    /// An enabled app whose worker is not up is a crash, and hiding that
    /// behind a green switch would make Settings lie about its one job.
    private var status: String {
        switch (app.enabled, app.running) {
        case (false, _): "Off"
        case (true, true): "Running"
        case (true, false): "Starting…"
        }
    }
}

// MARK: - Onboarding

struct OnboardingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.rows, id: \.permission) { row in
                    OnboardingRow(model: model, row: row)
                }
            } header: {
                Text("Apps reach macOS through Ledge, so the system asks Ledge — usually the moment an app first needs something. Settle any of these now, or later.")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.bottom, 6)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.startPermissionPoll() }
        .onDisappear { model.stopPermissionPoll() }
    }
}

private struct OnboardingRow: View {
    @ObservedObject var model: SettingsModel
    let row: PermissionRow

    var body: some View {
        LabeledContent {
            control
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.permission.title)
                    Text(row.permission.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let footnote = row.footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                Image(systemName: row.permission.symbol)
                    .frame(width: 20, alignment: .center)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch row.action {
        case .ask:
            Button("Allow…") { model.ask(row.permission) }
        case .openSettings:
            Button("Settings") { model.openSystemSettings(for: row.permission) }
        case .settled:
            Text(row.status.plain)
                .foregroundStyle(row.status.tone == .good ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
    }
}

// MARK: - One app's settings

/// The native rendering of one app's `meta.settings`: Toggle, Picker,
/// TextField, Slider — the platform's own controls, nothing skinned. Values
/// confirm through the catalog; each row keeps only the transient beat
/// between a change and its confirmation (and a text field mid-edit is never
/// clobbered by one).
struct AppSettingsPane: View {
    @ObservedObject var model: SettingsModel
    let app: CatalogApp

    var body: some View {
        Form {
            Section {
                ForEach(app.settings ?? [], id: \.key) { spec in
                    row(for: spec)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func confirmed(_ spec: SettingSpec) -> JSONValue? {
        app.values?[spec.key] ?? spec.defaultValue
    }

    private func send(_ spec: SettingSpec, _ value: JSONValue) {
        model.setSetting(app.id, key: spec.key, value: value)
    }

    @ViewBuilder private func row(for spec: SettingSpec) -> some View {
        // An unknown `type` renders as nothing rather than a guess — the
        // vocabulary can grow without lockstep shell upgrades.
        switch spec.kind {
        case .toggle:
            ToggleRow(spec: spec, confirmed: confirmed(spec)?.asBool ?? false) { send(spec, .bool($0)) }
        case .choice:
            ChoiceRow(
                spec: spec,
                confirmed: confirmed(spec)?.asString ?? spec.options?.first ?? ""
            ) { send(spec, .string($0)) }
        case .text:
            TextRow(spec: spec, confirmed: confirmed(spec)?.asString ?? "") { send(spec, .string($0)) }
        case .number:
            NumberRow(spec: spec, confirmed: confirmed(spec)?.asDouble ?? spec.min ?? 0) { send(spec, .double($0)) }
        case nil:
            EmptyView()
        }
    }
}

/// Label + optional hint on the left, one control on the right — the shape
/// every settings row in the product shares.
private struct Hinted<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        LabeledContent {
            content()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ToggleRow: View {
    let spec: SettingSpec
    let confirmed: Bool
    let send: (Bool) -> Void
    @State private var wanted: Bool?

    var body: some View {
        Hinted(title: spec.label, hint: spec.hint) {
            Toggle("", isOn: Binding(
                get: { wanted ?? confirmed },
                set: { on in
                    wanted = on
                    send(on)
                }
            ))
            .labelsHidden()
            // A bare Toggle in a LabeledContent falls back to a checkbox; the
            // Apps pane's rows are switches, and one window uses one control.
            .toggleStyle(.switch)
        }
        .onChange(of: confirmed) { _, _ in wanted = nil }
    }
}

private struct ChoiceRow: View {
    let spec: SettingSpec
    let confirmed: String
    let send: (String) -> Void
    @State private var wanted: String?

    var body: some View {
        Hinted(title: spec.label, hint: spec.hint) {
            Picker("", selection: Binding(
                get: { wanted ?? confirmed },
                set: { choice in
                    wanted = choice
                    send(choice)
                }
            )) {
                ForEach(spec.options ?? [], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: confirmed) { _, _ in wanted = nil }
    }
}

private struct TextRow: View {
    let spec: SettingSpec
    let confirmed: String
    let send: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Hinted(title: spec.label, hint: spec.hint) {
            TextField("", text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { send(draft) }
        }
        .onAppear { draft = confirmed }
        // Focus loss is a statement too, or half the edits never leave.
        .onChange(of: focused) { _, now in
            if !now, draft != confirmed { send(draft) }
        }
        // Never clobber a field mid-edit: the confirmation for the LAST
        // change arrives while the user types the next one.
        .onChange(of: confirmed) { _, fresh in
            if !focused { draft = fresh }
        }
    }
}

private struct NumberRow: View {
    let spec: SettingSpec
    let confirmed: Double
    let send: (Double) -> Void
    @State private var draft = 0.0
    @State private var editing = false

    var body: some View {
        Hinted(title: spec.label, hint: spec.hint) {
            if let min = spec.min, let max = spec.max, min < max {
                HStack(spacing: 8) {
                    slider(min: min, max: max)
                        .frame(width: 160)
                    Text(numberText(draft))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)
                }
            } else {
                // An unbounded number gets a field: a slider with invented
                // ends would be a guess wearing hardware.
                TextField("", value: $draft, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { send(draft) }
            }
        }
        .onAppear { draft = confirmed }
        .onChange(of: confirmed) { _, fresh in
            if !editing { draft = fresh }
        }
    }

    @ViewBuilder private func slider(min: Double, max: Double) -> some View {
        let bound = Binding(get: { draft }, set: { draft = $0 })
        // One envelope per release, not per pixel.
        if let step = spec.step, step > 0 {
            Slider(value: bound, in: min...max, step: step) { moving in
                editing = moving
                if !moving { send(draft) }
            }
        } else {
            Slider(value: bound, in: min...max) { moving in
                editing = moving
                if !moving { send(draft) }
            }
        }
    }
}

private func numberText(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
}

// MARK: - AppKit odds and ends

/// A closure with an `@objc` selector, for AppKit's target/action controls
/// (the wing bar's overflow menu uses it; menu items do not retain targets).
@MainActor
final class ControlTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() { handler() }
}

/// `NSWindowDelegate` as a small object rather than making the controller
/// one: the controller has no other business with AppKit's delegate protocol.
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
