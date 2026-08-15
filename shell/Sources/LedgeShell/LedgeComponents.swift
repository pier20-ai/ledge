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

/// A view with **no width of its own** — a rule, a sparkline, a slider, a row.
/// The column is the only thing that can give it one, so it keeps the vertical
/// stack's fill constraint even when the stack is centring or trailing its
/// children (`LedgeStackView.syncFillWidths`).
///
/// Marked rather than measured. `intrinsicContentSize` would answer for most of
/// these and `fittingSize` for the rest, but both are read at *insert* time,
/// when a subtree's own children have not arrived yet — a stack asked how wide
/// it wants to be mid-commit says "nothing", and the answer would be cached as
/// a constraint. A conformance is true before the first layout pass.
@MainActor
protocol LedgeColumnFilling: AnyObject {}

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
    /// width; anything narrower goes in an h-stack next to a spacer. Unless the
    /// stack named an alignment — see `placesChildren`, which is what makes
    /// `align="center"` mean something for a label.
    ///
    /// This is done with explicit constraints rather than NSStackView's
    /// `.width` alignment, whose priority ties with content hugging: the tie
    /// resolves to "intrinsic width, pinned to the *trailing* edge", which
    /// silently right-aligns every bare label.
    /// Below required, so a fixed-size child (an image, a badge) keeps its size
    /// and simply sits at the leading edge.
    static let fillPriority = NSLayoutConstraint.Priority(500)

    /// The ceiling a *placed* child is held under. Above every content priority
    /// (a label's 750 compression resistance loses to it, so a long line
    /// truncates instead of running off the panel) and below required, so a
    /// child with a real width constraint of its own — a 500 pt canvas in a 440
    /// pt panel — still wins rather than breaking the layout.
    static let capPriority = NSLayoutConstraint.Priority(999)

    /// **Does the column stretch its children, or place them?**
    ///
    /// `align="center"`/`"trailing"` used to be a silent no-op for anything that
    /// stretches: the fill constraint pinned a label to the full column width
    /// and `NSTextField` draws left inside it, so every app grew the same
    /// spacer/text/spacer helper. A stack that names a cross-axis alignment is
    /// asking for its children to be *placed*, so they are sized to what they
    /// measure and NSStackView's own alignment puts them where the app said.
    ///
    /// The exception is `LedgeColumnFilling` — a divider or a chart has no width
    /// of its own, and "centred" would resolve to zero.
    private var placesChildren: Bool {
        alignment == .centerX || alignment == .trailing
    }

    /// **Does a row stretch its children, or place them?**
    ///
    /// The column's question, asked of the other axis. NSStackView's `.fill`
    /// distribution pins the first child to the leading edge, the last to the
    /// trailing edge, and hands the slack to whichever child hugs least — so a
    /// row of `[numeral, phrase]` came out with the numeral stretched to 357 pt
    /// (its glyphs drawn flush left inside it) and the phrase pinned to the far
    /// edge: two things meant to read as one sentence, at opposite ends of the
    /// panel. D2 found it on Weather's temperature row; every app that hit it
    /// worked around it with a trailing `spacer`.
    ///
    /// The rule, spec §5: **a row places its children unless one of them has no
    /// width of its own.** That exception is not new — it is the column rule's
    /// own exception, in the same words. A `spacer`, `divider`, `chart`,
    /// `slider`, `progress`, `input` or nested scroller (every
    /// `LedgeColumnFilling`) measures nothing, so a row holding one has
    /// somewhere for its slack to go and keeps filling; a `spacer` is the app
    /// saying exactly that, which is what it has always been for.
    ///
    /// **The row's own width does not change** — only what happens inside it —
    /// so list rows, cards, washes and press targets still span their column.
    /// And it keys off the children rather than off `align`, because on a row
    /// `align` is the *cross* axis (top/middle/bottom) and always has been:
    /// re-pointing it at the main axis would silently re-lay-out every app.
    /// `distribute="equal"` is the third case and is untouched — an app that
    /// asked for equal shares is asking to fill.
    private var placesRowChildren: Bool {
        orientation == .horizontal
            && isStretchedByColumn
            && declaredDistribution != .fillEqually
            && !arrangedSubviews.contains { $0 is LedgeColumnFilling }
    }

    /// Told by the parent column: **this row's width is imposed, not measured.**
    ///
    /// The third condition, and the one that keeps the change narrow. A row only
    /// has slack to mis-spend when something else decided how wide it is — a
    /// column stretching it to its own width. A row that is *placed* (by a
    /// centred or trailing column, by a `button` hosting it, by nothing at all)
    /// is already the size of its contents, and switching its distribution there
    /// would cost it that: `.gravityAreas` does not give a stack a
    /// content-driven fitting width, so a centred transport pair would slide to
    /// the left of a row suddenly as wide as the panel. Radio and Beacon both
    /// look exactly like that, and both are why this flag exists.
    var isStretchedByColumn = false {
        didSet {
            guard isStretchedByColumn != oldValue else { return }
            syncFillWidths()
        }
    }

    /// `distribute` as the app declared it (spec §5). The *live* `distribution`
    /// may differ: a placing row runs on `.gravityAreas`, which is AppKit's own
    /// "lay them side by side and stop there" — no edge pinning, no stretching,
    /// and the leftover width simply left over.
    var declaredDistribution: NSStackView.Distribution = .fill {
        didSet {
            guard declaredDistribution != oldValue else { return }
            syncFillWidths()
        }
    }

    func syncFillWidths() {
        NSLayoutConstraint.deactivate(fillWidths)
        fillWidths = []
        // Recomputed on every sync because it depends on the children, and
        // `axis` is itself updatable — a column that becomes a row must not keep
        // a column's distribution, and vice versa.
        let wanted: NSStackView.Distribution =
            placesRowChildren ? .gravityAreas : declaredDistribution
        if distribution != wanted { distribution = wanted }
        guard orientation == .vertical else { return }
        let places = placesChildren
        let inset = edgeInsets.left + edgeInsets.right
        fillWidths = arrangedSubviews.compactMap { child in
            // A placed child keeps the width it measures — and is capped at the
            // column's, because NSStackView's own `.centerX`/`.trailing`
            // alignment does not contain anything: it centres a 1200 pt track
            // title just as happily, half of it off each edge of the panel.
            if places, !(child is LedgeColumnFilling) {
                (child as? LedgeStackView)?.isStretchedByColumn = false
                let cap = child.widthAnchor.constraint(
                    lessThanOrEqualTo: widthAnchor,
                    constant: -inset
                )
                cap.priority = Self.capPriority
                return cap
            }
            // A child that hugs harder than the fill *means* it — a `segment`
            // keeps its measured width, an icon-only `button` stays square — and
            // constraining it anyway is not merely redundant. The equality pulls
            // in both directions: the child wins its own width, and the *stack*
            // is dragged down to match it. One segmented control was enough to
            // collapse a whole page from 440 pt to 163, every sibling neatly
            // filling a column that had quietly shrunk to nothing.
            guard child.contentHuggingPriority(for: .horizontal) < Self.fillPriority else {
                (child as? LedgeStackView)?.isStretchedByColumn = false
                return nil
            }
            // This is the one branch that imposes a width, so it is the one that
            // gives a nested row slack to place its children in.
            (child as? LedgeStackView)?.isStretchedByColumn = true
            let constraint = child.widthAnchor.constraint(equalTo: widthAnchor, constant: -inset)
            constraint.priority = Self.fillPriority
            return constraint
        }
        NSLayoutConstraint.activate(fillWidths)
    }

    /// The `gradient` wash, if this stack declared one. Its own layer, below
    /// every child: a wash is a material behind the content, not a fill the
    /// content sits on top of — and keeping it off `backgroundColor` is what
    /// lets `fill` and `gradient` be used together.
    private var washLayer: CAGradientLayer?

    /// Semantic container styling (spec §5 proposal). `nil` clears.
    func applyContainer(fill: NSColor?, stroke: NSColor?, radius: CGFloat?, gradient: NSColor? = nil) {
        guard fill != nil || stroke != nil || radius != nil || gradient != nil || wantsLayer else {
            return
        }
        wantsLayer = true
        layer?.backgroundColor = (fill ?? .clear).cgColor
        layer?.borderColor = (stroke ?? .clear).cgColor
        layer?.borderWidth = stroke == nil ? 0 : LedgeMetrics.hairline
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius ?? 0
        // A wash has to be clipped by the container's own corners, or it draws
        // square shoulders past a rounded card.
        layer?.masksToBounds = (radius ?? 0) > 0 || gradient != nil
        applyWash(gradient)
    }

    /// The hue the wash was resolved to, or nil for no wash. Read by tests —
    /// a `CAGradientLayer`'s own `colors` are `Any` and comparing them means
    /// unwrapping CoreGraphics types by hand.
    private(set) var washColor: NSColor?

    private func applyWash(_ color: NSColor?) {
        washColor = color
        guard let color else {
            washLayer?.removeFromSuperlayer()
            washLayer = nil
            return
        }
        let wash = washLayer ?? {
            let layer = CAGradientLayer()
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
            // Below the children (which are subviews, hence above every
            // sublayer) and below nothing else — it is the bottom of the stack.
            self.layer?.insertSublayer(layer, at: 0)
            washLayer = layer
            return layer
        }()
        // Disabled actions: a re-commit that happens to change the hue must not
        // cross-fade a background while the panel is measuring itself.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.colors = [
            color.withAlphaComponent(LedgeTheme.washAlpha).cgColor,
            color.withAlphaComponent(0).cgColor,
        ]
        wash.locations = [0, NSNumber(value: Double(LedgeMetrics.washEnd))]
        wash.frame = bounds
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard let washLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        washLayer.frame = bounds
        CATransaction.commit()
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
final class LedgeScrollStackView: NSView, LedgeContentHosting, LedgeColumnFilling {
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
    /// The string as the app wrote it. `caps` is a *presentation*, so the raw
    /// content is what accessibility reads, what a later `caps: false` restores,
    /// and what a `caps`-only update re-renders from.
    private(set) var rawContent: String
    /// §5 `caps`. Uppercases and tracks out — the two always travel together,
    /// because uppercase at natural spacing is a jam.
    private(set) var caps = false

