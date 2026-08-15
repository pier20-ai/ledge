import AppKit
import Foundation
import LedgeShellCore
import QuartzCore

/// **Chat mode** — the transcript pane over the stage (flow.md, "Visit modes";
/// design.html §01 "Chat" and §08).
///
/// One session, two modes. Stage is the app, full size and interactive. Chat is
/// this: the same app still mounted and still hot-reloading, held at reduced
/// prominence at the top of the pane, with the conversation over it and the
/// prompt pill on the clearest glass at the bottom.
///
/// Three facts decide the whole composition:
///
///  1. **The stage is inert, period.** Not "inert until you collapse the
///     transcript" — collapsing only clears the view to *watch*; Done is the way
///     back to touching it. So the arrest is structural rather than a policy
///     somebody has to remember: the well refuses every hit test it is offered,
///     and the transcript's web view covers the pane above it in any case.
///  2. **The glass is the panel body, not a rectangle inside it.** Chat runs
///     opaque at the top to nearly clear at the bottom (flow.md, Material), and
///     that fade has to take the fillets, the shoulder and the bottom radius
///     with it — so it is painted by `ShellSurfaceView` as the body's own
///     material and not by anything in here.
///  3. **The transcript is one transparent web view over the whole pane**, not a
///     box below the stage. That is what lets a bubble float back over the
///     stage's bottom edge (design.html §08's −14 pt overlap) instead of being
///     clipped by a box boundary, and it is why the page is told how much room
///     the stage takes rather than being handed a smaller frame.
@MainActor
final class ChatSurfaceView: FlippedView {
    // MARK: - The measurements (design.html §01 `.glasspanel` / `.stage-min`)

    /// `.glasspanel` padding-top: the breath above the stage.
    static let topPad: CGFloat = 14
    /// The pill and the air around it — `margin-top: 10` + 40 pt capsule +
    /// `padding-bottom: 12`. The pill never moves, so this never changes.
    static let pillRoom: CGFloat = 62
    /// What the conversation itself gets below the stage: enough for the last
    /// exchange to linger (design.html §08) without the panel becoming a window.
    static let transcriptRoom: CGFloat = 152
    /// A slot with no stage is pure conversation, and takes the whole pane.
    static let blankPanelHeight: CGFloat = 384
    /// The stage's reduced prominence. Not a thumbnail and not a screenshot —
    /// the live tree, one step back.
    static let stageScale: CGFloat = 0.96
    static let stageDim: CGFloat = 0.92
    /// Scrolled into the past, it recedes further (design.html §08).
    static let recededDim: CGFloat = 0.55
    static let recededBlur: CGFloat = 6

    /// The panel height chat wants. `stageHeight` is the session's measured tree
    /// height, or nil for a slot with no stage; `collapsed` is the pill's ⌄,
    /// which leaves the stage and the pill and takes everything between them.
    static func panelHeight(stageHeight: CGFloat?, collapsed: Bool = false) -> CGFloat {
        guard let stageHeight else { return blankPanelHeight }
        let stage = topPad + stageHeight * stageScale
        return collapsed ? stage + pillRoom : stage + transcriptRoom + pillRoom
    }

    // MARK: - Parts

    /// The transcript's renderer. One web view for every session — there is one
    /// panel, so there is one conversation on screen — and switching sessions is
    /// a message on the bridge, not a reload.
    let editor = EditorSurfaceView()
    private let stageWell = StageWellView()

    /// The pane's height changed because the user collapsed or reopened the
    /// transcript. The controller re-measures; nothing in here resizes a panel.
    var onPaneChange: (() -> Void)?
    /// Esc, forwarded from the page (see `EditorCommand.escape`).
    var onEscape: (() -> Void)?

    private(set) var collapsed = false
    private(set) var recededIntoThePast = false
    private var stageContent: NSView?
    private var stageHeight: CGFloat = 0

