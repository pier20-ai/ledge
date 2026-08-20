import AppKit
import Foundation
import LedgeShellCore
import WebKit

/// How the last turn ended, as carried by the Edit/Preview toggle's colour.
/// Derived from `app` lifecycle envelopes (§3.2), not from `done` — the honest
/// question after a turn is not "did the agent finish" but "does the app still
/// run", and only the worker can answer that.
enum EditorBuildStatus: Equatable, Sendable {
    case neutral
    case reloaded
    case crashed
}

/// The transcript layer of chat mode (spec §8, design.html §08): the
/// conversation, as a transparent web view.
///
/// **One layer of three, not a page.** `ChatSurfaceView` composes it over the
/// session's live stage and inside the panel body's own glass; this draws the
/// bubbles, the shimmer and the pill and nothing else. It covers the whole pane
/// rather than a box below the stage, which is what lets a bubble float back
/// over the stage's bottom edge — and what makes the pointer arrest total.
///
/// Why a web view at all, in a shell whose entire premise is native views: this
/// is the one surface that is *not* an app. It renders a transcript — streamed
/// prose, at a word budget, with bubbles that glow — which is the thing AppKit
/// is worst at and the web is best at, and it is the one surface the user
/// iterates on daily. The protocol vocabulary (§5) stays deliberately small
/// precisely so it does not have to grow a rich-text engine for this.
///
/// Everything crossing into it is untrusted: the transcript is model output.
/// The page loads from `file://` under a CSP that permits no network at all, and
/// the bridge hands it JSON — never HTML.
@MainActor
final class EditorSurfaceView: FlippedView {
    let bridge = EditorBridge()
    /// The user sent something, so whatever the last turn's build status was is
    /// now stale. The controller uses this to put the toggle back to neutral.
    var onActivity: (() -> Void)?
    /// The pill's ⌄/⌃ (design.html §08). The pane clears itself; the panel is a
    /// different height with no transcript in it.
    var onTranscript: ((Bool) -> Void)?
    /// The transcript scrolled into the past, or came back to the latest.
    var onScrollback: ((Bool) -> Void)?
    /// Esc, with nothing in the page left to interrupt.
    var onEscape: (() -> Void)?
    /// The page announced itself — a first load, or a return from a web-content
    /// crash. Anything the page cannot know on its own has to be re-sent.
    var onReady: (() -> Void)?

