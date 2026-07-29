import AppKit
import LedgeShellCore
import QuartzCore

/// Physical notch dimensions for the screen the shell sits on. On notched
/// MacBooks the black bar must cover the hardware cutout exactly; elsewhere it
/// hangs below the menu bar like a Dynamic-Island-style pill.
struct NotchMetrics: Equatable {
    var closedWidth: CGFloat
    var closedHeight: CGFloat

    /// Mockup dimensions; used for snapshots and screens we can't measure.
    static let fallback = NotchMetrics(closedWidth: 210, closedHeight: 34)

    @MainActor
    static func detect(for screen: NSScreen) -> NotchMetrics {
        if
            screen.safeAreaInsets.top > 0,
            let topLeft = screen.auxiliaryTopLeftArea,
            let topRight = screen.auxiliaryTopRightArea
        {
            // +4 so the shape overlaps the cutout's antialiased edges.
            return NotchMetrics(
                closedWidth: screen.frame.width - topLeft.width - topRight.width + 4,
                closedHeight: screen.safeAreaInsets.top
            )
        }
        let menubarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchMetrics(
            closedWidth: fallback.closedWidth,
            closedHeight: max(32, min(38, menubarHeight))
        )
    }
}

/// What the screen will let a panel be (spec §5 "Layout & sizing", extended by
/// the app-declared `meta.panel`). 440 pt stays the default width — an app that
/// declares nothing gets exactly what it got before — but an app *may* ask for
/// another width, and asking is all it does: the shell owns the screen, so every
/// request lands here and is clamped.
///
/// This lives next to `NotchMetrics` because it is the same kind of fact: a
/// measurement of the display the notch is on, not a preference.
struct PanelLimits: Equatable {
    /// The width an app gets when it declares no `meta.panel.width` (spec §5).
    static let defaultWidth: CGFloat = 440
    /// Narrowest panel worth drawing: below this the 42 pt strip stops fitting
    /// its icons, and every two-column row in the vocabulary collapses.
    static let minWidth: CGFloat = 320
    /// Ceiling regardless of screen: past this a notch panel stops reading as a
    /// notch panel and starts reading as a window.
    static let hardMaxWidth: CGFloat = 640
    /// Shortest panel worth clamping to (a card still has to fit the strip).
    static let minHeight: CGFloat = 120
    /// Slack around the biggest shape for the panel's drop shadow.
    static let shadowMargin: CGFloat = 28
    /// The widest a single wing may grow (spec §8: wings up to ~340 × 34 for a
    /// 210 pt notch — 65 a side — with headroom for a longer label).
    static let maxWingWidth: CGFloat = 160

    var maxWidth: CGFloat
    var maxHeight: CGFloat

    /// Limits for snapshots and screens we can't measure. maxHeight matches a
    /// 16" MacBook's real cap (≈707) rather than the spec's illustrative 480,
    /// so snapshots show the proportions a live screen actually gets.
    static let fallback = PanelLimits(maxWidth: hardMaxWidth, maxHeight: 700)

    @MainActor
    static func detect(for screen: NSScreen) -> PanelLimits {
        let visible = screen.visibleFrame
        // Never within 80 pt of either screen edge, so a wide panel still reads
        // as hanging from the notch rather than spanning the display.
        let width = min(hardMaxWidth, max(defaultWidth, floor(screen.frame.width - 160)))
        // Spec §5 named 480 pt as the shell-computed default; the real cap is a
        // fraction of the screen, so a 16" display gets a much taller panel than
        // a 13" one and neither can push a panel past the dock.
        let height = max(240, floor(min(visible.height * 0.70, visible.height - 40)))
        return PanelLimits(maxWidth: width, maxHeight: height)
    }

    /// Clamp an app's requested panel width; `nil` (no declaration) is 440.
    func width(requesting requested: Double?) -> CGFloat {
        guard let requested, requested.isFinite else { return Self.defaultWidth }
        return min(max(CGFloat(requested), Self.minWidth), maxWidth)
    }

    /// Clamp an app's requested max panel height; `nil` is the screen cap.
    func height(requesting requested: Double?) -> CGFloat {
        guard let requested, requested.isFinite else { return maxHeight }
        return min(max(CGFloat(requested), Self.minHeight), maxHeight)
    }

    /// The fixed window that has to contain every shape the surface can morph
    /// into: the widest allowed panel, or the widest winged pill if that is
    /// wider, plus fillets and shadow slack. The window frame never animates
    /// (see `ShellSurfaceView`) — it only has to be big enough for all of it.
    @MainActor
    func windowSize(for metrics: NotchMetrics) -> CGSize {
        let widestShape = max(maxWidth, metrics.closedWidth + Self.maxWingWidth * 2)
        return CGSize(
            width: widestShape + ShellSurfaceView.fillet * 2 + Self.shadowMargin * 2,
            height: maxHeight + Self.shadowMargin
        )
    }
}

/// Tunables for the hover open/close feel: a short dwell to open (sharp but
/// still ignoring drive-bys), a longer debounce before closing so briefly
/// overshooting the panel edge doesn't cost you the panel.
struct HoverPolicy {
    var openOnHover = true
    var openDelay: TimeInterval = 0.20
    var closeDelay: TimeInterval = 0.60
    /// After the panel morphs (app switch, height change), the shape moves
    /// under a stationary cursor — often leaving it "outside" through no fault
    /// of the user. Exits within this window never schedule a close; the state
    /// is re-evaluated once the grace lapses.
    var morphGrace: TimeInterval = 0.90
    /// Extra hover slop around the collapsed notch, per edge.
    var closedSlopX: CGFloat = 8
    var closedSlopBottom: CGFloat = 6
    /// Forgiveness margin around the open panel before a close is scheduled.
    var openSlop: CGFloat = 26
}

private struct Spring {
    var response: CGFloat
    var damping: CGFloat

    static let open = Spring(response: 0.42, damping: 0.80)
    static let close = Spring(response: 0.45, damping: 1.0)
    static let morph = Spring(response: 0.40, damping: 0.85)
    static let bump = Spring(response: 0.30, damping: 0.75)
}

/// The 42 pt strip every expanded panel reserves (spec §8). Built from the
/// host's `catalog` snapshot and nothing else: installed apps at left in
/// catalog order, then **[+]**, then Settings at the far right.
///
/// The app icons **scroll**. Ten demo apps already overrun a 440 pt panel, and
/// the two controls that must never be unreachable are exactly the two an
/// overflowing row pushes off the end first: **[+]** (how you make app eleven)
/// and Settings (how you turn app ten off). So the row is
/// `[scrolling icons][+][safe gap][Settings]`, and the scroll area only ever
/// takes the width it needs — below the overflow point the layout is
/// point-for-point what it was before the scroller existed.
final class AppBarView: FlippedView {
    /// The Settings app is pinned to the far right rather than shown among the
    /// installed apps (spec §8). It is still an ordinary app to the protocol —
    /// only the strip treats it specially.
    static let settingsAppID = "settings"
    private static let newAppKey = "\u{0}new"

