import AppKit
import QuartzCore

// The six controls apps had been faking, promoted to first-class §5 kinds by
// design-system ruling D8/Q5. Every dimension comes from `LedgeMetrics` (L1) and
// every color from `LedgeTheme`; every one of them updates in place, because a
// create-only prop is the bug `button` already shipped once.

/// The `rate` prop's engine (spec §5): while a control declares a non-zero rate
/// and is on screen, it advances its own displayed value between commits.
///
/// This exists because the alternative is worse in both directions. An app that
/// wants a scrubber to move smoothly can either commit 60 times a second — a
/// full reconcile, a wire frame and a shadow-tree validation per frame, for one
/// number — or accept a bar that jumps once per poll. `rate` says the one thing
/// the app actually knows ("this value grows by one per second") and lets the
/// shell do the arithmetic where the pixels are.
///
/// Two rules keep it honest. It only runs **in a window** (a control in a
/// collapsed panel is not animating a layer nobody can see — the same
/// `LedgeSpinner` discipline), and it yields to the pointer: a drag suspends
/// self-advance until mouse-up, because the user is the authority on where the
/// thumb is while they are holding it.
@MainActor
final class LedgeSelfAdvance {
    private unowned let owner: NSView
    private let apply: (Double) -> Void
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// Value units per second. Zero (or absent) is the static behavior.
    private(set) var rate: Double = 0
    /// True while the user is dragging the control.
    private(set) var isSuspended = false

    init(owner: NSView, apply: @escaping (Double) -> Void) {
        self.owner = owner
        self.apply = apply
    }

    /// Whether the tick is live — how a test asserts the off-window teardown
    /// actually happens, without sampling pixels or waiting on a clock.
    var isAdvancing: Bool { timer != nil }

    func setRate(_ next: Double?) {
        let clean = (next ?? 0).isFinite ? max(0, next ?? 0) : 0
        guard clean != rate else { return }
        rate = clean
        sync()
    }

    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        sync()
    }

    /// Start or stop the tick to match (rate, suspension, window). Idempotent —
    /// call it from `viewDidMoveToWindow` and after every state change.
    func sync() {
        guard rate > 0, !isSuspended, owner.window != nil else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(
            timeInterval: LedgeMetrics.selfAdvanceInterval,
            repeats: true
        ) { [weak self] _ in
            // Scheduled on `RunLoop.main`, so the block runs on the main thread
            // — assert that rather than hopping through a Task, which would put
            // a whole extra run-loop turn between every tick and its pixel.
            MainActor.assumeIsolated { self?.fire() }
        }
        // `.common` so a scrubber keeps gliding while the user is dragging
        // something else in the panel or scrolling the app strip.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Advance as if `seconds` of wall clock had passed. The timer's own path,
    /// and the seam a test drives directly rather than sleeping.
    func advance(by seconds: Double) {
        guard rate > 0, !isSuspended, seconds > 0 else { return }
        apply(rate * seconds)
    }

    private func fire() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastTick
        lastTick = now
        // Interpolating from the clock rather than assuming a fixed step: a tick
        // the run loop was too busy to deliver must not cost the value.
        advance(by: elapsed)
    }
}

/// `toggle` (D6): a 36 × 20 capsule with a 16 pt knob. The whole control is the
/// hit target — a switch you have to hit the knob of is a puzzle.
final class LedgeToggle: NSControl {
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    private let handler: (Bool) -> Void

    private(set) var isOn: Bool
    private(set) var disabled: Bool

