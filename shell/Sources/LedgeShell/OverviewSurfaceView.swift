import AppKit
import LedgeShellCore
import QuartzCore

/// **The ledge** — the session strip, zoomed out (flow.md, "The strip": "Zoom
/// out to the overview — the ledge: sessions as slabs on a shelf. Click jumps;
/// the only ✕ in the product lives here. Trigger: the `|` divider.").
///
/// It is a *mode of the visit*, not a window and not a state: the same panel,
/// the same two wings, with the whole strip on screen at once instead of one
/// session of it. The left wing relabels itself **Back** while it is up.
///
/// design.html §04 is the specimen and this is it, verbatim: glass slabs
/// standing on a shelf hairline, a big white glyph each, the blank slot as a
/// dashed slab with a `+`, and the slabs rising toward the cursor on a gaussian
/// falloff. Reduce Motion keeps the shelf and drops the rise — the ✕ still
/// appears, because that is a reveal and not a motion (principle 10).
///
/// **The shelf pans; slabs never shrink** (G3.2). It used to close its gaps and
/// then narrow its slabs to make a long strip fit, and with nine sessions the
/// result was the thing the audit caught: the first slab sliced off at the panel
/// edge, its ✕ orphaned in the corner above nothing, and the blank slot pushed
/// out of the panel altogether — the one slot flow.md guarantees is always
/// there. A slab is 64 × 86 because that is what design.html draws; a shelf with
/// more on it than fits is a shelf you slide, exactly like the real one.
///
/// So the slabs live in a scrolling well: `viewport` clips, `content` pans
/// inside it, and everything that belongs to a slab — the ✕ bead included —
/// is a child of `content`, which is what makes "the bead is clipped with its
/// slab" a fact of the view hierarchy rather than a rule the layout remembers.
/// Where the content is cut, the edge fades (design.html's ticker mask, as a
/// gradient on the viewport's own layer) so a sliced slab reads as *more shelf*
/// and not as a rendering fault.
@MainActor
final class OverviewSurfaceView: FlippedView {
    /// One stop on the shelf: a session, or the blank slot.
    struct Slab: Equatable {
        var app: String?
        var name: String
        var icon: String

        var isBlank: Bool { app == nil }

        static let blank = Slab(app: nil, name: "New session", icon: "plus")
    }

    /// Click a slab: that session takes the stage (`nil` = the blank slot).
    var onSelect: ((String?) -> Void)?
    /// The ✕ bead: stop that app's session. The only ✕ in the product.
    var onStop: ((String) -> Void)?

    private(set) var slabs: [Slab] = []
    /// Which session is showing behind the ledge. Not a selection — nothing on
    /// this shelf is selected — only where the shelf is scrolled to when it
    /// opens, so zooming out puts you where you already were.
    private(set) var current: String?
    private var slabViews: [SlabView] = []
    private let shelfLine = HairlineView()
    /// The clipping well. Its width is the shelf hairline's, so a slab is cut
    /// exactly where the shelf ends rather than where the panel does.
    private let viewport = ShelfViewportView()
    /// What pans inside it: every slab, and the ✕ bead.
    private let content = FlippedView()
    /// design.html's ticker mask (`linear-gradient(90deg, transparent, #000 …)`)
    /// as a layer, applied only on the side that is actually cut.
    private let edgeFade = CAGradientLayer()
    /// How far the shelf has slid, in points, from its leading edge.
    private(set) var scrollOffset: CGFloat = 0
    /// The width the slabs actually occupy — never less than the viewport, so
    /// "the content is wider than the well" is the whole scrollability test.
    private(set) var contentWidth: CGFloat = 0
    /// Set by `apply`, consumed by the next layout: the shelf opens centred on
    /// the current session, and thereafter goes exactly where it is pushed.
    private var needsRecentre = true
    /// One bead, moved to whichever slab the pointer is over. There is only ever
    /// one visible in the mockup too — a ✕ per slab would be four ways to
    /// destroy something on a surface whose whole job is choosing one.
    private let closeBead: LedgeButton
    private var tracking: NSTrackingArea?
    private var hovered: SlabView?
    /// What the ✕ currently means. The bead is one control that moves between
    /// slabs, so its action is a variable and not the closure it was built with.
    private var stopAction: (() -> Void)?