    private let webView: WKWebView
    private var relay: EditorWebRelay!
    private var missingBundleLabel: NSTextField?

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)

        // Parsed off the main actor, applied on it. See `EditorCommand`: the
        // closure handed to WebKit is `@Sendable` and closes over nothing but a
        // weak reference to this (`@MainActor` ⇒ Sendable) object, so WebKit
        // calling it from its own queue cannot trip the executor assertion the
        // way a plain main-actor closure would.
        let relay = EditorWebRelay(
            onCommand: { [weak self] command in
                Task { @MainActor in self?.handle(command) }
            },
            onNavigationBlocked: { url in
                // The transcript is model output, and a link in it must not be
                // able to move the surface off the bundle — not to a web page,
                // not to another local file.
                NSLog("[ledge] editor blocked navigation to %@", url)
            }
        )
        self.relay = relay
        configuration.userContentController.add(relay, name: "ledge")
        webView.navigationDelegate = relay

        // The panel is black glass. A web view draws an opaque white page by
        // default, which does not tint the glass — it replaces it, and the
        // notch stops looking like hardware. `drawsBackground` is KVC-only on
        // WKWebView; `underPageBackgroundColor` covers the rubber-band area the
        // page itself never paints.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        bridge.evaluate = { [weak self] script in
            // The completion handler is `@Sendable` and ignores its arguments —
            // WebKit may call it on its own queue, and there is nothing here
            // worth hopping back for. Errors are the page's problem (a missing
            // `__ledgeDeliver` is guarded in the script itself).
            self?.webView.evaluateJavaScript(script, completionHandler: nil)
        }

        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        missingBundleLabel?.frame = bounds.insetBy(dx: 24, dy: 24)
    }

    /// The view the panel should make first responder so typing reaches the
    /// page. Not the surface itself: `WKWebView` forwards to its own content
    /// view, and handing first responder to the wrapper drops the first
    /// keystroke.
    var keyboardResponder: NSView { webView }

    /// Test seam: the destination of the relay's hop, reachable without a live
    /// web content process. There is no `WKWebView` painting in `swift test`, so
    /// this is the only way to assert what a page message actually *does* rather
    /// than only that it parses.
    func apply(_ command: EditorCommand) {
        handle(command)
    }

    private func handle(_ command: EditorCommand) {
        switch command {
        case .input, .cancel:
            onActivity?()
        case .transcript(let collapsed):
            onTranscript?(collapsed)
        case .scrollback(let past):
            onScrollback?(past)
        case .escape:
            onEscape?()
        case .ready:
            // After `bridge.submit`, below: the queue has to flush before
            // anything new is emitted, or the re-sent state arrives first.
            break
        }
        bridge.submit(command)
        if case .ready = command { onReady?() }
    }

    // MARK: - Loading

    /// Where the built bundle lives inside the resource bundle. Built by
    /// `scripts/build-editor.sh` from `editor/` at the repo root and copied
    /// wholesale (`.copy`, not `.process`) so the paths the HTML references
    /// survive verbatim.
    static var bundleRoot: URL? {
        guard let resources = Bundle.module.resourceURL else { return nil }
        let root = resources.appendingPathComponent("editor", isDirectory: true)
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
            ? root
            : nil
    }

    private func load() {
        guard let root = Self.bundleRoot else {
            showMissingBundle()
            return
        }
        // `loadFileURL` with a read-access *directory* rather than the file:
        // without it WebKit grants access to the single HTML file only and the
        // sibling script and stylesheet fail to load, which looks exactly like a
        // CSP problem and is not one.
        webView.loadFileURL(
            root.appendingPathComponent("index.html"),
            allowingReadAccessTo: root
        )
    }

    /// The dev-loop failure: a shell built without running the editor build. Say
    /// so in the panel, because a blank black rectangle is indistinguishable
    /// from a bridge that is silently broken.
    private func showMissingBundle() {
        webView.isHidden = true
        let label = NSTextField(wrappingLabelWithString:
            "Editor bundle missing.\nRun scripts/build-editor.sh and rebuild the shell.")
        label.font = LedgeTheme.monoFont(11)
        label.textColor = LedgeTheme.secondary
        label.alignment = .center
        label.isSelectable = false
        addSubview(label)
        missingBundleLabel = label
        NSLog("[ledge] editor bundle missing from the shell's resources")
    }
}

/// WebKit's side of the surface, kept off the main actor on purpose.
///
/// This repo has already lost a day to a `@MainActor` object handing a closure
/// to a system framework that then invoked it on its own queue, tripping Swift
/// 6's executor assertion inside a bundled build (a bare `SIGTRAP`, no
/// backtrace). Rather than assert where WebKit calls from, this object is
/// `nonisolated` throughout: it does only pure parsing, then hands a `Sendable`
/// value across an explicit hop.
private final class EditorWebRelay: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let onCommand: @Sendable (EditorCommand) -> Void
    private let onNavigationBlocked: @Sendable (String) -> Void

    init(
        onCommand: @escaping @Sendable (EditorCommand) -> Void,
        onNavigationBlocked: @escaping @Sendable (String) -> Void
    ) {
        self.onCommand = onCommand
        self.onNavigationBlocked = onNavigationBlocked
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // `message` is not Sendable and `body` is `Any`; parsing here is what
        // keeps both out of the hop.
        guard let command = EditorBridge.command(from: message.body) else { return }
        onCommand(command)
    }

    /// `@MainActor` **because the SDK says so**, not because it looks safe: the
    /// requirement is declared `@MainActor` and its `decisionHandler` is a
    /// `@MainActor @Sendable` closure, so a nonisolated implementation silently
    /// fails to witness it (a "nearly matches" warning and a delegate method
    /// that is never called — i.e. navigation quietly unguarded). Stating the
    /// isolation is the whole point; `userContentController` above stays
    /// nonisolated because it genuinely needs nothing from the main actor.
    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        // Only the initial bundle load. A link the model wrote is content, not
        // navigation: allowing it would let agent output replace the editor with
        // an arbitrary page inside the user's notch.
        let allowed = navigationAction.navigationType == .other && (url?.isFileURL ?? false)
        if !allowed { onNavigationBlocked(url?.absoluteString ?? "(none)") }
        decisionHandler(allowed ? .allow : .cancel)
    }
}
