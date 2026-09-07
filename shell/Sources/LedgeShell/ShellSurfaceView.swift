import AppKit
import LedgeShellCore
import QuartzCore

/// Physical notch dimensions for the screen the shell sits on. On notched
/// MacBooks the black bar must cover the hardware cutout exactly; elsewhere —
/// an external display, a pre-notch Mac — there is no cutout to cover and the
/// shell **synthesizes** one, centred in the menu bar like a Dynamic Island.
///
/// Everything downstream takes the cutout rect as input (the wing clamps, the
/// mini's floor, the panel's exclusion row), so a synthesized cutout needs no
/// special case anywhere else: it is simply a rect that happens not to have a
/// camera behind it.
struct NotchMetrics: Equatable {
    var closedWidth: CGFloat
    var closedHeight: CGFloat
    /// True when there is no hardware cutout and this shape was invented. The
    /// geometry does not care; the log line and the tests do.
    var isSynthesized = false

    /// Mockup dimensions; used for snapshots and screens we can't measure.
    static let fallback = NotchMetrics(closedWidth: 210, closedHeight: 34)

    /// The width of an invented pill: the same 210 pt a MacBook's cutout is, so
    /// an idle notch looks like an idle notch on every display. Clamped on a
    /// genuinely narrow screen, where a quarter of the menu bar is plenty.
    static let synthesizedWidth: CGFloat = 210

    /// Shortest and tallest an invented pill may be. A menu bar is around 24 pt
    /// — thinner than a wing's content is tall — so the floor is what keeps a
    /// live activity legible; the ceiling keeps the shape from becoming a bar.
    static let synthesizedHeightRange: ClosedRange<CGFloat> = 32...38

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
        return synthesized(
            menubarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            screenWidth: screen.frame.width
        )
    }

    /// The invented cutout, as pure arithmetic — the half of `detect` that has
    /// no `NSScreen` in it, and therefore the half a test can pin down.
    static func synthesized(menubarHeight: CGFloat, screenWidth: CGFloat) -> NotchMetrics {
        NotchMetrics(
            closedWidth: min(synthesizedWidth, max(120, screenWidth / 4)),
            closedHeight: min(
                max(menubarHeight, synthesizedHeightRange.lowerBound),
                synthesizedHeightRange.upperBound
            ),
            isSynthesized: true
        )
    }
}

/// Which display the notch surface lives on.
///
/// The window frame moves only at screen-configuration time (see
/// `ShellSurfaceView`), so this answer has to be **stable**: a policy that
/// depended on where the user's key window happens to be would relocate the
/// whole shell the next time the display arrangement changed, for reasons the
/// user could not see.
enum NotchScreen {
    /// The policy, over "does this screen have a hardware cutout", in
    /// `NSScreen.screens` order.
    ///
    /// 1. **A notched screen wins.** The cutout is the surface's natural home,
    ///    and a Ledge on the external display of a MacBook that has a notch is
    ///    a Ledge in the wrong place.
    /// 2. **Otherwise the primary screen** — index 0, the display that owns the
    ///    menu bar. Deliberately *not* `NSScreen.main`, which is wherever the
    ///    key window is: with no notch anywhere, that would put the panel on
    ///    whichever display the user last clicked on, and move it later.
    static func preferredIndex(notched: [Bool]) -> Int? {
        guard !notched.isEmpty else { return nil }
        return notched.firstIndex(of: true) ?? 0
    }

    @MainActor
    static func preferred(_ screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard let index = preferredIndex(notched: screens.map { $0.safeAreaInsets.top > 0 }) else {
            // No screens at all is a state AppKit really does report, briefly,
            // while displays are being reconfigured.
            return NSScreen.main
        }
        return screens[index]
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
        // The visit bar is a floor on the expanded shape (`visitBarWidth`), so
        // it is one of the shapes the window has to contain — stated here rather
        // than left to the accident that a wing happens to be wider.
        let widestShape = max(
            max(maxWidth, metrics.closedWidth + LedgeMetrics.visitBarWing * 2),
            metrics.closedWidth + Self.maxWingWidth * 2
        )
        return CGSize(
            width: widestShape + ShellSurfaceView.fillet * 2 + Self.shadowMargin * 2,
            height: maxHeight + Self.shadowMargin
        )
    }
}

/// The pointer's region, and nothing about timing.
///
/// `HoverPolicy` used to live here: an open delay, a close delay, a morph grace
/// and four slop margins, which together *were* the interaction model — hover
/// opened the panel and leaving it closed the panel. flow.md replaced all of it
/// (principle 8: "the visit opens by click and closes by click, Esc, or a
/// walk-away timeout"), so the delays are `LedgeInteraction`'s and the slop is
/// gone entirely: "pointer fully away" means outside the shape, not outside the
/// shape plus 26 points of forgiveness for a close nobody asked for.

/// Horizontal swipes on the collapsed surfaces (ticket 0001 A2).
///
/// Deliberately a value type with no AppKit in it: the *policy* — how far is a
/// swipe, how sideways does it have to be, when does one gesture end and the
/// next begin — is ordinary logic, and only the translation from `NSEvent` is
/// not. Testing the policy through synthesized scroll events would test
/// CoreGraphics.
struct SwipeRecognizer {
    enum Direction: String {
        case left
        case right
    }

    /// Points of horizontal travel before a scroll counts as a swipe. Short
    /// enough to feel like a flick on a 210 pt pill, long enough that a diagonal
    /// scroll aimed at something else never trips it.
    static let threshold: CGFloat = 28
    /// How much more horizontal than vertical the travel must be. The pill sits
    /// under the menu bar, where a lot of scrolling is going somewhere else.
    static let dominance: CGFloat = 1.5
    /// Quiet time after which an unfinished gesture is forgotten. Trackpad
    /// scrolls carry phases and end explicitly; a mouse wheel carries none, so
    /// this is what separates two flicks of one.
    static let idleGap: TimeInterval = 0.35

    private var travel = CGVector(dx: 0, dy: 0)
    /// One swipe per gesture: the rest of the finger's travel is the same
    /// intention, not a second one.
    private var fired = false
    private var lastEvent: TimeInterval = -.greatestFiniteMagnitude

    /// Feed one scroll delta. Returns a direction exactly once per gesture.
    mutating func feed(
        dx: CGFloat,
        dy: CGFloat,
        began: Bool,
        ended: Bool,
        at time: TimeInterval
    ) -> Direction? {
        if began || time - lastEvent > Self.idleGap { reset() }
        lastEvent = time
        defer { if ended { reset() } }

        travel.dx += dx
        travel.dy += dy
        guard !fired,
              abs(travel.dx) >= Self.threshold,
              abs(travel.dx) >= abs(travel.dy) * Self.dominance else { return nil }
        fired = true
        // Positive `scrollingDeltaX` is content moving right, i.e. a finger
        // moving right — the direction the user would name.
        return travel.dx > 0 ? .right : .left
    }

    mutating func reset() {
        travel = CGVector(dx: 0, dy: 0)
        fired = false
    }
}

/// The surface's springs are `LedgeMotion`'s (Theme.swift) — the house motion
/// table, not a private set. The alias is here so the call sites below still
/// read `spring: .open`; the numbers live in one place.
private typealias Spring = LedgeMotion.Spring

/// **The bottom app strip is gone.**
///
/// `AppStripScrollHintView` and `AppBarView` lived here: a 42 pt row of app
/// icons with a scroller, a **[+]** button and a pinned Settings icon. flow.md
/// has no bar in it — "in a visit, the wings are Ledge's controls" — and the
/// two entry points its death orphaned both have new homes: **[+]** is the
/// strip's blank slot (`SessionStrip`), and Settings is a right-click on any
/// Ledge glass (`ShellSurfaceView.ledgeMenu`). The panel is now content fit plus
/// the cutout exclusion row, and nothing else.

/// Wing content is decoration: it must never intercept the click or the hover
/// that opens the panel, so the container it lives in is transparent to hit
/// testing and everything inside it goes with it.
private class PassthroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// **The wings, in a visit** — the two zones flanking the hardware cutout at the
/// top of the expanded panel. Below the visit they are the app's live-activity
/// areas (`WingBarView`); here they are *Ledge's own controls*, and an app has
/// no say in either of them (flow.md, "Wings, minis, arbitration": "In visit:
/// wings are Ledge's controls only — left: glass toggle …, right: `‹|›`").
///
/// Two properties are the whole point of this view.
///
/// **The row exists by construction.** Every app in the repo opened with a title
/// row, and on a notched Mac the middle of that row was simply invisible:
/// chess's engine name, blocks's key hints, settings' worker count. Reserving
/// the row means an app that renders a top row *cannot* collide with the camera,
/// because its tree starts below it.
///
/// **The controls are notch-anchored, never panel-anchored** (principle 8). Both
/// hug the cutout's dead zone — the toggle's trailing edge against its left
/// side, the walker's leading edge against its right — so a session that is
/// 520 pt wide and one that is 360 pt wide put the same two controls in exactly
/// the same place on screen. Walking the strip therefore never slides a control
/// out from under the pointer, which was the old bar's worst habit.
final class PanelWingBarView: FlippedView {
    /// Which surface the visit is showing, and therefore what the left bead
    /// says. The label always names **where the press goes**, never where you
    /// are: with two full-panel surfaces and one control between them, a label
    /// that named the current surface sends every user the wrong way exactly
    /// once.
    enum Mode: Equatable {
        /// The app is on stage. The bead lowers the glass: **Apps**.
        case stage
        /// The editor is up. The bead raises it again: **Done**.
        case editor
        /// The ledge overview is up. The bead goes back to the session it was
        /// zoomed out of: **Back** (flow.md, §04: "the left wing reads Back —
        /// vague, and it always does the right thing").
        case overview

        var label: String {
            switch self {
            case .stage: "Apps"
            case .editor: "Done"
            case .overview: "Back"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .stage: "Edit with AI"
            case .editor: "Show the app"
            case .overview: "Back to the session"
            }
        }
    }

    private let leftZone = ClippingView()
    private let rightZone = ClippingView()
    private let split: HomeChatSplitView
    /// **‹ Back** — the left island while the chat or the ledge is up (G2.6:
    /// "you're going back to the app; this is cleaner"). One word instead of
    /// two lit zones: from either full-panel surface the only exit that needs
    /// a permanent control is *back*, and the bead says so.
    private let back: LedgeButton
    private let walker: WingWalkerView
    /// The overflow bead, after `‹|›` (G4, Manu: "a hamburger or overflow
    /// menu"): ⋯ popping Pop Out / Settings… / Quit Ledge. It replaced the
    /// bare tear bead — the shell had grown three chrome verbs and a bead per
    /// verb would crowd the wing; a menu holds them without widening it.
    /// Hidden inside the parked window — a window cannot pop out of itself,
    /// and it has the right-click menu for the rest.
    private let tear: LedgeButton
    /// The menu's targets, retained for the view's life — an `NSMenuItem`
    /// does not retain its target.
    private var overflowTargets: [ControlTarget] = []

