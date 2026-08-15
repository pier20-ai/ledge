import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The app tier of design.html §06's two-tier control law, on the wire (F2.3):
/// `variant="ghost"` and `image.stroke`.
///
/// Fixture-first like every other protocol addition — the assertions drive the
/// real engine → renderer path from `commit-app-controls.json` and its update,
/// the same two files the bun suite replays. What is being pinned is not "the
/// renderer has a ghost case" but "an app that writes `variant="ghost"` gets a
/// bare white glyph, and an app that writes `variant="bead"` does not get the
/// shell's chrome".
@MainActor
@Suite("App controls — ghost buttons and stroked images (spec §5)")
struct AppControlsTests {
    private func mount() throws -> (ProtocolEngine, ProtocolRenderer) {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        engine.receive(try Fixtures.envelope("commit-app-controls.json"))
        return (engine, renderer)
    }

    private func button(_ renderer: ProtocolRenderer, _ id: Int) throws -> LedgeButton {
        try #require(renderer.view(app: "gallery", id: id) as? LedgeButton)
    }

    private func image(_ renderer: ProtocolRenderer, _ id: Int) throws -> NSView {
        try #require(renderer.view(app: "gallery", id: id))
    }

    // MARK: - `variant="ghost"`

    @Test("An app's `variant=\"ghost\"` reaches the ghost tier, not plain")
    func ghostCrossesTheWire() throws {
        let (_, renderer) = try mount()
        for id in [5, 6] {
            let glyph = try button(renderer, id)
            #expect(glyph.currentVariant == .ghost, "node \(id) should be a ghost")
            // The whole point of the tier: nothing behind the glyph until the
            // cursor arrives. A chip here would be the §06 law broken.
            #expect(glyph.layer?.backgroundColor?.alpha == 0)
            #expect(glyph.layer?.borderWidth == 0)
        }
    }

    @Test("A ghost glyph is bigger than a chrome glyph (design.html §06)")
    func ghostGlyphsAreLarger() throws {
        let (engine, renderer) = try mount()

        // The app tier reads *larger*, not merely brighter: 14 pt is chrome's
        // size and it does not hold its own beside a 36 pt `display` numeral.
        for id in [5, 6] {
            let glyph = try button(renderer, id)
            #expect(glyph.isIconOnly)
            #expect(glyph.iconPointSize == LedgeMetrics.ghostIconPointSize)
            #expect(glyph.iconPointSize == 18)
        }
        #expect(LedgeMetrics.ghostIconPointSize > LedgeMetrics.iconOnlyPointSize)

        // …and the size follows the *variant*, not only the label: node 6 drops
        // to plain in the update, so its glyph has to be rebuilt at 14. This is
        // the case a "rebuild only when the label crosses empty" rule misses.
        engine.receive(try Fixtures.envelope("commit-app-controls-update.json"))
        let demoted = try button(renderer, 6)
        #expect(demoted.currentVariant == .plain)
        #expect(demoted.iconPointSize == LedgeMetrics.iconOnlyPointSize)
    }

    @Test("`bead` is still shell-only — an app naming it gets plain")
    func beadStaysShellOnly() throws {
        let (engine, renderer) = try mount()
        let pretender = try button(renderer, 7)
        #expect(pretender.currentVariant == .plain)
        #expect(pretender.beadFillColors == nil, "no bead layers from the wire")

        // Glass and accent are unchanged by the addition.
        #expect(try button(renderer, 8).currentVariant == .glass)

        // …and the same word is still refused on an update, not only at create.
        engine.receive(try Fixtures.envelope("commit-app-controls-update.json"))
        #expect(try button(renderer, 7).currentVariant == .ghost)  // bead → ghost, allowed
        #expect(try button(renderer, 7).beadFillColors == nil)
        #expect(try button(renderer, 6).currentVariant == .plain)  // ghost → plain, in place
        // Ghost survives an update that never mentions the variant (merged props).
        #expect(try button(renderer, 5).currentVariant == .ghost)
    }

    @Test("The wire's variant vocabulary is exactly four words")
    func variantVocabulary() {
        #expect(ProtocolRenderer.variant("plain") == .plain)
        #expect(ProtocolRenderer.variant("glass") == .glass)
        #expect(ProtocolRenderer.variant("accent") == .accent)
        #expect(ProtocolRenderer.variant("ghost") == .ghost)
        #expect(ProtocolRenderer.variant("bead") == .plain)
        #expect(ProtocolRenderer.variant("shimmer") == .plain)
        #expect(ProtocolRenderer.variant(nil) == .plain)
    }

