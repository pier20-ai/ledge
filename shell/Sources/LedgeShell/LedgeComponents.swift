import AppKit
import QuartzCore

enum LedgeAxis {
    case horizontal
    case vertical
}

/// A node whose children do **not** attach to the node's own view — a scrolling
/// stack is a clip view wrapping the stack, so the renderer has to know where a
/// child actually goes. Without this indirection `insert` would add children to
/// the scroll container and they would never scroll.
@MainActor
protocol LedgeContentHosting: AnyObject {
    var contentView: NSView { get }
}

final class LedgeStackView: NSStackView {
    init(axis: LedgeAxis, gap: CGFloat = LedgeMetrics.gap, pad: CGFloat = 0, views: [NSView] = []) {
        super.init(frame: .zero)
        orientation = axis == .horizontal ? .horizontal : .vertical
        spacing = gap
        edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        alignment = axis == .horizontal ? .centerY : .leading
        distribution = .fill
        views.forEach(addArrangedSubview)
        syncFillWidths()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var fillWidths: [NSLayoutConstraint] = []

    /// Set when this stack declared `scroll` and is therefore living inside a
    /// `LedgeScrollStackView`. The renderer tells the wrapper to re-measure when
    /// children arrive; walking the superview chain (clip → scroll → wrapper)
    /// would be three AppKit implementation details deep.
    weak var scrollHost: LedgeScrollStackView?

    /// A vertical stack stretches its children to its own width, so rows,
    /// boxes, charts and sliders span the panel without every app repeating a
    /// width; anything narrower goes in an h-stack next to a spacer.
    ///
    /// This is done with explicit constraints rather than NSStackView's
    /// `.width` alignment, whose priority ties with content hugging: the tie
    /// resolves to "intrinsic width, pinned to the *trailing* edge", which
    /// silently right-aligns every bare label.
    func syncFillWidths() {
        NSLayoutConstraint.deactivate(fillWidths)
        fillWidths = []
        guard orientation == .vertical else { return }
        let inset = edgeInsets.left + edgeInsets.right
        fillWidths = arrangedSubviews.map { child in
            let constraint = child.widthAnchor.constraint(equalTo: widthAnchor, constant: -inset)
            // Below required so a fixed-size child (an image, a badge) keeps its
            // size and simply sits at the leading edge.
            constraint.priority = NSLayoutConstraint.Priority(500)
            return constraint
        }
        NSLayoutConstraint.activate(fillWidths)
    }

    /// Semantic container styling (spec §5 proposal). `nil` clears.
    func applyContainer(fill: NSColor?, stroke: NSColor?, radius: CGFloat?) {
        guard fill != nil || stroke != nil || radius != nil || wantsLayer else { return }
        wantsLayer = true
        layer?.backgroundColor = (fill ?? .clear).cgColor
        layer?.borderColor = (stroke ?? .clear).cgColor
        layer?.borderWidth = stroke == nil ? 0 : LedgeMetrics.hairline
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius ?? 0
        layer?.masksToBounds = (radius ?? 0) > 0
    }
}

/// A vertical `stack` that declared `scroll` (spec §5). The stack itself is
/// unchanged — including `syncFillWidths`, so rows still span the column — and is
/// hung inside a transparent `NSScrollView` whose height is capped. Below the cap
/// this is invisible; above it the list scrolls instead of being clipped by the
/// panel, which is what deals' list and chess's move list do today.
///
/// Horizontal elasticity is off: a vertical list that rubber-bands sideways reads
/// as a bug, and nothing in the vocabulary is wider than its column.
final class LedgeScrollStackView: NSView, LedgeContentHosting {
    let stack: LedgeStackView
    private let scrollView = NSScrollView()
    /// Ceiling from the panel limit — a stack cannot ask for more room than the
    /// panel has, and the whole point is to stop asking.
    private let maxHeight: CGFloat
    /// Last height handed to Auto Layout, so `layout()` re-measures only when the
    /// content actually changed rather than every pass.
    private var reportedHeight: CGFloat = -1