    /// A press on any island that turns into a downward drag becomes the tear
    /// (G2.7): under the physical notch every visible pixel is an island, so
    /// without this hand-off the surface could not be torn from exactly where
    /// the hand goes. Set by the notch surface; nil in the parked window,
    /// where dragging is how the window moves.
    var onTearDrag: (() -> Void)? {
        didSet {
            split.onDragDown = onTearDrag
            walker.onDragDown = onTearDrag
            back.onDragDown = onTearDrag
            tear.onDragDown = onTearDrag
        }
    }

    /// Whether the overflow bead shows at all (the parked window hides it).
    var showsTear = true {
        didSet {
            tear.isHidden = !showsTear
            needsLayout = true
        }
    }

    /// The overflow, popped under the bead: the shell's three chrome verbs.
    /// A real `NSMenu`, because these are commands and macOS already knows
    /// how to draw, key-navigate and dismiss a list of commands — glass
    /// would be reinventing furniture (the Settings-window rule, in a menu).
    private func popOverflow() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, String?, ControlTarget)] = [
            ("Pop Out", "arrow.up.right.square", overflowTargets[0]),
            ("Settings…", nil, overflowTargets[1]),
            ("Quit Ledge", nil, overflowTargets[2]),
        ]
        for (index, entry) in entries.enumerated() {
            if index > 0, entry.0 == "Quit Ledge" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.0, action: #selector(ControlTarget.fire), keyEquivalent: "")
            item.target = entry.2
            if let symbol = entry.1 {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        // In the BEAD's own space, not the bar's: the bead sits inside
        // `rightZone`, and a frame read in one container popped the menu a
        // container away from the button (G4 on-device). Flip-aware, so the
        // menu hangs under the bead whichever way this view counts y.
        let below = CGPoint(x: 0, y: tear.isFlipped ? tear.bounds.maxY + 2 : -2)
        menu.popUp(positioning: nil, at: below, in: tear)
    }

    /// **Parked, the islands hug the window's edges** (G2.9): [⌂|✦] at the far
    /// left, ‹|› at the far right, flex space between. On the notch they hug
    /// the cutout because the cutout is *there*; in a window the anchor is the
    /// window itself, and controls pinned to phantom camera geometry read as
    /// furniture that forgot where it was.
    var hugsEdges = false {
        didSet {
            guard hugsEdges != oldValue else { return }
            needsLayout = true
        }
    }

    /// The hardware cutout's width and the row's height, pushed in by the
    /// surface before every layout. They are measurements of the display, not
    /// preferences (see `NotchMetrics`).
    var cutoutWidth: CGFloat = NotchMetrics.fallback.closedWidth
    var rowHeight: CGFloat = NotchMetrics.fallback.closedHeight

    init(
        onToggleGlass: @escaping () -> Void,
        onWalk: @escaping (Int) -> Void,
        onOverview: @escaping () -> Void,
        onPark: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        // The left island on the stage is the [⌂|✦] split (Manu's O2
        // conclusion): ⌂ shows the ledge — the word "Apps" opening a chat was
        // the counterintuitive thing — and ✦ lowers the glass. Both are the
        // glass swelling (design.html §01, principle 1's two-tier control law).
        split = HomeChatSplitView(onHome: onOverview, onChat: onToggleGlass)
        // …and on the chat and the ledge it is ‹ Back (G2.6). One action, one
        // wire: `onToggleGlass` already means "leave this full-panel surface
        // for the app" on both — it raises the glass in chat and it is Back's
        // own path out of the overview.
        back = LedgeButton("Back", symbol: "chevron.left", variant: .bead, size: .s) {
            onToggleGlass()
        }
        walker = WingWalkerView(onWalk: onWalk, onOverview: onOverview)
        // The bead itself only *presents*; the verbs live in the menu it pops.
        // The press reaches this bar through a box because the button's
        // handler is fixed at init, before `self` exists to capture.
        let press = OverflowPressBox()
        tear = LedgeButton("", symbol: "ellipsis", variant: .bead, size: .s) {
            press.fire()
        }
        super.init(frame: .zero)
        overflowTargets = [
            ControlTarget(onPark), ControlTarget(onSettings), ControlTarget(onQuit),
        ]
        press.fire = { [weak self] in self?.popOverflow() }
        back.isHidden = true
        back.setAccessibilityLabel("Back to the app")
        tear.setAccessibilityLabel("More — pop out, settings, quit")
        leftZone.addSubview(split)
        leftZone.addSubview(back)
        rightZone.addSubview(walker)
        rightZone.addSubview(tear)
        addSubview(leftZone)
        addSubview(rightZone)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// `mode` picks the left bead's word. `canToggleGlass` hides it entirely for
    /// a surface with no stage to lower — the blank slot (flow.md: "A blank slot
    /// has no stage: chat only, no glass toggle"), the placeholder, the
    /// permission card, and Settings, which is the shell wearing an app's
    /// clothes and has no folder for an agent to edit.
    ///
    /// The right-hand walker is **never** hidden: `‹|›` is how you leave a
    /// surface that has nothing on it, so a surface with nothing on it is
    /// exactly when it must be there.
    func apply(mode: Mode, canToggleGlass: Bool) {
        self.mode = mode
        // On the stage, the split: ⌂ opens the ledge, ✦ lowers the glass. On
        // the chat and the ledge, one word — **Back** (G2.6): from either
        // full-panel surface the exit is the app, and the control says so.
        let showsBack = mode != .stage
        split.isHidden = showsBack
        back.isHidden = !showsBack
        if !showsBack {
            split.apply(homeLit: false, chatLit: false, chatHidden: !canToggleGlass)
        }
        needsLayout = true
    }

    /// The last build status (spec §3.2 `app` states, read through the editor).
    /// The surface uses changes to pulse once; the bead itself stays glass,
    /// because a persistent fill on a permanent control is a status light and
    /// principle 3 rations those to the one moment that warrants them.
    func setBuildStatus(_ status: EditorBuildStatus) {
        buildStatus = status
    }

    private(set) var buildStatus: EditorBuildStatus = .neutral
    private(set) var mode: Mode = .stage

    // MARK: - Geometry

    /// The camera housing plus a margin: nothing is ever drawn here. Clamped to
    /// the row, so a panel narrower than the cutout is all dead zone and both
    /// wings are empty rather than negative.
    var deadZoneRect: CGRect {
        let width = min(cutoutWidth + LedgeMetrics.panelWingCutoutMargin * 2, bounds.width)
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: rowHeight)
    }

    /// Everything left of the dead zone, inset from the **bar's** own end.
    /// `max(0,…)` is the hard clamp: on a screen whose cutout is nearly as wide
    /// as the bar the zone shrinks to nothing and its content clips inside it —
    /// the same discipline the collapsed wings learned the hard way.
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

        // **Hugging the cutout** (Manu's G2.4 conclusion: the controls sit
        // beside the physical notch as floating islands; the bar band is gone
        // and the silhouette is one uniform width). Inner-anchored: the
        // split's trailing edge against the dead zone, the walker's leading
        // edge against its other side. Parked, the anchors flip outward
        // (`hugsEdges`, G2.9): far left and far right, flex space between.
        let toggle = split.intrinsicContentSize
        let toggleWidth = min(ceil(toggle.width), left.width)
        split.frame = CGRect(
            x: hugsEdges ? 0 : max(0, left.width - toggleWidth),
            y: (left.height - toggle.height) / 2,
            width: toggleWidth,
            height: toggle.height
        )

        // ‹ Back takes the split's exact anchorage, so swapping between them
        // never moves the island.
        let backSize = back.intrinsicContentSize
        let backWidth = min(ceil(backSize.width), left.width)
        back.frame = CGRect(
            x: hugsEdges ? 0 : max(0, left.width - backWidth),
            y: (left.height - backSize.height) / 2,
            width: backWidth,
            height: backSize.height
        )

        let walkerSize = walker.intrinsicContentSize
        let walkerWidth = min(walkerSize.width, right.width)
        // The walker's run: itself, plus the tear bead one gap out when shown.
        let tearSize = tear.intrinsicContentSize
        let run = walkerWidth
            + (showsTear ? LedgeMetrics.panelWingGap + tearSize.width : 0)
        let runX = hugsEdges ? max(0, right.width - run) : 0
        walker.frame = CGRect(
            x: runX,
            y: (right.height - walkerSize.height) / 2,
            width: walkerWidth,
            height: walkerSize.height
        )

        // The tear-off bead, after ‹|› (G2.7): its own island, one gap out.
        tear.frame = CGRect(
            x: runX + walkerWidth + LedgeMetrics.panelWingGap,
            y: (right.height - tearSize.height) / 2,
            width: tearSize.width,
            height: tearSize.height
        )
    }

    // MARK: - Test seams

    var splitView: HomeChatSplitView { split }
    var backView: LedgeButton { back }
    var walkerView: WingWalkerView { walker }
    var tearView: LedgeButton { tear }
}

/// The `‹|›` control (design.html §01) — the right wing in a visit.
///
/// **One bead, split.** It used to be two circular `bead` buttons with a
/// hairline parked between them, which read on device as two controls that
/// happened to be adjacent. design.html draws one capsule: a single fill, a
/// single edge ring, and a 1 pt rule dividing it into halves — `‹`, the seam,
/// `›`. So that is what this is: the bead belongs to the control, and only the
/// *zones* have states.
///
/// Three targets in a fixed shape: `‹` walks the strip back, `›` walks it
/// forward, and the `|` between them opens **the ledge** — the zoomed-out
/// overview where sessions are slabs on a shelf (flow.md, "The strip":
/// "Trigger: the `|` divider"). The seam is an eleven-point hit lane rather
/// than the one-point rule you can see, because a one-point target is not a
/// control.
final class WingWalkerView: FlippedView {
    /// Same law as `LedgeButton`: in the parked window, the click that keys the
    /// window is also the press (G2.4).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Which third of the control a point is in. The two halves are the fill;
    /// the seam is a hit lane straddling them, because a one-point click target
    /// is not a control (`LedgeMetrics.walkerDividerLane`).
    enum Zone: Equatable {
        case previous
        case overview
        case next
    }

