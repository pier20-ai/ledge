import AppKit
import QuartzCore

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension CALayer {
    /// Scales around the visual center. Layer-backed AppKit views anchor at
    /// (0,0), so a bare scale transform collapses toward the corner.
    func setPressScale(_ scale: CGFloat, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if scale == 1 {
            setAffineTransform(.identity)
        } else {
            setAffineTransform(
                CGAffineTransform(
                    translationX: bounds.width / 2 * (1 - scale),
                    y: bounds.height / 2 * (1 - scale)
                )
                .scaledBy(x: scale, y: scale)
            )
        }
        CATransaction.commit()
    }
}

/// A rounded box that vertically centers one line of text — NSTextField
/// top-aligns text whenever its frame is taller than the text, so every
/// pill/badge/tag routes through this instead.
class CenteredTextBox: RoundedBoxView {
    let label: NSTextField

    init(
        _ text: String,
        font: NSFont,
        color: NSColor,
        fill: NSColor,
        stroke: NSColor = .clear,
        radius: CGFloat
    ) {
        label = makeLabel(text, font: font, color: color, alignment: .center)
        super.init(fill: fill, stroke: stroke, radius: radius)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(
            x: 0,
            y: (bounds.height - height) / 2,
            width: bounds.width,
            height: height
        )
    }
}

final class HairlineView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = LedgeTheme.hairline.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class RoundedBoxView: FlippedView {
    init(
        fill: NSColor = LedgeTheme.raised,
        stroke: NSColor = LedgeTheme.hairline,
        radius: CGFloat = LedgeMetrics.rCard
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = stroke.cgColor
        layer?.borderWidth = LedgeMetrics.hairline
        // The card tier is 12 (D4): the old 10 was concentric with nothing and
        // read cheap beside the notch's own continuous curve.
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = LedgeMetrics.capsule(LedgeMetrics.dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
func makeLabel(
    _ text: String,
    font: NSFont,
    color: NSColor = LedgeTheme.primary,
    alignment: NSTextAlignment = .left
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.alignment = alignment
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.isSelectable = false
    label.setAccessibilityLabel(text)
    return label
}

final class HoverIconButton: NSButton {
    /// The SF Symbol this button was built from. `NSImage.name()` is nil once
    /// `withSymbolConfiguration` has copied the image, so the only way to know
    /// which symbol a strip icon is showing is to keep it.
    let symbolName: String

    private let handler: () -> Void
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var active = false
    private let dotLayer = CALayer()

    /// Background drawn when not hovered (e.g. the lit play button).
    var baseBackground: NSColor = .clear {
        didSet { refreshAppearance() }
    }

    init(symbol: String, accessibilityLabel: String, handler: @escaping () -> Void) {
        self.symbolName = symbol
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: LedgeMetrics.stripIconPointSize,
                weight: LedgeMetrics.stripIconWeight
            )
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = LedgeTheme.secondary
        target = self
        action = #selector(activate)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(.button)
        wantsLayer = true
        // A strip icon is a circle, like every other control (D4/D8 Q1). Its
        // hover is tint-only, so the shape only shows when a background is set
        // (the lit play button) — but when it does, it must not be a rounded rect.
        layer?.cornerCurve = .continuous

        dotLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: LedgeMetrics.stripActiveDot,
            height: LedgeMetrics.stripActiveDot
        )
        dotLayer.cornerRadius = LedgeMetrics.capsule(LedgeMetrics.stripActiveDot)
        dotLayer.backgroundColor = LedgeTheme.primary.cgColor
        dotLayer.opacity = 0
        layer?.addSublayer(dotLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = LedgeMetrics.capsule(bounds.height)
        CATransaction.commit()
        dotLayer.position = CGPoint(
            x: bounds.midX,
            y: bounds.minY + LedgeMetrics.stripActiveDotInset
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

    override func mouseDown(with event: NSEvent) {
        layer?.setPressScale(LedgeMetrics.pressScaleIcon, duration: LedgeMetrics.pressDurationIn)
        super.mouseDown(with: event)
        layer?.setPressScale(1, duration: LedgeMetrics.pressDurationOut)
    }

    func setActive(_ active: Bool) {
        self.active = active
        refreshAppearance()
    }

    /// Test seam: what the button currently believes about the pointer.
    var isHovering: Bool { hovering }

    /// Enter/exit pairs go stale when the panel morphs and this button moves
    /// under a stationary cursor — always verify against the live pointer.
    /// Internal rather than private because the app strip scrolls now, and a
    /// scroll moves the button under a stationary cursor exactly the same way a
    /// morph does (law L5); the strip re-syncs its icons on every clip-view
    /// bounds change.
    func syncHover() {
        let inside = window.map { window in
            bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        } ?? false
        guard inside != hovering else { return }
        hovering = inside
        refreshAppearance()
    }

    private func refreshAppearance() {
        contentTintColor = active || hovering ? LedgeTheme.primary : LedgeTheme.secondary
        layer?.backgroundColor = baseBackground.cgColor
        dotLayer.opacity = active ? 1 : 0
    }

    @objc private func activate() {
        handler()
    }
}