    init(stack: LedgeStackView, maxHeight: CGFloat) {
        self.stack = stack
        self.maxHeight = max(0, maxHeight)
        super.init(frame: .zero)
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true          // nothing visible until it scrolls
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        // An Auto Layout document view has to say so: left as-is, NSScrollView
        // also sets the stack's frame and the two fight (a conflict at best, a
        // layout loop at worst).
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        stack.scrollHost = self
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The stack keeps the clip view's width, so it only ever scrolls in
            // one axis and its children's fill-width constraints still resolve.
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        heightAnchor.constraint(lessThanOrEqualToConstant: self.maxHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var contentView: NSView { stack }

    /// The panel measures `fittingSize`, so the cap has to live here rather than
    /// in the panel: the app's tree reports the height it will actually occupy.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: cappedHeight)
    }

    /// `fittingSize` resolves the stack's own constraints without running a layout
    /// pass — calling `layoutSubtreeIfNeeded()` from inside `layout()` recurses.
    private var cappedHeight: CGFloat {
        min(ceil(stack.fittingSize.height), maxHeight)
    }

    /// A commit changes the stack's content but not this view's constraints, so
    /// re-measure after layout and invalidate only on a real change (converges).
    override func layout() {
        super.layout()
        contentChanged()
    }

    func contentChanged() {
        let height = cappedHeight
        guard abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        invalidateIntrinsicContentSize()
    }
}

/// A `wing` node (spec §5, panel wings): the app's content for the zone beside
/// the hardware cutout at the top of its expanded panel.
///
/// It is a `LedgeContentHosting` wrapper around a horizontal stack, for the same
/// reason `LedgeScrollStackView` is one: children attach to the stack, never to
/// the wrapper, so the renderer's `insert` lands in the right place without
/// knowing what a wing is. The wrapper itself is never inserted into the app's
/// content stack — the renderer routes it to the zone (see `ProtocolRenderer`).
///
/// The zone is small and its right-hand neighbour is a hole in the display, so
/// the two layout rules are hard bounds rather than preferences: content is
/// vertically centred in the row, and the wrapper **clips**. The trailing
/// constraint is required, which is what makes an over-long label lose its
/// compression-resistance argument and ellipsize instead of running under the
/// camera.
/// The container for a `mini` node (spec §3.3 extension).
///
/// Deliberately NOT `LedgeWingView`, which was the first thing tried and is
/// wrong here: a wing's stack is pinned `leading` + `centerY` with `trailing ≤`,
/// because the wing bar hands it an exact frame. Nothing in that drives a width
/// or a height, so its `fittingSize` is ~zero — and the peek surface *asks* its
/// content how big it wants to be. The result was a correctly-shaped, entirely
/// empty black box.
///
/// So the stack is pinned on all four edges: the view is exactly as big as its
/// content, which is the one thing the peek surface needs from it.
final class LedgeMiniView: FlippedView, LedgeContentHosting {
    let stack: LedgeStackView

