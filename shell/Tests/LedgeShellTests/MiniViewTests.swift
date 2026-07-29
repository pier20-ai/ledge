import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The mini view** — the third presentation rung, between the collapsed wing
/// and the full panel (spec §3.3 extension: `<mini>` + `ctx.peek`).
///
/// The property this suite protects is that a peek is an *interruption you can
/// ignore*, never a background app taking the screen: it only escalates from
/// collapsed, it puts itself away, it does not rewrite which app you were using,
/// and reaching for it opens that app rather than whatever you had before.
@MainActor
@Suite("Mini view (spec §3.3 extension)")
struct MiniViewTests {

    // MARK: - Placement

    @Test("A mini is a shell zone: mounted, but never inside the app's content")
    func miniIsNotInTheContentStack() throws {
        let renderer = ProtocolRenderer()
        let mutations = try Fixtures.envelope("commit-mini.json")
            .decodePayload(CommitPayload.self).mutations
        renderer.applyCommit(app: "music", mutations: mutations)

        let mini = try #require(renderer.miniView(for: "music"))
        let root = try #require(renderer.rootView(for: "music"))

        // The whole point: the panel must not grow a copy of the mini. An app
        // that peeks "Neon Rain — Hana Vale" is not asking for that line to
        // appear inside its panel as well.
        #expect(!descendants(of: root).contains(mini))
        // …and the mini's own children came with it.
        #expect(!descendants(of: mini).isEmpty)
    }

    @Test("A mini nested inside the layout is rejected, like a nested wing")
    func nestedMiniRejected() throws {
        let tree = ShadowTree()
        let mutations = try Fixtures.envelope("invalid-commit-nested-mini.json")
            .decodePayload(CommitPayload.self).mutations
        guard case .failure(let failure) = tree.apply(mutations) else {
            Issue.record("a nested mini must not validate")
            return
        }
        #expect(failure == .misplacedZone(id: 3, kind: .mini))
        #expect(tree.isEmpty)
    }

    @Test("An app with no mini offers nothing to peek at")
    func noMiniNoView() throws {
        let renderer = ProtocolRenderer()
        let mutations = try Fixtures.envelope("commit-mount.json")
            .decodePayload(CommitPayload.self).mutations
        renderer.applyCommit(app: "stocks", mutations: mutations)
        #expect(renderer.miniView(for: "stocks") == nil)
    }

    // (The `peek` envelope itself is covered in ProtocolEngineTests, where the
    // recording delegate lives.)

    // MARK: - Presentation state

    @Test("A mini is not an expansion")
    func miniIsNotExpanded() {
        let mini = ShellPresentation.mini(app: "music")
        // Load-bearing: the hover machinery treats `isExpanded` as "already
        // open". If a peek claimed to be an expansion, hovering it would try to
        // close the panel instead of opening the app.
        #expect(!mini.isExpanded)
        #expect(mini.isMini)
        #expect(mini.app == "music")
    }

    /// Reporting a presented app is what produces `selection` + the
    /// `expanded`/`collapsed` lifecycle (§4.2/§4.3). Apps key real work off
    /// `onLifecycle("expanded")` — aviary raises its frame rate, tetris unpauses
    /// — so a peek that reported itself would start every app that flashes a
    /// track change and then immediately collapse it again, for a panel that
    /// never opened.
    @Test("A peek reports no presented app, so no worker is told its panel opened")
    func miniReportsNothingToTheHost() {
        #expect(ShellPresentation.mini(app: "music").app == "music")
        #expect(ShellPresentation.mini(app: "music").reportedApp == nil)

        // Every other surface reports exactly what it shows.
        #expect(ShellPresentation.expanded(app: "chess").reportedApp == "chess")
        #expect(ShellPresentation.chat(app: "chess").reportedApp == "chess")
        #expect(ShellPresentation.collapsed.reportedApp == nil)
        #expect(ShellPresentation.newApp.reportedApp == nil)

        // Promoting a peek IS an expansion, and must report.
        var state = ShellState()
        state.present(.mini(app: "music"))
        #expect(state.presentation.reportedApp == nil)
        state.promoteMini()
        #expect(state.presentation.reportedApp == "music")
    }

    @Test("A peek does not rewrite the app you were last using")
    func peekDoesNotStealTheHoverMemory() {
        var state = ShellState()
        state.present(.expanded(app: "chess"))
        state.present(.collapsed)

        // Music interrupts with a track change while you were in Chess.
        state.present(.mini(app: "music"))
        #expect(state.lastPresentedApp == "chess")

        // Ignoring it and hovering the pill must still return you to Chess —
        // otherwise a notification you never touched has quietly changed what
        // the notch opens.
        state.dismissMini(app: "music")
        state.toggleExpansion()
        #expect(state.presentation == .expanded(app: "chess"))
    }

    @Test("Reaching for a mini opens that app, and remembers it")
    func promotingAMiniIsAChoice() {
        var state = ShellState()
        state.present(.expanded(app: "chess"))
        state.present(.collapsed)
        state.present(.mini(app: "music"))

        state.promoteMini()

        #expect(state.presentation == .expanded(app: "music"))
        // Now it WAS a visit, so it becomes the remembered app.
        #expect(state.lastPresentedApp == "music")
    }