    /// The panel height this surface asks for: the room above the shelf, the
    /// slab, the hairline, and the room below it (design.html `.shelfpanel` +
    /// `.shelfroom`). Fixed — the ledge is the same height whatever is on it,
    /// because it is a shelf and a shelf does not resize.
    static var panelHeight: CGFloat {
        LedgeMetrics.shelfTopPad
            + LedgeMetrics.slabHeight
            + LedgeMetrics.hairline
            + LedgeMetrics.shelfRoom
    }

    override init(frame frameRect: NSRect) {
        var press: (() -> Void)!
        closeBead = LedgeButton(
            "",
            symbol: "xmark",
            variant: .bead,
            size: .s,
            handler: { press() }
        )
        super.init(frame: frameRect)
        press = { [weak self] in self?.stopAction?() }
        closeBead.setAccessibilityLabel("Stop this session")
        closeBead.isHidden = true
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        addSubview(shelfLine)
        addSubview(viewport)
        viewport.addSubview(content)
        // The bead is a child of what pans, not of the surface: that is the
        // whole fix for the ✕ that floated in the corner while its slab was
        // clipped away underneath it.
        content.addSubview(closeBead)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Rebuild the shelf from the strip. Called on every present: the catalog is
    /// a full snapshot (spec §3.6), so the shelf is rebuilt from it rather than
    /// diffed — there are at most a handful of slabs and no state on them worth
    /// preserving except the pointer, which is re-read at the end.
    func apply(slabs newSlabs: [Slab], current newCurrent: String? = nil) {
        guard newSlabs != slabs || newCurrent != current else { return }
        slabs = newSlabs
        current = newCurrent
        for view in slabViews { view.removeFromSuperview() }
        slabViews = newSlabs.map { slab in
            let view = SlabView(slab: slab)
            view.onPress = { [weak self] in self?.onSelect?(slab.app) }
            content.addSubview(view, positioned: .below, relativeTo: closeBead)
            return view
        }
        hovered = nil
        closeBead.isHidden = true
        // A different strip is a different shelf: it opens where the session
        // that was showing stands, not wherever the last one had been slid to.
        needsRecentre = true
        needsLayout = true
    }

    // MARK: - Geometry

    /// How wide the slabs stand in total. Always the mockup's 64 × 18: **the
    /// shelf pans, so nothing on it is ever squeezed** (G3.2). What used to
    /// happen here — close the gaps, then narrow the slabs to a 44 pt floor —
    /// bought a fit that was not one: past the floor the strip overflowed
    /// anyway, and everything before it was a shelf of thin slivers pretending
    /// the panel was big enough.
    static func contentWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * LedgeMetrics.slabWidth
            + CGFloat(count - 1) * LedgeMetrics.slabGap
    }

    /// Where the shelf hairline is, measured from the top of the surface. The
    /// slabs stand **on** it, so it is also every slab's bottom edge.
    var shelfY: CGFloat { LedgeMetrics.shelfTopPad + LedgeMetrics.slabHeight }

    /// How far the shelf can slide before the last slab is flush with the end.
    /// Zero when the whole strip fits — which is also "this shelf does not
    /// scroll", so it is the one thing the wheel, the fade and the tests all ask.
    var maxScrollOffset: CGFloat { max(0, contentWidth - viewport.bounds.width) }