    var bridge: EditorBridge { editor.bridge }
    var keyboardResponder: NSView { editor.keyboardResponder }
    /// Whether a stage is mounted behind the pane. False on the blank slot,
    /// which is chat and nothing else (flow.md, "The strip").
    var hasStage: Bool { stageContent != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // `.stage-min`: the app's own glass, one content radius, a hairline —
        // and 0.92 of the ink it has on stage.
        stageWell.wantsLayer = true
        stageWell.layer?.backgroundColor = LedgeTheme.glassSolid.cgColor
        stageWell.layer?.cornerRadius = LedgeMetrics.rContent
        stageWell.layer?.borderWidth = LedgeMetrics.hairline
        stageWell.layer?.borderColor = LedgeTheme.hairline.cgColor
        stageWell.layer?.masksToBounds = true
        // CoreImage filters are opt-in per view, and the recede is the only
        // thing in the shell that uses one.
        stageWell.layerUsesCoreImageFilters = true
        stageWell.alphaValue = Self.stageDim
        stageWell.isHidden = true
        addSubview(stageWell)

        // Added last: the transcript is over the stage, always, and that is what
        // arrests the pointer before it can reach an app that is not listening.
        editor.autoresizingMask = [.width, .height]
        addSubview(editor)

        editor.onEscape = { [weak self] in self?.onEscape?() }
        editor.onTranscript = { [weak self] collapsed in self?.setCollapsed(collapsed) }
        editor.onScrollback = { [weak self] past in self?.setRecede(past) }
        // A page that has just come up (or come back from a web-content crash)
        // knows nothing about the stage behind it.
        editor.onReady = { [weak self] in self?.publishStage() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - The stage behind

    /// Mount (or unmount) the session's live tree behind the pane.
    ///
    /// The view handed over is the *same* composite the stage mode shows, so the
    /// app keeps rendering, keeps committing and keeps hot-reloading while the
    /// conversation about it is on screen. Re-presenting the same view is a
    /// re-measure, not a re-mount: an app that commits ten times a second must
    /// not have its view torn out and put back ten times a second.
    func setStage(_ content: NSView?, height: CGFloat) {
        stageHeight = height
        // Already ours *and* still in the well. Both halves matter: the
        // composite is shared with stage mode, so between two chat
        // presentations it may have been reparented out from under us — and an
        // identity check alone would then leave the well empty for good.
        if let content, content === stageContent, content.superview === stageWell {
            needsLayout = true
            return
        }
        // Unmount only what is genuinely mounted here. Ripping the composite
        // out of wherever stage mode has since put it is the same bug from the
        // other side.
        if let previous = stageContent, previous.superview === stageWell {
            previous.removeFromSuperview()
        }
        stageContent = content
        stageWell.isHidden = content == nil
        if let content {
            content.autoresizingMask = [.width, .height]
            stageWell.addSubview(content)
        }
        needsLayout = true
    }

    /// Tell the page how much of the pane the stage occupies, and whether there
    /// is one at all — the transcript starts below it, and the pill grows its
    /// ⌄/⌃ only when there is something to watch.
    private func publishStage() {
        bridge.setStage(present: stageContent != nil, inset: stageInset)
    }

    /// The stage's on-screen depth. **Not** including `topPad`: the page's own
    /// `.pane` padding is that same 14 pt, so counting it here too would push
    /// the first bubble a pad further down than the stage actually reaches.
    /// (The two constants have to agree — see the token-sync note in the build
    /// plan; the CSS cannot import Swift's.)
    var stageInset: CGFloat {
        stageContent == nil ? 0 : stageHeight * Self.stageScale
    }

    /// Point the pane at a session. Switching sessions is a message on the
    /// bridge, not a reload — but it is a new conversation, so the pane's own
    /// two states start over: nothing is collapsed and nothing is in the past.
    func focus(app: String) {
        guard bridge.app != app else { return }
        bridge.focus(app: app)
        collapsed = false
        setRecede(false)
    }

    // MARK: - The two states the page can put the pane in

    private func setCollapsed(_ next: Bool) {
        guard next != collapsed else { return }
        collapsed = next
        // Collapsing does not give the stage back its prominence: it is still
        // inert, and a stage that brightened while it was still untouchable
        // would be lying about it.
        onPaneChange?()
    }

    /// Scrolled into the past: the stage dims further and blurs, and comes back
    /// on jump-to-latest (design.html §08). Motion, not decoration — it is what
    /// makes "you are reading history" legible without a word.
    private func setRecede(_ past: Bool) {
        guard past != recededIntoThePast else { return }
        recededIntoThePast = past
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? LedgeMotion.fast : LedgeMotion.move
            context.allowsImplicitAnimation = true
            stageWell.animator().alphaValue = past ? Self.recededDim : Self.stageDim
        }
        stageWell.layer?.filters = past
            ? [CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": Self.recededBlur])]
                .compactMap { $0 }
            : []
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        editor.frame = bounds
        guard stageContent != nil else {
            publishStage()
            return
        }
        // Anchored at the top and shrunk toward it: an AppKit layer anchors at
        // (0, 0), so the scale alone would collapse the well into its top-left
        // corner. The translation puts the horizontal half back.
        stageWell.frame = CGRect(x: 0, y: Self.topPad, width: bounds.width, height: stageHeight)
        stageWell.layer?.setAffineTransform(
            CGAffineTransform(translationX: bounds.width * (1 - Self.stageScale) / 2, y: 0)
                .scaledBy(x: Self.stageScale, y: Self.stageScale)
        )
        publishStage()
    }

    // MARK: - The arrest

    /// Nothing beneath the pane receives a pointer event. The transcript's web
    /// view already covers the whole pane, so this is the second lock rather
    /// than the first — but it is the one that cannot be undone by a layout
    /// change, a transparent region, or a future surface that does not fill the
    /// pane, and "the stage is inert, period" is a law and not a side effect.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit.isDescendant(of: stageWell) else { return hit }
        return self
    }
}

/// The well the stage sits in while the conversation is up. It refuses hit
/// tests on its own account, so an app's tree cannot take a click even if it
/// somehow ended up in front of the transcript.
private final class StageWellView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