    init() {
        stack = LedgeStackView(axis: .horizontal, gap: LedgeMetrics.gap)
        super.init(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var contentView: NSView { stack }
}

final class LedgeWingView: FlippedView, LedgeContentHosting {
    let stack: LedgeStackView

    init() {
        stack = LedgeStackView(axis: .horizontal, gap: LedgeMetrics.panelWingGap)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var contentView: NSView { stack }
}

/// A `text` node (spec §5). Font and color are always set by the renderer from
/// the node's props right after construction, so this only has to be a
/// correctly-configured single-line label.
final class LedgeText: NSTextField {
    /// How many lines the app allowed (spec §5 `maxLines`). 1 is the default and
    /// the law: text never wraps unless it was asked to (L7).
    private(set) var lineLimit = 1
    /// §5 `truncate`. True (default) ends an over-long line with an ellipsis;
    /// false clips it flush. Either way the app chose — nothing wraps silently.
    private(set) var truncates = true

    init(_ content: String) {
        super.init(frame: .zero)
        stringValue = content
        font = LedgeTheme.systemFont(LedgeMetrics.textDefaultPointSize)
        textColor = LedgeTheme.primary
        isEditable = false
        isBordered = false
        // A bare NSTextField is bezeled: the bezel eats a couple of points on
        // each side at *draw* time without widening the intrinsic size, so a
        // label sized to its own string truncates by a character or two. The
        // `labelWithString:` convenience clears this; a subclass has to say so.
        isBezeled = false
        drawsBackground = false
        isSelectable = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.wraps = false
        // Horizontally a label is happy to be stretched — it draws from its
        // leading edge either way, so a vertical stack can fill it to the panel
        // width. A `spacer` hugs weaker still, so it is the spacer that absorbs
        // a row's slack. Vertically a label must never stretch, or rows would
        // grow to fill the panel.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setAccessibilityLabel(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Apply the §5 line props. `maxLines > 1` opts into wrapping up to N lines
    /// and then tail-truncating; 1 keeps the single-line law (L7).
    func applyLines(maxLines: Int, truncate: Bool) {
        let limit = max(1, maxLines)
        guard limit != lineLimit || truncate != truncates else { return }
        lineLimit = limit
        truncates = truncate
        if limit > 1 {
            // The order is not cosmetic. `lineBreakMode = .byTruncatingTail` on an
            // NSTextField *clears* `cell.wraps` as a side effect — set it after
            // `wraps` and the field silently goes back to one line, which is
            // exactly the bug that made this look implemented once already.
            // Wrapping plus `truncatesLastVisibleLine` is what gives "wrap to N
            // lines, then ellipsize", which is what `maxLines` means.
            usesSingleLineMode = false
            lineBreakMode = .byWordWrapping
            cell?.wraps = true
            cell?.isScrollable = false
            (cell as? NSTextFieldCell)?.truncatesLastVisibleLine = true
        } else {
            usesSingleLineMode = true
            cell?.wraps = false
            lineBreakMode = truncate ? .byTruncatingTail : .byClipping
        }
        maximumNumberOfLines = limit
        measuredWidth = 0
        preferredMaxLayoutWidth = 0
        invalidateIntrinsicContentSize()
    }

    /// The width the wrapped height was last measured at, so `layout()` only
    /// re-measures when the column actually changed.
    private var measuredWidth: CGFloat = 0

    /// A truncating NSTextField under-reports its intrinsic width by a few
    /// points, so a label laid out at exactly that width draws with an ellipsis
    /// it does not need — "$214.62" arrives as "$214…". Measure the string and
    /// take the wider answer; the same trick `LedgeButton` uses for its label.
    ///
    /// Multi-line is worse than under-reporting: an NSTextField top-aligns and
    /// reports a *single* line's height no matter how many it will draw, so a
    /// three-line note is laid out one line tall and loses two. Measure the
    /// attributed string against the available column instead, and cap the answer
    /// at `maxLines` — that cap is what makes the truncation visible rather than
    /// letting the label grow forever.
    override var intrinsicContentSize: NSSize {
        guard lineLimit > 1 else {
            var size = super.intrinsicContentSize
            size.width = max(
                size.width,
                ceil(attributedStringValue.size().width) + LedgeMetrics.textMeasureSlack
            )
            return size
        }
        let column = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
        guard column > 0 else { return super.intrinsicContentSize }
        let wrapped = wrappingCopy.boundingRect(
            with: CGSize(width: column, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let line = singleLineHeight
        let height = min(ceil(wrapped.height), line * CGFloat(lineLimit))
        // No intrinsic width: a wrapping label takes the column it was given, and
        // claiming its unwrapped width would fight the stack's fill constraint.
        return NSSize(width: NSView.noIntrinsicMetric, height: max(line, ceil(height)))
    }

    /// The same string, but allowed to wrap. `attributedStringValue` carries the
    /// field's own paragraph style, whose `lineBreakMode` is tail-truncation — and
    /// `boundingRect` honors it, so measuring the string as-is answers "one line,
    /// always" no matter how wide the text is. That is exactly the under-report
    /// L7 warns about, one level down.
    private var wrappingCopy: NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: attributedStringValue)
        guard copy.length > 0 else { return copy }
        let existing = copy.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        copy.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: copy.length)
        )
        return copy
    }

    /// One line of this label's own type, leading included.
    private var singleLineHeight: CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? LedgeTheme.systemFont(LedgeMetrics.textDefaultPointSize),
        ]
        if attributedStringValue.length > 0 {
            attributes = attributedStringValue.attributes(at: 0, effectiveRange: nil)
        }
        return ceil(NSAttributedString(string: "Xg", attributes: attributes).size().height)
    }

    /// The wrapped height depends on the column, which Auto Layout only knows
    /// once it has sized this label — so re-measure on every width change and ask
    /// the parent to lay out again with the taller answer. Guarded on the width,
    /// so it converges after one extra pass instead of looping.
    ///
    /// `setFrameSize` rather than `layout()`: AppKit only calls `layout()` on a
    /// view it thinks has subviews to arrange, and a label has none — so the
    /// column change would arrive nowhere.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        settleWrapColumn()
    }

    override func layout() {
        super.layout()
        settleWrapColumn()
    }