    override func layout() {
        super.layout()
        let well = max(0, bounds.width - LedgeMetrics.shelfPadX * 2)
        viewport.frame = CGRect(x: LedgeMetrics.shelfPadX, y: 0, width: well, height: shelfY)

        let total = Self.contentWidth(count: slabViews.count)
        contentWidth = max(total, well)
        // Centred while there is room, hard against the leading edge once there
        // is not: a shelf you can slide starts at its beginning.
        var x = max(0, (well - total) / 2)
        for view in slabViews {
            view.baseFrame = CGRect(
                x: x,
                y: LedgeMetrics.shelfTopPad,
                width: LedgeMetrics.slabWidth,
                height: LedgeMetrics.slabHeight
            )
            x += LedgeMetrics.slabWidth + LedgeMetrics.slabGap
        }
        if needsRecentre {
            needsRecentre = false
            scrollOffset = openingOffset()
        }
        scrollOffset = clamp(scrollOffset)
        content.frame = CGRect(x: -scrollOffset, y: 0, width: contentWidth, height: shelfY)

        shelfLine.frame = CGRect(
            x: LedgeMetrics.shelfPadX,
            y: shelfY,
            width: well,
            height: LedgeMetrics.hairline
        )
        refreshEdgeFade()
        syncPointer()
    }

    // MARK: - Panning the shelf

    /// Where the shelf sits the moment it opens: the current session's slab in
    /// the middle of the well, clamped to the ends. A shelf that always opened
    /// at its beginning would hide the session you zoomed out *of* the moment
    /// the strip outgrew the panel, which is the one slab you are certain to
    /// want to see.
    private func openingOffset() -> CGFloat {
        guard let current,
              let slab = slabViews.first(where: { $0.slab.app == current })
        else { return 0 }
        return clamp(slab.baseFrame.midX - viewport.bounds.width / 2)
    }

    private func clamp(_ offset: CGFloat) -> CGFloat {
        min(max(0, offset), maxScrollOffset)
    }

    /// Slide the shelf. Returns whether it actually moved, so a wheel over a
    /// shelf with nothing to reveal is handed back to the responder chain
    /// instead of being silently eaten.
    @discardableResult
    func pan(by delta: CGFloat) -> Bool {
        let next = clamp(scrollOffset + delta)
        guard next != scrollOffset else { return false }
        scrollOffset = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame.origin.x = -scrollOffset
        CATransaction.commit()
        refreshEdgeFade()
        // The rise is a function of where the cursor is *on the shelf*, and the
        // shelf just moved under a cursor that did not: re-read it, or the slab
        // that is lifted is the one that used to be there.
        syncPointer()
        return true
    }

