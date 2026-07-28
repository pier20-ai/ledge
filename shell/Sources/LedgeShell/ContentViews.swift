import AppKit
import LedgeShellCore

/// Gestures the surface reports upward. Everything here originates in Swift and
/// becomes a `selection` / `builderInput` envelope (spec §4.3) — the shell never
/// decides what a selection *means*, it only reports that one happened.
struct ShellCallbacks {
    let selectApp: (String) -> Void
    let selectNewApp: () -> Void
    let selectSettings: () -> Void
    let toggleChat: () -> Void

    /// Callbacks for a surface nobody can drive — snapshots, and the chrome
    /// surfaces that have nothing to report yet.
    @MainActor
    static let inert = ShellCallbacks(
        selectApp: { _ in },
        selectNewApp: {},
        selectSettings: {},
        toggleChat: {}
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
            font: LedgeTheme.systemFont(11.5, weight: .semibold),
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
                font: LedgeTheme.monoFont(10, weight: .medium),
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

private final class DividerLabelView: FlippedView {
    init(title: String) {
        super.init(frame: .zero)
        let left = HairlineView(frame: CGRect(x: 0, y: 10, width: 155, height: 1))
        addSubview(left)
        let label = makeLabel(
            title.uppercased(),
            font: LedgeTheme.monoFont(8.5, weight: .semibold),
            color: LedgeTheme.tertiary,
            alignment: .center
        )
        label.frame = CGRect(x: 161, y: 3, width: 86, height: 16)
        addSubview(label)
        let right = HairlineView(frame: CGRect(x: 253, y: 10, width: 155, height: 1))
        addSubview(right)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ChatBubbleView: RoundedBoxView {
    private let textLabel: NSTextField

    init(text: String, isUser: Bool) {
        textLabel = makeMultilineLabel(
            text,
            font: LedgeTheme.systemFont(12.5),
            color: LedgeTheme.primary
        )
        super.init(
            fill: isUser ? NSColor.white.withAlphaComponent(0.13) : LedgeTheme.raised,
            stroke: isUser ? .clear : LedgeTheme.hairline,
            radius: 13
        )
        addSubview(textLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        textLabel.frame = bounds.insetBy(dx: 11, dy: 7)
    }
}

private final class DiffView: RoundedBoxView {
    init() {
        super.init(fill: NSColor.black.withAlphaComponent(0.35), stroke: LedgeTheme.hairline, radius: 11)

        let header = FlippedView(frame: CGRect(x: 0, y: 0, width: 334, height: 26))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        let filename = makeLabel(
            "stocks.jsx",
            font: LedgeTheme.monoFont(10, weight: .semibold),
            color: LedgeTheme.secondary
        )
        filename.frame = CGRect(x: 10, y: 6, width: 160, height: 15)
        header.addSubview(filename)
        let counts = makeLabel(
            "+2  −1",
            font: LedgeTheme.monoFont(10, weight: .semibold),
            color: LedgeTheme.green,
            alignment: .right
        )
        counts.frame = CGRect(x: 240, y: 6, width: 84, height: 15)
        header.addSubview(counts)
        addSubview(header)

        let deleted = makeLabel(
            "<text size=\"xl\" weight=\"bold\">",
            font: LedgeTheme.monoFont(10.5),
            color: NSColor(srgbRed: 1, green: 0.54, blue: 0.50, alpha: 1)
        )
        deleted.frame = CGRect(x: 10, y: 31, width: 314, height: 16)
        deleted.wantsLayer = true
        deleted.layer?.backgroundColor = LedgeTheme.red.withAlpha(0.07).cgColor
        addSubview(deleted)

        let added = makeLabel(
            "<text size=\"xl\" weight=\"bold\"",
            font: LedgeTheme.monoFont(10.5),
            color: NSColor(srgbRed: 0.49, green: 0.91, blue: 0.64, alpha: 1)
        )
        added.frame = CGRect(x: 10, y: 49, width: 314, height: 16)
        added.wantsLayer = true
        added.layer?.backgroundColor = LedgeTheme.green.withAlpha(0.08).cgColor
        addSubview(added)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ChatInputView: RoundedBoxView {
    init(placeholder: String) {
        super.init(fill: NSColor.white.withAlphaComponent(0.07), stroke: LedgeTheme.hairline, radius: 12)
        let label = makeLabel(
            placeholder,
            font: LedgeTheme.systemFont(12.5),
            color: LedgeTheme.tertiary
        )
        label.frame = CGRect(x: 12, y: 13, width: 330, height: 18)
        addSubview(label)
        let send = AccentIconButton(accessibilityLabel: "Send", handler: {})
        send.frame = CGRect(x: 356, y: 2, width: 40, height: 40)
        addSubview(send)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Hosts an app's `<mini>` node in the peek surface (spec §3.3 extension).
///
/// The app supplies content and nothing else — no width, no dwell, no chrome —
/// so this centres it, pads it, and lets the controller size the surface from
/// `fits(in:)`. Deliberately dumb: everything about *when* a mini is on screen
/// lives in the panel controller, and everything about what it says lives in the
/// app's tree.
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

    /// Adopt (or release) the app's mini node. The view belongs to the app's
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
        let width = min(max(fitting.width + Self.padX * 2, floor), maxWidth)
        let height = min(max(fitting.height + Self.padY * 2, Self.minHeight), Self.maxHeight)
        return CGSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        guard let content else { return }
        let available = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        let fitting = content.fittingSize
        // Centred both ways: a mini is one line about one thing, and left-
        // aligning it in a surface sized to fit leaves a gap that reads as a
        // layout bug rather than a choice.
        content.frame = CGRect(
            x: available.minX + max(0, (available.width - fitting.width) / 2),
            y: available.minY + max(0, (available.height - fitting.height) / 2),
            width: min(fitting.width, available.width),
            height: min(fitting.height, available.height)
        )
    }
}

/// An app's chat surface (spec §8). Shell chrome, not an app: it renders
/// `builder` events, and until the agent adapters land it shows the mockup
/// transcript inert. Its height is fixed here because nothing measures it —
/// there is no host tree behind this surface.
final class ChatContentView: FlippedView {
    /// Total panel height (content + the 42 pt app strip).
    static let panelHeight: CGFloat = 384

    init(title: String = "Stocks", callbacks: ShellCallbacks) {
        super.init(frame: .zero)
        let header = AppHeaderView(
            title: title,
            status: "stocks.jsx",
            showsLiveDot: true,
            chatActive: true,
            onChat: callbacks.toggleChat
        )
        header.frame = CGRect(x: 0, y: 0, width: 440, height: 34)
        addSubview(header)

        let ticker = makeLabel(
            "AAPL",
            font: LedgeTheme.systemFont(13, weight: .bold),
            color: LedgeTheme.secondary
        )
        ticker.frame = CGRect(x: 16, y: 43, width: 48, height: 20)
        addSubview(ticker)
        let price = makeLabel(
            "$214.62",
            font: LedgeTheme.numericFont(22, weight: .bold),
            color: LedgeTheme.green
        )
        price.frame = CGRect(x: 68, y: 37, width: 112, height: 30)
        addSubview(price)
        let delta = makeLabel(
            "▲ 1.24%",
            font: LedgeTheme.numericFont(12, weight: .semibold),
            color: LedgeTheme.green
        )
        delta.frame = CGRect(x: 187, y: 44, width: 82, height: 18)
        addSubview(delta)

        let divider = DividerLabelView(title: "Transcript")
        divider.frame = CGRect(x: 16, y: 68, width: 408, height: 22)
        addSubview(divider)

        let user = ChatBubbleView(text: "make the price green when it's up", isUser: true)
        user.frame = CGRect(x: 195, y: 94, width: 229, height: 40)
        addSubview(user)

        let diff = DiffView()
        diff.frame = CGRect(x: 16, y: 138, width: 334, height: 72)
        addSubview(diff)

        let status = makeLabel(
            "✓ Worker reloaded · 1.2s — live above",
            font: LedgeTheme.monoFont(10.5, weight: .medium),
            color: LedgeTheme.green
        )
        status.frame = CGRect(x: 16, y: 217, width: 330, height: 18)
        addSubview(status)

        let input = ChatInputView(placeholder: "Ask for a change…")
        input.frame = CGRect(x: 12, y: 286, width: 416, height: 44)
        addSubview(input)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The **[+]** surface (spec §8): the same chat over a folder that doesn't
/// exist yet. Shell chrome; inert until the builder adapters land.
final class NewAppContentView: FlippedView {
    static let panelHeight: CGFloat = 352

    init(callbacks: ShellCallbacks) {
        super.init(frame: .zero)
        let header = AppHeaderView(title: "New app", status: "untitled.jsx")
        header.frame = CGRect(x: 0, y: 0, width: 440, height: 34)
        addSubview(header)

        let preview = RoundedBoxView(fill: NSColor.clear, stroke: NSColor.white.withAlphaComponent(0.14), radius: 12)
        preview.layer?.borderWidth = 1.5
        preview.frame = CGRect(x: 16, y: 42, width: 408, height: 56)
        let previewLabel = makeLabel(
            "Preview appears here as the app is built",
            font: LedgeTheme.systemFont(11.5),
            color: LedgeTheme.tertiary,
            alignment: .center
        )
        previewLabel.frame = CGRect(x: 16, y: 19, width: 376, height: 18)
        preview.addSubview(previewLabel)
        addSubview(preview)

        let divider = DividerLabelView(title: "Transcript")
        divider.frame = CGRect(x: 16, y: 105, width: 408, height: 22)
        addSubview(divider)

        let user = ChatBubbleView(
            text: "track flight UA 884 tomorrow, ping me if the gate changes",
            isUser: true
        )
        user.frame = CGRect(x: 150, y: 132, width: 274, height: 50)
        addSubview(user)

        let ai = ChatBubbleView(
            text: "On it — writing flight.jsx with a monitor() on the departures feed. It’ll need network access to flightaware.com.",
            isUser: false
        )
        ai.frame = CGRect(x: 16, y: 188, width: 334, height: 62)
        addSubview(ai)

        let input = ChatInputView(placeholder: "Describe an app…")
        input.frame = CGRect(x: 12, y: 254, width: 416, height: 44)
        addSubview(input)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