    private func settleWrapColumn() {
        guard lineLimit > 1, bounds.width > 0 else { return }
        guard abs(bounds.width - measuredWidth) > 0.5 else { return }
        measuredWidth = bounds.width
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

enum LedgeButtonVariant {
    case plain
    case glass
    case accent
}

/// Custom control instead of NSButton: the icon + label group is measured and
/// centered exactly, which NSButton's cell metrics never quite do with custom
/// fonts and SF Symbols.
final class LedgeButton: NSControl {
    private var variant: LedgeButtonVariant
    private let handler: () -> Void
    private let label: NSTextField
    private var iconView: NSImageView?
    /// Kept because `NSImage.name()` is nil once `withSymbolConfiguration` has
    /// copied the image — and the glyph has to be *rebuilt* at a different point
    /// size whenever the button crosses the icon-only boundary (D8/Q3).
    private var symbolName: String?
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var size: LedgeMetrics.Size
    private var disabled = false

    /// Test/introspection accessors. `iconFrame`/`labelFrame` are what the
    /// centering law (L2) is actually asserted against — "the icon looks centered"
    /// is how the 5 pt offset survived eleven apps.
    var currentLabel: String { label.stringValue }
    var iconFrame: CGRect? { iconView?.frame }
    var labelFrame: CGRect { label.frame }
    var iconPointSize: CGFloat? {
        iconView?.image?.symbolConfiguration != nil
            ? (isIconOnly ? LedgeMetrics.iconOnlyPointSize : LedgeMetrics.buttonIconPointSize)
            : nil
    }
    var contentAlpha: CGFloat { label.alphaValue }
    var currentSize: LedgeMetrics.Size { size }
    var isDisabled: Bool { disabled }
    /// A status hue for a `glass` button: the fill and the hairline take the
    /// colour, the content stays ink. Added for the Edit/Preview toggle, which
    /// has to carry "the app reloaded" / "the app crashed" without becoming a
    /// fourth variant — the shape, size and behaviour are unchanged, only the
    /// wash is. nil restores the ordinary glass treatment.
    var tint: NSColor? {
        didSet {
            guard tint != oldValue else { return }
            refreshAppearance()
        }
    }
    /// A tint that FILLS rather than washes, with white ink over it.
    ///
    /// `tint` is deliberately a wash — a state of the same control. This is for
    /// the one case that is not a state but a mode: while the editor is open,
    /// the toggle is the way back to your app, and it has to be findable at a
    /// glance in a panel full of transcript. A filled chip is that; a tinted
    /// glass button is not.
    var filledTint: NSColor? {
        didSet {
            guard filledTint != oldValue else { return }
            refreshInk()
            refreshAppearance()
        }
    }
    /// An empty label earns no width and no gap (law L2), which is exactly what
    /// makes this button a square — and, with the capsule rule, a circle.
    var isIconOnly: Bool { label.stringValue.isEmpty }

    init(
        _ title: String,
        symbol: String? = nil,
        variant: LedgeButtonVariant = .plain,
        size: LedgeMetrics.Size = .default,
        disabled: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.variant = variant
        self.size = size
        self.disabled = disabled
        self.handler = handler
        self.symbolName = symbol
        label = makeLabel(
            title,
            font: LedgeTheme.systemFont(11.5, weight: .semibold),
            color: variant == .accent ? LedgeTheme.glassSolid : LedgeTheme.primary
        )
        super.init(frame: .zero)

        addSubview(label)
        rebuildIcon()
        setAccessibilityLabel(title.isEmpty ? (symbol ?? "") : title)
        setAccessibilityRole(.button)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = LedgeMetrics.capsule(size.height)
        layer?.borderWidth = variant == .glass ? LedgeMetrics.hairline : 0
        refreshHugging()
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Partial-update entry point for the protocol renderer: a chessboard's
    /// pieces are button labels, so `update` ops must actually redraw. `label`,
    /// `symbol` and `variant` are nil = leave unchanged (`symbol: .some(nil)`
    /// removes the icon); `size` and `disabled` always arrive resolved, because
    /// the renderer hands over the *merged* prop set and a deleted `disabled`
    /// has to re-enable the button rather than read as "unchanged".
    func apply(
        label newLabel: String? = nil,
        symbol: String?? = nil,
        variant newVariant: LedgeButtonVariant? = nil,
        size newSize: LedgeMetrics.Size? = nil,
        disabled newDisabled: Bool? = nil
    ) {
        let wasIconOnly = isIconOnly
        if let newLabel {
            label.stringValue = newLabel
            setAccessibilityLabel(newLabel.isEmpty ? (symbolName ?? "") : newLabel)
        }
        if let newVariant {
            variant = newVariant
            layer?.borderWidth = variant == .glass ? LedgeMetrics.hairline : 0
        }
        if let newSize { size = newSize }
        if let newDisabled { disabled = newDisabled }
        if let symbol {
            symbolName = symbol
            rebuildIcon()
        } else if wasIconOnly != isIconOnly {
            // The label crossed the empty/non-empty line, so the glyph's point
            // size and weight changed even though the symbol did not.
            rebuildIcon()
        }
        refreshInk()
        applyDisabledAlpha()
        refreshHugging()
        refreshAppearance()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func rebuildIcon() {
        iconView?.removeFromSuperview()
        iconView = nil
        guard let symbolName else { return }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: isIconOnly ? LedgeMetrics.iconOnlyPointSize : LedgeMetrics.buttonIconPointSize,
                    weight: isIconOnly ? LedgeMetrics.iconOnlyWeight : LedgeMetrics.buttonIconWeight
                )
            )
        icon.contentTintColor = variant == .accent ? LedgeTheme.glassSolid : LedgeTheme.primary
        addSubview(icon)
        iconView = icon
        applyDisabledAlpha()
    }

    private func applyDisabledAlpha() {
        let alpha = disabled ? LedgeMetrics.disabledAlpha : 1
        label.alphaValue = alpha
        iconView?.alphaValue = alpha
        isEnabled = !disabled
    }

    /// A *labeled* button stretches to its column — that is deliberate, and every
    /// app's primary action relies on it. An icon-only button must not: a
    /// full-width capsule with one glyph adrift in the middle of it is not the
    /// 34 × 34 circle D6 specifies. Hugging above a vertical stack's fill
    /// constraint (priority 500) is what keeps it square wherever it is placed.
    private func refreshHugging() {
        setContentHuggingPriority(
            isIconOnly ? NSLayoutConstraint.Priority(751) : .defaultLow,
            for: .horizontal
        )
    }

    /// The measured content group: an *empty* label contributes zero width and
    /// zero gap (L2, D1's defect). Everything else follows from that.
    private var contentSizes: (icon: CGSize, label: CGSize, gap: CGFloat) {
        let iconSize = iconView?.image.map { image in
            CGSize(width: ceil(image.size.width), height: ceil(image.size.height))
        } ?? .zero
        guard !isIconOnly else { return (iconSize, .zero, 0) }
        let measured = label.attributedStringValue.size()
        let labelSize = CGSize(
            width: ceil(measured.width) + LedgeMetrics.labelCellPad,
            height: ceil(measured.height)
        )
        return (iconSize, labelSize, iconView == nil ? 0 : LedgeMetrics.buttonIconGap)
    }

    /// Lets the button size itself inside an Auto Layout stack. Icon-only ⇒
    /// square, so the capsule rule draws a circle (D8/Q1).
    override var intrinsicContentSize: NSSize {
        guard !isIconOnly else {
            return NSSize(width: size.height, height: size.height)
        }
        let content = contentSizes
        return NSSize(
            width: content.icon.width + content.gap + content.label.width + size.padX * 2,
            height: size.height
        )
    }

    override func layout() {
        super.layout()
        // Corner changes are layout, not state: they must not cross-fade (L6).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = LedgeMetrics.capsule(bounds.height > 0 ? bounds.height : size.height)
        CATransaction.commit()

        let content = contentSizes
        let contentWidth = content.icon.width + content.gap + content.label.width
        var x = (bounds.width - contentWidth) / 2
        if let iconView {
            iconView.frame = CGRect(
                x: x,
                y: (bounds.height - content.icon.height) / 2,
                width: content.icon.width,
                height: content.icon.height
            )
            x += content.icon.width + content.gap
        }
        label.frame = CGRect(
            x: x,
            y: (bounds.height - content.label.height) / 2,
            width: content.label.width,
            height: content.label.height
        )
        syncHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
        syncHover()
    }

    override func mouseEntered(with event: NSEvent) {
        syncHover()
    }

    override func mouseExited(with event: NSEvent) {
        syncHover()
    }

    /// Enter/exit pairs go stale when the panel morphs and this button moves
    /// under a stationary cursor — always verify against the live pointer.
    private func syncHover() {
        let inside = !disabled && (window.map { window in
            bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        } ?? false)
        guard inside != hovering else { return }
        hovering = inside
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        // Disabled means disabled: no press scale, no hover, no handler (D6).
        guard !disabled else { return }
        let press = isIconOnly ? LedgeMetrics.pressScaleIcon : LedgeMetrics.pressScaleLabeled
        layer?.setPressScale(press, duration: LedgeMetrics.pressDurationIn)
        var clickedInside = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                clickedInside = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        layer?.setPressScale(1, duration: LedgeMetrics.pressDurationOut)
        if clickedInside {
            handler()
        }
    }

    /// White over a filled tint, otherwise the variant's own ink.
    ///
    /// White rather than `glassSolid` (black): the amber send button in the
    /// existing surfaces already carries a white glyph, so a black-inked amber
    /// chip beside it would read as a different control family.
    private func refreshInk() {
        let contentColor: NSColor = if filledTint != nil {
            .white
        } else if variant == .accent {
            LedgeTheme.glassSolid
        } else {
            LedgeTheme.primary
        }
        label.textColor = contentColor
        iconView?.contentTintColor = contentColor
    }

    private func refreshAppearance() {
        if let filledTint {
            layer?.backgroundColor = (
                hovering
                    ? filledTint.blended(withFraction: 0.12, of: .white) ?? filledTint
                    : filledTint
            ).cgColor
            layer?.borderColor = NSColor.clear.cgColor
            return
        }
        switch variant {
        case .plain:
            layer?.backgroundColor = hovering ? LedgeTheme.raisedHover.cgColor : NSColor.clear.cgColor
        case .glass:
            if let tint {
                // Same alphas the semantic container tokens use (D6): a tint is
                // a wash over the glass, never a filled chip — the toggle must
                // read as the same control in a different state, not as a
                // different control.
                layer?.backgroundColor = tint.withAlphaComponent(hovering ? 0.26 : 0.18).cgColor
                layer?.borderColor = tint.withAlphaComponent(hovering ? 0.55 : 0.40).cgColor
            } else {
                layer?.backgroundColor = (hovering ? LedgeTheme.raisedHover2 : LedgeTheme.raised).cgColor
                layer?.borderColor = (hovering ? LedgeTheme.hairlineHover : LedgeTheme.hairline).cgColor
            }
        case .accent:
            layer?.backgroundColor = (
                hovering ? LedgeTheme.accent.blended(withFraction: 0.12, of: .white) ?? LedgeTheme.accent : LedgeTheme.accent
            ).cgColor
        }
    }
}

/// An `image` node whose `src` is an SF Symbol (`sf:name`, spec §5), drawn at
/// the requested size. Deliberately unstyled — the box around an icon is a
/// `stack` with a `fill`/`radius`, so the same view serves a 5 pt dot and a
/// 54 pt artwork tile.
final class LedgeSymbolView: NSImageView {
    init(symbol: String, radius: CGFloat = 0) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: symbol)
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = LedgeTheme.primary
        if radius > 0 {
            wantsLayer = true
            layer?.cornerRadius = radius
            layer?.masksToBounds = true
        }
        setAccessibilityRole(.image)
        setAccessibilityLabel(symbol)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// An `image` node whose `src` is a file on disk (spec §5). Apps build the path
/// from `import.meta.dir`, so it arrives absolute and inside the app's own
/// folder; decoding and caching are `LedgeImageStore`'s job.
///
/// Aspect-**fill**, not fit: the picture covers the whole `w × h` box the app
/// asked for and the overflow is cropped, because an artwork tile with
/// letterbox bars baked into it is not a tile. `radius` clips the corners.
///
/// A path that does not resolve is not an error and not a loud "missing image"
/// glyph — it draws as a quiet raised box, the same shape the picture would
/// have occupied, so a half-written app looks unfinished rather than broken.
final class LedgeFileImageView: NSView {
    private(set) var path: String
    private var image: NSImage?

    init(path: String, radius: CGFloat = 0) {
        self.path = path
        super.init(frame: .zero)
        image = LedgeImageStore.shared.image(atPath: path)
        wantsLayer = true
        applyRadius(radius)
        setAccessibilityRole(.image)
        setAccessibilityLabel((path as NSString).lastPathComponent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Partial-update entry point (spec §3.1): each argument nil = unchanged.
    /// An app that swaps album art sends an `update` op on the same node, so
    /// `src` has to land without rebuilding the view.
    func apply(path newPath: String?, radius: CGFloat?) {
        if let newPath, newPath != path {
            path = newPath
            image = LedgeImageStore.shared.image(atPath: newPath)
            setAccessibilityLabel((newPath as NSString).lastPathComponent)
            needsDisplay = true
        }
        if let radius {
            applyRadius(radius)
        }
    }

    private func applyRadius(_ radius: CGFloat) {
        // Implicit layer animations would cross-fade the corner on every commit.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = max(0, radius)
        layer?.masksToBounds = radius > 0
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        // `draw(_:)` is not a clip: draw against `bounds`, never the dirty rect
        // (see shell/README.md), or a partial redraw loses the picture.
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            LedgeTheme.raised.setFill()
            bounds.fill()
            return
        }
        // Aspect fill: the largest centred source rect with the box's own aspect
        // ratio, stretched over the whole box. Equivalently, scale by whichever
        // axis needs the most and crop the other.
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let visible = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let source = CGRect(
            x: (image.size.width - visible.width) / 2,
            y: (image.size.height - visible.height) / 2,
            width: visible.width,
            height: visible.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1)
    }
}

final class LedgeSpacerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Hugs weaker than anything else in a row, so a row's slack always
        // lands here rather than stretching a label or a button.
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class LedgeChartView: NSView {
    var points: [CGFloat] {
        didSet { needsDisplay = true }
    }
    var color: NSColor
    var showsFill: Bool

    init(points: [CGFloat], color: NSColor = LedgeTheme.green, showsFill: Bool = true) {
        self.points = points
        self.color = color
        self.showsFill = showsFill
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Chart")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let minValue = points.min() ?? 0
        let maxValue = points.max() ?? 1
        let range = max(maxValue - minValue, 0.001)
        let dx = bounds.width / CGFloat(points.count - 1)
        let path = NSBezierPath()
        let inset = LedgeMetrics.chartInsetY
        for (index, value) in points.enumerated() {
            let normalized = (value - minValue) / range
            let point = CGPoint(x: CGFloat(index) * dx, y: inset + normalized * (bounds.height - inset * 2))
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineWidth = LedgeMetrics.chartStroke
        path.lineJoinStyle = .round

        if showsFill {
            let fillPath = path.copy() as! NSBezierPath
            fillPath.line(to: CGPoint(x: bounds.maxX, y: 0))
            fillPath.line(to: CGPoint(x: 0, y: 0))
            fillPath.close()
            NSGradient(
                starting: color.withAlphaComponent(LedgeMetrics.chartFillAlpha),
                ending: color.withAlphaComponent(0)
            )?.draw(in: fillPath, angle: -90)
        }
        color.setStroke()
        path.stroke()
    }
}

final class LedgeSlider: NSControl {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobLayer = CALayer()
    private let handler: (Double) -> Void

    /// The app's own scale (spec §5 `min`/`max`, ratified in D6 — until now the
    /// props were accepted and silently ignored, so a BPM slider was 0…1). The
    /// geometry below is still normalized; only the *number* changes space.
    private(set) var rangeMin: Double = 0
    private(set) var rangeMax: Double = 1
    /// `step`: nil is continuous. A stepped slider snaps, which means the knob
    /// tracks the *snapped* value — that is the point of asking for a step.
    private(set) var step: Double?

    /// `rate` (spec §5): value units per second of shell-side self-advance, so a
    /// scrubber glides at 60 fps between a monitor's three-second polls. Built
    /// in `init` because it captures `self`.
    private var advancer: LedgeSelfAdvance!

    /// In `rangeMin…rangeMax` space, clamped and snapped on every write.
    var value: Double {
        didSet {
            value = resolve(value)
            setAccessibilityValue(value)
            needsLayout = true
        }
    }

    /// Knob position as a 0…1 fraction of the track.
    var position: Double {
        let span = rangeMax - rangeMin
        guard span > 0 else { return 0 }
        return min(max((value - rangeMin) / span, 0), 1)
    }

    init(
        value: Double,
        min lower: Double = 0,
        max upper: Double = 1,
        step: Double? = nil,
        handler: @escaping (Double) -> Void
    ) {
        self.rangeMin = lower
        self.rangeMax = Swift.max(upper, lower)
        self.step = step.flatMap { $0 > 0 ? $0 : nil }
        self.handler = handler
        self.value = 0
        super.init(frame: .zero)
        self.value = value              // clamps/snaps through `didSet`
        wantsLayer = true
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(rangeMin)
        setAccessibilityMaxValue(rangeMax)
        setAccessibilityValue(self.value)

        trackLayer.backgroundColor = LedgeTheme.track.cgColor
        // Ink, not accent: progress is content, and accent stays reserved for
        // actions (D8/Q6, law L9).
        fillLayer.backgroundColor = LedgeTheme.inkFill.cgColor
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.4
        knobLayer.shadowRadius = 3
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(knobLayer)
        advancer = LedgeSelfAdvance(owner: self) { [weak self] delta in
            guard let self else { return }
            // `value`'s own didSet clamps at rangeMax: a track that ran past its
            // duration sits at the end rather than walking off the track.
            self.value += delta
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Test/introspection: is the self-advance tick live?
    var isSelfAdvancing: Bool { advancer.isAdvancing }
    var rate: Double { advancer.rate }

    /// `rate` from a prop update. Resolved, not optional: a deleted key is "back
    /// to static", never "unchanged".
    func applyRate(_ rate: Double?) {
        advancer.setRate(rate)
    }

    /// A committed value, reconciled against wherever the local advance has got
    /// to. A poll that lands a few hundred milliseconds off is jitter and is
    /// ignored (the local clock is the better estimate between polls); anything
    /// bigger is the app telling us something — a seek, a new track — and jumps.
    func applyCommittedValue(_ next: Double) {
        guard advancer.rate > 0, !advancer.isSuspended else {
            value = next
            return
        }
        let tolerance = advancer.rate * LedgeMetrics.selfAdvanceGlideSeconds
        if abs(next - value) > tolerance { value = next }
    }

    /// Advance as if `seconds` had passed — the timer's own path, exposed so a
    /// test does not have to sleep.
    func advance(by seconds: Double) {
        advancer.advance(by: seconds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        advancer.sync()
    }

    /// Re-declare the scale from a prop update, then re-resolve the value into it
    /// — an app that narrows `max` under a value must not be left out of range.
    func applyRange(min lower: Double?, max upper: Double?, step newStep: Double??) {
        if let lower { rangeMin = lower }
        if let upper { rangeMax = upper }
        if rangeMax < rangeMin { rangeMax = rangeMin }
        if let newStep { step = newStep.flatMap { $0 > 0 ? $0 : nil } }
        setAccessibilityMinValue(rangeMin)
        setAccessibilityMaxValue(rangeMax)
        // Re-run the clamp/snap through `didSet` against the *new* scale.
        let current = value
        value = current
    }

    /// Clamp into range, then snap to the step grid measured from `rangeMin`.
    private func resolve(_ raw: Double) -> Double {
        let clamped = Swift.min(Swift.max(raw, rangeMin), rangeMax)
        guard let step, step > 0 else { return clamped }
        let snapped = rangeMin + (((clamped - rangeMin) / step).rounded() * step)
        return Swift.min(Swift.max(snapped, rangeMin), rangeMax)
    }

    override func layout() {
        super.layout()
        // Implicit layer animations would make the knob ease toward every
        // drag tick — the thumb must track the pointer exactly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pad = LedgeMetrics.sliderPadX
        let bar = LedgeMetrics.sliderTrackHeight
        let knob = LedgeMetrics.sliderKnob
        let track = CGRect(
            x: pad,
            y: bounds.midY - bar / 2,
            width: Swift.max(bounds.width - pad * 2, 0),
            height: bar
        )
        let knobCenter = track.minX + CGFloat(position) * track.width
        trackLayer.frame = track
        trackLayer.cornerRadius = LedgeMetrics.rTrack
        fillLayer.frame = CGRect(
            x: track.minX,
            y: track.minY,
            width: Swift.max(LedgeMetrics.rTrack, knobCenter - track.minX),
            height: bar
        )
        fillLayer.cornerRadius = LedgeMetrics.rTrack
        knobLayer.frame = CGRect(
            x: knobCenter - knob / 2,
            y: bounds.midY - knob / 2,
            width: knob,
            height: knob
        )
        knobLayer.cornerRadius = LedgeMetrics.capsule(knob)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        // Self-advance yields to the pointer: while the user holds the thumb,
        // they are the authority on where it is. It resumes on mouse-up, from
        // wherever they left it.
        advancer.setSuspended(true)
        defer { advancer.setSuspended(false) }
        update(with: event)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            update(with: next)
        }
    }

    private func update(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let pad = LedgeMetrics.sliderPadX
        let fraction = Double((local.x - pad) / Swift.max(bounds.width - pad * 2, 1))
        let before = value
        value = rangeMin + Swift.min(Swift.max(fraction, 0), 1) * (rangeMax - rangeMin)
        layoutSubtreeIfNeeded()
        // A stepped slider only reports when it actually moved a step, so an app
        // does not get 60 identical `change` events per drag second.
        guard step == nil || value != before else { return }
        handler(value)
    }
}

final class LedgeInput: FlippedView, NSTextFieldDelegate {
    private let textField = NSTextField()
    private let submit: (String) -> Void

    init(placeholder: String, submit: @escaping (String) -> Void) {
        self.submit = submit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = LedgeTheme.raised.cgColor
        layer?.borderColor = LedgeTheme.hairline.cgColor
        layer?.borderWidth = LedgeMetrics.hairline
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = LedgeMetrics.capsule(LedgeMetrics.inputHeight)

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = LedgeTheme.systemFont(LedgeMetrics.textDefaultPointSize)
        textField.textColor = LedgeTheme.primary
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: LedgeTheme.systemFont(LedgeMetrics.textDefaultPointSize),
                .foregroundColor: LedgeTheme.tertiary,
            ]
        )
        textField.delegate = self
        addSubview(textField)
        setAccessibilityLabel(placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Set the field's text from a host prop update (protocol renderer path).
    func setText(_ text: String) {
        textField.stringValue = text
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: LedgeMetrics.inputHeight)
    }

    override func layout() {
        super.layout()
        // Capsule, like everything else you press or type into (D8/Q2).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = LedgeMetrics.capsule(
            bounds.height > 0 ? bounds.height : LedgeMetrics.inputHeight
        )
        CATransaction.commit()

        let height = ceil(textField.intrinsicContentSize.height)
        let pad = LedgeMetrics.inputPadX
        textField.frame = CGRect(
            x: pad,
            y: (bounds.height - height) / 2,
            width: max(bounds.width - pad * 2, 0),
            height: height
        )
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        layer?.borderColor = LedgeTheme.accent.withAlphaComponent(0.70).cgColor
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        layer?.borderColor = LedgeTheme.hairline.cgColor
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submit(textField.stringValue)
        return true
    }
}
