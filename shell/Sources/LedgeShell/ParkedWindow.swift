import AppKit
import LedgeShellCore
import QuartzCore

/// **Parked** — the whole surface torn off the notch and standing on its own
/// (flow.md, States: "the window (parked) … the notch sits bare; clicking it, or
/// the window's ⌃, flies the surface home").
///
/// Borderless, shadowed, glass: never a titled `NSWindow`. Principle 6 is the
/// whole specification — "Panel, mini, wings, the torn-off window: the same
/// black glass as the notch, swelling, stretching, or detaching whole — never a
/// window that appeared nearby" — so this is the same body, the same beads and
/// the same walker as the panel, in a frame that has left the wall.
final class ParkedWindow: NSPanel {
    /// It has to be able to take key, or the transcript's composer could not be
    /// typed into once the surface has been parked. Non-activating like the
    /// notch panel: taking key must not pull the user out of their app until
    /// they actually click into this one.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc in the parked window does **nothing** (flow.md, and the C2 brief):
    /// it is a window, and the way to close a window is its ⌃. Swallowed rather
    /// than passed on, so the notch panel behind it cannot close a visit that is
    /// not on screen.
    override func cancelOperation(_ sender: Any?) {}
}

/// The parked window's body: the same silhouette family as the panel, rounded on
/// all four corners because it is no longer tucked under the menu bar.
///
/// It hosts the *whole* surface — the visit's two wings (so the strip still
/// walks and the glass still lowers onto the conversation), whatever content the
/// controller resolved (a session's tree, the chat pane, the ledge overview),
/// and one control the panel does not have: the ⌃ that flies it home.
@MainActor
final class ParkedSurfaceView: FlippedView {
    /// Air between the body's top edge and the chrome row (G2.4).
    static let topPad: CGFloat = 6

    /// **The slack around the body for its shadow** — the notch window's own
    /// (`PanelLimits.shadowMargin`). The body draws inset by it on all four
    /// sides, so the shadow falls off *inside* the window. It used to be the
    /// window's exact size, which cut the shadow square at the window's edge:
    /// the hard-edged grey block at every rounded corner, on any desktop light
    /// enough to show a shadow, was the window clipping its own. Nothing but
    /// the shadow is ever drawn in the margin, and nothing there is hit-tested.
    static let margin: CGFloat = PanelLimits.shadowMargin

    /// Where the body is: the window inset by `margin`.
    var bodyRect: CGRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    /// The body for a panel this tall: the panel's height plus `topPad`. The
    /// session measured its tree against the notch's chrome row alone
    /// (`HostSession.chromeHeight`), and the window spends `topPad` on top of
    /// that row — so a body exactly the panel's height gave the content six
    /// points less than it was measured at, and every parked app lost the
    /// bottom of its last line. Both sizing sites go through here.
    static func bodyHeight(forPanelHeight height: CGFloat) -> CGFloat {
        height + topPad
    }

    /// The window for a body this size: the body plus `margin` all round.
    static func windowSize(forBody size: CGSize) -> CGSize {
        CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
    }

    /// The body's frame, read back from the window's — the controller's every
    /// geometry question (the corner the user holds, "is it at the notch") is
    /// about the glass they can see, never the transparent margin.
    static func bodyFrame(ofWindow frame: CGRect) -> CGRect {
        frame.insetBy(dx: margin, dy: margin)
    }

    /// The ⌃ (design.html §04 `.window .home`).
    var onFlyHome: (() -> Void)?

    private let body = CAShapeLayer()
    private let bodyGlass = CAGradientLayer()
    private let bodyGlassMask = CAShapeLayer()
    /// The behind-window blur under the chat glass — see `ShellSurfaceView`'s
    /// for why it exists and why `.state = .active` is the setting that decides
    /// whether it does anything at all.
    private let bodyFrost = ParkedFrostView()
    private let rim = CAShapeLayer()
    private let wingBar: PanelWingBarView
    private let home: LedgeButton
    private let contentHost = FlippedView()
    /// The body's outline, in the content host's own space — see `layout`.
    private let contentMask = CAShapeLayer()
    private var currentContent: NSView?
    private let swell = ParkedSwellView()

    /// The chrome row's height. The notch's own row height, pushed in by the
    /// controller: the session measured its panel against that number
    /// (`HostSession.chromeHeight`), so the window has to spend exactly the same
    /// amount or every parked panel is a row too short.
    var rowHeight: CGFloat = NotchMetrics.fallback.closedHeight {
        didSet {
            guard rowHeight != oldValue else { return }
            needsLayout = true
        }
    }

    private(set) var presentation: ShellPresentation = .collapsed
    private(set) var bodyMaterial: ShellSurfaceView.BodyMaterial = .solid