    private var buttons: [String: HoverIconButton] = [:]
    private var appButtons: [HoverIconButton] = []
    private let separator = HairlineView()
    private let settingsDivider = HairlineView()
    private let scrollView = NSScrollView()
    private let iconRow = FlippedView()
    private let callbacks: ShellCallbacks

    init(callbacks: ShellCallbacks) {
        self.callbacks = callbacks
        super.init(frame: .zero)

        // Transparent and scroller-less until it has to be anything else: when
        // the icons fit, this view is indistinguishable from the plain row it
        // replaced, which is the whole compatibility requirement.
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .allowed
        // A 40 pt-tall row has nowhere to go vertically; rubber-banding it would
        // only ever look like a bug.
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = iconRow

        // Tracking areas inside a scroll view go stale the moment the content
        // slides under a stationary cursor — the same staleness law L5 was
        // written for, one container deeper. Re-verify every icon against the
        // live pointer whenever the clip view moves.
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Selector-based rather than block-based on purpose: NotificationCenter
        // keeps a zeroing weak reference to the observer object, so the strip
        // does not have to unregister from a `deinit` that (being nonisolated)
        // cannot touch main-actor state anyway.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iconAreaDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        addSubview(scrollView)
        addSubview(separator)
        addSubview(settingsDivider)
        setApps([])
    }

