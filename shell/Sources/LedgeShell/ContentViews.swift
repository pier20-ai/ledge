import AppKit
import LedgeShellCore

/// Gestures the surface reports upward. Everything here originates in Swift and
/// becomes a `selection` / `builderInput` envelope (spec §4.3) — the shell never
/// decides what a selection *means*, it only reports that one happened.
struct ShellCallbacks {
    let selectApp: (String) -> Void
    /// The strip's blank slot — what **[+]** used to be (flow.md, "The strip").
    let selectNewApp: () -> Void
    /// Settings, from the right-click menu or ⌘, (flow.md, Edges).
    let selectSettings: () -> Void
    /// The left wing's bead: lower the glass onto the conversation, or raise it.
    let toggleChat: () -> Void
    /// The right wing's `‹|›`, and a horizontal swipe: walk the session strip.
    /// `-1` is `‹`, `+1` is `›`.
    let walkStrip: (Int) -> Void
    /// The `|` between them: **the ledge**, the zoomed-out overview (flow.md,
    /// "The strip"). The same callback in the panel and in the parked window —
    /// the whole surface tears off, so its controls do too.
    let showOverview: () -> Void
    /// Quit Ledge, from the right-click menu. The only way out now that the
    /// bottom bar (and with it the Settings app's Quit row) is gone.
    let quit: () -> Void

    /// Callbacks for a surface nobody can drive — snapshots, and the chrome
    /// surfaces that have nothing to report yet.
    @MainActor
    static let inert = ShellCallbacks(
        selectApp: { _ in },
        selectNewApp: {},
        selectSettings: {},
        toggleChat: {},
        walkStrip: { _ in },
        showOverview: {},
        quit: {}
    )
}

@MainActor
private func makeMultilineLabel(
    _ text: String,
    font: NSFont,
    color: NSColor = LedgeTheme.primary,
    alignment: NSTextAlignment = .left
) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.textColor = color
    label.alignment = alignment
    label.isSelectable = false
    label.setAccessibilityLabel(text)
    return label
}

final class AppHeaderView: FlippedView {
    init(
        title: String,
        status: String? = nil,
        showsLiveDot: Bool = false,
        chatActive: Bool = false,
        onChat: (() -> Void)? = nil
    ) {
        super.init(frame: .zero)

        var titleX: CGFloat = 16
        if showsLiveDot {
            let dot = DotView(color: LedgeTheme.green)
            dot.frame = CGRect(x: 16, y: 15, width: 5, height: 5)
            addSubview(dot)
            titleX = 28
        }

        let titleLabel = makeLabel(
            title,
            font: LedgeTheme.systemFont(LedgeMetrics.TypeSize.s.pointSize, weight: .semibold),
            color: LedgeTheme.secondary
        )
        titleLabel.frame = CGRect(x: titleX, y: 9, width: 180, height: 17)
        addSubview(titleLabel)

        var rightEdge: CGFloat = 424
        if let onChat {
            let chat = HoverIconButton(
                symbol: "sparkles",
                accessibilityLabel: chatActive ? "Close chat" : "Open chat",
                handler: onChat
            )
            chat.contentTintColor = chatActive ? LedgeTheme.accent : LedgeTheme.secondary
            chat.frame = CGRect(x: 392, y: -3, width: 40, height: 40)
            addSubview(chat)
            rightEdge = 390
        }

        if let status {
            let statusLabel = makeLabel(
                status,
                font: LedgeTheme.monoFont(LedgeMetrics.TypeSize.xs.pointSize, weight: .medium),
                color: LedgeTheme.secondary,
                alignment: .right
            )
            statusLabel.frame = CGRect(x: rightEdge - 150, y: 9, width: 150, height: 17)
            addSubview(statusLabel)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Hosts an app's `<mini>` or `<summary>` node in **the swell** — the notch
/// growing down and out (flow.md: the notification and the summary, five
/// surfaces, two of them this one).
///
/// The app supplies content and nothing else — no width, no dwell, no chrome —
/// so this centres it, pads it, and lets the controller size the surface from
/// `preferredSize`. Deliberately dumb: everything about *when* a swell is on
/// screen lives in the panel controller, and everything about what it says
/// lives in the app's tree.
///
/// The one thing the app does not supply is the summary's **chevron**. flow.md:
/// "The summary always shows a quiet open affordance — it must be obvious that
/// a click opens the full thing." An affordance an app could forget to draw is
/// an affordance half the sessions will not have, so the shell draws it, outside
/// the app's node, and an app cannot remove it.
final class MiniContentView: FlippedView {
    /// Padding around the app's content. Generous horizontally because the
    /// surface's corners are rounded and text tucked into them reads as clipped.
    static let padX: CGFloat = 14
    static let padY: CGFloat = 6
    /// How far past the hardware cutout a mini always extends, per side.
    ///
    /// Derived from the notch, never a constant: a constant gets this *visibly*
    /// wrong. 180 pt is narrower than a 189 pt cutout, so a short mini rendered
    /// NARROWER than the notch it hangs from — the notch appearing to pinch in
    /// sideways while growing downwards, which is the one thing this surface
    /// must never look like.
    ///
    /// 22 pt a side, tuned against the real notch: enough that the surface
    /// reads as *the notch itself widening*, not so much that it becomes a panel
    /// that happens to start at the top of the screen. The panel is the other
    /// rung. Paired with a short content row — a peek is wide and shallow,
    /// because one line of text is what it is for.
    static let notchOvershoot: CGFloat = 22

    /// Absolute floor, used only when no cutout measurement is available
    /// (snapshots, headless tests).
    static let minWidth: CGFloat = 180
    static let minHeight: CGFloat = 34
    static let maxHeight: CGFloat = 80

    private var content: NSView?
    private let chevron: NSImageView

    /// Whether the shell's open affordance is drawn. True for the summary, false
    /// for the notification — a notification promises nothing; it *is* the
    /// thing, and it has at most one action of its own.
    private(set) var showsOpenAffordance = false

    override init(frame frameRect: NSRect) {
        chevron = NSImageView()
        chevron.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Opens the session"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: LedgeMetrics.swellChevronPointSize,
                weight: LedgeMetrics.swellChevronWeight
            )
        )
        // `ink-3` (design.html §03): quiet enough to be an affordance rather
        // than a control, present enough to be seen at notch scale.
        chevron.contentTintColor = LedgeTheme.tertiary
        chevron.imageScaling = .scaleProportionallyDown
        chevron.isHidden = true
        super.init(frame: frameRect)
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Turn the open affordance on (summary) or off (notification).
    func setShowsOpenAffordance(_ shows: Bool) {
        guard shows != showsOpenAffordance else { return }
        showsOpenAffordance = shows
        chevron.isHidden = !shows
        needsLayout = true
    }

    /// The width the chevron and its gap claim out of the surface.
    private var affordanceWidth: CGFloat {
        showsOpenAffordance
            ? LedgeMetrics.swellChevronBox + LedgeMetrics.swellChevronGap
            : 0
    }

    /// Adopt (or release) the app's swell node. The view belongs to the app's
    /// tree, so it is only ever borrowed — never removed from that tree, and
    /// handed back unmodified when the peek ends.
    func adopt(_ view: NSView?) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        guard let view else { return }
        // The renderer builds every node for Auto Layout; this surface frames
        // its content by hand, exactly as the panel wing zone does.
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view)
        needsLayout = true
    }