    /// The hardware cutout's width, pushed in by the controller. There is no
    /// camera in a floating window — what the gap preserves is the *layout*
    /// (G2.8: "keep a notch-sized empty space… the buttons stay where they
    /// were"): the same islands, the same distance apart, so the torn-off
    /// surface is recognisably the notch's body somewhere else.
    var cutoutWidth: CGFloat = NotchMetrics.fallback.closedWidth {
        didSet {
            guard cutoutWidth != oldValue else { return }
            needsLayout = true
        }
    }

    /// The session's own measured width, pushed in by the controller. The
    /// window is floored at the islands' span (G2.8), so a narrow app sits in
    /// a wider glass — and its tree, laid out at its own width, must be
    /// **centred** in it, exactly as the notch panel centres its content
    /// (G2.10: a 368 pt blocks was left-hugging a 458 pt window).
    var contentWidth: CGFloat = 0 {
        didSet {
            guard contentWidth != oldValue else { return }
            needsLayout = true
        }
    }

    init(callbacks: ShellCallbacks) {
        wingBar = PanelWingBarView(
            onToggleGlass: callbacks.toggleChat,
            onWalk: callbacks.walkStrip,
            onOverview: callbacks.showOverview,
            onPark: callbacks.park,
            onSettings: callbacks.openSettings,
            onQuit: callbacks.quit
        )
        // A window cannot tear off of itself, and dragging its glass is how it
        // moves — so no tear bead and no drag hand-off in here.
        wingBar.showsTear = false
        // The islands hug the window's own edges (G2.9) — the bar's only
        // layout since G6, so nothing to switch on here.
        var press: (() -> Void)!
        home = LedgeButton(
            "",
            symbol: "chevron.up",
            variant: .bead,
            size: .s,
            handler: { press() }
        )
        super.init(frame: .zero)
        press = { [weak self] in self?.onFlyHome?() }
        home.setAccessibilityLabel("Fly home")

        wantsLayer = true
        layer?.masksToBounds = false
        body.fillColor = NSColor.black.cgColor
        // The window rung of the shadow ramp — the only surface that uses it,
        // because it is the only one that has left the wall (Theme.swift).
        LedgeShadow.window.applyGeometry(to: body)
        body.shadowOpacity = LedgeShadow.window.opacity
        layer?.addSublayer(body)

        // The frost, on the same terms as the panel's (`ShellSurfaceView`): a
        // subview under everything, `.active` because Ledge is an accessory app
        // whose windows are never the active one, and masked to the body's own
        // outline. The parked window is the *same* chat glass torn off the
        // notch, and a torn-off surface that stopped being frosted would be the
        // one place the material visibly changed by moving.
        bodyFrost.material = .hudWindow
        bodyFrost.blendingMode = .behindWindow
        bodyFrost.state = .active
        bodyFrost.isHidden = true
        // The backing layer has to exist before the ordering can be set on it.
        bodyFrost.wantsLayer = true
        addSubview(bodyFrost)
        bodyFrost.layer?.zPosition = ShellSurfaceView.frostZPosition
        // Behind the gradient — see `ShellSurfaceView`. A subview's backing
        // layer is appended after every sublayer this view added itself, so
        // without an explicit `zPosition` the blur covers the glass and the rim
        // it is supposed to sit under. Set in `applyBodyMaterial`, because the

        bodyGlass.isHidden = true
        bodyGlass.startPoint = CGPoint(x: 0.5, y: 0)
        bodyGlass.endPoint = CGPoint(x: 0.5, y: 1)
        bodyGlass.mask = bodyGlassMask
        layer?.addSublayer(bodyGlass)

        rim.fillColor = nil
        rim.strokeColor = NSColor(white: 1, alpha: 0.08).cgColor
        rim.lineWidth = LedgeMetrics.hairline
        layer?.addSublayer(rim)

        // The content clips to the body, as the notch panel's container does
        // (`ShellSurfaceView.contentContainer`). A session's tree — and the
        // chat pane's web view, which paints an opaque backdrop — is a
        // square-cornered rectangle; since G6 it is exactly the body's width,
        // so unclipped its corners stood out past the glass's rounded ones (it
        // used to sit 21 pt inside them, which hid the omission).
        contentHost.wantsLayer = true
        contentHost.layer?.mask = contentMask
        addSubview(contentHost)
        addSubview(wingBar)
        addSubview(home)
        addSubview(swell)
        swell.isHidden = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Ledge, parked")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Presentation

    /// Show a surface, exactly as `ShellSurfaceView.present` does. The two take
    /// the same call so the controller's `refresh` does not branch on where the
    /// visit currently lives — it resolves one content view and one size, and
    /// hands them to whichever body is on screen.
    func present(_ newPresentation: ShellPresentation, content: NSView?, animated: Bool) {
        presentation = newPresentation
        setAccessibilityLabel("Ledge parked, \(newPresentation.app ?? "session")")
        guard content !== currentContent else {
            needsLayout = true
            return
        }
        currentContent?.removeFromSuperview()
        currentContent = content
        guard let content else { return }
        content.translatesAutoresizingMaskIntoConstraints = true
        contentHost.addSubview(content)
        needsLayout = true
    }

    /// Fly-home hands the content back to the notch panel by reparenting it —
    /// but this view keeps animating (the window shrinks toward the notch), and
    /// its `layout` must not go on stomping the frame of a view that now lives
    /// somewhere else. Called by the controller the moment the surface leaves.
    func abandonContent() {
        currentContent = nil
    }

    func setPanelWing(mode: PanelWingBarView.Mode, canToggleGlass: Bool) {
        wingBar.apply(mode: mode, canToggleGlass: canToggleGlass)
    }

    /// The chat pane's glass, in the window as in the panel (flow.md, Material).
    /// The same body, so the same material.
    func setBodyMaterial(_ material: ShellSurfaceView.BodyMaterial) {
        guard material != bodyMaterial else { return }
        bodyMaterial = material
        needsLayout = true
    }

    // MARK: - The swell, from the window's top edge

    /// Raise a notification in the parked window (flow.md: "Notifications swell
    /// from the parked window's top edge").
    ///
    /// The window is a fixed size, so the surface cannot deform outward the way
    /// the notch does; the band grows **down from the top edge** instead, in the
    /// same glass, carrying the same borrowed `<mini>` node the notch swell
    /// carries. Same content, same dwell, same click; different geometry,
    /// because the geometry belongs to the notch.
    func showSwell(_ content: NSView, height: CGFloat, animated: Bool, onClick: @escaping () -> Void) {
        swell.adopt(content, onClick: onClick)
        swell.isHidden = false
        let slab = bodyRect
        swell.frame = CGRect(x: slab.minX, y: slab.minY, width: slab.width, height: height)
        swell.needsLayout = true
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            swell.alphaValue = 1
            return
        }
        swell.alphaValue = 1
        swell.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -height))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = LedgeMotion.move
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.4, 1)
            swell.animator().layer?.setAffineTransform(.identity)
        }
    }

    func hideSwell(animated: Bool) {
        guard !swell.isHidden else { return }
        guard animated else {
            swell.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = LedgeMotion.fast
            swell.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.swell.isHidden = true
            self?.swell.alphaValue = 1
        })
    }

    var isShowingSwell: Bool { !swell.isHidden }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        // The body is the window inset by `margin` — the shadow falls in the
        // margin, and nothing else is ever drawn there.
        let slab = bodyRect
        let path = CGPath(
            roundedRect: slab,
            cornerWidth: LedgeMetrics.rWindow,
            cornerHeight: LedgeMetrics.rWindow,
            transform: nil
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.path = path
        body.shadowPath = path
        rim.path = path
        applyBodyMaterial(slab: slab)
        CATransaction.commit()

        let homeSize = home.intrinsicContentSize
        home.frame = CGRect(
            x: slab.maxX - homeSize.width - LedgeMetrics.parkedHomeInset,
            y: slab.minY + Self.topPad + (rowHeight - homeSize.height) / 2,
            width: homeSize.width,
            height: homeSize.height
        )
        // The visit's own controls, with the notch-sized gap between them
        // preserved (G2.8): no camera here, but the empty space is the body's
        // identity — collapsing it made the islands crowd the middle and the
        // window read as different chrome.
        wingBar.cutoutWidth = cutoutWidth
        wingBar.rowHeight = rowHeight
        // A breath below the body's top edge (G2.4: the beads were touching
        // it — the notch panel gets this air from the cutout row; the window
        // has to spend its own).
        wingBar.frame = CGRect(
            x: slab.minX,
            y: slab.minY + Self.topPad,
            width: max(0, home.frame.minX - LedgeMetrics.parkedHomeInset - slab.minX),
            height: rowHeight
        )
        wingBar.needsLayout = true

        // The session's content keeps its own declared width, centred in the
        // floored glass — the notch panel's G2.5 law, kept by the window.
        let width = contentWidth > 0 ? min(contentWidth, slab.width) : slab.width
        contentHost.frame = CGRect(
            x: slab.minX + (slab.width - width) / 2,
            y: slab.minY + Self.topPad + rowHeight,
            width: width,
            height: max(0, slab.height - rowHeight - Self.topPad)
        )
        // The same rounded outline the body draws, carried into the host's
        // coordinates: the clip is the body itself, not a second shape that
        // has to agree with it.
        let hostClip = CGMutablePath()
        hostClip.addPath(
            path,
            transform: CGAffineTransform(
                translationX: -contentHost.frame.minX,
                y: -contentHost.frame.minY
            )
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentMask.frame = contentHost.bounds
        contentMask.path = hostClip
        CATransaction.commit()
        // Only a view that genuinely lives here: after fly-home the composite
        // is the notch panel's again, and resizing it from a shrinking window
        // is exactly the stranded-frame bug (G2.4).
        if let currentContent, currentContent.superview === contentHost {
            currentContent.frame = contentHost.bounds
            currentContent.autoresizingMask = [.width, .height]
        }
        if !swell.isHidden {
            swell.frame = CGRect(
                x: slab.minX, y: slab.minY, width: slab.width, height: swell.frame.height
            )
        }
    }

    /// The margin is the shadow's, not Ledge's: a click there goes to whatever
    /// is under the window — the same rule the notch surface keeps for the
    /// glass around its shape. (`point` is in the superview's space; as the
    /// window's content view that is the window's own.)
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bodyRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// The frost exists only while the surface is in a window (see
    /// `applyBodyMaterial`), and a parked surface is *built* before its window
    /// adopts it — so arriving has to repaint the material.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    private func applyBodyMaterial(slab: CGRect) {
        let glass = bodyMaterial == .chatGlass && slab.height > 0
        body.fillColor = glass ? nil : NSColor.black.cgColor
        bodyGlass.isHidden = !glass
        // Only with a window behind to blur — offscreen the material falls back
        // to an opaque colour and every snapshot of a parked chat would be a
        // grey slab. Same gate as the panel's.
        bodyFrost.isHidden = !glass || window == nil
        bodyFrost.layer?.zPosition = ShellSurfaceView.frostZPosition
        guard glass else { return }
        // The gradient and the frost take the body's rectangle, so their
        // outline is the body's own path at the origin.
        let local = CGPath(
            roundedRect: CGRect(origin: .zero, size: slab.size),
            cornerWidth: LedgeMetrics.rWindow,
            cornerHeight: LedgeMetrics.rWindow,
            transform: nil
        )
        let bar = min(1, rowHeight / slab.height)
        bodyGlass.frame = slab
        bodyGlassMask.frame = bodyGlass.bounds
        bodyGlassMask.path = local
        bodyFrost.frame = slab
        bodyFrost.maskImage = ShellSurfaceView.maskImage(for: local, size: slab.size)
        bodyGlass.colors = [NSColor.black.cgColor] + LedgeGlass.chat.map { $0.color.cgColor }
        bodyGlass.locations = [0]
            + LedgeGlass.chat.map { NSNumber(value: Double(bar + (1 - bar) * $0.at)) }
    }

    // MARK: - Test seams

    var wingBarView: PanelWingBarView { wingBar }
    var homeBead: LedgeButton { home }
    /// Where the session's content stands — the centring law's test seam.
    var contentHostFrame: CGRect { contentHost.frame }

    /// The strip's end refused a walk inside the window: same flinch as the
    /// notch's (see `NSView.runEndBounce`).
    func bounceAtEnd(toward steps: Int) {
        runEndBounce(toward: steps)
    }
    var contentHostView: NSView { contentHost }
    var swellView: ParkedSwellView { swell }
}

