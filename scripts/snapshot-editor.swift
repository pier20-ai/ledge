// Render the built editor bundle in a real WKWebView and write a PNG.
//
//   swift scripts/snapshot-editor.swift [out.png]
//
// This exists because the obvious way to look at the editor does not work:
// `screencapture` needs a Screen Recording grant that a CLI process does not
// have, and without it returns the wallpaper. `WKWebView.takeSnapshot` renders
// in-process and needs no permission at all.
//
// It loads the SAME files the shell loads, with the same `loadFileURL` +
// read-access directory, then drives a scripted turn through the same
// `window.__ledgeDeliver` entry point Swift uses. So what comes out is the
// surface as it will actually appear — including whether the CSP let the bundle
// run at all, which is invisible until something fails to render.
//
// Composited over black on purpose: the page is transparent (the panel's glass
// is Swift's), so a snapshot on white would hide exactly the bug — an opaque
// page background — that this is most useful for catching.

import AppKit
import WebKit

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "/tmp/ledge-editor.png"

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let editorDir = repoRoot.appendingPathComponent("shell/Sources/LedgeShell/Resources/editor")
let indexURL = editorDir.appendingPathComponent("index.html")

guard FileManager.default.fileExists(atPath: indexURL.path) else {
    FileHandle.standardError.write(Data("no editor bundle — run scripts/build-editor.sh\n".utf8))
    exit(1)
}

/// A turn worth looking at: a prompt, a couple of tools, some prose with code,
/// and an end. Written as the events the host emits, not as page state, so the
/// reducer is exercised rather than bypassed.
/// Typing is driven through the real composer rather than injected as state:
/// React controlled inputs need the native setter plus an `input` event, and
/// doing it this way proves the composer, the Enter binding and the bridge post
/// all work — not just that the transcript renders.
let openThread = """
window.__ledgeDeliver({ event: "thread", app: "stocks", turn: 0 });
"""

let typeAndSend = """
(() => {
  const box = document.querySelector("textarea");
  const setValue = Object.getOwnPropertyDescriptor(
    window.HTMLTextAreaElement.prototype, "value").set;
  setValue.call(box, "make the price green when it rises");
  box.dispatchEvent(new Event("input", { bubbles: true }));
  box.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
})();
"""

let script = """
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "reasoning",
  delta: "Looking at app.jsx to find where the price is rendered, then " });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "reasoning",
  delta: "deciding whether the colour belongs on the text node or the row." });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "tool", name: "run", state: "started",
  detail: "/bin/zsh -lc \\"sed -n '1,120p' app.jsx\\"" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "tool", name: "run", state: "completed",
  detail: "/bin/zsh -lc \\"sed -n '1,120p' app.jsx\\"" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "The **price** row now tracks the delta:\\n\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "```\\n<text content={price} color={up ? \\"green\\" : \\"red\\"} />\\n```\\n\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "tool", name: "edit", state: "started",
  detail: "/Users/you/.ledge/apps/stocks/app.jsx" });
"""

final class Snapshotter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private var didSnapshot = false

    override init() {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        // The panel's own width, so line breaks and truncation are the real ones.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 440, height: 420),
                            configuration: configuration)
        super.init()
        // The page posts {type:"ready"} / {type:"input"} here exactly as it does
        // to the shell; without the handler those calls throw and the bundle
        // stops at the first one.
        controller.add(self, name: "ledge")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        print("[page → swift] \(message.body)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A beat for React to mount; the page's own replay buffer covers the gap
        // but the snapshot should show a settled surface.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            webView.evaluateJavaScript(openThread) { _, _ in }
            webView.evaluateJavaScript(typeAndSend) { _, error in
                if let error { print("[snapshot] compose failed: \(error)") }
                webView.evaluateJavaScript(script) { _, error in
                    if let error { print("[snapshot] inject failed: \(error)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.snapshot() }
                }
            }
        }
    }

    private func snapshot() {
        guard !didSnapshot else { return }
        didSnapshot = true
        webView.takeSnapshot(with: nil) { image, error in
            guard let image else {
                print("[snapshot] failed: \(String(describing: error))")
                exit(1)
            }
            let size = image.size
            let composited = NSImage(size: size)
            composited.lockFocus()
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(origin: .zero, size: size))
            composited.unlockFocus()

            guard
                let tiff = composited.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            else {
                print("[snapshot] could not encode PNG")
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: outputPath))
            print("[snapshot] wrote \(outputPath)")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let snapshotter = Snapshotter()
snapshotter.webView.loadFileURL(indexURL, allowingReadAccessTo: editorDir)

// A ceiling, so a page that never finishes loading fails the script rather than
// hanging a build.
DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    print("[snapshot] timed out")
    exit(1)
}
app.run()