    private let previous: WalkerZoneView
    private let next: WalkerZoneView
    private let divider = HairlineView()
    private let edge = WalkerEdgeView()
    private let onWalk: (Int) -> Void
    private let onOverview: () -> Void
    private var tracking: NSTrackingArea?
    /// The press turned into a downward drag: the island cancels itself and
    /// hands the gesture to whoever tears (G2.7 — see `PanelWingBarView`).
    var onDragDown: (() -> Void)?

    /// The bead is `s`: the smallest rung of the control ramp, which on a 34 pt
    /// notch row is the only one that fits with air around it.
    private static let bead = LedgeMetrics.Size.s

    init(onWalk: @escaping (Int) -> Void, onOverview: @escaping () -> Void) {
        self.onWalk = onWalk
        self.onOverview = onOverview
        previous = WalkerZoneView(symbol: "chevron.left", label: "Previous session")
        next = WalkerZoneView(symbol: "chevron.right", label: "Next session")
        super.init(frame: .zero)

        // The bead's silhouette is the control's, drawn once: a capsule that
        // clips both halves, with the edge ring stroked around the whole thing.
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        previous.onPress = { onWalk(-1) }
        next.onPress = { onWalk(1) }
        addSubview(previous)
        addSubview(next)
        addSubview(divider)
        addSubview(edge)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Walk the session strip")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.bead.height * 2 + LedgeMetrics.walkerDividerLane,
            height: Self.bead.height
        )
    }

    /// The seam's hit lane, centred on the divider.
    var dividerLaneRect: CGRect {
        CGRect(
            x: (bounds.width - LedgeMetrics.walkerDividerLane) / 2,
            y: 0,
            width: LedgeMetrics.walkerDividerLane,
            height: bounds.height
        )
    }

    func zone(at point: CGPoint) -> Zone? {
        guard bounds.contains(point) else { return nil }
        if dividerLaneRect.contains(point) { return .overview }
        return point.x < bounds.midX ? .previous : .next
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = LedgeMetrics.capsule(bounds.height)
        CATransaction.commit()

        // The two halves meet at the centre: the fill is continuous across the
        // whole bead and the rule is drawn on the seam, so there is one
        // background, not two beads with a gap.
        let half = bounds.width / 2
        previous.frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
        next.frame = CGRect(x: half, y: 0, width: bounds.width - half, height: bounds.height)
        divider.frame = CGRect(
            x: (bounds.width - LedgeMetrics.hairline) / 2,
            y: bounds.height * 0.25,
            width: LedgeMetrics.hairline,
            height: bounds.height * 0.5
        )
        edge.frame = bounds
    }

    // MARK: - Hover, per zone

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
        syncHover()
    }

    override func mouseEntered(with event: NSEvent) { syncHover() }
    override func mouseMoved(with event: NSEvent) { syncHover() }
    override func mouseExited(with event: NSEvent) { syncHover() }

    /// Always measured against the live pointer: enter/exit pairs go stale when
    /// the panel morphs under a stationary cursor (shell/README.md).
    private func syncHover() {
        guard let window else {
            setHovered(nil)
            return
        }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        setHovered(zone(at: point))
    }

    private(set) var hoveredZone: Zone?

    private func setHovered(_ zone: Zone?) {
        guard zone != hoveredZone else { return }
        hoveredZone = zone
        // **The zone under the cursor brightens; the bead does not.** That is
        // the whole point of a split control — a single capsule that lit up as
        // one would be telling the user it is one button.
        previous.isHovered = zone == .previous
        next.isHovered = zone == .next
    }

    // MARK: - The press

    private(set) var pressedZone: Zone?

    /// One `mouseDown` for the whole bead: the zones are painted surfaces, not
    /// controls, so the hit test happens here and nowhere else. That is also
    /// what keeps the seam's 11 pt lane from being stolen by whichever half it
    /// overlaps.
    override func mouseDown(with event: NSEvent) {
        let start = zone(at: convert(event.locationInWindow, from: nil))
        let downY = event.locationInWindow.y
        setPressed(start)
        var inside = start
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                inside = zone(at: point)
                break
            }
            // A press that travels DOWN past the tear threshold is not a press
            // any more — it is the park drag, started on an island (G2.7).
            if let onDragDown, downY - next.locationInWindow.y >= LedgeMetrics.parkTearThreshold {
                setPressed(nil)
                onDragDown()
                return
            }
            // Drag off the zone you pressed and the press lifts, as every other
            // control in the kit does.
            setPressed(zone(at: point) == start ? start : nil)
        }
        setPressed(nil)
        guard let start, inside == start else { return }
        switch start {
        case .previous: onWalk(-1)
        case .next: onWalk(1)
        // The seam: the ledge (flow.md, "The strip").
        case .overview: onOverview()
        }
    }

    private func setPressed(_ zone: Zone?) {
        guard zone != pressedZone else { return }
        pressedZone = zone
        previous.isPressed = zone == .previous
        next.isPressed = zone == .next
    }

    // MARK: - Test seams

    var previousZone: WalkerZoneView { previous }
    var nextZone: WalkerZoneView { next }
    var dividerFrame: CGRect { divider.frame }
}

/// **The [⌂|✦] split** — the left island (Manu's O2 conclusion, G2.4): ⌂ shows
/// the ledge, ✦ lowers the glass. One capsule, two zones, the walker's own
/// anatomy — and the zone whose surface is up stays lit, so the control also
/// answers "where am I".
@MainActor
final class HomeChatSplitView: FlippedView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    enum Zone: Equatable {
        case home
        case chat
    }

    private let home: WalkerZoneView
    private let chat: WalkerZoneView
    private let divider = HairlineView()
    private let edge = WalkerEdgeView()
    private let onHome: () -> Void
    private let onChat: () -> Void
    private var tracking: NSTrackingArea?
    private var chatHidden = false
    /// Same law as the walker's: a downward drag is the park, not a press.
    var onDragDown: (() -> Void)?

    private static let bead = LedgeMetrics.Size.s

    init(onHome: @escaping () -> Void, onChat: @escaping () -> Void) {
        self.onHome = onHome
        self.onChat = onChat
        home = WalkerZoneView(symbol: "house", label: "Show all apps")
        chat = WalkerZoneView(symbol: "bubble.left", label: "Edit with AI")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        home.onPress = onHome
        chat.onPress = onChat
        addSubview(home)
        addSubview(chat)
        addSubview(divider)
        addSubview(edge)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Apps and chat")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: chatHidden
                ? Self.bead.height
                : Self.bead.height * 2 + LedgeMetrics.hairline,
            height: Self.bead.height
        )
    }

    /// Which surface is up — the lit zone — and whether there is any glass to
    /// lower at all (the blank slot keeps ⌂ and loses ✦). Since G2.6 the split
    /// only ever shows on the stage — chat and the ledge wear ‹ Back instead
    /// (`PanelWingBarView`) — so in practice neither zone is ever lit; the
    /// states remain for the law that a lit zone *would* be honest.
    func apply(homeLit: Bool, chatLit: Bool, chatHidden: Bool) {
        home.isLit = homeLit
        chat.isLit = chatLit
        if self.chatHidden != chatHidden {
            self.chatHidden = chatHidden
            chat.isHidden = chatHidden
            divider.isHidden = chatHidden
            invalidateIntrinsicContentSize()
        }
        needsLayout = true
    }

    func zone(at point: CGPoint) -> Zone? {
        guard bounds.contains(point) else { return nil }
        if chatHidden { return .home }
        return point.x < bounds.midX ? .home : .chat
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = LedgeMetrics.capsule(bounds.height)
        CATransaction.commit()
        let half = chatHidden ? bounds.width : bounds.width / 2
        home.frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
        chat.frame = CGRect(x: half, y: 0, width: bounds.width - half, height: bounds.height)
        divider.frame = CGRect(
            x: (bounds.width - LedgeMetrics.hairline) / 2,
            y: bounds.height * 0.25,
            width: LedgeMetrics.hairline,
            height: bounds.height * 0.5
        )
        edge.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
        syncHover()
    }

    override func mouseEntered(with event: NSEvent) { syncHover() }
    override func mouseMoved(with event: NSEvent) { syncHover() }
    override func mouseExited(with event: NSEvent) { syncHover() }

    private func syncHover() {
        guard let window else {
            setHovered(nil)
            return
        }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        setHovered(zone(at: point))
    }

    private(set) var hoveredZone: Zone?

    private func setHovered(_ zone: Zone?) {
        guard zone != hoveredZone else { return }
        hoveredZone = zone
        home.isHovered = zone == .home
        chat.isHovered = zone == .chat
    }

    private(set) var pressedZone: Zone?

    override func mouseDown(with event: NSEvent) {
        let start = zone(at: convert(event.locationInWindow, from: nil))
        let downY = event.locationInWindow.y
        setPressed(start)
        var inside = start
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                inside = zone(at: point)
                break
            }
            if let onDragDown, downY - next.locationInWindow.y >= LedgeMetrics.parkTearThreshold {
                setPressed(nil)
                onDragDown()
                return
            }
            setPressed(zone(at: point) == start ? start : nil)
        }
        setPressed(nil)
        guard let start, inside == start else { return }
        switch start {
        case .home: onHome()
        case .chat: onChat()
        }
    }

    private func setPressed(_ zone: Zone?) {
        guard zone != pressedZone else { return }
        pressedZone = zone
        home.isPressed = zone == .home
        chat.isPressed = zone == .chat
    }

    // MARK: - Test seams

    var homeZone: WalkerZoneView { home }
    var chatZone: WalkerZoneView { chat }
}

/// Half of the split bead: a fill and a glyph, and no silhouette of its own —
/// the capsule and the edge ring belong to `WingWalkerView`. It is deliberately
/// not a `LedgeButton`: a button would bring its own background, its own
/// corner radius and its own press scale, which is exactly the "two beads"
/// defect restated in code.
final class WalkerZoneView: FlippedView {
    private let glyph = NSImageView()
    private let fill = CAGradientLayer()
    /// Run by the walker's own hit test, and by VoiceOver.
    var onPress: (() -> Void)?

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        // A layer's unit square is not flipped with the view, so `0` is the top
        // here exactly as it is in `LedgeButton` — the colour lists below read
        // top-first, the way design.html writes them.
        fill.startPoint = CGPoint(x: 0.5, y: 0)
        fill.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(fill)