    init(_ content: String) {
        rawContent = content
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

    /// A label is never a target. It is not editable, not selectable and has no
    /// action, so every press that lands on one is meant for something behind it
    /// — the row it sits in, or the panel itself. NSTextField is an NSControl and
    /// will happily consume that press, which is how a ticker in a tappable row
    /// becomes the one part of the row that does nothing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Set the content and its `caps` treatment together (spec §5).
    ///
    /// They are one call because they are one decision: tracking is not a font
    /// trait, so caps has to be drawn as an attributed value built from the
    /// field's *current* face — which means the renderer sets `font`/`textColor`
    /// first and this reads them. `content: nil` means "unchanged", the same
    /// contract every other partial-update prop has.
    func applyContent(_ content: String?, caps newCaps: Bool) {
        let wasCaps = caps
        if let content { rawContent = content }
        caps = newCaps
        // Every commit re-runs `configure`, including a price tick that changed
        // nothing here. Rebuilding an attributed string per tick is work the
        // panel does not need to do.
        guard caps || wasCaps || stringValue != rawContent else { return }
        setAccessibilityLabel(rawContent)
        guard caps else {
            // Plain assignment drops any attributes a previous `caps: true` left
            // behind, and the cell falls back to `font`/`textColor` — which is
            // why dropping the prop really does restore the ordinary label.
            stringValue = rawContent
            invalidateIntrinsicContentSize()
            return
        }
        let face = font ?? LedgeTheme.systemFont(LedgeMetrics.textDefaultPointSize)
        attributedStringValue = NSAttributedString(
            string: rawContent.uppercased(),
            attributes: [
                .font: face,
                .foregroundColor: textColor ?? LedgeTheme.primary,
                .kern: face.pointSize * LedgeMetrics.capsTracking,
            ]
        )
        invalidateIntrinsicContentSize()
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

/// The control ramp (principle 15: one control ramp, never forked).
///
/// The first three are what an *app* may ask for over the wire (§5
/// `button.variant`). The last two are **shell** styles — the two tiers
/// design.html §06 draws: a bead is a Ledge control, a ghost is a glyph in an
/// app's own content well. `ProtocolRenderer.variant` deliberately does not map
/// any wire string to them, so an app cannot dress its buttons as chrome.
enum LedgeButtonVariant {
    case plain
    case glass
    case accent
    /// A convex swelling of the glass: a top-lit vertical fill, a specular line
    /// along the top edge, a shadow along the bottom. Ledge's own controls.
    case bead
    /// Bare pure-white glyph, no background at all until the cursor is on it.
    /// Bigger and brighter than chrome, because it lives among content.
    case ghost
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
    /// A bead is drawn from two sublayers rather than a background colour: the
    /// gradient fill, and a one-point ring whose colour runs light at the top
    /// and dark at the bottom. Built only for the `bead` variant, because every
    /// other variant is genuinely one flat fill.
    private var beadFill: CAGradientLayer?
    private var beadEdge: CAGradientLayer?
    private var beadEdgeMask: CAShapeLayer?
    private var pressed = false

    /// Test/introspection accessors. `iconFrame`/`labelFrame` are what the
    /// centering law (L2) is actually asserted against — "the icon looks centered"
    /// is how the 5 pt offset survived eleven apps.
    var currentLabel: String { label.stringValue }
    var iconFrame: CGRect? { iconView?.frame }
    var labelFrame: CGRect { label.frame }
    var iconPointSize: CGFloat? {
        iconView?.image?.symbolConfiguration != nil
            ? (isIconOnly
                ? LedgeMetrics.iconOnlyPointSize(variant: variant)
                : LedgeMetrics.buttonIconPointSize)
            : nil
    }
    var contentAlpha: CGFloat { label.alphaValue }
    var currentSize: LedgeMetrics.Size { size }
    var isDisabled: Bool { disabled }
    var currentVariant: LedgeButtonVariant { variant }
    /// The bead's fill stops, top first — what "convex" actually reduces to,
    /// and the only way to assert the hover brightening without a screenshot.
    var beadFillColors: [NSColor]? {
        beadFill?.colors?.compactMap { ($0 as! CGColor?).flatMap(NSColor.init(cgColor:)) }
    }
    var beadEdgeColors: [NSColor]? {
        beadEdge?.colors?.compactMap { ($0 as! CGColor?).flatMap(NSColor.init(cgColor:)) }
    }
    var isPressed: Bool { pressed }
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
    /// makes this button a square — and, with the capsule rule, a circle. A
    /// button hosting a child is neither: its content is the child.
    var isIconOnly: Bool { hostedContent == nil && label.stringValue.isEmpty }

    /// The child node this button wraps, for the `label` *or child* form §5 has
    /// always specified. A list row is the case that needs it: the whole row is
    /// the tap target, and its inside is an ordinary tree — a ticker, a
    /// sparkline, a price — that no `label` string could ever be.
    ///
    /// Until this existed the child form parsed, validated and committed, and
    /// then rendered as a 34 pt circle with the row hanging off its left edge:
    /// the button measured its (empty) label and the child was pinned to a
    /// centre that had nothing to do with its size.
    private(set) var hostedContent: NSView?

    /// Adopt a child node's view. Called by the renderer on `insert`; a second
    /// child replaces the first, because §5 says *a* child.
    func host(_ view: NSView) {
        hostedContent?.removeFromSuperview()
        hostedContent = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The label and the icon are the *other* form of this control. Hiding
        // rather than removing keeps `apply` idempotent — a commit that later
        // drops the child gets its labelled button back.
        label.isHidden = true
        iconView?.isHidden = true
        refreshHugging()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

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
            font: LedgeTheme.systemFont(
                LedgeMetrics.TypeSize.s.pointSize,
                weight: .semibold
            ),
            color: Self.inkColor(variant: variant, filledTint: nil)
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
        rebuildBeadLayers()
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
        // The glyph is *built* at a point size, so anything that changes the
        // size has to rebuild it: the empty/non-empty label line, and — since
        // ghosts are 18 pt and everything else is 14 — the variant too.
        let wasGlyphSize = glyphPointSize
        if let newLabel {
            label.stringValue = newLabel
            setAccessibilityLabel(newLabel.isEmpty ? (symbolName ?? "") : newLabel)
        }
        if let newVariant {
            variant = newVariant
            layer?.borderWidth = variant == .glass ? LedgeMetrics.hairline : 0
            rebuildBeadLayers()
        }
        if let newSize { size = newSize }
        if let newDisabled { disabled = newDisabled }
        if let symbol {
            symbolName = symbol
            rebuildIcon()
        } else if wasGlyphSize != glyphPointSize {
            // The label crossed the empty/non-empty line, or the button crossed
            // the chrome/app tier line — either way the glyph's point size (and
            // possibly its weight) changed even though the symbol did not.
            rebuildIcon()
        }
        refreshInk()
        applyDisabledAlpha()
        refreshHugging()
        refreshAppearance()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The point size this button's glyph *should* be built at, right now.
    /// `iconPointSize` is the same number but only once there is an icon —
    /// this one is a pure function of the button's state, so it can be sampled
    /// before and after a mutation.
    private var glyphPointSize: CGFloat {
        isIconOnly
            ? LedgeMetrics.iconOnlyPointSize(variant: variant)
            : LedgeMetrics.buttonIconPointSize
    }

    private func rebuildIcon() {
        iconView?.removeFromSuperview()
        iconView = nil
        // A hosted child owns the whole button; an `icon` prop alongside it would
        // draw a glyph under the row.
        guard hostedContent == nil, let symbolName else { return }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: isIconOnly
                        ? LedgeMetrics.iconOnlyPointSize(variant: variant)
                        : LedgeMetrics.buttonIconPointSize,
                    weight: isIconOnly ? LedgeMetrics.iconOnlyWeight : LedgeMetrics.buttonIconWeight
                )
            )
        icon.contentTintColor = Self.inkColor(variant: variant, filledTint: filledTint)
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
        // A labelled button's height is fixed by the `size` ramp, so vertical
        // hugging never comes up. A hosted row has no intrinsic height at all,
        // which makes it the most willing thing in a column to absorb slack —
        // and a list row that grows when the panel does is not a row.
        setContentHuggingPriority(
            hostedContent == nil ? .defaultLow : .defaultHigh,
            for: .vertical
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
        // A hosted child brings its own size in both axes — the `size` ramp
        // describes a labelled capsule, and a row is not one.
        if hostedContent != nil {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
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
        // The capsule rule is for controls you press *at a control's height*. A
        // hosted row is a card by every other measure — pad, fill, the company it
        // keeps — so it takes the card radius (D4 concentric) instead of becoming
        // a 44 pt lozenge.
        layer?.cornerRadius = hostedContent != nil
            ? LedgeMetrics.rCard
            : LedgeMetrics.capsule(bounds.height > 0 ? bounds.height : size.height)
        layoutBeadLayers()
        CATransaction.commit()

        guard hostedContent == nil else {
            syncHover()
            return
        }

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
        setPressed(true, duration: LedgeMetrics.pressDurationIn)
        var clickedInside = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                clickedInside = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        setPressed(false, duration: LedgeMetrics.pressDurationOut)
        if clickedInside {
            handler()
        }
    }

    /// The press, for anything that is not a mouse. `mouseDown` runs its own
    /// event loop, so VoiceOver (and a test) had no way in at all — the button
    /// announced itself as a button and then did nothing when pressed.
    override func accessibilityPerformPress() -> Bool {
        guard !disabled else { return false }
        handler()
        return true
    }

    /// A bead does not shrink — it **sinks**. Scaling a convex swelling reads as
    /// the control getting smaller; moving it half a point down while the inset
    /// closes over the top reads as it being pushed into the glass, which is
    /// what it is. Every other variant keeps the D5 press scale.
    private func setPressed(_ down: Bool, duration: TimeInterval) {
        pressed = down
        guard variant == .bead else {
            let press = isIconOnly ? LedgeMetrics.pressScaleIcon : LedgeMetrics.pressScaleLabeled
            layer?.setPressScale(down ? press : 1, duration: duration)
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        // Down is −y in an unflipped view's layer, +y in a flipped one.
        let sink = isFlipped ? LedgeMetrics.beadPressSink : -LedgeMetrics.beadPressSink
        layer?.setAffineTransform(
            down ? CGAffineTransform(translationX: 0, y: sink) : .identity
        )
        CATransaction.commit()
        refreshBead()
    }

    /// White over a filled tint, otherwise the variant's own ink.
    ///
    /// White rather than `glassSolid` (black): the amber send button in the
    /// existing surfaces already carries a white glyph, so a black-inked amber
    /// chip beside it would read as a different control family.
    private static func inkColor(variant: LedgeButtonVariant, filledTint: NSColor?) -> NSColor {
        if filledTint != nil { return .white }
        switch variant {
        case .accent:
            return LedgeTheme.glassSolid
        case .ghost:
            // Pure white, not `primary`. A ghost sits in an app's content well
            // with no background to lift it, so the 6% the chrome ink gives up
            // to look calm is exactly what makes a bare glyph look switched off.
            return .white
        case .plain, .glass, .bead:
            return LedgeTheme.primary
        }
    }

    private func refreshInk() {
        let contentColor = Self.inkColor(variant: variant, filledTint: filledTint)
        label.textColor = contentColor
        iconView?.contentTintColor = contentColor
    }

    /// Frame the bead's sublayers to the button. Called from `layout` inside the
    /// action-disabled transaction, because a capsule that cross-fades its own
    /// corner radius on every resize is the L6 defect.
    private func layoutBeadLayers() {
        guard let beadFill, let beadEdge, let beadEdgeMask else { return }
        let radius = layer?.cornerRadius ?? LedgeMetrics.capsule(bounds.height)
        beadFill.frame = bounds
        beadFill.cornerCurve = .continuous
        beadFill.cornerRadius = radius
        beadFill.masksToBounds = true
        beadEdge.frame = bounds
        beadEdgeMask.frame = bounds
        // Stroked *inside* the silhouette: half a line width in, so the ring is
        // the button's own edge rather than a halo hanging off it.
        let inset = LedgeMetrics.beadEdgeWidth / 2
        beadEdgeMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: max(0, radius - inset),
            cornerHeight: max(0, radius - inset),
            transform: nil
        )
    }

    private var beadTopUnitPoint: CGPoint { CGPoint(x: 0.5, y: isFlipped ? 0 : 1) }
    private var beadBottomUnitPoint: CGPoint { CGPoint(x: 0.5, y: isFlipped ? 1 : 0) }

    /// The bead's two sublayers, built only when the variant needs them and torn
    /// down when it stops. They go in *below* everything: a layer-backed view's
    /// subviews are sublayers too, so an appended gradient would sit on top of
    /// the label.
    private func rebuildBeadLayers() {
        guard variant == .bead else {
            beadFill?.removeFromSuperlayer()
            beadEdge?.removeFromSuperlayer()
            beadFill = nil
            beadEdge = nil
            beadEdgeMask = nil
            return
        }
        guard beadFill == nil else { return }
        let fill = CAGradientLayer()
        // A layer's coordinate system matches its view's, and an NSControl is
        // not flipped — so unit y = 1 is the *top*. Saying it once here lets
        // every colour list below read top-first, which is how they are written
        // in design.html.
        fill.startPoint = beadTopUnitPoint
        fill.endPoint = beadBottomUnitPoint
        layer?.insertSublayer(fill, at: 0)
        beadFill = fill

        // The specular top and the shadowed bottom are one ring, not two edges:
        // a vertical gradient masked to a one-point capsule outline. That gets
        // both inset shadows from design.html with a single layer, and the ring
        // follows the capsule instead of cutting across its corners.
        let edge = CAGradientLayer()
        edge.startPoint = beadTopUnitPoint
        edge.endPoint = beadBottomUnitPoint
        let mask = CAShapeLayer()
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = LedgeMetrics.beadEdgeWidth
        edge.mask = mask
        layer?.insertSublayer(edge, above: fill)
        beadEdge = edge
        beadEdgeMask = mask
    }

    /// Paint the bead for the current hover/press state. Colours only — the
    /// frames are `layout`'s.
    private func refreshBead() {
        guard let beadFill, let beadEdge else { return }
        let top = hovering ? LedgeTheme.beadFillTopHover : LedgeTheme.beadFillTop
        let bottom = hovering ? LedgeTheme.beadFillBottomHover : LedgeTheme.beadFillBottom
        beadFill.colors = [top.cgColor, bottom.cgColor]
        beadEdge.colors = pressed
            // Pressed, the inset closes over the top too — the swelling is being
            // pushed into the glass, so there is no specular left to catch.
            ? [LedgeTheme.beadEdgePressed.cgColor, LedgeTheme.beadEdgePressed.cgColor]
            : [LedgeTheme.beadEdgeHighlight.cgColor, LedgeTheme.beadEdgeShadow.cgColor]
    }

    private func refreshAppearance() {
        refreshBead()
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
        case .bead:
            // The whole control is the two gradient sublayers `refreshBead`
            // paints; a background colour underneath them would flatten the
            // swelling back into a chip.
            layer?.backgroundColor = NSColor.clear.cgColor
        case .ghost:
            // Nothing at all until the cursor arrives, and then only the wash —
            // no border, no fill, no capsule the eye can find when idle.
            layer?.backgroundColor = hovering ? LedgeTheme.raisedHover.cgColor : NSColor.clear.cgColor
        }
    }
}

/// An `image` node whose `src` is an SF Symbol (`sf:name`, spec §5), drawn at
/// the requested size. Deliberately unstyled — the box around an icon is a
/// `stack` with a `fill`/`radius`, so the same view serves a 5 pt dot and a
/// 54 pt artwork tile.
extension NSView {
    /// The `image` node's `stroke` (spec §5): the same 1 pt hairline ring a
    /// `stack` draws, on the picture itself.
    ///
    /// It lives on the view rather than in the drawing code because both kinds
    /// of `image` need it — a file bitmap and an SF Symbol — and because the
    /// ring has to survive the aspect-fill crop and the missing-file placeholder
    /// alike. `nil` clears it, which is what a deleted prop (null, §3.1) means.
    func applyHairlineStroke(_ stroke: NSColor?) {
        guard stroke != nil || wantsLayer else { return }
        wantsLayer = true
        // Implicit layer animations would fade the ring in on every commit.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.borderColor = (stroke ?? .clear).cgColor
        layer?.borderWidth = stroke == nil ? 0 : LedgeMetrics.hairline
        layer?.cornerCurve = .continuous
        CATransaction.commit()
    }
}

final class LedgeSymbolView: NSImageView {
    /// The symbol this view is currently showing, without the `sf:` prefix —
    /// `NSImage.name()` is unreliable once a symbol configuration has copied the
    /// image, so the name is kept rather than read back (the same reason
    /// `LedgeButton` keeps `symbolName`).
    private(set) var symbol: String

    init(symbol: String, radius: CGFloat = 0) {
        self.symbol = symbol
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = LedgeTheme.primary
        applySymbol(symbol)
        applyRadius(radius)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Partial-update entry point (spec §3.1), the symbol twin of
    /// `LedgeFileImageView.apply`: each argument nil = unchanged.
    ///
    /// This exists because it was missing. `configure`'s `.image` case guarded
    /// `as? LedgeFileImageView`, so a `<image src="sf:…">` that changed its
    /// symbol mid-life kept the first glyph forever — an app either lived with
    /// a stale icon or forced a remount with a React `key`. A symbol node is an
    /// ordinary node: it updates in place like every other kind.
    func apply(symbol newSymbol: String?, radius: CGFloat?) {
        if let newSymbol, newSymbol != symbol {
            symbol = newSymbol
            applySymbol(newSymbol)
        }
        if let radius {
            applyRadius(radius)
        }
    }

    private func applySymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: name)
            ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: name)
        setAccessibilityLabel(name)
    }

    private func applyRadius(_ radius: CGFloat) {
        guard radius > 0 || wantsLayer else { return }
        wantsLayer = true
        // Implicit layer animations would cross-fade the corner on every commit.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = max(0, radius)
        layer?.masksToBounds = radius > 0
        CATransaction.commit()
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

/// A `divider` node (spec §5): the hairline rule between rows.
///
/// It exists because nothing else in the vocabulary can draw one. A `stack` with
/// a `stroke` outlines whatever it contains, and a stack containing nothing is
/// zero points tall — so "a line here" was the one piece of ordinary list
/// furniture an app had to fake with a tinted, one-child box.
///
/// Horizontal only, on the same grounds `stack scroll` is vertical only: in a row
/// the separation is already `gap` and `spacer`, and a rule between two chips is
/// decoration rather than structure. Dropped into an h-stack it is a 1 pt sliver
/// and says nothing — which is the honest answer, not a guess at what was meant.
final class LedgeDividerView: NSView, LedgeColumnFilling {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = LedgeTheme.hairline.cgColor
        // Weak horizontal hugging so the vertical stack's fill constraint takes
        // it to the full column: a rule that stops short of the text it separates
        // reads as a mistake.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One point tall, no intrinsic width — the column decides how wide a rule is,
    /// the shell decides how thick.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: LedgeMetrics.hairline)
    }
}

/// A list row — the shell's one list primitive.
///
/// Every list Ledge has drawn so far was assembled by hand out of a stack, a
/// pair of labels and a divider, and each one picked its own inset, its own
/// hover treatment and its own idea of where the rule goes. This is that row,
/// stated once (principle 15).
///
/// Full-bleed by construction: the hover fill and the divider run edge to edge
/// and only the *content* is inset, which is what makes a column of these read
/// as one list rather than a stack of little cards. The trailing value is set
/// in tabular figures — a column of numbers that shifts as it ticks is the
/// defect this exists to prevent.
@MainActor
final class LedgeRowView: FlippedView, LedgeColumnFilling {
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField?
    private let chevron: NSImageView?
    private let handler: (() -> Void)?
    private let hoverLayer = CALayer()
    private let dividerLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var hovering = false

    /// Whether this row draws the rule below it. The *owner* decides, because
    /// only the owner knows which row is last — a row that guessed from its
    /// superview would draw a rule under the bottom of the list.
    var showsDivider = true {
        didSet {
            guard showsDivider != oldValue else { return }
            refreshDivider()
        }
    }

    /// Test/introspection accessors.
    var isHovering: Bool { hovering }
    var currentTitle: String { titleLabel.stringValue }
    var currentValue: String? { valueLabel?.stringValue }
    var hasChevron: Bool { chevron != nil }
    var dividerIsVisible: Bool { !dividerLayer.isHidden }
    var hoverFillIsVisible: Bool { (hoverLayer.backgroundColor?.alpha ?? 0) > 0 }

    /// - Parameters:
    ///   - title: the leading text. One or two words (principle 4).
    ///   - value: the trailing slot, in tabular figures. nil leaves it out
    ///     entirely rather than reserving an empty column.
    ///   - chevron: whether the row goes somewhere. A row that does nothing
    ///     must not carry one.
    ///   - onClick: nil makes the row inert — no hover, no cursor, no press.
    init(
        title: String,
        value: String? = nil,
        chevron showsChevron: Bool = false,
        onClick: (() -> Void)? = nil
    ) {
        handler = onClick
        titleLabel = makeLabel(
            title,
            font: LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize),
            color: LedgeTheme.primary
        )
        valueLabel = value.map { text in
            let field = makeLabel(
                text,
                // Numeric, always: this column exists to be compared down the
                // list, and proportional digits make that impossible.
                font: LedgeTheme.numericFont(LedgeMetrics.TypeSize.m.pointSize),
                color: LedgeTheme.secondary
            )
            field.alignment = .right
            return field
        }
        chevron = showsChevron ? NSImageView() : nil
        super.init(frame: .zero)

        wantsLayer = true
        hoverLayer.cornerCurve = .continuous
        hoverLayer.cornerRadius = LedgeMetrics.rChip
        hoverLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverLayer)
        dividerLayer.backgroundColor = LedgeTheme.hairline.cgColor
        layer?.addSublayer(dividerLayer)

        addSubview(titleLabel)
        if let valueLabel { addSubview(valueLabel) }
        if let chevron {
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(
                        pointSize: LedgeMetrics.rowChevronPointSize,
                        weight: LedgeMetrics.rowChevronWeight
                    )
                )
            chevron.contentTintColor = LedgeTheme.tertiary
            chevron.imageScaling = .scaleProportionallyDown
            addSubview(chevron)
        }