    @Test("A late dwell timer cannot close what it no longer owns")
    func staleDismissIsIgnored() {
        var state = ShellState()

        // The user promoted the mini before its timer fired.
        state.present(.mini(app: "music"))
        state.promoteMini()
        state.dismissMini(app: "music")
        #expect(state.presentation == .expanded(app: "music"))

        // Another app took the surface before the first one's timer fired.
        state.present(.collapsed)
        state.present(.mini(app: "music"))
        state.present(.mini(app: "alarm"))
        state.dismissMini(app: "music")
        #expect(state.presentation == .mini(app: "alarm"))

        // Its own timer still works.
        state.dismissMini(app: "alarm")
        #expect(state.presentation == .collapsed)
    }

    @Test("promoteMini is a no-op when no mini is up")
    func promoteWithoutMini() {
        var state = ShellState()
        state.present(.expanded(app: "chess"))
        state.promoteMini()
        #expect(state.presentation == .expanded(app: "chess"))
    }

    // MARK: - Surface sizing

    /// A real mini node, built the way the renderer builds one.
    private func renderedMini() throws -> NSView {
        let renderer = ProtocolRenderer()
        let mutations = try Fixtures.envelope("commit-mini.json")
            .decodePayload(CommitPayload.self).mutations
        renderer.applyCommit(app: "music", mutations: mutations)
        return try #require(renderer.miniView(for: "music"))
    }

    /// The regression this suite most needs.
    ///
    /// The first implementation reused `LedgeWingView`, whose stack is pinned
    /// `leading` + `centerY` with `trailing ≤` because the wing bar frames it by
    /// hand. Nothing there drives a width or a height, so `fittingSize` came back
    /// ~zero, the surface fell to its minimum floor, and the content was laid out
    /// at zero size: a correctly-shaped, completely empty black box on screen.
    /// Every other test still passed, because they all asked about *placement*.
    @Test("A mini node reports a real size — an empty box is the failure mode")
    func miniMeasuresItsContent() throws {
        let mini = try renderedMini()
        mini.layoutSubtreeIfNeeded()
        let fitting = mini.fittingSize

        // "Neon Rain" + "Hana Vale" in a horizontal stack is unambiguously wider
        // than this and taller than a hairline. Zero here is the bug.
        #expect(fitting.width > 60)
        #expect(fitting.height > 10)
    }

    @Test("The peek surface is derived from its content, not from a floor")
    func miniSurfaceSizesToContent() throws {
        let surface = MiniContentView()
        surface.adopt(try renderedMini())
        surface.layoutSubtreeIfNeeded()
        let fitting = surface.fittingSizeOfContent

        // Derivation, not a magic number: the surface is the content plus its
        // padding, once that clears the floor. Asserting `> minWidth` instead
        // would pass for content of any size, including none.
        let size = surface.preferredSize(cutoutWidth: 0, maxWidth: 640)
        #expect(size.width == max(fitting.width + MiniContentView.padX * 2, MiniContentView.minWidth))
        #expect(size.height <= MiniContentView.maxHeight)
    }

    /// The bug caught on a real notch: the surface came out NARROWER than
    /// the cutout (a 180 pt floor under a 189 pt notch), so a peek looked like
    /// the notch pinching in sideways while growing downwards. A peek is the
    /// notch expanding a little — never smaller than it, in either axis.
    @Test("A peek is never narrower than the notch it hangs from")
    func miniIsNeverNarrowerThanTheCutout() throws {
        let surface = MiniContentView()
        surface.adopt(try renderedMini())
        surface.layoutSubtreeIfNeeded()

        for cutout in [CGFloat(189), 210, 160] {
            let size = surface.preferredSize(cutoutWidth: cutout, maxWidth: 640)
            #expect(size.width >= cutout + MiniContentView.notchOvershoot * 2)
        }

        // Even with nothing to show — the geometry must not depend on the
        // controller refusing empty peeks to be correct.
        let empty = MiniContentView()
        #expect(empty.preferredSize(cutoutWidth: 189, maxWidth: 640).width >= 189)
    }

    @Test("The peek surface clamps to a glance")
    func miniSurfaceClamps() {
        let surface = MiniContentView()

        // No cutout measurement (snapshots, headless): the absolute floor.
        let empty = surface.preferredSize(cutoutWidth: 0, maxWidth: 640)
        #expect(empty.width == MiniContentView.minWidth)
        #expect(empty.height == MiniContentView.minHeight)

        // A mini that tries to be a panel gets cut down to the surface's bounds.
        let huge = NSView(frame: CGRect(x: 0, y: 0, width: 5000, height: 5000))
        huge.setFrameSize(NSSize(width: 5000, height: 5000))
        surface.adopt(huge)
        let clamped = surface.preferredSize(cutoutWidth: 189, maxWidth: 640)
        #expect(clamped.width <= 640)
        #expect(clamped.height <= MiniContentView.maxHeight)
    }
}