    @objc private func iconAreaDidScroll() {
        syncIconHover()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rebuild from a full catalog snapshot (spec §3.6 — full snapshots, no
    /// diffs). Disabled apps are dropped; `order` decides the sequence; the
    /// wire icon is an SF Symbol name behind an `sf:` prefix (spec §5/§3.6).
    func setApps(_ apps: [CatalogApp]) {
        for button in buttons.values { button.removeFromSuperview() }
        buttons.removeAll()
        appButtons.removeAll()

        var x = LedgeMetrics.stripLeadingPad
        for app in apps.filter({ $0.enabled && $0.id != Self.settingsAppID }).sorted(by: { $0.order < $1.order }) {
            let button = addButton(
                key: app.id,
                symbol: Self.symbol(from: app.icon),
                title: app.name,
                into: iconRow
            ) { [weak self] in self?.callbacks.selectApp(app.id) }
            button.frame = CGRect(x: x, y: 1, width: LedgeMetrics.stripIconCell, height: LedgeMetrics.stripIconCell)
            appButtons.append(button)
            x += LedgeMetrics.stripIconCell
        }
        // [+] and Settings are siblings of the scroll view, not passengers in
        // it: they are the two controls that must survive any amount of crowding.
        _ = addButton(key: Self.newAppKey, symbol: "plus", title: "New app", into: self) {
            [weak self] in self?.callbacks.selectNewApp()
        }
        _ = addButton(
            key: Self.settingsAppID,
            symbol: "slider.horizontal.3",
            title: "Settings",
            into: self
        ) { [weak self] in self?.callbacks.selectSettings() }
        needsLayout = true
    }

    static func symbol(from icon: String) -> String {
        icon.hasPrefix("sf:") ? String(icon.dropFirst(3)) : icon
    }

    /// Width the icons would like: the leading pad plus one 40 pt cell each.
    private var iconContentWidth: CGFloat {
        LedgeMetrics.stripLeadingPad + CGFloat(appButtons.count) * LedgeMetrics.stripIconCell
    }

    /// The widest the scrolling area may be before it would push **[+]** into
    /// the Settings divider's safe gap.
    private var maxIconAreaWidth: CGFloat {
        max(
            0,
            bounds.width
                - LedgeMetrics.stripSettingsDividerInset
                - LedgeMetrics.stripSafeGap
                - LedgeMetrics.stripIconCell
        )
    }

    override func layout() {
        super.layout()
        separator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        settingsDivider.frame = CGRect(
            x: bounds.width - LedgeMetrics.stripSettingsDividerInset,
            y: 13,
            width: 1,
            height: 16
        )
        buttons[Self.settingsAppID]?.frame = CGRect(
            x: bounds.width - LedgeMetrics.stripSettingsInset,
            y: 1,
            width: LedgeMetrics.stripIconCell,
            height: LedgeMetrics.stripIconCell
        )

        // `min` is what makes an uncrowded strip identical to the old one: the
        // area takes exactly its content's width, so [+] lands where it always
        // did, and only an overflowing row is clamped and starts scrolling.
        let iconArea = min(iconContentWidth, maxIconAreaWidth)
        scrollView.frame = CGRect(x: 0, y: 1, width: iconArea, height: LedgeMetrics.stripIconCell)
        iconRow.frame = CGRect(
            x: 0,
            y: 0,
            width: max(iconContentWidth, iconArea),
            height: LedgeMetrics.stripIconCell
        )
        buttons[Self.newAppKey]?.frame = CGRect(
            x: iconArea,
            y: 1,
            width: LedgeMetrics.stripIconCell,
            height: LedgeMetrics.stripIconCell
        )
        syncIconHover()
    }

    /// Light the presented app's icon (spec §8: the dot indicator). `newApp`
    /// lights **[+]**.
    func select(_ presentation: ShellPresentation) {
        let key: String?
        if case .newApp = presentation {
            key = Self.newAppKey
        } else {
            key = presentation.app
        }
        for (buttonKey, button) in buttons {
            button.setActive(buttonKey == key)
        }
    }

    private func syncIconHover() {
        for button in appButtons { button.syncHover() }
    }

    @discardableResult
    private func addButton(
        key: String,
        symbol: String,
        title: String,
        into parent: NSView,
        handler: @escaping () -> Void
    ) -> HoverIconButton {
        let button = HoverIconButton(symbol: symbol, accessibilityLabel: title, handler: handler)
        button.frame = CGRect(x: 0, y: 1, width: LedgeMetrics.stripIconCell, height: LedgeMetrics.stripIconCell)
        buttons[key] = button
        parent.addSubview(button)
        return button
    }

    // MARK: - Test seams

    /// Where a strip control ended up **in the strip's own coordinates** — which
    /// for a scrolling icon is not the same as its frame in the row it lives in.
    func frameForButton(key: String) -> CGRect? {
        guard let button = buttons[key] else { return nil }
        return convert(button.bounds, from: button)
    }

    func frameForApp(_ app: String) -> CGRect? { frameForButton(key: app) }
    var newAppButtonFrame: CGRect? { frameForButton(key: Self.newAppKey) }
    var settingsButtonFrame: CGRect? { frameForButton(key: Self.settingsAppID) }
    /// Whether the icon area is actually scrolling (content wider than its clip).
    var isIconAreaScrolling: Bool { iconContentWidth > scrollView.frame.width + 0.5 }
    var iconAreaFrame: CGRect { scrollView.frame }
    /// Scroll the icon area, as a live scroll would — for the staleness test.
    func scrollIcons(to x: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Wing content is decoration: it must never intercept the click or the hover
/// that opens the panel, so the container it lives in is transparent to hit
/// testing and everything inside it goes with it.
private class PassthroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The **panel wings**: the two zones flanking the hardware cutout at the top of
/// the *expanded* panel. Not to be confused with the collapsed §3.3 wings
/// (`WingBarView`, below) — those are live-activity areas on the pill; this is
/// the row the panel reserves so an app's tree can no longer be drawn under the
/// camera.
///
/// The row exists **by construction, not by convention**. Every app in the repo
/// opened with a title row, and on a notched Mac the middle of that row was
/// simply invisible: chess's engine name, tetris's key hints, settings' worker
/// count. Asking eleven apps to leave the top-centre alone is a rule that gets
/// broken by app twelve; reserving the row means an app that renders a top row
/// *cannot* collide with the camera, because its tree starts below it.
///
/// The shell owns both zones by default — the app's name at the left, the "Edit
/// with AI" affordance at the right — and an app may take over the **left** one
/// with a `<wing side="left">` (spec §5). The right one is never an app's:
/// there has to be one place the user can always reach the builder from, and a
/// place an app can take away is not one.
final class PanelWingBarView: FlippedView {
    /// Left zone content: the app's own, when it mounted a `wing`.
    private var appContent: NSView?
    private let leftZone = ClippingView()
    private let rightZone = ClippingView()
    private let nameLabel: LedgeText
    private let editButton: LedgeButton

    /// The hardware cutout's width and the row's height, pushed in by the
    /// surface before every layout. They are measurements of the display, not
    /// preferences (see `NotchMetrics`).
    var cutoutWidth: CGFloat = NotchMetrics.fallback.closedWidth
    var rowHeight: CGFloat = NotchMetrics.fallback.closedHeight

    init(onEdit: @escaping () -> Void) {
        nameLabel = LedgeText("")
        nameLabel.font = LedgeTheme.systemFont(
            LedgeMetrics.panelWingNamePointSize,
            weight: LedgeMetrics.panelWingNameWeight
        )
        nameLabel.textColor = LedgeTheme.secondary
        nameLabel.invalidateIntrinsicContentSize()      // `font` doesn't do it for us
        // "Edit", not "Edit with AI": the wand says which kind of edit, and the
        // zone beside it is 95 pt wide on a 440 pt panel (D6 voice — obvious,
        // never verbose).
        editButton = LedgeButton(
            "Edit",
            symbol: "wand.and.stars",
            variant: .glass,
            size: .s,
            handler: onEdit
        )
        editButton.setAccessibilityLabel("Edit with AI")
        super.init(frame: .zero)
        leftZone.addSubview(nameLabel)
        rightZone.addSubview(editButton)
        addSubview(leftZone)
        addSubview(rightZone)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// `name` is the app's catalog display name, shown when it supplies no wing;
    /// `content` is its `wing side="left"` view, which replaces the name
    /// wholesale (an app that names itself twice is an app wasting the zone).
    /// `canEdit` hides the affordance for surfaces that have no app behind them
    /// — the placeholder card and **[+]** have nothing to edit.
    ///
    /// `showingEditor` flips it from a door into a toggle: **Edit** while the
    /// app's tree is on screen, **Preview** while the editor is. One control for
    /// two full-panel surfaces (the editor is not a split — see
    /// `EditorSurfaceView`), so the label must always name where the press
    /// *goes*, never where you are.
    func apply(name: String?, content: NSView?, canEdit: Bool, showingEditor: Bool = false) {
        if content !== appContent {
            appContent?.removeFromSuperview()
            appContent = content
            if let content {
                // The renderer builds every node for Auto Layout; the zone
                // frames its content by hand, so translation goes back on.
                content.translatesAutoresizingMaskIntoConstraints = true
                leftZone.addSubview(content)
            }
        }
        nameLabel.stringValue = name ?? ""
        nameLabel.isHidden = appContent != nil || (name ?? "").isEmpty
        editButton.isHidden = !canEdit
        if showingEditor != isShowingEditor {
            isShowingEditor = showingEditor
            editButton.apply(
                label: showingEditor ? "Preview" : "Edit",
                symbol: showingEditor ? "eye" : "wand.and.stars"
            )
            editButton.setAccessibilityLabel(showingEditor ? "Show the app" : "Edit with AI")
            applyToggleAppearance()
        }
        needsLayout = true
    }

    /// The toggle's build status (spec §3.2 `app` states, read through the
    /// editor): neutral glass normally, green when the app reloaded cleanly,
    /// red when it crashed. The colour lives on this control rather than in the
    /// transcript because it is the answer to "did that work" — and the eye is
    /// already on this corner when the user goes to look back at the app.
    func setBuildStatus(_ status: EditorBuildStatus) {
        buildStatus = status
        applyToggleAppearance()
    }

    /// Two things share this control, so they are resolved in one place.
    ///
    /// While the editor is open the button is the way BACK to your app, and it
    /// has to be findable at a glance in a panel that is otherwise a wall of
    /// transcript — so it fills, in yellow, with white ink. Build status is a
    /// wash on the same control when the app's tree is showing.
    private func applyToggleAppearance() {
        if isShowingEditor {
            // The shell's accent already IS the amber this asks for (Theme.swift).
            editButton.filledTint = LedgeTheme.accent
            editButton.tint = nil
            return
        }
        editButton.filledTint = nil
        editButton.tint = switch buildStatus {
        case .neutral: nil
        case .reloaded: LedgeTheme.green
        case .crashed: LedgeTheme.red
        }
    }

    private(set) var buildStatus: EditorBuildStatus = .neutral
    private var isShowingEditor = false

    /// Release the app's content without destroying it — called when the panel
    /// switches apps, so the outgoing app's wing view goes back to being an
    /// unparented node in its own tree rather than lingering in the zone.
    func clearContent() {
        appContent?.removeFromSuperview()
        appContent = nil
    }

    // MARK: - Geometry

    /// The camera housing plus a margin: nothing is ever drawn here. Clamped to
    /// the row, so a panel narrower than the cutout is all dead zone and both
    /// wings are empty rather than negative.
    var deadZoneRect: CGRect {
        let width = min(cutoutWidth + LedgeMetrics.panelWingCutoutMargin * 2, bounds.width)
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: rowHeight)
    }

    /// Everything left of the dead zone, inset from the panel edge. `max(0,…)`
    /// is the hard clamp: as the panel narrows toward the cutout the zone
    /// shrinks to nothing and its content ellipsizes inside it — the same
    /// discipline the collapsed wings learned the hard way.
    var leftZoneRect: CGRect {
        let pad = LedgeMetrics.panelWingPad
        let edge = deadZoneRect.minX
        return CGRect(x: min(pad, edge), y: 0, width: max(0, edge - pad), height: rowHeight)
    }

    var rightZoneRect: CGRect {
        let pad = LedgeMetrics.panelWingPad
        let edge = deadZoneRect.maxX
        return CGRect(x: edge, y: 0, width: max(0, bounds.width - pad - edge), height: rowHeight)
    }

    override func layout() {
        super.layout()
        let left = leftZoneRect
        let right = rightZoneRect
        leftZone.frame = left
        rightZone.frame = right

        // The label is sized to its own line height and centred by hand:
        // NSTextField top-aligns in an over-tall frame (see shell/README.md),
        // and its *width* is the zone's, never the string's, so a long name
        // ellipsizes rather than running on under the housing.
        let lineHeight = min(ceil(nameLabel.intrinsicContentSize.height), left.height)
        nameLabel.frame = CGRect(
            x: 0,
            y: (left.height - lineHeight) / 2,
            width: left.width,
            height: lineHeight
        )
        appContent?.frame = CGRect(x: 0, y: 0, width: left.width, height: left.height)

        // Trailing-aligned: the affordance hangs off the panel's right edge, so
        // it stays put as the zone grows and shrinks with the panel width.
        let size = editButton.intrinsicContentSize
        let width = min(ceil(size.width), right.width)
        editButton.frame = CGRect(
            x: right.width - width,
            y: (right.height - size.height) / 2,
            width: width,
            height: size.height
        )
    }

    // MARK: - Test seams

    var nameView: NSTextField { nameLabel }
    var editView: LedgeButton { editButton }
    var appContentView: NSView? { appContent }
}

/// A container that clips. Used for the panel-wing zones, where "clipped" is the
/// point: whatever an app puts in a zone, it stops at the zone's edge and the
/// camera is on the other side of that edge.
private final class ClippingView: FlippedView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The collapsed notch's two wings, laid out around the hardware cutout (spec
/// §3.3 extension). The label sits in the left wing, the canvas strip in the
/// right one, and the cutout's own width is dead space between them.
private final class WingBarView: PassthroughView {
    let label: LedgeText
    let canvas: ProtocolCanvasView

    /// Inset between a wing's edge and its content.
    static let pad: CGFloat = 12

    /// Filled in by the surface before every layout: the width of each wing, and
    /// the hardware cutout that sits between them — the wings are what is left
    /// of the pill on either side of it.
    var extents: (left: CGFloat, right: CGFloat) = (0, 0)
    var notchWidth: CGFloat = NotchMetrics.fallback.closedWidth
    var notchHeight: CGFloat = NotchMetrics.fallback.closedHeight

    /// The wing label's face — the mockup's `600 12px` live-activity text.
    static let font = LedgeTheme.systemFont(11.5, weight: .semibold)

    init() {
        // LedgeText, not a bare NSTextField: it already clears the bezel that
        // otherwise eats a couple of points at draw time and truncates a label
        // laid out at exactly its own measured width (see shell/README.md).
        label = LedgeText("")
        label.font = Self.font
        label.invalidateIntrinsicContentSize()      // `font` doesn't do it for us
        canvas = ProtocolCanvasView()
        canvas.chromeless = true                 // no card behind it: it IS the pill
        super.init(frame: .zero)
        addSubview(label)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Every number here is a hard bound, not a hint. The strip is the menu
    /// bar's height and the middle of it is the camera housing — opaque
    /// hardware, not a dark pixel — so wing content that overruns either does
    /// not "look wrong", it silently disappears.
    override func layout() {
        super.layout()
        let height = max(0, min(notchHeight, bounds.height))
        let available = max(0, bounds.width - notchWidth)
        let left = max(0, min(extents.left, available))
        let right = max(0, min(extents.right, available - left))

        // NSTextField top-aligns in an over-tall frame, so the label is sized to
        // its own line height and centred by hand (see shell/README.md). The
        // width is the *wing's*, never the string's: a label too long for its
        // wing truncates with an ellipsis (LedgeText is `.byTruncatingTail`)
        // rather than running on under the housing.
        let lineHeight = min(ceil(label.intrinsicContentSize.height), height)
        label.frame = CGRect(
            x: Self.pad,
            y: (height - lineHeight) / 2,
            width: max(0, left - Self.pad * 2),
            height: lineHeight
        )
        // The canvas starts where the housing ends and is exactly notch-height,
        // so an app's draw ops (§3.4) can use the notch height as their
        // coordinate space without a scale factor.
        canvas.frame = CGRect(
            x: bounds.width - right + Self.pad,
            y: 0,
            width: max(0, right - Self.pad * 2),
            height: height
        )
    }
}

/// The whole shell is one fixed-size transparent window; this view morphs a
/// black notch shape inside it with springs. The window frame never animates —
/// that is what keeps open/close buttery.
final class ShellSurfaceView: FlippedView {
    static let fillet: CGFloat = 12
    private static let appBarHeight: CGFloat = 42
    private static let expandedBottomRadius: CGFloat = 26
    private static let collapsedBottomRadius: CGFloat = 12
    /// Between the two, because the mini surface is between the two: the panel's
    /// 26 on a ~60 pt card reads as a lozenge, the pill's 12 as a cut-off panel.
    private static let miniBottomRadius: CGFloat = 18

    var metrics: NotchMetrics = .fallback {
        didSet {
            guard metrics != oldValue else { return }
            applyGeometry(spring: nil)
        }
    }

    /// What the screen allows. Only used to clamp wing widths here — panel
    /// width/height arrive already clamped via `present`.
    var limits: PanelLimits = .fallback

    var hoverPolicy = HoverPolicy()
    var requestOpen: (() -> Void)?
    var requestClose: (() -> Void)?

    /// Expanded panel height. Always measured, never scripted: it is the
    /// presented tree's fitting height plus the strip (spec §5), or the fixed
    /// height of a chrome surface (chat / [+] / the placeholder card).
    private(set) var expandedHeight: CGFloat = HostPlaceholderView.panelHeight
    /// Expanded panel width — 440 unless the presented app declared another one
    /// in `meta.panel.width` (already clamped by `PanelLimits`).
    private(set) var expandedWidth: CGFloat = PanelLimits.defaultWidth

    /// The mini surface's measured size, kept separately from the panel's so
    /// that a peek and a later expand each morph from their own last shape
    /// rather than inheriting the other's.
    private(set) var miniSize = CGSize(width: 260, height: 64)

    /// Whether the cutout exclusion row is reserved. True for the panel *and*
    /// the mini surface: both hang from the top of the screen, so both would
    /// otherwise draw their first row underneath the camera. False for the pill,
    /// which *is* the cutout and has nothing to exclude.
    private var reservesCutoutRow: Bool {
        presentation.isExpanded || presentation.isMini
    }

    /// The wing an app currently owns, or nil for the idle pill (spec §3.3
    /// extension). Arbitration between apps happens in the panel controller;
    /// this is only ever the winner.
    private(set) var wing: WingSpec?

    /// The drop shelf (INTAKE): files dragged onto the **expanded** panel become
    /// an app-level `drop` event. `canAcceptDrop` answers "is there an app on
    /// screen to give them to" — if not, the drag is refused rather than
    /// swallowed, so the Finder's own drop feedback stays honest.
    var canAcceptDrop: (() -> Bool)?
    var onDropFiles: (([String]) -> Bool)?

    private let shapeLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()
    private let rimMask = CAGradientLayer()
    private let glowLayer = CAShapeLayer()
    /// The drop shelf's affordance: the panel's own outline, stroked in the
    /// existing accent-stroke token while a valid drag is over it. Its own layer
    /// so it can never disturb the rim light or the attention glow.
    private let dropLayer = CAShapeLayer()
    private let contentContainer = FlippedView()
    /// Everything below the cutout exclusion row. The app's tree and every
    /// chrome surface live in here rather than in `contentContainer` directly,
    /// which is what makes "an app cannot draw under the camera" a fact of the
    /// view hierarchy instead of a rule apps are asked to remember.
    private let contentHost = FlippedView()
    private let wingBar = WingBarView()
    private let panelWingBar: PanelWingBarView
    private let appBar: AppBarView
    private var currentContent: NSView?
    private(set) var presentation: ShellPresentation = .collapsed
    private var hoverBump = false
    private var hoverInside = false
    /// Whether the cursor is currently within the hover region. Read by the
    /// panel controller so a peek's dwell does not expire out from under a user
    /// who is looking straight at it.
    var isHovered: Bool { hoverInside }
    private var morphGraceUntil: CFTimeInterval = 0
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    init(callbacks: ShellCallbacks) {
        self.appBar = AppBarView(callbacks: callbacks)
        // The Edit affordance opens the app's existing chat surface (spec §8).
        // Inert this phase — there is no builder behind it yet — but it is the
        // one control that has to exist before the thing it opens does, because
        // "where do I ask for a change" is the question the whole surface is an
        // answer to.
        self.panelWingBar = PanelWingBarView(onEdit: callbacks.toggleChat)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false

        shapeLayer.fillColor = NSColor.black.cgColor
        shapeLayer.shadowColor = NSColor.black.cgColor
        shapeLayer.shadowOffset = CGSize(width: 0, height: 8)
        shapeLayer.shadowRadius = 14
        shapeLayer.shadowOpacity = 0
        layer?.addSublayer(shapeLayer)

        // Hairline edge light, faded out near the menu bar so the shape stays
        // seamless against the hardware notch.
        rimLayer.fillColor = nil
        rimLayer.strokeColor = NSColor(white: 1, alpha: 0.08).cgColor
        rimLayer.lineWidth = 1
        rimMask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor]
        rimMask.locations = [0, 0.35, 1]
        rimLayer.mask = rimMask
        layer?.addSublayer(rimLayer)

        // `attention` (spec §3.3) — a glow, drawn as its own stroked copy of the
        // shape so pulsing it can never disturb the rim light's own settings.
        glowLayer.fillColor = nil
        glowLayer.strokeColor = LedgeTheme.accent.cgColor
        glowLayer.lineWidth = 2
        glowLayer.opacity = 0
        layer?.addSublayer(glowLayer)

        // The drop shelf's highlight — the same outline in the existing
        // accent-stroke token, hidden until a valid file drag is over the panel.
        dropLayer.fillColor = nil
        dropLayer.strokeColor = LedgeTheme.accentStroke.cgColor
        dropLayer.lineWidth = 2
        dropLayer.opacity = 0
        layer?.addSublayer(dropLayer)

        // Files may be dropped onto the expanded panel (INTAKE). Registering the
        // surface itself is enough: nothing inside it registers for dragged
        // types, so AppKit walks up to here from whatever the drag is over.
        registerForDraggedTypes([.fileURL])

        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        // Unchanged value, now named: the content container is the panel's 26
        // minus its 12 pt inset — the concentric rule the panel got right on day
        // one and the components never followed (D4).
        contentContainer.layer?.cornerRadius = LedgeMetrics.rContent
        addSubview(contentContainer)

        contentContainer.addSubview(contentHost)

        // Wings ride inside the content container so they spring with the shape
        // instead of snapping to each new width.
        wingBar.autoresizingMask = [.width, .height]
        wingBar.isHidden = true
        contentContainer.addSubview(wingBar)

        // Above the content host, so the reserved row is never overdrawn by an
        // app whose tree is taller than the box it was given.
        panelWingBar.isHidden = true
        contentContainer.addSubview(panelWingBar)

        appBar.alphaValue = 0
        addSubview(appBar)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Ledge notch panel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Geometry

    /// Outer shape size, including the fillets that tuck the panel under the
    /// menu bar. `width`/`height` are only consulted when expanded; collapsed,
    /// the size comes from the hardware notch plus whatever wings are up.
    func shapeSize(
        expanded: Bool,
        width: CGFloat = PanelLimits.defaultWidth,
        height: CGFloat
    ) -> CGSize {
        shapeSize(expanded: expanded, width: width, height: height, bumped: false)
    }

    /// How much wider the collapsed pill gets on hover. Split evenly across the
    /// two sides — it is a bump, not a wing.
    private static let hoverBumpWidth: CGFloat = 14

    private func shapeSize(
        expanded: Bool,
        width: CGFloat,
        height: CGFloat,
        bumped: Bool
    ) -> CGSize {
        let fillets = Self.fillet * 2
        guard expanded else {
            let wings = wingExtents
            return CGSize(
                width: metrics.closedWidth + wings.left + wings.right + fillets
                    + (bumped ? Self.hoverBumpWidth : 0),
                height: metrics.closedHeight + (bumped ? 2.5 : 0)
            )
        }
        return CGSize(width: width + fillets, height: height)
    }

    /// The hardware cutout — the camera housing — in this view's coordinates.
    /// It is a hole in the display: it does not move, it is the same width the
    /// pill is at rest, and nothing drawn under it is ever seen.
    var hardwareCutoutRect: CGRect {
        CGRect(
            x: (bounds.width - metrics.closedWidth) / 2,
            y: 0,
            width: metrics.closedWidth,
            height: metrics.closedHeight
        )
    }

    /// How far the collapsed shape reaches past the hardware notch on each side
    /// (spec §3.3 extension). Text sizes the left wing, the canvas strip sizes
    /// the right one, and a bare `width` request is a *total* pill width whose
    /// surplus is split evenly — which is what lets an app with no content at
    /// all (the breathing pacer) animate pure shape.
    private var wingExtents: (left: CGFloat, right: CGFloat) {
        guard let wing else { return (0, 0) }
        let maxWing = PanelLimits.maxWingWidth
        var left: CGFloat = 0
        var right: CGFloat = 0

        if let text = wing.text, !text.isEmpty {
            // Measure the string rather than trusting intrinsicContentSize: it
            // under-reports for a truncating label by a few points, so a label
            // laid out at exactly that width draws an ellipsis it does not need
            // (see shell/README.md). +6 is the same slack LedgeText applies.
            let width = ceil(
                (text as NSString).size(withAttributes: [.font: WingBarView.font]).width
            ) + 6
            left = min(width + WingBarView.pad * 2, maxWing)
        }
        if let canvas = wing.canvas, canvas.w > 0 {
            right = min(CGFloat(canvas.w) + WingBarView.pad * 2, maxWing)
        }
        if let requested = wing.width, requested.isFinite {
            let total = min(
                max(CGFloat(requested), metrics.closedWidth),
                metrics.closedWidth + maxWing * 2
            )
            let deficit = max(0, total - (metrics.closedWidth + left + right))
            left = min(left + deficit / 2, maxWing)
            right = min(right + deficit / 2, maxWing)
        }
        return (left, right)
    }

    /// Where the black shape sits. The expanded panel is centred on the window;
    /// the collapsed pill is **not centred on its own width** — it is anchored to
    /// the hardware cutout.
    ///
    /// That distinction is the whole ballgame for wings. Centring the pill slides
    /// it sideways by `(left − right) / 2` whenever the wings are asymmetric, and
    /// `WingBarView` lays its content out as `[left wing | cutout | right wing]`
    /// — so the two disagree by exactly that offset. A label with no canvas
    /// beside it (an alarm's countdown; the maximally asymmetric case) then draws
    /// half of itself under the camera housing, where no pixel is ever seen.
    private var shapeRect: CGRect {
        // The mini surface is centred on the cutout like the panel, not anchored
        // beside it like the pill — it is a small panel, not a wide wing.
        if presentation.isMini {
            return CGRect(
                x: (bounds.width - miniSize.width) / 2,
                y: 0,
                width: miniSize.width,
                height: miniSize.height
            )
        }
        let bumped = hoverBump && !presentation.isExpanded
        let size = shapeSize(
            expanded: presentation.isExpanded,
            width: expandedWidth,
            height: expandedHeight,
            bumped: bumped
        )
        guard !presentation.isExpanded else {
            return CGRect(
                x: (bounds.width - size.width) / 2,
                y: 0,
                width: size.width,
                height: size.height
            )
        }
        return CGRect(
            x: hardwareCutoutRect.minX - Self.fillet - wingExtents.left
                - (bumped ? Self.hoverBumpWidth / 2 : 0),
            y: 0,
            width: size.width,
            height: size.height
        )
    }

    /// Where the shape currently is inside this view — what a snapshot crops to,
    /// and (collapsed) not the centre of the view: see `shapeRect`.
    var currentShapeRect: CGRect { shapeRect }

    private var bodyRect: CGRect {
        shapeRect.insetBy(dx: Self.fillet, dy: 0)
    }

    /// The region the cursor may occupy without the shell reacting as if the
    /// pointer left. Also the interactive (hit-testable) region.
    private var hoverRegion: CGRect {
        let shape = shapeRect
        // A mini gets the open-panel slop rather than the pill's: it is bigger
        // than the pill and the user is reaching *for* it, so the region has to
        // cover the shape they can actually see.
        if presentation.isExpanded || presentation.isMini {
            let slop = hoverPolicy.openSlop
            return CGRect(
                x: shape.minX - slop,
                y: 0,
                width: shape.width + slop * 2,
                height: shape.height + slop
            )
        }
        return CGRect(
            x: shape.minX - hoverPolicy.closedSlopX,
            y: 0,
            width: shape.width + hoverPolicy.closedSlopX * 2,
            height: shape.height + hoverPolicy.closedSlopBottom
        )
    }

    override func layout() {
        super.layout()
        applyGeometry(spring: nil)
    }

    // MARK: - Presentation

    /// Full catalog snapshot from the host (spec §3.6) — the strip is built from
    /// this and nothing else.
    func setCatalog(_ apps: [CatalogApp]) {
        appBar.setApps(apps)
        appBar.select(presentation)
    }

    /// Show a surface. `content` is whatever fills the panel above the strip —
    /// a host-rendered app tree, a chrome surface, or the placeholder card;
    /// `height` is the whole panel's height including the strip.
    ///
    /// Re-presenting the *same* content view (an in-place commit landed) is a
    /// re-measure, not a content swap: swapping would cross-fade the panel on
    /// every price tick.
    func present(
        _ newPresentation: ShellPresentation,
        content: NSView?,
        width: CGFloat = PanelLimits.defaultWidth,
        height: CGFloat,
        animated: Bool
    ) {
        let old = presentation
        let sameContent = content != nil && content === currentContent
        guard old != newPresentation || !sameContent
                || height != expandedHeight || width != expandedWidth else { return }

        presentation = newPresentation
        expandedHeight = newPresentation.isExpanded ? height : expandedHeight
        expandedWidth = newPresentation.isExpanded ? width : expandedWidth
        if newPresentation.isMini { miniSize = CGSize(width: width, height: height) }
        hoverBump = false
        openWork?.cancel()
        if newPresentation.isExpanded {
            closeWork?.cancel()
        }

        appBar.select(newPresentation)
        setAccessibilityLabel("Ledge notch panel, \(Self.describe(newPresentation))")

        let spring: Spring? = if !animated {
            nil
        } else if !old.isExpanded && newPresentation.isExpanded {
            .open
        } else if old.isExpanded && !newPresentation.isExpanded {
            .close
        } else {
            .morph
        }
        applyGeometry(spring: spring)
        if !sameContent {
            swapContent(content ?? FlippedView(), animated: animated)
        }
        updateAppBar(expanded: newPresentation.isExpanded, animated: animated)
        updateShadow(animated: animated)

        // Switching apps resizes the panel under a stationary cursor; without
        // a grace period that reads as "mouse left" and slams the panel shut
        // mid-switch. Exits are forgiven until the morph has settled.
        if animated, old.isExpanded, newPresentation.isExpanded {
            morphGraceUntil = CACurrentMediaTime() + hoverPolicy.morphGrace
            let work = DispatchWorkItem { [weak self] in self?.evaluateHover() }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + hoverPolicy.morphGrace,
                execute: work
            )
        }

        // The hover region just changed shape under a possibly-stationary
        // cursor; resync so a stale inside/outside state can't wedge us.
        if window != nil {
            evaluateHover()
        }
    }

    /// Height of the row the expanded panel reserves for the hardware cutout —
    /// the panel wings live in it, and the app's tree starts below it. It is the
    /// cutout's own height because that is exactly how much of the panel the
    /// camera housing covers; on a screen with no cutout it is the menu-bar
    /// height, which is the same measurement (`NotchMetrics`).
    var panelWingRowHeight: CGFloat { metrics.closedHeight }

    /// Fill the panel wings for whatever is presented (spec §5 `wing`).
    ///
    /// `name` is the app's catalog display name — the left zone's default, and
    /// the reason apps may now delete their own title rows. `content` is the
    /// app's `wing side="left"` view when it mounted one, which replaces the
    /// name. `canEdit` is false for surfaces with no app behind them.
    ///
    /// Called on every refresh rather than diffed here: the renderer answers
    /// "what is this app's wing" from its live tree, so appearing, changing and
    /// disappearing are all just a different answer to the same question.
    func setPanelWing(name: String?, content: NSView?, canEdit: Bool, showingEditor: Bool = false) {
        panelWingBar.apply(
            name: name,
            content: content,
            canEdit: canEdit,
            showingEditor: showingEditor
        )
    }

    /// Put a wing up on the collapsed notch, or take it down with `nil` (spec
    /// §3.3 extension). Repeated width updates at 2–10 Hz are the normal case
    /// (a breathing pacer, a live meter): each one re-springs the shape from
    /// wherever the previous animation had got to, so "latest wins" is the
    /// coalescing rule and the morph spring is the only thing driving width.
    /// The hover bump stays additive on top and is never fought over.
    func setWing(_ spec: WingSpec?, animated: Bool = true) {
        let next = spec.flatMap { $0.isEmpty ? nil : $0 }
        guard next != wing else { return }
        wing = next
        wingBar.label.stringValue = next?.text ?? ""
        wingBar.label.isHidden = next?.text == nil
        wingBar.canvas.isHidden = next?.canvas == nil
        applyGeometry(spring: animated ? .morph : nil)
    }

    /// The canvas strip that lives in the right wing. The renderer blits an
    /// app's coalesced draw frames (§3.4) here as well as into its panel tree,
    /// so the same node can be drawn collapsed and expanded — including the
    /// `image` op, which is what puts a spritesheet cell on the notch.
    var wingCanvasView: ProtocolCanvasView { wingBar.canvas }

    /// The expanded panel's cutout exclusion row and its two zones, for the
    /// geometry assertions — "nothing is under the camera" is the kind of claim
    /// that has to be measured, not looked at (the collapsed wings learned this
    /// first; see `WingGeometryTests`).
    var panelWingBarView: PanelWingBarView { panelWingBar }
    var panelContentHost: NSView { contentHost }
    /// The strip, for the overflow-layout assertions.
    var appBarView: AppBarView { appBar }

    /// The label that lives in the left wing. Paired with `wingCanvasView`:
    /// between them they are everything a wing can contain, and where they
    /// landed is the thing worth asserting about wing geometry.
    var wingLabelView: NSTextField { wingBar.label }

    /// `attention` (spec §3.3): a glow on the notch, no notification. Deliberately
    /// short and additive — it does not touch the shape, the hover state, or any
    /// of the feel tunables.
    func flashAttention() {
        flashGlow(color: LedgeTheme.accent, values: [0, 0.9, 0, 0.7, 0], keyTimes: [0, 0.15, 0.45, 0.6, 1])
    }

    /// Build status on the Edit/Preview toggle (spec §3.2 states, surfaced in
    /// §8's chrome). Sets the toggle's colour and — only on a genuine change —
    /// pulses the panel once in the same hue.
    ///
    /// One pulse, not the attention keyframe's two: `attention` is an app asking
    /// to be noticed, this is an answer to something the user just did, and an
    /// answer that insists twice reads as an alarm.
    func setBuildStatus(_ status: EditorBuildStatus) {
        let changed = status != panelWingBar.buildStatus
        panelWingBar.setBuildStatus(status)
        guard changed, status != .neutral else { return }
        flashGlow(
            color: status == .crashed ? LedgeTheme.red : LedgeTheme.green,
            values: [0, 0.85, 0],
            keyTimes: [0, 0.2, 1]
        )
    }

    /// Test seam: how many pulses have been run. The animation itself is not
    /// observable in a headless layout pass, and "does it pulse twice on a
    /// re-present" is exactly the question worth asserting.
    private(set) var attentionPulseCount = 0

    private func flashGlow(color: NSColor, values: [Double], keyTimes: [NSNumber]) {
        attentionPulseCount += 1
        glowLayer.strokeColor = color.cgColor
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = values
        pulse.keyTimes = keyTimes
        pulse.duration = 1.1
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(pulse, forKey: "attention")
    }

    /// Recomputes every layer/subview target and (optionally) springs the
    /// visible geometry from wherever it currently is.
    private func applyGeometry(spring: Spring?) {
        guard bounds.width > 0 else { return }

        let shape = shapeRect
        let body = bodyRect
        let bottomRadius: CGFloat = if presentation.isExpanded {
            Self.expandedBottomRadius
        } else if presentation.isMini {
            Self.miniBottomRadius
        } else {
            Self.collapsedBottomRadius
        }
        let path = notchPath(in: shape, topRadius: Self.fillet, bottomRadius: bottomRadius)
        let barHeight = presentation.isExpanded ? Self.appBarHeight : 0

        let previousPath = shapeLayer.presentation()?.path ?? shapeLayer.path
        let previousShadowPath = shapeLayer.presentation()?.shadowPath ?? shapeLayer.shadowPath
        let previousContentPosition = contentContainer.layer?.presentation()?.position
            ?? contentContainer.layer?.position
        let previousContentBounds = contentContainer.layer?.presentation()?.bounds
            ?? contentContainer.layer?.bounds
        let previousBarPosition = appBar.layer?.presentation()?.position ?? appBar.layer?.position

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.path = path
        shapeLayer.shadowPath = path
        rimLayer.path = path
        glowLayer.path = path
        dropLayer.path = path
        rimMask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(shape.height, 1))
        contentContainer.frame = CGRect(
            x: body.minX,
            y: 0,
            width: body.width,
            height: shape.height - barHeight
        )
        // Wings only exist on the collapsed pill; expanded — or peeking — the
        // surface is the app's own, and a wing drawn across it would be the same
        // app talking over itself.
        wingBar.isHidden = reservesCutoutRow || wing == nil
        wingBar.extents = reservesCutoutRow ? (0, 0) : wingExtents
        wingBar.notchWidth = metrics.closedWidth
        wingBar.notchHeight = metrics.closedHeight
        wingBar.frame = contentContainer.bounds
        wingBar.needsLayout = true

        // The cutout exclusion row (panel wings): reserved while expanded, gone
        // while collapsed — the pill *is* the cutout, so there is nothing there
        // to exclude.
        let exclusion = reservesCutoutRow ? panelWingRowHeight : 0
        // The row is *reserved* while peeking but stays empty: the app's name and
        // the Edit affordance belong to the panel. A peek is a glance, and a
        // glance with chrome on it is a panel that forgot to open.
        panelWingBar.isHidden = !presentation.isExpanded
        panelWingBar.cutoutWidth = metrics.closedWidth
        panelWingBar.rowHeight = panelWingRowHeight
        panelWingBar.frame = CGRect(
            x: 0,
            y: 0,
            width: contentContainer.bounds.width,
            height: exclusion
        )
        panelWingBar.needsLayout = true
        contentHost.frame = CGRect(
            x: 0,
            y: exclusion,
            width: contentContainer.bounds.width,
            height: max(0, contentContainer.bounds.height - exclusion)
        )
        if presentation.isExpanded {
            appBar.frame = CGRect(
                x: body.minX,
                y: shape.height - barHeight,
                width: body.width,
                height: Self.appBarHeight
            )
        }
        contentContainer.layoutSubtreeIfNeeded()
        appBar.layoutSubtreeIfNeeded()
        CATransaction.commit()

        guard let spring else { return }
        addSpring(to: shapeLayer, keyPath: "path", from: previousPath, spring: spring)
        addSpring(to: shapeLayer, keyPath: "shadowPath", from: previousShadowPath, spring: spring)
        addSpring(to: rimLayer, keyPath: "path", from: previousPath, spring: spring)
        addSpring(to: glowLayer, keyPath: "path", from: previousPath, spring: spring)
        addSpring(to: dropLayer, keyPath: "path", from: previousPath, spring: spring)
        if let contentLayer = contentContainer.layer {
            addSpring(
                to: contentLayer,
                keyPath: "position",
                from: previousContentPosition.map { NSValue(point: $0) },
                spring: spring
            )
            addSpring(
                to: contentLayer,
                keyPath: "bounds",
                from: previousContentBounds.map { NSValue(rect: $0) },
                spring: spring
            )
        }
        if presentation.isExpanded, let barLayer = appBar.layer {
            addSpring(
                to: barLayer,
                keyPath: "position",
                from: previousBarPosition.map { NSValue(point: $0) },
                spring: spring
            )
        }
    }

    private func addSpring(
        to layer: CALayer,
        keyPath: String,
        from previousValue: Any?,
        spring: Spring
    ) {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = previousValue
        animation.toValue = layer.value(forKeyPath: keyPath)
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / spring.response, 2)
        animation.damping = 2 * spring.damping * sqrt(animation.stiffness)
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: keyPath)
    }

    private func swapContent(_ next: NSView, animated: Bool) {
        let previous = currentContent
        currentContent = next
        next.frame = contentHost.bounds
        next.autoresizingMask = [.width, .height]
        contentHost.addSubview(next)

        guard animated else {
            previous?.removeFromSuperview()
            return
        }

        if let previous {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.10
                previous.animator().alphaValue = 0
            }, completionHandler: {
                previous.removeFromSuperview()
            })
        }