        setAccessibilityRole(onClick == nil ? .staticText : .button)
        setAccessibilityLabel([title, value].compactMap { $0 }.joined(separator: ", "))
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: LedgeMetrics.rowHeight)
    }

    override func layout() {
        super.layout()
        // Frames and radii are layout, never a cross-fade (L6).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        dividerLayer.frame = CGRect(
            x: 0,
            y: bounds.height - LedgeMetrics.hairline,
            width: bounds.width,
            height: LedgeMetrics.hairline
        )
        CATransaction.commit()

        var trailing = bounds.width - LedgeMetrics.rowPadX
        if let chevron {
            let glyph = chevron.image?.size ?? .zero
            chevron.frame = CGRect(
                x: trailing - glyph.width,
                y: (bounds.height - glyph.height) / 2,
                width: glyph.width,
                height: glyph.height
            )
            trailing = chevron.frame.minX - LedgeMetrics.rowGap
        }
        if let valueLabel {
            let measured = valueLabel.attributedStringValue.size()
            let width = ceil(measured.width) + LedgeMetrics.textMeasureSlack
            valueLabel.frame = CGRect(
                x: trailing - width,
                y: (bounds.height - ceil(measured.height)) / 2,
                width: width,
                height: ceil(measured.height)
            )
            trailing = valueLabel.frame.minX - LedgeMetrics.rowGap
        }
        let titleHeight = ceil(titleLabel.attributedStringValue.size().height)
        titleLabel.frame = CGRect(
            x: LedgeMetrics.rowPadX,
            y: (bounds.height - titleHeight) / 2,
            width: max(0, trailing - LedgeMetrics.rowPadX),
            height: titleHeight
        )
        syncHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
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

    override func mouseEntered(with event: NSEvent) { syncHover() }
    override func mouseExited(with event: NSEvent) { syncHover() }

    /// Enter/exit pairs go stale whenever the panel morphs under a stationary
    /// cursor — the same defect `LedgeButton` guards against, and the same fix.
    private func syncHover() {
        let inside = handler != nil && (window.map { window in
            bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        } ?? false)
        guard inside != hovering else { return }
        hovering = inside
        CATransaction.begin()
        CATransaction.setAnimationDuration(LedgeMotion.fast)
        hoverLayer.backgroundColor = hovering
            ? LedgeTheme.raisedHover.cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
        refreshDivider()
        // A hovered row's fill has to meet its neighbour cleanly, and it cannot
        // if the neighbour is still drawing a rule into it.
        previousSibling()?.refreshDivider()
    }

    /// The rule is suppressed on a hovered row *and* on the row above it: a
    /// hairline crossing a lit fill reads as a seam through the highlight.
    fileprivate func refreshDivider() {
        let nextIsHovered = nextSibling()?.hovering ?? false
        dividerLayer.isHidden = !showsDivider || hovering || nextIsHovered
    }

    private func siblingRows() -> (rows: [LedgeRowView], index: Int)? {
        guard let siblings = superview?.subviews else { return nil }
        let rows = siblings.compactMap { $0 as? LedgeRowView }
        guard let index = rows.firstIndex(of: self) else { return nil }
        return (rows, index)
    }

    private func previousSibling() -> LedgeRowView? {
        guard let (rows, index) = siblingRows(), index > 0 else { return nil }
        return rows[index - 1]
    }

    private func nextSibling() -> LedgeRowView? {
        guard let (rows, index) = siblingRows(), index + 1 < rows.count else { return nil }
        return rows[index + 1]
    }

    override func mouseDown(with event: NSEvent) {
        guard let handler else { return }
        var clickedInside = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                clickedInside = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        if clickedInside { handler() }
    }
}

