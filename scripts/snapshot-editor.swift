// Render the built editor bundle in a real WKWebView and write a PNG.
//
//   swift scripts/snapshot-editor.swift [out.png] [--new] [--empty] [--rich]
//
// `--rich` renders the markdown a real turn emits — a heading, a table, a list,
// a link — which is the only way to see whether any of it is readable.
//
// `--new` renders the [+] surface instead: the editor with no app behind it,
// the prompt that creates one, and the host's `created` answer arriving mid-turn
// (spec §4.3, §8).
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
let creating = arguments.contains("--new")
/// Just the resting surface: no prompt, no turn. The empty state is the first
/// thing anyone sees, and it is the one screen no scripted turn ever shows.
let restingOnly = arguments.contains("--empty")
let rich = arguments.contains("--rich")
/// Keep the page's own transparency instead of flattening it onto black — for
/// when the PNG is going to be laid over the native chat snapshot rather than
/// looked at on its own.
let keepAlpha = arguments.contains("--transparent")
/// The pill mid-compose: a multi-line draft, typed and NOT sent. Its second
/// state (20 pt corners, the send bead) is otherwise unreachable in a snapshot.
let composing = arguments.contains("--draft")
/// The pill's third state: ⌄ pressed, the transcript cleared to watch the stage.
let collapsedPane = arguments.contains("--collapsed")
/// Chat mode over a stage: how many points of the pane the session's live tree
/// occupies at the top. The transcript leaves that much room and the newest
/// bubble floats back over its bottom edge — which is only reviewable at the
/// real number. Zero (the default) is the blank slot: a full-pane conversation.
let stageInset = Double(value(of: "--stage") ?? "") ?? 0
/// The pane's real size in points, `WxH`. Defaults to the shell's own default
/// panel minus the cutout row.
let paneSize: CGSize = {
    let parts = (value(of: "--size") ?? "").split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2 else { return CGSize(width: 440, height: 420) }
    return CGSize(width: parts[0], height: parts[1])
}()
/// The "you have no agent installed" state — the first thing a new user sees.
let noAgent = arguments.contains("--no-agent")
/// `--flag value`, or nil.
func value(of flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let flagValues = Set(["--stage", "--size"].compactMap { value(of: $0) })
let outputPath = arguments.dropFirst().first(where: { !$0.hasPrefix("--") && !flagValues.contains($0) })
    ?? (creating ? "/tmp/ledge-editor-new.png" : "/tmp/ledge-editor.png")

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
let openThread = creating ? """
window.__ledgeDeliver({ event: "thread", app: "", turn: 0 });
""" : """
window.__ledgeDeliver({ event: "thread", app: "stocks", turn: 0 });
"""

let prompt = creating ? "a pomodoro timer that dings" : "make the price green when it rises"

let typeAndSend = """
(() => {
  const box = document.querySelector("textarea");
  const setValue = Object.getOwnPropertyDescriptor(
    window.HTMLTextAreaElement.prototype, "value").set;
  setValue.call(box, "\(prompt)");
  box.dispatchEvent(new Event("input", { bubbles: true }));
  box.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
})();
"""

let createScript = """
window.__ledgeDeliver({ app: "pomodoro-timer", turn: 0, event: "created" });
window.__ledgeDeliver({ app: "pomodoro-timer", turn: 1, event: "reasoning",
  delta: "The folder already has an app.jsx that renders, so the work is to " });
window.__ledgeDeliver({ app: "pomodoro-timer", turn: 1, event: "reasoning",
  delta: "replace its body with a timer and a start button." });
window.__ledgeDeliver({ app: "pomodoro-timer", turn: 1, event: "tool", name: "edit",
  state: "started", detail: "/Users/you/.ledge/apps/pomodoro-timer/app.jsx" });
window.__ledgeDeliver({ app: "pomodoro-timer", turn: 1, event: "text",
  delta: "**Pomodoro Timer** is in your strip — 25 minutes, then a chime.\\n\\n" });
window.__ledgeDeliver({ app: "pomodoro-timer", turn: 1, event: "text",
  delta: "Press Preview to watch it run." });
window.__ledgeDeliver({ app: "pomodoro-timer", turn: 1, event: "done", status: "completed" });
"""

let editScript = """
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

// Verbatim shapes from the music app's artwork turn, which is where the table
// problem was found.
let richScript = """
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "Done — the collapsed right wing now shows 30pt album art.\\n\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "## Album artwork\\n\\n| Before | After |\\n| --- | --- |\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "| Collapsed wing showed text only | Reuses the mini-player canvas |\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "| Artwork edge was unframed | Added a subtle white outline |\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "| Missing artwork | Falls back to text-only |\\n\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "Checks made:\\n- `app.jsx` compiled and hot-reloaded\\n- the live host confirmed the wing\\n\\n" });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "text",
  delta: "[app.jsx](/Users/admin/.ledge/apps/music/app.jsx:430) is the only file touched." });
window.__ledgeDeliver({ app: "stocks", turn: 1, event: "done", status: "completed" });
"""

let script = rich ? richScript : (creating ? createScript : editScript)

final class Snapshotter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private var didSnapshot = false

    override init() {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        // The pane's own size, so line breaks, truncation and the room left for
        // the stage are the real ones.
        webView = WKWebView(frame: CGRect(origin: .zero, size: paneSize),
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
            // What Swift tells the page about the stage behind it
            // (`EditorBridge.setStage`).
            webView.evaluateJavaScript("""
            window.__ledgeDeliver({ event: "stage", present: \(stageInset > 0),
              inset: \(stageInset) });
            """) { _, _ in }
            if noAgent {
                webView.evaluateJavaScript("""
                window.__ledgeDeliver({ event: "agent", app: "", turn: 0,
                  installed: false, name: "Codex", install: "npm i -g @openai/codex" });
                """) { _, _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.snapshot() }
                return
            }
            if composing || collapsedPane {
                let type = """
                (() => {
                  const box = document.querySelector("textarea");
                  const set = Object.getOwnPropertyDescriptor(
                    window.HTMLTextAreaElement.prototype, "value").set;
                  set.call(box, "a stand-up alarm, 9:25 weekdays —\\nring the wings, no sound");
                  box.dispatchEvent(new Event("input", { bubbles: true }));
                })();
                """
                let collapse = """
                document.querySelector(".pill .toggle").click();
                """
                // A beat first: the ⌄ only exists once React has re-rendered
                // with the stage the line above just announced.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    webView.evaluateJavaScript(composing ? type : collapse) { _, error in
                        if let error { print("[snapshot] pill state failed: \(error)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.snapshot() }
                    }
                }
                return
            }
            guard !restingOnly else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.snapshot() }
                return
            }
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
            if !keepAlpha {
                NSColor.black.setFill()
                NSRect(origin: .zero, size: size).fill()
            }
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
