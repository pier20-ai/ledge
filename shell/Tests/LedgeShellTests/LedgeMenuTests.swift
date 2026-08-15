import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The right-click menu** (flow.md, Edges: "Triggers: right-click any Ledge
/// glass → native menu (Settings…, Quit Ledge); ⌘, during a visit").
///
/// This is not a convenience. Killing the bottom app bar orphaned the only two
/// ways out of the product — the pinned Settings icon and the Quit row inside
/// the Settings app — so this menu is now the *only* route to either, and the
/// state it has to work from above all is the **collapsed pill**: that is what
/// is on screen when nothing else is.
@MainActor
@Suite("The Ledge menu — Settings… and Quit (flow.md, Edges)")
struct LedgeMenuTests {
    private func makeSurface(menu: NSMenu) -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        surface.contextMenu = { menu }
        return surface
    }

    private func twoItemMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ledge", action: nil, keyEquivalent: ""))
        return menu
    }

    /// The state the menu matters most in. A right-click on 210 pt of black
    /// glass is the whole discoverability budget for Settings now.
    @Test("It works from the collapsed pill")
    func collapsedPill() {
        let menu = twoItemMenu()
        let surface = makeSurface(menu: menu)
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()

        let shape = surface.currentShapeRect
        #expect(surface.contextMenu(at: CGPoint(x: shape.midX, y: shape.midY)) === menu)
        // Off the glass, nothing: the transparent window passes the click
        // through to whatever is beneath, and so does the menu.
        #expect(surface.contextMenu(at: CGPoint(x: shape.maxX + 20, y: shape.midY)) == nil)
    }

    /// "…not inside app content." An app's content well is the app's, and a
    /// shell menu over it would be the shell speaking with the app's voice. The
    /// exclusion is the content host's own rect, so it needs no cooperation from
    /// any app.
    @Test("In a visit it covers the chrome and stops at the app's content well")
    func visitChromeOnly() {
        let menu = twoItemMenu()
        let surface = makeSurface(menu: menu)
        surface.setContentOwner(.app)
        surface.present(
            .expanded(app: "stocks"),
            content: FlippedView(),
            width: 440,
            height: 300,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()

        let shape = surface.currentShapeRect
        // The cutout exclusion row is chrome — it holds Ledge's two controls.
        let chrome = CGPoint(x: shape.midX, y: surface.panelWingRowHeight / 2)
        #expect(surface.contextMenu(at: chrome) === menu)

        // Below it is the app's well.
        let well = CGPoint(x: shape.midX, y: surface.panelWingRowHeight + 40)
        #expect(surface.contextMenu(at: well) == nil)
    }

    /// **The defect Manu hit.** The exclusion used to be the content host's rect
    /// unconditionally — every pixel of a visit below a 32 pt row — so the menu
    /// was suppressed over surfaces the *shell* draws: the "no host" placeholder
    /// and the permission card. Since hovering the notch opens the visit inside
    /// Th, that is the state a right-click almost always lands in, and the only
    /// route to Settings and to Quit answered with nothing.
    ///
    /// Measured on device before the fix: a right-click on the cutout row logged
    /// `menu(for:) -> menu`; forty points lower, on the placeholder card,
    /// `menu(for:) -> nil`.
    @Test("A well the shell drew itself is Ledge glass, all the way down")
    func shellDrawnWellAnswers() {
        let menu = twoItemMenu()
        let surface = makeSurface(menu: menu)
        surface.setContentOwner(.shell)                  // the placeholder, the permission card
        surface.present(
            .expanded(app: nil),
            content: FlippedView(),
            width: 440,
            height: 300,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()

        let shape = surface.currentShapeRect
        #expect(surface.contextMenu(at: CGPoint(x: shape.midX, y: 10)) === menu)
        #expect(surface.contextMenu(
            at: CGPoint(x: shape.midX, y: surface.panelWingRowHeight + 40)
        ) === menu)
        // Still nothing off the glass.
        #expect(surface.contextMenu(at: CGPoint(x: shape.maxX + 20, y: 100)) == nil)
    }

    /// The controller is what decides who owns the well, and it has to get the
    /// two surfaces that matter right: the placeholder (no host) and the
    /// permission card are the shell's, an app's tree is not.
    @Test("The controller hands the well to an app, and keeps its own cards")
    func ownershipFollowsWhoDrewIt() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        session.inject(try Fixtures.envelope("commit-mount.json"))

        controller.present(.permissions, animated: false)
        #expect(controller.surfaceForTesting.contentOwner == .shell)

        // No host behind this one: the placeholder is a card the shell drew.
        controller.present(.expanded(app: "ghost"), animated: false)
        #expect(controller.surfaceForTesting.contentOwner == .shell)

        // A real tree owns its own well.
        controller.present(.expanded(app: "stocks"), animated: false)
        #expect(controller.surfaceForTesting.contentOwner == .app)

        // So does the editor — a composer must keep Cut/Copy/Paste.
        controller.present(.newApp, animated: false)
        #expect(controller.surfaceForTesting.contentOwner == .app)
    }

    /// The whole delivery path, not just the decision: a right-click on the
    /// pill has to reach `menu(for:)` through whatever view happens to be under
    /// the cursor, in a borderless non-activating panel belonging to an
    /// accessory app that is not frontmost. Displaying the menu is AppKit's and
    /// cannot be asserted headlessly; being *asked* for it can.
    @Test("A real right-click on the panel reaches the surface and gets the menu")
    func rightClickRoutesThroughThePanel() {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        controller.present(.collapsed, animated: false)
        let panel = controller.panelForTesting
        // A window AppKit has never shown has no number to address an event to.
        panel.orderFrontRegardless()
        let surface = controller.surfaceForTesting
        surface.layoutSubtreeIfNeeded()

        var asked = 0
        surface.contextMenu = { asked += 1; return nil }     // nil: nothing pops up mid-test

        let shape = surface.currentShapeRect
        let point = surface.convert(CGPoint(x: shape.midX, y: shape.midY), to: nil)
        guard let click = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            Issue.record("could not synthesize a right-click")
            return
        }
        panel.sendEvent(click)
        #expect(asked == 1)
    }

    /// A swell is Ledge glass too. The payload is one borrowed row; the surface
    /// around it is the notch.
    @Test("It works on a swell")
    func onASwell() {
        let menu = twoItemMenu()
        let surface = makeSurface(menu: menu)
        surface.present(
            .summary(app: "chess"),
            content: FlippedView(),
            width: 300,
            height: 90,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        let shape = surface.currentShapeRect
        #expect(surface.contextMenu(at: CGPoint(x: shape.midX, y: shape.midY)) === menu)
    }

    /// Exactly two items, and a ⌘, on the first. flow.md names both and nothing
    /// else; a third item here is a menu that has started to become a bar.
    @Test("The controller's own menu is exactly Settings… and Quit Ledge")
    func theRealMenu() {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        controller.present(.collapsed, animated: false)
        let menu = controller.contextMenuForTesting
        let items = menu.items.filter { !$0.isSeparatorItem }

        #expect(items.count == 2)
        #expect(items.first?.title == "Settings…")
        #expect(items.first?.keyEquivalent == ",")
        #expect(items.first?.keyEquivalentModifierMask == .command)
        #expect(items.last?.title == "Quit Ledge")
        // Both are wired: a menu item with no action is a menu item that looks
        // like it works.
        #expect(items.allSatisfy { $0.action != nil && $0.target != nil })
    }

    /// Settings opens as a visit for now. flow.md wants a **native macOS
    /// window** ("configuration doesn't belong on glass") and that is a later
    /// phase — the trigger is final, the destination is not.
    @Test("Settings… opens the settings session as a visit")
    func settingsOpensAVisit() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))
        controller.present(.collapsed, animated: false)

        controller.openSettingsForTesting()
        #expect(controller.presentation == .expanded(app: LedgeApps.settings))
        #expect(controller.interactionState == .visit)

        // Re-opening it keeps the settings controls on screen rather than
        // toggling into the editor — there is no app folder behind Settings for
        // an agent to edit.
        controller.openSettingsForTesting()
        #expect(controller.presentation == .expanded(app: LedgeApps.settings))
    }

    /// ⌘, is a *visit* shortcut (flow.md). It is also only reachable while the
    /// panel holds key — a non-activating panel cannot claim a key equivalent
    /// from the app the user is actually in — which is why the menu is the path
    /// that always works.
    @Test("⌘, answers during a visit and declines below it")
    func settingsShortcutScope() throws {
        let session = HostSession()
        let controller = NotchPanelController(session: session)
        session.openReplay()
        session.inject(try Fixtures.envelope("catalog.json"))

        controller.present(.collapsed, animated: false)
        #expect(controller.handleSettingsShortcut() == false)

        controller.present(.expanded(app: "stocks"), animated: false)
        #expect(controller.handleSettingsShortcut())
        #expect(controller.presentation == .expanded(app: LedgeApps.settings))
    }
}