/// An empty state — a glyph, one quiet line, and at most one thing to do.
///
/// There is no "No data" anywhere in Ledge and there never will be: an empty
/// surface is not an error report, it is a surface with nothing in it yet, and
/// the line's job is to say what would put something there. One sentence is the
/// single place principle 4 allows one.
@MainActor
final class LedgeEmptyState: FlippedView {
    private let glyphView = NSImageView()
    private let lineLabel: NSTextField
    private let action: LedgeButton?

    /// Test/introspection accessors.
    var line: String { lineLabel.stringValue }
    var actionButton: LedgeButton? { action }

    /// - Parameters:
    ///   - symbol: an SF Symbol name. Drawn at the display tier in `tertiary` —
    ///     furniture, not an alarm.
    ///   - line: one line, in `secondary`. Not a paragraph.
    ///   - actionTitle: at most one. nil means the surface fills itself in on
    ///     its own and there is nothing to press.
    init(
        symbol: String,
        line: String,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        lineLabel = makeLabel(
            line,
            font: LedgeTheme.systemFont(LedgeMetrics.TypeSize.m.pointSize),
            color: LedgeTheme.secondary
        )
        lineLabel.alignment = .center
        action = actionTitle.map { title in
            LedgeButton(title, variant: .bead, size: .s, handler: onAction ?? {})
        }
        super.init(frame: .zero)

        glyphView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: LedgeMetrics.emptyGlyphPointSize,
                    weight: LedgeMetrics.emptyGlyphWeight
                )
            )
        glyphView.contentTintColor = LedgeTheme.tertiary
        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphView)
        addSubview(lineLabel)

        // Pinned on all four edges: the shell asks this view for its size, and a
        // view the shell measures that is not fully pinned measures as nothing.
        var constraints: [NSLayoutConstraint] = [
            glyphView.topAnchor.constraint(equalTo: topAnchor, constant: LedgeMetrics.emptyPad),
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            lineLabel.topAnchor.constraint(
                equalTo: glyphView.bottomAnchor,
                constant: LedgeMetrics.emptyGlyphGap
            ),
            lineLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: LedgeMetrics.emptyPad
            ),
            lineLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -LedgeMetrics.emptyPad
            ),
            lineLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ]
        if let action {
            action.translatesAutoresizingMaskIntoConstraints = false
            addSubview(action)
            constraints += [
                action.topAnchor.constraint(
                    equalTo: lineLabel.bottomAnchor,
                    constant: LedgeMetrics.emptyActionGap
                ),
                action.centerXAnchor.constraint(equalTo: centerXAnchor),
                action.bottomAnchor.constraint(
                    equalTo: bottomAnchor,
                    constant: -LedgeMetrics.emptyPad
                ),
            ]
        } else {
            constraints.append(
                lineLabel.bottomAnchor.constraint(
                    equalTo: bottomAnchor,
                    constant: -LedgeMetrics.emptyPad
                )
            )
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityLabel(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class LedgeSpacerView: NSView, LedgeColumnFilling {
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

final class LedgeChartView: NSView, LedgeColumnFilling {
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

final class LedgeSlider: NSControl, LedgeColumnFilling {
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

final class LedgeInput: FlippedView, NSTextFieldDelegate, LedgeColumnFilling {
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
