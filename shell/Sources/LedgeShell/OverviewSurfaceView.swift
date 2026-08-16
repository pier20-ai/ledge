import AppKit
import LedgeShellCore
import QuartzCore

/// **The ledge** — the session strip, zoomed out (flow.md, "The strip").
///
/// A **grid of square glass cards** (G2.5). The first ledge was a shelf:
/// slabs standing on a hairline, panning sideways, cut off at the well's ends.
/// On device the pan read as an x-y scrolling list and the flat-bottomed slabs
/// read as truncated cards — so the shelf is retired. The grid shows the whole
/// strip at once: one square card per session, fully rounded, the blank slot
/// last as a dashed square with a `+`.
///
/// The interaction is the Dock's magnification in two axes: every card swells
/// toward the cursor on a gaussian of its 2-D distance
/// (`LedgeMetrics.cardMagnification`), so the neighbourhood leans toward the
/// hand and the card under it comes forward — scaled about its own centre,
/// with the panel rung of the shadow ramp fading in beneath it. Reduce Motion
/// holds every card still; the ✕ is a reveal, not a motion, so it survives
/// (principle 10).
///
/// Click jumps; the only ✕ in the product lives here, riding the hovered
/// card's top-right corner.
@MainActor
final class OverviewSurfaceView: FlippedView {
    /// One card on the grid: a session, or the blank slot.
    struct Card: Equatable {
        var app: String?
        var name: String
        var icon: String

        var isBlank: Bool { app == nil }

        static let blank = Card(app: nil, name: "New session", icon: "plus")
    }

    /// Click a card: that session takes the stage (`nil` = the blank slot).
    var onSelect: ((String?) -> Void)?
    /// The ✕ bead: stop that app's session. The only ✕ in the product.
    var onStop: ((String) -> Void)?

    private(set) var cards: [Card] = []
    /// Which session is showing behind the ledge. Not a selection — nothing on
    /// this grid is selected — only what Back returns to, remembered by the
    /// controller and mirrored here for the tests that ask.
    private(set) var current: String?
    private var cardViews: [CardView] = []
    /// One bead, moved to whichever card the pointer is over. A ✕ per card
    /// would be a dozen ways to destroy something on a surface whose whole job
    /// is choosing one.
    private let closeBead: LedgeButton
    private var tracking: NSTrackingArea?
    private var hovered: CardView?
    /// What the ✕ currently means. The bead is one control that moves between
    /// cards, so its action is a variable and not the closure it was built with.
    private var stopAction: (() -> Void)?

    // MARK: - Geometry, stated once

    /// Cards per row for `count` cards: the full `gridColumns`, or fewer when
    /// fewer exist — a strip of two is two cards centred, not two cards and
    /// two holes.
    static func columns(count: Int) -> Int {
        min(max(count, 1), LedgeMetrics.gridColumns)
    }

    static func rows(count: Int) -> Int {
        let columns = columns(count: count)
        return (max(count, 1) + columns - 1) / columns
    }

