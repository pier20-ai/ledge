import AppKit
import Foundation
import Testing
import UserNotifications
@testable import LedgeShell
@testable import LedgeShellCore

/// The drop shelf (INTAKE): files dropped on the open panel become an app-level
/// `drop` event for whatever app is presented. `NSDraggingInfo` cannot be
/// constructed outside a real drag session, so the decision and the delivery are
/// factored onto plain paths — which is also the whole of the logic; the AppKit
/// overrides do nothing but read the pasteboard and call these.
@MainActor
@Suite("Drop shelf (INTAKE)")
struct DropShelfTests {
    private func makeSurface(app: String? = "flights") -> (ShellSurfaceView, Box) {
        let box = Box()
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        surface.canAcceptDrop = { app != nil }
        surface.onDropFiles = { paths in
            box.dropped.append(paths)
            return app != nil
        }
        return (surface, box)
    }

    final class Box {
        var dropped: [[String]] = []
    }

    @Test("An expanded panel with an app on screen takes the files")
    func expandedAccepts() {
        let (surface, box) = makeSurface()
        surface.present(.expanded(app: "flights"), content: NSView(), height: 300, animated: false)

        #expect(surface.acceptsDrop(of: ["/tmp/pass.pdf"]))
        #expect(surface.deliverDrop(of: ["/tmp/pass.pdf", "/tmp/receipt.png"]))
        #expect(box.dropped == [["/tmp/pass.pdf", "/tmp/receipt.png"]])
    }

    @Test("The collapsed pill is not a drop target")
    func collapsedRefuses() {
        let (surface, box) = makeSurface()
        surface.present(.collapsed, content: nil, height: 0, animated: false)

        #expect(surface.acceptsDrop(of: ["/tmp/pass.pdf"]) == false)
        #expect(surface.deliverDrop(of: ["/tmp/pass.pdf"]) == false)
        #expect(box.dropped.isEmpty)
    }

    @Test("With no app presented the drag is refused rather than swallowed")
    func noAddresseeRefuses() {
        let (surface, box) = makeSurface(app: nil)
        surface.present(.expanded(app: nil), content: NSView(), height: 300, animated: false)

        #expect(surface.acceptsDrop(of: ["/tmp/pass.pdf"]) == false)
        #expect(box.dropped.isEmpty)
    }

    @Test("A drag carrying no files is not a drop")
    func emptyDragRefused() {
        let (surface, _) = makeSurface()
        surface.present(.expanded(app: "flights"), content: NSView(), height: 300, animated: false)
        #expect(surface.acceptsDrop(of: []) == false)
    }

    @Test("The panel starts with no drop highlight showing")
    func highlightStartsHidden() {
        let (surface, _) = makeSurface()
        surface.present(.expanded(app: "flights"), content: NSView(), height: 300, animated: false)
        #expect(surface.isShowingDropHighlight == false)
    }
}

/// Notifications are `UNUserNotificationCenter` only (no fallback). Under
/// `swift test` there is no app bundle — `UNUserNotificationCenter.current()`
/// would trap — so the presenter must (a) never touch it and (b) turn a post
/// into a logged drop rather than a crash or a toast-by-other-means.
@MainActor
@Suite("Notification presenter (spec §6)")
struct NotificationPresenterTests {
    @Test("Unbundled (swift run / swift test): unavailable, no fallback")
    func unbundledIsUnavailable() {
        #expect(Bundle.main.bundleIdentifier == nil)
        #expect(NotificationPresenter.isAvailable == false)
    }

    @Test("Building and posting unbundled is a safe no-op — UNUserNotificationCenter is never touched")
    func unbundledPostIsSafeNoOp() {
        let presenter = NotificationPresenter()
        var delivered = false
        presenter.onAction = { _, _, _ in delivered = true }
        presenter.post(
            NotifyPayload(id: 1, text: "hello", title: nil, actions: nil),
            app: "alarm",
            appName: "Alarm"
        )
        #expect(delivered == false)
        withExtendedLifetime(presenter) {}
    }

    @Test("Response identifiers map to app-visible action names; body click = opened, dismissal = nothing")
    func actionNameMapping() {
        // The mapping is the contract apps build their `notification` event
        // handlers on: body click → "opened", dismissal → dropped, buttons as-is.
        #expect(NotificationPresenter.actionName(for: UNNotificationDefaultActionIdentifier)
            == NotificationPresenter.openedAction)
        #expect(NotificationPresenter.actionName(for: UNNotificationDismissActionIdentifier) == nil)
        #expect(NotificationPresenter.actionName(for: "execute") == "execute")
    }
}