    // MARK: - `image.stroke`

    @Test("`image.stroke` rings the picture itself, on a file and on a symbol")
    func imageStrokeIsAHairline() throws {
        let (_, renderer) = try mount()

        // A file image — the artwork well. The ring is on the image view, so it
        // survives the aspect-fill crop and the missing-file placeholder alike.
        let sleeve = try image(renderer, 2)
        #expect(sleeve is LedgeFileImageView)
        #expect(sleeve.layer?.borderWidth == LedgeMetrics.hairline)
        #expect(sleeve.layer?.borderColor == LedgeTheme.hairline.cgColor)

        // …and an SF Symbol takes the same prop, with the same token set.
        let glyph = try image(renderer, 3)
        #expect(glyph is LedgeSymbolView)
        #expect(glyph.layer?.borderColor == LedgeTheme.accentStroke.cgColor)

        // An image that never mentions `stroke` is unframed — the default has
        // to stay "no ring", or every existing app grows one.
        let bare = try image(renderer, 4)
        #expect((bare.layer?.borderWidth ?? 0) == 0)
    }

    @Test("A deleted stroke takes the ring away (spec §3.1 null)")
    func strokeIsResolvedNotOptional() throws {
        let (engine, renderer) = try mount()
        engine.receive(try Fixtures.envelope("commit-app-controls-update.json"))

        // `stroke: null` — the frame goes, and the node is not rebuilt for it.
        let sleeve = try image(renderer, 2)
        #expect(sleeve.layer?.borderWidth == 0)
        #expect((sleeve as? LedgeFileImageView)?.layer?.cornerRadius == 14)

        // …and an image that gains one mid-life gets it without a new node.
        let framed = try image(renderer, 4)
        #expect(framed.layer?.borderWidth == LedgeMetrics.hairline)
        #expect(framed.layer?.borderColor == LedgeTheme.hairline.cgColor)
    }

    // MARK: - `image.src` on a symbol node (G3)

    @Test("An `sf:` image re-applies `src` on update, in place")
    func symbolImageAcceptsASrcUpdate() throws {
        let (engine, renderer) = try mount()
        let glyph = try #require(renderer.view(app: "gallery", id: 3) as? LedgeSymbolView)
        #expect(glyph.symbol == "waveform")
        let mounted = glyph.image

        engine.receive(try Fixtures.envelope("commit-app-controls-update.json"))

        // The node is the same object — an update, not a remount. That is the
        // whole bug: `configure` guarded `as? LedgeFileImageView`, so the only
        // way an app could change a symbol was to make React throw the node
        // away and build a new one (Focus carried exactly that `key`).
        #expect(renderer.view(app: "gallery", id: 3) === glyph)
        #expect(glyph.symbol == "waveform.badge.mic")
        #expect(glyph.image !== mounted)
        // …and the glyph resolved: a symbol that does not exist falls back to
        // `questionmark.square.dashed`, which would make the assertion above
        // pass while the picture stayed wrong.
        #expect(glyph.image?.accessibilityDescription == "waveform.badge.mic")

        // The stroke it was mounted with is untouched by a src-only update —
        // `configure` sees merged props, and `accent` is still in them.
        #expect(glyph.layer?.borderColor == LedgeTheme.accentStroke.cgColor)
    }

    @Test("A file path arriving at a symbol node changes nothing")
    func symbolImageIgnoresAFilePath() throws {
        let (engine, renderer) = try mount()
        let glyph = try #require(renderer.view(app: "gallery", id: 3) as? LedgeSymbolView)

        // Changing *kind* is a different component (§5): a bare path here must
        // not be drawn as a symbol named "/tmp/…", and must not blank the node.
        engine.receive(Envelope(
            app: "gallery",
            seq: 30,
            type: "commit",
            payload: .object(["mutations": .array([
                .object(["op": .string("update"), "id": .int(3), "props": .object([
                    "src": .string("/tmp/ledge-fixture-artwork.png"),
                ])]),
            ])])
        ))
        #expect(glyph.symbol == "waveform")
        #expect(glyph.image?.accessibilityDescription == "waveform")
    }
}
