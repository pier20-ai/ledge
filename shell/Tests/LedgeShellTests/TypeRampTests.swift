import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The type ramp, after F1 moved it out of `ProtocolRenderer.font` into
/// `LedgeMetrics` and grew it by two sizes, a weight and `caps` (spec §5).
///
/// Fixture-first, like every other protocol addition: the assertions below drive
/// the real engine → renderer path from `commit-type-ramp.json`, the same file
/// the bun suite replays. The old sizes are pinned here too — "existing fixtures
/// still pass" is a weaker claim than "10 · 11.5 · 12.5 · 15 · 30 are still
/// exactly those numbers".
@MainActor
@Suite("Type ramp — display, hero, light, caps (spec §5)")
struct TypeRampTests {
    private func mount() throws -> (ProtocolEngine, ProtocolRenderer) {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        engine.receive(try Fixtures.envelope("commit-type-ramp.json"))
        return (engine, renderer)
    }

    private func text(_ renderer: ProtocolRenderer, _ id: Int) throws -> LedgeText {
        try #require(renderer.view(app: "type", id: id) as? LedgeText)
    }

    // MARK: - The ramp itself

    @Test("The five original sizes are unchanged, to the half point")
    func originalSizesHold() {
        #expect(LedgeMetrics.TypeSize.xs.pointSize == 10)
        #expect(LedgeMetrics.TypeSize.s.pointSize == 11.5)
        #expect(LedgeMetrics.TypeSize.m.pointSize == 12.5)
        #expect(LedgeMetrics.TypeSize.l.pointSize == 15)
        #expect(LedgeMetrics.TypeSize.xl.pointSize == 30)
        // The default is `m`, and an unknown token resolves to it rather than to
        // nothing — that is how a `hero` from a newer app degrades on this shell.
        #expect(LedgeMetrics.TypeSize(token: nil) == .m)
        #expect(LedgeMetrics.TypeSize(token: "colossal") == .m)
        #expect(LedgeMetrics.TypeWeight(token: "featherweight") == .regular)
    }

    @Test("display and hero sit above xl, and the ramp never doubles back")
    func newSizesExtendTheRamp() {
        #expect(LedgeMetrics.TypeSize.display.pointSize == 36)
        #expect(LedgeMetrics.TypeSize.hero.pointSize == 48)
        let ramp = LedgeMetrics.TypeSize.allCases.map(\.pointSize)
        #expect(ramp == ramp.sorted())
        #expect(LedgeMetrics.TypeWeight.light.fontWeight == .light)
    }

    @Test("The renderer resolves the ramp rather than owning it")
    func rendererReadsTheRamp() {
        // The whole point of the move: `font` is a token resolver now, so the
        // shell's own chrome and an app's `text` node cannot disagree.
        #expect(ProtocolRenderer.font(size: "hero", weight: "light", mono: false).pointSize == 48)
        #expect(ProtocolRenderer.font(size: "display", weight: nil, mono: false).pointSize == 36)
        #expect(ProtocolRenderer.font(size: "xl", weight: "bold", mono: false).pointSize == 30)
        #expect(ProtocolRenderer.font(size: nil, weight: nil, mono: false).pointSize == 12.5)
    }

    // MARK: - The fixture, through the real path

    @Test("The mount fixture renders every addition")
    func fixtureMounts() throws {
        let (_, renderer) = try mount()

        let hero = try text(renderer, 2)
        #expect(hero.font?.pointSize == 48)
        #expect(hero.stringValue == "72°")

        let display = try text(renderer, 3)
        #expect(display.font?.pointSize == 36)

        // The unchanged headline price, from the spec's own §3.1 example.
        let price = try text(renderer, 5)
        #expect(price.font?.pointSize == 30)
        #expect(price.stringValue == "$214.62")
    }

    @Test("`caps` uppercases the glyphs and tracks them out by 6%")
    func capsUppercasesAndTracks() throws {
        let (_, renderer) = try mount()
        let eyebrow = try text(renderer, 4)

        #expect(eyebrow.caps)
        #expect(eyebrow.stringValue == "FEELS LIKE")
        // The raw string survives the shouting: it is what accessibility reads
        // and what a later `caps: false` restores.
        #expect(eyebrow.rawContent == "Feels like")
        #expect(eyebrow.accessibilityLabel() == "Feels like")

        // Tracking is not a font trait, so it has to arrive as an attribute.
        let kern = eyebrow.attributedStringValue.attribute(
            .kern,
            at: 0,
            effectiveRange: nil
        ) as? CGFloat
        #expect(kern == LedgeMetrics.TypeSize.xs.pointSize * LedgeMetrics.capsTracking)

        // A node that never asked for caps is left entirely alone.
        let plain = try text(renderer, 6)
        #expect(!plain.caps)
        #expect(plain.stringValue == "steady")
    }

    @Test("The update fixture drops caps, adds caps, and moves a size — in place")
    func fixtureUpdates() throws {
        let (engine, renderer) = try mount()
        let eyebrow = try text(renderer, 4)
        let plain = try text(renderer, 6)
        let display = try text(renderer, 3)

        engine.receive(try Fixtures.envelope("commit-type-ramp-update.json"))

        // Same views — an update must not remount.
        #expect(try text(renderer, 4) === eyebrow)

        // `caps: null` really does restore the app's own casing, rather than
        // leaving a shouted label behind because "unchanged" swallowed it.
        #expect(!eyebrow.caps)
        #expect(eyebrow.stringValue == "Feels like")

        #expect(plain.caps)
        #expect(plain.stringValue == "STEADY")
        #expect(plain.rawContent == "Steady")

        #expect(display.font?.pointSize == 48)
    }
}
