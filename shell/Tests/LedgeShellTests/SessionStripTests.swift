import Foundation
import Testing
@testable import LedgeShellCore

/// **The strip** (flow.md, "The strip"), which replaced the bottom app bar.
///
/// `AppStripTests` used to live here and tested a scrolling row of icons with a
/// pinned **[+]** and a pinned Settings — a bar flow.md does not have. What
/// survived the deletion is the *idea*: a linear row of sessions you walk. Its
/// two laws are below, and the second one is the whole reason this is a value
/// type rather than an index into an array.
@Suite("The session strip (flow.md)")
struct SessionStripTests {
    private func catalog(_ ids: [String], disabled: Set<String> = []) -> [CatalogApp] {
        ids.enumerated().map { index, id in
            CatalogApp(
                id: id,
                name: id.capitalized,
                icon: "sf:circle",
                order: index,
                enabled: !disabled.contains(id),
                running: true
            )
        }
    }

    @Test("Installed apps in registry order, then exactly one blank slot")
    func slotsAreRegistryOrderPlusOneBlank() {
        let strip = SessionStrip(catalog: catalog(["music", "chess", "weather"]))
        #expect(strip.slots == [.app("music"), .app("chess"), .app("weather"), .blank])
        #expect(strip.slots.filter { $0 == .blank }.count == 1)
    }

    @Test("Catalog order wins over catalog sequence, and disabled apps are not on it")
    func orderAndEnablement() {
        var apps = catalog(["weather", "chess"], disabled: ["chess"])
        apps[0].order = 5
        let strip = SessionStrip(catalog: apps)
        // A disabled app is one the user turned off; walking onto it would be
        // walking onto nothing.
        #expect(strip.apps == ["weather"])
    }

    /// flow.md: "Walking past either end lands on the blank slot — at most one
    /// blank exists." Both halves of that sentence are one fact: the slots are a
    /// **ring** with the blank as its last member, so the two ends meet there.
    @Test("Walking past either end lands on the same blank slot")
    func bothEndsMeetAtTheBlank() {
        let strip = SessionStrip(catalog: catalog(["music", "chess", "weather"]))

        // Off the right-hand end.
        #expect(strip.step(from: .app("weather"), by: 1) == .blank)
        // Off the left-hand end — the *same* blank, not a second one.
        #expect(strip.step(from: .app("music"), by: -1) == .blank)
        // And leaving the blank in either direction lands on a real end.
        #expect(strip.step(from: .blank, by: 1) == .app("music"))
        #expect(strip.step(from: .blank, by: -1) == .app("weather"))
    }

    @Test("Ordinary steps walk one session at a time, in both directions")
    func ordinarySteps() {
        let strip = SessionStrip(catalog: catalog(["music", "chess", "weather"]))
        #expect(strip.step(from: .app("music"), by: 1) == .app("chess"))
        #expect(strip.step(from: .app("chess"), by: 1) == .app("weather"))
        #expect(strip.step(from: .app("weather"), by: -1) == .app("chess"))
        // A step of zero is where you already are — the identity a swipe that
        // did not clear the threshold must resolve to.
        #expect(strip.step(from: .app("chess"), by: 0) == .app("chess"))
    }

    @Test("A presentation maps onto the strip; the blank slot IS the [+] surface")
    func presentationsMapOntoSlots() {
        let strip = SessionStrip(catalog: catalog(["music", "chess"]))
        #expect(strip.slot(for: .expanded(app: "chess")) == .app("chess"))
        #expect(strip.slot(for: .chat(app: "chess")) == .app("chess"))
        // **[+]** is gone as a control; the blank slot is what it became.
        #expect(strip.slot(for: .newApp) == .blank)
        // Surfaces that are not sessions are not on the strip at all — the
        // permission card, and an app the catalog does not have.
        #expect(strip.slot(for: .permissions) == nil)
        #expect(strip.slot(for: .expanded(app: "ghost")) == nil)
        #expect(strip.slot(for: .collapsed) == nil)
    }

    @Test("A strip with nothing installed is one blank slot, and walking it stays put")
    func emptyStrip() {
        let strip = SessionStrip(catalog: [])
        #expect(strip.slots == [.blank])
        #expect(strip.step(from: .blank, by: 1) == .blank)
        #expect(strip.step(from: .blank, by: -1) == .blank)
        // Walking from a surface that is not on the strip walks *onto* it,
        // rather than refusing — which is how ‹|› gets you out of the
        // placeholder card.
        #expect(strip.step(from: nil, by: 1) == .blank)
    }

    @Test("Walking from a non-strip surface lands on the first session")
    func walkingOntoTheStrip() {
        let strip = SessionStrip(catalog: catalog(["music", "chess"]))
        #expect(strip.step(from: nil, by: 1) == .app("music"))
        #expect(strip.step(from: nil, by: -1) == .blank)
    }
}