    /// The surface size this content wants, already clamped.
    /// The adopted content's own fitting size — the number `preferredSize` is
    /// built from. Exposed so tests can assert the surface is *derived from* its
    /// content rather than landing on a floor, which is how an empty mini once
    /// passed every placement test while rendering nothing at all.
    var fittingSizeOfContent: CGSize { content?.fittingSize ?? .zero }

    /// `cutoutWidth` is the hardware notch: the surface is never narrower than
    /// that plus `notchOvershoot` a side, so a peek always reads as the notch
    /// widening rather than pinching in. Pass 0 where there is no measurement
    /// (snapshots, headless tests).
    func preferredSize(cutoutWidth: CGFloat, maxWidth: CGFloat) -> CGSize {
        let fitting = content?.fittingSize ?? .zero
        let floor = max(Self.minWidth, cutoutWidth + Self.notchOvershoot * 2)
        // The chevron is paid for out of the *surface*, not out of the app's
        // room: a summary and a notification carrying the same line come out the
        // same height, and the app's content never has to shrink to make space
        // for something it did not ask for.
        let width = min(max(fitting.width + Self.padX * 2 + affordanceWidth, floor), maxWidth)
        let height = min(max(fitting.height + Self.padY * 2, Self.minHeight), Self.maxHeight)
        return CGSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        let padded = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        // Trailing, vertically centred — design.html §03 draws it at the end of
        // the payload row, after the line.
        if showsOpenAffordance {
            chevron.frame = CGRect(
                x: padded.maxX - LedgeMetrics.swellChevronBox,
                y: padded.midY - LedgeMetrics.swellChevronBox / 2,
                width: LedgeMetrics.swellChevronBox,
                height: LedgeMetrics.swellChevronBox
            )
        }
        guard let content else { return }
        let available = CGRect(
            x: padded.minX,
            y: padded.minY,
            width: max(0, padded.width - affordanceWidth),
            height: padded.height
        )
        let fitting = content.fittingSize
        // Centred both ways: a swell is one line about one thing, and left-
        // aligning it in a surface sized to fit leaves a gap that reads as a
        // layout bug rather than a choice.
        content.frame = CGRect(
            x: available.minX + max(0, (available.width - fitting.width) / 2),
            y: available.minY + max(0, (available.height - fitting.height) / 2),
            width: min(fitting.width, available.width),
            height: min(fitting.height, available.height)
        )
    }

    // MARK: - Test seams

    var chevronView: NSImageView { chevron }
}