    /// The wheel, and a trackpad's two fingers. A mouse has no horizontal axis
    /// at all, so the larger of the two deltas is the one that means "along the
    /// shelf" — the only axis this surface has.
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        // Already at the end it did not move, and an unmoved shelf must not eat
        // the wheel: whoever is above this surface may still want it.
        if !pan(by: -delta) { super.scrollWheel(with: event) }
    }

    /// design.html's ticker mask, on the side that is actually cut. No mask at
    /// all when the whole strip fits: a gradient mask forces the layer offscreen
    /// to composite, and a shelf with nothing hidden has nothing to soften.
    private func refreshEdgeFade() {
        let width = viewport.bounds.width
        let leading = scrollOffset > 0.5
        let trailing = scrollOffset < maxScrollOffset - 0.5
        guard width > 0, leading || trailing else {
            viewport.layer?.mask = nil
            return
        }
        let opaque = NSColor.black.cgColor
        let clear = NSColor.black.withAlphaComponent(0).cgColor
        let stop = min(LedgeMetrics.shelfFadeWidth, width / 3) / width
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        if leading {
            colors += [clear, opaque]
            locations += [0, NSNumber(value: Double(stop))]
        } else {
            colors.append(opaque)
            locations.append(0)
        }
        if trailing {
            colors += [opaque, clear]
            locations += [NSNumber(value: Double(1 - stop)), 1]
        } else {
            colors.append(opaque)
            locations.append(1)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = viewport.bounds
        edgeFade.colors = colors
        edgeFade.locations = locations
        viewport.layer?.mask = edgeFade
        CATransaction.commit()
    }

    // MARK: - The rise (design.html §04's page script)

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
    }

    override func mouseEntered(with event: NSEvent) { syncPointer() }
    override func mouseMoved(with event: NSEvent) { syncPointer() }
    override func mouseExited(with event: NSEvent) { syncPointer() }

    /// Whether the shelf magnifies at all. Reduce Motion keeps every slab flat
    /// and still — the ✕ is a *reveal*, so it survives (principle 10: Reduce
    /// Motion swaps motion for fades, it does not remove affordances).
    var magnifies: Bool {
        reduceMotionOverride.map { !$0 }
            ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The system switch, forced. Only a test sets this: Reduce Motion is a
    /// per-user accessibility preference and a suite that flipped the real one
    /// would be changing the machine it runs on.
    var reduceMotionOverride: Bool?

    /// Always measured against the live pointer, never against a stale
    /// enter/exit pair: the panel morphs under a stationary cursor all the time
    /// (shell/README.md), and the shelf arrives in the middle of exactly that.
    private func syncPointer() {
        guard let window else {
            apply(pointerX: nil)
            return
        }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        // Outside the well is off the shelf, even when it is still on the panel:
        // the room either side of the hairline is not shelf, and a cursor parked
        // there must not be lifting the slab that happens to be behind the fade.
        guard viewport.frame.contains(point) else {
            apply(pointerX: nil)
            return
        }
        apply(pointerX: shelfX(fromSurface: point.x))
    }

    /// A surface-space x, in the shelf's own scrolled coordinates. Everything
    /// about the rise is measured here, so sliding the shelf under a stationary
    /// cursor lifts whatever arrived under it.
    func shelfX(fromSurface x: CGFloat) -> CGFloat {
        x - viewport.frame.minX + scrollOffset
    }

    /// The whole gesture, on a plain coordinate **in the shelf's scrolled
    /// space** (`shelfX(fromSurface:)` converts): which slab is under the
    /// cursor, how far each one rises, and where the ✕ goes. Exposed so the
    /// falloff can be asserted without synthesizing mouse-moved events into a
    /// window that does not exist headlessly.
    func apply(pointerX: CGFloat?) {
        var nearest: SlabView?
        for view in slabViews {
            let factor: CGFloat = if let pointerX, magnifies {
                LedgeMetrics.slabMagnification(distance: pointerX - view.baseFrame.midX)
            } else {
                0
            }
            view.setMagnification(factor)
            if let pointerX, view.baseFrame.minX <= pointerX, pointerX < view.baseFrame.maxX {
                nearest = view
            }
        }
        setHovered(nearest)
    }

    private func setHovered(_ view: SlabView?) {
        hovered?.isHovered = false
        hovered = view
        view?.isHovered = true

        // The ✕ belongs to a session, so the blank slot never has one: there is
        // nothing there to stop.
        guard let view, let app = view.slab.app else {
            closeBead.isHidden = true
            return
        }
        let size = closeBead.intrinsicContentSize
        closeBead.isHidden = false
        closeBead.frame = CGRect(
            x: view.baseFrame.midX - size.width / 2,
            // Above the slab's *risen* top edge, so the bead travels with the
            // slab it belongs to instead of hovering over a gap.
            y: view.frame.minY - LedgeMetrics.slabCloseGap - size.height,
            width: size.width,
            height: size.height
        )
        closeBead.setAccessibilityLabel("Stop \(view.slab.name)")
        stopAction = { [weak self] in self?.onStop?(app) }
    }

    // MARK: - Test seams

    var slabViewsForTesting: [SlabView] { slabViews }
    /// Where the slabs *stand* on the shelf, before the cursor lifts any of
    /// them — in the shelf's own scrolled space, not the panel's.
    var slabFrames: [CGRect] { slabViews.map(\.baseFrame) }
    /// …and where they are right now, which is the same thing until a pointer
    /// arrives.
    var slabLiveFrames: [CGRect] { slabViews.map(\.frame) }
    var slabRises: [CGFloat] { slabViews.map(\.rise) }
    var closeBeadView: LedgeButton { closeBead }
    var isShowingClose: Bool { !closeBead.isHidden }
    var shelfHairlineFrame: CGRect { shelfLine.frame }
    /// The clipping well, in surface space. A slab is on screen exactly when its
    /// panned frame intersects this.
    var viewportFrame: CGRect { viewport.frame }
    /// The well itself, so "the ✕ is inside the thing that clips" can be
    /// asserted as a fact about the hierarchy rather than about a frame.
    var viewportForTesting: NSView { viewport }
    /// Which side of the shelf is currently softened, read off the live mask
    /// rather than recomputed — the claim is about the pixels.
    var edgeFadeSides: (leading: Bool, trailing: Bool) {
        // A faded side is one the mask starts (or ends) transparent on — read
        // off the colours, because the stops alone cannot tell a fade-in at the
        // leading edge from a fade-out that begins near it.
        guard viewport.layer?.mask === edgeFade,
              let colors = edgeFade.colors as? [CGColor],
              colors.count >= 2
        else { return (false, false) }
        return (leading: colors[0].alpha == 0, trailing: colors[colors.count - 1].alpha == 0)
    }
}