        glyph.contentTintColor = LedgeTheme.primary
        addSubview(glyph)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setSymbol(symbol, label: label)
        refresh()
    }

    /// Swap the zone's glyph — the ⌂ becomes ← while the ledge is up (G2.5),
    /// because from there the press means "back to the app", and the icon
    /// should say where the press goes.
    func setSymbol(_ symbol: String, label: String) {
        guard symbol != symbolName else { return }
        symbolName = symbol
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: LedgeMetrics.iconOnlyPointSize,
                    weight: LedgeMetrics.iconOnlyWeight
                )
            )
        setAccessibilityLabel(label)
        needsLayout = true
    }

    /// Which SF Symbol the zone currently wears — the ⌂/← swap's test seam.
    private(set) var symbolName: String?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The walker owns the hit test — the whole bead is one target region split
    /// three ways, and a half that grabbed its own clicks would take the seam's
    /// lane with it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isHovered = false { didSet { guard isHovered != oldValue else { return }; refresh() } }
    /// A persistent "this mode is on" floor (the [⌂|✦] split lights the zone
    /// whose surface is up). Same two tokens as hover — no third colour.
    var isLit = false { didSet { guard isLit != oldValue else { return }; refresh() } }
    var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            refresh()
            // A bead does not shrink — it **sinks** (`LedgeMetrics.beadPressSink`).
            CATransaction.begin()
            CATransaction.setAnimationDuration(
                isPressed ? LedgeMetrics.pressDurationIn : LedgeMetrics.pressDurationOut
            )
            layer?.setAffineTransform(
                isPressed
                    ? CGAffineTransform(translationX: 0, y: LedgeMetrics.beadPressSink)
                    : .identity
            )
            CATransaction.commit()
        }
    }

    /// The fill's stops, top first — the only way to assert a per-zone hover
    /// without a screenshot.
    var fillColors: [NSColor] {
        (fill.colors as? [CGColor] ?? []).compactMap(NSColor.init(cgColor:))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        let size = glyph.image?.size ?? .zero
        glyph.frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    private func refresh() {
        let bright = isHovered || isLit
        let top = bright ? LedgeTheme.beadFillTopHover : LedgeTheme.beadFillTop
        let bottom = bright ? LedgeTheme.beadFillBottomHover : LedgeTheme.beadFillBottom
        // Pressed, the light comes from the wrong side: a swelling lit from the
        // top reads as a dent when the gradient flips, which is what "pushed
        // into the glass" looks like. Same two tokens, reversed — no third
        // colour for a third state (principle 15).
        fill.colors = isPressed
            ? [bottom.cgColor, top.cgColor]
            : [top.cgColor, bottom.cgColor]
    }
}

/// The bead's edge — **one** ring around the whole split control, drawn last so
/// neither half can paint over it: the specular line along the top, the shadow
/// along the bottom, exactly as `LedgeButton`'s bead variant draws them.
private final class WalkerEdgeView: FlippedView {
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.colors = [
            LedgeTheme.beadEdgeHighlight.cgColor,
            LedgeTheme.beadEdgeShadow.cgColor,
        ]
        ring.fillColor = nil
        ring.strokeColor = NSColor.black.cgColor
        ring.lineWidth = LedgeMetrics.beadEdgeWidth
        gradient.mask = ring
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        ring.frame = bounds
        // Stroked *inside* the silhouette, so the ring is the bead's own edge
        // rather than a halo hanging off it.
        let inset = LedgeMetrics.beadEdgeWidth / 2
        let radius = LedgeMetrics.capsule(bounds.height) - inset
        ring.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: max(0, radius),
            cornerHeight: max(0, radius),
            transform: nil
        )
        CATransaction.commit()
    }
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
/// **The wing's stock meter** (spec §3.3 extension) — flow.md's third wing form,
/// made a wire form so that "how far along is it" costs an app one number
/// instead of a draw loop.
///
/// Two layers and no drawing: a track and an ink fill, both capsules, laid out
/// from `fraction`. The ink is design.html §02's `--ink-2`, deliberately **not**
/// the accent — a meter is the state of a thing, not a thing worth a hue
/// (principle 3, "colour is for state changes worth interrupting for").
final class WingMeterView: FlippedView {
    /// Glanceable, never interactive — like every other pixel on the collapsed
    /// pill, whose one gesture is the click that opens the app.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    /// 0…1, already clamped by whoever set it.
    private(set) var fraction: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        trackLayer.backgroundColor = LedgeTheme.track.cgColor
        fillLayer.backgroundColor = LedgeTheme.secondary.cgColor
        trackLayer.cornerCurve = .continuous
        fillLayer.cornerCurve = .continuous
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(fraction newFraction: CGFloat) {
        let clamped = max(0, min(1, newFraction))
        guard clamped != fraction else { return }
        fraction = clamped
        needsLayout = true
        layout()
    }

    /// Where the two capsules ended up, for the geometry assertions.
    var trackFrame: CGRect { trackLayer.frame }
    var fillFrame: CGRect { fillLayer.frame }

    override func layout() {
        super.layout()
        // A meter re-drawn at 4 Hz must not cross-fade its own fill: the value
        // moving IS the animation (L6), and an implicit one lags behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = min(LedgeMetrics.wingMeterHeight, bounds.height)
        let track = CGRect(
            x: 0,
            y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width),
            height: height
        )
        trackLayer.frame = track
        trackLayer.cornerRadius = LedgeMetrics.capsule(height)
        fillLayer.frame = CGRect(
            x: track.minX,
            y: track.minY,
            width: (track.width * fraction).rounded(),
            height: height
        )
        fillLayer.cornerRadius = LedgeMetrics.capsule(height)
        CATransaction.commit()
    }
}

private final class WingBarView: PassthroughView {
    let label: LedgeText
    let canvas: ProtocolCanvasView
    let meter = WingMeterView()

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
        addSubview(meter)
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
        let rightWing = CGRect(
            x: bounds.width - right + Self.pad,
            y: 0,
            width: max(0, right - Self.pad * 2),
            height: height
        )
        canvas.frame = rightWing
        // The meter shares the right wing with the canvas and never both at
        // once (`setWing` hides one of them), so it can have the same box: the
        // bar itself is 3 pt, centred inside it by `WingMeterView`.
        meter.frame = rightWing
    }
}

/// The whole shell is one fixed-size transparent window; this view morphs a
/// black notch shape inside it with springs. The window frame never animates —
/// that is what keeps open/close buttery.
final class ShellSurfaceView: FlippedView {
    static let fillet: CGFloat = 12
    private static let expandedBottomRadius: CGFloat = 26
    private static let collapsedBottomRadius: CGFloat = 12
    /// Between the two, because a swell is between the two: the panel's 26 on a
    /// ~60 pt card reads as a lozenge, the pill's 12 as a cut-off panel.
    private static let swellBottomRadius: CGFloat = 18

    var metrics: NotchMetrics = .fallback {
        didSet {
            guard metrics != oldValue else { return }
            applyGeometry(spring: nil)
        }
    }

    /// What the screen allows. Only used to clamp wing widths here — panel
    /// width/height arrive already clamped via `present`.
    var limits: PanelLimits = .fallback

    /// The pointer crossed into, or out of, the shape. The surface reports the
    /// fact and nothing else: Th, Texit and what a hover *means* all belong to
    /// the interaction machine, which the panel controller drives.
    var onPointerInside: ((Bool) -> Void)?
    /// A click landed on Ledge's own glass — the pill, a wing, a swell, or the
    /// panel outside the app's content. Who it is addressed to is the machine's
    /// answer (flow.md's Transitions table), not this view's.
    var onClick: (() -> Void)?
    /// Esc, with a visit up.
    var onEscape: (() -> Void)?
    /// A horizontal swipe. Below the visit it is nothing (principle 9 leaves the
    /// collapsed pill exactly one gesture: the click); in a visit it walks the
    /// session strip, which is the same code path `‹|›` uses.
    var onSwipe: ((SwipeRecognizer.Direction) -> Void)?
    /// The context menu for Ledge glass — Settings… and Quit Ledge (flow.md,
    /// Edges). Supplied by the controller, which owns both actions.
    var contextMenu: (() -> NSMenu?)?

    // MARK: - Tearing the surface off the notch (flow.md: Visit → Parked)

    /// The drag crossed the tear threshold: the whole surface comes off, and the
    /// argument is where the torn body's **top-left corner** belongs on screen
    /// so it stays exactly under the fingers that pulled it.
    var onTearBegan: ((CGPoint) -> Void)?
    /// The same corner, on every subsequent drag event.
    var onTearMoved: ((CGPoint) -> Void)?
    /// The fingers let go. The window stays where it was dropped.
    var onTearEnded: (() -> Void)?

    private var swipe = SwipeRecognizer()

    /// Expanded panel height. Always measured, never scripted: it is the
    /// presented tree's fitting height plus the strip (spec §5), or the fixed
    /// height of a chrome surface (chat / [+] / the placeholder card).
    private(set) var expandedHeight: CGFloat = HostPlaceholderView.panelHeight
    /// Expanded panel width — 440 unless the presented app declared another one
    /// in `meta.panel.width` (already clamped by `PanelLimits`).
    private(set) var expandedWidth: CGFloat = PanelLimits.defaultWidth

    /// The swell's measured size, kept separately from the panel's so that a
    /// notification and a later visit each morph from their own last shape
    /// rather than inheriting the other's.
    private(set) var swellSize = CGSize(width: 260, height: 64)