    init(on: Bool, disabled: Bool = false, handler: @escaping (Bool) -> Void) {
        self.isOn = on
        self.disabled = disabled
        self.handler = handler
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(on)

        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.4
        knobLayer.shadowRadius = 3
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(knobLayer)
        applyDisabled()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: LedgeMetrics.toggleWidth, height: LedgeMetrics.toggleHeight)
    }

    /// Prop update from the host. The knob and the track slide/cross-fade because
    /// this is a *state* change (L6) — even though the renderer applies commits
    /// with implicit animation switched off, so the transaction is re-opened.
    func apply(on: Bool?, disabled newDisabled: Bool?) {
        if let newDisabled, newDisabled != disabled {
            disabled = newDisabled
            applyDisabled()
        }
        guard let on, on != isOn else { return }
        isOn = on
        setAccessibilityValue(on)
        animateState()
    }

    private func animateState() {
        CATransaction.begin()
        CATransaction.setDisableActions(false)      // the renderer's commit disabled them
        CATransaction.setAnimationDuration(LedgeMetrics.toggleDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        trackLayer.backgroundColor = trackColor
        knobLayer.frame = knobFrame
        CATransaction.commit()
    }

    private var trackColor: CGColor {
        (isOn ? LedgeTheme.accent : LedgeTheme.track).cgColor
    }

    private var knobFrame: CGRect {
        let inset = LedgeMetrics.toggleKnobInset
        let knob = LedgeMetrics.toggleKnob
        let x = isOn ? bounds.width - inset - knob : inset
        return CGRect(x: x, y: bounds.midY - knob / 2, width: knob, height: knob)
    }

    private func applyDisabled() {
        alphaValue = disabled ? LedgeMetrics.disabledAlpha : 1
        isEnabled = !disabled
    }

    override func layout() {
        super.layout()
        // Geometry is a layout tick: it must not animate (L6).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerCurve = .continuous
        trackLayer.cornerRadius = LedgeMetrics.capsule(bounds.height)
        trackLayer.backgroundColor = trackColor
        knobLayer.frame = knobFrame
        knobLayer.cornerRadius = LedgeMetrics.capsule(LedgeMetrics.toggleKnob)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        guard !disabled else { return }
        var inside = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                inside = bounds.contains(convert(next.locationInWindow, from: nil))
                break
            }
        }
        guard inside else { return }
        flip()
    }

    /// The click itself, once the press has resolved into one.
    private func flip() {
        isOn.toggle()
        setAccessibilityValue(isOn)
        animateState()
        handler(isOn)
    }

    /// Test seam: `mouseDown` resolves a press by pulling from the *window's*
    /// event queue, which a headless test has no way to feed — so the flip that
    /// reaches the handler is otherwise unreachable. One path either way: this
    /// is the same `flip` the click ends in, not a copy of it.
    func flipForTesting() { flip() }
}

/// `segment` (D6): a capsule group of h24 segments. The selection is a layer that
/// *moves* rather than a per-segment background, so switching tabs reads as one
/// object sliding instead of two independent fades.
final class LedgeSegment: NSControl {
    struct Option: Equatable {
        let id: String
        let label: String
    }

    private let handler: (String) -> Void
    private(set) var options: [Option]
    private(set) var value: String
    private let selectionLayer = CALayer()
    private var labels: [NSTextField] = []
    private var tracking: NSTrackingArea?
    private var hoveredIndex: Int?

