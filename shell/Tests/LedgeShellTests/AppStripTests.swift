import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The app strip's overflow behavior (spec §8). The row is
/// `[scrolling icons][+][safe gap][Settings]`, and the two properties worth
/// pinning down pull in opposite directions: an uncrowded strip must look
/// **exactly** as it did before the scroller existed, and a crowded one must
/// still put **[+]** and Settings within reach — they are how you add app eleven
/// and how you turn app ten off, which are precisely the things you want when a
/// strip has overflowed.
@MainActor
@Suite("App strip overflow (spec §8)")
struct AppStripTests {
    private func app(_ index: Int) -> CatalogApp {
        CatalogApp(
            id: "app\(index)",
            name: "App \(index)",
            icon: "sf:circle",
            order: index,
            enabled: true,
            running: true
        )
    }

    private func makeBar(_ count: Int, width: CGFloat = PanelLimits.defaultWidth) -> AppBarView {
        let bar = AppBarView(callbacks: .inert)
        bar.setApps((0..<count).map(app))
        bar.frame = CGRect(x: 0, y: 0, width: width, height: 42)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    @Test("A strip that fits keeps its icons left and its fixed controls right")
    func uncrowdedLayout() throws {
        let bar = makeBar(4)
        #expect(!bar.isIconAreaScrolling)
        #expect(!bar.showsLeftScrollHint)
        #expect(!bar.showsRightScrollHint)

        // App icons keep their 10 pt lead and 40 pt pitch.
        for index in 0..<4 {
            let frame = try #require(bar.frameForApp("app\(index)"))
            #expect(frame.minX == 10 + CGFloat(index) * 40)
            #expect(frame.width == 40)
        }
        let plus = try #require(bar.newAppButtonFrame)
        let settings = try #require(bar.settingsButtonFrame)
        #expect(plus.maxX < settings.minX)
        #expect(settings.minX - plus.maxX == 10)
    }

    @Test("A crowded strip scrolls its icons and keeps [+] and Settings put")
    func crowdedScrolls() throws {
        let bar = makeBar(20)
        #expect(bar.isIconAreaScrolling)
        #expect(!bar.showsLeftScrollHint)
        #expect(bar.showsRightScrollHint)

        let plus = try #require(bar.newAppButtonFrame)
        let settings = try #require(bar.settingsButtonFrame)
        #expect(plus.maxX <= settings.minX)
        #expect(settings.maxX <= bar.bounds.width)
        // Both are still inside the strip — which is the only thing "always
        // visible" can mean for a control the user has to be able to hit.
        #expect(bar.bounds.contains(plus))
        #expect(bar.bounds.contains(settings))
    }

    @Test("The safe gap between [+] and Settings holds at every crowding")
    func safeGapHolds() throws {
        for count in [0, 1, 5, 8, 9, 12, 40] {
            let bar = makeBar(count)
            let plus = try #require(bar.newAppButtonFrame)
            let settings = try #require(bar.settingsButtonFrame)
            let gap = settings.minX - plus.maxX
            #expect(
                gap >= LedgeMetrics.stripSafeGap,
                "gap collapsed to \(gap) with \(count) apps"
            )
        }
    }

    @Test("Settings stays pinned right whatever the panel width")
    func settingsPinnedRight() throws {
        for width in [PanelLimits.minWidth, 440, 640] as [CGFloat] {
            let bar = makeBar(20, width: width)
            let settings = try #require(bar.settingsButtonFrame)
            #expect(settings.minX == width - LedgeMetrics.stripSettingsInset)
        }
    }

    @Test("Scrolling re-verifies hover against the live pointer (law L5)")
    func scrollResyncsHover() {
        // Tracking areas inside a scroll view go stale when the content slides
        // under a stationary cursor — the same staleness a panel morph causes,
        // one container deeper. The assertion available headlessly is that the
        // strip *asks*: with no window there is no pointer, so every icon must
        // settle un-hovered rather than keeping whatever it last believed.
        let bar = makeBar(20)
        bar.scrollIcons(to: CGPoint(x: 120, y: 0).x)
        bar.layoutSubtreeIfNeeded()
        for button in allButtons(in: bar) {
            #expect(!button.isHovering)
        }
    }

    @Test("A scrolled icon really moves, and the scroll area never crowds [+]")
    func scrollMovesIcons() throws {
        let bar = makeBar(20)
        let before = try #require(bar.frameForApp("app0"))
        bar.scrollIcons(to: 120)
        bar.layoutSubtreeIfNeeded()
        let after = try #require(bar.frameForApp("app0"))
        #expect(after.minX < before.minX)
        #expect(bar.showsLeftScrollHint)
        #expect(bar.showsRightScrollHint)

        // Scrolling moves the icons and nothing else: [+] is a sibling of the
        // scroll view, so it sits at the area's edge whatever the icons do.
        let plus = try #require(bar.newAppButtonFrame)
        #expect(bar.iconAreaFrame.maxX <= plus.minX + 0.01)
    }
}