    /// Whether the cutout exclusion row is reserved. True for the panel *and*
    /// both swells: all three hang from the top of the screen, so all three
    /// would otherwise draw their first row underneath the camera (principle 7 —
    /// "the physical notch is an exclusion zone"). False for the pill, which
    /// *is* the cutout and has nothing to exclude.
    private var reservesCutoutRow: Bool {
        presentation.isExpanded || presentation.isSwell
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

    /// What the panel body is made of. Solid black glass everywhere except chat
    /// mode, where it runs opaque at the top to nearly clear at the bottom so
    /// the prompt pill sits on the clearest glass there is (flow.md, Material).
    enum BodyMaterial: Equatable {
        case solid
        case chatGlass
    }

    private(set) var bodyMaterial: BodyMaterial = .solid

    /// Set the body's material. Called from `refresh`, like `setPanelWing`: a
    /// material that has not changed is a cheap no-op, and the alternative is
    /// two places that both believe they know which surface is up.
    func setBodyMaterial(_ material: BodyMaterial) {
        guard material != bodyMaterial else { return }
        bodyMaterial = material
        applyGeometry(spring: nil)
    }

    private let shapeLayer = CAShapeLayer()
    /// The chat pane's glass, painted into the same silhouette `shapeLayer`
    /// strokes. Hidden — and the shape solidly filled — in every other mode.
    private let bodyGlass = CAGradientLayer()
    private let bodyGlassMask = CAShapeLayer()
    /// **The frost behind the glass** (flow.md, Material; deferred out of C1
    /// pending a judgement on device, and the judgement came back "needed").
    ///
    /// The gradient alone is a tint, and a tint over a bright window is still
    /// that window: at the bottom of the pane the old floor was 18% of a
    /// near-black, so a striped or high-contrast background came through at
    /// almost full strength and the prompt was unreadable. Blur is what actually
    /// destroys the detail underneath; the gradient then only has to supply
    /// contrast, not hide anything.
    ///
    /// It is a *view* rather than a layer because behind-window blur is a
    /// window-server effect with no CALayer equivalent, and it is masked to the
    /// same silhouette everything else is cut to, so the body stays one shape.
    private let bodyFrost = FrostView()
    /// Keeps the panel's shadow **outside** the silhouette. Opaque glass hid it
    /// for free; glass you can see through does not, and a shadow visible
    /// through its own body is the one thing that would make the bottom of the
    /// chat pane read as dirty rather than clear.
    private let shadowMask = CAShapeLayer()
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
    private var currentContent: NSView?
    private(set) var presentation: ShellPresentation = .collapsed
    /// The promissory swell (flow.md: "hover < Th → a small promissory swell,
    /// nothing more"). A few points of notch, and no surface at all.
    private var promising = false
    private var pointerInside = false
    /// Whether the cursor is on the shape right now. Read by the panel
    /// controller so a notification's dwell does not expire out from under a
    /// user who is looking straight at it.
    var isHovered: Bool { pointerInside }
    /// Whether a drag is in flight over the surface — one of the three things
    /// that stop the walk-away timer (`ExitInhibitor`).
    private(set) var isDragInFlight = false
    private var trackingArea: NSTrackingArea?

    init(callbacks: ShellCallbacks) {
        // The visit's two controls (flow.md: in a visit the wings are Ledge's).
        // The left bead lowers the glass onto the conversation; the right pair
        // walks the session strip. Both are the shell's, on every session.
        self.panelWingBar = PanelWingBarView(
            onToggleGlass: callbacks.toggleChat,
            onWalk: callbacks.walkStrip,
            onOverview: callbacks.showOverview,
            onPark: callbacks.park,
            onSettings: callbacks.openSettings,
            onQuit: callbacks.quit
        )
        super.init(frame: .zero)
        // Any island press that turns into a downward drag becomes the tear
        // (G2.7): the islands cover the glass beside the cutout, so they must
        // hand the gesture over or the park drag has nowhere to start.
        panelWingBar.onTearDrag = { [weak self] in self?.adoptTear() }

        wantsLayer = true
        layer?.masksToBounds = false

        shapeLayer.fillColor = NSColor.black.cgColor
        // The panel rung of the shadow ramp (Theme.swift). Geometry only — the
        // opacity is a *state* (`updateShadow`), because a collapsed notch casts
        // nothing at all and the fade between is the personality.
        LedgeShadow.panel.applyGeometry(to: shapeLayer)
        shapeLayer.shadowOpacity = 0
        layer?.addSublayer(shapeLayer)

        // The frost sits **under** everything: behind the gradient, behind the
        // content, behind the rim. It is a subview rather than a sublayer, so it
        // goes in before `contentContainer` and stays at index 0.
        //
        // Two settings are load-bearing and neither is the default:
        //
        //   · `state = .active`. Ledge's panel is a `.nonactivatingPanel` and is
        //     therefore *never* the active window. The default
        //     `.followsWindowActiveState` would switch the blur off permanently
        //     and the frost would be an expensive no-op — which is exactly how a
        //     masked vibrancy attempt in a non-activating panel "proves
        //     impossible" if this line is missing.
        //   · `blendingMode = .behindWindow`. Within-window blending frosts the
        //     shell's own content; what has to be destroyed is the desktop
        //     behind it.
        bodyFrost.material = .hudWindow
        bodyFrost.blendingMode = .behindWindow
        bodyFrost.state = .active
        bodyFrost.isHidden = true
        // Force the backing layer into existence now, so the `zPosition` below
        // has something to be set on: AppKit creates a subview's layer lazily,
        // and an ordering applied to a nil layer is a no-op that reads like a
        // fix.
        bodyFrost.wantsLayer = true
        addSubview(bodyFrost)
        // **Behind the gradient, explicitly.**
        //
        // Adding it first is not enough and the ordering is not a detail: the
        // body's material, the rim light and the attention glow are *sublayers
        // of this view's own layer*, while the frost is a **subview**, and
        // AppKit appends every subview's backing layer after all of them. So the
        // frost drew on top — a slab of blurred material over the gradient it
        // was supposed to sit under, covering the rim light on its way past.
        //
        // `zPosition` is the one ordering that is actually defined across both
        // kinds of sibling. Everything else here sits at 0, so a single negative
        // rung puts the frost under all of it and leaves their order alone.
        //
        bodyFrost.layer?.zPosition = Self.frostZPosition

        // Above the shape, below the rim light: the glass replaces the fill, it
        // does not sit on top of the edge.
        bodyGlass.isHidden = true
        bodyGlass.startPoint = CGPoint(x: 0.5, y: 0)
        bodyGlass.endPoint = CGPoint(x: 0.5, y: 1)
        bodyGlass.mask = bodyGlassMask
        layer?.addSublayer(bodyGlass)

        shadowMask.fillRule = .evenOdd
        shadowMask.fillColor = NSColor.black.cgColor

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

        // **Not inside the content container.** The bar is a fixed width and a
        // fixed place — it does not spring with the panel, because it does not
        // change (principle 8) — and when the panel is narrower than the bar it
        // reaches past the container on both sides. Added after it, so the
        // reserved row is never overdrawn by an app whose tree is taller than
        // the box it was given.
        panelWingBar.isHidden = true
        addSubview(panelWingBar)

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
        shapeSize(expanded: expanded, width: width, height: height, promising: false)
    }

    private func shapeSize(
        expanded: Bool,
        width: CGFloat,
        height: CGFloat,
        promising: Bool
    ) -> CGSize {
        let fillets = Self.fillet * 2
        guard expanded else {
            let wings = wingExtents
            // The promise grows the notch down *and* out — a swell, in miniature
            // (principle 7). The old `hoverBumpWidth` was 14 pt of pure width
            // and it was announcing an open the hover was about to perform;
            // this announces nothing but that the notch noticed.
            return CGSize(
                width: metrics.closedWidth + wings.left + wings.right + fillets
                    + (promising ? LedgeInteraction.promiseWidth : 0),
                height: metrics.closedHeight + (promising ? LedgeInteraction.promiseHeight : 0)
            )
        }
        // **One uniform width, top to bottom** (Manu's G2.4 conclusion): the
        // bar band is gone — the controls float beside the cutout as their own
        // islands — so the shape is the panel, floored at the islands' own
        // span. The floor is the G2.5 lesson: without it a 320 pt session left
        // the islands hanging past the glass over bare wallpaper, and every
        // open and close morphed a shape that never reached its own controls.
        return CGSize(width: max(width, visitBarWidth) + fillets, height: height)
    }

    /// **The visit bar's width — a constant.**
    ///
    /// It is the cutout plus a fixed reach on each side (`visitBarWing`), so it
    /// is the same on every session and every panel: the widest session and the
    /// narrowest put Ledge's two controls in exactly the same two places on
    /// screen (principle 8, and principle 15's "stated once"). The only thing
    /// that can change it is the display's own cutout.
    var visitBarWidth: CGFloat {
        metrics.closedWidth + LedgeMetrics.visitBarWing * 2
    }

    /// Where the bar sits: centred on the cutout, `panelWingRowHeight` tall.
    /// Measured from `bounds` rather than from the shape, because the shape is
    /// the one thing here that a session is allowed to change.
    var visitBarRect: CGRect {
        CGRect(
            x: (bounds.width - visitBarWidth) / 2,
            y: 0,
            width: visitBarWidth,
            height: panelWingRowHeight
        )
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
        } else if wing.meter != nil {
            // The meter's width is the shell's, not the app's (that is what
            // makes it a form rather than a canvas with a shorter spelling).
            right = min(LedgeMetrics.wingMeterWidth + WingBarView.pad * 2, maxWing)
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
        // A swell is centred on the cutout like the panel, not anchored beside
        // it like the pill: it is the notch itself growing down and out, so it
        // has to stay symmetric about the camera.
        if presentation.isSwell {
            return CGRect(
                x: (bounds.width - swellSize.width) / 2,
                y: 0,
                width: swellSize.width,
                height: swellSize.height
            )
        }
        let promise = promising && !presentation.isExpanded
        let size = shapeSize(
            expanded: presentation.isExpanded,
            width: expandedWidth,
            height: expandedHeight,
            promising: promise
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
                - (promise ? LedgeInteraction.promiseWidth / 2 : 0),
            y: 0,
            width: size.width,
            height: size.height
        )
    }

    /// Where the shape currently is inside this view — what a snapshot crops to,
    /// and (collapsed) not the centre of the view: see `shapeRect`.
    var currentShapeRect: CGRect { shapeRect }

    /// The outline the body is currently cut to. A test seam for the one law
    /// `notchPath` exists to keep — that every presentation produces the *same
    /// element sequence*, so CoreAnimation can interpolate between any two of
    /// them (`ShapeMorphTests`).
    var currentSilhouette: CGPath {
        shapeLayer.path ?? CGMutablePath()
    }

    private var bodyRect: CGRect {
        shapeRect.insetBy(dx: Self.fillet, dy: 0)
    }

    /// The body — the shape inset by its fillets, in every presentation. Since
    /// G2.4 the silhouette is one uniform width top to bottom, so there is no
    /// separate "panel body": a session narrower than the floor gets a wider
    /// pane of glass and its *content* centres inside it (`applyGeometry`),
    /// which is what keeps the shoulder joint permanently degenerate and the
    /// open morph a pure lerp.
    private var panelBodyRect: CGRect { bodyRect }

    /// The shape, and only the shape: where the pointer counts as *on* Ledge,
    /// and the interactive (hit-testable) region.
    ///
    /// It used to carry four slop margins — 26 pt around the open panel, 8 and 6
    /// around the pill — because leaving the region *closed the panel* and the
    /// forgiveness was load-bearing. Nothing leaving the region does now closes
    /// anything on its own: it starts a 2.5 s timer that any keystroke, drag or
    /// running tool suspends (`ExitInhibitor`). "Pointer fully away" (flow.md)
    /// therefore means what it says, and a slop margin would only make the
    /// hit-testable pill bigger than the pill.
    ///
    /// Since G2.4 the silhouette is one uniform width, so the shape *is* the
    /// glass: no L-shaped corners of nothing to punch through any more.
    func isOnGlass(_ point: CGPoint) -> Bool {
        shapeRect.contains(point)
    }

    override func layout() {
        super.layout()
        applyGeometry(spring: nil)
    }

    // MARK: - Presentation

    /// Show a surface. `content` is whatever fills the panel below the cutout
    /// exclusion row — a host-rendered app tree, a chrome surface, or the
    /// placeholder card; `height` is the whole panel's height including it.
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
        if newPresentation.isSwell { swellSize = CGSize(width: width, height: height) }
        // A surface arriving takes the promise's place: the notch has stopped
        // promising and started delivering.
        promising = false

        setAccessibilityLabel("Ledge notch panel, \(Self.describe(newPresentation))")

        // Arrivals **pop**, returns **settle** (design.html §07, F1's motion
        // table). A swell is an arrival exactly as much as the panel is, so
        // growing into one pops and retracting out of one settles — a swell
        // that bounced on the way out would read as a glitch.
        let spring: Spring? = if !animated {
            nil
        } else if !old.isExpanded && newPresentation.isExpanded {
            .open
        } else if old.isExpanded && !newPresentation.isExpanded {
            .close
        } else if !old.isConversation && newPresentation.isConversation {
            // The transcript pane arriving over the stage is an arrival like any
            // other, and it pops. Leaving settles — the glass lifting off the
            // app is a return, and returns are always calmer.
            .open
        } else if old.isConversation && !newPresentation.isConversation {
            .close
        } else if !old.isSwell && newPresentation.isSwell {
            .pop
        } else if old.isSwell && !newPresentation.isSwell {
            .settle
        } else {
            .morph
        }
        lastSpring = spring
        applyGeometry(spring: spring)
        if !sameContent {
            swapContent(content ?? FlippedView(), animated: animated)
        }
        syncIslandArrival(from: old, animated: animated)
        updateShadow(animated: animated)

        // The shape just changed under a possibly-stationary cursor; resync so
        // a stale inside/outside belief cannot wedge the machine.
        if window != nil {
            evaluatePointer()
        }
    }