/// The notification band inside a parked window: the top edge of the glass
/// growing downward, with the app's borrowed `<mini>` node in it.
@MainActor
final class ParkedSwellView: FlippedView {
    private let fill = CAShapeLayer()
    private let content = MiniContentView()
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.fillColor = NSColor.black.cgColor
        LedgeShadow.swell.applyGeometry(to: fill)
        fill.shadowOpacity = LedgeShadow.swell.opacity
        layer?.addSublayer(fill)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func adopt(_ view: NSView?, onClick: @escaping () -> Void) {
        content.setShowsOpenAffordance(false)
        content.adopt(view)
        action = onClick
    }

    override func layout() {
        super.layout()
        // Square where it meets the window's top edge, rounded where it hangs
        // into the body: the band *is* the top of the window, pulled down.
        let path = CGMutablePath()
        let radius = LedgeMetrics.rContent
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: bounds.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: radius, y: bounds.maxY),
            control: CGPoint(x: 0, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius),
            control: CGPoint(x: bounds.maxX, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: 0))
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.path = path
        fill.shadowPath = path
        CATransaction.commit()
        content.frame = bounds
    }

    /// The band's height for the content it was given, on a window this wide.
    func preferredHeight(width: CGFloat) -> CGFloat {
        content.preferredSize(cutoutWidth: 0, maxWidth: width).height
    }

    override func mouseDown(with event: NSEvent) {
        action?()
    }

    var miniContent: MiniContentView { content }
}


/// The parked window's frost. Refuses hit tests for the same reason the panel's
/// does: it is scenery the size of the whole surface, and a click landing on it
/// instead of on the app's tree would be an invisible control eating a visible
/// one.
private final class ParkedFrostView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