/// A well that clips. The slabs pan inside it and the ✕ bead pans with them, so
/// "the shelf ends here" is enforced by the view hierarchy and cannot be got
/// wrong by a frame calculation.
@MainActor
final class ShelfViewportView: FlippedView {
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

/// One session, standing on the shelf (design.html §04 `.slab`).
///
/// Not a `LedgeButton`: a bead is the glass swelling and this is a *pane* of it
/// — square-bottomed, top-lit, and transformed from its bottom edge as the
/// cursor passes. The only thing it shares with a button is that pressing it
/// does something.
@MainActor
final class SlabView: FlippedView {
    let slab: OverviewSurfaceView.Slab
    var onPress: (() -> Void)?

    private let fill = CAGradientLayer()
    private let topEdge = CALayer()
    private let leftEdge = CALayer()
    private let rightEdge = CALayer()
    private let dashed = CAShapeLayer()
    private let glyph = NSImageView()
    private(set) var magnification: CGFloat = 0

    init(slab: OverviewSurfaceView.Slab) {
        self.slab = slab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // **Top corners only.** A slab stands on the shelf: its bottom edge is
        // where it meets the hairline, and a rounded foot would float.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.cornerRadius = LedgeMetrics.slabRadius

        if slab.isBlank {
            // "At most one blank exists" (flow.md) and it is drawn as an empty
            // frame: a dashed outline with no fill and no bottom, so it reads as
            // a space for a slab rather than a slab that failed to load.
            dashed.fillColor = nil
            dashed.strokeColor = LedgeTheme.track.cgColor
            dashed.lineWidth = LedgeMetrics.hairline
            dashed.lineDashPattern = [3, 3]
            layer?.addSublayer(dashed)
        } else {
            fill.startPoint = CGPoint(x: 0.5, y: 0)
            fill.endPoint = CGPoint(x: 0.5, y: 1)
            fill.colors = [LedgeTheme.slabFillTop.cgColor, LedgeTheme.slabFillBottom.cgColor]
            layer?.addSublayer(fill)
            topEdge.backgroundColor = LedgeTheme.slabEdgeHighlight.cgColor
            leftEdge.backgroundColor = LedgeTheme.slabEdgeSide.cgColor
            rightEdge.backgroundColor = LedgeTheme.slabEdgeSide.cgColor
            for edge in [topEdge, leftEdge, rightEdge] { layer?.addSublayer(edge) }
            // The slab rung of the shadow ramp: it is the panel's, because a
            // risen slab hangs off the shelf exactly as the panel hangs off the
            // notch. There is no fourth shadow (principle 15).
            if let layer {
                LedgeShadow.panel.applyGeometry(to: layer)
                layer.shadowOpacity = 0
            }
        }

        glyph.image = NSImage(
            systemSymbolName: slab.icon,
            accessibilityDescription: slab.name
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: LedgeMetrics.slabGlyphPointSize,
                weight: LedgeMetrics.slabGlyphWeight
            )
        )
        // Big and white — a slab's whole content is its glyph, so this is the
        // one place the catalog icon is the datum rather than a label's
        // punctuation (principle 5). The blank slot's `+` is quieter: it is an
        // invitation, not a session.
        glyph.contentTintColor = slab.isBlank ? LedgeTheme.tertiary : LedgeTheme.primary
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(slab.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        dashed.frame = bounds
        // No bottom: the dashed frame is open where it meets the shelf, exactly
        // as the mockup draws it (`border-bottom: none`).
        let path = CGMutablePath()
        let inset = LedgeMetrics.hairline / 2
        let radius = LedgeMetrics.slabRadius
        path.move(to: CGPoint(x: inset, y: bounds.maxY))
        path.addLine(to: CGPoint(x: inset, y: inset + radius))
        path.addQuadCurve(
            to: CGPoint(x: inset + radius, y: inset),
            control: CGPoint(x: inset, y: inset)
        )
        path.addLine(to: CGPoint(x: bounds.maxX - inset - radius, y: inset))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX - inset, y: inset + radius),
            control: CGPoint(x: bounds.maxX - inset, y: inset)
        )
        path.addLine(to: CGPoint(x: bounds.maxX - inset, y: bounds.maxY))
        dashed.path = path