    init(options: [Option], value: String, handler: @escaping (String) -> Void) {
        self.options = options
        self.value = value
        self.handler = handler
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = LedgeTheme.raised.cgColor
        layer?.borderColor = LedgeTheme.hairline.cgColor
        layer?.borderWidth = LedgeMetrics.hairline
        selectionLayer.backgroundColor = LedgeTheme.selected.cgColor
        selectionLayer.cornerCurve = .continuous
        selectionLayer.cornerRadius = LedgeMetrics.capsule(LedgeMetrics.segmentItemHeight)
        layer?.addSublayer(selectionLayer)
        setAccessibilityRole(.radioGroup)
        // Hugs harder than a vertical stack's fill constraint (priority 500), so
        // a segmented control keeps its measured width instead of being stretched
        // across the panel like a button.
        setContentHuggingPriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        rebuildLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `options` rebuilds the row; `value` only moves the selection, so a range
    /// picker switching 1D → 1W does not tear down and rebuild its own labels.
    func apply(options newOptions: [Option]?, value newValue: String?) {
        var rebuilt = false
        if let newOptions, newOptions != options {
            options = newOptions
            rebuildLabels()
            rebuilt = true
        }
        if let newValue, newValue != value {
            value = newValue
            refreshInk()
            if !rebuilt { moveSelection(animated: true) }
        }
        if rebuilt {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private func rebuildLabels() {
        labels.forEach { $0.removeFromSuperview() }
        labels = options.map { option in
            let field = makeLabel(
                option.label,
                font: LedgeTheme.systemFont(LedgeMetrics.TypeSize.s.pointSize, weight: .semibold),
                color: LedgeTheme.secondary,
                alignment: .center
            )
            addSubview(field)
            return field
        }
        refreshInk()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func refreshInk() {
        for (index, field) in labels.enumerated() {
            let isSelected = options[index].id == value
            field.textColor = isSelected || hoveredIndex == index
                ? LedgeTheme.primary
                : LedgeTheme.secondary
        }
    }

    /// Each segment is its measured label plus D6's 12 pt of pad either side.
    private var itemWidths: [CGFloat] {
        labels.map { ceil($0.attributedStringValue.size().width) + LedgeMetrics.segmentItemPadX * 2 }
    }

    override var intrinsicContentSize: NSSize {
        let content = itemWidths.reduce(0, +)
        return NSSize(
            width: content + LedgeMetrics.segmentPad * 2,
            height: LedgeMetrics.segmentHeight
        )
    }

    private func itemFrames() -> [CGRect] {
        let pad = LedgeMetrics.segmentPad
        var x = pad
        return itemWidths.map { width in
            let frame = CGRect(x: x, y: pad, width: width, height: bounds.height - pad * 2)
            x += width
            return frame
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = LedgeMetrics.capsule(bounds.height)
        let frames = itemFrames()
        for (index, field) in labels.enumerated() where index < frames.count {
            let height = ceil(field.intrinsicContentSize.height)
            field.frame = CGRect(
                x: frames[index].minX,
                y: (bounds.height - height) / 2,
                width: frames[index].width,
                height: height
            )
        }
        CATransaction.commit()
        moveSelection(animated: false)
        syncHover()
    }

    private func moveSelection(animated: Bool) {
        let frames = itemFrames()
        guard let index = options.firstIndex(where: { $0.id == value }), index < frames.count else {
            selectionLayer.isHidden = true
            return
        }
        selectionLayer.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(LedgeMetrics.segmentDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        selectionLayer.frame = frames[index]
        selectionLayer.cornerRadius = LedgeMetrics.capsule(frames[index].height)
        CATransaction.commit()
    }

    // MARK: - Hover & press

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
    override func mouseExited(with event: NSEvent) { syncHover() }
    override func mouseMoved(with event: NSEvent) { syncHover() }

    /// Enter/exit pairs go stale when the panel morphs under a stationary
    /// cursor — always verify against the live pointer (L5).
    private func syncHover() {
        let local = window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
        let index = local.flatMap { point -> Int? in
            guard bounds.contains(point) else { return nil }
            return itemFrames().firstIndex { $0.minX <= point.x && point.x < $0.maxX }
        }
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        refreshInk()
    }

    override func mouseDown(with event: NSEvent) {
        let frames = itemFrames()
        func index(at point: CGPoint) -> Int? {
            frames.firstIndex { $0.minX <= point.x && point.x < $0.maxX }
        }
        guard index(at: convert(event.locationInWindow, from: nil)) != nil else { return }
        var hit: Int?
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                let point = convert(next.locationInWindow, from: nil)
                if bounds.contains(point) { hit = index(at: point) }
                break
            }
        }
        guard let hit, options[hit].id != value else { return }
        value = options[hit].id
        refreshInk()
        moveSelection(animated: true)
        handler(value)
    }
}

/// `stepper` (D6): h28 capsule, square −/+ hit targets and a numeric value column
/// wide enough that "7" and "23" don't shift the buttons. Holds to repeat, so
/// setting an alarm to 06:45 is not 45 clicks.
final class LedgeStepper: NSControl {
    private let handler: (Double) -> Void
    private let minusIcon = NSImageView()
    private let plusIcon = NSImageView()
    private let valueLabel: NSTextField

    private(set) var value: Double
    private(set) var rangeMin: Double
    private(set) var rangeMax: Double
    private(set) var step: Double
    /// A display string the app computed (`format`) — an alarm's value is minutes
    /// since midnight and reads "07:30", which no numeric formatter here could
    /// know. Absent, the raw number is shown.
    private(set) var display: String?

    init(
        value: Double,
        min lower: Double,
        max upper: Double,
        step: Double,
        format: String?,
        handler: @escaping (Double) -> Void
    ) {
        self.rangeMin = lower
        self.rangeMax = Swift.max(upper, lower)
        self.step = step > 0 ? step : 1
        self.display = format
        self.value = value
        self.handler = handler
        valueLabel = makeLabel(
            "",
            font: LedgeTheme.numericFont(LedgeMetrics.stepperValuePointSize, weight: .semibold),
            color: LedgeTheme.primary,
            alignment: .center
        )
        super.init(frame: .zero)
        self.value = resolve(value)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = LedgeTheme.raised.cgColor
        layer?.borderColor = LedgeTheme.hairline.cgColor
        layer?.borderWidth = LedgeMetrics.hairline
        for (icon, symbol) in [(minusIcon, "minus"), (plusIcon, "plus")] {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(
                        pointSize: LedgeMetrics.stepperGlyphPointSize,
                        weight: .semibold
                    )
                )
            icon.contentTintColor = LedgeTheme.primary
            addSubview(icon)
        }
        addSubview(valueLabel)
        setAccessibilityRole(.incrementor)
        setContentHuggingPriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        refreshValueLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// In-place prop update. `min`/`max`/`step` are re-declared first so the value
    /// is resolved into the *new* scale, not the old one.
    func apply(value newValue: Double?, min lower: Double?, max upper: Double?, step newStep: Double?, format: String??) {
        if let lower { rangeMin = lower }
        if let upper { rangeMax = upper }
        if rangeMax < rangeMin { rangeMax = rangeMin }
        if let newStep, newStep > 0 { step = newStep }
        if let format { display = format }
        value = resolve(newValue ?? value)
        refreshValueLabel()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func resolve(_ raw: Double) -> Double {
        Swift.min(Swift.max(raw, rangeMin), rangeMax)
    }

    /// Test/introspection accessor: what the value column actually reads.
    var displayedText: String { valueLabel.stringValue }

    private func refreshValueLabel() {
        let text = display ?? Self.plain(value)
        valueLabel.stringValue = text
        valueLabel.setAccessibilityLabel(text)
        setAccessibilityValue(value)
    }

    /// Integers read as integers: a step of 1 should not print "7.0".
    private static func plain(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(format: "%g", value)
    }

    private var valueWidth: CGFloat {
        Swift.max(
            LedgeMetrics.stepperValueMinWidth,
            ceil(valueLabel.attributedStringValue.size().width) + LedgeMetrics.labelCellPad
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: LedgeMetrics.stepperButton * 2 + valueWidth,
            height: LedgeMetrics.stepperHeight
        )
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = LedgeMetrics.capsule(bounds.height)
        CATransaction.commit()

        let hit = LedgeMetrics.stepperButton
        func center(_ view: NSView, in rect: CGRect) {
            let size = view is NSImageView
                ? (view as! NSImageView).image?.size ?? .zero
                : CGSize(width: rect.width, height: ceil(view.intrinsicContentSize.height))
            view.frame = CGRect(
                x: rect.midX - ceil(size.width) / 2,
                y: rect.midY - ceil(size.height) / 2,
                width: ceil(size.width),
                height: ceil(size.height)
            )
        }
        center(minusIcon, in: CGRect(x: 0, y: 0, width: hit, height: bounds.height))
        center(plusIcon, in: CGRect(x: bounds.width - hit, y: 0, width: hit, height: bounds.height))
        let height = ceil(valueLabel.intrinsicContentSize.height)
        valueLabel.frame = CGRect(
            x: hit,
            y: (bounds.height - height) / 2,
            width: Swift.max(bounds.width - hit * 2, 0),
            height: height
        )
    }

    /// −1 for the decrement target, +1 for increment, 0 for the value column.
    private func direction(at point: CGPoint) -> Double {
        let hit = LedgeMetrics.stepperButton
        if point.x < hit { return -1 }
        if point.x > bounds.width - hit { return 1 }
        return 0
    }

    override func mouseDown(with event: NSEvent) {
        let direction = direction(at: convert(event.locationInWindow, from: nil))
        guard direction != 0 else { return }
        bump(direction)
        // Hold-to-repeat: one beat of grace, then fast. Implemented against the
        // event queue rather than a Timer so it cannot outlive the mouse-up.
        var interval = LedgeMetrics.stepperRepeatDelay
        while true {
            let deadline = Date().addingTimeInterval(interval)
            var released = false
            while let next = window?.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: deadline,
                inMode: .eventTracking,
                dequeue: true
            ) {
                if next.type == .leftMouseUp { released = true; break }
            }
            if released { break }
            bump(direction)
            interval = LedgeMetrics.stepperRepeatInterval
        }
    }

    /// One step, clamped. At the end of the range nothing is emitted — an app
    /// should not get a stream of `change` events all carrying the same number.
    private func bump(_ direction: Double) {
        let next = resolve(value + direction * step)
        guard next != value else { return }
        value = next
        // The app owns the display string, so a stepper the app is driving shows
        // the raw number for one frame at most; one it is not driving shows the
        // number, which is the honest thing for it to show.
        if display == nil { refreshValueLabel() } else { setAccessibilityValue(value) }
        layoutSubtreeIfNeeded()
        handler(value)
    }
}

/// `progress` (D6): the slider's track without the knob. Read-only by
/// definition — an app that wants input asks for a `slider`.
final class LedgeProgress: NSView, LedgeColumnFilling {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    var value: Double {
        didSet {
            value = min(max(value, 0), 1)
            needsLayout = true
        }
    }

    /// `rate` (spec §5): fraction per second of shell-side self-advance. Built
    /// lazily in `init` because it captures `self`.
    private var advancer: LedgeSelfAdvance!

    /// The fill's ink. Ink by default — a meter is quiet unless the app says the
    /// moment is worth a hue (design.html §01: Focus's session meter is accent,
    /// because the working moment is the one thing on that panel).
    private(set) var fillColor: NSColor = LedgeTheme.inkFill

    init(value: Double, color: NSColor = LedgeTheme.inkFill) {
        self.value = min(max(value, 0), 1)
        self.fillColor = color
        super.init(frame: .zero)
        wantsLayer = true
        trackLayer.backgroundColor = LedgeTheme.track.cgColor
        fillLayer.backgroundColor = color.cgColor
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityValue(self.value)
        advancer = LedgeSelfAdvance(owner: self) { [weak self] delta in
            guard let self else { return }
            // `value`'s own didSet clamps at 1: a countdown that outran its
            // deadline sits full rather than overflowing.
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

    /// `rate` from a prop update. Resolved, not optional — a deleted key means
    /// "back to static", never "unchanged".
    func applyRate(_ rate: Double?) {
        advancer.setRate(rate)
    }

    /// `color` from a prop update. Resolved rather than optional for the same
    /// reason `rate` is: `configure` sees the merged prop set, so a deleted
    /// `color` (null, §3.1) has to go back to ink instead of reading as
    /// "unchanged".
    func applyColor(_ color: NSColor) {
        guard color != fillColor else { return }
        fillColor = color
        // A commit that happens to change the hue must not cross-fade a bar
        // while the panel is measuring itself.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    /// A committed value, reconciled against wherever the local advance has got
    /// to. See `LedgeMetrics.selfAdvanceGlideSeconds` for why small differences
    /// are ignored rather than applied.
    func applyCommittedValue(_ next: Double) {
        guard advancer.rate > 0 else {
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: LedgeMetrics.progressHeight)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)          // a tick, not a state change
        trackLayer.frame = bounds
        trackLayer.cornerCurve = .continuous
        trackLayer.cornerRadius = LedgeMetrics.capsule(bounds.height)
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width * CGFloat(value),
            height: bounds.height
        )
        fillLayer.cornerCurve = .continuous
        fillLayer.cornerRadius = LedgeMetrics.capsule(bounds.height)
        CATransaction.commit()
        setAccessibilityValue(value)
    }
}

/// `spinner` (D6): a 16 pt ring at 2 pt, one turn every 0.9 s. Indeterminate
/// waiting only — determinate progress is `progress`.
///
/// The rotation is attached in `didMoveToWindow` and torn down when the view
/// leaves, so a spinner inside a collapsed panel is not animating a layer nobody
/// can see (and a detached view does not keep a CADisplayLink-shaped hole open).
final class LedgeSpinner: NSView {
    private static let animationKey = "ledge.spin"
    private let ringLayer = CAShapeLayer()
    private let capLayer = CAShapeLayer()
    private let spinLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [ringLayer, capLayer] {
            shape.fillColor = nil
            shape.lineWidth = LedgeMetrics.spinnerStroke
            shape.lineCap = .round
        }
        ringLayer.strokeColor = LedgeTheme.track.cgColor
        capLayer.strokeColor = LedgeTheme.primary.cgColor
        capLayer.strokeStart = 0
        capLayer.strokeEnd = LedgeMetrics.spinnerCapFraction
        layer?.addSublayer(ringLayer)
        spinLayer.addSublayer(capLayer)
        layer?.addSublayer(spinLayer)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: LedgeMetrics.spinnerSize, height: LedgeMetrics.spinnerSize)
    }

    /// Whether the ring is currently turning — how a test asks without sampling
    /// pixels, and the assertion that the off-window teardown actually happens.
    var isSpinning: Bool { spinLayer.animation(forKey: Self.animationKey) != nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = LedgeMetrics.spinnerStroke / 2
        let circle = CGPath(
            ellipseIn: bounds.insetBy(dx: inset, dy: inset),
            transform: nil
        )
        ringLayer.frame = bounds
        ringLayer.path = circle
        // A sublayer rotates about its own center: give it bounds + a position
        // rather than a frame, so the default (0.5, 0.5) anchor is the middle.
        spinLayer.bounds = bounds
        spinLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        capLayer.frame = spinLayer.bounds
        capLayer.path = circle
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }

    private func start() {
        guard !isSpinning else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2                  // clockwise on screen
        spin.duration = LedgeMetrics.spinnerDuration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        spinLayer.add(spin, forKey: Self.animationKey)
    }

    private func stop() {
        spinLayer.removeAnimation(forKey: Self.animationKey)
    }
}

/// `pill` (D6): the badge every app was assembling from a stack, a text and three
/// hand-picked alphas. A pill is always the **tint + stroke + hue-ink triple** of
/// one family (L9), and it routes through `CenteredTextBox` because a raw
/// NSTextField top-aligns inside a taller box.
final class LedgePill: CenteredTextBox {
    /// The hue families a pill may name. `neutral` is the no-hue case — raised
    /// glass and secondary ink — not a grey invented for the occasion.
    enum Tone: String, CaseIterable {
        case accent
        case green
        case red
        case violet
        case cyan
        case neutral

        static let `default`: Tone = .neutral

        init(token: String?) {
            self = Tone(rawValue: token ?? "") ?? .default
        }

        var ink: NSColor {
            switch self {
            case .accent: LedgeTheme.accent
            case .green: LedgeTheme.green
            case .red: LedgeTheme.red
            case .violet: LedgeTheme.violet
            case .cyan: LedgeTheme.cyan
            case .neutral: LedgeTheme.secondary
            }
        }

        var tint: NSColor {
            switch self {
            case .accent: LedgeTheme.accentTint
            case .green: LedgeTheme.greenTint
            case .red: LedgeTheme.redTint
            case .violet: LedgeTheme.violetTint
            case .cyan: LedgeTheme.cyanTint
            case .neutral: LedgeTheme.raised
            }
        }

        var stroke: NSColor {
            switch self {
            case .accent: LedgeTheme.accentStroke
            case .green: LedgeTheme.greenStroke
            case .red: LedgeTheme.redStroke
            case .violet: LedgeTheme.violetStroke
            case .cyan: LedgeTheme.cyanStroke
            case .neutral: LedgeTheme.hairline
            }
        }
    }

    private(set) var tone: Tone

    init(text: String, tone: Tone) {
        self.tone = tone
        super.init(
            text,
            font: LedgeTheme.systemFont(LedgeMetrics.pillPointSize, weight: LedgeMetrics.pillWeight),
            color: tone.ink,
            fill: tone.tint,
            stroke: tone.stroke,
            radius: LedgeMetrics.capsule(LedgeMetrics.pillHeight)
        )
        layer?.cornerCurve = .continuous
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        // A badge is its own width, never the column's (see `LedgeSegment`).
        setContentHuggingPriority(NSLayoutConstraint.Priority(751), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Label and tone both update in place — a status pill that has to be
    /// recreated to go from PAPER to LIVE is the create-only-props bug again.
    func apply(text: String?, tone newTone: Tone?) {
        if let text {
            label.stringValue = text
            setAccessibilityLabel(text)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        guard let newTone, newTone != tone else { return }
        tone = newTone
        label.textColor = newTone.ink
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = newTone.tint.cgColor
        layer?.borderColor = newTone.stroke.cgColor
        CATransaction.commit()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ceil(label.attributedStringValue.size().width) + LedgeMetrics.pillPadX * 2,
            height: LedgeMetrics.pillHeight
        )
    }
}