    /// Height of the row the expanded panel reserves for the hardware cutout —
    /// the panel wings live in it, and the app's tree starts below it. It is the
    /// cutout's own height because that is exactly how much of the panel the
    /// camera housing covers; on a screen with no cutout it is the menu-bar
    /// height, which is the same measurement (`NotchMetrics`).
    var panelWingRowHeight: CGFloat { metrics.closedHeight }

    /// Set the visit's two controls (flow.md: in a visit the wings are Ledge's).
    ///
    /// Called on every refresh rather than diffed here — a mode that has not
    /// changed is a cheap no-op inside the bar, and the alternative is two
    /// places that both believe they know which surface is up.
    func setPanelWing(mode: PanelWingBarView.Mode, canToggleGlass: Bool) {
        panelWingBar.apply(mode: mode, canToggleGlass: canToggleGlass)
    }

    /// Put a wing up on the collapsed notch, or take it down with `nil` (spec
    /// §3.3 extension). Repeated width updates at 2–10 Hz are the normal case
    /// (a breathing pacer, a live meter): each one re-springs the shape from
    /// wherever the previous animation had got to, so "latest wins" is the
    /// coalescing rule and the morph spring is the only thing driving width.
    /// The promissory swell stays additive on top and is never fought over.
    func setWing(_ spec: WingSpec?, animated: Bool = true) {
        let next = spec.flatMap { $0.isEmpty ? nil : $0 }
        guard next != wing else { return }
        wing = next
        wingBar.label.stringValue = next?.text ?? ""
        wingBar.label.isHidden = next?.text == nil
        wingBar.canvas.isHidden = next?.canvas == nil
        // One right wing, two ways to fill it: the canvas wins when an app asks
        // for both (its own pixels beat a shape the shell drew), so the meter is
        // shown only when nothing else has claimed the strip.
        let meter = next?.canvas == nil ? next?.meter : nil
        wingBar.meter.isHidden = meter == nil
        wingBar.meter.apply(fraction: CGFloat(meter?.fraction ?? 0))
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

    /// The label that lives in the left wing. Paired with `wingCanvasView`:
    /// between them they are everything a wing can contain, and where they
    /// landed is the thing worth asserting about wing geometry.
    var wingLabelView: NSTextField { wingBar.label }

    /// The right wing's stock meter (spec §3.3 extension). Paired with
    /// `wingCanvasView`: they are the two things that can occupy that wing, and
    /// which one is up is the assertion worth making.
    var wingMeterView: WingMeterView { wingBar.meter }

    /// `attention` (spec §3.3): a glow on the notch, no notification. Deliberately
    /// short and additive — it does not touch the shape, the hover state, or any
    /// of the feel tunables.
    func flashAttention() {
        flashGlow(color: LedgeTheme.accent, values: [0, 0.9, 0, 0.7, 0], keyTimes: [0, 0.15, 0.45, 0.6, 1])
    }

    /// Build status, read from spec §3.2's app states. Records it and — only on
    /// a genuine change — pulses the panel once in the matching hue.
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

    /// The strip's end refused a walk: flinch (see `NSView.runEndBounce`).
    func bounceAtEnd(toward steps: Int) {
        endBounceCount += 1
        runEndBounce(toward: steps)
    }

    /// Test seam: refusals are motion, and motion is invisible headlessly.
    private(set) var endBounceCount = 0

    /// Test seam: which house spring the last presentation used. "Arrivals pop,
    /// returns settle" (principle 10, design.html §07) is a law, and a law that
    /// nothing can observe is a comment.
    private(set) var lastSpring: LedgeMotion.Spring?

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
        let body = panelBodyRect
        let bottomRadius: CGFloat = if presentation.isExpanded {
            Self.expandedBottomRadius
        } else if presentation.isSwell {
            Self.swellBottomRadius
        } else {
            Self.collapsedBottomRadius
        }
        // One path for every shape (principle 6, "one material, one body"): the
        // swell is the same silhouette as the pill and the panel, at a size
        // between them, so the notch visibly *grows* into it rather than having
        // a card appear underneath it. A visit adds one joint to that silhouette
        // — the shoulder where a narrow panel hangs off a wider bar — and it is
        // part of the same path, so the two are one body and not two shapes that
        // happen to touch.
        // **The joint is always present**, on every presentation — see
        // `notchPath`. A pill and a full-width panel have `panel.minX == barLeft`
        // and a zero radius, so the joint is a straight edge and draws nothing;
        // what it buys is that the path the pill animates *from* and the path the
        // visit animates *to* have the same segments in the same order, which is
        // the only condition under which CoreAnimation's path interpolation
        // produces a shape rather than a smear.
        //
        // `y` is clamped into the span the side actually spans so a short shape
        // (the 34 pt pill) cannot put the joint below its own bottom fillet, and
        // it stays at `panelWingRowHeight` wherever there is room — including on
        // a panel wider than the bar, so that walking between a narrow session
        // and a wide one slides the joint's *radius* to zero instead of also
        // teleporting its depth.
        let shoulder = BarShoulder(
            panel: body,
            y: min(panelWingRowHeight, max(Self.fillet, shape.height - bottomRadius)),
            // Always degenerate since G2.4: the silhouette is one uniform width
            // (no bar band), but the joint stays in the path so every
            // presentation keeps the same element signature and the morph
            // never smears (the F2.1 law).
            radius: 0
        )
        let path = Self.notchPath(
            in: shape,
            topRadius: Self.fillet,
            bottomRadius: bottomRadius,
            shoulder: shoulder
        )

        let previousPath = shapeLayer.presentation()?.path ?? shapeLayer.path
        let previousShadowPath = shapeLayer.presentation()?.shadowPath ?? shapeLayer.shadowPath
        let previousContentPosition = contentContainer.layer?.presentation()?.position
            ?? contentContainer.layer?.position
        let previousContentBounds = contentContainer.layer?.presentation()?.bounds
            ?? contentContainer.layer?.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.path = path
        shapeLayer.shadowPath = path
        rimLayer.path = path
        glowLayer.path = path
        dropLayer.path = path
        rimMask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(shape.height, 1))
        applyBodyMaterial(path: path, shape: shape)
        contentContainer.frame = CGRect(
            x: body.minX,
            y: 0,
            width: body.width,
            height: shape.height
        )
        // Wings only exist on the collapsed pill; expanded — or swelled — the
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
        // The row is *reserved* on a swell but stays empty: the two controls
        // belong to the visit. A swell is a glance, and a glance with chrome on
        // it is a panel that forgot to open. The reservation itself is not
        // optional — it is what keeps the payload strictly below the cutout
        // (principle 7).
        //
        // **A constant frame.** The bar is `visitBarRect` and nothing else: not
        // the panel's width, not the container's. Walking from a 360 pt session
        // to a 640 pt one moves neither control by a point, which is the whole
        // of principle 8 and the thing that felt wrong on device.
        panelWingBar.isHidden = !presentation.isExpanded
        panelWingBar.cutoutWidth = metrics.closedWidth
        panelWingBar.rowHeight = panelWingRowHeight
        panelWingBar.frame = presentation.isExpanded
            ? visitBarRect
            : CGRect(x: visitBarRect.minX, y: 0, width: visitBarRect.width, height: exclusion)
        panelWingBar.needsLayout = true
        // The session's content keeps its own declared width, centred in the
        // floored glass (G2.5): a 320 pt app in a 390 pt visit is a 320 pt app
        // with glass either side, never a stretched one.
        let contentWidth = presentation.isExpanded
            ? min(expandedWidth, contentContainer.bounds.width)
            : contentContainer.bounds.width
        contentHost.frame = CGRect(
            x: (contentContainer.bounds.width - contentWidth) / 2,
            y: exclusion,
            width: contentWidth,
            height: max(0, contentContainer.bounds.height - exclusion)
        )
        contentContainer.layoutSubtreeIfNeeded()
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
    }

    /// Fill the silhouette — solidly, or with the chat pane's glass.
    ///
    /// The gradient's stops are stated as fractions of the **body**, so they are
    /// remapped past the cutout exclusion row here: that row is the notch
    /// itself, it is hardware, and nothing about it is ever translucent.
    private func applyBodyMaterial(path: CGPath, shape: CGRect) {
        let glass = bodyMaterial == .chatGlass && presentation.isExpanded && shape.height > 0
        shapeLayer.fillColor = glass ? nil : NSColor.black.cgColor
        shapeLayer.mask = glass ? shadowMask : nil
        bodyGlass.isHidden = !glass
        // **Only when there is something behind to blur.**
        //
        // `.behindWindow` blending is a window-server effect: with no window
        // there is no "behind", and every offscreen renderer — `cacheDisplay`,
        // the snapshot pipeline, the alpha probes in `ChatModeTests` — gets the
        // material's opaque fallback colour instead. That turns the chat pane
        // into a flat grey block in exactly the pictures the surface is reviewed
        // from, and it would be reviewing a thing the product never shows.
        //
        // So the frost is a property of being *on screen*, which is the only
        // place it means anything. `viewDidMoveToWindow` re-runs this.
        bodyFrost.isHidden = !glass || window == nil
        // See the note where the frost is added: the backing layer only exists
        // once the view is in a layer-backed hierarchy, so this is the first
        // place the ordering can actually be set.
        bodyFrost.layer?.zPosition = Self.frostZPosition
        guard glass else { return }

        let bar = min(1, panelWingRowHeight / shape.height)
        bodyGlass.frame = CGRect(x: 0, y: 0, width: bounds.width, height: shape.height)
        bodyGlassMask.frame = bodyGlass.bounds
        bodyGlassMask.path = path

        // The frost takes the same rectangle and the same outline. `maskImage`
        // is the only way to give an `NSVisualEffectView` a shape — the blur is
        // composited by the window server, so a CALayer mask on it does nothing
        // — and it is regenerated here rather than cached because the shape
        // changes on every session, every mode and every frame of the open.
        bodyFrost.frame = bodyGlass.frame
        bodyFrost.maskImage = Self.maskImage(for: path, size: bodyFrost.bounds.size)
        // The bar row, then the body's own ramp. The first stop is the notch:
        // opaque, and the same black the pill is made of.
        bodyGlass.colors = [NSColor.black.cgColor]
            + LedgeGlass.chat.map { $0.color.cgColor }
        bodyGlass.locations = [0]
            + LedgeGlass.chat.map { NSNumber(value: Double(bar + (1 - bar) * $0.at)) }

        // Everything outside the shape, and nothing inside it: the shadow is
        // cast by the body rather than painted underneath it.
        let inverse = CGMutablePath()
        inverse.addRect(bounds)
        inverse.addPath(path)
        shadowMask.frame = bounds
        shadowMask.path = inverse
    }

    /// The frost exists only while the surface is in a window (see
    /// `applyBodyMaterial`), so arriving in one — or leaving — has to repaint
    /// the body material. Nothing else here depends on the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyGeometry(spring: nil)
    }

    /// One rung below every other layer in the body. See `applyBodyMaterial`.
    static let frostZPosition: CGFloat = -1

    /// An alpha mask in the shape of the silhouette, for `NSVisualEffectView`.
    ///
    /// Drawn flipped, because the path is stated in the surface's own y-down
    /// coordinates and `maskImage` is interpreted bottom-up like every other
    /// `NSImage`. `capInsets` is deliberately left at zero and the image is
    /// built at the exact size it will be used: the shape has a shoulder in the
    /// middle of it, so there is no stretchable centre to nominate.
    static func maskImage(for path: CGPath, size: CGSize) -> NSImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        return NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
            return true
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
        // A view arriving here may have been dimmed on its way *out* of a
        // previous swap, or parked in some other host. It is the content now.
        next.alphaValue = 1
        contentHost.addSubview(next)

        // **Only tear down what this host actually owns.**
        //
        // The stage composite is shared: entering chat, the controller hands it
        // to `ChatSurfaceView.setStage` — which reparents it into the stage well
        // — and *then* presents the chat pane here. `previous` is that composite,
        // and it is no longer ours. Fading and removing it emptied the well the
        // instant chat opened, which is why the live app was a black rectangle
        // on device while every snapshot (a fresh pane, no prior content) was
        // fine. Ownership is `superview`, and nothing else.
        let owned = previous?.superview === contentHost

        guard animated else {
            if owned { previous?.removeFromSuperview() }
            return
        }

        // G2.4's recipe, verbatim from the device test: "shut the current app
        // altogether to get a black surface of the same size, then resize with
        // animation, then mount the new app." The old content leaves at once —
        // bare glass, no half-faded tree stretching under the spring — the
        // silhouette does its move, and the new tree fades up as it lands.
        if let previous, owned {
            previous.removeFromSuperview()
            previous.alphaValue = 1
        }

        next.alphaValue = 0
        next.setFrameOrigin(CGPoint(x: 0, y: 6))
        let settle = min(0.30, (lastSpring?.response ?? 0.2) * 0.75)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self, weak next] in
            guard let next, next === self?.currentContent else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                next.animator().alphaValue = 1
                next.animator().setFrameOrigin(.zero)
            }
        }
    }

    /// The islands join the G2.4 arrival recipe: on an open the silhouette does
    /// its move bare, and the controls fade up on the same beat as the content.
    /// A bar that popped in at full strength while the glass was still growing
    /// under it read as chrome detached from the body — half of the G2.5
    /// "open and close transforms are broken" report.
    private func syncIslandArrival(from old: ShellPresentation, animated: Bool) {
        guard presentation.isExpanded else { return }
        guard animated, !old.isExpanded else {
            panelWingBar.alphaValue = 1
            return
        }
        panelWingBar.alphaValue = 0
        let settle = min(0.30, (lastSpring?.response ?? 0.2) * 0.75)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, self.presentation.isExpanded else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                self.panelWingBar.animator().alphaValue = 1
            }
        }
    }

    private func updateShadow(animated: Bool) {
        // Which rung of the ramp is lit, not a bespoke alpha: an open panel
        // hangs off the wall (`panel`), a swell — either swell, and the promise
        // of one — is barely off it (`swell`), and a collapsed notch casts
        // nothing at all.
        let opacity: Float = if presentation.isExpanded {
            LedgeShadow.panel.opacity
        } else if presentation.isSwell || promising {
            LedgeShadow.swell.opacity
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
        case .mini(let app): "\(app) notification"
        case .summary(let app): "\(app) summary"
        case .expanded(let app): app ?? "no host"
        case .chat(let app): "\(app) chat"
        case .newApp: "new session"
        case .overview: "the ledge"
        }
    }

    // MARK: - The pointer
    //
    // The tracking-area plumbing below is the old hover machine's, kept whole:
    // measuring the live pointer instead of trusting a stale exit event is the
    // one thing that code got right and the reason it is still here. What is
    // gone is everything it used to *decide* — an open delay, a close delay, a
    // morph grace. This view now reports one bit (inside / outside) and the
    // interaction machine decides what a hover means (flow.md's Transitions).

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
        evaluatePointer()
    }

    override func mouseMoved(with event: NSEvent) {
        evaluatePointer()
    }

    override func mouseExited(with event: NSEvent) {
        evaluatePointer()
    }

    /// Tracking events can carry coordinates relative to whichever window is
    /// key, and exit events go stale while the shape morphs under a stationary
    /// cursor — so always test the live global pointer position instead.
    private func evaluatePointer() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        setPointerInside(isOnGlass(convert(windowPoint, from: nil)))
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside, !presentation.isExpanded { haptic() }
        onPointerInside?(inside)
    }

    /// Show — or take back — the promissory swell (flow.md: "hover < Th → a
    /// small promissory swell of the notch, nothing more").
    ///
    /// **pop** in, **settle** out, per F1's motion table: the promise is an
    /// arrival, and withdrawing it is a return. Never on the expanded panel,
    /// which is not a notch to swell.
    func setPromise(_ on: Bool) {
        guard on != promising, !presentation.isExpanded, !presentation.isSwell else { return }
        promising = on
        applyGeometry(spring: on ? .bump : .settle)
        updateShadow(animated: true)
    }

    /// Test seam: is the notch currently promising?
    var isPromising: Bool { promising }

    /// Test seam: which rung of the shadow ramp is lit. Not observable in a
    /// headless layout pass any other way, and "a swell casts the swell shadow"
    /// is exactly the kind of claim that quietly stops being true.
    var shadowOpacity: Float { shapeLayer.shadowOpacity }

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

    /// Anything outside the shape is not ours: return nil so the transparent
    /// window passes clicks through to whatever is beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard isOnGlass(local) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// A horizontal swipe. Principle 9 leaves exactly two gestures besides the
    /// click, and this is one of them: **a horizontal swipe walks the session
    /// strip**. One meaning, everywhere it works.
    ///
    /// It used to mean two other things — dismiss the mini, and an app-level
    /// `swipe` event for whoever owned the wing — and both are gone: a
    /// notification that a sideways flick could dismiss taught the user a
    /// gesture the rest of the product does not have, and an app-defined swipe
    /// is a fixed vocabulary with a hole in it.
    /// **Where the gesture is actually read.** Called by `NotchPanel.sendEvent`
    /// *before* the event is dispatched to a view, and by `scrollWheel` below
    /// for the cases that reach the surface on their own. Returns true when the
    /// flick was a walk and must go no further.
    ///
    /// It has to happen ahead of dispatch, because a scroll event goes to the
    /// deepest view under the cursor and only bubbles up if nobody eats it — and
    /// in a visit almost everything eats it: a `stack scroll` is an NSScrollView,
    /// a focusable canvas takes the wheel, and the chat surface is a WKWebView,
    /// which swallows the lot. That is why `‹` and `›` worked on device and the
    /// swipe did nothing: the surface was never asked.
    ///
    /// Vertical scrolling is untouched — the recognizer's 1.5× dominance rule
    /// decides, and anything that is not a horizontal flick is handed straight
    /// back to whoever it was going to.
    @discardableResult
    func translateScroll(_ event: NSEvent) -> Bool {
        // One feed per event: the panel asks first, and a non-swipe then goes on
        // to be dispatched — possibly back to this view, where feeding the same
        // deltas twice would trip the threshold at half a flick.
        guard event !== lastTranslatedScroll else { return false }
        lastTranslatedScroll = event

        // **Only in a visit.** Below it the gesture has no meaning at all: the
        // pill has exactly one gesture (the click), and a notification a flick
        // could dismiss teaches a gesture the rest of the product does not have.
        guard presentation.isExpanded else {
            swipe.reset()
            return false
        }
        // **…except on the ledge, where the shelf itself is the strip** (G3.2).
        // Zoomed out, a sideways flick is how you slide a shelf that is longer
        // than the panel — and it cannot be both that and a walk, because the
        // walk *leaves* the shelf: two fingers moved to see the far end would
        // pan 28 points and then drop you into a session. The overview keeps
        // `‹ ›` and Back, so nothing is unreachable; only the gesture moved.
        guard presentation != .overview else {
            swipe.reset()
            return false
        }
        // Momentum is the flick continuing after the fingers are gone. Feeding
        // it in would let one gesture fire twice, a beat apart.
        guard event.momentumPhase == [] else { return false }
        guard let direction = swipe.feed(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY,
            began: event.phase.contains(.began),
            ended: !event.phase.intersection([.ended, .cancelled]).isEmpty,
            at: event.timestamp
        ) else { return false }
        haptic()
        onSwipe?(direction)
        return true
    }

    private weak var lastTranslatedScroll: NSEvent?

    override func scrollWheel(with event: NSEvent) {
        guard !translateScroll(event) else { return }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Below the visit, a click on Ledge's glass is the one gesture the
        // surface has (principle 9). In a visit, a click on the *chrome* — the
        // glass outside the app's content well — is also ours; a click inside
        // the content well never reaches here, because the app's own views take
        // it first.
        guard !presentation.isExpanded else {
            // …and a press on that chrome that *travels downward* is the second
            // of the two gestures principle 9 allows: "dragging the panel off
            // the notch parks it". It can only start here, which is exactly the
            // rule — an app's content and the transcript take their own presses,
            // so neither can tear the surface off by accident.
            guard !trackTear(from: event) else { return }
            super.mouseDown(with: event)
            return
        }
        haptic()
        onClick?()
    }

    /// Pull the press until it either tears the surface off or is let go.
    ///
    /// Returns true when it became a park, in which case the press is entirely
    /// consumed here. Below the threshold nothing happens at all: the events are
    /// pumped and dropped, which is what makes a press that wandered a few
    /// points still read as a click on the glass rather than as a failed drag.
    ///
    /// **A live window follows the pointer, not a proxy.** The alternative —
    /// dragging a silhouette and building the window on mouse-up — was rejected
    /// because the thing being torn off is a live session: a proxy would show a
    /// frozen picture of it for the length of the gesture, which is precisely
    /// the "a window appeared nearby" reading principle 6 forbids. Nothing is
    /// re-parented mid-drag either, which is the part that would be unstable:
    /// the controller stands a second body up under the pointer and hands it the
    /// same content view, and this view — still the notch's — goes back to being
    /// the bare pill.
    private func trackTear(from event: NSEvent) -> Bool {
        guard onTearBegan != nil, let window else { return false }
        let start = NSEvent.mouseLocation
        // Where the pointer sits inside the shape, so the torn body keeps its
        // grip: the corner is placed relative to the fingers for the whole drag.
        let corner = window.convertPoint(
            toScreen: convert(CGPoint(x: shapeRect.minX, y: shapeRect.minY), to: nil)
        )
        let grab = CGSize(width: start.x - corner.x, height: corner.y - start.y)
        var torn = false

        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let here = window.convertPoint(toScreen: next.locationInWindow)
            if next.type == .leftMouseUp { break }
            let topLeft = CGPoint(x: here.x - grab.width, y: here.y + grab.height)
            if torn {
                onTearMoved?(topLeft)
                continue
            }
            // Downward only, and past the threshold: the surface hangs from the
            // top of the screen, so a sideways or upward drag is not a tear —
            // there is nowhere up there to tear it to.
            guard start.y - here.y >= LedgeMetrics.parkTearThreshold else { continue }
            torn = true
            isDragInFlight = true
            haptic()
            onTearBegan?(topLeft)
        }

        guard torn else { return false }
        isDragInFlight = false
        onTearEnded?()
        return true
    }

    /// A press that began on one of the islands travelled past the tear
    /// threshold, and the island hands the drag over mid-flight (G2.7: under
    /// the physical notch every visible pixel IS an island, so a surface whose
    /// bare glass alone could tear was a surface that could not be torn from
    /// exactly where the hand goes). The threshold has already been crossed by
    /// the caller, so the tear starts now, from wherever the pointer is.
    func adoptTear() {
        guard presentation.isExpanded, onTearBegan != nil, let window else { return }
        let here = NSEvent.mouseLocation
        let corner = window.convertPoint(
            toScreen: convert(CGPoint(x: shapeRect.minX, y: shapeRect.minY), to: nil)
        )
        let grab = CGSize(width: here.x - corner.x, height: corner.y - here.y)
        isDragInFlight = true
        haptic()
        onTearBegan?(corner)

        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            onTearMoved?(CGPoint(x: point.x - grab.width, y: point.y + grab.height))
        }
        isDragInFlight = false
        onTearEnded?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // MARK: - The context menu (flow.md, Edges: Settings)

    /// Right-click on any Ledge glass — the collapsed pill, a wing, a swell, the
    /// panel's chrome — raises the shell's two-item menu. It is the only way to
    /// Settings and the only way to Quit now that the bottom bar is gone, so it
    /// has to work from the *collapsed pill* above all: that is the state the
    /// user is in when nothing else is on screen to click.
    ///
    /// **Never inside app content** — but the well is only app content when
    /// something else drew it. That distinction is the fix: the exclusion used
    /// to be the content host's rect unconditionally, which is every pixel of
    /// the visit below a 32 pt row, *including* the surfaces the shell draws
    /// itself. On device that made the menu unreachable in practice — hovering
    /// the notch opens the visit inside Th, and a right-click on the placeholder
    /// card ("no host") or the permission card, the two surfaces where Quit
    /// matters most, returned nil. Now the well answers unless an app or the
    /// editor owns it, and both of those own their own context menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    /// Who drew what is below the cutout row. Set by the panel controller on
    /// every refresh — it is the only object that knows whether an app's tree
    /// resolved or the shell fell back to a card of its own.
    enum ContentOwner {
        /// The shell drew it: the placeholder, the permission card, an empty
        /// visit. Ledge glass, end to end.
        case shell
        /// An app's tree, or the editor's web view. Its well, its menu.
        case app
    }

    private(set) var contentOwner: ContentOwner = .shell

    func setContentOwner(_ owner: ContentOwner) {
        contentOwner = owner
    }

    /// The decision, on a plain point, so it can be asserted without
    /// synthesizing a right-click in a window that does not exist headlessly.
    func contextMenu(at point: CGPoint) -> NSMenu? {
        guard isOnGlass(point) else { return nil }
        if presentation.isExpanded, contentOwner == .app {
            let well = convert(contentHost.bounds, from: contentHost)
            guard !well.contains(point) else { return nil }
        }
        return contextMenu?()
    }

    // MARK: - Shape

    /// The joint where a narrow panel hangs off the fixed bar: the panel's body,
    /// the depth at which the bar ends, and the radius of the two concave
    /// fillets that marry them (design.html §01 `.panel::before/::after`).
    struct BarShoulder {
        var panel: CGRect
        var y: CGFloat
        var radius: CGFloat
    }

    /// One closed outline for every shape the surface can be.
    ///
    /// The body is a rounded slab with two fillets tucking its top corners under
    /// the menu bar, and — below the bar — a step in to the panel's own width:
    /// down the bar's edge, along its underside, round a concave fillet, and on
    /// down the panel. A 440 pt panel under a 489 pt bar is **one silhouette**,
    /// not a panel parked beneath a strip (principle 6: one material, one body).
    ///
    /// **Every segment is emitted every time, in the same order, whether or not
    /// there is a shoulder** — and that invariance is the whole reason this
    /// function is shaped the way it is.
    ///
    /// `CAShapeLayer.path` animates by interpolating control points *pairwise*.
    /// It can only do that when the two paths have the same element count and
    /// the same element types; when they differ, Core Animation pairs whatever
    /// lines up by index — a quad against a line, the bottom-left corner against
    /// the shoulder — and the in-betweens are not silhouettes at all. That was
    /// literally visible on device as a warped blob with drooping lobes every
    /// time the pill opened into a visit, because the collapsed pill emitted 9
    /// elements and an expanded visit emitted 15.
    ///
    /// With no shoulder the extra segments **degenerate**: `left == barLeft`,
    /// `radius == 0`, and the joint sits at the end of the top fillet, so all
    /// three collapse to zero length and the rendered outline is byte-for-byte
    /// the pill it always was. At rest the law holds; in flight the path is a
    /// pure lerp between two well-formed outlines, so every frame is a sane bar
    /// over a sane panel.
    ///
    /// Keep this structurally constant. Adding a segment behind an `if` is the
    /// bug, not a refactor of it — `ShapeMorphTests` fails if the count moves.
    static func notchPath(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat,
        shoulder: BarShoulder? = nil
    ) -> CGPath {
        let path = CGMutablePath()
        // The bar's own edges: the whole rect when nothing steps in.
        let barLeft = rect.minX + topRadius
        let barRight = rect.maxX - topRadius
        let left = shoulder?.panel.minX ?? barLeft
        let right = shoulder?.panel.maxX ?? barRight
        // Where the bar ends and the panel begins. With no shoulder the joint is
        // the end of the top fillet — the point the path is already standing on
        // — which is what makes the three shoulder segments vanish.
        let jointY = shoulder?.y ?? (rect.minY + topRadius)
        let jointR = shoulder?.radius ?? 0

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: barLeft, y: rect.minY + topRadius),
            control: CGPoint(x: barLeft, y: rect.minY)
        )

        // Down the bar's left edge, along its underside, then a concave fillet
        // onto the panel's edge. The control point sits in the inner corner,
        // which is what curves the join *inwards*.
        path.addLine(to: CGPoint(x: barLeft, y: jointY))
        path.addLine(to: CGPoint(x: left - jointR, y: jointY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: jointY + jointR),
            control: CGPoint(x: left, y: jointY)
        )

        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: left + bottomRadius, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - bottomRadius),
            control: CGPoint(x: right, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: right, y: jointY + jointR))
        path.addQuadCurve(
            to: CGPoint(x: right + jointR, y: jointY),
            control: CGPoint(x: right, y: jointY)
        )
        path.addLine(to: CGPoint(x: barRight, y: jointY))

        path.addLine(to: CGPoint(x: barRight, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: barRight, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// The behind-window blur under the chat glass.
///
/// It refuses hit tests on its own account: the frost is scenery that happens to
/// be the size of the panel, and a click landing on it instead of on the app's
/// tree — or on the glass, where a drag can park the surface — would be a
/// control the user cannot see swallowing one they can.
private final class FrostView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A late-bound press: `LedgeButton`'s handler is fixed at init, and the wing
/// bar needs the press to reach a method on itself — which does not exist yet
/// when the button is made.
@MainActor
final class OverflowPressBox {
    var fire: () -> Void = {}
}