        let hairline = LedgeMetrics.hairline
        topEdge.frame = CGRect(x: 0, y: 0, width: bounds.width, height: hairline)
        leftEdge.frame = CGRect(x: 0, y: 0, width: hairline, height: bounds.height)
        rightEdge.frame = CGRect(
            x: bounds.width - hairline, y: 0, width: hairline, height: bounds.height
        )
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: LedgeMetrics.slabRadius,
            cornerHeight: LedgeMetrics.slabRadius,
            transform: nil
        )
        CATransaction.commit()

        let box = glyph.image?.size ?? .zero
        glyph.frame = CGRect(
            x: (bounds.width - box.width) / 2,
            y: (bounds.height - box.height) / 2,
            width: box.width,
            height: box.height
        )
    }

    /// Where this slab stands when nothing is lifting it — its place on the
    /// shelf, set by the shelf's own layout. The live `frame` is this plus
    /// whatever the cursor is doing to it.
    var baseFrame: CGRect = .zero {
        didSet {
            guard baseFrame != oldValue else { return }
            applyRise()
        }
    }

    /// How far this slab is currently displaced upward. Read by the shelf to
    /// place the ✕ bead, and by the tests that assert the falloff.
    var rise: CGFloat { LedgeMetrics.slabRise * magnification }

    /// Apply one frame of the rise. `factor` is the gaussian's value: 0 flat on
    /// the shelf, 1 directly under the cursor.
    func setMagnification(_ factor: CGFloat) {
        guard factor != magnification else { return }
        magnification = factor
        applyRise()
    }

    /// Grow **about the bottom edge**, then rise (design.html:
    /// `transform-origin: 50% 100%`).
    ///
    /// Real geometry, not a layer transform. Two reasons, and the second is the
    /// one that decided it: a transformed layer-backed view does not appear in
    /// `cacheDisplay`, so every snapshot of the shelf would show it flat — and a
    /// scaled *glyph* is a blurred glyph, where a slab that grows around a glyph
    /// that stays the size it was reads exactly like a pane coming forward.
    private func applyRise() {
        let scale = 1 + LedgeMetrics.slabMagnify * magnification
        let width = baseFrame.width * scale
        let height = baseFrame.height * scale
        frame = CGRect(
            x: baseFrame.midX - width / 2,
            y: baseFrame.maxY - height - rise,
            width: width,
            height: height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowOpacity = slab.isBlank ? 0 : LedgeShadow.panel.opacity * Float(magnification)
        CATransaction.commit()
    }

    var isHovered = false {
        didSet {
            guard isHovered != oldValue, !slab.isBlank else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(LedgeMotion.fast)
            topEdge.backgroundColor = (
                isHovered ? LedgeTheme.slabEdgeHighlightHover : LedgeTheme.slabEdgeHighlight
            ).cgColor
            CATransaction.commit()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Press-and-release inside, like every other control in the kit; the
        // slab does not sink, because it is already moving under the cursor.
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            inside = bounds.contains(point)
            if next.type == .leftMouseUp { break }
        }
        guard inside else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