    /// The panel height this surface asks for: pad, the rows, pad. A function
    /// of the strip — a grid does not scroll, it grows a row.
    static func panelHeight(count: Int) -> CGFloat {
        let rows = CGFloat(rows(count: count))
        return LedgeMetrics.gridPad * 2
            + rows * LedgeMetrics.cardSize
            + (rows - 1) * LedgeMetrics.cardGap
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
        addSubview(closeBead)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Rebuild the grid from the strip. Called on every present: the catalog is
    /// a full snapshot (spec §3.6), so the grid is rebuilt from it rather than
    /// diffed — there are at most a handful of cards and no state on them worth
    /// preserving except the pointer, which is re-read at the end.
    func apply(cards newCards: [Card], current newCurrent: String? = nil) {
        guard newCards != cards || newCurrent != current else { return }
        cards = newCards
        current = newCurrent
        for view in cardViews { view.removeFromSuperview() }
        cardViews = newCards.map { card in
            let view = CardView(card: card)
            view.onPress = { [weak self] in self?.onSelect?(card.app) }
            addSubview(view, positioned: .below, relativeTo: closeBead)
            return view
        }
        hovered = nil
        closeBead.isHidden = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let count = cardViews.count
        let columns = Self.columns(count: count)
        let size = LedgeMetrics.cardSize
        let gap = LedgeMetrics.cardGap
        for (index, view) in cardViews.enumerated() {
            let row = index / columns
            let column = index % columns
            // Each row centres its own width, so a short last row sits in the
            // middle of the grid rather than hanging off its left edge.
            let inRow = min(columns, count - row * columns)
            let rowWidth = CGFloat(inRow) * size + CGFloat(inRow - 1) * gap
            view.baseFrame = CGRect(
                x: (bounds.width - rowWidth) / 2 + CGFloat(column) * (size + gap),
                y: LedgeMetrics.gridPad + CGFloat(row) * (size + gap),
                width: size,
                height: size
            )
        }
        syncPointer()
    }

    // MARK: - The swell toward the cursor

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

    /// Whether the grid magnifies at all. Reduce Motion keeps every card flat
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
    /// (shell/README.md), and the grid arrives in the middle of exactly that.
    private func syncPointer() {
        guard let window else {
            apply(pointer: nil)
            return
        }
        apply(pointer: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    /// The whole gesture, on a plain coordinate in the surface's own space:
    /// how much each card swells, which one is hovered, and where the ✕ goes.
    /// Exposed so the falloff can be asserted without synthesizing mouse-moved
    /// events into a window that does not exist headlessly.
    func apply(pointer: CGPoint?) {
        var under: CardView?
        for view in cardViews {
            let factor: CGFloat = if let pointer, magnifies {
                LedgeMetrics.cardMagnification(
                    distance: hypot(
                        pointer.x - view.baseFrame.midX,
                        pointer.y - view.baseFrame.midY
                    )
                )
            } else {
                0
            }
            view.setMagnification(factor)
            if let pointer, view.baseFrame.contains(pointer) {
                under = view
            }
        }
        setHovered(under)
    }

    private func setHovered(_ view: CardView?) {
        hovered?.isHovered = false
        hovered = view
        view?.isHovered = true
        // A swollen card overlaps its neighbours, so the one under the hand
        // comes forward — still under the ✕, which belongs to it.
        if let view { addSubview(view, positioned: .below, relativeTo: closeBead) }

        // The ✕ belongs to a session, so the blank slot never has one: there is
        // nothing there to stop.
        guard let view, let app = view.card.app else {
            closeBead.isHidden = true
            return
        }
        let size = closeBead.intrinsicContentSize
        closeBead.isHidden = false
        // Riding the swollen card's top-right corner, half on the glass —
        // where a badge on a card goes, and it travels with the swell.
        closeBead.frame = CGRect(
            x: view.frame.maxX - 8 - size.width / 2,
            y: view.frame.minY + 8 - size.height / 2,
            width: size.width,
            height: size.height
        )
        closeBead.setAccessibilityLabel("Stop \(view.card.name)")
        stopAction = { [weak self] in self?.onStop?(app) }
    }

    // MARK: - Test seams

    var cardViewsForTesting: [CardView] { cardViews }
    /// Where the cards sit on the grid, before the cursor swells any of them.
    var cardFrames: [CGRect] { cardViews.map(\.baseFrame) }
    /// …and where they are right now, which is the same thing until a pointer
    /// arrives.
    var cardLiveFrames: [CGRect] { cardViews.map(\.frame) }
    var cardMagnifications: [CGFloat] { cardViews.map(\.magnification) }
    var closeBeadView: LedgeButton { closeBead }
    var isShowingClose: Bool { !closeBead.isHidden }
}

/// One session, square on the grid.
///
/// Not a `LedgeButton`: a bead is the glass swelling and this is a *pane* of
/// it — a card of the slab material, fully rounded, swelling about its own
/// centre as the cursor nears. The only thing it shares with a button is that
/// pressing it does something.
@MainActor
final class CardView: FlippedView {
    let card: OverviewSurfaceView.Card
    var onPress: (() -> Void)?

    private let fill = CAGradientLayer()
    private let dashed = CAShapeLayer()
    private let glyph = NSImageView()
    private(set) var magnification: CGFloat = 0

    init(card: OverviewSurfaceView.Card) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true

        if card.isBlank {
            // "At most one blank exists" (flow.md) and it is drawn as an empty
            // frame: a dashed rounded square with no fill, so it reads as a
            // space for a card rather than a card that failed to load.
            dashed.fillColor = nil
            dashed.strokeColor = LedgeTheme.track.cgColor
            dashed.lineWidth = LedgeMetrics.hairline
            dashed.lineDashPattern = [3, 3]
            layer?.addSublayer(dashed)
        } else {
            fill.startPoint = CGPoint(x: 0.5, y: 0)
            fill.endPoint = CGPoint(x: 0.5, y: 1)
            fill.colors = [LedgeTheme.slabFillTop.cgColor, LedgeTheme.slabFillBottom.cgColor]
            // The card clips its own material; the shadow lives on the view's
            // layer, which does not clip — a layer cannot cast a shadow it has
            // clipped away.
            fill.cornerCurve = .continuous
            fill.masksToBounds = true
            fill.borderWidth = LedgeMetrics.hairline
            fill.borderColor = LedgeTheme.slabEdgeSide.cgColor
            layer?.addSublayer(fill)
            // The card rung of the shadow ramp: a swollen card hangs off the
            // grid exactly as the panel hangs off the notch. There is no fourth
            // shadow (principle 15).
            if let layer {
                LedgeShadow.panel.applyGeometry(to: layer)
                layer.shadowOpacity = 0
            }
        }

        glyph.image = NSImage(
            systemSymbolName: card.icon,
            accessibilityDescription: card.name
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: LedgeMetrics.cardGlyphPointSize,
                weight: LedgeMetrics.cardGlyphWeight
            )
        )
        // Big and white — a card's whole content is its glyph, so this is the
        // one place the catalog icon is the datum rather than a label's
        // punctuation (principle 5). The blank slot's `+` is quieter: it is an
        // invitation, not a session.
        glyph.contentTintColor = card.isBlank ? LedgeTheme.tertiary : LedgeTheme.primary
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(card.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // The radius swells with the card, so a zoomed card is the same card
        // closer to you rather than one whose corners tightened.
        let scale = 1 + LedgeMetrics.cardMagnify * magnification
        let radius = LedgeMetrics.cardRadius * scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.cornerRadius = radius
        dashed.frame = bounds
        dashed.path = CGPath(
            roundedRect: bounds.insetBy(
                dx: LedgeMetrics.hairline / 2,
                dy: LedgeMetrics.hairline / 2
            ),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
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

    /// Where this card sits when nothing is swelling it — its place on the
    /// grid, set by the grid's own layout. The live `frame` is this plus
    /// whatever the cursor is doing to it.
    var baseFrame: CGRect = .zero {
        didSet {
            guard baseFrame != oldValue else { return }
            applySwell()
        }
    }

    /// Apply one frame of the swell. `factor` is the gaussian's value: 0 at
    /// rest, 1 directly under the cursor.
    func setMagnification(_ factor: CGFloat) {
        guard factor != magnification else { return }
        magnification = factor
        applySwell()
    }

    /// Grow **about the centre** — the card comes toward you; it is not
    /// standing on anything.
    ///
    /// Real geometry, not a layer transform: a transformed layer-backed view
    /// does not appear in `cacheDisplay` (every snapshot would show the grid
    /// flat), and a scaled *glyph* is a blurred glyph — a card that grows
    /// around a glyph that stays sharp reads exactly like a pane coming
    /// forward.
    private func applySwell() {
        let scale = 1 + LedgeMetrics.cardMagnify * magnification
        let width = baseFrame.width * scale
        let height = baseFrame.height * scale
        frame = CGRect(
            x: baseFrame.midX - width / 2,
            y: baseFrame.midY - height / 2,
            width: width,
            height: height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowOpacity = card.isBlank ? 0 : LedgeShadow.panel.opacity * Float(magnification)
        CATransaction.commit()
        needsLayout = true
    }

    var isHovered = false {
        didSet {
            guard isHovered != oldValue, !card.isBlank else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(LedgeMotion.fast)
            fill.borderColor = (
                isHovered ? LedgeTheme.slabEdgeHighlightHover : LedgeTheme.slabEdgeSide
            ).cgColor
            CATransaction.commit()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Press-and-release inside, like every other control in the kit; the
        // card does not sink, because it is already moving under the cursor.
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