        next.alphaValue = 0
        next.setFrameOrigin(CGPoint(x: 0, y: 6))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak next] in
            guard let next, next === self?.currentContent else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                next.animator().alphaValue = 1
                next.animator().setFrameOrigin(.zero)
            }
        }
    }

    private func updateAppBar(expanded: Bool, animated: Bool) {
        guard animated else {
            appBar.alphaValue = expanded ? 1 : 0
            return
        }
        if expanded {
            guard appBar.alphaValue < 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                guard let self, self.presentation.isExpanded else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    self.appBar.animator().alphaValue = 1
                }
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                appBar.animator().alphaValue = 0
            }
        }
    }

    private func updateShadow(animated: Bool) {
        let opacity: Float = if presentation.isExpanded {
            0.55
        } else if hoverBump {
            0.4
        } else {
            0
        }
        let previous = shapeLayer.presentation()?.shadowOpacity ?? shapeLayer.shadowOpacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.shadowOpacity = opacity
        CATransaction.commit()
        if animated {
            addSpring(to: shapeLayer, keyPath: "shadowOpacity", from: previous, spring: .morph)
        }
    }

    private static func describe(_ presentation: ShellPresentation) -> String {
        switch presentation {
        case .collapsed: "idle"
        case .mini(let app): "\(app) peek"
        case .expanded(let app): app ?? "no host"
        case .chat(let app): "\(app) chat"
        case .newApp: "new app"
        case .permissions: "permissions"
        }
    }

    // MARK: - Hover state machine

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        evaluateHover()
    }

    override func mouseMoved(with event: NSEvent) {
        evaluateHover()
    }

    override func mouseExited(with event: NSEvent) {
        evaluateHover()
    }

    /// Tracking events can carry coordinates relative to whichever window is
    /// key, and exit events go stale while the shape morphs under a stationary
    /// cursor — so always test the live global pointer position instead.
    private func evaluateHover() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        setHovering(hoverRegion.contains(convert(windowPoint, from: nil)))
    }

    private func setHovering(_ inside: Bool) {
        guard inside != hoverInside else { return }
        hoverInside = inside

        if inside {
            closeWork?.cancel()
            guard !presentation.isExpanded else { return }
            haptic()
            setBump(true)
            guard hoverPolicy.openOnHover else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverInside, !self.presentation.isExpanded else { return }
                self.requestOpen?()
            }
            openWork?.cancel()
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverPolicy.openDelay, execute: work)
        } else {
            openWork?.cancel()
            if presentation.isExpanded {
                // An exit right after a morph is the panel moving, not the
                // user leaving — forgive it; present() scheduled a resync for
                // when the grace lapses.
                guard CACurrentMediaTime() >= morphGraceUntil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.hoverInside, self.presentation.isExpanded else { return }
                    self.requestClose?()
                }
                closeWork?.cancel()
                closeWork = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + hoverPolicy.closeDelay,
                    execute: work
                )
            } else {
                setBump(false)
            }
        }
    }

    private func setBump(_ bumped: Bool) {
        guard bumped != hoverBump, !presentation.isExpanded else { return }
        hoverBump = bumped
        applyGeometry(spring: .bump)
        updateShadow(animated: true)
    }

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    // MARK: - Drop shelf (INTAKE)

    /// Files are accepted **only while expanded, and only when an app is on
    /// screen to receive them**: an id-0 `drop` event goes to the presented app
    /// (§4.1), so with nothing presented there is no addressee and refusing is
    /// the honest answer. The collapsed pill is 210 pt of hardware notch — far
    /// too small a target to be a drop zone worth aiming at.
    private func acceptsDrag(_ sender: any NSDraggingInfo) -> Bool {
        acceptsDrop(of: Self.filePaths(from: sender))
    }

    /// The whole decision, taken on plain paths so it is testable without
    /// synthesizing an `NSDraggingInfo` (which cannot be constructed outside a
    /// real drag session).
    func acceptsDrop(of paths: [String]) -> Bool {
        guard presentation.isExpanded, canAcceptDrop?() ?? false else { return false }
        return !paths.isEmpty
    }

    /// Hand the paths to the presented app; false when nobody took them, which
    /// is what `performDragOperation` reports back to the drag source.
    @discardableResult
    func deliverDrop(of paths: [String]) -> Bool {
        guard acceptsDrop(of: paths) else { return false }
        return onDropFiles?(paths) ?? false
    }

    /// Test seam: whether the accent outline is currently showing.
    var isShowingDropHighlight: Bool { dropLayer.opacity > 0 }

    private static func filePaths(from sender: any NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (urls as? [URL] ?? []).map(\.path)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else { return [] }
        setDropHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrag(sender) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsDrag(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        return deliverDrop(of: Self.filePaths(from: sender))
    }

    /// A short fade rather than a spring: the highlight tracks the cursor
    /// crossing an edge, and springing it would still be settling when the user
    /// has already dropped.
    private func setDropHighlight(_ on: Bool) {
        let target: Float = on ? 1 : 0
        guard dropLayer.opacity != target else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = dropLayer.presentation()?.opacity ?? dropLayer.opacity
        fade.toValue = target
        fade.duration = 0.12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropLayer.opacity = target
        CATransaction.commit()
        dropLayer.add(fade, forKey: "dropHighlight")
    }

    // MARK: - Events

    /// Anything outside the notch (plus hover slop) is not ours: return nil so
    /// the transparent window passes clicks through to whatever is beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard hoverRegion.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if !presentation.isExpanded {
            openWork?.cancel()
            haptic()
            requestOpen?()
            return
        }
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if presentation.isExpanded {
            requestClose?()
        }
    }

    // MARK: - Shape

    private func notchPath(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(
            to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
